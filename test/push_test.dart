import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/pages/settings/push_settings_card.dart';
import 'package:whisper_campus/services/push/push_controller.dart';
import 'package:whisper_campus/services/push/push_platform.dart';
import 'package:whisper_campus/services/push/push_utils.dart';

import 'test_helpers.dart';

class _FakePlatform implements PushPlatform {
  _FakePlatform({
    this.supported = true,
    this.perm = PushPermission.notAsked,
    this.promptAnswer = PushPermission.granted,
  });

  bool supported;
  PushPermission perm;
  PushPermission promptAnswer;
  PushSubscriptionData? subscription;
  Object? subscribeError;
  final log = <String>[];

  @override
  bool get isSupported => supported;

  @override
  Future<PushPermission> permission() async => perm;

  @override
  Future<PushPermission> requestPermission() async {
    log.add('prompt');
    perm = promptAnswer;
    return perm;
  }

  @override
  Future<PushSubscriptionData?> currentSubscription() async => subscription;

  @override
  Future<PushSubscriptionData> subscribe(String vapidPublicKey) async {
    log.add('subscribe:$vapidPublicKey');
    final error = subscribeError;
    if (error != null) throw error;
    return subscription = const PushSubscriptionData(
      endpoint: 'https://push.example.com/abc',
      p256dh: 'key',
      auth: 'auth',
    );
  }

  @override
  Future<String?> unsubscribe() async {
    log.add('unsubscribe');
    final endpoint = subscription?.endpoint;
    subscription = null;
    return endpoint;
  }
}

class _FakeApi implements PushServerApi {
  final saved = <String>{};
  Object? failWith;
  final log = <String>[];

  @override
  Future<void> save(PushSubscriptionData subscription, String? userAgent) async {
    final error = failWith;
    if (error != null) throw error;
    log.add('save:${subscription.endpoint}');
    saved.add(subscription.endpoint);
  }

  @override
  Future<void> remove(String endpoint) async {
    log.add('remove:$endpoint');
    saved.remove(endpoint);
  }

  @override
  Future<bool> has(String endpoint) async => saved.contains(endpoint);
}

