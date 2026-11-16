/// Which kinds of notifications the user wants. Stored on the server so the
/// same choices apply on every device and to push messages.
class NotificationPrefs {
  const NotificationPrefs({
    this.likes = true,
    this.comments = true,
    this.chatReplies = true,
    this.events = true,
    this.announcements = true,
  });

  factory NotificationPrefs.fromMap(Map<String, dynamic> map) {
    bool flag(String key) => map[key] != false; // default on
    return NotificationPrefs(
      likes: flag('likes'),
      comments: flag('comments'),
      chatReplies: flag('chat_replies'),
      events: flag('events'),
      announcements: flag('announcements'),
    );
  }

  final bool likes;
  final bool comments;
  final bool chatReplies;
  final bool events;
  final bool announcements;

  NotificationPrefs copyWith({
    bool? likes,
    bool? comments,
    bool? chatReplies,
    bool? events,
    bool? announcements,
  }) {
    return NotificationPrefs(
      likes: likes ?? this.likes,
      comments: comments ?? this.comments,
      chatReplies: chatReplies ?? this.chatReplies,
      events: events ?? this.events,
      announcements: announcements ?? this.announcements,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationPrefs &&
      other.likes == likes &&
      other.comments == comments &&
      other.chatReplies == chatReplies &&
      other.events == events &&
      other.announcements == announcements;

  @override
  int get hashCode =>
      Object.hash(likes, comments, chatReplies, events, announcements);
}
