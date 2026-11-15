import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'room_moderator_contact_page.dart';

class ModeratorInboxPage extends StatefulWidget {
  const ModeratorInboxPage({super.key});

  @override
  State<ModeratorInboxPage> createState() => _ModeratorInboxPageState();
}

class _ModeratorInboxPageState extends State<ModeratorInboxPage> {
  final _db = Supabase.instance.client;
  List<Map<String, dynamic>> _conversations = [];
  String? _error;
  bool _loading = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(const Duration(seconds: 15), (_) => _load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
    try {
      final rows = await _db.rpc('get_my_moderator_inbox');
      if (!mounted) return;
      setState(() { _conversations = List<Map<String, dynamic>>.from(rows); _loading = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _error = error.toString(); _loading = false; });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _time(Object? raw) {
    if (raw == null) return 'New conversation';
    final date = DateTime.tryParse(raw.toString())?.toLocal();
    if (date == null) return '';
    final today = DateTime.now();
    if (date.year == today.year && date.month == today.month && date.day == today.day) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
    return '${date.day}/${date.month}/${date.year}';
  }

  Future<void> _open(Map<String, dynamic> item) async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => RoomModeratorContactPage(
        roomId: item['room_id'].toString(),
        roomName: item['room_name'].toString(),
        mode: item['room_mode'].toString(),
        initialThreadId: item['thread_id'].toString(),
      ),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Moderator inbox'),
      actions: [IconButton(tooltip: 'Refresh', onPressed: _load, icon: const Icon(Icons.refresh_rounded))],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load your moderator inbox. $_error', textAlign: TextAlign.center)))
            : _conversations.isEmpty
                ? const Center(child: Text('No moderator messages yet.'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _conversations.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final item = _conversations[index];
                        final mode = item['room_mode'] == 'official' ? 'Official' : 'Unofficial';
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                          leading: CircleAvatar(child: Icon(item['room_mode'] == 'official' ? Icons.school_outlined : Icons.forum_outlined)),
                          title: Row(children: [
                            Expanded(child: Text(item['display_name']?.toString() ?? 'Student', maxLines: 1, overflow: TextOverflow.ellipsis)),
                            Text(_time(item['last_message_at']), style: Theme.of(context).textTheme.labelSmall),
                          ]),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${item['room_name']} · $mode', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.primary)),
                            const SizedBox(height: 3),
                            Text(item['last_message']?.toString() ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _open(item),
                        );
                      },
                    ),
                  ),
  );
}
