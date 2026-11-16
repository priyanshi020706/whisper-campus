import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/utils/error_message.dart';
import '../models/notification_prefs.dart';

/// Where notification settings are read and saved.
abstract class NotificationPrefsSource {
  Future<NotificationPrefs> fetch();
  Future<void> save(NotificationPrefs prefs, NotificationPrefs previous);
}

class SupabaseNotificationPrefsSource implements NotificationPrefsSource {
  SupabaseNotificationPrefsSource([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<NotificationPrefs> fetch() async {
    final rows = await _client.rpc('get_my_notification_prefs');
    final list = List<Map<String, dynamic>>.from(rows as List);
    return list.isEmpty
        ? const NotificationPrefs()
        : NotificationPrefs.fromMap(list.first);
  }

  @override
  Future<void> save(NotificationPrefs prefs, NotificationPrefs previous) async {
    // Only send what changed; null means "leave as is" on the server.
    bool? changed(bool next, bool before) => next == before ? null : next;
    await _client.rpc(
      'set_my_notification_prefs',
      params: {
        'p_likes': changed(prefs.likes, previous.likes),
        'p_comments': changed(prefs.comments, previous.comments),
        'p_chat_replies': changed(prefs.chatReplies, previous.chatReplies),
        'p_events': changed(prefs.events, previous.events),
        'p_announcements': changed(prefs.announcements, previous.announcements),
      },
    );
  }
}

/// Holds the signed-in user's notification choices. A switch changes at once
/// and is undone, with a message, if the server refuses it.
class NotificationPrefsController extends ChangeNotifier {
  NotificationPrefsController({NotificationPrefsSource? source})
    : _source = source ?? SupabaseNotificationPrefsSource();

  final NotificationPrefsSource _source;
  NotificationPrefs _prefs = const NotificationPrefs();
  bool _loaded = false;
  bool _disposed = false;

  NotificationPrefs get prefs => _prefs;

  /// False until the first successful load.
  bool get loaded => _loaded;

  Future<String?> load() async {
    try {
      final fresh = await _source.fetch();
      if (_disposed) return null;
      _prefs = fresh;
      _loaded = true;
      notifyListeners();
      return null;
    } catch (error) {
      debugPrint('NOTIFICATION PREFS LOAD ERROR: $error');
      return friendlyError(error);
    }
  }

  /// Applies [change] to the current choices. Returns null on success, or a
  /// message to show the user.
  Future<String?> update(
    NotificationPrefs Function(NotificationPrefs current) change,
  ) async {
    final before = _prefs;
    final next = change(before);
    if (next == before) return null;
    _prefs = next;
    notifyListeners();
    try {
      await _source.save(next, before);
      return null;
    } catch (error) {
      debugPrint('NOTIFICATION PREFS SAVE ERROR: $error');
      if (!_disposed) {
        _prefs = before;
        notifyListeners();
      }
      return friendlyError(error);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
