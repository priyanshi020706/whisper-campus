import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/room_activity.dart';

/// Where room activity comes from. The real one talks to Supabase; tests use a
/// fake.
abstract class RoomActivitySource {
  Future<Map<String, RoomActivity>> fetch(String mode);
  Future<void> setPinned(String roomId, String mode, bool pinned);
  Future<void> setMuted(String roomId, String mode, bool muted, {int? minutes});
}

/// Reads recent-chat activity and manages pinned rooms. All the rules (who can
/// see which room, the limit of three pins) are enforced in the database; see
/// `20261117060000_room_chat_recents_and_pins.sql`.
class RoomActivityService implements RoomActivitySource {
  RoomActivityService([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Rooms the user has chatted in or pinned, keyed by room id.
  @override
  Future<Map<String, RoomActivity>> fetch(String mode) async {
    final rows = await _client.rpc(
      'get_my_room_activity',
      params: {'p_mode': mode},
    );
    return {
      for (final row in List<Map<String, dynamic>>.from(rows as List))
        row['room_id'] as String: RoomActivity.fromMap(row),
    };
  }

  @override
  Future<void> setPinned(String roomId, String mode, bool pinned) async {
    await _client.rpc(
      pinned ? 'pin_room' : 'unpin_room',
      params: {'p_room_id': roomId, 'p_mode': mode},
    );
  }

  @override
  Future<void> setMuted(
    String roomId,
    String mode,
    bool muted, {
    int? minutes,
  }) async {
    await _client.rpc(
      'set_room_muted',
      params: {
        'p_room_id': roomId,
        'p_mode': mode,
        'p_muted': muted,
        'p_minutes': minutes,
      },
    );
  }
}
