/// One chat message, built from either a history row or a live broadcast.
class RoomMessage {
  const RoomMessage({
    required this.id,
    required this.roomId,
    required this.authorUsername,
    required this.authorId,
    required this.content,
    required this.createdAt,
    required this.isMine,
  });

  factory RoomMessage.fromMap(
    Map<String, dynamic> map, {
    String? myUsername,
    String? myUserId,
  }) {
    final authorUsername = (map['author_username'] as String?) ?? 'Anonymous';
    return RoomMessage(
      id: map['message_id'] as String,
      roomId: map['room_id'] as String,
      authorUsername: authorUsername,
      authorId: map['author_id'] as String?,
      content: map['content'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      // Unofficial chat hides author ids, so "mine" falls back to the
      // anonymous username. A moderator badge is not part of the username.
      isMine:
          (myUserId != null && map['author_id'] == myUserId) ||
          (myUsername != null &&
              authorUsername.replaceAll(RegExp(r' \(Moderator\)$'), '') ==
                  myUsername),
    );
  }

  final String id;
  final String roomId;
  final String authorUsername;
  final String? authorId;
  final String content;
  final DateTime createdAt;
  final bool isMine;
}
