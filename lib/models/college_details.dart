/// What the college account already tells us about a student or faculty member.
///
/// The name comes from the Google account and the enrollment number, branch and
/// year from the MITS email address. The server fills them in; people cannot
/// edit them on the profile setup screen.
class CollegeDetails {
  const CollegeDetails({
    this.fullName,
    this.enrollmentNumber,
    this.branchCode,
    this.department,
    this.academicYear,
  });

  final String? fullName;
  final String? enrollmentNumber;
  final String? branchCode;
  final String? department;
  final int? academicYear;

  factory CollegeDetails.fromRow(Map<String, dynamic> row) {
    String? clean(Object? value) {
      final text = value?.toString().trim() ?? '';
      return text.isEmpty ? null : text;
    }

    final year = row['academic_year'];
    return CollegeDetails(
      fullName: clean(row['full_name']),
      enrollmentNumber: clean(row['enrollment_number']),
      branchCode: clean(row['branch_code']),
      department: clean(row['department']),
      academicYear: year is num ? year.toInt() : int.tryParse('${year ?? ''}'),
    );
  }

  /// True when Google gave us a name, so the form must not ask for one.
  bool get hasName => fullName != null;

  /// For example "Mathematics & Computing · Year 1", or null when unknown.
  String? get branchAndYear {
    final parts = <String>[
      ?department,
      if (academicYear != null) 'Year $academicYear',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}