PushController controllerFor(PushPlatform platform, PushServerApi api, {String key = 'PUBLICKEY'}) {
  final controller = PushController(platform: platform, api: api, vapidKey: key);
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  group('key encoding', () {
    test('url-safe base64 round trips, with or without padding', () {
      final bytes = Uint8List.fromList(List.generate(65, (i) => (i * 7 + 3) % 256));

      final text = bytesToUrlBase64(bytes);

      expect(text.contains('='), isFalse);
      expect(text.contains('+') || text.contains('/'), isFalse);
      expect(urlBase64ToBytes(text), bytes);
    });

    test('decodes a real-looking VAPID public key', () {
      // 65 bytes (uncompressed P-256 point) as 87 url-safe characters.
      const key =
          'BEl62iUYgUivxIkv69yViEuiBIa-ib37J8xYjSJRLMrpOmnbmVVDKi6mZ3TfbYQ8t_bnPxUUUjkI6hxlb8cuRfY';
      final bytes = urlBase64ToBytes(key);

      expect(bytes.length, 65);
      expect(bytes.first, 0x04);
    });
  });

  group('PushController status', () {
    test('unsupported browser', () async {
      final c = controllerFor(_FakePlatform(supported: false), _FakeApi());
      await c.refresh();
      expect(c.status, PushStatus.unsupported);
    });

    test('no VAPID key means push is not set up', () async {
      final c = controllerFor(_FakePlatform(), _FakeApi(), key: '');
      await c.refresh();
      expect(c.status, PushStatus.notConfigured);
    });

    test('blocked in the browser', () async {
      final c = controllerFor(_FakePlatform(perm: PushPermission.denied), _FakeApi());
      await c.refresh();
      expect(c.status, PushStatus.blocked);
    });

    test('not asked yet is "off"', () async {
      final c = controllerFor(_FakePlatform(), _FakeApi());
      await c.refresh();
      expect(c.status, PushStatus.off);
    });

    test('allowed and registered on the server is "on"', () async {
      final platform = _FakePlatform(perm: PushPermission.granted)
        ..subscription = const PushSubscriptionData(endpoint: 'https://push.example.com/abc', p256dh: 'k', auth: 'a');
      final api = _FakeApi()..saved.add('https://push.example.com/abc');
      final c = controllerFor(platform, api);
      await c.refresh();
      expect(c.status, PushStatus.on);
    });

    test('allowed but unknown to the server (for example another account) is "off"', () async {
      final platform = _FakePlatform(perm: PushPermission.granted)
        ..subscription = const PushSubscriptionData(endpoint: 'https://push.example.com/abc', p256dh: 'k', auth: 'a');
      final c = controllerFor(platform, _FakeApi());
      await c.refresh();
      expect(c.status, PushStatus.off);
    });
  });

  group('PushController enable and disable', () {
    test('enable asks permission, subscribes and tells the server', () async {
      final platform = _FakePlatform();
      final api = _FakeApi();
      final c = controllerFor(platform, api);
      await c.refresh();

      final message = await c.enable();

      expect(message, isNull);
      expect(c.status, PushStatus.on);
      expect(platform.log, ['prompt', 'subscribe:PUBLICKEY']);
      expect(api.saved, {'https://push.example.com/abc'});
    });

    test('refusing the prompt keeps it off and explains', () async {
      final platform = _FakePlatform(promptAnswer: PushPermission.denied);
      final api = _FakeApi();
      final c = controllerFor(platform, api);

      final message = await c.enable();

      expect(c.status, PushStatus.blocked);
      expect(message, contains('blocked'));
      expect(api.saved, isEmpty);
    });

    test('dismissing the prompt without answering is not an error state', () async {
      final platform = _FakePlatform(promptAnswer: PushPermission.notAsked);
      final c = controllerFor(platform, _FakeApi());

      final message = await c.enable();

      expect(c.status, PushStatus.off);
      expect(message, isNotNull);
    });

    test('a server failure undoes the browser subscription', () async {
      final platform = _FakePlatform();
      final api = _FakeApi()..failWith = StateError('db down');
      final c = controllerFor(platform, api);

      final message = await c.enable();

      expect(c.status, PushStatus.off);
      expect(message, 'Something went wrong. Please try again.');
      expect(platform.subscription, isNull);
      expect(c.busy, isFalse);
    });

    test('a subscribe failure leaves it off', () async {
      final platform = _FakePlatform()..subscribeError = StateError('no service worker');
      final c = controllerFor(platform, _FakeApi());

      final message = await c.enable();

      expect(c.status, PushStatus.off);
      expect(message, isNotNull);
      expect(c.busy, isFalse);
    });

    test('disable unsubscribes and tells the server', () async {
      final platform = _FakePlatform();
      final api = _FakeApi();
      final c = controllerFor(platform, api);
      await c.enable();

      final message = await c.disable();

      expect(message, isNull);
      expect(c.status, PushStatus.off);
      expect(api.saved, isEmpty);
      expect(api.log, contains('remove:https://push.example.com/abc'));
    });

    test('enable does nothing without a key or support', () async {
      final noKey = controllerFor(_FakePlatform(), _FakeApi(), key: '');
      expect(await noKey.enable(), 'Push notifications are not set up yet.');

      final unsupported = controllerFor(_FakePlatform(supported: false), _FakeApi());
      expect(await unsupported.enable(), isNotNull);
    });
  });

  group('sign-out cleanup', () {
    test('removes this device from the account', () async {
      final platform = _FakePlatform(perm: PushPermission.granted)
        ..subscription = const PushSubscriptionData(endpoint: 'https://push.example.com/abc', p256dh: 'k', auth: 'a');
      final api = _FakeApi()..saved.add('https://push.example.com/abc');

      await PushController.removeThisDevice(platform: platform, api: api);

      expect(platform.subscription, isNull);
      expect(api.saved, isEmpty);
    });

    test('never throws, even when everything fails', () async {
      final platform = _FakePlatform()..subscription = const PushSubscriptionData(endpoint: 'https://push.example.com/abc', p256dh: 'k', auth: 'a');
      final api = _FakeApi();

      await PushController.removeThisDevice(platform: _ThrowingPlatform(), api: api);
      await PushController.removeThisDevice(platform: platform, api: _ThrowingApi());
    });

    test('does nothing on browsers without push', () async {
      final api = _FakeApi();
      await PushController.removeThisDevice(platform: _FakePlatform(supported: false), api: api);

      expect(api.log, isEmpty);
    });
  });

  group('PushSettingsCard', () {
    Future<void> pumpCard(
      WidgetTester tester,
      PushController controller, {
      Screen screen = const Screen('d', Size(360, 740), 1.0),
    }) async {
      useScreen(tester, screen);
      await tester.pumpWidget(
        themedApp(
          Scaffold(body: SingleChildScrollView(child: PushSettingsCard(controller: controller))),
          textScale: screen.textScale,
        ),
      );
    }

    testWidgets('switching on enables push', (tester) async {
      final platform = _FakePlatform();
      final api = _FakeApi();
      final c = controllerFor(platform, api);
      await c.refresh();
      await pumpCard(tester, c);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();

      expect(c.status, PushStatus.on);
      expect(find.textContaining('On.'), findsOneWidget);
    });

    testWidgets('switching off disables push', (tester) async {
      final platform = _FakePlatform();
      final api = _FakeApi();
      final c = controllerFor(platform, api);
      await c.enable();
      await pumpCard(tester, c);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();

      expect(c.status, PushStatus.off);
    });

    testWidgets('blocked, unsupported and not-set-up show an explanation and a disabled switch', (tester) async {
      for (final (platform, key, text) in [
        (_FakePlatform(perm: PushPermission.denied), 'K', 'blocked'),
        (_FakePlatform(supported: false), 'K', 'Home Screen'),
        (_FakePlatform(), '', 'not set up'),
      ]) {
        final c = controllerFor(platform, _FakeApi(), key: key);
        await c.refresh();
        await pumpCard(tester, c);

        expect(find.textContaining(text), findsOneWidget, reason: text);
        expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull, reason: text);
      }
    });

    testWidgets('a refused permission shows a message', (tester) async {
      final platform = _FakePlatform(promptAnswer: PushPermission.denied);
      final c = controllerFor(platform, _FakeApi());
      await c.refresh();
      await pumpCard(tester, c);

      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('blocked'), findsWidgets);
    });

    for (final screen in smallScreens) {
      for (final status in ['off', 'blocked', 'unsupported']) {
        testWidgets('fits: ${screen.name}, $status', (tester) async {
          final platform = switch (status) {
            'blocked' => _FakePlatform(perm: PushPermission.denied),
            'unsupported' => _FakePlatform(supported: false),
            _ => _FakePlatform(),
          };
          final c = controllerFor(platform, _FakeApi());
          await c.refresh();
          await pumpCard(tester, c, screen: screen);

          expectNoLayoutErrors(tester);
        });
      }
    }
  });
}

class _ThrowingPlatform extends _FakePlatform {
  @override
  Future<String?> unsubscribe() async => throw StateError('browser error');
}

class _ThrowingApi extends _FakeApi {
  @override
  Future<void> remove(String endpoint) async => throw StateError('offline');
}
