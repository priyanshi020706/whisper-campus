/// One choice in a poll, with the current vote count.
class PollOption {
  const PollOption({
    required this.id,
    required this.label,
    required this.votes,
    required this.mine,
  });

  factory PollOption.fromMap(Map<String, dynamic> map) => PollOption(
    id: map['option_id'] as String,
    label: (map['label'] as String?) ?? '',
    votes: (map['votes'] as num?)?.toInt() ?? 0,
    mine: map['mine'] == true,
  );

  final String id;
  final String label;
  final int votes;
  final bool mine;
}

/// A poll attached to a post or a chat message. Votes are anonymous: only counts
/// and the signed-in user's own choices are known.
class PollData {
  const PollData({
    required this.pollId,
    required this.targetId,
    required this.question,
    required this.allowsMultiple,
    required this.options,
    required this.totalVoters,
    this.closesAt,
  });

  factory PollData.fromMap(Map<String, dynamic> map) {
    final options = [
      for (final o in List<Map<String, dynamic>>.from(
        (map['options'] as List?) ?? const [],
      ))
        PollOption.fromMap(o),
    ];
    final closes = map['closes_at'];
    return PollData(
      pollId: map['poll_id'] as String,
      targetId: map['target_id'] as String,
      question: (map['question'] as String?) ?? '',
      allowsMultiple: map['allows_multiple'] == true,
      options: options,
      totalVoters: (map['total_voters'] as num?)?.toInt() ?? 0,
      closesAt: closes == null ? null : DateTime.tryParse('$closes'),
    );
  }

  /// Parses a list of polls as the server returns it (json array).
  static List<PollData> listFrom(Object? json) => [
    for (final item in List<Map<String, dynamic>>.from(
      (json as List?) ?? const [],
    ))
      PollData.fromMap(item),
  ];

  final String pollId;
  final String targetId;
  final String question;
  final bool allowsMultiple;
  final List<PollOption> options;
  final int totalVoters;
  final DateTime? closesAt;

  bool isClosed({DateTime? now}) =>
      closesAt != null && !closesAt!.isAfter(now ?? DateTime.now());

  bool get hasVoted => options.any((o) => o.mine);

  Set<String> get myOptionIds => {
    for (final o in options)
      if (o.mine) o.id,
  };

  /// Share of voters who picked [option], 0 to 1.
  double shareOf(PollOption option) =>
      totalVoters == 0 ? 0 : (option.votes / totalVoters).clamp(0.0, 1.0);

  /// The poll as it will look once the user's choices are [selected]: counts
  /// change by the difference from the user's current choices. Used to show a
  /// vote straight away before the server confirms it.
  PollData withMyVotes(Set<String> selected) {
    final before = myOptionIds;
    final hadVoted = before.isNotEmpty;
    final willVote = selected.isNotEmpty;
    return PollData(
      pollId: pollId,
      targetId: targetId,
      question: question,
      allowsMultiple: allowsMultiple,
      closesAt: closesAt,
      totalVoters: totalVoters + (willVote ? 1 : 0) - (hadVoted ? 1 : 0),
      options: [
        for (final o in options)
          PollOption(
            id: o.id,
            label: o.label,
            mine: selected.contains(o.id),
            votes:
                o.votes +
                (selected.contains(o.id) ? 1 : 0) -
                (before.contains(o.id) ? 1 : 0),
          ),
      ],
    );
  }
}

/// What the user fills in to create a poll.
class PollDraft {
  const PollDraft({
    required this.question,
    required this.options,
    this.allowsMultiple = false,
    this.closesAt,
  });

  final String question;
  final List<String> options;
  final bool allowsMultiple;
  final DateTime? closesAt;
}

/// Why a poll draft cannot be created yet, or null when it is fine.
String? validatePollDraft(String question, List<String> options) {
  final q = question.trim();
  if (q.isEmpty) return 'Write a question.';
  if (q.length > 200) return 'The question is too long (200 characters max).';
  final cleaned = [
    for (final o in options)
      if (o.trim().isNotEmpty) o.trim(),
  ];
  if (cleaned.length < 2) return 'Add at least two choices.';
  if (cleaned.length > 6) return 'A poll can have up to 6 choices.';
  if (cleaned.any((o) => o.length > 80)) {
    return 'Each choice can be at most 80 characters.';
  }
  final lower = cleaned.map((o) => o.toLowerCase()).toList();
  if (lower.toSet().length != lower.length) {
    return 'Each choice must be different.';
  }
  return null;
}

/// "closes in 2h", "closes in 3 days", or "closed".
String pollClosingLabel(DateTime? closesAt, {DateTime? now}) {
  if (closesAt == null) return '';
  final current = now ?? DateTime.now();
  final left = closesAt.difference(current);
  if (left.isNegative || left == Duration.zero) return 'Poll closed';
  if (left.inMinutes < 60) {
    return 'closes in ${left.inMinutes < 1 ? 1 : left.inMinutes}m';
  }
  if (left.inHours < 24) return 'closes in ${left.inHours}h';
  final days = left.inDays;
  return 'closes in $days ${days == 1 ? 'day' : 'days'}';
}
