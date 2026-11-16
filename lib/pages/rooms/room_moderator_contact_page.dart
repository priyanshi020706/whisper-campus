import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/utils/error_message.dart';

class RoomModeratorContactPage extends StatefulWidget {
  const RoomModeratorContactPage({super.key, required this.roomId, required this.roomName, required this.mode, this.initialThreadId});

  final String roomId;
  final String roomName;
  final String mode;
  final String? initialThreadId;

  @override
  State<RoomModeratorContactPage> createState() => _RoomModeratorContactPageState();
}

class _RoomModeratorContactPageState extends State<RoomModeratorContactPage> {
  final _db = Supabase.instance.client;
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  Timer? _refreshTimer;
  List<Map<String, dynamic>> _threads = [];
  List<Map<String, dynamic>> _messages = [];
  String? _threadId;
  String? _error;
  bool _isModerator = false;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final moderator = await _db.rpc('is_active_room_moderator', params: {
        'p_room': widget.roomId,
        'p_mode': widget.mode,
      });
      final admin = await _db.rpc('is_super_admin');
      _isModerator = moderator == true || admin == true;
      if (widget.initialThreadId != null) {
        _threadId = widget.initialThreadId;
        await _loadMessages();
      } else if (_isModerator) {
        await _loadThreads();
      } else {
        final id = await _db.rpc('get_or_create_room_moderator_thread', params: {
          'p_room_id': widget.roomId,
          'p_mode': widget.mode,
        });
        _threadId = id.toString();
        await _loadMessages();
      }
      _refreshTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        if (_threadId != null) {
          _loadMessages();
        } else if (_isModerator) {
          _loadThreads();
        }
      });
      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (mounted) setState(() { _error = friendlyError(error); _loading = false; });
    }
  }

  Future<void> _loadThreads() async {
    try {
      final rows = await _db.rpc('list_room_moderator_threads', params: {
        'p_room_id': widget.roomId,
        'p_mode': widget.mode,
      });
      if (mounted) setState(() => _threads = List<Map<String, dynamic>>.from(rows));
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    }
  }

  Future<void> _openThread(Map<String, dynamic> thread) async {
    setState(() { _threadId = thread['thread_id'].toString(); _error = null; _loading = true; });
    await _loadMessages();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMessages() async {
    final id = _threadId;
    if (id == null) return;
    try {
      final rows = await _db.rpc('get_room_moderator_messages', params: {'p_thread_id': id});
      if (!mounted) return;
      setState(() => _messages = List<Map<String, dynamic>>.from(rows));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final id = _threadId;
    if (text.isEmpty || id == null || _sending) return;
    setState(() => _sending = true);
    try {
      await _db.rpc('send_room_moderator_message', params: {'p_thread_id': id, 'p_content': text});
      _controller.clear();
      await _loadMessages();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Message could not be sent: ${friendlyError(error)}')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_threadId == null ? 'Moderator inbox · ${widget.roomName}' : 'Contact moderator · ${widget.roomName}'),
      leading: _threadId != null && _isModerator && widget.initialThreadId == null
          ? IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() { _threadId = null; _messages = []; }))
          : null,
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not open moderator messages. $_error', textAlign: TextAlign.center)))
            : _threadId == null
                ? _threads.isEmpty
                    ? const Center(child: Text('No suggestions yet.'))
                    : ListView.separated(
                        itemCount: _threads.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final item = _threads[index];
                          return ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                            title: Text(item['display_name']?.toString() ?? 'Student'),
                            subtitle: Text(item['last_message']?.toString() ?? 'Open conversation'),
                            onTap: () => _openThread(item),
                          );
                        },
                      )
                : Column(children: [
                    Expanded(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          final mine = message['is_mine'] == true;
                          return Align(
                            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              constraints: const BoxConstraints(maxWidth: 520),
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: mine ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHigh,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                if (_isModerator) Text(message['display_name']?.toString() ?? 'Student', style: Theme.of(context).textTheme.labelSmall),
                                Text(message['content']?.toString() ?? ''),
                              ]),
                            ),
                          );
                        },
                      ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                        child: Row(children: [
                          Expanded(child: TextField(controller: _controller, minLines: 1, maxLines: 4, decoration: const InputDecoration(hintText: 'Write a suggestion…', border: OutlineInputBorder()))),
                          const SizedBox(width: 8),
                          IconButton.filled(onPressed: _sending ? null : _send, icon: const Icon(Icons.send_rounded)),
                        ]),
                      ),
                    ),
                  ]),
  );
}
