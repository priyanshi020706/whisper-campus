import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:whisper_campus/models/college_details.dart';
import 'package:whisper_campus/pages/profile/profile_setup_page.dart';

import 'test_helpers.dart';

const _student = CollegeDetails(
  fullName: 'Pratik Bhayal',
  enrollmentNumber: '25MC1PR108',
  branchCode: 'MC',
  department: 'Mathematics & Computing',
  academicYear: 1,
);

class _Saved {
  _Saved(this.isFaculty, this.first, this.last, this.bio, this.department);

  final bool isFaculty;
  final String first;
  final String last;
  final String? bio;
  final String? department;
}

void main() {
  group('CollegeDetails', () {
    test('reads a server row and trims blanks', () {
      final details = CollegeDetails.fromRow({
        'full_name': '  Pratik Bhayal ',
        'enrollment_number': '25MC1PR108',
        'branch_code': 'MC',
        'department': 'Mathematics & Computing',
        'academic_year': 1,
        'role': 'student',
      });

      expect(details.fullName, 'Pratik Bhayal');
      expect(details.hasName, isTrue);
      expect(details.enrollmentNumber, '25MC1PR108');
      expect(details.branchAndYear, 'Mathematics & Computing · Year 1');
    });

    test('empty and missing values become null', () {
      final details = CollegeDetails.fromRow({
        'full_name': '   ',
        'enrollment_number': null,
        'academic_year': null,
      });

      expect(details.hasName, isFalse);
      expect(details.enrollmentNumber, isNull);
      expect(details.branchAndYear, isNull);
    });

    test('year alone and department alone', () {
      expect(const CollegeDetails(academicYear: 2).branchAndYear, 'Year 2');
      expect(
        const CollegeDetails(department: 'CSE').branchAndYear,
        'CSE',
      );
    });
  });

  group('ProfileSetupPage', () {
    Future<List<_Saved>> pump(
      WidgetTester tester, {
      CollegeDetails? details = _student,
      bool loaderFails = false,
      bool isFaculty = false,
      Object? saveError,
      Screen screen = const Screen('phone', Size(390, 844), 1.0),
      List<bool>? completed,
    }) async {
      useScreen(tester, screen);
      final saved = <_Saved>[];
      await tester.pumpWidget(
        themedApp(
          ProfileSetupPage(
            isFaculty: isFaculty,
            loadDetails: () async {
              if (loaderFails) throw StateError('rpc missing');
              return details;
            },
            save: ({
              required bool isFaculty,
              required String firstName,
              required String lastName,
              String? bio,
              String? departmentCode,
            }) async {
              if (saveError != null) throw saveError;
              saved.add(_Saved(isFaculty, firstName, lastName, bio, departmentCode));
            },
            onCompleted: () => completed?.add(true),
          ),
          textScale: screen.textScale,
        ),
      );
      await tester.pump();
      await tester.pump();
      return saved;
    }

    testWidgets('name and enrollment are shown and cannot be edited', (tester) async {
      await pump(tester);

      expect(find.text('Pratik Bhayal'), findsOneWidget);
      expect(find.text('25MC1PR108'), findsOneWidget);
      expect(find.text('Mathematics & Computing · Year 1'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(3));
      // Only the bio can be typed into.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Bio (optional)'), findsOneWidget);
      expect(find.textContaining('First name'), findsNothing);
      expect(find.textContaining('cannot be changed'), findsWidgets);
    });

    testWidgets('saving sends only the bio, never a typed name', (tester) async {
      final completed = <bool>[];
      final saved = await pump(tester, completed: completed);

      await tester.enterText(find.byType(TextField), '  CS fan  ');
      await tester.tap(find.text('Complete Setup'));
      await tester.pump();
      await tester.pump();

      expect(saved, hasLength(1));
      expect(saved.single.first, '');
      expect(saved.single.last, '');
      expect(saved.single.bio, 'CS fan');
      expect(completed, [true]);
    });

    testWidgets('the button waits until the details have loaded', (tester) async {
      useScreen(tester, const Screen('phone', Size(390, 844), 1.0));
      await tester.pumpWidget(
        themedApp(
          ProfileSetupPage(
            loadDetails: () => Future.delayed(
              const Duration(milliseconds: 50),
              () => _student,
            ),
            save: ({
              required bool isFaculty,
              required String firstName,
              required String lastName,
              String? bio,
              String? departmentCode,
            }) async {},
            onCompleted: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNull,
      );

      await tester.pump(const Duration(milliseconds: 80));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('no Google name: optional name fields are shown and sent', (tester) async {
      final saved = await pump(
        tester,
        details: const CollegeDetails(enrollmentNumber: '25CS1AB015'),
      );

      expect(find.textContaining('First name'), findsOneWidget);
      expect(find.textContaining('Last name'), findsOneWidget);
      expect(find.text('25CS1AB015'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'First name (optional)'), 'Asha');
      await tester.enterText(find.widgetWithText(TextField, 'Last name (optional)'), 'Rao');
      await tester.tap(find.text('Complete Setup'));
      await tester.pump();
      await tester.pump();

      expect(saved.single.first, 'Asha');
      expect(saved.single.last, 'Rao');
    });

    testWidgets('details failing to load falls back to the plain form', (tester) async {
      final saved = await pump(tester, loaderFails: true);

      expect(find.textContaining('First name'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline_rounded), findsNothing);

      await tester.tap(find.text('Complete Setup'));
      await tester.pump();
      await tester.pump();

      expect(saved, hasLength(1));
    });

    testWidgets('a refused save shows a message and stays on the screen', (tester) async {
      final completed = <bool>[];
      await pump(
        tester,
        saveError: const PostgrestException(message: 'nope', code: '42501'),
        completed: completed,
      );

      await tester.tap(find.text('Complete Setup'));
      await tester.pump();
      await tester.pump();

      expect(find.text('You do not have permission to do that.'), findsOneWidget);
      expect(completed, isEmpty);
    });

    testWidgets('faculty: name is locked and the department can be chosen', (tester) async {
      final saved = await pump(
        tester,
        isFaculty: true,
        details: const CollegeDetails(fullName: 'Dr Sharma'),
      );

      expect(find.text('Dr Sharma'), findsOneWidget);
      expect(find.textContaining('First name'), findsNothing);
      expect(find.text('Bio (optional)'), findsNothing);
      expect(find.text('Department (optional)'), findsOneWidget);

      await tester.tap(find.text('Complete Setup'));
      await tester.pump();
      await tester.pump();

      expect(saved.single.isFaculty, isTrue);
      expect(saved.single.first, '');
      expect(saved.single.bio, isNull);
    });

    for (final screen in smallScreens) {
      testWidgets('long values fit: ${screen.name}', (tester) async {
        await pump(
          tester,
          screen: screen,
          details: const CollegeDetails(
            fullName: 'Venkata Subrahmanyam Lakshminarayana Bhattacharyya Iyer',
            enrollmentNumber: '25MC1PR108',
            department: 'Electronics & Telecommunication Engineering',
            academicYear: 4,
          ),
        );

        expectNoLayoutErrors(tester);
        await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -400));
        await tester.pump();
        expectNoLayoutErrors(tester);
      });

      testWidgets('faculty form fits: ${screen.name}', (tester) async {
        await pump(
          tester,
          screen: screen,
          isFaculty: true,
          details: const CollegeDetails(fullName: 'Dr Venkata Subrahmanyam'),
        );

        expectNoLayoutErrors(tester);
      });
    }
  });
}
