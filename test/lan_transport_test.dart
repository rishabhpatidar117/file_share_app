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

  /// connectToDevice returns as soon as `hello` is queued; the `hello_ack`
  /// arrives asynchronously. Wait for the handshake to complete so assertions
  /// on the transport state are not racing the socket listener.
  Future<void> waitForState(LanSocketTransport t, TransportState expected,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (t.state != expected) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for state $expected (was ${t.state})');
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> waitForConnected(LanSocketTransport t,
      {Duration timeout = const Duration(seconds: 5)}) {
    return waitForState(t, TransportState.connected, timeout: timeout);
  }

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
    await waitForConnected(sender);

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

  test('both ends know they are connected after the handshake', () async {
    sender.setDeviceName('Loopback');
    final receiverConnected = receiver.onPeerConnected.first;

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForConnected(sender);

    final peer = await receiverConnected.timeout(const Duration(seconds: 5));
    expect(peer.deviceName, 'Loopback');
    expect(receiver.state, TransportState.connected);
  });

  test('bidirectional transfer over a single established connection', () async {
    // A -> B
    final dataA = Uint8List.fromList(
      List<int>.generate(250000, (i) => i % 251),
    );
    // B -> A (sent back over the same accepted socket)
    final dataB = Uint8List.fromList(
      List<int>.generate(180000, (i) => i % 127),
    );
    final fileA = '${sandbox.path}/from_a.bin';
    final fileB = '${sandbox.path}/from_b.bin';
    await File(fileA).writeAsBytes(dataA);
    await File(fileB).writeAsBytes(dataB);
    final hashA = await computeFileHash(fileA);
    final hashB = await computeFileHash(fileB);
    final readerA = ChunkedFileReader(file: File(fileA));
    final readerB = ChunkedFileReader(file: File(fileB));

    final receivedByReceiver = <Uint8List>[];
    final receivedBySender = <Uint8List>[];

    // Receiver side (B) handles A's incoming session.
    receiver.onIncomingSession.listen((session) async {
      expect(session.remoteDeviceName, 'DeviceA');
      await receiver.acceptIncoming(session.sessionId, {});
    });
    receiver.onChunkReceived.listen((event) async {
      receivedByReceiver.add(event.data);
      await receiver.sendChunkAck(event.fileIndex, event.metadata.index);
    });
    receiver.onIncomingFileComplete.listen((event) async {
      expect(event.sha256, hashA);
      await receiver.sendFileCompleteAck(event.fileIndex);
    });

    // Sender side (A) also handles B's reverse session over the same socket.
    sender.onIncomingSession.listen((session) async {
      expect(session.remoteDeviceName, 'DeviceB');
      await sender.acceptIncoming(session.sessionId, {});
    });
    sender.onChunkReceived.listen((event) async {
      receivedBySender.add(event.data);
      await sender.sendChunkAck(event.fileIndex, event.metadata.index);
    });
    sender.onIncomingFileComplete.listen((event) async {
      expect(event.sha256, hashB);
      await sender.sendFileCompleteAck(event.fileIndex);
    });

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));

    // A -> B.
    await sender.sendSessionStart(
      'duplex-a',
      'DeviceA',
      const [
        SessionFileMeta(index: 0, fileName: 'from_a.bin', fileSize: 250000, totalChunks: 1),
      ],
    );
    final chunkA = await readerA.readChunk(0);
    await sender.sendChunk(0, chunkA.metadata, chunkA.bytes);
    await sender.sendFileComplete(0, hashA,
        fileName: 'from_a.bin', fileSize: readerA.totalSize, totalChunks: 1);

    // B -> A over the same link A opened.
    await receiver.sendSessionStart(
      'duplex-b',
      'DeviceB',
      const [
        SessionFileMeta(index: 0, fileName: 'from_b.bin', fileSize: 180000, totalChunks: 1),
      ],
    );
    final chunkB = await readerB.readChunk(0);
    await receiver.sendChunk(0, chunkB.metadata, chunkB.bytes);
    await receiver.sendFileComplete(0, hashB,
        fileName: 'from_b.bin', fileSize: readerB.totalSize, totalChunks: 1);

    final bytesToB = <int>[];
    for (final p in receivedByReceiver) {
      bytesToB.addAll(p);
    }
    final bytesToA = <int>[];
    for (final p in receivedBySender) {
      bytesToA.addAll(p);
    }
    expect(bytesToB, dataA);
    expect(bytesToA, dataB);
  });

  test('disconnect tears the link down on both ends', () async {
    sender.setDeviceName('Loopback');
    final peerGone = receiver.onPeerDisconnected.first;

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForConnected(sender);

    await sender.disconnectPeers();

    final gone = await peerGone.timeout(const Duration(seconds: 5));
    expect(gone, 'Loopback');
    // Sender has no local server running; the receiver keeps listening.
    await waitForState(sender, TransportState.disconnected);
    expect(receiver.state, TransportState.listening);
  });

  test('retransmit of a rejected chunk recovers on second send', () async {
    sourcePath = '${sandbox.path}/retry.bin';
    await File(sourcePath).writeAsBytes(List.filled(64, 7));
    final reader = ChunkedFileReader(file: File(sourcePath));
    final sourceHash = await computeFileHash(sourcePath);

    final receivedData = <Uint8List>[];
    final gotAll = Completer<void>();
    var rejectedOnce = false;

    receiver.onIncomingSession.listen((s) async {
      await receiver.acceptIncoming(s.sessionId, {0: 0});
    });

    receiver.onChunkReceived.listen((event) async {
      // First arrival: reject (simulates CRC mismatch).  The retransmit
      // (same chunk index) is accepted.
      if (!rejectedOnce) {
        rejectedOnce = true;
        await receiver.sendChunkError(event.fileIndex, event.metadata.index);
      } else {
        receivedData.add(event.data);
        await receiver.sendChunkAck(event.fileIndex, event.metadata.index);
        if (!gotAll.isCompleted) gotAll.complete();
      }
    });

    receiver.onIncomingFileComplete.listen((event) async {
      await receiver.sendFileCompleteAck(event.fileIndex);
    });

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForConnected(sender);

    await sender.sendSessionStart(
      'session-retry',
      'SenderTest',
      const [
        SessionFileMeta(index: 0, fileName: 'retry.bin', fileSize: 64, totalChunks: 1),
      ],
    );

    final chunk = await reader.readChunk(0);
    // First send → receiver errors it back.
    try {
      await sender.sendChunk(0, chunk.metadata, chunk.bytes);
      fail('Expected TransportException');
    } catch (_) {
      // Receiver rejected the chunk as expected.
    }
    // Retransmit → receiver accepts.
    await sender.sendChunk(0, chunk.metadata, chunk.bytes);
    await gotAll.future.timeout(const Duration(seconds: 10));

    expect(receivedData.single, chunk.bytes);

    await sender.sendFileComplete(
      0,
      sourceHash,
      fileName: 'retry.bin',
      fileSize: reader.totalSize,
      totalChunks: 1,
    );
  });

  test('chunks delivered out of order reconstruct the correct data', () async {
    sourcePath = '${sandbox.path}/ooo.bin';
    final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    await File(sourcePath).writeAsBytes(data);
    final reader = ChunkedFileReader(file: File(sourcePath), chunkSize: 4);
    expect(reader.totalChunks, 3); // [1..4] [5..8] [9,10]
    final sourceHash = await computeFileHash(sourcePath);

    final receivedParts = <int, Uint8List>{};
    final deliveryOrder = <int>[];
    final gotAll = Completer<void>();

    receiver.onIncomingSession.listen((s) async {
      await receiver.acceptIncoming(s.sessionId, {0: 0});
    });
    receiver.onChunkReceived.listen((event) async {
      deliveryOrder.add(event.metadata.index);
      receivedParts[event.metadata.index] = event.data;
      await receiver.sendChunkAck(event.fileIndex, event.metadata.index);
      if (receivedParts.length == reader.totalChunks && !gotAll.isCompleted) {
        gotAll.complete();
      }
    });
    receiver.onIncomingFileComplete.listen((event) async {
      await receiver.sendFileCompleteAck(event.fileIndex);
    });

    await sender.connectToDevice(const DeviceInfo(
      id: 'loopback',
      name: 'Loopback',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForConnected(sender);

    await sender.sendSessionStart(
      'session-ooo',
      'SenderTest',
      const [
        SessionFileMeta(
          index: 0,
          fileName: 'ooo.bin',
          fileSize: 10,
          totalChunks: 3,
        ),
      ],
      chunkSize: 4,
    );

    // Read all chunks, then send in out-of-order sequence: 0 → 2 → 1.
    final chunks = <ChunkData>[];
    for (var i = 0; i < reader.totalChunks; i++) {
      chunks.add(await reader.readChunk(i));
    }
    await sender.sendChunk(0, chunks[0].metadata, chunks[0].bytes);
    await sender.sendChunk(0, chunks[2].metadata, chunks[2].bytes);
    await sender.sendChunk(0, chunks[1].metadata, chunks[1].bytes);
    await gotAll.future.timeout(const Duration(seconds: 10));

    expect(deliveryOrder, [0, 2, 1]); // confirm out-of-order delivery

    // Reassemble in logical chunk order and verify correctness.
    final reassembled = <int>[];
    for (var i = 0; i < reader.totalChunks; i++) {
      reassembled.addAll(receivedParts[i]!);
    }
    expect(reassembled, data);

    await sender.sendFileComplete(
      0,
      sourceHash,
      fileName: 'ooo.bin',
      fileSize: reader.totalSize,
      totalChunks: 3,
    );
  });
}