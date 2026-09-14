import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';
import 'package:swiftshare/core/utils/crc32c.dart';

void main() {
  group('Crc32c', () {
    test('matches known CRC-32C check vector', () {
      // CRC-32C (Castagnoli) check value for "123456789" is 0xE3069283
      final bytes = '123456789'.codeUnits;
      expect(Crc32c.hash(bytes), 0xE3069283);
    });

    test('empty input produces 0', () {
      expect(Crc32c.hash(const []), 0);
    });

    test('deterministic for the same data', () {
      final data = Uint8List.fromList(List.generate(4096, (i) => i % 251));
      expect(Crc32c.hash(data), Crc32c.hash(data));
    });

    test('differs for corrupted data', () {
      final a = Uint8List.fromList([1, 2, 3, 4, 5]);
      final b = Uint8List.fromList([1, 2, 3, 4, 6]);
      expect(Crc32c.hash(a), isNot(Crc32c.hash(b)));
    });

    test('is a 32-bit value', () {
      final data = Uint8List.fromList(List.generate(1000, (i) => i * 7));
      final hash = Crc32c.hash(data);
      expect(hash, inInclusiveRange(0, 0xFFFFFFFF));
      expect(hash.toUnsigned(32), hash);
    });
  });
}