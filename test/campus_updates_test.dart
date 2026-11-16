import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/campus_updates.dart';
import 'package:whisper_campus/services/campus_updates_controller.dart';
import 'package:whisper_campus/services/live_signals.dart';

CampusEvent event({
  String id = 'e1',
  DateTime? start,
  DateTime? end,
  String? myStatus,
  int going = 0,
  int interested = 0,
  bool cancelled = false,
}) => CampusEvent(
  id: id,
  title: 'Tech Fest',
  startsAt: start ?? DateTime(2026, 11, 20, 10),
  endsAt: end,
  organizerLabel: 'Faculty',
  myStatus: myStatus,
  goingCount: going,
  interestedCount: interested,
  cancelled: cancelled,
);

class _FakeSource implements CampusUpdatesSource {
  List<CampusEvent> eventList = [event()];
  List<Announcement> announcementList = [];
  Object? failWith;
  int eventFetches = 0;
  final calls = <String>[];
  Future<void> Function()? onRsvp;

  void _maybeFail() {
    final error = failWith;
    if (error != null) throw error;
  }

  @override
  Future<List<CampusEvent>> events({required bool includePast}) async {
    eventFetches++;
    _maybeFail();
    return eventList;
  }

  @override
  Future<List<Announcement>> announcements() async {
    _maybeFail();
    return announcementList;
  }

  @override
  Future<void> rsvp(String eventId, String? status) async {
    calls.add('rsvp:$eventId:$status');
    await onRsvp?.call();
    _maybeFail();
    // Like the real server, remember the answer.
    eventList = [
      for (final e in eventList) e.id == eventId ? e.withMyStatus(status) : e,
    ];
  }

  @override
  Future<void> cancelEvent(String eventId) async {
    calls.add('cancel:$eventId');
    _maybeFail();
  }

  @override
  Future<void> createEvent({
    required String title,
    required String description,
    required String location,
    required DateTime startsAt,
    DateTime? endsAt,
    String? roomId,
  }) async {
    calls.add('createEvent:$title');
    _maybeFail();
  }

  @override
  Future<void> createAnnouncement({
    required String title,
    required String body,
    String? roomId,
    bool pinned = false,
    DateTime? expiresAt,
  }) async {
    calls.add('createAnnouncement:$title');
    _maybeFail();
  }

  @override
  Future<void> deleteAnnouncement(String id) async {
    calls.add('delete:$id');
    _maybeFail();
  }

  @override
  Future<List<PublishRoom>> publishRooms() async => const [];
}

