import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/campus_updates.dart';
import 'package:whisper_campus/models/post_card.dart';
import 'package:whisper_campus/pages/events/announcements_page.dart';
import 'package:whisper_campus/pages/events/events_page.dart';
import 'package:whisper_campus/pages/search/search_page.dart';
import 'package:whisper_campus/services/campus_updates_controller.dart';
import 'package:whisper_campus/services/live_signals.dart';
import 'package:whisper_campus/services/saved_posts_controller.dart';

import 'test_helpers.dart';

// ---------------------------------------------------------------- search ----

class _SearchSource implements PostSearchSource {
  final calls = <(String, String)>[];
  Future<List<PostCardData>> Function(String kind, String query)? handler;

  @override
  Future<List<PostCardData>> search(String kind, String query) {
    calls.add((kind, query));
    return handler!(kind, query);
  }
}

class _SavedSource implements SavedPostsSource {
  final saved = <String>{};
  @override
  Future<Set<String>> fetchIds(String kind) async => {};
  @override
  Future<List<PostCardData>> fetchPosts() async => const [];
  @override
  Future<void> setSaved(String kind, String postId, bool value) async {
    value ? saved.add(postId) : saved.remove(postId);
  }
}

PostCardData postCard(String id, {String content = 'physics lab notes', String kind = 'post'}) =>
    PostCardData(
      kind: kind,
      postId: id,
      roomId: 'dept-cs',
      authorLabel: 'Anon1',
      content: content,
      createdAt: DateTime(2026, 11, 16),
    );

// ---------------------------------------------------------------- events ----

class _UpdatesSource implements CampusUpdatesSource {
  List<CampusEvent> events_ = [];
  List<Announcement> announcements_ = [];
  List<PublishRoom> rooms = const [];
  Object? failCreate;
  final calls = <String>[];

  @override
  Future<List<CampusEvent>> events({required bool includePast}) async => events_;
  @override
  Future<List<Announcement>> announcements() async => announcements_;
  @override
  Future<void> rsvp(String eventId, String? status) async {
    calls.add('rsvp:$eventId:$status');
    events_ = [for (final e in events_) e.id == eventId ? e.withMyStatus(status) : e];
  }

  @override
  Future<void> cancelEvent(String eventId) async {
    calls.add('cancel:$eventId');
    events_ = [
      for (final e in events_)
        e.id == eventId
            ? CampusEvent(
                id: e.id, title: e.title, startsAt: e.startsAt,
                organizerLabel: e.organizerLabel, cancelled: true, canManage: true,
              )
            : e,
    ];
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
    final error = failCreate;
    if (error != null) throw error;
    calls.add('createEvent:$title:${roomId ?? 'campus'}');
  }

  @override
  Future<void> createAnnouncement({
    required String title,
    required String body,
    String? roomId,
    bool pinned = false,
    DateTime? expiresAt,
  }) async {
    final error = failCreate;
    if (error != null) throw error;
    calls.add('createAnnouncement:$title:${roomId ?? 'campus'}:pinned=$pinned');
  }

  @override
  Future<void> deleteAnnouncement(String id) async {
    calls.add('delete:$id');
    announcements_ = [for (final a in announcements_) if (a.id != id) a];
  }

  @override
  Future<List<PublishRoom>> publishRooms() async => rooms;
}

class _NoSub implements LiveSubscription {
  @override
  void cancel() {}
}

CampusEvent ev(String id, {int daysAhead = 2, String title = 'Tech Fest', bool manage = false, String desc = ''}) =>
    CampusEvent(
      id: id,
      title: title,
      description: desc,
      location: 'Main hall',
      startsAt: DateTime.now().add(Duration(days: daysAhead)),
      organizerLabel: 'Faculty',
      roomId: 'dept-cs',
      goingCount: 4,
      interestedCount: 7,
      canManage: manage,
    );

Announcement ann(String id, {String title = 'Exam schedule', bool pinned = false, bool manage = false}) =>
    Announcement(
      id: id,
      title: title,
      body: 'Details follow.',
      pinned: pinned,
      createdAt: DateTime(2026, 11, 16),
      organizerLabel: 'Admin',
      canManage: manage,
    );

