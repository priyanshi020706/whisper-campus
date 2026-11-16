import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/core/theme/app_theme.dart';
import 'package:whisper_campus/models/room_message.dart';
import 'package:whisper_campus/models/chat_extras.dart';
import 'package:whisper_campus/models/poll.dart';
import 'package:whisper_campus/core/widgets/poll_card.dart';
import 'package:whisper_campus/pages/rooms/chat_bubble.dart';
import 'test_helpers.dart';

RoomMessage message({
  String id = 'm',
  String user = 'Anon1',
  bool mine = false,
  String text = 'hello',
  String time = '2026-11-16T14:00:00+00:00',
  String? authorId,
}) => RoomMessage(
  id: id,
  roomId: 'general',
  authorUsername: user,
  authorId: authorId,
  content: text,
  createdAt: DateTime.parse(time),
  isMine: mine,
);

void main() {
  group('startsChatGroup', () {
    test('first message starts a group', () {
      expect(startsChatGroup(null, message()), isTrue);
    });

    test('same sender within minutes continues the group', () {
      final a = message(time: '2026-11-16T14:00:00+00:00');
      final b = message(id: 'n', time: '2026-11-16T14:02:00+00:00');

      expect(startsChatGroup(a, b), isFalse);
    });

    test('a pause of five minutes starts a new group', () {
      final a = message(time: '2026-11-16T14:00:00+00:00');
      final b = message(id: 'n', time: '2026-11-16T14:06:00+00:00');

      expect(startsChatGroup(a, b), isTrue);
    });

    test('a different sender starts a new group', () {
      expect(startsChatGroup(message(), message(user: 'Anon2')), isTrue);
    });

    test('my message after someone else starts a group', () {
      expect(startsChatGroup(message(), message(mine: true)), isTrue);
    });
  });

  group('chatDayLabel', () {
    final now = DateTime(2026, 11, 16, 20);

    test('today and yesterday', () {
      expect(chatDayLabel(DateTime(2026, 11, 16, 1), now: now), 'Today');
      expect(chatDayLabel(DateTime(2026, 11, 15, 23), now: now), 'Yesterday');
    });

    test('older days show the date', () {
      expect(chatDayLabel(DateTime(2026, 10, 3), now: now), '03/10/2026');
    });
  });

  group('chatSenderColor', () {
    test('is stable for one sender and ignores the moderator badge', () {
      expect(
        chatSenderColor('Anon4fece0', Brightness.light),
        chatSenderColor('Anon4fece0 (Moderator)', Brightness.light),
      );
    });

    test('differs between light and dark themes for readability', () {
      expect(
        chatSenderColor('Anon18dac4', Brightness.light),
        isNot(chatSenderColor('Anon18dac4', Brightness.dark)),
      );
    });
  });

  group('ChatBubble', () {
    Future<void> pump(
      WidgetTester tester,
      RoomMessage msg, {
      required ThemeData theme,
      bool startsGroup = true,
      List<(String, String)> menu = const [],
    }) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            // The real chat list scrolls; the test font is also very wide.
            body: SingleChildScrollView(
              child: ChatBubble(
                message: msg,
                startsGroup: startsGroup,
                timeLabel: '19:47',
                menuItems: menu,
              ),
            ),
          ),
        ),
      );
    }

    for (final entry in {'light': AppTheme.light, 'dark': AppTheme.dark}.entries) {
      testWidgets('my message sits on the right (${entry.key})', (tester) async {
        await pump(tester, message(mine: true, text: 'mine'), theme: entry.value);

        expect(tester.takeException(), isNull);
        final right = tester.getTopRight(find.text('mine')).dx;
        expect(right, greaterThan(300));
        expect(find.text('Anon1'), findsNothing);
      });

      testWidgets('their message sits on the left with a name (${entry.key})', (
        tester,
      ) async {
        await pump(tester, message(text: 'theirs'), theme: entry.value);

        expect(tester.takeException(), isNull);
        expect(tester.getTopLeft(find.text('theirs')).dx, lessThan(100));
        expect(find.text('Anon1'), findsOneWidget);
      });
    }

    testWidgets('name is hidden inside a group', (tester) async {
      await pump(tester, message(), theme: AppTheme.light, startsGroup: false);

      expect(find.text('Anon1'), findsNothing);
    });

    testWidgets('long text wraps without overflow', (tester) async {
      await pump(
        tester,
        message(text: 'word ' * 120, mine: true),
        theme: AppTheme.light,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('menu shows when items are given', (tester) async {
      await pump(
        tester,
        message(),
        theme: AppTheme.light,
        menu: const [('report', 'Report message')],
      );
      await tester.tap(find.byTooltip('Message options'));
      await tester.pumpAndSettle();

      expect(find.text('Report message'), findsOneWidget);
    });

    testWidgets('long press opens the menu even inside a group', (tester) async {
      String? chosen;
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ChatBubble(
              message: message(text: 'grouped'),
              startsGroup: false,
              timeLabel: '19:47',
              menuItems: const [('report', 'Report message')],
              onMenuSelected: (value) => chosen = value,
            ),
          ),
        ),
      );

      await tester.longPress(find.text('grouped'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report message'));
      await tester.pumpAndSettle();

      expect(chosen, 'report');
    });

    testWidgets('my bubble and their bubble use different colours', (
      tester,
    ) async {
      Color bubbleColor() {
        final box = tester.widgetList<DecoratedBox>(
          find.descendant(
            of: find.byType(ChatBubble),
            matching: find.byType(DecoratedBox),
          ),
        ).first;
        return (box.decoration as BoxDecoration).color!;
      }

      await pump(tester, message(mine: true), theme: AppTheme.light);
      final mineColor = bubbleColor();
      await pump(tester, message(), theme: AppTheme.light);

      expect(bubbleColor(), isNot(mineColor));
    });
  });

  group('ChatBubble replies, reactions and polls', () {
    final pollData = PollData(
      pollId: 'p',
      targetId: 'm',
      question: 'Pizza or burger?',
      allowsMultiple: false,
      totalVoters: 3,
      options: const [
        PollOption(id: 'a', label: 'Pizza', votes: 2, mine: false),
        PollOption(id: 'b', label: 'Burger', votes: 1, mine: true),
      ],
    );

    Widget bubble({
      bool mine = false,
      ChatQuote? quote,
      List<ReactionCount> reactions = const [],
      bool withPoll = false,
      void Function(String)? onReactionTap,
      VoidCallback? onActions,
      VoidCallback? onSwipeReply,
      String text = 'hello',
    }) => ChatBubble(
      message: message(mine: mine, text: text),
      startsGroup: true,
      timeLabel: '19:47',
      quote: quote,
      reactions: reactions,
      onReactionTap: onReactionTap ?? (_) {},
      onActions: onActions,
      onSwipeReply: onSwipeReply,
      pollBuilder: withPoll
          ? (textColor, accent) => PollCard(
              poll: pollData,
              textColor: textColor,
              accentColor: accent,
              onVote: (_) async => null,
            )
          : null,
    );

    testWidgets('shows the quoted message, reactions and counts', (tester) async {
      useScreen(tester, const Screen('d', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            body: bubble(
              quote: const ChatQuote(author: 'Anon2', content: 'the original text'),
              reactions: const [
                ReactionCount(emoji: '👍', count: 3, mine: true),
                ReactionCount(emoji: '😂', count: 1, mine: false),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Anon2'), findsWidgets);
      expect(find.text('the original text'), findsOneWidget);
      expect(find.text('👍'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('a poll replaces the message text', (tester) async {
      useScreen(tester, const Screen('d', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(Scaffold(body: SingleChildScrollView(child: bubble(withPoll: true, text: '📊 Pizza or burger?')))),
      );

      expect(find.text('Pizza or burger?'), findsOneWidget); // the poll question
      expect(find.text('📊 Pizza or burger?'), findsNothing); // not the raw text
      expect(find.text('Pizza'), findsOneWidget);
      expect(find.text('67%'), findsOneWidget);
    });

    testWidgets('tapping a reaction reports the emoji', (tester) async {
      String? tapped;
      useScreen(tester, const Screen('d', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            body: bubble(
              reactions: const [ReactionCount(emoji: '❤️', count: 1, mine: false)],
              onReactionTap: (e) => tapped = e,
            ),
          ),
        ),
      );

      await tester.tap(find.text('❤️'));

      expect(tapped, '❤️');
    });

    testWidgets('long press opens the actions, swipe right replies', (tester) async {
      var actions = 0;
      var replies = 0;
      useScreen(tester, const Screen('d', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            body: bubble(onActions: () => actions++, onSwipeReply: () => replies++),
          ),
        ),
      );

      await tester.longPress(find.text('hello'));
      await tester.fling(find.text('hello'), const Offset(200, 0), 1000);
      await tester.pump(const Duration(milliseconds: 500));

      expect(actions, 1);
      expect(replies, 1);
    });

    testWidgets('a swipe left does not reply', (tester) async {
      var replies = 0;
      useScreen(tester, const Screen('d', Size(360, 740), 1.0));
      await tester.pumpWidget(
        themedApp(Scaffold(body: bubble(onSwipeReply: () => replies++))),
      );

      await tester.fling(find.text('hello'), const Offset(-200, 0), 1000);
      await tester.pump(const Duration(milliseconds: 500));

      expect(replies, 0);
    });

    for (final screen in smallScreens) {
      for (final mine in [false, true]) {
        testWidgets('everything at once fits: ${screen.name}, mine=$mine', (tester) async {
          useScreen(tester, screen);
          await tester.pumpWidget(
            themedApp(
              Scaffold(
                body: SingleChildScrollView(
                  child: bubble(
                    mine: mine,
                    quote: ChatQuote(author: 'Someone with a long name ' * 3, content: 'quoted ' * 60),
                    reactions: [
                      for (final e in reactionEmojis)
                        ReactionCount(emoji: e, count: 99, mine: e == '😮'),
                    ],
                    text: 'a long message ' * 40,
                  ),
                ),
              ),
              textScale: screen.textScale,
            ),
          );

          expectNoLayoutErrors(tester);
        });

        testWidgets('a poll bubble fits: ${screen.name}, mine=$mine', (tester) async {
          useScreen(tester, screen);
          await tester.pumpWidget(
            themedApp(
              Scaffold(
                body: SingleChildScrollView(
                  child: bubble(
                    mine: mine,
                    withPoll: true,
                    quote: const ChatQuote(author: 'A', content: 'quoted'),
                    reactions: const [ReactionCount(emoji: '👍', count: 12, mine: true)],
                  ),
                ),
              ),
              textScale: screen.textScale,
            ),
          );

          expectNoLayoutErrors(tester);
        });
      }
    }
  });
}
