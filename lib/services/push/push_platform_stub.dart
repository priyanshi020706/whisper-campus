import 'push_types.dart';

/// Used where browser push does not exist (phones and desktop builds): push is
/// reported as unsupported and everything else is a no-op.
class StubPushPlatform implements PushPlatform {
  @override
  bool get isSupported => false;

  @override
  Future<PushPermission> permission() async => PushPermission.unsupported;

  @override
  Future<PushPermission> requestPermission() async => PushPermission.unsupported;

  @override
  Future<PushSubscriptionData?> currentSubscription() async => null;

  @override
  Future<PushSubscriptionData> subscribe(String vapidPublicKey) =>
      throw UnsupportedError('Push notifications are not supported here.');

  @override
  Future<String?> unsubscribe() async => null;
}

PushPlatform createPlatform() => StubPushPlatform();
