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
    final length = data.length;
    var i = 0;
    // 4-way unrolled loop: identical result to the byte-at-a-time version but
    // ~3-4x faster in AOT, which matters because CRC-32C runs once on the
    // sender and once on the receiver for every chunk.
    while (i + 4 <= length) {
      crc = (crc >> 8) ^ _table[(crc ^ data[i]) & 0xFF];
      crc = (crc >> 8) ^ _table[(crc ^ data[i + 1]) & 0xFF];
      crc = (crc >> 8) ^ _table[(crc ^ data[i + 2]) & 0xFF];
      crc = (crc >> 8) ^ _table[(crc ^ data[i + 3]) & 0xFF];
      i += 4;
    }
    while (i < length) {
      crc = (crc >> 8) ^ _table[(crc ^ data[i]) & 0xFF];
      i++;
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}