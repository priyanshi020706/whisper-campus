import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/error_message.dart';
import '../../core/widgets/keyboard_helpers.dart';
import '../../models/room_message.dart';
import '../../services/room_activity_controller.dart';
import '../../services/live_signals.dart';
import 'chat_bubble.dart';
import 'chat_parts.dart';
import 'room_mute_button.dart';
import '../../services/chat_extras_service.dart';
import '../../models/poll.dart';
import '../../models/chat_extras.dart';
import '../../core/widgets/poll_card.dart';
import '../../core/widgets/create_poll_sheet.dart';
import '../../services/report_service.dart';

class RoomChatPage extends StatefulWidget {
  const RoomChatPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.embedded = false,
    this.onClose,
    this.roomConversation = false,
    this.roomMode = 'unofficial',
    this.onRead,
    this.activity,
  });

  final String roomId;
  final String roomName;
  final bool embedded;
  final VoidCallback? onClose;
  final bool roomConversation;
  final String roomMode;
  final VoidCallback? onRead;

  /// Shared recent-chat state. When given (room conversations), the header
  /// shows a mute button for this room.
  final RoomActivityController? activity;

  @override
  State<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends State<RoomChatPage> {
  final _supabase = Supabase.instance.client;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();
  late final KeyboardStickyScroll _keyboardScroll;
  final List<RoomMessage> _messages = [];
  final _extrasService = ChatExtrasService();

  // Replies, reactions and polls, keyed by message id.
  final Map<String, ReplyLink> _replyLinks = {};
  final Map<String, List<ReactionCount>> _reactions = {};
  final Map<String, PollData> _polls = {};
  final Set<String> _extrasFetched = {};
  RoomMessage? _replyingTo;

  /// After a failed extras fetch (for example before the database update is
  /// applied) stop retrying on every refresh for a minute.
  DateTime? _extrasBackoffUntil;
  RealtimeChannel? _channel;
  Timer? _syncTimer;
  int _syncTick = 0;
  bool _connectionWarningShown = false;
  bool _loading = true;
  bool _sending = false;
  bool _realtimeConnected = false;
  String? _myUsername;
  String? _error;
  String? _blockedReason;
  bool _joinedOfficialSession = false;
  bool _joinedRoomConversation = false;
  bool _canModerateRoom = false;
  bool _isSuperAdmin = false;

  @override
  void initState() {
    super.initState();
    // Keep the newest messages visible when the keyboard opens or closes.
    _keyboardScroll = KeyboardStickyScroll(_scrollController)..attach();
    _inputFocus.addListener(_onInputFocusChanged);
    if (widget.roomConversation) {
      _joinRoomConversation();
    } else if (widget.roomId == 'official-live' || widget.roomId == 'general') {
      _joinOfficialSession();
    } else {
      unawaited(_startChat());
    }
  }

  /// Bell button to mute this room for a while, or until unmuted.
  Widget? _muteButton() {
    final activity = widget.activity;
    if (activity == null || !widget.roomConversation) return null;
    return RoomMuteButton(controller: activity, roomId: widget.roomId);
  }

  void _onInputFocusChanged() {
    // Tapping the box opens the keyboard: stay on the latest message if we
    // were reading it. The metrics observer covers the animation itself; this
    // covers keyboards that report their size late.
    if (!_inputFocus.hasFocus || !_nearBottom) return;
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (mounted && _nearBottom) _keyboardScroll.jumpToBottomAfterLayout();
    });
  }

  Future<void> _startChat() async {
    unawaited(_loadMyRole());
    // Know our own name before any message arrives so "mine" is right.
    await _loadMyUsername();
    if (!mounted) return;
    _subscribe();
    await _loadHistory();
    _startSyncTimer();
  }

  /// Safety net behind the live channel: if the socket drops or a broadcast is
  /// missed, messages still appear within seconds without a manual refresh.
  /// It polls every 4 seconds while disconnected and every 24 seconds while
  /// connected.
  void _startSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || _blockedReason != null) return;
      _syncTick++;
      if (_realtimeConnected && _syncTick % 6 != 0) return;
      _loadHistory();
      // Reactions and votes can be missed too: refresh them on the slow tick.
      if (_syncTick % 6 == 0) {
        unawaited(_loadExtras(all: true));
      }
    });
  }

  bool get _nearBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels < 120;
  }

  Future<void> _loadMyRole() async {
    final uid = _supabase.auth.currentUser?.id;
    if (uid == null) return;
    try {
      final row = await _supabase
          .from('profiles')
          .select('role')
          .eq('id', uid)
          .maybeSingle();
      final admin = row?['role'] == 'super_admin';
      if (mounted) {
        setState(() {
          _isSuperAdmin = admin;
          if (admin) _canModerateRoom = true;
        });
      }
    } catch (_) {}
  }

  Future<void> _joinRoomConversation() async {
    try {
      final blocked = await _supabase.rpc(
        'get_my_room_block',
        params: {'p_room_id': widget.roomId, 'p_mode': widget.roomMode},
      );
      if (blocked is List && blocked.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _blockedReason =
              blocked.first['reason'] as String? ?? 'Room rules violation';
          _loading = false;
        });
        return;
      }
      await _supabase.rpc(
        'join_room_chat',
        params: {'p_room_id': widget.roomId, 'p_mode': widget.roomMode},
      );
      _joinedRoomConversation = true;
      widget.onRead?.call();
      if (mounted) unawaited(_startChat());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not join this room chat: ${friendlyError(error)}';
        _loading = false;
      });
    }
  }

  Future<void> _joinOfficialSession() async {
    try {
      final mode = widget.roomId == 'official-live' ? 'official' : 'unofficial';
      final blocked = await _supabase.rpc(
        'get_my_room_block',
        params: {'p_room_id': widget.roomId, 'p_mode': mode},
      );
      if (blocked is List && blocked.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _blockedReason =
              blocked.first['reason'] as String? ?? 'Room rules violation';
          _loading = false;
        });
        return;
      }
      await _supabase.rpc('join_room', params: {'p_room_id': widget.roomId});
      _joinedOfficialSession = true;
      final faculty = await _supabase.rpc('is_faculty');
      final moderator = await _supabase.rpc(
        'is_active_room_moderator',
        params: {'p_room': widget.roomId, 'p_mode': mode},
      );
      if (mounted) {
        setState(
          () => _canModerateRoom =
              _isSuperAdmin ||
              moderator == true ||
              (widget.roomId == 'official-live' && faculty == true),
        );
      }
      if (mounted) unawaited(_startChat());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not join this room: ${friendlyError(error)}';
        _loading = false;
      });
    }
  }

  Future<void> _loadMyUsername() async {
    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) return;
    try {
      final row = await _supabase
          .from('profiles')
          .select('anon_username')
          .eq('id', userId)
          .maybeSingle();
      if (!mounted) return;
      setState(() => _myUsername = row?['anon_username'] as String?);
    } catch (_) {
      // Chat remains usable if profile lookup is unavailable.
    }
  }

  void _subscribe() {
    _channel = _supabase
        .channel(
          widget.roomConversation
              ? 'room:${widget.roomMode}:${widget.roomId}'
              : 'room:${widget.roomId}',
          opts: const RealtimeChannelConfig(private: true),
        )
        .onBroadcast(
          event: 'new_message',
          callback: (raw) {
            if (!mounted) return;
            try {
              final message = RoomMessage.fromMap(
                unwrapBroadcast(raw),
                myUsername: _myUsername,
                myUserId: _supabase.auth.currentUser?.id,
              );
              if (message.roomId != widget.roomId) return;
              final stickToBottom = message.isMine || _nearBottom;
              setState(() {
                if (!_messages.any((item) => item.id == message.id)) {
                  _messages.add(message);
                  _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
                }
              });
              if (stickToBottom) _scrollToLatest();
              unawaited(_loadExtras(ids: [message.id]));
            } catch (error) {
              // Never lose a message because one payload was malformed.
              debugPrint('LIVE CHAT PAYLOAD ERROR: $error');
              _loadHistory();
            }
          },
        )
        .onBroadcast(
          event: 'reaction_changed',
          callback: (raw) {
            final id = unwrapBroadcast(raw)['message_id']?.toString();
            if (id != null && mounted) unawaited(_loadExtras(ids: [id]));
          },
        )
        .onBroadcast(
          event: 'poll_changed',
          callback: (raw) {
            final id = unwrapBroadcast(raw)['message_id']?.toString();
            if (id != null && mounted) unawaited(_loadExtras(ids: [id]));
          },
        )
        .onBroadcast(
          event: 'message_removed',
          callback: (raw) {
            if (!mounted) return;
            final body = unwrapBroadcast(raw);
            if (body['room_id']?.toString() != widget.roomId) return;
            final id = body['message_id']?.toString();
            if (id == null) return;
            setState(
              () => _messages.removeWhere((message) => message.id == id),
            );
          },
        )
        .subscribe((status, error) {
          if (!mounted) return;
          final connected = status == RealtimeSubscribeStatus.subscribed;
          setState(() => _realtimeConnected = connected);
          if (connected) {
            _connectionWarningShown = false;
            // Catch messages sent while this client was joining the channel.
            _loadHistory();
          } else if ((status == RealtimeSubscribeStatus.channelError ||
                  status == RealtimeSubscribeStatus.timedOut) &&
              !_connectionWarningShown) {
            _connectionWarningShown = true;
            debugPrint('LIVE CHAT CONNECTION ERROR: $status $error');
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Live connection lost. Reconnecting; messages will keep refreshing.',
                ),
              ),
            );
          }
        });
  }

  Future<void> _loadHistory() async {
    try {
      final rows = widget.roomConversation
          ? await _supabase.rpc(
              'get_room_chat_messages',
              params: {
                'p_room_id': widget.roomId,
                'p_mode': widget.roomMode,
                'p_limit': 100,
              },
            )
          : await _supabase.rpc(
              'get_room_messages',
              params: {'p_room_id': widget.roomId, 'p_limit': 100},
            );
      final history = List<Map<String, dynamic>>.from(rows)
          .map(
            (row) => RoomMessage.fromMap(
              row,
              myUsername: _myUsername,
              myUserId: _supabase.auth.currentUser?.id,
            ),
          )
          .toList();
      if (!mounted) return;
      final hadMessages = _messages.length;
      final wasNearBottom = _nearBottom;
      setState(() {
        final liveMessages = _messages.toList();
        _messages
          ..clear()
          ..addAll(history);
        for (final message in liveMessages) {
          if (!_messages.any((item) => item.id == message.id)) {
            _messages.add(message);
          }
        }
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _loading = false;
        _error = null;
      });
      if (_messages.length != hadMessages &&
          (hadMessages == 0 || wasNearBottom)) {
        _scrollToLatest();
      }
      unawaited(_loadExtras());
    } catch (error) {
      debugPrint('LOAD CHAT HISTORY ERROR: $error');
      if (!mounted) return;
      // A failed background refresh must not replace messages already shown.
      if (_messages.isNotEmpty) return;
      setState(() {
        _loading = false;
        _error = 'Could not load messages: ${friendlyError(error)}';
      });
    }
  }

  /// Fetches replies, reactions and polls. By default only for messages not
  /// fetched before; [ids] refreshes specific ones, [all] refreshes every
  /// message currently shown.
  Future<void> _loadExtras({List<String>? ids, bool all = false}) async {
    final backingOff =
        _extrasBackoffUntil != null &&
        DateTime.now().isBefore(_extrasBackoffUntil!);
    if (backingOff && !all && ids == null) return;
    final wanted =
        ids ??
        [
          for (final message in _messages)
            if (all || !_extrasFetched.contains(message.id)) message.id,
        ];
    if (wanted.isEmpty) return;
    // The server accepts up to 300 at a time; the screen holds at most ~100.
    final batch = wanted.length > 200
        ? wanted.sublist(wanted.length - 200)
        : wanted;
    try {
      final extras = await _extrasService.fetch(batch);
      if (!mounted) return;
      setState(() {
        for (final id in batch) {
          _extrasFetched.add(id);
          final link = extras.links[id];
          if (link != null) {
            _replyLinks[id] = link;
          }
          final poll = extras.polls[id];
          if (poll != null) {
            _polls[id] = poll;
          }
          final reactions = extras.reactions[id];
          if (reactions == null || reactions.isEmpty) {
            _reactions.remove(id);
          } else {
            _reactions[id] = reactions;
          }
        }
      });
    } catch (error) {
      // Extras are an extra: messages stay readable without them.
      debugPrint('CHAT EXTRAS ERROR: $error');
      _extrasBackoffUntil = DateTime.now().add(const Duration(minutes: 1));
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// React to a message. Shows at once; undone if the server refuses.
  Future<void> _react(RoomMessage message, String? emoji) async {
    final before = _reactions[message.id] ?? const <ReactionCount>[];
    final after = reactionsAfterChoosing(before, emoji);
    setState(() {
      if (after.isEmpty) {
        _reactions.remove(message.id);
      } else {
        _reactions[message.id] = after;
      }
    });
    try {
      await _extrasService.react(message.id, emoji);
    } catch (error) {
      debugPrint('REACT ERROR: $error');
      if (!mounted) return;
      setState(() {
        if (before.isEmpty) {
          _reactions.remove(message.id);
        } else {
          _reactions[message.id] = before;
        }
      });
      _say(friendlyError(error));
    }
  }

  /// Sends a vote. Returns null on success, or a message to show.
  Future<String?> _vote(
    PollData poll,
    List<String> optionIds,
    String messageId,
  ) async {
    try {
      await _extrasService.vote(poll.pollId, optionIds);
      unawaited(_loadExtras(ids: [messageId]));
      return null;
    } catch (error) {
      debugPrint('VOTE ERROR: $error');
      return friendlyError(error);
    }
  }

  Future<void> _createPoll() async {
    final draft = await showCreatePollSheet(
      context,
      title: 'Create a poll',
      confirmLabel: 'Send poll',
    );
    if (draft == null || !mounted) return;
    try {
      await _extrasService.createPoll(
        roomId: widget.roomId,
        mode: widget.roomMode,
        draft: draft,
      );
      _keyboardScroll.stickToBottom();
      await _loadHistory();
      _scrollToLatest();
    } catch (error) {
      debugPrint('CREATE POLL ERROR: $error');
      _say('Could not send the poll: ${friendlyError(error)}');
    }
  }

  void _startReply(RoomMessage message) {
    setState(() => _replyingTo = message);
    _inputFocus.requestFocus();
  }

  void _openMessageActions(RoomMessage message) {
    final mine = message.isMine;
    final myReaction = (_reactions[message.id] ?? const <ReactionCount>[])
        .where((r) => r.mine)
        .map((r) => r.emoji)
        .firstOrNull;
    showMessageActions(
      context,
      currentReaction: myReaction,
      onReact: (emoji) => _react(message, emoji),
      actions: [
        MessageAction(Icons.reply_rounded, 'Reply', () => _startReply(message)),
        if (!mine)
          MessageAction(Icons.flag_outlined, 'Report message', () {
            reportContent(
              context,
              target: ReportTarget.message,
              targetId: message.id,
            );
          }),
        if (_isSuperAdmin)
          MessageAction(
            Icons.delete_outline,
            'Remove for everyone',
            () => _deleteMessage(message),
          ),
      ],
    );
  }

  /// The quote shown in a reply bubble: the original if it is loaded, otherwise
  /// the short text the server kept.
  ChatQuote? _quoteFor(RoomMessage message) {
    final link = _replyLinks[message.id];
    if (link == null) return null;
    RoomMessage? original;
    for (final candidate in _messages) {
      if (candidate.id == link.replyTo) {
        original = candidate;
        break;
      }
    }
    return ChatQuote(
      author: original == null
          ? null
          : (original.isMine ? 'You' : original.authorUsername),
      content: original?.content ?? link.quotedContent ?? 'Original message',
    );
  }

  Future<void> _sendMessage() async {
    final content = _textController.text.trim();
    if (content.isEmpty || _sending) return;
    if (_supabase.auth.currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please sign in to send a message.')),
      );
      return;
    }

    setState(() => _sending = true);
    try {
      final replyTo = _replyingTo;
      if (replyTo != null) {
        await _extrasService.sendReply(
          roomId: widget.roomId,
          mode: widget.roomMode,
          content: content,
          replyTo: replyTo.id,
        );
        if (mounted) setState(() => _replyingTo = null);
      } else if (widget.roomConversation) {
        await _supabase.rpc(
          'send_room_chat_message',
          params: {
            'p_room_id': widget.roomId,
            'p_mode': widget.roomMode,
            'p_content': content,
          },
        );
      } else {
        await _supabase.rpc(
          'send_campus_live_message',
          params: {'p_room_id': widget.roomId, 'p_content': content},
        );
      }
      _textController.clear();
      _keyboardScroll.stickToBottom();
      await _loadHistory();
      _scrollToLatest();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not send your message: ${friendlyError(error)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _deleteMessage(RoomMessage message) async {
    if (!_isSuperAdmin) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove this chat message?'),
        content: const Text(
          'This message will be deleted for everyone in this room.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _supabase.rpc(
        'admin_delete_room_message',
        params: {
          'p_message_id': message.id,
          'p_room_id': widget.roomId,
          'p_mode': widget.roomId == 'official-live'
              ? 'official'
              : widget.roomMode,
        },
      );
      if (mounted) {
        setState(() => _messages.removeWhere((item) => item.id == message.id));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not remove message: ${friendlyError(error)}'),
          ),
        );
      }
    }
  }

  Future<void> _blockUser(RoomMessage message) async {
    final authorId = message.authorId;
    if (!_canModerateRoom || authorId == null || message.isMine) return;
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove and block this member?'),
        content: TextField(
          controller: reason,
          maxLength: 500,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Reason for the warning',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Block for 3 days'),
          ),
        ],
      ),
    );
    final messageReason = reason.text.trim();
    reason.dispose();
    if (confirmed != true || messageReason.isEmpty) return;
    try {
      await _supabase.rpc(
        'block_room_user',
        params: {
          'p_room_id': widget.roomId,
          'p_user_id': authorId,
          'p_reason': messageReason,
          'p_mode': widget.roomConversation
              ? widget.roomMode
              : widget.roomId == 'official-live'
              ? 'official'
              : 'unofficial',
        },
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Member removed and blocked for 3 days.'),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not block this member: ${friendlyError(error)}',
            ),
          ),
        );
      }
    }
  }

  Future<void> _showOfficialProfile(String? userId) async {
    if (widget.roomId != 'official-live' || userId == null) return;
    try {
      final result = await _supabase.rpc(
        'get_official_profile_card',
        params: {'p_user_id': userId},
      );
      if (result is! List || result.isEmpty || !mounted) return;
      final profile = Map<String, dynamic>.from(result.first);
      final isFaculty = profile['role'] == 'faculty';
      final isSuperAdmin = profile['role'] == 'super_admin';
      await showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile['real_name']?.toString() ?? 'Student',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  isFaculty
                      ? 'Faculty${(profile['branch_code']?.toString().isNotEmpty ?? false) ? ' · ${profile['branch_code']}' : ''}'
                      : isSuperAdmin
                      ? 'Faculty · Super Admin'
                      : '${profile['branch_code']?.toString() ?? ''} · ${_yearLabel(profile['study_year'])}',
                ),
                if ((profile['enrollment_number']?.toString().isNotEmpty ??
                    false)) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Enrollment number: ${profile['enrollment_number']}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (profile['moderated_rooms'] is List &&
                    (profile['moderated_rooms'] as List).isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('Room moderator in'),
                  const SizedBox(height: 4),
                  Text((profile['moderated_rooms'] as List).join(', ')),
                ],
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open profile: ${friendlyError(error)}'),
          ),
        );
      }
    }
  }

  String _yearLabel(Object? value) {
    final year = (value as num?)?.toInt();
    if (year == null) return 'Year unavailable';
    if (year > 4) return 'Alumni';
    if (year == 1) return '1st year';
    if (year == 2) return '2nd year';
    if (year == 3) return '3rd year';
    return '4th year';
  }

  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _keyboardScroll.dispose();
    _inputFocus.removeListener(_onInputFocusChanged);
    _inputFocus.dispose();
    _textController.dispose();
    _scrollController.dispose();
    final channel = _channel;
    if (channel != null) unawaited(_supabase.removeChannel(channel));
    if (_joinedRoomConversation) {
      unawaited(
        _supabase.rpc(
          'leave_room_chat',
          params: {'p_room_id': widget.roomId, 'p_mode': widget.roomMode},
        ),
      );
    } else if (_joinedOfficialSession) {
      unawaited(
        _supabase.rpc('leave_room', params: {'p_room_id': widget.roomId}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      final colors = Theme.of(context).colorScheme;
      return Material(
        color: colors.surface,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(
                children: [
                  Icon(Icons.waves_rounded, color: colors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${widget.roomName} chat',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(
                          _realtimeConnected ? 'Live' : 'Connecting…',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                  ?_muteButton(),
                  if (widget.onClose != null)
                    IconButton(
                      tooltip: 'Close live chat',
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close_rounded),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildChatBody()),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.roomName} chat'),
            Text(
              widget.roomConversation
                  ? (_realtimeConnected
                        ? 'Live · Messages disappear after 7 days'
                        : 'Connecting · 7-day message history')
                  : (_realtimeConnected ? 'Live' : 'Connecting…'),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
        actions: [?_muteButton()],
      ),
      body: _buildChatBody(),
    );
  }

  Widget _buildChatBody() {
    if (_blockedReason != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'You are blocked from ${widget.roomName} for 3 days. Reason: ${_blockedReason!}',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final replying = _replyingTo;
    return Column(
      children: [
        Expanded(child: _buildMessages()),
        if (replying != null)
          ReplyBanner(
            author: replying.isMine ? 'yourself' : replying.authorUsername,
            content: replying.content,
            onClose: () => setState(() => _replyingTo = null),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Create a poll',
                  onPressed: _createPoll,
                  icon: const Icon(Icons.poll_outlined),
                ),
                Expanded(
                  child: SendOnEnter(
                    controller: _textController,
                    onSend: _sendMessage,
                    child: TextField(
                      controller: _textController,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Write a message…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: _sending ? null : _sendMessage,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessages() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _loadHistory, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_messages.isEmpty) {
      return const Center(child: Text('No messages yet. Say hello!'));
    }
    return ListView.builder(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final previous = index > 0 ? _messages[index - 1] : null;
        final mine = message.isMine;
        final startsGroup = startsChatGroup(previous, message);
        final newDay =
            previous == null ||
            !isSameChatDay(
              previous.createdAt.toLocal(),
              message.createdAt.toLocal(),
            );

        final menuItems = <(String, String)>[
          if (!mine) ('reply', 'Reply'),
          if (!mine) ('report', 'Report message'),
          if (_isSuperAdmin) ('remove', 'Remove for everyone'),
        ];
        final poll = _polls[message.id];
        final canOpenProfile = widget.roomId == 'official-live';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay)
              ChatDaySeparator(
                label: chatDayLabel(message.createdAt.toLocal()),
              ),
            ChatBubble(
              message: message,
              startsGroup: startsGroup,
              timeLabel: _formatTime(message.createdAt),
              menuItems: menuItems,
              quote: _quoteFor(message),
              reactions: _reactions[message.id] ?? const [],
              onReactionTap: (emoji) => _react(message, emoji),
              onActions: () => _openMessageActions(message),
              onSwipeReply: () => _startReply(message),
              pollBuilder: poll == null
                  ? null
                  : (textColor, accent) => PollCard(
                      poll: poll,
                      textColor: textColor,
                      accentColor: accent,
                      onVote: (ids) => _vote(poll, ids, message.id),
                    ),
              onMenuSelected: (value) {
                if (value == 'reply') _startReply(message);
                if (value == 'remove') _deleteMessage(message);
                if (value == 'report') {
                  reportContent(
                    context,
                    target: ReportTarget.message,
                    targetId: message.id,
                  );
                }
              },
              onNameTap: canOpenProfile
                  ? () => _showOfficialProfile(message.authorId)
                  : null,
              onNameLongPress: canOpenProfile && _canModerateRoom
                  ? () => _blockUser(message)
                  : null,
            ),
          ],
        );
      },
    );
  }

  String _formatTime(DateTime date) {
    final local = date.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
