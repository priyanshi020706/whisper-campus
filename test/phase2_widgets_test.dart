import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/core/theme/app_theme.dart';
import 'package:whisper_campus/core/widgets/create_poll_sheet.dart';
import 'package:whisper_campus/core/widgets/poll_card.dart';
import 'package:whisper_campus/models/chat_extras.dart';
import 'package:whisper_campus/models/poll.dart';
import 'package:whisper_campus/pages/rooms/chat_parts.dart';

import 'test_helpers.dart';

PollData poll({
  bool multiple = false,
  DateTime? closes,
  List<(String, int, bool)> options = const [
    ('Pizza', 3, false),
    ('Burger', 1, true),
  ],
  int? voters,
}) {
  return PollData(
    pollId: 'p1',
    targetId: 'm1',
    question: 'Pizza or burger?',
    allowsMultiple: multiple,
    closesAt: closes,
    totalVoters: voters ?? options.fold(0, (sum, o) => sum + o.$2),
    options: [
      for (var i = 0; i < options.length; i++)
        PollOption(
          id: 'o$i',
          label: options[i].$1,
          votes: options[i].$2,
          mine: options[i].$3,
        ),
    ],
  );
}

PollDraft? _draft;

void main() {
  group('PollData', () {
    test('fromMap reads the server json', () {
      final data = PollData.fromMap({
        'poll_id': 'p',
        'target_id': 't',
        'question': 'Q?',
        'allows_multiple': true,
        'closes_at': '2026-11-20T10:00:00+00:00',
        'total_voters': 5,
        'options': [
          {'option_id': 'a', 'label': 'A', 'votes': 3, 'mine': true},
          {'option_id': 'b', 'label': 'B', 'votes': 2, 'mine': false},
        ],
      });

      expect(data.allowsMultiple, isTrue);
      expect(data.options.length, 2);
      expect(data.myOptionIds, {'a'});
      expect(data.hasVoted, isTrue);
      expect(data.closesAt, isNotNull);
    });

    test('shares are fractions of voters and survive zero votes', () {
      final p = poll();
      expect(p.shareOf(p.options[0]), 0.75);
      expect(poll(options: const [('A', 0, false), ('B', 0, false)]).shareOf(
        poll(options: const [('A', 0, false)]).options.first,
      ), 0);
    });

    test('isClosed uses the closing time', () {
      final now = DateTime(2026, 11, 17, 12);
      expect(poll(closes: now.subtract(const Duration(minutes: 1))).isClosed(now: now), isTrue);
      expect(poll(closes: now.add(const Duration(minutes: 1))).isClosed(now: now), isFalse);
      expect(poll().isClosed(now: now), isFalse);
    });

    test('withMyVotes changes counts by the difference (single choice)', () {
      final before = poll(); // I voted Burger
      final after = before.withMyVotes({'o0'}); // switch to Pizza

      expect(after.options[0].votes, 4);
      expect(after.options[1].votes, 0);
      expect(after.totalVoters, 4);
      expect(after.options[0].mine, isTrue);
      expect(after.options[1].mine, isFalse);
    });

    test('withMyVotes: first vote adds a voter, clearing removes one', () {
      final fresh = poll(options: const [('A', 2, false), ('B', 0, false)]);
      final voted = fresh.withMyVotes({'o1'});
      expect(voted.totalVoters, 3);
      final cleared = voted.withMyVotes({});
      expect(cleared.totalVoters, 2);
      expect(cleared.options[1].votes, 0);
    });

    test('withMyVotes handles several answers in a multiple-choice poll', () {
      final p = poll(
        multiple: true,
        options: const [('A', 1, true), ('B', 1, false), ('C', 0, false)],
        voters: 2,
      );
      final next = p.withMyVotes({'o0', 'o2'});

      expect(next.options.map((o) => o.votes), [1, 1, 1]);
      expect(next.totalVoters, 2); // still one voter, me
    });

    test('closing label', () {
      final now = DateTime(2026, 11, 17, 12);
      expect(pollClosingLabel(null, now: now), '');
      expect(pollClosingLabel(now.subtract(const Duration(seconds: 1)), now: now), 'Poll closed');
      expect(pollClosingLabel(now.add(const Duration(minutes: 30)), now: now), 'closes in 30m');
      expect(pollClosingLabel(now.add(const Duration(hours: 5)), now: now), 'closes in 5h');
      expect(pollClosingLabel(now.add(const Duration(days: 1, hours: 2)), now: now), 'closes in 1 day');
      expect(pollClosingLabel(now.add(const Duration(days: 3, hours: 2)), now: now), 'closes in 3 days');
    });

    test('draft validation', () {
      expect(validatePollDraft('', ['a', 'b']), 'Write a question.');
      expect(validatePollDraft('q', ['a']), 'Add at least two choices.');
      expect(validatePollDraft('q', ['a', ' ', '']), 'Add at least two choices.');
      expect(validatePollDraft('q', ['a', 'A']), 'Each choice must be different.');
      expect(validatePollDraft('q', ['a', 'x' * 81]), 'Each choice can be at most 80 characters.');
      expect(validatePollDraft('q', List.generate(7, (i) => 'c$i')), 'A poll can have up to 6 choices.');
      expect(validatePollDraft('q' * 201, ['a', 'b']), isNotNull);
      expect(validatePollDraft('q', ['a', 'b']), isNull);
    });
  });

  group('ChatExtras', () {
    test('parses links, reactions and polls', () {
      final extras = ChatExtras.fromJson({
        'links': [
          {'message_id': 'm2', 'reply_to': 'm1', 'quoted_content': 'first'},
          {'message_id': 'm9', 'reply_to': null, 'quoted_content': null},
        ],
        'reactions': [
          {'message_id': 'm1', 'emoji': '😂', 'count': 2, 'mine': false},
          {'message_id': 'm1', 'emoji': '👍', 'count': 1, 'mine': true},
        ],
        'polls': [
          {
            'poll_id': 'p', 'target_id': 'm3', 'question': 'Q', 'allows_multiple': false,
            'total_voters': 0, 'options': [],
          },
        ],
      });

      expect(extras.links['m2']?.replyTo, 'm1');
      expect(extras.links['m2']?.quotedContent, 'first');
      expect(extras.links.containsKey('m9'), isFalse); // deleted original
      expect(extras.reactions['m1']!.map((r) => r.emoji), ['👍', '😂']); // picker order
      expect(extras.polls['m3']?.question, 'Q');
    });

    test('bad or empty json gives empty extras', () {
      expect(ChatExtras.fromJson(null).links, isEmpty);
      expect(ChatExtras.fromJson('nope').reactions, isEmpty);
      expect(ChatExtras.fromJson({}).polls, isEmpty);
    });

    test('choosing a reaction adds it', () {
      final next = reactionsAfterChoosing(const [], '👍');
      expect(next.single.emoji, '👍');
      expect(next.single.mine, isTrue);
      expect(next.single.count, 1);
    });

    test('choosing a different one moves my reaction', () {
      final current = [
        const ReactionCount(emoji: '👍', count: 1, mine: true),
        const ReactionCount(emoji: '😂', count: 2, mine: false),
      ];
      final next = reactionsAfterChoosing(current, '😂');

      expect(next.map((r) => r.emoji), ['😂']); // the 👍 vanished at zero
      expect(next.single.count, 3);
      expect(next.single.mine, isTrue);
    });

    test('choosing mine again, or null, removes it', () {
      final current = [const ReactionCount(emoji: '❤️', count: 2, mine: true)];

      final again = reactionsAfterChoosing(current, '❤️');
      expect(again.single.count, 1);
      expect(again.single.mine, isFalse);

      final cleared = reactionsAfterChoosing(current, null);
      expect(cleared.single.count, 1);
      expect(cleared.single.mine, isFalse);
    });
  });

  group('PollCard', () {
    Future<void> pumpPoll(
      WidgetTester tester,
      PollData data, {
      Future<String?> Function(List<String>)? onVote,
      Screen screen = const Screen('default', Size(360, 740), 1.0),
      bool showQuestion = true,
    }) async {
      useScreen(tester, screen);
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: PollCard(
                poll: data,
                showQuestion: showQuestion,
                onVote: onVote ?? (_) async => null,
              ),
            ),
          ),
          textScale: screen.textScale,
        ),
      );
    }

    testWidgets('shows question, choices, percentages and totals', (tester) async {
      await pumpPoll(tester, poll());

      expect(find.text('Pizza or burger?'), findsOneWidget);
      expect(find.text('Pizza'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('4 votes'), findsOneWidget);
    });

    testWidgets('tapping a choice votes and shows it at once', (tester) async {
      List<String>? sent;
      await pumpPoll(tester, poll(), onVote: (ids) async {
        sent = ids;
        return null;
      });

      await tester.tap(find.text('Pizza'));
      await tester.pump();

      expect(sent, ['o0']);
      expect(find.text('100%'), findsOneWidget); // all 4 voters now picked Pizza
    });

    testWidgets('a refused vote is undone and explained', (tester) async {
      await pumpPoll(tester, poll(), onVote: (_) async => 'This poll has closed.');

      await tester.tap(find.text('Pizza'));
      await tester.pump();
      await tester.pump();

      expect(find.text('75%'), findsOneWidget); // back to the server's numbers
      expect(find.text('This poll has closed.'), findsOneWidget);
    });

    testWidgets('tapping my own choice again removes my vote', (tester) async {
      List<String>? sent;
      await pumpPoll(tester, poll(), onVote: (ids) async {
        sent = ids;
        return null;
      });

      await tester.tap(find.text('Burger')); // already mine
      await tester.pump();

      expect(sent, isEmpty);
    });

    testWidgets('multiple choice sends the whole selection', (tester) async {
      List<String>? sent;
      await pumpPoll(
        tester,
        poll(multiple: true, options: const [('A', 1, true), ('B', 0, false)], voters: 1),
        onVote: (ids) async {
          sent = ids;
          return null;
        },
      );

      await tester.tap(find.text('B'));
      await tester.pump();

      expect(sent!.toSet(), {'o0', 'o1'});
      expect(find.text('multiple answers', findRichText: true), findsNothing);
    });

    testWidgets('a closed poll cannot be voted in', (tester) async {
      var votes = 0;
      await pumpPoll(
        tester,
        poll(closes: DateTime.now().subtract(const Duration(minutes: 5))),
        onVote: (_) async {
          votes++;
          return null;
        },
      );

      await tester.tap(find.text('Pizza'));
      await tester.pump();

      expect(votes, 0);
      expect(find.textContaining('Poll closed'), findsOneWidget);
    });

    for (final screen in smallScreens) {
      testWidgets('long text does not overflow: ${screen.name}', (tester) async {
        await pumpPoll(
          tester,
          PollData(
            pollId: 'p',
            targetId: 't',
            question: 'A really long poll question ' * 8,
            allowsMultiple: true,
            closesAt: DateTime.now().add(const Duration(days: 3)),
            totalVoters: 1234,
            options: [
              for (var i = 0; i < 6; i++)
                PollOption(
                  id: 'o$i',
                  label: 'A long choice label that keeps going and going $i ' * 3,
                  votes: i * 100,
                  mine: i == 2,
                ),
            ],
          ),
          screen: screen,
        );

        expectNoLayoutErrors(tester);
      });
    }
  });

  group('CreatePollSheet', () {
    Future<PollDraft?> openSheet(
      WidgetTester tester, {
      Screen screen = const Screen('default', Size(360, 740), 1.0),
      Future<void> Function()? act,
    }) async {
      useScreen(tester, screen);
      _draft = null;
      PollDraft? result;
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => _draft = await showCreatePollSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
          textScale: screen.textScale,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(); // the route builds; its animation starts next frame
      await tester.pump(const Duration(milliseconds: 600));
      if (act != null) await act();
      await tester.pump(const Duration(milliseconds: 500));
      return result;
    }

    testWidgets('creates a draft', (tester) async {
      await openSheet(tester, act: () async {
        await tester.enterText(find.widgetWithText(TextField, 'Question'), 'Lunch?');
        await tester.enterText(find.widgetWithText(TextField, 'Choice 1'), 'Pizza');
        await tester.enterText(find.widgetWithText(TextField, 'Choice 2'), 'Burger');
        await tester.tap(find.text('1 day'));
        await tester.pump();
        await tester.ensureVisible(find.text('Create poll').last);
        await tester.tap(find.text('Create poll').last);
        await tester.pump(const Duration(milliseconds: 500));
      });
      final draft = _draft;
      expect(draft, isNotNull);
      expect(draft!.question, 'Lunch?');
      expect(draft.options, ['Pizza', 'Burger']);
      expect(draft.allowsMultiple, isFalse);
      expect(draft.closesAt, isNotNull); // "1 day" was chosen
      expect(draft.closesAt!.isAfter(DateTime.now().add(const Duration(hours: 23))), isTrue);
    });

    testWidgets('refuses a poll with one choice', (tester) async {
      await openSheet(tester, act: () async {
        await tester.enterText(find.widgetWithText(TextField, 'Question'), 'Lunch?');
        await tester.enterText(find.widgetWithText(TextField, 'Choice 1'), 'Pizza');
        await tester.ensureVisible(find.text('Create poll').last);
        await tester.tap(find.text('Create poll').last);
        await tester.pump();
      });

      expect(find.text('Add at least two choices.'), findsOneWidget);
    });

    testWidgets('choices can be added up to six and removed down to two', (tester) async {
      await openSheet(tester, act: () async {
        for (var i = 0; i < 6; i++) {
          final add = find.text('Add choice');
          if (add.evaluate().isEmpty) break;
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pump();
        }
        expect(find.textContaining('Choice '), findsNWidgets(6));
        expect(find.text('Add choice'), findsNothing);
        for (var i = 0; i < 6; i++) {
          final remove = find.byTooltip('Remove choice');
          if (remove.evaluate().isEmpty) break;
          await tester.ensureVisible(remove.first);
          await tester.tap(remove.first);
          await tester.pump();
        }
        expect(find.textContaining('Choice '), findsNWidgets(2));
      });
    });

    for (final screen in smallScreens) {
      testWidgets('no overflow with the keyboard open: ${screen.name}', (tester) async {
        await openSheet(tester, screen: screen, act: () async {
          tester.view.viewInsets = FakeViewPadding(bottom: screen.size.height * 0.4);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expectNoLayoutErrors(tester);
        });
      });
    }
  });

  group('chat parts', () {
    for (final screen in smallScreens) {
      testWidgets('quote, chips, banner do not overflow: ${screen.name}', (tester) async {
        useScreen(tester, screen);
        await tester.pumpWidget(
          themedApp(
            Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    QuoteBlock(
                      author: 'A very long author name that never ends ' * 2,
                      content: 'quoted message text ' * 30,
                      accent: Colors.purple,
                      textColor: Colors.black,
                    ),
                    ReactionChips(
                      reactions: [
                        for (final e in reactionEmojis)
                          ReactionCount(emoji: e, count: 1234, mine: e == '❤️'),
                      ],
                      onTap: (_) {},
                      textColor: Colors.black,
                      accent: Colors.purple,
                    ),
                    ReplyBanner(
                      author: 'A very long author name ' * 4,
                      content: 'text ' * 80,
                      onClose: () {},
                    ),
                  ],
                ),
              ),
            ),
            textScale: screen.textScale,
          ),
        );

        expectNoLayoutErrors(tester);
      });
    }

    testWidgets('tapping a reaction chip reports the emoji', (tester) async {
      String? tapped;
      await tester.pumpWidget(
        themedApp(
          Scaffold(
            body: ReactionChips(
              reactions: const [ReactionCount(emoji: '😂', count: 2, mine: false)],
              onTap: (e) => tapped = e,
              textColor: Colors.black,
              accent: Colors.purple,
            ),
          ),
        ),
      );

      await tester.tap(find.text('😂'));

      expect(tapped, '😂');
    });

    testWidgets('actions sheet: pick a reaction or an action', (tester) async {
      useScreen(tester, const Screen('default', Size(360, 740), 1.0));
      String? reacted;
      var replied = false;
      await tester.pumpWidget(
        themedApp(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showMessageActions(
                  context,
                  currentReaction: '👍',
                  onReact: (e) => reacted = e,
                  actions: [MessageAction(Icons.reply, 'Reply', () => replied = true)],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Reply'), findsOneWidget);
      await tester.tap(find.text('😮'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(reacted, '😮');

      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Reply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(replied, isTrue);
    });

    for (final screen in smallScreens) {
      testWidgets('actions sheet fits: ${screen.name}', (tester) async {
        useScreen(tester, screen);
        await tester.pumpWidget(
          themedApp(
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showMessageActions(
                    context,
                    currentReaction: null,
                    onReact: (_) {},
                    actions: [
                      for (final label in ['Reply', 'Report message', 'Remove for everyone'])
                        MessageAction(Icons.circle, label, () {}),
                    ],
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            textScale: screen.textScale,
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));

        expectNoLayoutErrors(tester);
      });
    }
  });

  test('themes still build', () {
    expect(AppTheme.dark.useMaterial3, isTrue);
  });
}
