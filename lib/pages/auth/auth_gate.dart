import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sign_up_page.dart';
import '../profile/profile_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Session? _session;
  String? _error;
  StreamSubscription<AuthState>? _authSubscription;

  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();

    _session = _supabase.auth.currentSession;

    _authSubscription = _supabase.auth.onAuthStateChange.listen(
      (data) {
        if (!mounted) return;

        setState(() {
          _session = data.session;
          _error = null;
        });
      },
      onError: (error, stackTrace) {
        if (!mounted) return;

        setState(() {
          _error = error.toString();
        });
      },
    );
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Authentication error:\n\n$_error',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    if (_session == null) {
      return const SignUpPage();
    }

    return const ProfilePage();
  }
}