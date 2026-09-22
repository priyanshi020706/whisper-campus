class ProfileModel {
  final String anonUsername;
  final String avatarSeed;
  final String role;
  final String? department;
  final int? academicYear;
  final String? bio;

  ProfileModel({
    required this.anonUsername,
    required this.avatarSeed,
    required this.role,
    this.department,
    this.academicYear,
    this.bio,
  });

  factory ProfileModel.fromMap(Map<String, dynamic> map) {
    return ProfileModel(
      anonUsername: map['anon_username'] ?? 'Anonymous',
      avatarSeed: map['avatar_seed'] ?? '',
      role: map['role'] ?? 'student',
      department: map['department'],
      academicYear: map['academic_year'],
      bio: map['bio'],
    );
  }
}