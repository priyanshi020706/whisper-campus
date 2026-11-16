class AppConstants {
  static const String collegeDomain = '@mitsgwl.ac.in';

  static const String appName = 'Whisper Campus';

  /// The public half of the server's push (VAPID) key. Set at build time with
  /// `--dart-define=VAPID_PUBLIC_KEY=...`. Empty means push is not set up, and
  /// the notification switch says so. It is a public key, not a secret.
  static const String vapidPublicKey = String.fromEnvironment('VAPID_PUBLIC_KEY');
}
