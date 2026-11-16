/// What the server knows about one room chat for the signed-in user: when the
/// latest message arrived, whether it was theirs, how many are unread, and
/// whether the room is pinned. Comes from `get_my_room_activity`.
class RoomActivity {
  const RoomActivity({
    required this.roomId,
    this.lastMessageAt,
    this.lastMessageMine = false,
    this.unreadCount = 0,
    this.pinned = false,
    this.pinnedAt,
    this.muted = false,
    this.mutedUntil,
  });

  factory RoomActivity.fromMap(Map<String, dynamic> map) {
    DateTime? time(Object? value) =>
        value == null ? null : DateTime.tryParse(value.toString());
    return RoomActivity(
      roomId: map['room_id'] as String,
      lastMessageAt: time(map['last_message_at']),
      lastMessageMine: map['last_message_mine'] == true,
      unreadCount: (map['unread_count'] as num?)?.toInt() ?? 0,
      pinned: map['pinned'] == true,
      pinnedAt: time(map['pinned_at']),
      muted: map['muted'] == true,
      mutedUntil: time(map['muted_until']),
    );
  }

  final String roomId;
  final DateTime? lastMessageAt;
  final bool lastMessageMine;
  final int unreadCount;
  final bool pinned;
  final DateTime? pinnedAt;

  /// The user turned notifications for this room off.
  final bool muted;

  /// When a timed mute ends. Null with [muted] means "until the user unmutes".
  final DateTime? mutedUntil;

  /// Whether the mute is in force at [now]. A timed mute stops counting once
  /// its time has passed, even before the server is asked again.
  bool isMutedAt({DateTime? now}) {
    if (!muted) return false;
    final until = mutedUntil;
    return until == null || until.isAfter(now ?? DateTime.now());
  }

  RoomActivity copyWith({
    bool? pinned,
    DateTime? pinnedAt,
    int? unreadCount,
    bool? muted,
    DateTime? mutedUntil,
    bool clearMutedUntil = false,
  }) {
    return RoomActivity(
      roomId: roomId,
      lastMessageAt: lastMessageAt,
      lastMessageMine: lastMessageMine,
      unreadCount: unreadCount ?? this.unreadCount,
      pinned: pinned ?? this.pinned,
      pinnedAt: pinned == false ? null : (pinnedAt ?? this.pinnedAt),
      muted: muted ?? this.muted,
      mutedUntil: muted == false || clearMutedUntil
          ? null
          : (mutedUntil ?? this.mutedUntil),
    );
  }
}

/// At most this many rooms can be pinned. The database enforces it too.
const maxPinnedRooms = 3;

/// Orders rooms the way a chat app does:
///
/// 1. Pinned rooms first, in the order they were pinned (at most three).
/// 2. Then rooms with a recent message, newest message first. A message
///    counts whether you sent it or someone else did.
/// 3. Then every other room, in the order given (stable).
List<T> orderRoomsByActivity<T>(
  List<T> items,
  String Function(T item) idOf,
  Map<String, RoomActivity> activity,
) {
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];

  int group((int, T) entry) {
    final info = activity[idOf(entry.$2)];
    if (info == null) return 2;
    if (info.pinned) return 0;
    if (info.lastMessageAt != null) return 1;
    return 2;
  }

  indexed.sort((a, b) {
    final ga = group(a);
    final gb = group(b);
    if (ga != gb) return ga.compareTo(gb);
    final ia = activity[idOf(a.$2)];
    final ib = activity[idOf(b.$2)];
    if (ga == 0) {
      final pa = ia?.pinnedAt;
      final pb = ib?.pinnedAt;
      if (pa != null && pb != null && pa != pb) return pa.compareTo(pb);
    } else if (ga == 1) {
      final byTime = ib!.lastMessageAt!.compareTo(ia!.lastMessageAt!);
      if (byTime != 0) return byTime;
    }
    return a.$1.compareTo(b.$1); // stable: keep the given order
  });
  return [for (final entry in indexed) entry.$2];
}

/// How many of [items] are pinned.
int pinnedCount(Map<String, RoomActivity> activity) =>
    activity.values.where((a) => a.pinned).length;

/// "Just now", "5m ago", "3h ago", "Yesterday", "4d ago".
String relativeTimeLabel(DateTime time, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final diff = current.difference(time);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'Yesterday';
  return '${diff.inDays}d ago';
}

/// One line for a room row, such as "You · 5m ago" or "12m ago".
String? roomActivityLine(RoomActivity? activity, {DateTime? now}) {
  final at = activity?.lastMessageAt;
  if (activity == null || at == null) return null;
  final when = relativeTimeLabel(at, now: now);
  return activity.lastMessageMine ? 'You · $when' : when;
}

/// Ways to mute a room. `null` minutes means until the user unmutes.
enum MuteLength {
  hour('1 hour', Duration(hours: 1)),
  eightHours('8 hours', Duration(hours: 8)),
  untilUnmuted('Until I unmute', null);

  const MuteLength(this.label, this.duration);

  final String label;
  final Duration? duration;
}

/// "Muted until 14:30", "Muted until Tue 18 Nov, 09:00" or "Muted until you
/// unmute". Empty when the room is not muted.
String muteStatusLabel(RoomActivity? activity, {DateTime? now}) {
  final current = now ?? DateTime.now();
  if (activity == null || !activity.isMutedAt(now: current)) return '';
  final until = activity.mutedUntil?.toLocal();
  if (until == null) return 'Muted until you unmute';
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(until.hour)}:${two(until.minute)}';
  final sameDay =
      until.year == current.year &&
      until.month == current.month &&
      until.day == current.day;
  if (sameDay) return 'Muted until $time';
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return 'Muted until ${days[until.weekday - 1]} ${until.day} ${months[until.month - 1]}, $time';
}
