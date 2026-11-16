import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/core/theme/app_theme.dart';

/// Sizes a widget test like a small phone with enlarged text, the situation
/// where layouts overflow first.
class Screen {
  const Screen(this.name, this.size, this.textScale);

  final String name;
  final Size size;
  final double textScale;
}

const smallScreens = [
  Screen('320 wide, normal text', Size(320, 640), 1.0),
  Screen('320 wide, large text', Size(320, 640), 1.6),
  Screen('360 wide, huge text', Size(360, 740), 2.0),
];

/// Wraps [child] in the app theme with a given text scale and a MaterialApp.
Widget themedApp(
  Widget child, {
  double textScale = 1.0,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? AppTheme.light,
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(textScale),
      ),
      child: app!,
    ),
    home: child,
  );
}

void useScreen(WidgetTester tester, Screen screen) {
  tester.view.physicalSize = screen.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Fails the test if Flutter reported a layout overflow or other error.
void expectNoLayoutErrors(WidgetTester tester) {
  final exception = tester.takeException();
  expect(exception, isNull, reason: 'a layout error was reported: $exception');
}
