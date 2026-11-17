import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/college_details.dart';
import 'college_profile_sync.dart';

/// Loads the college details shown on the profile setup screen.
typedef CollegeDetailsLoader = Future<CollegeDetails?> Function();

/// Saves the profile. The names are only used when Google gave no name; the
/// server ignores them otherwise.
typedef ProfileSaver = Future<void> Function({
  required bool isFaculty,
  required String firstName,
  required String lastName,
  String? bio,
  String? departmentCode,
});

/// Reads the Google name and the enrollment, branch and year that the server
/// worked out from the college email. Returns null when there is nothing yet.
Future<CollegeDetails?> loadCollegeDetails(SupabaseClient supabase) async {
  final rows = await supabase.rpc('get_my_college_details');
  if (rows is List && rows.isNotEmpty) {
    return CollegeDetails.fromRow(Map<String, dynamic>.from(rows.first as Map));
  }
  return null;
}

bool _needsCampusSync(Object error) =>
    error is PostgrestException &&
    error.message.toLowerCase().contains('sync required');

/// Saves the profile. If the server says the campus profile has not been
/// created yet, it syncs once and tries again before giving up.
Future<void> saveProfile(
  SupabaseClient supabase, {
  required bool isFaculty,
  required String firstName,
  required String lastName,
  String? bio,
  String? departmentCode,
}) async {
  Future<void> call() async {
    if (isFaculty) {
      await supabase.rpc('save_my_faculty_profile', params: {
        'p_first_name': firstName,
        'p_last_name': lastName,
        'p_department_code': departmentCode,
      });
    } else {
      await supabase.rpc('save_my_identity', params: {
        'p_first_name': firstName,
        'p_last_name': lastName,
        'p_bio': (bio == null || bio.trim().isEmpty) ? null : bio.trim(),
      });
    }
  }

  try {
    await call();
  } catch (error) {
    if (!_needsCampusSync(error)) rethrow;
    await syncCollegeProfileDetails(supabase: supabase);
    await call();
  }
}
