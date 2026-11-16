import 'package:flutter/material.dart';

import '../../core/utils/error_message.dart';
import '../../core/widgets/post_card_tile.dart';
import '../../models/post_card.dart';
import '../../services/saved_posts_controller.dart';

/// The user's bookmarked posts, newest bookmark first.
class SavedPostsPage extends StatefulWidget {
  const SavedPostsPage({
    super.key,
    required this.saved,
    required this.onOpenComments,
    this.imageUrlLoader = defaultImageUrlLoader,
  });

  final SavedPostsController saved;

  /// Opens the comments for a post (the feed's comments sheet).
  final void Function(PostCardData post) onOpenComments;
  final ImageUrlLoader imageUrlLoader;

  @override
  State<SavedPostsPage> createState() => _SavedPostsPageState();
}

class _SavedPostsPageState extends State<SavedPostsPage> {
  List<PostCardData> _posts = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final posts = await widget.saved.loadPosts();
      if (!mounted) return;
      setState(() {
        _posts = posts;
        _loading = false;
      });
    } catch (error) {
      debugPrint('SAVED POSTS LOAD ERROR: $error');
      if (!mounted) return;
      setState(() {
        _error = friendlyError(error);
        _loading = false;
      });
    }
  }

  Future<void> _remove(PostCardData post) async {
    final index = _posts.indexOf(post);
    setState(() => _posts = [..._posts]..remove(post));
    final message = await widget.saved.toggle(post.kind, post.postId);
    if (message != null && mounted) {
      // Put it back: the server did not remove the bookmark.
      setState(() => _posts = [..._posts]..insert(
        index.clamp(0, _posts.length),
        post,
      ));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved posts'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          : _posts.isEmpty
          ? const _EmptySaved()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              itemCount: _posts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final post = _posts[index];
                return PostCardTile(
                  key: ValueKey(postKey(post.kind, post.postId)),
                  post: post,
                  imageUrlLoader: widget.imageUrlLoader,
                  onOpen: () => widget.onOpenComments(post),
                  actions: [
                    TextButton.icon(
                      onPressed: () => _remove(post),
                      icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
                      label: const Text('Remove'),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _EmptySaved extends StatelessWidget {
  const _EmptySaved();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border_rounded, size: 48, color: colors.outline),
            const SizedBox(height: 12),
            Text(
              'Nothing saved yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Tap the bookmark on a post to keep it here.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
