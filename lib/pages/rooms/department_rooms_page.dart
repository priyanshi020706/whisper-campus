import 'package:flutter/material.dart';

import '../../core/widgets/campus_live_action.dart';
import '../../core/widgets/room_activity_widgets.dart';
import '../../models/campus_department.dart';
import '../../models/room_activity.dart';
import '../../services/room_activity_controller.dart';

/// The unofficial department rooms. Rooms you pinned come first (up to three),
/// then rooms with the most recent chat message, then the rest in their usual
/// order.
class DepartmentRoomsPage extends StatefulWidget {
  const DepartmentRoomsPage({
    super.key,
    this.onNavigateHome,
    this.onOpenLiveChat,
    this.activity,
  });

  final VoidCallback? onNavigateHome;
  final VoidCallback? onOpenLiveChat;

  /// Shared recent-chat state. When null the page loads its own.
  final RoomActivityController? activity;

  @override
  State<DepartmentRoomsPage> createState() => _DepartmentRoomsPageState();
}

class _DepartmentRoomsPageState extends State<DepartmentRoomsPage> {
  late final RoomActivityController _activity;
  late final bool _ownsActivity;

  @override
  void initState() {
    super.initState();
    _ownsActivity = widget.activity == null;
    _activity = widget.activity ?? RoomActivityController();
    if (_ownsActivity) {
      _activity.start();
    } else {
      _activity.refresh();
    }
  }

  @override
  void dispose() {
    if (_ownsActivity) _activity.dispose();
    super.dispose();
  }

  Future<void> _togglePin(String roomId) async {
    final message = await _activity.togglePin(roomId);
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Department rooms'),
        actions: [
          IconButton(
            tooltip: 'Back to home',
            onPressed: widget.onNavigateHome,
            icon: const Icon(Icons.home_outlined),
          ),
          CampusLiveAction(
            active: false,
            onPressed: () => widget.onOpenLiveChat?.call(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _activity,
        builder: (context, _) {
          final ordered = _activity.order(
            campusDepartments,
            (department) => department.roomId,
          );
          bool isPinned(CampusDepartment d) => _activity.isPinned(d.roomId);
          bool isRecent(CampusDepartment d) =>
              !isPinned(d) && _activity.of(d.roomId)?.lastMessageAt != null;
          final pinned = ordered.where(isPinned).toList();
          final recent = ordered.where(isRecent).toList();
          final others = ordered
              .where((d) => !isPinned(d) && !isRecent(d))
              .toList();

          Widget section(String label, List<CampusDepartment> items) {
            if (items.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RoomSectionLabel(label),
                for (final department in items) ...[
                  _DepartmentTile(
                    department: department,
                    activity: _activity.of(department.roomId),
                    onTap: () =>
                        Navigator.of(context).pop(department.roomId),
                    onTogglePin: () => _togglePin(department.roomId),
                  ),
                  const SizedBox(height: 8),
                ],
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              Text(
                'Find your branch community',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Join the conversation anonymously with students in your department. '
                'Pin up to $maxPinnedRooms rooms to keep them on top.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              section('Pinned', pinned),
              section('Recent chats', recent),
              section(
                pinned.isEmpty && recent.isEmpty ? 'All departments' : 'Other departments',
                others,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DepartmentTile extends StatelessWidget {
  const _DepartmentTile({
    required this.department,
    required this.activity,
    required this.onTap,
    required this.onTogglePin,
  });

  final CampusDepartment department;
  final RoomActivity? activity;
  final VoidCallback onTap;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final line = roomActivityLine(activity);
    final unread = activity?.unreadCount ?? 0;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        minVerticalPadding: 10,
        leading: CircleAvatar(
          backgroundColor: colors.primaryContainer,
          foregroundColor: colors.onPrimaryContainer,
          child: const Icon(Icons.school_outlined),
        ),
        title: Text(
          department.name,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          line == null
              ? department.code.toUpperCase()
              : '${department.code.toUpperCase()} · $line',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (activity?.isMutedAt() ?? false)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: RoomMutedIcon(),
              ),
            RoomUnreadBadge(count: unread, muted: activity?.isMutedAt() ?? false),
            RoomPinButton(
              pinned: activity?.pinned ?? false,
              onPressed: onTogglePin,
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
