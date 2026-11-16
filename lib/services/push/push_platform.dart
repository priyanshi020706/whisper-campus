import 'push_platform_stub.dart'
    if (dart.library.js_interop) 'push_platform_web.dart'
    as impl;
import 'push_types.dart';

export 'push_types.dart';

/// The push implementation for the platform the app is running on.
PushPlatform createPushPlatform() => impl.createPlatform();
