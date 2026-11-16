import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/room_message.dart';
import 'package:whisper_campus/services/live_signals.dart';

class _FakeChannel implements LiveChannelHandle {
  _FakeChannel(this.topic, this.onBroadcast, this.onStatus);

  final String topic;
  final void Function(Map<String, dynamic>) onBroadcast;
  final void Function(bool) onStatus;
  bool closed = false;

  @override
  Future<void> close() async => closed = true;
}

void main() {
  late List<_FakeChannel> channels;
  late LiveSignals signals;

  setUp(() {
    channels = [];
    signals = LiveSignals.forTesting((topic, onBroadcast, onStatus) {
      final channel = _FakeChannel(topic, onBroadcast, onStatus);
      channels.add(channel);
      return channel;
    });
  });

  // What the server really sends: {event, payload, type} around our payload.
  Map<String, dynamic> frame(Map<String, dynamic> body) => {
    'event': 'activity',
    'type': 'broadcast',
    'payload': body,
  };

  test('listeners on the same topic share one channel', () {
    signals.listen('feed:unofficial', (_) {});
    signals.listen('feed:unofficial', (_) {});

    expect(channels.length, 1);
    expect(signals.openTopicCount, 1);
  });

  test('different topics get their own channels', () {
    signals.listen('feed:unofficial', (_) {});
    signals.listen('feed:official', (_) {});

    expect(channels.map((c) => c.topic), ['feed:unofficial', 'feed:official']);
  });

  test('the channel closes only when the last listener leaves', () {
    final first = signals.listen('feed:official', (_) {});
    final second = signals.listen('feed:official', (_) {});

    first.cancel();
    expect(channels.single.closed, isFalse);

    second.cancel();
    expect(channels.single.closed, isTrue);
    expect(signals.openTopicCount, 0);
  });

  test('cancelling twice is safe', () {
    final subscription = signals.listen('feed:official', (_) {});
    subscription.cancel();
    subscription.cancel();

    expect(signals.openTopicCount, 0);
  });

  test('a new listener after closing opens a fresh channel', () {
    signals.listen('feed:official', (_) {}).cancel();
    signals.listen('feed:official', (_) {});

    expect(channels.length, 2);
    expect(channels.last.closed, isFalse);
  });

  test('every listener receives the unwrapped signal', () {
    final a = <Map<String, dynamic>>[];
    final b = <Map<String, dynamic>>[];
    signals.listen('feed:unofficial', a.add);
    signals.listen('feed:unofficial', b.add);

    channels.single.onBroadcast(
      frame({'kind': 'like', 'op': 'insert', 'post_id': 'p1', 'room_id': 'general'}),
    );

    expect(a.single['kind'], 'like');
    expect(a.single['post_id'], 'p1');
    expect(b.single['room_id'], 'general');
  });

  test('a failing listener does not stop the others', () {
    final received = <String>[];
    signals.listen('feed:unofficial', (_) => throw StateError('boom'));
    signals.listen('feed:unofficial', (s) => received.add(s['kind'] as String));

    channels.single.onBroadcast(frame({'kind': 'post'}));

    expect(received, ['post']);
  });

  test('a cancelled listener stops receiving', () {
    final received = <String>[];
    final subscription = signals.listen(
      'feed:unofficial',
      (s) => received.add(s['kind'] as String),
    );
    signals.listen('feed:unofficial', (_) {});

    subscription.cancel();
    channels.single.onBroadcast(frame({'kind': 'post'}));

    expect(received, isEmpty);
  });

  test('first connection is quiet, a reconnect asks for a resync', () {
    final received = <String>[];
    signals.listen('feed:official', (s) => received.add(s['kind'] as String));

    channels.single.onStatus(true); // first connect
    expect(received, isEmpty);

    channels.single.onStatus(false); // dropped
    expect(received, isEmpty);

    channels.single.onStatus(true); // reconnected
    expect(received, ['resync']);
  });

  group('unwrapBroadcast', () {
    test('returns the nested payload', () {
      expect(unwrapBroadcast(frame({'a': 1})), {'a': 1});
    });

    test('accepts an already unwrapped message', () {
      expect(unwrapBroadcast({'message_id': 'x'}), {'message_id': 'x'});
    });
  });

  group('live chat message', () {
    // The exact shape broadcast_room_message() sends, inside the wrapper.
    final liveFrame = {
      'event': 'new_message',
      'type': 'broadcast',
      'payload': {
        'message_id': 'm1',
        'room_id': 'dept-cs',
        'room_mode': 'unofficial',
        'author_username': 'Anon4fece0 (Moderator)',
        'content': 'hello',
        'created_at': '2026-11-16T14:00:00+00:00',
      },
    };

    test('is read from the nested payload', () {
      final message = RoomMessage.fromMap(unwrapBroadcast(liveFrame));

      expect(message.id, 'm1');
      expect(message.roomId, 'dept-cs');
      expect(message.content, 'hello');
      expect(message.isMine, isFalse);
    });

    test('reading the unwrapped frame directly would have failed', () {
      // This was the original bug: fields were read from the outer map.
      expect(() => RoomMessage.fromMap(liveFrame), throwsA(isA<TypeError>()));
    });

    test('own message is recognised despite the moderator badge', () {
      final message = RoomMessage.fromMap(
        unwrapBroadcast(liveFrame),
        myUsername: 'Anon4fece0',
      );

      expect(message.isMine, isTrue);
    });

    test('official messages are matched by author id', () {
      final message = RoomMessage.fromMap(
        {
          'message_id': 'm2',
          'room_id': 'official-live',
          'author_id': 'u1',
          'author_username': 'Asha · CS · 2nd',
          'content': 'hi',
          'created_at': '2026-11-16T14:00:00+00:00',
        },
        myUserId: 'u1',
      );

      expect(message.isMine, isTrue);
    });
  });
}
