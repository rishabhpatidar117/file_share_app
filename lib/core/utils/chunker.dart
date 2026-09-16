import 'dart:async';
import 'dart:io';
import 'dart:isolate';
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

  /// How many chunks beyond the current one get read ahead into a bounded
  /// cache while a network ack is in flight. Keeps peak memory small (a few
  /// chunks) no matter how large the file is.
  final int prefetchChunks;

  late final int totalChunks;
  late final int totalSize;

  RandomAccessFile? _raf;
  Future<void>? _diskChain;

  /// Next sequential read offset so back-to-back chunks skip seek operations.
  int _sequentialOffset = 0;
  bool _sequentialValid = false;
  final Map<int, ChunkData> _prefetchCache = {};
  bool _closed = false;

  ChunkedFileReader({
    required this.file,
    this.chunkSize = 512 * 1024,
    this.prefetchChunks = 2,
  }) {
    totalSize = file.lengthSync();
    totalChunks = totalSize == 0 ? 1 : (totalSize / chunkSize).ceil();
  }

  Future<RandomAccessFile> _ensureOpen() async {
    _raf ??= await file.open(mode: FileMode.read);
    return _raf!;
  }

  /// Serializes disk reads (including read-ahead) so two concurrent reads can
  /// never interleave positions on the same RandomAccessFile.
  Future<T> _queueRead<T>(Future<T> Function(RandomAccessFile raf) op) {
    final previous = _diskChain ?? Future<void>.value();
    final result = previous.catchError((_) {}).then((_) async {
      final raf = await _ensureOpen();
      return op(raf);
    });
    _diskChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<ChunkData> readChunk(int index) {
    if (index < 0 || index >= totalChunks) {
      throw RangeError.range(index, 0, totalChunks - 1, 'index');
    }
    final cached = _prefetchCache.remove(index);
    if (cached != null) {
      _schedulePrefetch(index + 1);
      return Future.value(cached);
    }

    final future = _queueRead((raf) => _readFromDisk(raf, index));
    _schedulePrefetch(index + 1);
    return future;
  }

  Future<ChunkData> _readFromDisk(RandomAccessFile raf, int index) async {
    final offset = index * chunkSize;
    if (!_sequentialValid || offset != _sequentialOffset) {
      await raf.setPosition(offset);
    }
    final remaining = totalSize - offset;
    final readSize = remaining < chunkSize ? remaining : chunkSize;
    final bytes = await raf.read(readSize);
    _sequentialOffset = offset + readSize;
    _sequentialValid = true;

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
  }

  /// Read ahead the next chunks while the current chunk is being sent/acked.
  /// Un-awaited on purpose; bounded by [prefetchChunks] so memory stays flat.
  void _schedulePrefetch(int from) {
    if (_closed || prefetchChunks <= 0 || from >= totalChunks) return;
    unawaited(_prefetchLoop(from));
  }

  Future<void> _prefetchLoop(int from) async {
    var next = from;
    while (next < totalChunks && _prefetchCache.length < prefetchChunks) {
      if (_closed) return;
      if (_prefetchCache.containsKey(next)) {
        next++;
        continue;
      }
      try {
        final chunk = await _queueRead((raf) => _readFromDisk(raf, next));
        if (!_closed) _prefetchCache[next] = chunk;
        next++;
      } catch (_) {
        return;
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _prefetchCache.clear();
    await _raf?.close();
    _raf = null;
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

/// Whole-file SHA-256 computed on a worker isolate so a multi-GB verification
/// pass never stalls the Flutter UI isolate. Used at the end of every file
/// transfer (sender computes the ref hash; the receiver verifies it).
Future<String> computeFileHashInBackground(String filePath) {
  final path = filePath;
  return Isolate.run(() => _sha256FileSyncish(path));
}

Future<String> _sha256FileSyncish(String filePath) => computeFileHash(filePath);
