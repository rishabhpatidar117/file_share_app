import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/core/utils/chunker.dart';

void main() {
  final tempDir = Directory.systemTemp.createTempSync('swiftshare_test');

  tearDownAll(() {
    if (!tempDir.existsSync()) return;
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // File handles may briefly persist on Windows; retry once.
      Future.delayed(const Duration(milliseconds: 100), () {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });
    }
  });

  Uint8List makePayload(int size) {
    return Uint8List.fromList(List.generate(size, (i) => i % 256));
  }

  test('chunk count computed correctly', () {
    final file = File('${tempDir.path}/small.bin');
    file.writeAsBytesSync(makePayload(1000));

    final reader = ChunkedFileReader(file: file, chunkSize: 256);
    expect(reader.totalChunks, 4);
    expect(reader.totalSize, 1000);
  });

  test('chunking splits a file into fixed size chunks', () async {
    final size = 1024 * 512 + 123; // 1 chunk + partial
    final payload = makePayload(size);
    final file = File('${tempDir.path}/split_me.bin');
    file.writeAsBytesSync(payload);

    final reader = ChunkedFileReader(file: file, chunkSize: 512 * 1024);
    expect(reader.totalChunks, 2);

    final chunk0 = await reader.readChunk(0);
    expect(chunk0.metadata.size, 512 * 1024);
    expect(chunk0.metadata.isLast, false);
    expect(chunk0.metadata.offset, 0);
    expect(chunk0.metadata.index, 0);

    final chunk1 = await reader.readChunk(1);
    expect(chunk1.metadata.size, 123);
    expect(chunk1.metadata.isLast, true);
    expect(chunk1.metadata.offset, 512 * 1024);
    expect(chunk1.metadata.index, 1);
  });

  test('chunk reassembly reproduces exact bytes', () async {
    final size = 128 * 1024 + 77;
    final payload = makePayload(size);
    final srcFile = File('${tempDir.path}/reassemble_src.bin');
    srcFile.writeAsBytesSync(payload);

    final reader = ChunkedFileReader(file: srcFile, chunkSize: 32768);
    final writer = ChunkedFileWriter(
      filePath: '${tempDir.path}/reassemble_dst.bin',
      expectedSize: size,
    );

    for (int i = 0; i < reader.totalChunks; i++) {
      final chunk = await reader.readChunk(i);
      await writer.writeChunk(chunk.metadata, chunk.bytes);
    }
    await writer.close();

    final dstBytes = File('${tempDir.path}/reassemble_dst.bin').readAsBytesSync();
    expect(dstBytes.length, size);
    expect(dstBytes, payload);
  });

  test('CRC mismatch throws ChunkVerificationException', () async {
    final file = File('${tempDir.path}/tamper.bin');
    file.writeAsBytesSync(makePayload(100));

    final reader = ChunkedFileReader(file: file, chunkSize: 64);
    final chunk = await reader.readChunk(0);

    final tampered = Uint8List.fromList([
      ...chunk.bytes.sublist(0, chunk.bytes.length - 1),
      42,
    ]);

    final writer = ChunkedFileWriter(
      filePath: '${tempDir.path}/tamper_dst.bin',
      expectedSize: 100,
    );

    expect(
      () => writer.writeChunk(chunk.metadata, tampered),
      throwsA(isA<ChunkVerificationException>()),
    );
    await writer.close();
  });

  test('empty file has exactly one last chunk', () async {
    final file = File('${tempDir.path}/empty.bin');
    file.writeAsBytesSync(const []);

    final reader = ChunkedFileReader(file: file, chunkSize: 256);
    expect(reader.totalChunks, 1);

    final chunk = await reader.readChunk(0);
    expect(chunk.metadata.size, 0);
    expect(chunk.metadata.isLast, true);
  });

  test('ChunkMetadata JSON round-trip', () {
    const meta = ChunkMetadata(
      index: 3,
      offset: 1536,
      size: 512,
      crc32cChecksum: 0xDEADBEEF,
      isLast: false,
    );
    final restored = ChunkMetadata.fromJson(meta.toJson());
    expect(restored.index, meta.index);
    expect(restored.offset, meta.offset);
    expect(restored.size, meta.size);
    expect(restored.crc32cChecksum, meta.crc32cChecksum);
    expect(restored.isLast, meta.isLast);
  });
}