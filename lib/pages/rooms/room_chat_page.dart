import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RoomChatPage extends StatefulWidget {
  const RoomChatPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.embedded = false,
    this.onClose,
  });

  final String roomId;
  final String roomName;
  final bool embedded;
  final VoidCallback? onClose;

  @override
  State<RoomChatPage> createState() => _RoomChatPageState();
}

class _RoomChatPageState extends State<RoomChatPage> {
  final _supabase = Supabase.instance.client;
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_RoomMessage> _messages = [];
  RealtimeChannel? _channel;
  bool _loading = true;
  bool _sending = false;
  bool _realtimeConnected = false;
  String? _myUsername;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscribe();
    _loadHistory();
    _loadMyUsername();
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
      await _loadHistory();
    } catch (_) {
      // Chat remains usable if profile lookup is unavailable.
    }
  }

  void _subscribe() {
    _channel = _supabase
        .channel(
          'room:${widget.roomId}',
          opts: const RealtimeChannelConfig(private: true),
        )
        .onBroadcast(
          event: 'new_message',
          callback: (payload) {
            final message = _RoomMessage.fromMap(
              payload,
              myUsername: _myUsername,
              myUserId: _supabase.auth.currentUser?.id,
            );
            if (message.roomId != widget.roomId || !mounted) return;
            setState(() {
              if (!_messages.any((item) => item.id == message.id)) {
                _messages.add(message);
                _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
              }
            });
            _scrollToLatest();
          },
        )
        .subscribe((status, error) {
          if (!mounted) return;
          final connected = status == RealtimeSubscribeStatus.subscribed;
          setState(() => _realtimeConnected = connected);
          if (connected) {
            // Catch messages sent while this client was joining the channel.
            _loadHistory();
          } else if (status == RealtimeSubscribeStatus.channelError ||
              status == RealtimeSubscribeStatus.timedOut) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  error == null
                      ? 'Live chat connection failed. Reopen this room to retry.'
                      : 'Live chat connection failed: $error',
                ),
              ),
            );
          }
        });
  }

  Future<void> _loadHistory() async {
    try {
      final rows = await _supabase.rpc(
        'get_room_messages',
        params: {'p_room_id': widget.roomId, 'p_limit': 100},
      );
      final history = List<Map<String, dynamic>>.from(rows)
          .map(
            (row) => _RoomMessage.fromMap(
              row,
              myUsername: _myUsername,
              myUserId: _supabase.auth.currentUser?.id,
            ),
          )
          .toList();
      if (!mounted) return;
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
      _scrollToLatest();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load messages. Please try again.';
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
      await _supabase.from('room_messages').insert({
        'room_id': widget.roomId,
        'content': content,
      });
      _textController.clear();
      await _loadHistory();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send your message.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
    _textController.dispose();
    _scrollController.dispose();
    final channel = _channel;
    if (channel != null) unawaited(_supabase.removeChannel(channel));
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
              _realtimeConnected ? 'Live' : 'Connecting…',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
      body: _buildChatBody(),
    );
  }

  Widget _buildChatBody() {
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
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final colors = Theme.of(context).colorScheme;
        final mine = message.isMine;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: mine
                  ? colors.primaryContainer
                  : colors.surfaceContainerLow,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!mine)
                  Text(
                    message.authorUsername,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                Text(message.content),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    _formatTime(message.createdAt),
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ),
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

class _RoomMessage {
  const _RoomMessage({
    required this.id,
    required this.roomId,
    required this.authorUsername,
    required this.content,
    required this.createdAt,
    required this.isMine,
  });

  factory _RoomMessage.fromMap(
    Map<String, dynamic> map, {
    String? myUsername,
    String? myUserId,
  }) {
    final authorUsername = (map['author_username'] as String?) ?? 'Anonymous';
    return _RoomMessage(
      id: map['message_id'] as String,
      roomId: map['room_id'] as String,
      authorUsername: authorUsername,
      content: map['content'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      isMine:
          (myUserId != null && map['author_id'] == myUserId) ||
          (myUsername != null && authorUsername == myUsername),
    );
  }

  final String id;
  final String roomId;
  final String authorUsername;
  final String content;
  final DateTime createdAt;
  final bool isMine;
}
