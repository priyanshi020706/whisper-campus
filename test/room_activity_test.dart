import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/room_activity.dart';

void main() {
  final now = DateTime(2026, 11, 17, 12);

  RoomActivity act(
    String id, {
    int? minutesAgo,
    bool pinned = false,
    int? pinnedMinutesAgo,
    bool mine = false,
    int unread = 0,
  }) => RoomActivity(
    roomId: id,
    lastMessageAt: minutesAgo == null
        ? null
        : now.subtract(Duration(minutes: minutesAgo)),
    lastMessageMine: mine,
    unreadCount: unread,
    pinned: pinned,
    pinnedAt: pinnedMinutesAgo == null
        ? null
        : now.subtract(Duration(minutes: pinnedMinutesAgo)),
  );

  List<String> order(List<String> ids, List<RoomActivity> activity) =>
      orderRoomsByActivity(ids, (id) => id, {
        for (final a in activity) a.roomId: a,
      });

  group('orderRoomsByActivity', () {
    const rooms = ['a', 'b', 'c', 'd', 'e'];

    test('rooms with no activity keep their given order', () {
      expect(order(rooms, const []), rooms);
    });

    test('the room with the newest message comes first', () {
      final result = order(rooms, [
        act('c', minutesAgo: 30),
        act('e', minutesAgo: 5),
        act('a', minutesAgo: 120),
      ]);

      expect(result, ['e', 'c', 'a', 'b', 'd']);
    });

    test('a message I sent counts the same as one I received', () {
      final result = order(rooms, [
        act('b', minutesAgo: 20, mine: true),
        act('d', minutesAgo: 10),
      ]);

      expect(result.take(2), ['d', 'b']);
    });

    test('pinned rooms come first, in the order they were pinned', () {
      final result = order(rooms, [
        act('d', pinned: true, pinnedMinutesAgo: 10),
        act('b', pinned: true, pinnedMinutesAgo: 60),
        act('e', minutesAgo: 1),
      ]);

      expect(result, ['b', 'd', 'e', 'a', 'c']);
    });

    test('a pinned room stays on top even with no recent message', () {
      final result = order(rooms, [
        act('c', pinned: true, pinnedMinutesAgo: 5),
        act('a', minutesAgo: 1),
      ]);

      expect(result.first, 'c');
      expect(result[1], 'a');
    });

    test('pinned plus recent plus the rest, all together', () {
      final result = order(rooms, [
        act('e', pinned: true, pinnedMinutesAgo: 100, minutesAgo: 500),
        act('b', minutesAgo: 3),
        act('d', minutesAgo: 40),
        act('a'), // joined but nothing recent
      ]);

      expect(result, ['e', 'b', 'd', 'a', 'c']);
    });

    test('ids the server did not mention are left in place', () {
      final result = order(['x', 'y', 'z'], [act('z', minutesAgo: 1)]);

      expect(result, ['z', 'x', 'y']);
    });

    test('does not change the list it is given', () {
      final input = ['a', 'b'];
      orderRoomsByActivity(input, (id) => id, {'b': act('b', minutesAgo: 1)});

      expect(input, ['a', 'b']);
    });
  });

  test('pinnedCount counts only pinned rooms', () {
    expect(
      pinnedCount({
        'a': act('a', pinned: true),
        'b': act('b'),
        'c': act('c', pinned: true),
      }),
      2,
    );
  });

  group('relativeTimeLabel', () {
    test('uses minutes, hours, yesterday and days', () {
      expect(relativeTimeLabel(now, now: now), 'Just now');
      expect(
        relativeTimeLabel(now.subtract(const Duration(minutes: 5)), now: now),
        '5m ago',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(hours: 30)), now: now),
        'Yesterday',
      );
      expect(
        relativeTimeLabel(now.subtract(const Duration(days: 4)), now: now),
        '4d ago',
      );
    });
  });

  group('roomActivityLine', () {
    test('says "You" when the last message was mine', () {
      expect(
        roomActivityLine(act('a', minutesAgo: 5, mine: true), now: now),
        'You · 5m ago',
      );
      expect(roomActivityLine(act('a', minutesAgo: 5), now: now), '5m ago');
    });

    test('is null when there is no recent message', () {
      expect(roomActivityLine(act('a'), now: now), isNull);
      expect(roomActivityLine(null, now: now), isNull);
    });
  });

  test('fromMap reads the server row', () {
    final activity = RoomActivity.fromMap({
      'room_id': 'dept-cs',
      'last_message_at': '2026-11-17T10:00:00+00:00',
      'last_message_mine': true,
      'unread_count': 4,
      'pinned': true,
      'pinned_at': '2026-11-16T10:00:00+00:00',
    });

    expect(activity.roomId, 'dept-cs');
    expect(activity.lastMessageMine, isTrue);
    expect(activity.unreadCount, 4);
    expect(activity.pinned, isTrue);
    expect(activity.pinnedAt, isNotNull);
  });

  test('copyWith(pinned: false) clears the pin time', () {
    final unpinned = act('a', pinned: true, pinnedMinutesAgo: 5).copyWith(
      pinned: false,
    );

    expect(unpinned.pinned, isFalse);
    expect(unpinned.pinnedAt, isNull);
  });
}
