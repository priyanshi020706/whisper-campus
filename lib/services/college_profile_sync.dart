import 'package:supabase_flutter/supabase_flutter.dart';

class CollegeProfileDetails {
  const CollegeProfileDetails({
    required this.branch,
    required this.academicYear,
  });

  final String branch;
  final int academicYear;

  static const Map<String, String> _branches = {
    'ad': 'AI & Data Science',
    'ai': 'Artificial Intelligence',
    'am': 'AI & Machine Learning',
    'cb': 'CS & Business Systems',
    'cd': 'CS & Design',
    'ce': 'Civil Engineering',
    'cm': 'Chemical Engineering',
    'cs': 'Computer Science & Engg',
    'ec': 'Electronics & Communication',
    'ee': 'Electrical Engineering',
    'el': 'Electronics Engineering',
    'et': 'Electronics & Telecommunication',
    'io': 'Internet of Things (IoT)',
    'ir': 'IT (AI & Robotics)',
    'it': 'Information Technology',
    'mc': 'Mathematics & Computing',
    'me': 'Mechanical Engineering',
    'tc': 'CS & Technology',
    'ar': 'Architecture (B.Arch)',
  };

  static CollegeProfileDetails? fromCollegeEmail(
    String? email, {
    DateTime? today,
  }) {
    if (email == null) return null;
    final parts = email.trim().toLowerCase().split('@');
    if (parts.length != 2 || parts[1] != 'mitsgwl.ac.in') return null;

    final match = RegExp(r'^(\d{2})([a-z]{2})').firstMatch(parts[0]);
    if (match == null) return null;

    final branch = _branches[match.group(2)];
    final enrollmentYear = 2000 + int.parse(match.group(1)!);
    final academicYear = (today ?? DateTime.now()).year - enrollmentYear + 1;
    if (branch == null || academicYear < 1) return null;

    return CollegeProfileDetails(branch: branch, academicYear: academicYear);
  }
}

/// Synchronizes only the signed-in user's own branch/year fields.
/// The email itself is never written to the profiles table.
Future<bool> syncCollegeProfileDetails({
  required SupabaseClient supabase,
  required User user,
}) async {
  final details = CollegeProfileDetails.fromCollegeEmail(user.email);
  if (details == null) return false;

  try {
    await supabase.rpc('sync_my_college_profile');
    return true;
  } catch (_) {
    return false;
  }
}
