import 'package:flutter/material.dart';

/// Round count of unread messages. Shows "99+" above ninety-nine.
class RoomUnreadBadge extends StatelessWidget {
  const RoomUnreadBadge({super.key, required this.count, this.muted = false});

  final int count;

  /// Muted rooms still count unread messages but look quiet (grey).
  final bool muted;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: muted ? colors.outline : colors.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        child: Text(
          count > 99 ? '99+' : '$count',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: muted ? colors.surface : colors.onPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

/// Pin / unpin toggle. Disabled looking when three rooms are already pinned and
/// this one is not (the tap then explains the limit).
class RoomPinButton extends StatelessWidget {
  const RoomPinButton({
    super.key,
    required this.pinned,
    required this.onPressed,
    this.size = 20,
  });

  final bool pinned;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: pinned ? 'Unpin room' : 'Pin room',
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: size,
      icon: Icon(
        pinned ? Icons.push_pin : Icons.push_pin_outlined,
        color: pinned ? colors.primary : colors.onSurfaceVariant,
      ),
    );
  }
}

/// Small heading above a group of rooms ("Pinned", "Recent chats", ...).
class RoomSectionLabel extends StatelessWidget {
  const RoomSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: colors.onSurfaceVariant,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// Small crossed-bell shown next to a muted room.
class RoomMutedIcon extends StatelessWidget {
  const RoomMutedIcon({super.key, this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: 'Muted',
    child: Icon(
      Icons.notifications_off_outlined,
      size: size,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
