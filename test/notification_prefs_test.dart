import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/notification_prefs.dart';
import 'package:whisper_campus/services/notification_prefs_controller.dart';

class _FakeSource implements NotificationPrefsSource {
  NotificationPrefs stored = const NotificationPrefs();
  Object? failWith;
  final saves = <(NotificationPrefs, NotificationPrefs)>[];

  @override
  Future<NotificationPrefs> fetch() async {
    final error = failWith;
    if (error != null) throw error;
    return stored;
  }

  @override
  Future<void> save(NotificationPrefs prefs, NotificationPrefs previous) async {
    final error = failWith;
    if (error != null) throw error;
    saves.add((prefs, previous));
    stored = prefs;
  }
}

void main() {
  group('NotificationPrefs', () {
    test('everything is on by default', () {
      const prefs = NotificationPrefs();

      expect(prefs.likes && prefs.comments && prefs.chatReplies, isTrue);
      expect(prefs.events && prefs.announcements, isTrue);
    });

    test('fromMap reads the server row and defaults missing keys to on', () {
      final prefs = NotificationPrefs.fromMap({'likes': false, 'events': false});

      expect(prefs.likes, isFalse);
      expect(prefs.events, isFalse);
      expect(prefs.comments, isTrue);
      expect(prefs.chatReplies, isTrue);
    });

    test('equality compares every switch', () {
      expect(const NotificationPrefs(), const NotificationPrefs());
      expect(
        const NotificationPrefs().copyWith(likes: false),
        isNot(const NotificationPrefs()),
      );
    });
  });

  group('NotificationPrefsController', () {
    late _FakeSource source;
    late NotificationPrefsController controller;

    setUp(() {
      source = _FakeSource();
      controller = NotificationPrefsController(source: source);
      addTearDown(controller.dispose);
    });

    test('load reads the saved choices', () async {
      source.stored = const NotificationPrefs(comments: false);

      final message = await controller.load();

      expect(message, isNull);
      expect(controller.loaded, isTrue);
      expect(controller.prefs.comments, isFalse);
    });

    test('a failed load returns a friendly message and stays unloaded', () async {
      source.failWith = StateError('offline');

      final message = await controller.load();

      expect(message, 'Something went wrong. Please try again.');
      expect(controller.loaded, isFalse);
    });

    test('changing a switch applies at once and saves only the change', () async {
      final message = await controller.update((p) => p.copyWith(likes: false));

      expect(message, isNull);
      expect(controller.prefs.likes, isFalse);
      expect(source.saves.single.$1.likes, isFalse);
      expect(source.saves.single.$2.likes, isTrue);
    });

    test('setting a switch to its current value does nothing', () async {
      await controller.update((p) => p.copyWith(likes: true));

      expect(source.saves, isEmpty);
    });

    test('a refused save is undone and explained', () async {
      source.failWith = StateError('boom');

      final message = await controller.update((p) => p.copyWith(events: false));

      expect(controller.prefs.events, isTrue);
      expect(message, isNotNull);
    });
  });
}
