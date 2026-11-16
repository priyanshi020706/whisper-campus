import 'poll.dart';

/// Emojis a message can be reacted to with. The server accepts exactly these.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// How many people reacted to a message with one emoji.
class ReactionCount {
  const ReactionCount({
    required this.emoji,
    required this.count,
    required this.mine,
  });

  final String emoji;
  final int count;

  /// The signed-in user chose this emoji.
  final bool mine;
}

/// The message another message replies to.
class ReplyLink {
  const ReplyLink({required this.replyTo, this.quotedContent});

  final String replyTo;

  /// Start of the quoted message, as the server kept it.
  final String? quotedContent;
}

/// Replies, reactions and polls for a batch of chat messages, keyed by message
/// id. Comes from `get_chat_message_extras`.
class ChatExtras {
  const ChatExtras({
    this.links = const {},
    this.reactions = const {},
    this.polls = const {},
  });

  factory ChatExtras.fromJson(Object? json) {
    if (json is! Map) return const ChatExtras();
    final map = Map<String, dynamic>.from(json);

    final links = <String, ReplyLink>{};
    for (final raw in List<Map<String, dynamic>>.from(
      (map['links'] as List?) ?? const [],
    )) {
      final replyTo = raw['reply_to'] as String?;
      if (replyTo == null) continue;
      links[raw['message_id'] as String] = ReplyLink(
        replyTo: replyTo,
        quotedContent: raw['quoted_content'] as String?,
      );
    }

    final reactions = <String, List<ReactionCount>>{};
    for (final raw in List<Map<String, dynamic>>.from(
      (map['reactions'] as List?) ?? const [],
    )) {
      reactions
          .putIfAbsent(raw['message_id'] as String, () => [])
          .add(
            ReactionCount(
              emoji: raw['emoji'] as String,
              count: (raw['count'] as num).toInt(),
              mine: raw['mine'] == true,
            ),
          );
    }
    // Keep a stable, familiar order: the emoji order of the picker.
    for (final list in reactions.values) {
      list.sort(
        (a, b) => reactionEmojis
            .indexOf(a.emoji)
            .compareTo(reactionEmojis.indexOf(b.emoji)),
      );
    }

    final polls = {
      for (final poll in PollData.listFrom(map['polls'])) poll.targetId: poll,
    };
    return ChatExtras(links: links, reactions: reactions, polls: polls);
  }

  final Map<String, ReplyLink> links;
  final Map<String, List<ReactionCount>> reactions;
  final Map<String, PollData> polls;
}

/// Applies the user's own reaction change to a message's reactions straight
/// away: picking [emoji] again, or picking null, removes it.
List<ReactionCount> reactionsAfterChoosing(
  List<ReactionCount> current,
  String? emoji,
) {
  final previous = current.where((r) => r.mine).map((r) => r.emoji).firstOrNull;
  final removing = emoji == null || emoji == previous;
  final next = <ReactionCount>[];
  for (final r in current) {
    var count = r.count;
    var mine = r.mine;
    if (r.mine) {
      count -= 1;
      mine = false;
    }
    if (!removing && r.emoji == emoji) {
      count += 1;
      mine = true;
    }
    if (count > 0) next.add(ReactionCount(emoji: r.emoji, count: count, mine: mine));
  }
  if (!removing && !next.any((r) => r.emoji == emoji)) {
    next.add(ReactionCount(emoji: emoji, count: 1, mine: true));
  }
  next.sort(
    (a, b) => reactionEmojis
        .indexOf(a.emoji)
        .compareTo(reactionEmojis.indexOf(b.emoji)),
  );
  return next;
}
