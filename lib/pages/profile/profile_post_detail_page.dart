import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/widgets/campus_live_action.dart';
import '../../core/widgets/student_avatar.dart';
import '../../models/profile_activity.dart';
import '../../models/post_content.dart';

class ProfilePostDetailPage extends StatefulWidget {
  const ProfilePostDetailPage({
    super.key,
    required this.activity,
    required this.officialMode,
    this.currentUserAvatarSeed,
    this.onNavigateHome,
    this.onOpenLiveChat,
  });

  final ProfileActivity activity;
  final bool officialMode;
  final String? currentUserAvatarSeed;
  final VoidCallback? onNavigateHome;
  final VoidCallback? onOpenLiveChat;

  @override
  State<ProfilePostDetailPage> createState() => _ProfilePostDetailPageState();
}

class _ProfilePostDetailPageState extends State<ProfilePostDetailPage> {
  final _supabase = Supabase.instance.client;
  final _replyController = TextEditingController();
  late int _likeCount;
  late int _commentCount;
  late bool _likedByMe;
  List<Map<String, dynamic>> _replies = [];
  bool _loading = true;
  bool _sending = false;
  bool _liking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _likeCount = widget.activity.likeCount;
    _commentCount = widget.activity.commentCount;
    _likedByMe = widget.activity.likedByMe;
    _loadReplies();
  }

  @override
  void dispose() {
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _loadReplies() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _supabase.rpc(
        widget.officialMode
            ? 'get_official_post_replies'
            : 'get_post_replies_with_avatars',
        params: {'p_post_id': widget.activity.postId},
      );
      if (!mounted) return;
      setState(() {
        _replies = List<Map<String, dynamic>>.from(rows);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the comments. Pull down to retry.';
        _loading = false;
      });
      debugPrint('PROFILE POST REPLIES ERROR: $error');
    }
  }

  Future<void> _toggleLike() async {
    if (_liking) return;
    setState(() => _liking = true);
    try {
      if (widget.officialMode) {
        final rows = await _supabase.rpc(
          'toggle_official_post_like',
          params: {'p_post_id': widget.activity.postId},
        );
        final row = (rows as List).first as Map<String, dynamic>;
        if (!mounted) return;
        setState(() {
          _likeCount = (row['like_count'] as num).toInt();
          _likedByMe = row['liked_by_me'] as bool;
        });
      } else {
        if (_likedByMe) {
          await _supabase
              .from('post_likes')
              .delete()
              .eq('post_id', widget.activity.postId);
        } else {
          await _supabase.from('post_likes').insert({
            'post_id': widget.activity.postId,
          });
        }
        if (!mounted) return;
        setState(() {
          _likedByMe = !_likedByMe;
          _likeCount += _likedByMe ? 1 : -1;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update the like.')),
        );
      }
      debugPrint('PROFILE POST LIKE ERROR: $error');
    } finally {
      if (mounted) setState(() => _liking = false);
    }
  }

  Future<void> _sendReply() async {
    final content = _replyController.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _supabase
          .from(widget.officialMode ? 'official_post_replies' : 'post_replies')
          .insert({'post_id': widget.activity.postId, 'content': content});
      _replyController.clear();
      await _loadReplies();
      if (mounted) setState(() => _commentCount++);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send your comment.')),
        );
      }
      debugPrint('PROFILE POST REPLY ERROR: $error');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _timeLabel(DateTime date) {
    final local = date.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);
    if (difference.inMinutes < 1) return 'just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';
    return '${local.day}/${local.month}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activity = widget.activity;
    return Scaffold(
      appBar: AppBar(
        title: Text(activity.isComment ? 'Your comment' : 'Post'),
        actions: [
          IconButton(
            tooltip: 'Home',
            onPressed: widget.onNavigateHome,
            icon: const Icon(Icons.home_outlined),
          ),
          CampusLiveAction(
            active: false,
            onPressed: () => widget.onOpenLiveChat?.call(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadReplies,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                children: [
                  if (activity.isComment) ...[
                    _YourCommentCard(
                      content: activity.activityContent,
                      time: _timeLabel(activity.createdAt),
                      officialMode: widget.officialMode,
                      avatarSeed: widget.currentUserAvatarSeed,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Original post',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                  ],
                  _PostContextCard(
                    activity: activity,
                    officialMode: widget.officialMode,
                    avatarSeed: activity.isComment
                        ? null
                        : widget.currentUserAvatarSeed,
                    timeLabel: _timeLabel(activity.createdAt),
                    likeCount: _likeCount,
                    likedByMe: _likedByMe,
                    commentCount: _commentCount,
                    liking: _liking,
                    onLike: _toggleLike,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Comments',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    Card(
                      child: ListTile(
                        title: Text(_error!),
                        trailing: IconButton(
                          onPressed: _loadReplies,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ),
                    )
                  else if (_replies.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Text(
                          'No comments yet. Start the conversation.',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                    )
                  else
                    ..._replies.map(
                      (reply) => _ReplyTile(
                        author:
                            (reply[widget.officialMode
                                    ? 'author_name'
                                    : 'author_username']
                                as String?) ??
                            'Student',
                        content: reply['content'] as String? ?? '',
                        time: _timeLabel(
                          DateTime.parse(reply['created_at'] as String),
                        ),
                        officialMode: widget.officialMode,
                        avatarSeed: reply['avatar_seed'] as String?,
                      ),
                    ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyController,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      decoration: InputDecoration(
                        hintText: 'Write a comment…',
                        counterText: '',
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _sendReply(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Send comment',
                    onPressed: _sending ? null : _sendReply,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PostContextCard extends StatelessWidget {
  const _PostContextCard({
    required this.activity,
    required this.officialMode,
    this.avatarSeed,
    required this.timeLabel,
    required this.likeCount,
    required this.likedByMe,
    required this.commentCount,
    required this.liking,
    required this.onLike,
  });

  final ProfileActivity activity;
  final bool officialMode;
  final String? avatarSeed;
  final String timeLabel;
  final int likeCount;
  final bool likedByMe;
  final int commentCount;
  final bool liking;
  final VoidCallback onLike;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final postDisplayText = PostContent.decode(activity.postContent).displayText;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                officialMode
                    ? CircleAvatar(
                        backgroundColor: colors.primaryContainer,
                        foregroundColor: colors.onPrimaryContainer,
                        child: const Icon(Icons.school_rounded),
                      )
                    : StudentAvatar(seed: avatarSeed, size: 40),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        activity.postAuthorName,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        '${activity.scopeName} · $timeLabel',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                _ModeLabel(officialMode: officialMode),
              ],
            ),
            if (activity.imageUrl != null) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: Image.network(
                    activity.imageUrl!,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox(
                          height: 100,
                          child: Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        ),
                  ),
                ),
              ),
            ],
            if (postDisplayText.isNotEmpty) ...[
              const SizedBox(height: 13),
              Text(
                postDisplayText,
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(height: 1.45),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                IconButton(
                  tooltip: likedByMe ? 'Unlike post' : 'Like post',
                  onPressed: liking ? null : onLike,
                  icon: liking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          likedByMe ? Icons.favorite : Icons.favorite_border,
                          color: likedByMe ? colors.error : null,
                        ),
                ),
                Text('$likeCount'),
                const SizedBox(width: 18),
                const Icon(Icons.mode_comment_outlined, size: 19),
                const SizedBox(width: 6),
                Text('$commentCount'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _YourCommentCard extends StatelessWidget {
  const _YourCommentCard({
    required this.content,
    required this.time,
    required this.officialMode,
    this.avatarSeed,
  });

  final String content;
  final String time;
  final bool officialMode;
  final String? avatarSeed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.primaryContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                officialMode
                    ? Icon(Icons.mode_comment_outlined, size: 18, color: colors.primary)
                    : StudentAvatar(seed: avatarSeed, size: 28),
                const SizedBox(width: 8),
                Text(
                  'Your comment · $time',
                  style: Theme.of(context).textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _ModeLabel(officialMode: officialMode),
              ],
            ),
            const SizedBox(height: 9),
            Text(content, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _ReplyTile extends StatelessWidget {
  const _ReplyTile({
    required this.author,
    required this.content,
    required this.time,
    required this.officialMode,
    this.avatarSeed,
  });

  final String author;
  final String content;
  final String time;
  final bool officialMode;
  final String? avatarSeed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            officialMode
                ? CircleAvatar(
                    radius: 18,
                    backgroundColor: colors.secondaryContainer,
                    foregroundColor: colors.onSecondaryContainer,
                    child: const Icon(Icons.school_rounded, size: 18),
                  )
                : StudentAvatar(seed: avatarSeed, size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          author,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      Text(
                        time,
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(content, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeLabel extends StatelessWidget {
  const _ModeLabel({required this.officialMode});

  final bool officialMode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: officialMode
            ? colors.tertiaryContainer
            : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Text(
          officialMode ? 'Official' : 'Unofficial',
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
