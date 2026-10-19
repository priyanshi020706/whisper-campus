class ProfileStats {
  const ProfileStats({
    this.posts = 0,
    this.likesReceived = 0,
    this.comments = 0,
  });

  final int posts;
  final int likesReceived;
  final int comments;

  factory ProfileStats.fromRow(Map<String, dynamic> row) => ProfileStats(
    posts: (row['post_count'] as num?)?.toInt() ?? 0,
    likesReceived: (row['like_count'] as num?)?.toInt() ?? 0,
    comments: (row['comment_count'] as num?)?.toInt() ?? 0,
  );
}

class ProfileActivity {
  const ProfileActivity({
    required this.type,
    required this.id,
    required this.postId,
    required this.scopeName,
    required this.activityContent,
    required this.postContent,
    required this.postAuthorName,
    required this.createdAt,
    required this.likeCount,
    required this.commentCount,
    this.scopeId,
    this.imagePath,
    this.imageUrl,
    this.likedByMe = false,
  });

  final String type;
  final String id;
  final String postId;
  final String? scopeId;
  final String scopeName;
  final String activityContent;
  final String postContent;
  final String postAuthorName;
  final DateTime createdAt;
  final int likeCount;
  final int commentCount;
  final String? imagePath;
  final String? imageUrl;
  final bool likedByMe;

  bool get isComment => type == 'comment';

  factory ProfileActivity.fromRow(
    Map<String, dynamic> row, {
    required bool official,
  }) => ProfileActivity(
    type: row['activity_type'] as String,
    id: row['activity_id'] as String,
    postId: row['post_id'] as String,
    scopeId: official
        ? row['department_code'] as String?
        : row['room_id'] as String?,
    scopeName: row['scope_name'] as String? ?? 'Campus-wide',
    activityContent: row['activity_content'] as String? ?? '',
    postContent: row['post_content'] as String? ?? '',
    postAuthorName: row['post_author_name'] as String? ?? 'Student',
    createdAt: DateTime.parse(row['created_at'] as String),
    likeCount: (row['like_count'] as num?)?.toInt() ?? 0,
    commentCount: (row['comment_count'] as num?)?.toInt() ?? 0,
    imagePath: row['image_path'] as String?,
    likedByMe: row['liked_by_me'] as bool? ?? false,
  );

  ProfileActivity copyWith({
    String? imageUrl,
    int? likeCount,
    int? commentCount,
    bool? likedByMe,
  }) => ProfileActivity(
    type: type,
    id: id,
    postId: postId,
    scopeId: scopeId,
    scopeName: scopeName,
    activityContent: activityContent,
    postContent: postContent,
    postAuthorName: postAuthorName,
    createdAt: createdAt,
    likeCount: likeCount ?? this.likeCount,
    commentCount: commentCount ?? this.commentCount,
    imagePath: imagePath,
    imageUrl: imageUrl ?? this.imageUrl,
    likedByMe: likedByMe ?? this.likedByMe,
  );
}
