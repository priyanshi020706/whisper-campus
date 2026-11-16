/// Whether this browser lets the app show notifications.
enum PushPermission { unsupported, notAsked, granted, denied }

/// A device's push address, as the server needs it.
class PushSubscriptionData {
  const PushSubscriptionData({
    required this.endpoint,
    required this.p256dh,
    required this.auth,
  });

  final String endpoint;
  final String p256dh;
  final String auth;
}

/// What the app needs from the browser to receive push messages. The real one
/// is in `push_platform_web.dart`; other platforms use a stub, and tests use a
/// fake.
abstract class PushPlatform {
  bool get isSupported;

  Future<PushPermission> permission();

  /// Asks the user for permission (shows the browser's prompt).
  Future<PushPermission> requestPermission();

  /// The subscription of this browser, or null if there is none.
  Future<PushSubscriptionData?> currentSubscription();

  /// Subscribes this browser using the server's public VAPID key.
  Future<PushSubscriptionData> subscribe(String vapidPublicKey);

  /// Removes this browser's subscription. Returns the endpoint that was removed,
  /// or null if there was none.
  Future<String?> unsubscribe();
}
