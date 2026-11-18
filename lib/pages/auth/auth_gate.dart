import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/error_message.dart';
import '../../services/college_profile_sync.dart';
import '../../services/profile_setup_service.dart';
import '../../services/push/push_controller.dart';
import '../home/home_feed_page.dart';
import 'sign_up_page.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  Session? _session;
  String? _error;
  bool _profileSyncComplete = false;
  StreamSubscription<AuthState>? _authSubscription;
  final Set<String> _syncingProfileIds = {};
  final Set<String> _syncedProfileIds = {};

  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();

    _session = _supabase.auth.currentSession;
    final initialSession = _session;
    _profileSyncComplete = initialSession == null;
    if (initialSession != null) {
      unawaited(_syncCollegeDetails(initialSession));
    }

    _authSubscription = _supabase.auth.onAuthStateChange.listen(
      (data) {
        if (!mounted) return;

        final session = data.session;
        setState(() {
          _session = session;
          _profileSyncComplete =
              session == null || _syncedProfileIds.contains(session.user.id);
          _error = null;
        });
        if (session != null) {
          unawaited(_syncCollegeDetails(session));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('AUTH STATE ERROR: $error');
        if (!mounted) return;
        setState(() => _error = friendlyError(error));
      },
    );
  }

  Future<void> _syncCollegeDetails(Session session) async {
    final userId = session.user.id;
    if (_syncedProfileIds.contains(userId) || !_syncingProfileIds.add(userId)) {
      return;
    }

    try {
      await syncCollegeProfileDetails(supabase: _supabase);

      // Profile identity is created from the verified Google identity during
      // sign-in. Do not make students or faculty complete a blocking form.
      try {
        final profile = await _supabase
            .from('profiles')
            .select('role')
            .eq('id', userId)
            .maybeSingle();
        final isFaculty = profile?['role'] == 'faculty';
        await saveProfile(
          _supabase,
          isFaculty: isFaculty,
          firstName: '',
          lastName: '',
        );
      } catch (error) {
        // Missing optional profile details should not block access. The user
        // can complete optional profile fields later from the profile screen.
        debugPrint('OPTIONAL PROFILE COMPLETION ERROR: $error');
      }

      _syncedProfileIds.add(userId);
    } catch (error) {
      debugPrint('COLLEGE PROFILE SYNC ERROR: $error');
      if (mounted) {
        setState(() {
          _error = 'Could not verify your MITS Google account. '
              'Sign in with your college Google account and try again.';
        });
      }
    } finally {
      _syncingProfileIds.remove(userId);
      if (mounted) setState(() => _profileSyncComplete = true);
    }
  }

  void _retry() {
    final session = _session;
    setState(() {
      _error = null;
      if (session != null) {
        _syncedProfileIds.remove(session.user.id);
        _profileSyncComplete = false;
      }
    });
    if (session != null) unawaited(_syncCollegeDetails(session));
  }

  Future<void> _signOut() async {
    await PushController.removeThisDevice();
    try {
      await _supabase.auth.signOut();
    } catch (error) {
      debugPrint('SIGN OUT ERROR: $error');
    }
    if (!mounted) return;
    setState(() {
      _error = null;
      _session = null;
    });
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  Widget _messageScreen(String message, {bool canRetry = true}) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    if (canRetry)
                      FilledButton(onPressed: _retry, child: const Text('Retry')),
                    OutlinedButton(
                      onPressed: _signOut,
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return _messageScreen(error);
    }

    final session = _session;
    if (session == null) {
      return const SignUpPage();
    }

    if (!_profileSyncComplete) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return const HomeFeedPage();
  }
}
