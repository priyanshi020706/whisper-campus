import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/app_constants.dart';
import '../../services/auth_service.dart';
class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _emailController = TextEditingController();
  final _authService = AuthService();

  bool _loading = false;
  String _message = '';

  Future<void> _sendMagicLink() async {
    final email = _emailController.text.trim().toLowerCase();

    if (!email.endsWith(AppConstants.collegeDomain)) {
      setState(() {
        _message = 'Please use your MITS college email.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _message = '';
    });

    try {
    await _authService.sendMagicLink(email);

      if (!mounted) return;

      setState(() {
        _message =
            'Magic link sent!\n\n'
            'Check your MITS email and click the sign-in link.';
      });
    } on AuthException catch (e) {
      if (!mounted) return;

      setState(() {
        _message = e.message;
      });
    } catch (e) {
      if (!mounted) return;

      debugPrint('AUTH ERROR: $e');

      setState(() {
        _message = 'Something went wrong. Please try again.';
      });
    }

    if (!mounted) return;

    setState(() {
      _loading = false;
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
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
                  'Use your MITS college email to continue.',
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 32),

                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  enabled: !_loading,
                  decoration: const InputDecoration(
                    labelText: 'College email',
                    hintText: 'you@mitsgwl.ac.in',
                    border: OutlineInputBorder(),
                  ),
                ),

                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _loading ? null : _sendMagicLink,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        _loading
                            ? 'Sending...'
                            : 'Send Magic Link',
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