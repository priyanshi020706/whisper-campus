import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/error_message.dart';
import 'push_platform.dart';

/// What the push switch can show.
enum PushStatus {
  /// Still finding out.
  loading,

  /// This browser cannot receive push messages.
  unsupported,

  /// The app was built without a VAPID key, so push is not set up yet.
  notConfigured,

  /// The user blocked notifications in the browser.
  blocked,

  /// Available but not turned on for this device.
  off,

  /// Turned on for this device.
  on,
}

/// The server side of push subscriptions.
abstract class PushServerApi {
  Future<void> save(PushSubscriptionData subscription, String? userAgent);
  Future<void> remove(String endpoint);
  Future<bool> has(String endpoint);
}

class SupabasePushServerApi implements PushServerApi {
  SupabasePushServerApi([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<void> save(PushSubscriptionData subscription, String? userAgent) async {
    await _client.rpc(
      'save_push_subscription',
      params: {
        'p_endpoint': subscription.endpoint,
        'p_p256dh': subscription.p256dh,
        'p_auth': subscription.auth,
        'p_user_agent': userAgent,
      },
    );
  }

  @override
  Future<void> remove(String endpoint) async {
    await _client.rpc('remove_push_subscription', params: {'p_endpoint': endpoint});
  }

  @override
  Future<bool> has(String endpoint) async {
    final result = await _client.rpc(
      'has_push_subscription',
      params: {'p_endpoint': endpoint},
    );
    return result == true;
  }
}

/// Turns push notifications on or off for this device.
///
/// The user must switch it on themselves: the browser asks for permission, the
/// device is subscribed, and the server remembers it. Switching it off (or
/// signing out) removes it from both.
class PushController extends ChangeNotifier {
  PushController({
    PushPlatform? platform,
    PushServerApi? api,
    String? vapidKey,
    this.userAgent,
  }) : _platform = platform ?? createPushPlatform(),
       _api = api ?? SupabasePushServerApi(),
       _vapidKey = vapidKey ?? AppConstants.vapidPublicKey;

  final PushPlatform _platform;
  final PushServerApi _api;
  final String _vapidKey;
  final String? userAgent;

  PushStatus _status = PushStatus.loading;
  bool _busy = false;
  bool _disposed = false;

  PushStatus get status => _status;

  /// True while turning push on or off.
  bool get busy => _busy;

  void _set(PushStatus status, {bool? busy}) {
    if (_disposed) return;
    _status = status;
    if (busy != null) _busy = busy;
    notifyListeners();
  }

  /// Works out the current state from the browser and the server.
  Future<void> refresh() async {
    if (!_platform.isSupported) return _set(PushStatus.unsupported);
    if (_vapidKey.isEmpty) return _set(PushStatus.notConfigured);
    try {
      switch (await _platform.permission()) {
        case PushPermission.unsupported:
          return _set(PushStatus.unsupported);
        case PushPermission.denied:
          return _set(PushStatus.blocked);
        case PushPermission.notAsked:
          return _set(PushStatus.off);
        case PushPermission.granted:
          final subscription = await _platform.currentSubscription();
          final registered =
              subscription != null && await _api.has(subscription.endpoint);
          return _set(registered ? PushStatus.on : PushStatus.off);
      }
    } catch (error) {
      debugPrint('PUSH REFRESH ERROR: $error');
      _set(PushStatus.off);
    }
  }

  /// Asks permission, subscribes this device and tells the server. Returns null
  /// on success, or a message to show the user.
  Future<String?> enable() async {
    if (_busy) return null;
    if (!_platform.isSupported) return 'This browser cannot show push notifications.';
    if (_vapidKey.isEmpty) return 'Push notifications are not set up yet.';
    _set(_status, busy: true);
    try {
      final permission = await _platform.requestPermission();
      if (permission == PushPermission.denied) {
        _set(PushStatus.blocked, busy: false);
        return 'Notifications are blocked for this site in your browser.';
      }
      if (permission != PushPermission.granted) {
        _set(PushStatus.off, busy: false);
        return 'Notifications were not allowed.';
      }
      final subscription = await _platform.subscribe(_vapidKey);
      await _api.save(subscription, userAgent);
      _set(PushStatus.on, busy: false);
      return null;
    } catch (error) {
      debugPrint('PUSH ENABLE ERROR: $error');
      // Do not leave a half-made subscription behind.
      try {
        await _platform.unsubscribe();
      } catch (_) {}
      _set(PushStatus.off, busy: false);
      return friendlyError(error);
    }
  }

  /// Turns push off for this device. Returns null on success, or a message.
  Future<String?> disable() async {
    if (_busy) return null;
    _set(_status, busy: true);
    try {
      final endpoint = await _platform.unsubscribe();
      if (endpoint != null) await _api.remove(endpoint);
      _set(PushStatus.off, busy: false);
      return null;
    } catch (error) {
      debugPrint('PUSH DISABLE ERROR: $error');
      await refresh();
      _set(_status, busy: false);
      return friendlyError(error);
    }
  }

  /// Removes this device from the signed-in account, so the next person who
  /// signs in on it does not receive the previous person's notifications. Never
  /// throws: sign-out must always work.
  static Future<void> removeThisDevice({
    PushPlatform? platform,
    PushServerApi? api,
  }) async {
    try {
      final browser = platform ?? createPushPlatform();
      if (!browser.isSupported) return;
      final endpoint = await browser.unsubscribe();
      if (endpoint != null) await (api ?? SupabasePushServerApi()).remove(endpoint);
    } catch (error) {
      debugPrint('PUSH SIGN-OUT CLEANUP ERROR: $error');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
