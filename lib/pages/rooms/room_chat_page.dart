import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/utils/error_message.dart';
import '../../models/room_message.dart';
import '../../services/live_signals.dart';
import 'chat_bubble.dart';
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
  });

  final String roomId;
  final String roomName;
  final bool embedded;
  final VoidCallback? onClose;
  final bool roomConversation;
  final String roomMode;
  final VoidCallback? onRead;

  @override
  State<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends State<RoomChatPage> {
  final _supabase = Supabase.instance.client;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<RoomMessage> _messages = [];
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
    if (widget.roomConversation) {
      _joinRoomConversation();
    } else if (widget.roomId == 'official-live' || widget.roomId == 'general') {
      _joinOfficialSession();
    } else {
      unawaited(_startChat());
    }
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
          _blockedReason = blocked.first['reason'] as String? ?? 'Room rules violation';
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
        setState(() => _canModerateRoom =
            _isSuperAdmin || moderator == true ||
            (widget.roomId == 'official-live' && faculty == true));
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
            } catch (error) {
              // Never lose a message because one payload was malformed.
              debugPrint('LIVE CHAT PAYLOAD ERROR: $error');
              _loadHistory();
            }
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
      if (_messages.length != hadMessages && (hadMessages == 0 || wasNearBottom)) {
        _scrollToLatest();
      }
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
      if (widget.roomConversation) {
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
      await _loadHistory();
      _scrollToLatest();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send your message: ${friendlyError(error)}')),
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
          SnackBar(content: Text('Could not remove message: ${friendlyError(error)}')),
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
            content: Text('Could not block this member: ${friendlyError(error)}'),
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
                      ? 'Faculty${(profile['branch_code']?.toString().isNotEmpty ??
                                    false)
                                ? ' · ${profile['branch_code']}'
                                : ''}'
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
    return Column(
      children: [
        Expanded(child: _buildMessages()),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: 'Write a message…',
                      border: OutlineInputBorder(),
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final previous = index > 0 ? _messages[index - 1] : null;
        final mine = message.isMine;
        final startsGroup = startsChatGroup(previous, message);
        final newDay = previous == null ||
            !isSameChatDay(
              previous.createdAt.toLocal(),
              message.createdAt.toLocal(),
            );

        final menuItems = <(String, String)>[
          if (!mine) ('report', 'Report message'),
          if (_isSuperAdmin) ('remove', 'Remove for everyone'),
        ];
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
              onMenuSelected: (value) {
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
