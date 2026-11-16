import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Keeps a chat-style list showing its newest item when the on-screen keyboard
/// opens or closes.
///
/// Without this the keyboard shrinks the list from the bottom, so the last
/// messages end up hidden behind it until the user scrolls. If the list was
/// already at (or near) the bottom, it follows the bottom while the keyboard
/// animates. A list the user has scrolled up to read is left where it is.
///
/// Usage: create it with the list's [ScrollController], call [attach] in
/// `initState` and [dispose] in `dispose`.
class KeyboardStickyScroll with WidgetsBindingObserver {
  KeyboardStickyScroll(this.controller, {this.nearBottomDistance = 120});

  final ScrollController controller;

  /// How close to the bottom (in logical pixels) still counts as "at bottom".
  final double nearBottomDistance;

  bool _stick = true;
  double _lastInset = 0;

  void attach() {
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_onScroll);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_onScroll);
  }

  /// Marks the list as "follow the bottom", e.g. after sending a message.
  void stickToBottom() => _stick = true;

  void _onScroll() {
    if (!controller.hasClients) return;
    final position = controller.position;
    _stick = position.maxScrollExtent - position.pixels < nearBottomDistance;
  }

  /// Scrolls to the newest item once the next frame has laid out.
  void jumpToBottomAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      controller.jumpTo(controller.position.maxScrollExtent);
    });
  }

  @override
  void didChangeMetrics() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final inset = view.viewInsets.bottom / view.devicePixelRatio;
    if ((inset - _lastInset).abs() < 0.5) return;
    _lastInset = inset;
    if (_stick) jumpToBottomAfterLayout();
  }
}

/// Sends on Enter when a hardware keyboard is used (web and desktop); Shift+Enter
/// still adds a new line. Phones with an on-screen keyboard are unaffected:
/// Enter there keeps adding a line and the send button sends.
///
/// Pass the text field's [controller] so Enter that confirms an input-method
/// composition (for example Hindi or Japanese typing) is not mistaken for send.
class SendOnEnter extends StatelessWidget {
  const SendOnEnter({
    super.key,
    required this.onSend,
    required this.controller,
    required this.child,
  });

  final VoidCallback onSend;
  final TextEditingController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final isEnter =
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter;
        if (!isEnter) return KeyEventResult.ignored;
        if (HardwareKeyboard.instance.isShiftPressed) {
          return KeyEventResult.ignored;
        }
        final composing = controller.value.composing;
        if (composing.isValid && !composing.isCollapsed) {
          return KeyEventResult.ignored;
        }
        onSend();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}
