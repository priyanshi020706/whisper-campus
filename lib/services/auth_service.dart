import 'package:supabase_flutter/supabase_flutter.dart';

/// Sign-in is Google only. Students must use their MITS Google account; the
/// server verifies the provider and email domain (see sync_my_college_profile).
/// Email magic links are intentionally not offered, so no one can create an
/// account without Google verification.
class AuthService {
  final SupabaseClient _supabase = Supabase.instance.client;

  Future<void> signInWithGoogle() async {
    await _supabase.auth.signInWithOAuth(OAuthProvider.google);
  }

  Future<void> signOut() async {
    await _supabase.auth.signOut();
  }

  User? get currentUser => _supabase.auth.currentUser;

  Session? get currentSession => _supabase.auth.currentSession;
}
