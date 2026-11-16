import 'package:flutter/material.dart';

import '../../core/widgets/room_activity_widgets.dart';
import '../../models/campus_department.dart';
import '../../models/notification_prefs.dart';
import '../../models/room_activity.dart';
import '../../services/notification_prefs_controller.dart';
import '../../services/room_activity_controller.dart';

/// Choose which notifications to receive and manage muted rooms.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({
    super.key,
    required this.prefs,
    required this.rooms,
    this.extraSections = const [],
  });

  final NotificationPrefsController prefs;
  final RoomActivityController rooms;

  /// Extra blocks shown above the switches (for example the push toggle).
  final List<Widget> extraSections;

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
    widget.rooms.refresh();
  }

  Future<void> _load() async {
    final message = await widget.prefs.load();
    if (mounted) setState(() => _loadError = message);
  }

  Future<void> _change(
    NotificationPrefs Function(NotificationPrefs) change,
  ) async {
    final message = await widget.prefs.update(change);
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _unmute(String roomId) async {
    final message = await widget.rooms.unmute(roomId);
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Notification settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.prefs, widget.rooms]),
        builder: (context, _) {
          final prefs = widget.prefs.prefs;
          final muted = widget.rooms.mutedRoomIds;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_loadError != null)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.error_outline),
                    title: Text(_loadError!),
                    subtitle: const Text('Your saved choices could not be loaded.'),
                    trailing: TextButton(
                      onPressed: _load,
                      child: const Text('Retry'),
                    ),
                  ),
                ),
              ...widget.extraSections,
              const RoomSectionLabel('Activity'),
              _SwitchCard(
                icon: Icons.favorite_border_rounded,
                title: 'Likes',
                subtitle: 'When someone likes your post',
                value: prefs.likes,
                onChanged: (v) => _change((p) => p.copyWith(likes: v)),
              ),
              _SwitchCard(
                icon: Icons.mode_comment_outlined,
                title: 'Comments',
                subtitle: 'When someone comments on your post',
                value: prefs.comments,
                onChanged: (v) => _change((p) => p.copyWith(comments: v)),
              ),
              _SwitchCard(
                icon: Icons.reply_rounded,
                title: 'Chat replies',
                subtitle: 'When someone replies to your message in a room',
                value: prefs.chatReplies,
                onChanged: (v) => _change((p) => p.copyWith(chatReplies: v)),
              ),
              const RoomSectionLabel('Campus'),
              _SwitchCard(
                icon: Icons.event_outlined,
                title: 'Events',
                subtitle: 'New events and reminders',
                value: prefs.events,
                onChanged: (v) => _change((p) => p.copyWith(events: v)),
              ),
              _SwitchCard(
                icon: Icons.campaign_outlined,
                title: 'Announcements',
                subtitle: 'Important notices from faculty and moderators',
                value: prefs.announcements,
                onChanged: (v) => _change((p) => p.copyWith(announcements: v)),
              ),
              const RoomSectionLabel('Muted rooms'),
              if (muted.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(
                    'No muted rooms. Mute a room from its chat to stop its '
                    'notifications.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                )
              else
                for (final roomId in muted)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.notifications_off_outlined),
                      title: Text(
                        roomDisplayName(roomId),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        muteStatusLabel(widget.rooms.muteInfo(roomId)),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: TextButton(
                        onPressed: () => _unmute(roomId),
                        child: const Text('Unmute'),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}
