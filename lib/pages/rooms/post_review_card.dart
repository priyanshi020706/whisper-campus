import 'package:flutter/material.dart';

import '../../core/widgets/post_preview.dart';

/// One post waiting for a moderator: who and where, the post as students will
/// see it, and clear Reject / Approve buttons.
class PostReviewCard extends StatelessWidget {
  const PostReviewCard({
    super.key,
    required this.heading,
    this.subheading,
    this.submittedAt,
    required this.content,
    this.imageUrl,
    required this.busy,
    required this.onReject,
    required this.onApprove,
  });

  /// Usually the room name.
  final String heading;

  /// Usually the author label.
  final String? subheading;
  final DateTime? submittedAt;
  final String content;
  final String? imageUrl;
  final bool busy;
  final VoidCallback onReject;
  final VoidCallback onApprove;

  String? _when() {
    final time = submittedAt?.toLocal();
    if (time == null) return null;
    final dd = time.day.toString().padLeft(2, '0');
    final mm = time.month.toString().padLeft(2, '0');
    final hh = time.hour.toString().padLeft(2, '0');
    final min = time.minute.toString().padLeft(2, '0');
    return '$dd/$mm/${time.year} · $hh:$min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final when = _when();
    final meta = [
      if (subheading != null && subheading!.isNotEmpty) subheading!,
      ?when,
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.hourglass_top_rounded,
                  size: 18,
                  color: colors.tertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    heading,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            if (meta.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                meta,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            const Divider(height: 24),
            PostPreview(content: content, imageUrl: imageUrl),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : onReject,
                    icon: const Icon(Icons.close_rounded),
                    label: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy ? null : onApprove,
                    icon: busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: const Text('Approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
