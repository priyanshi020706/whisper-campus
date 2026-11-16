import 'package:supabase_flutter/supabase_flutter.dart';

/// Turns any thrown error into a short message that is safe to show students.
///
/// Raw exceptions can contain table names, SQL details or stack information,
/// so screens should show this text and log the original error with
/// `debugPrint` instead.
String friendlyError(Object? error) {
  if (error is PostgrestException) {
    // P0001 is the code for `raise exception` in our own SQL functions, whose
    // messages are written for users (for example "Enter first and last name").
    if (error.code == 'P0001' && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    if (error.code == '42501') {
      return 'You do not have permission to do that.';
    }
    if (error.code == '23505') {
      return 'That already exists.';
    }
    if (error.code == '23514' || error.code == '22001') {
      return 'That value is not allowed. Please check it and try again.';
    }
    return 'Something went wrong. Please try again.';
  }
  if (error is AuthException) {
    return 'Your session could not be verified. Please sign in again.';
  }
  if (error is StorageException) {
    return 'The image could not be uploaded. Please try again.';
  }
  final type = error.runtimeType.toString();
  if (type.contains('SocketException') ||
      type.contains('ClientException') ||
      type.contains('TimeoutException') ||
      type.contains('WebSocket')) {
    return 'Network problem. Check your connection and try again.';
  }
  return 'Something went wrong. Please try again.';
}
