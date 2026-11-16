import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/room_activity.dart';
import 'package:whisper_campus/pages/rooms/room_mute_button.dart';
import 'package:whisper_campus/services/room_activity_controller.dart';
import 'package:whisper_campus/services/room_activity_service.dart';

import 'test_helpers.dart';

class _Source implements RoomActivitySource {
  Map<String, RoomActivity> data = {};
  final calls = <String>[];
  Object? failWith;

  @override
  Future<Map<String, RoomActivity>> fetch(String mode) async => data;

  @override
  Future<void> setPinned(String roomId, String mode, bool pinned) async {}

  @override
  Future<void> setMuted(String roomId, String mode, bool muted, {int? minutes}) async {
    final error = failWith;
    if (error != null) throw error;
    calls.add('${muted ? 'mute' : 'unmute'}:${minutes ?? 'forever'}');
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
  group('muteStatusLabel', () {
    final now = DateTime(2026, 11, 17, 12);

    RoomActivity muted({DateTime? until}) =>
        RoomActivity(roomId: 'a', muted: true, mutedUntil: until);

    test('empty when not muted or null', () {
      expect(muteStatusLabel(null, now: now), '');
      expect(muteStatusLabel(const RoomActivity(roomId: 'a'), now: now), '');
    });

    test('until you unmute', () {
      expect(muteStatusLabel(muted(), now: now), 'Muted until you unmute');
    });

    test('later today shows just the time', () {
      expect(
        muteStatusLabel(muted(until: DateTime(2026, 11, 17, 20, 5)), now: now),
        'Muted until 20:05',
      );
    });

    test('another day shows the day too', () {
      expect(
        muteStatusLabel(muted(until: DateTime(2026, 11, 18, 9)), now: now),
        'Muted until Wed 18 Nov, 09:00',
      );
    });

    test('a mute that already ended shows nothing', () {
      expect(
        muteStatusLabel(muted(until: DateTime(2026, 11, 17, 11)), now: now),
        '',
      );
    });
  });

  group('RoomActivity mute', () {
    test('fromMap reads muted_until', () {
      final activity = RoomActivity.fromMap({
        'room_id': 'a',
        'muted': true,
        'muted_until': '2026-11-17T20:00:00+00:00',
      });

      expect(activity.muted, isTrue);
      expect(activity.mutedUntil, isNotNull);
    });

    test('isMutedAt honours the end time', () {
      final now = DateTime(2026, 11, 17, 12);
      final timed = RoomActivity(
        roomId: 'a',
        muted: true,
        mutedUntil: DateTime(2026, 11, 17, 13),
      );

      expect(timed.isMutedAt(now: now), isTrue);
      expect(timed.isMutedAt(now: DateTime(2026, 11, 17, 13, 1)), isFalse);
      expect(const RoomActivity(roomId: 'a', muted: true).isMutedAt(now: now), isTrue);
      expect(const RoomActivity(roomId: 'a').isMutedAt(now: now), isFalse);
    });

    test('unmuting clears the end time', () {
      final timed = RoomActivity(roomId: 'a', muted: true, mutedUntil: DateTime(2030));

      expect(timed.copyWith(muted: false).mutedUntil, isNull);
    });

    test('the three lengths', () {
      expect(MuteLength.hour.duration, const Duration(hours: 1));
      expect(MuteLength.eightHours.duration, const Duration(hours: 8));
      expect(MuteLength.untilUnmuted.duration, isNull);
    });
  });

  group('RoomMuteButton', () {
    Future<(_Source, RoomActivityController)> pump(
      WidgetTester tester, {
      Screen screen = const Screen('d', Size(360, 740), 1.0),
      Map<String, RoomActivity> data = const {},
    }) async {
      useScreen(tester, screen);
      final source = _Source()..data = {...data};
      final controller = RoomActivityController(
        source: source,
        refreshEvery: const Duration(hours: 1),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            appBar: AppBar(
              title: const Text('Clubs chat'),
              actions: [RoomMuteButton(controller: controller, roomId: 'clubs')],
            ),
          ),
          textScale: screen.textScale,
        ),
      );
      return (source, controller);
    }

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('not muted: offers 1 hour, 8 hours and until I unmute', (tester) async {
      await pump(tester);
      await openMenu(tester);

      expect(find.text('Mute for 1 hour'), findsOneWidget);
      expect(find.text('Mute for 8 hours'), findsOneWidget);
      expect(find.text('Mute until I unmute'), findsOneWidget);
      expect(find.text('Unmute notifications'), findsNothing);
    });

    testWidgets('choosing 1 hour mutes for 60 minutes and says so', (tester) async {
      final (source, controller) = await pump(tester);
      await openMenu(tester);

      await tester.tap(find.text('Mute for 1 hour'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['mute:60']);
      expect(controller.isMuted('clubs'), isTrue);
      expect(find.text('Room muted for 1 hour.'), findsOneWidget);
    });

    testWidgets('8 hours and until I unmute', (tester) async {
      final (source, _) = await pump(tester);

      await openMenu(tester);
      await tester.tap(find.text('Mute for 8 hours'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Room muted for 8 hours.'), findsOneWidget);

      await openMenu(tester);
      await tester.tap(find.text('Change to: until I unmute'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['mute:480', 'mute:forever']);
      expect(find.text('Room muted until you unmute it.'), findsOneWidget);
    });

    testWidgets('muted: shows until when, and Unmute works', (tester) async {
      final (source, controller) = await pump(
        tester,
        data: {'clubs': RoomActivity(roomId: 'clubs', muted: true)},
      );
      await openMenu(tester);

      expect(find.text('Muted until you unmute'), findsOneWidget);
      expect(find.text('Unmute notifications'), findsOneWidget);

      await tester.tap(find.text('Unmute notifications'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(source.calls, ['unmute:forever']);
      expect(controller.isMuted('clubs'), isFalse);
      expect(find.text('Notifications are back on for this room.'), findsOneWidget);
    });

    testWidgets('the icon changes when muted', (tester) async {
      await pump(
        tester,
        data: {'clubs': RoomActivity(roomId: 'clubs', muted: true)},
      );

      expect(find.byIcon(Icons.notifications_off_rounded), findsOneWidget);
      expect(find.byIcon(Icons.notifications_none_rounded), findsNothing);
    });

    testWidgets('a refused mute shows a message and stays unmuted', (tester) async {
      final (source, controller) = await pump(tester);
      source.failWith = StateError('boom');
      await openMenu(tester);

      await tester.tap(find.text('Mute for 1 hour'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.isMuted('clubs'), isFalse);
      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
    });

    for (final screen in smallScreens) {
      testWidgets('menu fits: ${screen.name}', (tester) async {
        await pump(
          tester,
          screen: screen,
          data: {
            'clubs': RoomActivity(
              roomId: 'clubs',
              muted: true,
              mutedUntil: DateTime.now().add(const Duration(days: 2)),
            ),
          },
        );
        await openMenu(tester);

        expectNoLayoutErrors(tester);
      });
    }
  });
}
