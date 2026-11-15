import 'package:flutter/material.dart';

class CampusLiveAction extends StatefulWidget {
  const CampusLiveAction({
    super.key,
    required this.active,
    required this.onPressed,
    this.compact = false,
  });

  final bool active;
  final VoidCallback onPressed;
  final bool compact;

  @override
  State<CampusLiveAction> createState() => _CampusLiveActionState();
}

class _CampusLiveActionState extends State<CampusLiveAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: widget.active ? 'Close Campus Live' : 'Campus Live',
      onPressed: widget.onPressed,
      color: widget.active ? colorScheme.primary : null,
      style: widget.compact
          ? IconButton.styleFrom(
              minimumSize: const Size(40, 40),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.sensors_rounded),
          Positioned(
            right: -2,
            top: -2,
            child: FadeTransition(
              opacity: Tween<double>(begin: .35, end: 1).animate(_pulse),
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: const Color(0xFF35D07F),
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.surface, width: 1.5),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
