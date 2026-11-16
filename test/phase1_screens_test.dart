import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/core/theme/app_theme.dart';
import 'package:whisper_campus/core/widgets/edit_dialogs.dart';
import 'package:whisper_campus/models/notification_prefs.dart';
import 'package:whisper_campus/models/post_card.dart';
import 'package:whisper_campus/models/post_content.dart';
import 'package:whisper_campus/models/room_activity.dart';
import 'package:whisper_campus/pages/saved/saved_posts_page.dart';
import 'package:whisper_campus/pages/settings/notification_settings_page.dart';
import 'package:whisper_campus/services/notification_prefs_controller.dart';
import 'package:whisper_campus/services/room_activity_controller.dart';
import 'package:whisper_campus/services/room_activity_service.dart';
import 'package:whisper_campus/services/saved_posts_controller.dart';

import 'test_helpers.dart';

class _PrefsSource implements NotificationPrefsSource {
  NotificationPrefs stored = const NotificationPrefs();
  @override
  Future<NotificationPrefs> fetch() async => stored;
  @override
  Future<void> save(NotificationPrefs prefs, NotificationPrefs previous) async {
    stored = prefs;
  }
}

class _RoomSource implements RoomActivitySource {
  _RoomSource(this.data);
  Map<String, RoomActivity> data;
  @override
  Future<Map<String, RoomActivity>> fetch(String mode) async => data;
  @override
  Future<void> setPinned(String roomId, String mode, bool pinned) async {}
  @override
  Future<void> setMuted(String roomId, String mode, bool muted, {int? minutes}) async {
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

class _SavedSource implements SavedPostsSource {
  _SavedSource(this.posts);
  List<PostCardData> posts;
  Object? loadError;
  @override
  Future<Set<String>> fetchIds(String kind) async =>
      {for (final p in posts) if (p.kind == kind) p.postId};
  @override
  Future<List<PostCardData>> fetchPosts() async {
    final error = loadError;
    if (error != null) throw error;
    return posts;
  }

  @override
  Future<void> setSaved(String kind, String postId, bool saved) async {
    if (!saved) posts = [for (final p in posts) if (p.postId != postId) p];
  }
}

PostCardData card(
  String id, {
  String content = 'plain post text',
  String kind = 'post',
  String room = 'dept-cs',
}) => PostCardData(
  kind: kind,
  postId: id,
  roomId: room,
  authorLabel: 'Anon18dac4',
  content: content,
  createdAt: DateTime(2026, 11, 16, 20),
  likeCount: 12,
  commentCount: 3,
);

void main() {
  group('NotificationSettingsPage', () {
    for (final screen in smallScreens) {
      testWidgets('no overflow: ${screen.name}', (tester) async {
        useScreen(tester, screen);
        final prefs = NotificationPrefsController(source: _PrefsSource());
        final rooms = RoomActivityController(
          source: _RoomSource({
            'dept-cs': RoomActivity(roomId: 'dept-cs', muted: true),
            'dept-ee': RoomActivity(roomId: 'dept-ee', muted: true),
            'a-very-long-club-room-name-that-keeps-going': RoomActivity(
              roomId: 'a-very-long-club-room-name-that-keeps-going',
              muted: true,
            ),
          }),
          refreshEvery: const Duration(hours: 1),
        );
        addTearDown(prefs.dispose);
        addTearDown(rooms.dispose);
        await tester.pumpWidget(
          themedApp(
            NotificationSettingsPage(prefs: prefs, rooms: rooms),
            textScale: screen.textScale,
          ),
        );
        await tester.pump();
        await tester.pump();

        expectNoLayoutErrors(tester);
        // Scroll through the whole page to build every row.
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();
        expectNoLayoutErrors(tester);
      });
    }

    testWidgets('flipping a switch saves it', (tester) async {
      useScreen(tester, smallScreens.first);
      final source = _PrefsSource();
      final prefs = NotificationPrefsController(source: source);
      final rooms = RoomActivityController(
        source: _RoomSource({}),
        refreshEvery: const Duration(hours: 1),
      );
      addTearDown(prefs.dispose);
      addTearDown(rooms.dispose);
      await tester.pumpWidget(
        themedApp(NotificationSettingsPage(prefs: prefs, rooms: rooms)),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Likes'));
      await tester.pump();

      expect(source.stored.likes, isFalse);
      expect(prefs.prefs.likes, isFalse);
    });

    testWidgets('a muted room can be unmuted from the list', (tester) async {
      useScreen(tester, smallScreens.first);
      final prefs = NotificationPrefsController(source: _PrefsSource());
      final rooms = RoomActivityController(
        source: _RoomSource({
          'dept-cs': RoomActivity(roomId: 'dept-cs', muted: true),
        }),
        refreshEvery: const Duration(hours: 1),
      );
      addTearDown(prefs.dispose);
      addTearDown(rooms.dispose);
      await rooms.refresh();
      await tester.pumpWidget(
        themedApp(NotificationSettingsPage(prefs: prefs, rooms: rooms)),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();

      expect(find.text('Computer Science & Engg'), findsOneWidget);
      await tester.tap(find.text('Unmute'));
      await tester.pump();

      expect(rooms.isMuted('dept-cs'), isFalse);
    });

    testWidgets('empty muted list explains how to mute', (tester) async {
      useScreen(tester, smallScreens.first);
      final prefs = NotificationPrefsController(source: _PrefsSource());
      final rooms = RoomActivityController(
        source: _RoomSource({}),
        refreshEvery: const Duration(hours: 1),
      );
      addTearDown(prefs.dispose);
      addTearDown(rooms.dispose);
      await tester.pumpWidget(
        themedApp(NotificationSettingsPage(prefs: prefs, rooms: rooms)),
      );
      await tester.pump();
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pump();

      expect(find.textContaining('No muted rooms'), findsOneWidget);
    });
  });

  group('SavedPostsPage', () {
    Future<void> pumpSaved(
      WidgetTester tester,
      _SavedSource source, {
      Screen screen = const Screen('default', Size(360, 740), 1.0),
      void Function(PostCardData)? onOpen,
    }) async {
      useScreen(tester, screen);
      final saved = SavedPostsController(source: source);
      addTearDown(saved.dispose);
      await saved.refresh();
      await tester.pumpWidget(
        themedApp(
          SavedPostsPage(
            saved: saved,
            onOpenComments: onOpen ?? (_) {},
            imageUrlLoader: (_) async => null,
          ),
          textScale: screen.textScale,
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('shows readable posts, not stored text', (tester) async {
      final encoded = const PostContent(
        title: 'Lab timing',
        tags: ['Urgent'],
        body: 'Is the lab open on Sunday?',
      ).encode();
      await pumpSaved(tester, _SavedSource([card('1', content: encoded)]));

      expect(find.text('Lab timing'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
      expect(find.textContaining('WC_POST_V1'), findsNothing);
      expect(find.textContaining('Computer Science'), findsOneWidget); // room name
    });

    for (final screen in smallScreens) {
      testWidgets('long content does not overflow: ${screen.name}', (tester) async {
        final long = PostContent(
          title: 'A very long title that keeps going and going for a while',
          tags: ['Doubt/Query', 'Urgent', 'Academic', 'Tea'],
          body: 'word ' * 200,
        ).encode();
        await pumpSaved(
          tester,
          _SavedSource([card('1', content: long), card('2', kind: 'official_post')]),
          screen: screen,
        );

        expectNoLayoutErrors(tester);
        await tester.drag(find.byType(ListView), const Offset(0, -2000));
        await tester.pump();
        expectNoLayoutErrors(tester);
      });
    }

    testWidgets('empty state', (tester) async {
      await pumpSaved(tester, _SavedSource([]));

      expect(find.text('Nothing saved yet'), findsOneWidget);
    });

    testWidgets('load failure shows a retry', (tester) async {
      final source = _SavedSource([card('1')])..loadError = StateError('x');
      await pumpSaved(tester, source);

      expect(find.text('Something went wrong. Please try again.'), findsOneWidget);
      source.loadError = null;
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(find.text('plain post text'), findsOneWidget);
    });

    testWidgets('Remove takes the post out of the list', (tester) async {
      await pumpSaved(tester, _SavedSource([card('1'), card('2', content: 'second')]));

      await tester.tap(find.text('Remove').first);
      await tester.pump();
      await tester.pump();

      expect(find.text('plain post text'), findsNothing);
      expect(find.text('second'), findsOneWidget);
    });

    testWidgets('tapping a post opens its comments', (tester) async {
      PostCardData? opened;
      await pumpSaved(tester, _SavedSource([card('7')]), onOpen: (p) => opened = p);

      await tester.tap(find.text('plain post text'));

      expect(opened?.postId, '7');
    });
  });

  group('edit dialogs', () {
    Future<String?> openEdit(
      WidgetTester tester,
      String initial, {
      Screen screen = const Screen('default', Size(360, 740), 1.0),
      bool hasImage = false,
      Future<void> Function()? act,
    }) async {
      useScreen(tester, screen);
      String? result;
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showEditPostDialog(
                  context,
                  initialContent: initial,
                  hasImage: hasImage,
                ),
                child: const Text('open'),
              ),
            ),
          ),
          textScale: screen.textScale,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));
      if (act != null) await act();
      await tester.pump(const Duration(milliseconds: 400));
      return result;
    }

    testWidgets('editing an encoded post keeps its tags and image-free body', (tester) async {
      final initial = const PostContent(
        title: 'Old title',
        tags: ['Tea'],
        body: 'old body',
      ).encode();
      String? result;
      await tester.runAsync(() async {});
      useScreen(tester, const Screen('default', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showEditPostDialog(
                  context,
                  initialContent: initial,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.widgetWithText(TextField, 'Old title'), 'New title');
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 400));

      final decoded = PostContent.decode(result!);
      expect(decoded.title, 'New title');
      expect(decoded.tags, ['Tea']);
      expect(decoded.body, 'old body');
    });

    testWidgets('a plain legacy post stays plain', (tester) async {
      String? result;
      useScreen(tester, const Screen('default', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showEditPostDialog(
                  context,
                  initialContent: 'just some text',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.widgetWithText(TextField, 'just some text'), 'changed text');
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(result, 'changed text');
    });

    for (final screen in smallScreens) {
      testWidgets('edit dialog does not overflow: ${screen.name}', (tester) async {
        final initial = PostContent(
          title: 'A long title ' * 5,
          tags: ['Tea', 'Urgent'],
          body: 'body ' * 100,
        ).encode();
        await openEdit(tester, initial, screen: screen);

        expectNoLayoutErrors(tester);
        expect(find.text('Save'), findsOneWidget);
      });
    }

    testWidgets('an empty post is refused with a message', (tester) async {
      await openEdit(
        tester,
        const PostContent(title: 't', tags: [], body: '').encode(),
        act: () async {
          await tester.enterText(find.widgetWithText(TextField, 't'), '');
          await tester.tap(find.text('Save'));
          await tester.pump();
        },
      );

      expect(find.text('Add some text or keep the image.'), findsOneWidget);
    });

    test('validation rules', () {
      const empty = EditedPost(title: '', tags: [], body: '');
      expect(validateEditedPost(empty, wasEncoded: true, hasImage: false), isNotNull);
      expect(validateEditedPost(empty, wasEncoded: true, hasImage: true), isNull);

      final tooLong = EditedPost(title: 't', tags: const [], body: 'x' * 3000);
      expect(validateEditedPost(tooLong, wasEncoded: true, hasImage: false),
          'That is too long. Shorten it a little.');

      const fine = EditedPost(title: 'Title', tags: ['Tea'], body: 'ok');
      expect(validateEditedPost(fine, wasEncoded: true, hasImage: false), isNull);
    });

    test('canStillEdit allows ten minutes', () {
      final now = DateTime(2026, 11, 17, 12);
      expect(canStillEdit(now.subtract(const Duration(minutes: 9)), now: now), isTrue);
      expect(canStillEdit(now.subtract(const Duration(minutes: 11)), now: now), isFalse);
      expect(canStillEdit(now.subtract(const Duration(hours: 3)), now: now), isFalse);
    });

    testWidgets('comment dialog returns trimmed text and refuses empty', (tester) async {
      String? result;
      useScreen(tester, const Screen('default', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showEditCommentDialog(
                  context,
                  initialText: 'old',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));

      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('A comment cannot be empty.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '  new text  ');
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(result, 'new text');
    });
  });

  test('app themes build', () {
    expect(AppTheme.light.useMaterial3, isTrue);
    expect(AppTheme.dark.useMaterial3, isTrue);
  });
}
