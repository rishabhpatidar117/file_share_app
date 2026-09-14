import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/transport/lan_socket/lan_socket_transport.dart';
import 'package:swiftshare/transport/device_info.dart';
import 'package:swiftshare/transport/transport_channel.dart';
import 'package:swiftshare/core/utils/chunker.dart';

/// Exercises the real LAN socket transport over the loopback interface:
/// discovery-free connect, session negotiation, acked chunk transfer and
/// whole-file SHA-256 verification.
void main() {
  late LanSocketTransport receiver;
  late LanSocketTransport sender;
  late Directory sandbox;
  late String sourcePath;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('swiftshare_lan_test');
    receiver = LanSocketTransport();
    sender = LanSocketTransport();
    await receiver.startIncoming();
  });

  tearDown(() async {
    await sender.disconnect();
    await receiver.disconnect();
    try {
      await sandbox.delete(recursive: true);
    } catch (_) {}
  });

  test('full session: negotiate, chunk, ack and verify a real file', () async {
    // Build a 2.5 MB source file so it spans several 512 KB chunks.
    final rng = Random(42);
    final data = Uint8List.fromList(
      List<int>.generate(2_621_440, (_) => rng.nextInt(256)),
    );
    sourcePath = '${sandbox.path}/source.bin';
    await File(sourcePath).writeAsBytes(data);

    final reader = ChunkedFileReader(file: File(sourcePath));
    final sourceHash = await computeFileHash(sourcePath);

    // Receiver: collect the incoming file and hand it back off the wire.
    final receivedParts = <Uint8List>[];
    final gotDataEvent = Completer<void>();
    final done = Completer<void>();

    receiver.onIncomingSession.listen((session) async {
      expect(session.remoteDeviceName, 'SenderTest');
      expect(session.chunkSize, 512 * 1024);
      await receiver.acceptIncoming(session.sessionId, {});
    });

    receiver.onChunkReceived.listen((event) async {
      receivedParts.add(event.data);
      await receiver.sendChunkAck(event.fileIndex, event.metadata.index);
      if (gotDataEvent.isCompleted) return;
      gotDataEvent.complete();
    });

    // File-complete handshake with hash verification.
    var receivedHash = '';
    receiver.onIncomingFileComplete.listen((event) async {
      receivedHash = event.sha256;
      expect(event.sha256, sourceHash);
      expect(event.fileName, 'payload.bin');
      await receiver.sendFileCompleteAck(event.fileIndex);
      done.complete();
    });

    // Connect: sender connects to the receiver's listening socket.
    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    expect(sender.state, TransportState.connected);

    final resume = await sender.sendSessionStart(
      'session-1',
      'SenderTest',
      const [
        SessionFileMeta(
          index: 0,
          fileName: 'payload.bin',
          fileSize: 2621440,
          totalChunks: 5,
        ),
      ],
      chunkSize: 512 * 1024,
    );
    expect(resume, {});

    // Send every chunk; each sendChunk completes only after the receiver acks.
    for (var i = 0; i < reader.totalChunks; i++) {
      final chunk = await reader.readChunk(i);
      await sender.sendChunk(0, chunk.metadata, chunk.bytes);
    }
    await gotDataEvent.future;

    final receivedBytes = <int>[];
    for (final part in receivedParts) {
      receivedBytes.addAll(part);
    }
    expect(receivedBytes, data);

    await sender.sendFileComplete(
      0,
      sourceHash,
      fileName: 'payload.bin',
      fileSize: reader.totalSize,
      totalChunks: reader.totalChunks,
    );
    await done.future.timeout(const Duration(seconds: 30));
    expect(receivedHash, sourceHash);
  });

  test('receiver detects a corrupt chunk and errors it back', () async {
    sourcePath = '${sandbox.path}/tiny.bin';
    await File(sourcePath).writeAsBytes(List.filled(64, 7));

    final reader = ChunkedFileReader(file: File(sourcePath));
    final gotChunk = Completer<void>();

    receiver.onIncomingSession.listen((session) async {
      await receiver.acceptIncoming(session.sessionId, {0: 0});
    });

    // Acknowledge nothing; instead reject the single chunk (bad CRC).
    receiver.onChunkReceived.listen((event) async {
      await receiver.sendChunkError(event.fileIndex, event.metadata.index);
      if (!gotChunk.isCompleted) gotChunk.complete();
    });

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));

    await sender.sendSessionStart(
      'session-2',
      'SenderTest',
      const [
        SessionFileMeta(index: 0, fileName: 'tiny.bin', fileSize: 64, totalChunks: 1),
      ],
    );

    final chunk = await reader.readChunk(0);
    await expectLater(
      sender.sendChunk(0, chunk.metadata, chunk.bytes),
      throwsA(isA<TransportException>()),
    );
  });

  test('receiver reports back resume points when files were partially received',
      () async {
    sourcePath = '${sandbox.path}/resume.bin';
    await File(sourcePath).writeAsBytes(List.filled(1_500_000, 3));

    final reader = ChunkedFileReader(file: File(sourcePath));
    expect(reader.totalChunks, 3);

    final gotSession = Completer<IncomingSession>();
    receiver.onIncomingSession.listen((session) {
      if (!gotSession.isCompleted) gotSession.complete(session);
    });

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));

    // Receiver only has 1 chunk on disk -> asks the sender to start at index 1.
    final ackFuture = sender.sendSessionStart(
      'session-3',
      'SenderTest',
      const [
        SessionFileMeta(
          index: 0,
          fileName: 'resume.bin',
          fileSize: 1500000,
          totalChunks: 3,
        ),
      ],
    );

    final session = await gotSession.future.timeout(const Duration(seconds: 10));
    expect(session.files.single.fileName, 'resume.bin');
    expect(session.chunkSize, 512 * 1024);
    await receiver.acceptIncoming(session.sessionId, {0: 1});

    final resume = await ackFuture.timeout(const Duration(seconds: 10));
    expect(resume, {0: 1});
  });
}