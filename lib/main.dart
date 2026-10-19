import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'pages/auth/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://eroqgxcdizteebxvnswt.supabase.co',
    publishableKey: 'sb_publishable_nhUxxM0Ua0CcAIDPZps9eQ_W6nObXqB',

    // Web is currently our development target.
    // We use implicit flow for this client-only web app.
    // Mobile will use PKCE when we configure deep links.
    authOptions: FlutterAuthClientOptions(
      authFlowType: kIsWeb ? AuthFlowType.implicit : AuthFlowType.pkce,
    ),
  );

  final themeController = ThemeController();
  await themeController.load();
  runApp(MyApp(themeController: themeController));
}

final supabase = Supabase.instance.client;

// ============================================================
// APP
// ============================================================

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.themeController});

  static final _fallbackThemeController = ThemeController();

  final ThemeController? themeController;

  @override
  Widget build(BuildContext context) {
    final controller = themeController ?? _fallbackThemeController;
    return AppThemeScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Whisper Campus',
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: controller.themeMode,
          home: const AuthGate(),
        ),
      ),
    );
  }
}
