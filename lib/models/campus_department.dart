class CampusDepartment {
  const CampusDepartment(this.code, this.name);

  final String code;
  final String name;

  String get roomId => 'dept-$code';
}

const campusDepartments = <CampusDepartment>[
  CampusDepartment('ad', 'AI & Data Science'),
  CampusDepartment('ai', 'Artificial Intelligence'),
  CampusDepartment('am', 'AI & Machine Learning'),
  CampusDepartment('cb', 'CS & Business Systems'),
  CampusDepartment('cd', 'CS & Design'),
  CampusDepartment('ce', 'Civil Engineering'),
  CampusDepartment('cm', 'Chemical Engineering'),
  CampusDepartment('cs', 'Computer Science & Engg'),
  CampusDepartment('ec', 'Electronics & Communication'),
  CampusDepartment('ee', 'Electrical Engineering'),
  CampusDepartment('el', 'Electronics Engineering'),
  CampusDepartment('et', 'Electronics & Telecommunication'),
  CampusDepartment('io', 'Internet of Things (IoT)'),
  CampusDepartment('ir', 'IT (AI & Robotics)'),
  CampusDepartment('it', 'Information Technology'),
  CampusDepartment('mc', 'Mathematics & Computing'),
  CampusDepartment('me', 'Mechanical Engineering'),
  CampusDepartment('tc', 'CS & Technology'),
  CampusDepartment('ar', 'Architecture (B.Arch)'),
];
