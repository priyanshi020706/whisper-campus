
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    authFlowType: kIsWeb
        ? AuthFlowType.implicit
        : AuthFlowType.pkce,
  ),
);

  runApp(const MyApp());
}

final supabase = Supabase.instance.client;

// ============================================================
// APP
// ============================================================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Whisper Campus',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
        ),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}



