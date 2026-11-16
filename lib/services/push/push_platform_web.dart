import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'push_types.dart';
import 'push_utils.dart';

/// Web Push through the browser's service worker and Push API.
///
/// The service worker lives in `web/push_sw.js`. It is registered under its own
/// scope so it never competes with Flutter's own service worker.
class WebPushPlatform implements PushPlatform {
  static const _script = 'push_sw.js';
  static const _scope = 'push-scope/';

  @override
  bool get isSupported {
    try {
      return web.window.navigator.has('serviceWorker') &&
          web.window.has('PushManager') &&
          web.window.has('Notification');
    } catch (_) {
      return false;
    }
  }

  PushPermission _parse(String value) => switch (value) {
    'granted' => PushPermission.granted,
    'denied' => PushPermission.denied,
    _ => PushPermission.notAsked,
  };

  @override
  Future<PushPermission> permission() async {
    if (!isSupported) return PushPermission.unsupported;
    return _parse(web.Notification.permission);
  }

  @override
  Future<PushPermission> requestPermission() async {
    if (!isSupported) return PushPermission.unsupported;
    final result = await web.Notification.requestPermission().toDart;
    return _parse(result.toDart);
  }

  Future<web.ServiceWorkerRegistration> _register() async {
    final registration = await web.window.navigator.serviceWorker
        .register(_script.toJS, web.RegistrationOptions(scope: _scope))
        .toDart;
    // A push subscription needs an active worker: wait for it (at most 10 s).
    for (var i = 0; i < 100; i++) {
      if (registration.active != null) return registration;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('The notification service did not start.');
  }

  PushSubscriptionData _read(web.PushSubscription subscription) {
    Uint8List key(String name) {
      final buffer = subscription.getKey(name);
      if (buffer == null) throw StateError('The push subscription is incomplete.');
      return buffer.toDart.asUint8List();
    }

    return PushSubscriptionData(
      endpoint: subscription.endpoint,
      p256dh: bytesToUrlBase64(key('p256dh')),
      auth: bytesToUrlBase64(key('auth')),
    );
  }

  @override
  Future<PushSubscriptionData?> currentSubscription() async {
    if (!isSupported) return null;
    final registration = await web.window.navigator.serviceWorker
        .getRegistration(_scope)
        .toDart;
    if (registration == null) return null;
    final subscription = await registration.pushManager.getSubscription().toDart;
    return subscription == null ? null : _read(subscription);
  }

  @override
  Future<PushSubscriptionData> subscribe(String vapidPublicKey) async {
    final registration = await _register();
    final existing = await registration.pushManager.getSubscription().toDart;
    final subscription =
        existing ??
        await registration.pushManager
            .subscribe(
              web.PushSubscriptionOptionsInit(
                userVisibleOnly: true,
                applicationServerKey: urlBase64ToBytes(vapidPublicKey).toJS,
              ),
            )
            .toDart;
    return _read(subscription);
  }

  @override
  Future<String?> unsubscribe() async {
    if (!isSupported) return null;
    final registration = await web.window.navigator.serviceWorker
        .getRegistration(_scope)
        .toDart;
    if (registration == null) return null;
    final subscription = await registration.pushManager.getSubscription().toDart;
    if (subscription == null) return null;
    final endpoint = subscription.endpoint;
    await subscription.unsubscribe().toDart;
    return endpoint;
  }
}

PushPlatform createPlatform() => WebPushPlatform();
