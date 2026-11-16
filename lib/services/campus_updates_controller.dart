import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/utils/error_message.dart';
import '../models/campus_updates.dart';
import 'live_signals.dart';

/// A room the user may publish to.
class PublishRoom {
  const PublishRoom({required this.id, required this.name});

  final String id;
  final String name;
}

/// Where events and announcements live.
abstract class CampusUpdatesSource {
  Future<List<CampusEvent>> events({required bool includePast});
  Future<List<Announcement>> announcements();
  Future<void> rsvp(String eventId, String? status);
  Future<void> cancelEvent(String eventId);
  Future<void> createEvent({
    required String title,
    required String description,
    required String location,
    required DateTime startsAt,
    DateTime? endsAt,
    String? roomId,
  });
  Future<void> createAnnouncement({
    required String title,
    required String body,
    String? roomId,
    bool pinned = false,
    DateTime? expiresAt,
  });
  Future<void> deleteAnnouncement(String id);
  Future<List<PublishRoom>> publishRooms();
}

class SupabaseCampusUpdatesSource implements CampusUpdatesSource {
  SupabaseCampusUpdatesSource([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  List<Map<String, dynamic>> _rows(Object? json) =>
      List<Map<String, dynamic>>.from((json as List?) ?? const []);

  @override
  Future<List<CampusEvent>> events({required bool includePast}) async {
    final json = await _client.rpc(
      'list_events',
      params: {'p_include_past': includePast, 'p_limit': 60},
    );
    return [for (final row in _rows(json)) CampusEvent.fromMap(row)];
  }

  @override
  Future<List<Announcement>> announcements() async {
    final json = await _client.rpc('list_announcements', params: {'p_limit': 30});
    return [for (final row in _rows(json)) Announcement.fromMap(row)];
  }

  @override
  Future<void> rsvp(String eventId, String? status) async {
    await _client.rpc(
      'rsvp_event',
      params: {'p_event_id': eventId, 'p_status': status},
    );
  }

  @override
  Future<void> cancelEvent(String eventId) async {
    await _client.rpc('cancel_event', params: {'p_event_id': eventId});
  }

  @override
  Future<void> createEvent({
    required String title,
    required String description,
    required String location,
    required DateTime startsAt,
    DateTime? endsAt,
    String? roomId,
  }) async {
    await _client.rpc(
      'create_event',
      params: {
        'p_title': title,
        'p_description': description,
        'p_location': location,
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_ends_at': endsAt?.toUtc().toIso8601String(),
        'p_room_id': roomId,
      },
    );
  }

  @override
  Future<void> createAnnouncement({
    required String title,
    required String body,
    String? roomId,
    bool pinned = false,
    DateTime? expiresAt,
  }) async {
    await _client.rpc(
      'create_announcement',
      params: {
        'p_title': title,
        'p_body': body,
        'p_room_id': roomId,
        'p_pinned': pinned,
        'p_expires_at': expiresAt?.toUtc().toIso8601String(),
      },
    );
  }

  @override
  Future<void> deleteAnnouncement(String id) async {
    await _client.rpc('delete_announcement', params: {'p_id': id});
  }

  @override
  Future<List<PublishRoom>> publishRooms() async {
    final json = await _client.rpc('list_my_moderated_rooms');
    final seen = <String>{};
    final rooms = <PublishRoom>[];
    for (final row in _rows(json)) {
      final id = row['room_id'] as String?;
      if (id == null || !seen.add(id)) continue;
      rooms.add(PublishRoom(id: id, name: (row['room_name'] as String?) ?? id));
    }
    return rooms;
  }
}

typedef LiveListen =
    LiveSubscription Function(
      String topic,
      void Function(Map<String, dynamic> signal) onSignal,
    );

/// Events and announcements for the whole app. Screens listen to it; it keeps
/// itself fresh from live signals and shows RSVPs instantly.
class CampusUpdatesController extends ChangeNotifier {
  CampusUpdatesController({CampusUpdatesSource? source, LiveListen? listen})
    : _source = source ?? SupabaseCampusUpdatesSource(),
      _listen = listen ?? LiveSignals.instance.listen;

  final CampusUpdatesSource _source;
  final LiveListen _listen;

  List<CampusEvent> _events = const [];
  List<Announcement> _announcements = const [];
  bool _includePast = false;
  bool _loaded = false;
  String? _error;
  LiveSubscription? _subscription;
  final _debounce = Debouncer(const Duration(milliseconds: 600));
  bool _disposed = false;

  /// Bumped on every local change, so a refresh that began earlier does not
  /// overwrite a change the user just made.
  int _changes = 0;

  /// Changes sent to the server but not confirmed yet. A refresh that finishes
  /// while any are pending may show the old state, so it is repeated afterwards.
  int _pending = 0;
  bool _refreshQueued = false;

  List<CampusEvent> get events => _events;
  List<Announcement> get announcements => _announcements;
  bool get includePast => _includePast;
  bool get loaded => _loaded;
  String? get error => _error;

  /// The announcement to show as a banner: pinned first, otherwise the newest.
  Announcement? get featuredAnnouncement =>
      _announcements.isEmpty ? null : _announcements.first;

  /// Starts live updates. Call [dispose] when done.
  void start() {
    _subscription ??= _listen('campus:updates', (signal) {
      _debounce.run(refresh);
    });
    refresh();
  }

  Future<void> setIncludePast(bool value) async {
    if (_includePast == value) return;
    _includePast = value;
    notifyListeners();
    await refresh();
  }

  /// Reloads both lists. Returns null on success, or a message for the user.
  Future<String?> refresh() async {
    final startedAt = _changes;
    try {
      final results = await Future.wait([
        _source.events(includePast: _includePast),
        _source.announcements(),
      ]);
      if (_disposed) return null;
      if (startedAt != _changes || _pending > 0) {
        // The user changed something meanwhile; fetch again once it is saved.
        _refreshQueued = true;
        _refreshIfIdle();
        return null;
      }
      _events = results[0] as List<CampusEvent>;
      _announcements = results[1] as List<Announcement>;
      _loaded = true;
      _error = null;
      notifyListeners();
      return null;
    } catch (error) {
      debugPrint('CAMPUS UPDATES ERROR: $error');
      if (_disposed) return null;
      _error = friendlyError(error);
      notifyListeners();
      return _error;
    }
  }

  /// Sets or clears the user's answer. Same status again takes it back. Returns
  /// null on success, or a message for the user.
  Future<String?> rsvp(String eventId, String status) async {
    final index = _events.indexWhere((e) => e.id == eventId);
    if (index < 0) return null;
    final before = _events;
    final event = _events[index];
    final next = event.myStatus == status ? null : status;
    _changes++;
    _pending++;
    _events = [
      for (final e in _events) e.id == eventId ? e.withMyStatus(next) : e,
    ];
    notifyListeners();
    try {
      await _source.rsvp(eventId, next);
      return null;
    } catch (error) {
      debugPrint('RSVP ERROR: $error');
      if (!_disposed) {
        _changes++;
        _events = before;
        notifyListeners();
      }
      return friendlyError(error);
    } finally {
      _pending--;
      _refreshIfIdle();
    }
  }

  /// Runs a refresh that was postponed, once no change is waiting on the server.
  void _refreshIfIdle() {
    if (_disposed || !_refreshQueued || _pending > 0) return;
    _refreshQueued = false;
    unawaited(refresh());
  }

  Future<String?> cancelEvent(String eventId) => _run(() async {
    await _source.cancelEvent(eventId);
  });

  Future<String?> createEvent({
    required String title,
    required String description,
    required String location,
    required DateTime startsAt,
    DateTime? endsAt,
    String? roomId,
  }) => _run(() async {
    await _source.createEvent(
      title: title,
      description: description,
      location: location,
      startsAt: startsAt,
      endsAt: endsAt,
      roomId: roomId,
    );
  });

  Future<String?> createAnnouncement({
    required String title,
    required String body,
    String? roomId,
    bool pinned = false,
    DateTime? expiresAt,
  }) => _run(() async {
    await _source.createAnnouncement(
      title: title,
      body: body,
      roomId: roomId,
      pinned: pinned,
      expiresAt: expiresAt,
    );
  });

  Future<String?> deleteAnnouncement(String id) => _run(() async {
    await _source.deleteAnnouncement(id);
  });

  Future<List<PublishRoom>> publishRooms() async {
    try {
      return await _source.publishRooms();
    } catch (error) {
      debugPrint('PUBLISH ROOMS ERROR: $error');
      return const [];
    }
  }

  /// Runs a change, then reloads. Returns a message on failure.
  Future<String?> _run(Future<void> Function() action) async {
    _pending++;
    try {
      await action();
    } catch (error) {
      debugPrint('CAMPUS UPDATES ACTION ERROR: $error');
      return friendlyError(error);
    } finally {
      _pending--;
    }
    await refresh();
    return null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _subscription?.cancel();
    _debounce.dispose();
    super.dispose();
  }
}
