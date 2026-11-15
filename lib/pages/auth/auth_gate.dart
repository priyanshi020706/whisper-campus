import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sign_up_page.dart';
import '../profile/profile_setup_page.dart';
import '../home/home_feed_page.dart';
import '../../services/college_profile_sync.dart';

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

        setState(() {
          _session = data.session;
          _profileSyncComplete = data.session == null ||
              _syncedProfileIds.contains(data.session?.user.id ?? '');
          _error = null;
        });
        final session = data.session;
        if (session != null) {
          unawaited(_syncCollegeDetails(session));
        }
      },
      onError: (error, stackTrace) {
        if (!mounted) return;

        setState(() {
          _error = error.toString();
        });
      },
    );
  }

  Future<void> _syncCollegeDetails(Session session) async {
    final userId = session.user.id;
    if (_syncedProfileIds.contains(userId) || !_syncingProfileIds.add(userId)) {
      return;
    }

    try {
      await syncCollegeProfileDetails(
        supabase: _supabase,
      );
      _syncedProfileIds.add(userId);
    } catch (error) {
      if (mounted) {
        setState(() => _error =
            'Could not verify your MITS Google account. Please sign in again.\n\nDetails: $error');
      }
    } finally {
      _syncingProfileIds.remove(userId);
      if (mounted) setState(() => _profileSyncComplete = true);
    }
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

    if (!_profileSyncComplete) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return FutureBuilder(
      future: _supabase
          .from('profiles')
          .select('profile_completed, role')
          .eq('id', _session!.user.id)
          .maybeSingle(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load your profile.\n\n'
                  '${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        final profile = snapshot.data;
        final isFaculty = profile?['role'] == 'faculty';

        if (profile == null || profile['profile_completed'] != true) {
          return ProfileSetupPage(isFaculty: isFaculty);
        }

        return FutureBuilder(
          future: _supabase.rpc('get_my_identity'),
          builder: (context, identitySnapshot) {
            if (identitySnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (identitySnapshot.hasError) {
              return Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not verify your official profile. Please retry.\n\n'
                      '${identitySnapshot.error}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              );
            }
            final rows = identitySnapshot.data;
            if (rows is! List || rows.isEmpty) {
              return ProfileSetupPage(isFaculty: isFaculty);
            }
            return const HomeFeedPage();
          },
        );
      },
    );
  }
}
