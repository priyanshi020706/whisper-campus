import 'package:supabase_flutter/supabase_flutter.dart';

/// Sends the authenticated session to the server. Role and college fields are
/// derived and saved inside sync_my_college_profile, never supplied by the app.
Future<void> syncCollegeProfileDetails({
  required SupabaseClient supabase,
}) async {
  await supabase.rpc('sync_my_college_profile');
}