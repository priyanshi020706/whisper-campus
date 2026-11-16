import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/core/widgets/keyboard_helpers.dart';

/// A chat-like screen: a list of 40 rows above a text box, resized by the
/// keyboard exactly like a Scaffold body.
class _Chat extends StatefulWidget {
  const _Chat({required this.controller, this.onController});

  final ScrollController controller;
  final void Function(KeyboardStickyScroll sticky)? onController;

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  late final KeyboardStickyScroll sticky;

  @override
  void initState() {
    super.initState();
    sticky = KeyboardStickyScroll(widget.controller)..attach();
    widget.onController?.call(sticky);
  }

  @override
  void dispose() {
    sticky.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: widget.controller,
              itemCount: 40,
              itemBuilder: (_, i) => SizedBox(height: 50, child: Text('row $i')),
            ),
          ),
          const TextField(),
        ],
      ),
    );
  }
}

void main() {
  Future<void> openKeyboard(WidgetTester tester, double height) async {
    tester.view.viewInsets = FakeViewPadding(bottom: height);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  group('KeyboardStickyScroll', () {
    testWidgets('keeps the last row visible when the keyboard opens', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: _Chat(controller: controller)));
      controller.jumpTo(controller.position.maxScrollExtent); // reading the end
      await tester.pump();

      await openKeyboard(tester, 300);

      expect(
        controller.position.maxScrollExtent - controller.position.pixels,
        lessThan(1),
        reason: 'the newest message must not be hidden behind the keyboard',
      );
    });

    testWidgets('without the helper the bottom would be hidden (control)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      late KeyboardStickyScroll sticky;
      await tester.pumpWidget(
        MaterialApp(
          home: _Chat(controller: controller, onController: (s) => sticky = s),
        ),
      );
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      sticky.dispose(); // turn the helper off

      await openKeyboard(tester, 300);

      expect(
        controller.position.maxScrollExtent - controller.position.pixels,
        greaterThan(100),
      );
    });

    testWidgets('does not move a list the reader scrolled up', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: _Chat(controller: controller)));
      controller.jumpTo(400); // reading older messages, far from the bottom
      await tester.pump();

      await openKeyboard(tester, 300);

      expect(controller.position.pixels, 400);
    });

    testWidgets('follows the bottom again when the keyboard closes', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: _Chat(controller: controller)));
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await openKeyboard(tester, 300);

      await openKeyboard(tester, 0);

      expect(
        controller.position.maxScrollExtent - controller.position.pixels,
        lessThan(1),
      );
    });
  });

  group('SendOnEnter', () {
    Future<TextEditingController> pumpField(
      WidgetTester tester,
      void Function() onSend,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SendOnEnter(
              controller: controller,
              onSend: onSend,
              child: TextField(controller: controller, maxLines: 4),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      return controller;
    }

    testWidgets('Enter sends', (tester) async {
      var sent = 0;
      await pumpField(tester, () => sent++);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(sent, 1);
    });

    testWidgets('numpad Enter sends', (tester) async {
      var sent = 0;
      await pumpField(tester, () => sent++);

      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);

      expect(sent, 1);
    });

    testWidgets('Shift+Enter does not send (it adds a line)', (tester) async {
      var sent = 0;
      await pumpField(tester, () => sent++);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(sent, 0);
    });

    testWidgets('other keys do not send', (tester) async {
      var sent = 0;
      await pumpField(tester, () => sent++);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);

      expect(sent, 0);
    });

    testWidgets('Enter that confirms an input-method composition is ignored', (
      tester,
    ) async {
      var sent = 0;
      final controller = await pumpField(tester, () => sent++);
      controller.value = const TextEditingValue(
        text: 'नमस',
        composing: TextRange(start: 0, end: 3),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(sent, 0);
    });
  });
}
