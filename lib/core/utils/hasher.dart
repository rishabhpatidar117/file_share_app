import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';
import 'crc32c.dart';

class Hasher {
  Hasher._();

  static Future<String> sha256File(String filePath) async {
    final file = File(filePath);
    final stream = file.openRead();
    final hash = await sha256.bind(stream).first;
    return hash.toString();
  }

  static String crc32cBytes(Uint8List bytes) {
    return Crc32c.hash(bytes).toRadixString(16);
  }

  static Future<String> xxh3File(String filePath) async {
    // Fallback: use sha256 if xxh3 unavailable
    return sha256File(filePath);
  }
}