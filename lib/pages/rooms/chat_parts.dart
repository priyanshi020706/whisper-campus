import 'package:flutter/material.dart';

import '../../models/chat_extras.dart';

/// The quoted message shown at the top of a reply bubble.
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({
    super.key,
    required this.author,
    required this.content,
    required this.accent,
    required this.textColor,
    this.onTap,
  });

  /// Null when the original message is no longer loaded.
  final String? author;
  final String content;
  final Color accent;
  final Color textColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: textColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.transparent,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: accent),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          author ?? 'Earlier message',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          content,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: textColor.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small emoji-with-count chips under a message. Tap one to react with it (or
/// to take your reaction back).
class ReactionChips extends StatelessWidget {
  const ReactionChips({
    super.key,
    required this.reactions,
    required this.onTap,
    required this.textColor,
    required this.accent,
  });

  final List<ReactionCount> reactions;
  final void Function(String emoji) onTap;
  final Color textColor;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final r in reactions)
            Semantics(
              button: true,
              label: '${r.emoji} ${r.count}${r.mine ? ', your reaction' : ''}',
              child: Material(
                color: r.mine
                    ? accent.withValues(alpha: 0.25)
                    : textColor.withValues(alpha: 0.1),
                shape: StadiumBorder(
                  side: BorderSide(
                    color: r.mine ? accent : Colors.transparent,
                  ),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onTap(r.emoji),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(r.emoji, style: const TextStyle(fontSize: 14)),
                        const SizedBox(width: 4),
                        Text(
                          '${r.count}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: textColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bar above the message box showing which message is being replied to.
class ReplyBanner extends StatelessWidget {
  const ReplyBanner({
    super.key,
    required this.author,
    required this.content,
    required this.onClose,
  });

  final String author;
  final String content;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $author',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Cancel reply',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

/// One action in the message actions sheet.
class MessageAction {
  const MessageAction(this.icon, this.label, this.onSelected);

  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// Bottom sheet opened by long-pressing a message: pick an emoji reaction, or
/// choose an action such as Reply or Report.
Future<void> showMessageActions(
  BuildContext context, {
  required String? currentReaction,
  required void Function(String emoji) onReact,
  required List<MessageAction> actions,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final emoji in reactionEmojis)
                  IconButton.filledTonal(
                    tooltip: 'React $emoji',
                    isSelected: emoji == currentReaction,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      backgroundColor: emoji == currentReaction
                          ? Theme.of(sheetContext).colorScheme.primaryContainer
                          : null,
                    ),
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      onReact(emoji);
                    },
                    icon: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          for (final action in actions)
            ListTile(
              leading: Icon(action.icon),
              title: Text(action.label),
              onTap: () {
                Navigator.of(sheetContext).pop();
                action.onSelected();
              },
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
