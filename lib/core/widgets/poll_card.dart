import 'package:flutter/material.dart';

import '../../models/poll.dart';

/// A poll with tappable choices and live results. Used under feed posts and
/// inside chat messages.
///
/// Tapping a choice shows the vote straight away and sends it with [onVote],
/// which returns null on success or a message to show if the server refused.
class PollCard extends StatefulWidget {
  const PollCard({
    super.key,
    required this.poll,
    required this.onVote,
    this.showQuestion = true,
    this.textColor,
    this.accentColor,
  });

  final PollData poll;
  final Future<String?> Function(List<String> optionIds) onVote;
  final bool showQuestion;

  /// Overrides for use on a coloured chat bubble.
  final Color? textColor;
  final Color? accentColor;

  @override
  State<PollCard> createState() => _PollCardState();
}

class _PollCardState extends State<PollCard> {
  PollData? _local;
  bool _busy = false;

  PollData get _poll => _local ?? widget.poll;

  @override
  void didUpdateWidget(PollCard old) {
    super.didUpdateWidget(old);
    // Fresh data from the server replaces the optimistic copy.
    if (!identical(old.poll, widget.poll)) _local = null;
  }

  Future<void> _choose(PollOption option) async {
    final poll = _poll;
    if (_busy || poll.isClosed()) return;
    final current = poll.myOptionIds;
    final Set<String> next;
    if (poll.allowsMultiple) {
      next = current.contains(option.id)
          ? (current.toSet()..remove(option.id))
          : (current.toSet()..add(option.id));
    } else {
      next = current.contains(option.id) ? <String>{} : {option.id};
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _local = poll.withMyVotes(next);
    });
    final message = await widget.onVote(next.toList());
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (message != null) _local = null;
    });
    if (message != null) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final poll = _poll;
    final closed = poll.isClosed();
    final text = widget.textColor ?? colors.onSurface;
    final accent = widget.accentColor ?? colors.primary;
    final muted = text.withValues(alpha: 0.7);
    final footer = [
      '${poll.totalVoters} ${poll.totalVoters == 1 ? 'vote' : 'votes'}',
      if (poll.allowsMultiple) 'multiple answers',
      pollClosingLabel(poll.closesAt),
    ].where((part) => part.isNotEmpty).join(' · ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showQuestion) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.poll_outlined, size: 18, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  poll.question,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        for (final option in poll.options) ...[
          _OptionRow(
            option: option,
            share: poll.shareOf(option),
            multiple: poll.allowsMultiple,
            disabled: closed,
            textColor: text,
            accent: accent,
            onTap: () => _choose(option),
          ),
          const SizedBox(height: 6),
        ],
        Text(
          footer,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(color: muted),
        ),
      ],
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.share,
    required this.multiple,
    required this.disabled,
    required this.textColor,
    required this.accent,
    required this.onTap,
  });

  final PollOption option;
  final double share;
  final bool multiple;
  final bool disabled;
  final Color textColor;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (share * 100).round();
    final icon = multiple
        ? (option.mine ? Icons.check_box : Icons.check_box_outline_blank)
        : (option.mine ? Icons.radio_button_checked : Icons.radio_button_off);
    return Semantics(
      button: true,
      selected: option.mine,
      label: '${option.label}, $percent percent, ${option.votes} votes',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            // Result bar behind the row.
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: share.clamp(0.0, 1.0),
                  child: ColoredBox(
                    color: accent.withValues(alpha: option.mine ? 0.28 : 0.14),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: option.mine
                        ? accent
                        : textColor.withValues(alpha: 0.25),
                  ),
                ),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: disabled ? null : onTap,
                hoverColor: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(icon, size: 18, color: option.mine ? accent : textColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          option.label,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: textColor,
                            fontWeight: option.mine
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$percent%',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
