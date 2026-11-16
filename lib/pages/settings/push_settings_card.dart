import 'package:flutter/material.dart';

import '../../services/push/push_controller.dart';

/// The "Push notifications on this device" switch for the settings page.
class PushSettingsCard extends StatelessWidget {
  const PushSettingsCard({super.key, required this.controller});

  final PushController controller;

  Future<void> _toggle(BuildContext context, bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    final message = on ? await controller.enable() : await controller.disable();
    if (message != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final status = controller.status;
        final canSwitch =
            !controller.busy &&
            (status == PushStatus.on || status == PushStatus.off);

        final String subtitle = switch (status) {
          PushStatus.loading => 'Checking…',
          PushStatus.unsupported =>
            'This browser cannot show push notifications. On iPhone, add '
                'Whisper Campus to your Home Screen first, then open it from there.',
          PushStatus.notConfigured => 'Push notifications are not set up yet.',
          PushStatus.blocked =>
            'Notifications are blocked for this site. Allow them in your '
                'browser settings, then come back here.',
          PushStatus.off =>
            'Get likes, comments, replies, events and announcements even '
                'when the app is closed.',
          PushStatus.on => 'On. This device will get your notifications.',
        };

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    status == PushStatus.on
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    color: status == PushStatus.on
                        ? theme.colorScheme.primary
                        : null,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Push notifications on this device',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                controller.busy
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : Switch(
                        value: status == PushStatus.on,
                        onChanged: canSwitch
                            ? (value) => _toggle(context, value)
                            : null,
                      ),
              ],
            ),
          ),
        );
      },
    );
  }
}
