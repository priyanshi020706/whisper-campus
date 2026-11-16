/// An event on campus, with who is coming.
class CampusEvent {
  const CampusEvent({
    required this.id,
    required this.title,
    required this.startsAt,
    required this.organizerLabel,
    this.description = '',
    this.location = '',
    this.endsAt,
    this.roomId,
    this.cancelled = false,
    this.goingCount = 0,
    this.interestedCount = 0,
    this.myStatus,
    this.canManage = false,
  });

  factory CampusEvent.fromMap(Map<String, dynamic> map) {
    DateTime? time(Object? v) => v == null ? null : DateTime.tryParse('$v');
    return CampusEvent(
      id: map['event_id'] as String,
      title: (map['title'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      location: (map['location'] as String?) ?? '',
      startsAt: time(map['starts_at']) ?? DateTime.now(),
      endsAt: time(map['ends_at']),
      roomId: map['room_id'] as String?,
      organizerLabel: (map['organizer_label'] as String?) ?? 'Campus team',
      cancelled: map['cancelled'] == true,
      goingCount: (map['going_count'] as num?)?.toInt() ?? 0,
      interestedCount: (map['interested_count'] as num?)?.toInt() ?? 0,
      myStatus: map['my_status'] as String?,
      canManage: map['can_manage'] == true,
    );
  }

  final String id;
  final String title;
  final String description;
  final String location;
  final DateTime startsAt;
  final DateTime? endsAt;
  final String? roomId;

  /// "Admin", "Faculty" or "Room moderator". Never a person's name.
  final String organizerLabel;
  final bool cancelled;
  final int goingCount;
  final int interestedCount;

  /// `going`, `interested` or null.
  final String? myStatus;

  /// The signed-in user created it (or is an admin), so may cancel it.
  final bool canManage;

  /// When the event is over. Events without an end time count as three hours.
  DateTime get endsOrDefault => endsAt ?? startsAt.add(const Duration(hours: 3));

  bool isOver({DateTime? now}) => endsOrDefault.isBefore(now ?? DateTime.now());

  bool isHappeningNow({DateTime? now}) {
    final current = now ?? DateTime.now();
    return !cancelled && !startsAt.isAfter(current) && !isOver(now: current);
  }

  /// This event as it will look once the user's answer is [status]
  /// (`going`, `interested`, or null to take it back).
  CampusEvent withMyStatus(String? status) {
    var going = goingCount;
    var interested = interestedCount;
    if (myStatus == 'going') going -= 1;
    if (myStatus == 'interested') interested -= 1;
    if (status == 'going') going += 1;
    if (status == 'interested') interested += 1;
    return CampusEvent(
      id: id,
      title: title,
      description: description,
      location: location,
      startsAt: startsAt,
      endsAt: endsAt,
      roomId: roomId,
      organizerLabel: organizerLabel,
      cancelled: cancelled,
      goingCount: going,
      interestedCount: interested,
      myStatus: status,
      canManage: canManage,
    );
  }
}

/// A notice from faculty, admins or a room moderator.
class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.organizerLabel,
    this.body = '',
    this.pinned = false,
    this.roomId,
    this.expiresAt,
    this.canManage = false,
  });

  factory Announcement.fromMap(Map<String, dynamic> map) {
    DateTime? time(Object? v) => v == null ? null : DateTime.tryParse('$v');
    return Announcement(
      id: map['announcement_id'] as String,
      title: (map['title'] as String?) ?? '',
      body: (map['body'] as String?) ?? '',
      pinned: map['pinned'] == true,
      roomId: map['room_id'] as String?,
      organizerLabel: (map['organizer_label'] as String?) ?? 'Campus team',
      createdAt: time(map['created_at']) ?? DateTime.now(),
      expiresAt: time(map['expires_at']),
      canManage: map['can_manage'] == true,
    );
  }

  final String id;
  final String title;
  final String body;
  final bool pinned;
  final String? roomId;
  final String organizerLabel;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final bool canManage;
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "Mon 18 Nov".
String formatEventDay(DateTime time) {
  final t = time.toLocal();
  return '${_weekdays[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
}

/// "10:30".
String formatEventTime(DateTime time) {
  final t = time.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// "Mon 18 Nov · 10:00 – 14:00", or with both dates if it spans days.
String formatEventWhen(DateTime start, DateTime? end) {
  final s = start.toLocal();
  if (end == null) return '${formatEventDay(s)} · ${formatEventTime(s)}';
  final e = end.toLocal();
  final sameDay = s.year == e.year && s.month == e.month && s.day == e.day;
  if (sameDay) {
    return '${formatEventDay(s)} · ${formatEventTime(s)} – ${formatEventTime(e)}';
  }
  return '${formatEventDay(s)} ${formatEventTime(s)} – '
      '${formatEventDay(e)} ${formatEventTime(e)}';
}

/// "In 2 days", "Tomorrow", "Today", "Happening now", "Ended".
String eventCountdown(CampusEvent event, {DateTime? now}) {
  final current = now ?? DateTime.now();
  if (event.cancelled) return 'Cancelled';
  if (event.isOver(now: current)) return 'Ended';
  if (event.isHappeningNow(now: current)) return 'Happening now';
  final today = DateTime(current.year, current.month, current.day);
  final start = event.startsAt.toLocal();
  final day = DateTime(start.year, start.month, start.day);
  final days = day.difference(today).inDays;
  if (days == 0) {
    final left = event.startsAt.difference(current);
    if (left.inMinutes < 60) return 'In ${left.inMinutes < 1 ? 1 : left.inMinutes} min';
    return 'Today';
  }
  if (days == 1) return 'Tomorrow';
  return 'In $days days';
}

/// Why an event draft cannot be saved yet, or null when it is fine.
String? validateEventDraft({
  required String title,
  required String description,
  required String location,
  required DateTime? startsAt,
  required DateTime? endsAt,
  DateTime? now,
}) {
  final current = now ?? DateTime.now();
  if (title.trim().isEmpty) return 'Give the event a title.';
  if (title.trim().length > 120) return 'The title is too long (120 characters max).';
  if (description.length > 1000) return 'The description is too long (1000 characters max).';
  if (location.length > 120) return 'The place is too long (120 characters max).';
  if (startsAt == null) return 'Choose when the event starts.';
  if (startsAt.isBefore(current.subtract(const Duration(minutes: 5)))) {
    return 'The start time has already passed.';
  }
  if (startsAt.isAfter(current.add(const Duration(days: 365)))) {
    return 'Choose a start time within the next year.';
  }
  if (endsAt != null && !endsAt.isAfter(startsAt)) {
    return 'The event must end after it starts.';
  }
  return null;
}

/// Why an announcement draft cannot be posted yet, or null when it is fine.
String? validateAnnouncementDraft({required String title, required String body}) {
  if (title.trim().isEmpty) return 'Give the announcement a title.';
  if (title.trim().length > 120) return 'The title is too long (120 characters max).';
  if (body.length > 2000) return 'The text is too long (2000 characters max).';
  return null;
}
