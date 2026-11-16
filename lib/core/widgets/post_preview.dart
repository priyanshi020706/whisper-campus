import 'package:flutter/material.dart';

import '../../models/post_content.dart';

/// Readable view of a stored post: title, tag chips, body and image. Used where
/// a post is shown outside the feed (moderator review, "my pending posts"), so
/// the raw stored text (`WC_POST_V1:{...}`) is never shown to people.
class PostPreview extends StatelessWidget {
  const PostPreview({
    super.key,
    required this.content,
    this.imageUrl,
    this.maxBodyLines,
  });

  /// The stored post text, encoded or plain.
  final String content;
  final String? imageUrl;

  /// Cuts the body after this many lines. Null shows all of it.
  final int? maxBodyLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final post = PostContent.decode(content);
    final hasText =
        post.title.isNotEmpty || post.body.isNotEmpty || post.tags.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (post.title.isNotEmpty)
          Text(
            post.title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
        if (post.tags.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [for (final tag in post.tags) _TagChip(tag: tag)],
          ),
        ],
        if (post.body.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            post.body,
            maxLines: maxBodyLines,
            overflow: maxBodyLines == null ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.35),
          ),
        ],
        if (!hasText && imageUrl == null)
          Text(
            'No text in this post.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        if (imageUrl != null) ...[
          const SizedBox(height: 12),
          _PreviewImage(url: imageUrl!),
        ],
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lower = tag.toLowerCase();
    final alert = lower == 'urgent' || lower == 'doubt/query';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: alert ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          tag,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: alert
                ? colors.onErrorContainer
                : colors.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// The whole image is shown (not cropped) so a moderator sees what students
/// will see. Tap to open it full screen.
class _PreviewImage extends StatelessWidget {
  const _PreviewImage({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Material(
        color: colors.surfaceContainerHighest,
        child: InkWell(
          hoverColor: Colors.transparent,
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => Dialog.fullscreen(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: InteractiveViewer(
                      child: Image.network(url, fit: BoxFit.contain),
                    ),
                  ),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.topRight,
                      child: IconButton.filledTonal(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: SizedBox(
              width: double.infinity,
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