void main() {
  group('SearchPage', () {
    Future<(_SearchSource, SavedPostsController)> pumpSearch(
      WidgetTester tester, {
      Screen screen = const Screen('d', Size(360, 740), 1.0),
      String kind = 'post',
      void Function(PostCardData)? onOpen,
    }) async {
      useScreen(tester, screen);
      final source = _SearchSource()
        ..handler = (kind, query) async => [postCard('1')];
      final saved = SavedPostsController(source: _SavedSource());
      addTearDown(saved.dispose);
      await tester.pumpWidget(
        themedApp(
          SearchPage(
            initialKind: kind,
            saved: saved,
            onOpenComments: onOpen ?? (_) {},
            source: source,
            imageUrlLoader: (_) async => null,
            debounce: const Duration(milliseconds: 100),
          ),
          textScale: screen.textScale,
        ),
      );
      return (source, saved);
    }

    testWidgets('starts with a hint and does not search', (tester) async {
      final (source, _) = await pumpSearch(tester);

      expect(find.text('Search the campus'), findsOneWidget);
      expect(source.calls, isEmpty);
    });

    testWidgets('searches after a short pause and shows readable results', (tester) async {
      final (source, _) = await pumpSearch(tester);

      await tester.enterText(find.byType(TextField), 'physics');
      expect(source.calls, isEmpty); // not yet: still typing
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(source.calls, [('post', 'physics')]);
      expect(find.text('physics lab notes'), findsOneWidget);
    });

    testWidgets('typing quickly sends only the last search', (tester) async {
      final (source, _) = await pumpSearch(tester);

      await tester.enterText(find.byType(TextField), 'ph');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.enterText(find.byType(TextField), 'phys');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.enterText(find.byType(TextField), 'physics');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(source.calls, [('post', 'physics')]);
    });

    testWidgets('one letter does not search', (tester) async {
      final (source, _) = await pumpSearch(tester);

      await tester.enterText(find.byType(TextField), 'p');
      await tester.pump(const Duration(milliseconds: 200));

      expect(source.calls, isEmpty);
    });

    testWidgets('an older answer never replaces a newer one', (tester) async {
      final (source, _) = await pumpSearch(tester);
      final slow = Completer<List<PostCardData>>();
      source.handler = (kind, query) {
        if (query == 'first') return slow.future;
        return Future.value([postCard('2', content: 'second result')]);
      };

      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump(const Duration(milliseconds: 150)); // first request starts
      await tester.enterText(find.byType(TextField), 'second');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();
      slow.complete([postCard('1', content: 'stale result')]); // arrives late
      await tester.pump();
      await tester.pump();

      expect(find.text('second result'), findsOneWidget);
      expect(find.text('stale result'), findsNothing);
    });

    testWidgets('no matches says so', (tester) async {
      final (source, _) = await pumpSearch(tester);
      source.handler = (_, _) async => [];

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(find.textContaining('No posts match'), findsOneWidget);
    });

    testWidgets('an error shows a friendly message', (tester) async {
      final (source, _) = await pumpSearch(tester);
      source.handler = (_, _) async => throw StateError('db down');

      await tester.enterText(find.byType(TextField), 'physics');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      expect(find.textContaining('db down'), findsNothing);
    });

    testWidgets('switching to Official searches again in that mode', (tester) async {
      final (source, _) = await pumpSearch(tester);
      await tester.enterText(find.byType(TextField), 'physics');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      await tester.tap(find.text('Official'));
      await tester.pump();
      await tester.pump();

      expect(source.calls.last, ('official_post', 'physics'));
    });

    testWidgets('the clear button empties the search', (tester) async {
      await pumpSearch(tester);
      await tester.enterText(find.byType(TextField), 'physics');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();

      expect(find.text('Search the campus'), findsOneWidget);
    });

    testWidgets('Save bookmarks a result, tapping opens the comments', (tester) async {
      PostCardData? opened;
      final (_, saved) = await pumpSearch(tester, onOpen: (p) => opened = p);
      await tester.enterText(find.byType(TextField), 'physics');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(saved.isSaved('post', '1'), isTrue);
      expect(find.text('Saved'), findsOneWidget);

      await tester.tap(find.text('physics lab notes'));
      expect(opened?.postId, '1');
    });

    for (final screen in smallScreens) {
      testWidgets('results do not overflow: ${screen.name}', (tester) async {
        final (source, _) = await pumpSearch(tester, screen: screen);
        source.handler = (_, _) async => [
          postCard('1', content: 'word ' * 200),
          postCard('2', kind: 'official_post'),
        ];
        await tester.enterText(find.byType(TextField), 'word');
        await tester.pump(const Duration(milliseconds: 150));
        await tester.pump();

        expectNoLayoutErrors(tester);
      });
    }
  });

  group('EventsPage', () {
    Future<(_UpdatesSource, CampusUpdatesController)> pumpEvents(
      WidgetTester tester,
      List<CampusEvent> events, {
      Screen screen = const Screen('d', Size(360, 740), 1.0),
      bool canCreate = false,
      bool isStaff = false,
      List<PublishRoom> rooms = const [],
    }) async {
      useScreen(tester, screen);
      final source = _UpdatesSource()
        ..events_ = events
        ..rooms = rooms;
      final updates = CampusUpdatesController(
        source: source,
        listen: (_, _) => _NoSub(),
      );
      addTearDown(updates.dispose);
      await tester.pumpWidget(
        themedApp(
          EventsPage(updates: updates, canCreate: canCreate, isStaff: isStaff),
          textScale: screen.textScale,
        ),
      );
      await tester.pump();
      await tester.pump();
      return (source, updates);
    }

    testWidgets('shows events with counts, place and organizer role', (tester) async {
      await pumpEvents(tester, [ev('1')]);

      expect(find.text('Tech Fest'), findsOneWidget);
      expect(find.text('Main hall'), findsOneWidget);
      expect(find.text('Going · 4'), findsOneWidget);
      expect(find.text('Interested · 7'), findsOneWidget);
      expect(find.textContaining('Faculty'), findsOneWidget);
    });

    testWidgets('empty state, with and without permission to add', (tester) async {
      await pumpEvents(tester, []);
      expect(find.text('No upcoming events'), findsOneWidget);
      expect(find.text('Check back soon.'), findsOneWidget);
      expect(find.text('Add event'), findsNothing);
    });

    testWidgets('people who can add events see the button', (tester) async {
      await pumpEvents(tester, [], canCreate: true);

      expect(find.text('Add event'), findsOneWidget);
      expect(find.textContaining('Tap "Add event"'), findsOneWidget);
    });

    testWidgets('tapping Going shows it at once; tapping again removes it', (tester) async {
      final (source, _) = await pumpEvents(tester, [ev('1')]);

      await tester.tap(find.text('Going · 4'));
      await tester.pump();
      expect(find.text('Going · 5'), findsOneWidget);

      await tester.tap(find.text('Going · 5'));
      await tester.pump();
      expect(find.text('Going · 4'), findsOneWidget);
      expect(source.calls, ['rsvp:1:going', 'rsvp:1:null']);
    });

    testWidgets('a long description expands and collapses', (tester) async {
      await pumpEvents(tester, [ev('1', desc: 'details ' * 60)]);

      expect(find.text('Show more'), findsOneWidget);
      await tester.tap(find.text('Show more'));
      await tester.pump();
      expect(find.text('Show less'), findsOneWidget);
    });

    testWidgets('cancelling asks first and then marks it cancelled', (tester) async {
      final (source, _) = await pumpEvents(tester, [ev('1', manage: true)]);

      await tester.tap(find.byTooltip('Event options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Cancel event'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Cancel this event?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel event'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(source.calls, contains('cancel:1'));
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('a cancelled event cannot be answered', (tester) async {
      final (source, _) = await pumpEvents(tester, [
        CampusEvent(
          id: 'c', title: 'Called off', organizerLabel: 'Admin', cancelled: true,
          startsAt: DateTime.now().add(const Duration(days: 3)),
        ),
      ]);

      await tester.tap(find.textContaining('Going'));
      await tester.pump();

      expect(source.calls, isEmpty);
    });

    for (final screen in smallScreens) {
      testWidgets('cards do not overflow: ${screen.name}', (tester) async {
        await pumpEvents(
          tester,
          [
            ev('1', title: 'A very long event title ' * 6, desc: 'long details ' * 90, manage: true),
            ev('2'),
          ],
          screen: screen,
        );

        expectNoLayoutErrors(tester);
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();
        expectNoLayoutErrors(tester);
      });
    }

    testWidgets('creating an event: validation, then success', (tester) async {
      final (source, _) = await pumpEvents(
        tester,
        [],
        canCreate: true,
        isStaff: true,
      );

      await tester.tap(find.text('Add event'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.ensureVisible(find.text('Create event'));
      await tester.tap(find.text('Create event'));
      await tester.pump();

      expect(find.text('Give the event a title.'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Title'), 'Quiz night');
      await tester.tap(find.text('Create event'));
      await tester.pump();
      expect(find.text('Choose when the event starts.'), findsOneWidget);
      expect(source.calls, isEmpty);
    });

    testWidgets('a moderator must pick one of their rooms', (tester) async {
      await pumpEvents(
        tester,
        [],
        canCreate: true,
        isStaff: false,
        rooms: const [PublishRoom(id: 'clubs', name: 'Clubs')],
      );

      await tester.tap(find.text('Add event'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Clubs'), findsWidgets);
      expect(find.text('Whole campus'), findsNothing);
    });

    for (final screen in smallScreens) {
      testWidgets('create sheet fits with the keyboard: ${screen.name}', (tester) async {
        await pumpEvents(
          tester,
          [],
          canCreate: true,
          isStaff: true,
          screen: screen,
          rooms: [PublishRoom(id: 'r', name: 'A room with a very very long name ' * 3)],
        );
        await tester.tap(find.text('Add event'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        tester.view.viewInsets = FakeViewPadding(bottom: screen.size.height * 0.4);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expectNoLayoutErrors(tester);
      });
    }
  });

  group('AnnouncementsPage', () {
    Future<(_UpdatesSource, CampusUpdatesController)> pumpAnn(
      WidgetTester tester,
      List<Announcement> items, {
      Screen screen = const Screen('d', Size(360, 740), 1.0),
      bool canCreate = false,
      bool isStaff = false,
      List<PublishRoom> rooms = const [],
    }) async {
      useScreen(tester, screen);
      final source = _UpdatesSource()
        ..announcements_ = items
        ..rooms = rooms;
      final updates = CampusUpdatesController(source: source, listen: (_, _) => _NoSub());
      addTearDown(updates.dispose);
      await tester.pumpWidget(
        themedApp(
          AnnouncementsPage(updates: updates, canCreate: canCreate, isStaff: isStaff),
          textScale: screen.textScale,
        ),
      );
      await tester.pump();
      await tester.pump();
      return (source, updates);
    }

    testWidgets('lists announcements with the organizer role', (tester) async {
      await pumpAnn(tester, [ann('1', pinned: true), ann('2', title: 'Holiday')]);

      expect(find.text('Exam schedule'), findsOneWidget);
      expect(find.text('Holiday'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.textContaining('Admin'), findsWidgets);
    });

    testWidgets('empty state', (tester) async {
      await pumpAnn(tester, []);

      expect(find.text('No announcements'), findsOneWidget);
    });

    testWidgets('the owner can remove one, after confirming', (tester) async {
      final (source, _) = await pumpAnn(tester, [ann('1', manage: true)]);

      await tester.tap(find.byTooltip('Announcement options'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(source.calls, ['delete:1']);
      expect(find.text('Exam schedule'), findsNothing);
    });

    testWidgets('people without rights see no remove menu or post button', (tester) async {
      await pumpAnn(tester, [ann('1')]);

      expect(find.byTooltip('Announcement options'), findsNothing);
      expect(find.text('Post'), findsNothing);
    });

    testWidgets('staff can pin; moderators cannot', (tester) async {
      await pumpAnn(tester, [], canCreate: true, isStaff: true);
      await tester.tap(find.text('Post'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Pin to the top'), findsOneWidget);
    });

    testWidgets('a moderator sees no pin switch and only their rooms', (tester) async {
      await pumpAnn(
        tester,
        [],
        canCreate: true,
        isStaff: false,
        rooms: const [PublishRoom(id: 'clubs', name: 'Clubs')],
      );
      await tester.tap(find.text('Post'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Pin to the top'), findsNothing);
      expect(find.text('Whole campus'), findsNothing);
    });

    testWidgets('posting needs a title', (tester) async {
      await pumpAnn(tester, [], canCreate: true, isStaff: true);
      await tester.tap(find.text('Post'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      await tester.ensureVisible(find.text('Post announcement'));
      await tester.tap(find.text('Post announcement'));
      await tester.pump();

      expect(find.text('Give the announcement a title.'), findsOneWidget);
    });

    for (final screen in smallScreens) {
      testWidgets('page and sheet fit: ${screen.name}', (tester) async {
        await pumpAnn(
          tester,
          [
            Announcement(
              id: 'x', title: 'A long announcement title ' * 6, body: 'text ' * 300,
              createdAt: DateTime(2026), organizerLabel: 'Faculty', roomId: 'dept-cs',
              pinned: true, canManage: true,
            ),
          ],
          screen: screen,
          canCreate: true,
          isStaff: true,
        );
        expectNoLayoutErrors(tester);

        await tester.tap(find.text('Post'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        tester.view.viewInsets = FakeViewPadding(bottom: screen.size.height * 0.4);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expectNoLayoutErrors(tester);
      });
    }

    for (final screen in smallScreens) {
      testWidgets('banner fits: ${screen.name}', (tester) async {
        useScreen(tester, screen);
        await tester.pumpWidget(
          themedApp(
            Scaffold(
              body: AnnouncementBanner(
                item: ann('1', title: 'A very long announcement title ' * 5, pinned: true),
                onTap: () {},
                onDismiss: () {},
              ),
            ),
            textScale: screen.textScale,
          ),
        );

        expectNoLayoutErrors(tester);
      });
    }

    testWidgets('banner: tap opens, X dismisses', (tester) async {
      var opened = 0;
      var dismissed = 0;
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            body: AnnouncementBanner(
              item: ann('1'),
              onTap: () => opened++,
              onDismiss: () => dismissed++,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Exam schedule'));
      await tester.tap(find.byTooltip('Dismiss'));

      expect(opened, 1);
      expect(dismissed, 1);
    });
  });
}
