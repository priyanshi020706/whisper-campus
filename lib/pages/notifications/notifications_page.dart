import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  final _supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _supabase.rpc(
        'get_my_notifications',
        params: {'p_limit': 100},
      );
      if (!mounted) return;
      setState(() {
        _items = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load notifications: $error';
        _loading = false;
      });
    }
  }

  Future<void> _markRead(Map<String, dynamic> item) async {
    if (item['read_at'] != null) return;
    try {
      await _supabase.rpc(
        'mark_my_notifications_read',
        params: {'p_notification_id': item['notification_id']},
      );
      if (!mounted) return;
      setState(() {
        item['read_at'] = DateTime.now().toIso8601String();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not mark notification as read: $error'),
          ),
        );
      }
    }
  }

  Future<void> _markAllRead() async {
    try {
      await _supabase.rpc('mark_my_notifications_read');
      if (!mounted) return;
      final now = DateTime.now().toIso8601String();
      setState(() {
        for (final item in _items) {
          item['read_at'] ??= now;
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not mark notifications as read: $error'),
          ),
        );
      }
    }
  }

  String _timeLabel(Object? value) {
    if (value is! String) return '';
    final time = DateTime.tryParse(value)?.toLocal();
    if (time == null) return '';
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return 'now';
    if (difference.inHours < 1) return '${difference.inMinutes}m';
    if (difference.inDays < 1) return '${difference.inHours}h';
    if (difference.inDays < 7) return '${difference.inDays}d';
    return '${time.day}/${time.month}/${time.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          TextButton(
            onPressed: _markAllRead,
            child: const Text('Mark all read'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _load,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            )
          : _items.isEmpty
          ? const Center(child: Text('You’re all caught up.'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _items.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, indent: 72),
                itemBuilder: (context, index) {
                  final item = _items[index];
                  final official = item['campus_mode'] == 'official';
                  final liked = item['activity_type'] == 'like';
                  final unread = item['read_at'] == null;
                  final actor = item['actor_name']?.toString() ?? 'Someone';
                  final preview = item['preview']?.toString() ?? '';
                  return ListTile(
                    onTap: () => _markRead(item),
                    tileColor: unread
                        ? colors.primary.withValues(alpha: .06)
                        : null,
                    leading: CircleAvatar(
                      backgroundColor: official
                          ? colors.primaryContainer
                          : colors.secondaryContainer,
                      child: Icon(
                        liked
                            ? Icons.favorite_rounded
                            : Icons.mode_comment_rounded,
                        color: liked ? colors.error : colors.primary,
                        size: 19,
                      ),
                    ),
                    title: Text(
                      liked
                          ? '$actor liked your post'
                          : '$actor commented on your post',
                      style: TextStyle(
                        fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    subtitle: preview.isEmpty
                        ? Text(official ? 'Official' : 'Unofficial')
                        : Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: Text(_timeLabel(item['created_at'])),
                  );
                },
              ),
            ),
    );
  }
}
