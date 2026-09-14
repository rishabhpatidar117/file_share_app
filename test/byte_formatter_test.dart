import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/core/utils/byte_formatter.dart';

void main() {
  group('ByteFormatter', () {
    test('formats bytes', () {
      expect(ByteFormatter.format(0), '0 B');
      expect(ByteFormatter.format(512), '512 B');
      expect(ByteFormatter.format(1024), '1.0 KB');
      expect(ByteFormatter.format(1536), '1.5 KB');
      expect(ByteFormatter.format(5 * 1024 * 1024), '5.0 MB');
      expect(ByteFormatter.format(2 * 1024 * 1024 * 1024), '2.00 GB');
    });

    test('formats speed', () {
      expect(ByteFormatter.formatSpeed(1024 * 1024), '1.0 MB/s');
    });

    test('formats durations', () {
      expect(ByteFormatter.formatDuration(const Duration(seconds: 5)), '5s');
      expect(ByteFormatter.formatDuration(const Duration(minutes: 2, seconds: 10)), '2m 10s');
      expect(ByteFormatter.formatDuration(const Duration(hours: 1, minutes: 30)), '1h 30m');
    });
  });
}