void main() {
  group('formatting', () {
    test('day, time and ranges', () {
      final start = DateTime(2026, 11, 16, 9, 5); // a Monday
      expect(formatEventDay(start), 'Mon 16 Nov');
      expect(formatEventTime(start), '09:05');
      expect(formatEventWhen(start, null), 'Mon 16 Nov · 09:05');
      expect(
        formatEventWhen(start, DateTime(2026, 11, 16, 14)),
        'Mon 16 Nov · 09:05 – 14:00',
      );
      expect(
        formatEventWhen(start, DateTime(2026, 11, 17, 18)),
        'Mon 16 Nov 09:05 – Tue 17 Nov 18:00',
      );
    });

    test('countdown wording', () {
      final now = DateTime(2026, 11, 17, 12);
      expect(eventCountdown(event(start: DateTime(2026, 11, 17, 18)), now: now), 'Today');
      expect(eventCountdown(event(start: DateTime(2026, 11, 17, 12, 30)), now: now), 'In 30 min');
      expect(eventCountdown(event(start: DateTime(2026, 11, 18, 9)), now: now), 'Tomorrow');
      expect(eventCountdown(event(start: DateTime(2026, 11, 22, 9)), now: now), 'In 5 days');
      expect(eventCountdown(event(start: DateTime(2026, 11, 17, 11)), now: now), 'Happening now');
      expect(eventCountdown(event(start: DateTime(2026, 11, 10, 9)), now: now), 'Ended');
      expect(eventCountdown(event(start: DateTime(2026, 11, 18), cancelled: true), now: now), 'Cancelled');
    });

    test('an event without an end lasts three hours', () {
      final e = event(start: DateTime(2026, 11, 17, 10));
      expect(e.isOver(now: DateTime(2026, 11, 17, 12, 59)), isFalse);
      expect(e.isOver(now: DateTime(2026, 11, 17, 13, 1)), isTrue);
    });
  });

  group('CampusEvent.withMyStatus', () {
    test('going adds to the count', () {
      final next = event(going: 2).withMyStatus('going');
      expect(next.goingCount, 3);
      expect(next.myStatus, 'going');
    });

    test('switching moves the count between the two', () {
      final next = event(going: 3, interested: 1, myStatus: 'going').withMyStatus('interested');
      expect(next.goingCount, 2);
      expect(next.interestedCount, 2);
    });

    test('clearing removes my count', () {
      final next = event(interested: 4, myStatus: 'interested').withMyStatus(null);
      expect(next.interestedCount, 3);
      expect(next.myStatus, isNull);
    });
  });

  group('fromMap', () {
    test('event', () {
      final e = CampusEvent.fromMap({
        'event_id': 'x', 'title': 'T', 'description': 'D', 'location': 'L',
        'starts_at': '2026-11-20T10:00:00+00:00', 'ends_at': null, 'room_id': 'clubs',
        'organizer_label': 'Admin', 'cancelled': false, 'going_count': 5,
        'interested_count': 2, 'my_status': 'going', 'can_manage': true,
      });
      expect(e.goingCount, 5);
      expect(e.myStatus, 'going');
      expect(e.canManage, isTrue);
      expect(e.roomId, 'clubs');
    });

    test('announcement', () {
      final a = Announcement.fromMap({
        'announcement_id': 'a', 'title': 'T', 'body': 'B', 'pinned': true,
        'room_id': null, 'organizer_label': 'Faculty',
        'created_at': '2026-11-17T10:00:00+00:00', 'expires_at': null, 'can_manage': false,
      });
      expect(a.pinned, isTrue);
      expect(a.expiresAt, isNull);
    });
  });

  group('validation', () {
    final now = DateTime(2026, 11, 17, 12);
    String? check({
      String title = 'Fest',
      String description = '',
      String location = '',
      DateTime? start,
      DateTime? end,
    }) => validateEventDraft(
      title: title,
      description: description,
      location: location,
      startsAt: start ?? now.add(const Duration(days: 1)),
      endsAt: end,
      now: now,
    );

    test('accepts a good event', () => expect(check(), isNull));
    test('title is required', () => expect(check(title: '  '), 'Give the event a title.'));
    test('start must be in the future', () {
      expect(check(start: now.subtract(const Duration(days: 1))), 'The start time has already passed.');
    });
    test('start within a year', () {
      expect(check(start: now.add(const Duration(days: 400))), 'Choose a start time within the next year.');
    });
    test('end after start', () {
      final start = now.add(const Duration(days: 1));
      expect(check(start: start, end: start), 'The event must end after it starts.');
    });
    test('missing start', () {
      expect(
        validateEventDraft(title: 't', description: '', location: '', startsAt: null, endsAt: null),
        'Choose when the event starts.',
      );
    });
    test('announcement rules', () {
      expect(validateAnnouncementDraft(title: '', body: ''), isNotNull);
      expect(validateAnnouncementDraft(title: 'x' * 121, body: ''), isNotNull);
      expect(validateAnnouncementDraft(title: 'ok', body: 'y' * 2001), isNotNull);
      expect(validateAnnouncementDraft(title: 'ok', body: 'fine'), isNull);
    });
  });

  group('CampusUpdatesController', () {
    late _FakeSource source;
    late CampusUpdatesController controller;
    void Function(Map<String, dynamic>)? liveCallback;
    var cancelled = 0;

    setUp(() {
      source = _FakeSource();
      liveCallback = null;
      cancelled = 0;
      controller = CampusUpdatesController(
        source: source,
        listen: (topic, onSignal) {
          expect(topic, 'campus:updates');
          liveCallback = onSignal;
          return _FakeSubscription(() => cancelled++);
        },
      );
    });

    tearDown(() => controller.dispose());

    test('refresh loads events and announcements', () async {
      source.announcementList = [
        Announcement(id: 'a', title: 'Hi', createdAt: DateTime(2026), organizerLabel: 'Admin', pinned: true),
      ];

      final message = await controller.refresh();

      expect(message, isNull);
      expect(controller.loaded, isTrue);
      expect(controller.events.single.title, 'Tech Fest');
      expect(controller.featuredAnnouncement?.title, 'Hi');
    });

    test('a failed refresh reports a friendly message and keeps old data', () async {
      await controller.refresh();
      source.failWith = StateError('offline');

      final message = await controller.refresh();

      expect(message, 'Something went wrong. Please try again.');
      expect(controller.events, isNotEmpty);
      expect(controller.error, isNotNull);
    });

    test('RSVP shows at once and calls the server', () async {
      await controller.refresh();

      final message = await controller.rsvp('e1', 'going');

      expect(message, isNull);
      expect(controller.events.single.myStatus, 'going');
      expect(controller.events.single.goingCount, 1);
      expect(source.calls, ['rsvp:e1:going']);
    });

    test('the same answer again takes it back', () async {
      source.eventList = [event(myStatus: 'going', going: 1)];
      await controller.refresh();

      await controller.rsvp('e1', 'going');

      expect(controller.events.single.myStatus, isNull);
      expect(source.calls, ['rsvp:e1:null']);
    });

    test('a refused RSVP is undone with a message', () async {
      await controller.refresh();
      source.failWith = StateError('boom');

      final message = await controller.rsvp('e1', 'going');

      expect(controller.events.single.myStatus, isNull);
      expect(controller.events.single.goingCount, 0);
      expect(message, isNotNull);
    });

    test('a refresh that was in flight does not undo a fresh RSVP', () async {
      await controller.refresh();
      final slowRefresh = controller.refresh();
      await controller.rsvp('e1', 'going');
      await slowRefresh;
      // The dropped refresh is repeated so the list matches the server.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(controller.events.single.myStatus, 'going');
      expect(controller.events.single.goingCount, 1);
    });

    test('a live signal refreshes after a short pause', () async {
      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final before = source.eventFetches;

      liveCallback!({'kind': 'event'});
      liveCallback!({'kind': 'event'}); // a burst counts once
      await Future<void>.delayed(const Duration(milliseconds: 800));

      expect(source.eventFetches, before + 1);
    });

    test('toggling past events reloads', () async {
      await controller.refresh();
      final before = source.eventFetches;

      await controller.setIncludePast(true);

      expect(controller.includePast, isTrue);
      expect(source.eventFetches, before + 1);
    });

    test('creating and cancelling go through and reload', () async {
      await controller.refresh();
      final before = source.eventFetches;

      expect(await controller.createEvent(title: 'New', description: '', location: '', startsAt: DateTime(2027)), isNull);
      expect(await controller.cancelEvent('e1'), isNull);
      expect(await controller.createAnnouncement(title: 'Note', body: ''), isNull);
      expect(await controller.deleteAnnouncement('a1'), isNull);

      expect(source.calls, ['createEvent:New', 'cancel:e1', 'createAnnouncement:Note', 'delete:a1']);
      expect(source.eventFetches, before + 4);
    });

    test('a refused create returns the message and does not reload', () async {
      await controller.refresh();
      final before = source.eventFetches;
      source.failWith = StateError('no');

      final message = await controller.createEvent(title: 'x', description: '', location: '', startsAt: DateTime(2027));

      expect(message, isNotNull);
      expect(source.eventFetches, before);
    });

    test('dispose stops listening', () {
      controller.start();
      controller.dispose();

      expect(cancelled, 1);
    });
  });
}

class _FakeSubscription implements LiveSubscription {
  _FakeSubscription(this._onCancel);
  final void Function() _onCancel;
  @override
  void cancel() => _onCancel();
}
