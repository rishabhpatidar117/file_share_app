import 'dart:typed_data';

class Crc32c {
  Crc32c._();

  static const int _polynomial = 0x82F63B78;

  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      var crc = i;
      for (int j = 0; j < 8; j++) {
        crc = (crc & 1) != 0
            ? (crc >> 1) ^ _polynomial
            : crc >> 1;
      }
      table[i] = crc & 0xFFFFFFFF;
    }
    return table;
  }

  static int hash(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      final idx = (crc ^ byte) & 0xFF;
      crc = (crc >> 8) ^ _table[idx];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}