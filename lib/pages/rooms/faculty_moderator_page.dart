import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/utils/error_message.dart';

class FacultyModeratorPage extends StatefulWidget {
  const FacultyModeratorPage({super.key, this.initialMode = 'official'});

  final String initialMode;

  @override
  State<FacultyModeratorPage> createState() => _FacultyModeratorPageState();
}

class _FacultyModeratorPageState extends State<FacultyModeratorPage> {
  final _db = Supabase.instance.client;
  final _query = TextEditingController();
  Timer? _searchTimer;
  int _searchRequestId = 0;
  List<Map<String, dynamic>> _rooms = [];
  List<Map<String, dynamic>> _students = [];
  List<Map<String, dynamic>> _moderators = [];
  String? _roomId;
  String? _branch;
  late String _mode = widget.initialMode;
  bool _isSuperAdmin = false;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  static const _branches = [
    'AD',
    'AI',
    'AM',
    'CB',
    'CD',
    'CE',
    'CM',
    'CS',
    'EC',
    'EE',
    'EL',
    'ET',
    'IO',
    'IR',
    'IT',
    'MC',
    'ME',
    'TC',
    'AR',
  ];

  @override
  void initState() {
    super.initState();
    _loadRoleAndRooms();
  }

  Future<void> _loadRoleAndRooms() async {
    try {
      final id = _db.auth.currentUser?.id;
      final profile = id == null
          ? null
          : await _db
                .from('profiles')
                .select('role')
                .eq('id', id)
                .maybeSingle();
      _isSuperAdmin = profile?['role'] == 'super_admin';
    } catch (_) {
      _isSuperAdmin = false;
    }
    _loadRooms();
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadRooms() async {
    try {
      final rows = await _db.rpc(
        'list_moderation_rooms',
        params: {'p_mode': _mode},
      );
      final officialRooms = List<Map<String, dynamic>>.from(rows)
          .map((room) => {'id': room['room_id'], 'name': room['room_name']})
          .toList();
      if (!mounted) return;
      setState(() {
        _rooms = officialRooms;
        _roomId = _rooms.isEmpty ? null : _rooms.first['id'] as String;
        _loading = false;
      });
      await _loadModerators();
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load rooms: ${friendlyError(e)}';
        });
      }
    }
  }

  Future<void> _loadModerators() async {
    if (_roomId == null) return;
    try {
      final rows = await _db.rpc(
        'list_room_moderators',
        params: {'p_room_id': _roomId, 'p_mode': _mode},
      );
      if (mounted) {
        setState(() => _moderators = List<Map<String, dynamic>>.from(rows));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not load moderators: ${friendlyError(e)}');
      }
    }
  }

  void _scheduleSearch() {
    _searchTimer?.cancel();
    final query = _query.text.trim();
    final requestId = ++_searchRequestId;
    if (query.isEmpty) {
      setState(() {
        _students = [];
        _error = null;
        _busy = false;
      });
      return;
    }
    _searchTimer = Timer(const Duration(milliseconds: 280), () {
      _search(query, requestId);
    });
  }

  Future<void> _search([String? value, int? requestId]) async {
    final query = (value ?? _query.text).trim();
    if (query.isEmpty) {
      setState(() => _students = []);
      return;
    }
    final currentRequest = requestId ?? ++_searchRequestId;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final rows = await _db.rpc(
        'search_students',
        params: {'p_query': query, 'p_branch_code': _branch, 'p_mode': _mode},
      );
      if (mounted && currentRequest == _searchRequestId) {
        setState(() {
          _students = List<Map<String, dynamic>>.from(rows);
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted && currentRequest == _searchRequestId) {
        setState(() {
          _busy = false;
          _error = 'Search failed: ${friendlyError(e)}';
        });
      }
    }
  }

  String _year(Object? value) {
    final n = (value as num?)?.toInt();
    if (n == null) return 'Year unavailable';
    if (n > 4) return 'Alumni';
    if (n == 1) return '1st';
    if (n == 2) return '2nd';
    if (n == 3) return '3rd';
    return '4th';
  }

  Future<void> _assign(Map<String, dynamic> student) async {
    DateTime? expires;
    final yes = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Confirm moderator assignment',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '${student['student_name']} · ${student['branch_code']} · ${_year(student['study_year'])}',
                ),
                Text(
                  'Enrollment: ${student['enrollment_number']?.toString() ??
                          'Unavailable'} · Roll: ${student['roll_number']?.toString() ?? 'Unavailable'}',
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                      initialDate: DateTime.now().add(const Duration(days: 30)),
                    );
                    if (date != null) {
                      setSheet(
                        () => expires = DateTime(
                          date.year,
                          date.month,
                          date.day,
                        ).add(const Duration(days: 1)),
                      );
                    }
                  },
                  child: Text(
                    expires == null
                        ? 'No expiry (default)'
                        : 'Expires ${expires!
                                  .subtract(const Duration(days: 1))
                                  .toLocal()
                                  .toString()
                                  .split(' ')
                                  .first}',
                  ),
                ),
                if (expires != null)
                  TextButton(
                    onPressed: () => setSheet(() => expires = null),
                    child: const Text('Clear expiry'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.pop(sheet, true),
                  child: const Text('Make Moderator'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (yes != true || _roomId == null) return;
    try {
      await _db.rpc(
        'assign_room_moderator',
        params: {
          'p_room_id': _roomId,
          'p_student_id': student['student_id'],
          'p_ends_at': expires?.toUtc().toIso8601String(),
          'p_mode': _mode,
        },
      );
      await _loadModerators();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Assignment failed: ${friendlyError(e)}')),
        );
      }
    }
  }

  Future<void> _remove(Map<String, dynamic> row) async {
    try {
      await _db.rpc(
        'remove_room_moderator',
        params: {
          'p_room_id': _roomId,
          'p_student_id': row['student_id'],
          'p_mode': _mode,
        },
      );
      await _loadModerators();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removal failed: ${friendlyError(e)}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Room moderators')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_isSuperAdmin) ...[
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(
                labelText: 'Campus side',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'official', child: Text('Official')),
                DropdownMenuItem(
                  value: 'unofficial',
                  child: Text('Unofficial'),
                ),
              ],
              onChanged: (value) {
                if (value == null) return;
                _searchTimer?.cancel();
                _searchRequestId++;
                _query.clear();
                setState(() {
                  _mode = value;
                  _roomId = null;
                  _branch = null;
                  _rooms = [];
                  _students = [];
                  _moderators = [];
                  _loading = true;
                });
                _loadRooms();
              },
            ),
            const SizedBox(height: 14),
          ],
          DropdownButtonFormField<String>(
            initialValue: _roomId,
            decoration: const InputDecoration(
              labelText: 'Room',
              border: OutlineInputBorder(),
            ),
            items: _rooms
                .map(
                  (r) => DropdownMenuItem(
                    value: r['id'] as String,
                    child: Text(r['name'] as String),
                  ),
                )
                .toList(),
            onChanged: (v) {
              setState(() {
                _roomId = v;
                _students = [];
              });
              _loadModerators();
            },
          ),
          const SizedBox(height: 18),
          DropdownButtonFormField<String?>(
            initialValue: _branch,
            decoration: const InputDecoration(
              labelText: 'Branch (optional)',
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All branches'),
              ),
              ..._branches.map(
                (b) => DropdownMenuItem<String?>(value: b, child: Text(b)),
              ),
            ],
            onChanged: (v) {
              setState(() => _branch = v);
              if (_query.text.trim().isNotEmpty) _scheduleSearch();
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _query,
                  onChanged: (_) => _scheduleSearch(),
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    labelText: 'Name, enrollment or roll number',
                    hintText: 'Enrollment prefix appears as you type',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              IconButton.filled(
                onPressed: _busy ? null : _search,
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          for (final s in _students)
            ListTile(
              title: Text(
                '${s['student_name']} · ${s['branch_code']} · ${_year(s['study_year'])}',
              ),
              subtitle: Text(
                'Enrollment: ${s['enrollment_number']?.toString() ?? 'Unavailable'} · Roll: ${s['roll_number']?.toString() ?? 'Unavailable'}',
              ),
              trailing: const Icon(Icons.add_moderator_outlined),
              onTap: () => _assign(s),
            ),
          const Divider(height: 32),
          Text(
            'Current moderators',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_moderators.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text('No active moderators for this room.'),
            ),
          for (final m in _moderators)
            ListTile(
              title: Text(
                '${m['student_name']} · ${m['branch_code']} · ${_year(m['study_year'])}',
              ),
              subtitle: Text(
                'Enrollment: ${m['enrollment_number']?.toString() ?? 'Unavailable'} · Roll: ${m['roll_number']?.toString() ?? 'Unavailable'}',
              ),
              trailing: TextButton(
                onPressed: () => _remove(m),
                child: const Text('Remove'),
              ),
            ),
        ],
      ),
    );
  }
}
