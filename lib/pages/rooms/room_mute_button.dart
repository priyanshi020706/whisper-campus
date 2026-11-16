import 'package:flutter/material.dart';

import '../../models/room_activity.dart';
import '../../services/room_activity_controller.dart';

/// The bell in a room's header. Tap it to mute the room for 1 hour, 8 hours or
/// until you unmute, or to unmute it. While muted it shows until when.
class RoomMuteButton extends StatelessWidget {
  const RoomMuteButton({
    super.key,
    required this.controller,
    required this.roomId,
  });

  final RoomActivityController controller;
  final String roomId;

  static const _unmute = 'unmute';

  Future<void> _choose(BuildContext context, String value) async {
    final messenger = ScaffoldMessenger.of(context);
    final String? problem;
    final String done;
    if (value == _unmute) {
      problem = await controller.unmute(roomId);
      done = 'Notifications are back on for this room.';
    } else {
      final length = MuteLength.values.firstWhere((l) => l.name == value);
      problem = await controller.mute(roomId, duration: length.duration);
      done = switch (length) {
        MuteLength.hour => 'Room muted for 1 hour.',
        MuteLength.eightHours => 'Room muted for 8 hours.',
        MuteLength.untilUnmuted => 'Room muted until you unmute it.',
      };
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(problem ?? done)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final info = controller.muteInfo(roomId);
        final muted = controller.isMuted(roomId);
        final status = muteStatusLabel(info);
        final theme = Theme.of(context);

        PopupMenuItem<String> option(MuteLength length) =>
            PopupMenuItem<String>(
              value: length.name,
              child: Text(
                muted
                    ? (length == MuteLength.untilUnmuted
                          ? 'Change to: until I unmute'
                          : 'Change to: ${length.label}')
                    : (length == MuteLength.untilUnmuted
                          ? 'Mute until I unmute'
                          : 'Mute for ${length.label}'),
              ),
            );

        return PopupMenuButton<String>(
          tooltip: muted ? 'Notifications muted' : 'Mute notifications',
          icon: Icon(
            muted
                ? Icons.notifications_off_rounded
                : Icons.notifications_none_rounded,
          ),
          onSelected: (value) => _choose(context, value),
          itemBuilder: (_) => [
            if (muted) ...[
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  status,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const PopupMenuItem<String>(
                value: _unmute,
                child: Text('Unmute notifications'),
              ),
              const PopupMenuDivider(),
            ],
            for (final length in MuteLength.values) option(length),
          ],
        );
      },
    );
  }
}
