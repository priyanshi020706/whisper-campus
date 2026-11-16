import 'package:flutter_test/flutter_test.dart';
import 'package:whisper_campus/models/campus_department.dart';

void main() {
  group('campusDepartments', () {
    test('codes are unique and lower case', () {
      final codes = campusDepartments.map((d) => d.code).toList();

      expect(codes.toSet().length, codes.length);
      for (final code in codes) {
        expect(code, code.toLowerCase());
        expect(code.length, 2);
      }
    });

    test('room id is derived from the code', () {
      const department = CampusDepartment('cs', 'Computer Science & Engg');

      expect(department.roomId, 'dept-cs');
    });
  });
}
