import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'crc32c.dart';

class ChunkMetadata {
  final int index;
  final int offset;
  final int size;
  final int crc32cChecksum;
  final bool isLast;

  const ChunkMetadata({
    required this.index,
    required this.offset,
    required this.size,
    required this.crc32cChecksum,
    required this.isLast,
  });

  Map<String, dynamic> toJson() => {
    'index': index,
    'offset': offset,
    'size': size,
    'crc32c': crc32cChecksum,
    'isLast': isLast,
  };

  factory ChunkMetadata.fromJson(Map<String, dynamic> json) => ChunkMetadata(
    index: json['index'] as int,
    offset: json['offset'] as int,
    size: json['size'] as int,
    crc32cChecksum: json['crc32c'] as int,
    isLast: json['isLast'] as bool,
  );
}

class ChunkedFileReader {
  final File file;
  final int chunkSize;
  late final int totalChunks;
  late final int totalSize;

  ChunkedFileReader({required this.file, this.chunkSize = 512 * 1024}) {
    totalSize = file.lengthSync();
    totalChunks = totalSize == 0 ? 1 : (totalSize / chunkSize).ceil();
  }

  Future<ChunkData> readChunk(int index) async {
    final raf = await file.open(mode: FileMode.read);
    try {
      final offset = index * chunkSize;
      await raf.setPosition(offset);
      final remaining = totalSize - offset;
      final readSize = remaining < chunkSize ? remaining : chunkSize;
      final bytes = await raf.read(readSize);
      
      return ChunkData(
        metadata: ChunkMetadata(
          index: index,
          offset: offset,
          size: readSize,
          crc32cChecksum: Crc32c.hash(bytes),
          isLast: index == totalChunks - 1,
        ),
        bytes: bytes,
      );
    } finally {
      await raf.close();
    }
  }
}

class ChunkData {
  final ChunkMetadata metadata;
  final Uint8List bytes;

  const ChunkData({required this.metadata, required this.bytes});
}

class ChunkedFileWriter {
  final String filePath;
  final int expectedSize;
  RandomAccessFile? _raf;
  bool _initialized = false;

  ChunkedFileWriter({required this.filePath, required this.expectedSize});

  Future<void> writeChunk(ChunkMetadata metadata, Uint8List bytes) async {
    if (!_initialized) {
      final file = File(filePath);
      final dir = file.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _raf = await file.open(mode: FileMode.write);
      _initialized = true;
    }

    final actualCrc = Crc32c.hash(bytes);
    if (actualCrc != metadata.crc32cChecksum) {
      throw ChunkVerificationException(
        'Chunk ${metadata.index} CRC mismatch: '
        'expected ${metadata.crc32cChecksum}, got $actualCrc',
      );
    }

    await _raf!.setPosition(metadata.offset);
    await _raf!.writeFrom(bytes);
  }

  Future<void> close() async {
    await _raf?.close();
    _raf = null;
    _initialized = false;
  }
}

class ChunkVerificationException implements Exception {
  final String message;
  const ChunkVerificationException(this.message);
  @override
  String toString() => 'ChunkVerificationException: $message';
}

Future<String> computeFileHash(String filePath) async {
  final file = File(filePath);
  final stream = file.openRead();
  final hash = await sha256.bind(stream).first;
  return hash.toString();
}