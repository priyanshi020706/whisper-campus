import 'package:flutter/material.dart';

import '../../models/chat_extras.dart';
import '../../models/room_message.dart';
import 'chat_parts.dart';

/// Name colours for other people's messages. They come from the app's own
/// palette (lavender, berry, teal, amber, and a soft indigo), so the chat looks
/// like the rest of Whisper Campus. One colour per sender, readable on both the
/// light and the dark chat background.
const _lightNameColors = [
  Color(0xFF5B3FB0), // deep lavender
  Color(0xFFAA4F83), // berry
  Color(0xFF187B75), // teal
  Color(0xFFA85A12), // amber
  Color(0xFF4150A8), // indigo
];

const _darkNameColors = [
  Color(0xFFB6A3FF), // lavender
  Color(0xFFF0A6CF), // berry
  Color(0xFF62DFD0), // mint
  Color(0xFFFFB66F), // amber
  Color(0xFFA9B6FF), // indigo
];

/// The same sender always gets the same colour. A moderator badge is not part
/// of the sender's identity.
Color chatSenderColor(String username, Brightness brightness) {
  final name = username.replaceAll(RegExp(r' \(Moderator\)$'), '');
  var hash = 0;
  for (final unit in name.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final palette = brightness == Brightness.dark
      ? _darkNameColors
      : _lightNameColors;
  return palette[hash % palette.length];
}

/// Surface and border for other people's bubbles, taken from the app's own
/// card style so the chat matches the rest of the screens in light and dark.
({Color color, Color border}) chatSurface(ThemeData theme) {
  final colors = theme.colorScheme;
  final card = theme.cardTheme;
  final shape = card.shape;
  final border = shape is RoundedRectangleBorder
      ? shape.side.color
      : colors.outlineVariant;
  return (color: card.color ?? colors.surfaceContainerHigh, border: border);
}

/// "Today", "Yesterday" or a date, for the separators between days.
String chatDayLabel(DateTime day, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final today = DateTime(current.year, current.month, current.day);
  final date = DateTime(day.year, day.month, day.day);
  final difference = today.difference(date).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  final dd = date.day.toString().padLeft(2, '0');
  final mm = date.month.toString().padLeft(2, '0');
  return '$dd/$mm/${date.year}';
}

bool isSameChatDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Whether [message] starts a new run of messages from one sender. Runs are
/// broken by a different sender, a new day, or a pause of over five minutes.
bool startsChatGroup(RoomMessage? previous, RoomMessage message) {
  if (previous == null) return true;
  if (previous.isMine != message.isMine) return true;
  if (!isSameChatDay(
    previous.createdAt.toLocal(),
    message.createdAt.toLocal(),
  )) {
    return true;
  }
  if (message.createdAt.difference(previous.createdAt).inMinutes.abs() >= 5) {
    return true;
  }
  final a = previous.authorId ?? previous.authorUsername;
  final b = message.authorId ?? message.authorUsername;
  return a != b;
}

/// Centered "Today / Yesterday / date" chip between days.
class ChatDaySeparator extends StatelessWidget {
  const ChatDaySeparator({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final surface = chatSurface(theme);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface.color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: surface.border),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: colors.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The message a bubble replies to, as shown inside the bubble.
class ChatQuote {
  const ChatQuote({required this.author, required this.content, this.onTap});

  /// Null when the original is no longer loaded.
  final String? author;
  final String content;
  final VoidCallback? onTap;
}

/// One message bubble. My messages sit on the right in the theme's strong
/// colour; everyone else's sit on the left on a neutral surface with the
/// sender's name in their own colour.
///
/// The "..." menu (report, remove) is in the name row of a sender's first
/// bubble. Long-press (touch) or right-click (desktop) opens the same menu on
/// any bubble, so messages inside a group can be reported too.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    required this.startsGroup,
    required this.timeLabel,
    this.menuItems = const [],
    this.onMenuSelected,
    this.onNameTap,
    this.onNameLongPress,
    this.quote,
    this.reactions = const [],
    this.onReactionTap,
    this.pollBuilder,
    this.onActions,
    this.onSwipeReply,
  });

  final RoomMessage message;

  /// First bubble of a run: shows the sender name and the small tail corner.
  final bool startsGroup;
  final String timeLabel;

  /// Entries for the menu as (value, label). Empty disables the menu.
  final List<(String, String)> menuItems;
  final ValueChanged<String>? onMenuSelected;
  final VoidCallback? onNameTap;
  final VoidCallback? onNameLongPress;

  /// The message this one replies to.
  final ChatQuote? quote;
  final List<ReactionCount> reactions;
  final void Function(String emoji)? onReactionTap;

  /// Builds a poll to show instead of the message text. Receives the text and
  /// accent colours that suit this bubble.
  final Widget Function(Color textColor, Color accent)? pollBuilder;

  /// Long-press (touch) or right-click (desktop): opens the message actions.
  /// When null the plain "..." menu opens instead.
  final VoidCallback? onActions;

  /// Swipe right on the bubble to reply.
  final VoidCallback? onSwipeReply;

  List<PopupMenuEntry<String>> _menuEntries() => [
    for (final item in menuItems)
      PopupMenuItem<String>(value: item.$1, child: Text(item.$2)),
  ];

  Future<void> _openMenu(BuildContext context, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: _menuEntries(),
    );
    if (selected != null) onMenuSelected?.call(selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final mine = message.isMine;

    final surface = chatSurface(theme);
    final background = mine ? colors.primary : surface.color;
    final textColor = mine ? colors.onPrimary : colors.onSurface;
    final metaColor = mine
        ? colors.onPrimary.withValues(alpha: 0.75)
        : colors.onSurfaceVariant;

    const big = Radius.circular(16);
    const tail = Radius.circular(4);
    final radius = BorderRadius.only(
      topLeft: !mine && startsGroup ? tail : big,
      topRight: mine && startsGroup ? tail : big,
      bottomLeft: big,
      bottomRight: big,
    );

    final maxWidth = (MediaQuery.sizeOf(context).width * 0.78).clamp(
      220.0,
      520.0,
    );
    final hasMenu = menuItems.isNotEmpty;

    final nameRow = Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        children: [
          Flexible(
            child: InkWell(
              onTap: onNameTap,
              onLongPress: onNameLongPress,
              hoverColor: Colors.transparent,
              child: Text(
                message.authorUsername,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: chatSenderColor(
                    message.authorUsername,
                    theme.brightness,
                  ),
                  fontWeight: FontWeight.w700,
                  decoration: onNameTap != null
                      ? TextDecoration.underline
                      : null,
                ),
              ),
            ),
          ),
          if (hasMenu) ...[
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: 'Message options',
              padding: EdgeInsets.zero,
              iconSize: 18,
              icon: Icon(Icons.more_horiz, color: metaColor),
              splashRadius: 14,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 20),
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: WidgetStatePropertyAll(Size(24, 20)),
                padding: WidgetStatePropertyAll(EdgeInsets.zero),
              ),
              onSelected: onMenuSelected,
              itemBuilder: (_) => _menuEntries(),
            ),
          ],
        ],
      ),
    );

    final bubble = DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: radius,
        border: mine ? null : Border.all(color: surface.border),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 5),
        child: _fit(
          pollBuilder != null,
          maxWidth,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!mine && startsGroup) nameRow,
              if (quote != null)
                QuoteBlock(
                  author: quote!.author,
                  content: quote!.content,
                  accent: mine ? colors.onPrimary : colors.primary,
                  textColor: textColor,
                  onTap: quote!.onTap,
                ),
              if (pollBuilder != null)
                pollBuilder!(textColor, mine ? colors.onPrimary : colors.primary)
              else
                Text(
                  message.content,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: textColor,
                    height: 1.3,
                  ),
                ),
              if (reactions.isNotEmpty && onReactionTap != null)
                ReactionChips(
                  reactions: reactions,
                  onTap: onReactionTap!,
                  textColor: textColor,
                  accent: mine ? colors.onPrimary : colors.primary,
                ),
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  timeLabel,
                  style: theme.textTheme.labelSmall?.copyWith(color: metaColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        top: startsGroup ? 8 : 2,
        left: mine ? 48 : 0,
        right: mine ? 0 : 48,
      ),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: GestureDetector(
            onLongPressStart: onActions != null
                ? (_) => onActions!()
                : hasMenu
                ? (details) => _openMenu(context, details.globalPosition)
                : null,
            onSecondaryTapDown: onActions != null
                ? (_) => onActions!()
                : hasMenu
                ? (details) => _openMenu(context, details.globalPosition)
                : null,
            onHorizontalDragEnd: onSwipeReply == null
                ? null
                : (details) {
                    if ((details.primaryVelocity ?? 0) > 300) onSwipeReply!();
                  },
            child: bubble,
          ),
        ),
      ),
    );
  }
}

/// Polls need the full bubble width; ordinary messages shrink to their text.
Widget _fit(bool fullWidth, double maxWidth, Widget child) => fullWidth
    ? SizedBox(width: maxWidth - 24, child: child)
    : IntrinsicWidth(child: child);
