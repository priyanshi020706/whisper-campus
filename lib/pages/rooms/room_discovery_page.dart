import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class RoomDiscoveryPage extends StatefulWidget {
  const RoomDiscoveryPage({super.key, this.selectedRoomId});

  final String? selectedRoomId;

  @override
  State<RoomDiscoveryPage> createState() => _RoomDiscoveryPageState();
}

class _RoomDiscoveryPageState extends State<RoomDiscoveryPage> {
  final _supabase = Supabase.instance.client;
  List<_Room> _rooms = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRooms();
  }

  Future<void> _loadRooms() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _supabase
          .from('rooms')
          .select('id, name')
          .order('name');
      final loadedRooms = List<Map<String, dynamic>>.from(rows)
          .map(
            (row) =>
                _Room(id: row['id'] as String, name: row['name'] as String),
          )
          .toList();
      final hasDepartmentRooms = loadedRooms.any(
        (room) => room.id.startsWith('dept-'),
      );
      final availableById = {
        for (final room in loadedRooms)
          if (room.id != 'general' && !room.id.startsWith('dept-'))
            room.id: room,
        if (hasDepartmentRooms)
          'departments': const _Room(id: 'departments', name: 'Departments'),
      };
      const preferredIds = [
        'events',
        'clubs',
        'campus-life',
        'departments',
        'academics',
        'sports',
      ];
      final rooms = <_Room>[
        for (final id in preferredIds)
          if (availableById.containsKey(id)) availableById[id]!,
        for (final room in loadedRooms)
          if (room.id != 'general' &&
              !room.id.startsWith('dept-') &&
              !preferredIds.contains(room.id))
            room,
      ];
      if (!mounted) return;
      setState(() {
        _rooms = rooms;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load rooms. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explore the rooms'),
        actions: [
          IconButton(
            tooltip: 'Back to home',
            onPressed: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
            icon: const Icon(Icons.home_outlined),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _loadRooms,
                    child: const Text('Try again'),
                  ),
                ],
              ),
            )
          : _rooms.isEmpty
          ? const Center(child: Text('No rooms are available yet.'))
          : LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width < 900 ? 2 : 3;
                final cardRatio = width < 560
                    ? 1.02
                    : width < 900
                    ? 1.72
                    : 2.18;
                final horizontalPadding = width >= 1240
                    ? (width - 1160) / 2
                    : 20.0;
                return CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          12,
                          horizontalPadding,
                          20,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Explore the rooms ✨',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall
                                        ?.copyWith(fontWeight: FontWeight.w800),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Find your people. Pick a room to join.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: colors.onSurfaceVariant,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: colors.outlineVariant,
                                ),
                              ),
                              child: Text(
                                '${_rooms.length} rooms',
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        0,
                        horizontalPadding,
                        28,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          mainAxisSpacing: 12,
                          crossAxisSpacing: 12,
                          childAspectRatio: cardRatio,
                        ),
                        itemCount: _rooms.length,
                        itemBuilder: (context, index) =>
                            _buildRoomCard(_rooms[index], colors),
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildRoomCard(_Room room, ColorScheme colors) {
    final accent = _accentFor(room.id, colors);
    final selected = room.id == widget.selectedRoomId;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 285;
        return Card(
          clipBehavior: Clip.antiAlias,
          color: Color.alphaBlend(
            accent.withValues(
              alpha: colors.brightness == Brightness.dark ? 0.13 : 0.09,
            ),
            colors.surface,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: accent.withValues(alpha: 0.2)),
          ),
          child: InkWell(
            onTap: () => Navigator.of(context).pop(room.id),
            child: Stack(
              children: [
                Positioned(
                  right: -25,
                  top: -34,
                  child: Container(
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.11),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  right: 68,
                  top: 14,
                  child: Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: accent.withValues(alpha: 0.58),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(compact ? 14 : 17),
                  child: compact
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                _buildArtwork(room.id, accent, size: 56),
                                const Spacer(),
                                _buildRoomAction(selected, accent),
                              ],
                            ),
                            const Spacer(),
                            _buildRoomText(room),
                          ],
                        )
                      : Row(
                          children: [
                            _buildArtwork(room.id, accent, size: 70),
                            const SizedBox(width: 14),
                            Expanded(child: _buildRoomText(room)),
                            const SizedBox(width: 10),
                            _buildRoomAction(selected, accent),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildArtwork(String id, Color accent, {required double size}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: Text(_emojiFor(id), style: TextStyle(fontSize: size * 0.53)),
    );
  }

  Widget _buildRoomText(_Room room) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          room.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 3),
        Text(
          _descriptionFor(room.id),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: colors.onSurfaceVariant, height: 1.3),
        ),
      ],
    );
  }

  Widget _buildRoomAction(bool selected, Color accent) {
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
        shape: BoxShape.circle,
      ),
      child: Icon(
        selected ? Icons.check_rounded : Icons.arrow_forward_rounded,
        size: 17,
        color: accent,
      ),
    );
  }

  Color _accentFor(String id, ColorScheme colors) {
    final dark = colors.brightness == Brightness.dark;
    return switch (id) {
      'departments' => dark ? const Color(0xFFB4A4FF) : const Color(0xFF6659C5),
      'events' => dark ? const Color(0xFFFF8394) : const Color(0xFFDD5269),
      'clubs' => dark ? const Color(0xFF9BB2FF) : const Color(0xFF4C65D9),
      'campus-life' => dark ? const Color(0xFF72D8A9) : const Color(0xFF258B68),
      'academics' => dark ? const Color(0xFFFFC978) : const Color(0xFFC78326),
      'sports' => dark ? const Color(0xFFFFA27C) : const Color(0xFFDE6845),
      _ => dark ? const Color(0xFFB4A4FF) : const Color(0xFF6659C5),
    };
  }

  String _emojiFor(String id) {
    return switch (id) {
      'departments' => '🏫',
      'events' => '🔥',
      'clubs' => '🎮',
      'campus-life' => '🌱',
      'academics' => '📚',
      'sports' => '🏆',
      _ => '💬',
    };
  }

  String _descriptionFor(String id) {
    return switch (id) {
      'departments' => 'Anonymous spaces for every branch.',
      'events' => 'Fests, workshops, and announcements.',
      'clubs' => 'Club activities and discussions.',
      'campus-life' => 'Hostel life, food, and more.',
      'academics' => 'Study, assignments, exams, and doubts.',
      'sports' => 'Teams, matches, and fitness.',
      _ => 'Open conversations about anything.',
    };
  }
}

class _Room {
  const _Room({required this.id, required this.name});

  final String id;
  final String name;
}
