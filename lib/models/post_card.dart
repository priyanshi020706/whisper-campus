/// A post as returned by the card RPCs (saved posts, search results): enough to
/// show a readable preview and open the post.
class PostCardData {
  const PostCardData({
    required this.kind,
    required this.postId,
    required this.roomId,
    required this.authorLabel,
    required this.content,
    required this.createdAt,
    this.avatarSeed,
    this.imagePath,
    this.likeCount = 0,
    this.commentCount = 0,
    this.likedByMe = false,
    this.isMine = false,
    this.editedAt,
    this.savedAt,
  });

  factory PostCardData.fromMap(Map<String, dynamic> map) {
    DateTime? time(Object? v) => v == null ? null : DateTime.tryParse('$v');
    return PostCardData(
      kind: map['post_kind'] as String,
      postId: map['post_id'] as String,
      roomId: (map['room_id'] as String?) ?? '',
      authorLabel: (map['author_label'] as String?) ?? 'Anonymous',
      avatarSeed: map['avatar_seed'] as String?,
      content: (map['content'] as String?) ?? '',
      imagePath: map['image_path'] as String?,
      createdAt: time(map['created_at']) ?? DateTime.now(),
      likeCount: (map['like_count'] as num?)?.toInt() ?? 0,
      commentCount: (map['comment_count'] as num?)?.toInt() ?? 0,
      likedByMe: map['liked_by_me'] == true,
      isMine: map['is_mine'] == true,
      editedAt: time(map['edited_at']),
      savedAt: time(map['saved_at']),
    );
  }

  /// `post` (unofficial) or `official_post`.
  final String kind;
  final String postId;
  final String roomId;
  final String authorLabel;
  final String? avatarSeed;
  final String content;
  final String? imagePath;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final bool likedByMe;
  final bool isMine;
  final DateTime? editedAt;
  final DateTime? savedAt;

  bool get isOfficial => kind == 'official_post';

  /// Storage bucket that holds this post's image.
  String get imageBucket =>
      isOfficial ? 'official-post-images' : 'campus-post-images';
}

/// Identifies a post across both campus modes, for sets and maps.
String postKey(String kind, String postId) => '$kind:$postId';
