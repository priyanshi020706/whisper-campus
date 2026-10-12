
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/auth_service.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _authService = AuthService();

  bool _loading = false;
  String _message = '';

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _message = '';
    });

    try {
      await _authService.signInWithGoogle();
    } on AuthException catch (e) {
      if (!mounted) return;

      setState(() {
        _message = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;

      debugPrint('GOOGLE AUTH ERROR: $e');

      setState(() {
        _message = 'Google sign-in failed. Please try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Whisper Campus'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 450,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Welcome to Whisper Campus',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Sign in with your MITS Google account to continue.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _loading ? null : _signInWithGoogle,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _loading
                            ? 'Connecting to Google...'
                            : 'Continue with Google',
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (_message.isNotEmpty)
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
