import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../home/home_feed_page.dart';
import '../../services/college_profile_sync.dart';

class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({super.key});

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final _supabase = Supabase.instance.client;
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _bioController = TextEditingController();

  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _completeProfile() async {
    final user = _supabase.auth.currentUser;

    if (user == null) {
      setState(() => _error = 'Please sign in again.');
      return;
    }
    if (_firstNameController.text.trim().isEmpty ||
        _lastNameController.text.trim().isEmpty) {
      setState(() => _error = 'Enter both your first name and last name.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await _supabase.rpc(
        'save_my_identity',
        params: {
          'p_first_name': _firstNameController.text.trim(),
          'p_last_name': _lastNameController.text.trim(),
          'p_bio': _bioController.text.trim().isEmpty
              ? null
              : _bioController.text.trim(),
        },
      );

      // Retry after setup in case the profile row was created after sign-in.
      await syncCollegeProfileDetails(supabase: _supabase, user: user);

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeFeedPage()),
      );
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _error = 'Could not save profile. Please try again.';
      });

      debugPrint('PROFILE SETUP ERROR: $e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set Up Your Profile')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.shield_outlined,
                size: 64,
                color: Colors.deepPurple,
              ),
              const SizedBox(height: 16),
              Text(
                'Welcome to Whisper Campus!',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Choose the name your classmates will see in Official mode. '
                'Your branch and year are detected from your MITS email. '
                'Your anonymous profile stays separate.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _firstNameController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'First name *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lastNameController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Last name *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bioController,
                maxLength: 160,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Bio (optional)',
                  hintText: 'A little about you...',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loading ? null : _completeProfile,
                child: _loading
                    ? const CircularProgressIndicator()
                    : const Text('Complete Setup'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
