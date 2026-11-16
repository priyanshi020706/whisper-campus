import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/room_activity.dart';
import 'package:whisper_campus/services/room_activity_controller.dart';
import 'package:whisper_campus/services/room_activity_service.dart';

class _FakeSource implements RoomActivitySource {
  Map<String, RoomActivity> data = {};
  Object? failPinWith;
  final calls = <String>[];

  @override
  Future<Map<String, RoomActivity>> fetch(String mode) async => data;

  @override
  Future<void> setPinned(String roomId, String mode, bool pinned) async {
    calls.add('${pinned ? 'pin' : 'unpin'}:$roomId:$mode');
    final error = failPinWith;
    if (error != null) throw error;
    final base = data[roomId] ?? RoomActivity(roomId: roomId);
    data = {...data, roomId: base.copyWith(pinned: pinned, pinnedAt: DateTime.now())};
  }

  @override
  Future<void> setMuted(String roomId, String mode, bool muted, {int? minutes}) async {
    calls.add('${muted ? 'mute' : 'unmute'}:$roomId:$mode:${minutes ?? 'forever'}');
    final error = failPinWith;
    if (error != null) throw error;
    final base = data[roomId] ?? RoomActivity(roomId: roomId);
    data = {
      ...data,
      roomId: base.copyWith(
        muted: muted,
        mutedUntil: minutes == null ? null : DateTime.now().add(Duration(minutes: minutes)),
      ),
    };
  }
}

void main() {
  late _FakeSource source;
  late RoomActivityController controller;

  setUp(() {
    source = _FakeSource();
    controller = RoomActivityController(
      source: source,
      refreshEvery: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);
  });

  test('refresh loads activity and notifies listeners', () async {
    source.data = {'a': RoomActivity(roomId: 'a', unreadCount: 2)};
    var notified = 0;
    controller.addListener(() => notified++);

    await controller.refresh();

    expect(controller.of('a')?.unreadCount, 2);
    expect(notified, 1);
  });

  test('order puts the newest chat first after a refresh', () async {
    final now = DateTime.now();
    source.data = {
      'b': RoomActivity(roomId: 'b', lastMessageAt: now.subtract(const Duration(minutes: 30))),
      'c': RoomActivity(roomId: 'c', lastMessageAt: now.subtract(const Duration(minutes: 2))),
    };
    await controller.refresh();

    expect(controller.order(['a', 'b', 'c'], (id) => id), ['c', 'b', 'a']);
  });

  test('pinning works, shows at once, and calls the server', () async {
    final message = await controller.togglePin('a');

    expect(message, isNull);
    expect(controller.isPinned('a'), isTrue);
    expect(source.calls, ['pin:a:unofficial']);
  });

  test('a fourth pin is refused without calling the server', () async {
    for (final id in ['a', 'b', 'c']) {
      await controller.togglePin(id);
    }
    source.calls.clear();

    final message = await controller.togglePin('d');

    expect(message, contains('3 rooms'));
    expect(controller.isPinned('d'), isFalse);
    expect(source.calls, isEmpty);
  });

  test('unpinning frees a slot', () async {
    for (final id in ['a', 'b', 'c']) {
      await controller.togglePin(id);
    }

    await controller.togglePin('a');
    final message = await controller.togglePin('d');

    expect(message, isNull);
    expect(controller.isPinned('d'), isTrue);
    expect(controller.isPinned('a'), isFalse);
  });

  test('if the server refuses, the change is undone and a message returned', () async {
    source.failPinWith = StateError('boom');

    final message = await controller.togglePin('a');

    expect(controller.isPinned('a'), isFalse);
    expect(message, 'Something went wrong. Please try again.');
  });

  test('muting works, shows at once, and can be undone', () async {
    expect(controller.isMuted('a'), isFalse);

    final message = await controller.mute('a');

    expect(message, isNull);
    expect(controller.isMuted('a'), isTrue);
    expect(controller.mutedRoomIds, ['a']);
    expect(source.calls, contains('mute:a:unofficial:forever'));

    await controller.unmute('a');
    expect(controller.isMuted('a'), isFalse);
    expect(controller.mutedRoomIds, isEmpty);
    expect(source.calls.last, 'unmute:a:unofficial:forever');
  });

  test('mute for 1 hour and 8 hours sends the minutes', () async {
    await controller.mute('a', duration: const Duration(hours: 1));
    await controller.mute('b', duration: const Duration(hours: 8));

    expect(source.calls, containsAll(['mute:a:unofficial:60', 'mute:b:unofficial:480']));
    final until = controller.muteInfo('a')!.mutedUntil!;
    expect(until.isAfter(DateTime.now().add(const Duration(minutes: 59))), isTrue);
    expect(until.isBefore(DateTime.now().add(const Duration(minutes: 61))), isTrue);
  });

  test('changing the mute length replaces the old one', () async {
    await controller.mute('a', duration: const Duration(hours: 1));
    await controller.mute('a'); // until unmuted

    expect(controller.muteInfo('a')!.mutedUntil, isNull);
    expect(controller.isMuted('a'), isTrue);
  });

  test('a mute that has run out no longer counts', () async {
    source.data = {
      'a': RoomActivity(
        roomId: 'a',
        muted: true,
        mutedUntil: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
      'b': RoomActivity(
        roomId: 'b',
        muted: true,
        mutedUntil: DateTime.now().add(const Duration(hours: 1)),
      ),
    };
    await controller.refresh();

    expect(controller.isMuted('a'), isFalse);
    expect(controller.isMuted('b'), isTrue);
    expect(controller.mutedRoomIds, ['b']);
  });

  test('a refused mute is undone with a message', () async {
    source.failPinWith = StateError('boom');

    final message = await controller.mute('a', duration: const Duration(hours: 1));

    expect(controller.isMuted('a'), isFalse);
    expect(message, 'Something went wrong. Please try again.');
  });

  test('a refused unmute keeps the room muted', () async {
    await controller.mute('a');
    source.failPinWith = StateError('boom');

    final message = await controller.unmute('a');

    expect(controller.isMuted('a'), isTrue);
    expect(message, isNotNull);
  });

  test('muting a room does not touch its pin', () async {
    await controller.togglePin('a');
    await controller.mute('a');

    expect(controller.isPinned('a'), isTrue);
    expect(controller.isMuted('a'), isTrue);
  });

  test('a failed refresh keeps what is already shown', () async {
    source.data = {'a': RoomActivity(roomId: 'a', unreadCount: 1)};
    await controller.refresh();

    final broken = _ThrowingSource();
    final other = RoomActivityController(
      source: broken,
      refreshEvery: const Duration(hours: 1),
    );
    addTearDown(other.dispose);
    await other.refresh(); // must not throw

    expect(controller.of('a')?.unreadCount, 1);
    expect(other.activity, isEmpty);
  });
}

class _ThrowingSource implements RoomActivitySource {
  @override
  Future<Map<String, RoomActivity>> fetch(String mode) async =>
      throw StateError('offline');

  @override
  Future<void> setPinned(String roomId, String mode, bool pinned) async {}

  @override
  Future<void> setMuted(String roomId, String mode, bool muted, {int? minutes}) async {}
}
