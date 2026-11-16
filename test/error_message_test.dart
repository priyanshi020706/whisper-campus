import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:whisper_campus/core/utils/error_message.dart';

void main() {
  group('friendlyError', () {
    test('shows the message of our own SQL exceptions', () {
      const error = PostgrestException(
        message: 'You are doing that too quickly. Please wait a moment and try again.',
        code: 'P0001',
      );

      expect(
        friendlyError(error),
        'You are doing that too quickly. Please wait a moment and try again.',
      );
    });

    test('hides database details for other Postgres errors', () {
      const error = PostgrestException(
        message: 'relation "public.secret_table" does not exist',
        code: '42P01',
      );

      final message = friendlyError(error);

      expect(message, isNot(contains('secret_table')));
      expect(message, 'Something went wrong. Please try again.');
    });

    test('maps permission errors', () {
      const error = PostgrestException(message: 'denied', code: '42501');

      expect(friendlyError(error), 'You do not have permission to do that.');
    });

    test('never leaks the text of unknown errors', () {
      expect(
        friendlyError(StateError('token=abc123')),
        'Something went wrong. Please try again.',
      );
    });
  });
}
