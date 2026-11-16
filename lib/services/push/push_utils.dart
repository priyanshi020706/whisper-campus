import 'dart:convert';
import 'dart:typed_data';

/// Decodes the URL-safe base64 a VAPID public key is written in.
Uint8List urlBase64ToBytes(String value) {
  final padded = value.padRight((value.length + 3) ~/ 4 * 4, '=');
  return base64Url.decode(padded);
}

/// Encodes bytes as URL-safe base64 without padding (the format push servers
/// expect for subscription keys).
String bytesToUrlBase64(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
