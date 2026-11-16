import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/utils/error_message.dart';
import '../models/room_activity.dart';
import 'room_activity_service.dart';

/// Holds the signed-in user's recent-chat activity and pins for one mode, keeps
/// it fresh, and orders room lists with it. One controller is shared by the
/// screens that list rooms so they all agree.
class RoomActivityController extends ChangeNotifier {
  RoomActivityController({
    this.mode = 'unofficial',
    RoomActivitySource? source,
    this.refreshEvery = const Duration(seconds: 30),
  }) : _source = source ?? RoomActivityService();

  final String mode;
  final RoomActivitySource _source;
  final Duration refreshEvery;

  Map<String, RoomActivity> _activity = const {};
  Timer? _timer;
  bool _disposed = false;
  bool _busy = false;

  /// Bumped on every pin change. A refresh that started before a change holds
  /// an older picture, so its result is dropped instead of undoing the change.
  int _changes = 0;

  Map<String, RoomActivity> get activity => _activity;

  RoomActivity? of(String roomId) => _activity[roomId];

  bool isPinned(String roomId) => _activity[roomId]?.pinned ?? false;

  /// Whether the room is muted right now. A timed mute stops counting when its
  /// time passes, without waiting for the next refresh.
  bool isMuted(String roomId) => _activity[roomId]?.isMutedAt() ?? false;

  RoomActivity? muteInfo(String roomId) => _activity[roomId];

  /// Rooms the user muted, for the notification settings page.
  List<String> get mutedRoomIds => [
    for (final a in _activity.values)
      if (a.isMutedAt()) a.roomId,
  ];

  int get pinnedTotal => pinnedCount(_activity);

  /// Rooms ordered pinned first, then by latest message, then as given.
  List<T> order<T>(List<T> items, String Function(T item) idOf) =>
      orderRoomsByActivity(items, idOf, _activity);

  /// Loads now and then again every [refreshEvery] until [dispose].
  void start() {
    refresh();
    _timer?.cancel();
    _timer = Timer.periodic(refreshEvery, (_) => refresh());
  }

  /// Fetches the latest activity. Failures are ignored on purpose: the room
  /// lists still work in their default order without it.
  Future<void> refresh() async {
    if (_busy || _disposed) return;
    _busy = true;
    final startedAt = _changes;
    var outdated = false;
    try {
      final fresh = await _source.fetch(mode);
      if (_disposed) return;
      if (startedAt != _changes) {
        outdated = true;
        return;
      }
      _activity = fresh;
      notifyListeners();
    } catch (error) {
      debugPrint('ROOM ACTIVITY ERROR: $error');
    } finally {
      _busy = false;
      // Fetch again so the picture includes the change made meanwhile.
      if (outdated && !_disposed) unawaited(refresh());
    }
  }

  /// Pins or unpins a room. Returns null on success, or a short message to show
  /// the user (for example when three rooms are already pinned).
  Future<String?> togglePin(String roomId) async {
    final current = _activity[roomId];
    final pin = !(current?.pinned ?? false);
    if (pin && pinnedTotal >= maxPinnedRooms) {
      return 'You can pin up to $maxPinnedRooms rooms. Unpin one first.';
    }

    final before = _activity;
    _changes++;
    final base = current ?? RoomActivity(roomId: roomId);
    // Show the change straight away; undo it if the server says no.
    _activity = {
      ..._activity,
      roomId: base.copyWith(pinned: pin, pinnedAt: DateTime.now()),
    };
    notifyListeners();
    try {
      await _source.setPinned(roomId, mode, pin);
    } catch (error) {
      debugPrint('PIN ERROR: $error');
      if (!_disposed) {
        _changes++;
        _activity = before;
        notifyListeners();
      }
      return friendlyError(error);
    }
    unawaited(refresh());
    return null;
  }

  /// Mutes a room's notifications for [duration], or until the user unmutes
  /// when [duration] is null. Returns null on success, or a message for the
  /// user.
  Future<String?> mute(String roomId, {Duration? duration}) =>
      _setMuted(roomId, muted: true, duration: duration);

  Future<String?> unmute(String roomId) => _setMuted(roomId, muted: false);

  Future<String?> _setMuted(
    String roomId, {
    required bool muted,
    Duration? duration,
  }) async {
    final before = _activity;
    final base = _activity[roomId] ?? RoomActivity(roomId: roomId);
    _changes++;
    // Show it at once; undo it if the server refuses.
    _activity = {
      ..._activity,
      roomId: muted
          ? base.copyWith(
              muted: true,
              mutedUntil: duration == null
                  ? null
                  : DateTime.now().add(duration),
              clearMutedUntil: duration == null,
            )
          : base.copyWith(muted: false),
    };
    notifyListeners();
    try {
      await _source.setMuted(
        roomId,
        mode,
        muted,
        minutes: duration == null ? null : (duration.inSeconds / 60).ceil(),
      );
    } catch (error) {
      debugPrint('MUTE ERROR: $error');
      if (!_disposed) {
        _changes++;
        _activity = before;
        notifyListeners();
      }
      return friendlyError(error);
    }
    unawaited(refresh());
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
