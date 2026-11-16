import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/services/live_signals.dart';

void main() {
  test('Debouncer runs only the latest action after a burst', () async {
    final debouncer = Debouncer(const Duration(milliseconds: 30));
    final calls = <int>[];

    debouncer.run(() => calls.add(1));
    debouncer.run(() => calls.add(2));
    debouncer.run(() => calls.add(3));
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(calls, [3]);
    debouncer.dispose();
  });

  test('Debouncer does not run after dispose', () async {
    final debouncer = Debouncer(const Duration(milliseconds: 30));
    var ran = false;

    debouncer.run(() => ran = true);
    debouncer.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(ran, isFalse);
  });
}
