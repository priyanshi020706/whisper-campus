import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LiveRoomPreview extends StatefulWidget {
  const LiveRoomPreview({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.onJoin,
    this.expanded = false,
    this.onClose,
  });

  final String roomId;
  final String roomName;
  final VoidCallback onJoin;
  final bool expanded;
  final VoidCallback? onClose;

  @override
  State<LiveRoomPreview> createState() => _LiveRoomPreviewState();
}

class _LiveRoomPreviewState extends State<LiveRoomPreview> {
  final _supabase = Supabase.instance.client;
  List<_PreviewMessage> _messages = [];
  Timer? _refreshTimer;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadLatest();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _loadLatest(),
    );
  }

  @override
  void didUpdateWidget(covariant LiveRoomPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId) {
      _messages = [];
      _loading = true;
      _loadLatest();
    }
  }

  Future<void> _loadLatest() async {
    try {
      final rows = await _supabase.rpc(
        'get_room_messages',
        params: {
          'p_room_id': widget.roomId,
          'p_limit': widget.expanded ? 30 : 3,
        },
      );
      final messages = List<Map<String, dynamic>>.from(rows)
          .map(_PreviewMessage.fromMap)
          .toList();
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: colors.primary.withValues(alpha: 0.34)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.waves_rounded,
                    color: colors.onPrimaryContainer,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Campus Live',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFF35C98A),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Live · ${widget.roomName.toLowerCase()}',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    tooltip: 'Close live panel',
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
              ],
            ),
          ),
          if (widget.expanded)
            Expanded(child: _buildExpandedContent(colors))
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 17),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'See what students are talking about right now.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  if (_loading && _messages.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (_failed && _messages.isEmpty)
                    TextButton.icon(
                      onPressed: _loadLatest,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Could not load chat. Tap to retry.'),
                    )
                  else if (_messages.isEmpty)
                    Text(
                      'It is quiet for now. Be the first to say hello.',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    )
                  else
                    ..._messages.map(_buildMessage),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: widget.onJoin,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      icon: const Icon(Icons.forum_outlined),
                      label: const Text('Join the conversation'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildExpandedContent(ColorScheme colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'See what students are talking about right now.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 14),
          Expanded(
            child: _loading && _messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _failed && _messages.isEmpty
                ? Center(
                    child: TextButton.icon(
                      onPressed: _loadLatest,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Could not load chat. Tap to retry.'),
                    ),
                  )
                : _messages.isEmpty
                ? Center(
                    child: Text(
                      'It is quiet for now. Be the first to say hello.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(top: 4),
                    itemCount: _messages.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 18,
                      color: colors.outlineVariant.withValues(alpha: 0.45),
                    ),
                    itemBuilder: (context, index) =>
                        _buildMessage(_messages[index]),
                  ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: widget.onJoin,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
            ),
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Join the conversation'),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(_PreviewMessage message) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: colors.secondaryContainer,
            foregroundColor: colors.onSecondaryContainer,
            child: const Icon(Icons.person_outline, size: 16),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        message.authorUsername,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _timeLabel(message.createdAt),
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  message.content,
                  maxLines: widget.expanded ? 3 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _timeLabel(DateTime date) {
    final minutes = DateTime.now().difference(date.toLocal()).inMinutes;
    if (minutes < 1) return 'now';
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h';
    return '${date.toLocal().day}/${date.toLocal().month}';
  }
}

class _PreviewMessage {
  const _PreviewMessage({
    required this.authorUsername,
    required this.content,
    required this.createdAt,
  });

  factory _PreviewMessage.fromMap(Map<String, dynamic> map) {
    return _PreviewMessage(
      authorUsername: (map['author_username'] as String?) ?? 'Anonymous',
      content: map['content'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  final String authorUsername;
  final String content;
  final DateTime createdAt;
}
