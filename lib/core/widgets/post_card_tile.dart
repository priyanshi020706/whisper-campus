import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/campus_department.dart';
import '../../models/post_card.dart';
import 'post_preview.dart';

/// Resolves a signed URL for a post image. Overridable so tests need no network.
typedef ImageUrlLoader = Future<String?> Function(PostCardData post);

Future<String?> defaultImageUrlLoader(PostCardData post) async {
  final path = post.imagePath;
  if (path == null || path.isEmpty) return null;
  try {
    return await Supabase.instance.client.storage
        .from(post.imageBucket)
        .createSignedUrl(path, 3600);
  } catch (_) {
    return null;
  }
}

/// A post shown as a card outside the feed (saved posts, search results): where
/// it is from, a readable preview, counts and optional actions.
class PostCardTile extends StatefulWidget {
  const PostCardTile({
    super.key,
    required this.post,
    required this.onOpen,
    this.imageUrlLoader = defaultImageUrlLoader,
    this.actions = const [],
  });

  final PostCardData post;
  final VoidCallback onOpen;
  final ImageUrlLoader imageUrlLoader;

  /// Buttons shown after the like and comment counts.
  final List<Widget> actions;

  @override
  State<PostCardTile> createState() => _PostCardTileState();
}

class _PostCardTileState extends State<PostCardTile> {
  String? _imageUrl;

  @override
  void initState() {
    super.initState();
    widget.imageUrlLoader(widget.post).then((url) {
      if (mounted && url != null) setState(() => _imageUrl = url);
    });
  }

  String _when(DateTime time) {
    final local = time.toLocal();
    final dd = local.day.toString().padLeft(2, '0');
    final mm = local.month.toString().padLeft(2, '0');
    return '$dd/$mm/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final post = widget.post;
    final meta = [
      roomDisplayName(post.roomId),
      post.authorLabel,
      _when(post.createdAt),
      if (post.editedAt != null) 'edited',
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        hoverColor: Colors.transparent,
        onTap: widget.onOpen,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                meta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              PostPreview(
                content: post.content,
                imageUrl: _imageUrl,
                maxBodyLines: 6,
              ),
              const SizedBox(height: 10),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 14,
                runSpacing: 4,
                children: [
                  _Count(icon: Icons.favorite_border, value: post.likeCount),
                  _Count(
                    icon: Icons.mode_comment_outlined,
                    value: post.commentCount,
                  ),
                  ...widget.actions,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.icon, required this.value});

  final IconData icon;
  final int value;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Text('$value', style: TextStyle(color: color)),
      ],
    );
  }
}
