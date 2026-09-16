import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/transport/lan_socket/lan_socket_transport.dart';
import 'package:swiftshare/transport/device_info.dart';
import 'package:swiftshare/transport/transport_channel.dart';
import 'package:swiftshare/core/utils/chunker.dart';

/// A minimal raw TCP peer that speaks the LAN transport wire protocol, so we
/// can assert on the exact bytes a `LanSocketTransport` emits: compact binary
/// v2 chunk frames (`SSCH` magic) vs. the legacy base64-in-JSON fallback used
/// by v1 peers.
class _RawPeer {
  final int version; // echoed back in hello_ack
  final List<int> _acc = [];
  final List<Uint8List> chunkPayloads = [];
  final List<String> receivedTypes = [];
  bool sawBinaryMagic = false;
  bool sawLegacyChunk = false;
  Socket? _socket;
  ServerSocket? _server;

  _RawPeer(this.version);

  Future<(String, int)> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((socket) {
      _socket = socket;
      socket.listen((data) {
        _acc.addAll(data);
        _drain(socket);
      });
    });
    final port = _server!.port;
    return ('127.0.0.1', port);
  }

  /// Big-endian uint32 read from the byte list (values are 0..255).
  int _readUint32(List<int> b, int offset) =>
      (b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3];

  void _drain(Socket socket) {
    while (true) {
      if (_acc.length < 4) return;
      final length = _readUint32(_acc, 0);
      if (_acc.length < 4 + length) return;
      final frame = Uint8List.fromList(_acc.sublist(4, 4 + length));
      _acc.removeRange(0, 4 + length);
      _handle(socket, frame);
    }
  }

  void _handle(Socket socket, Uint8List frame) {
    if (frame.length >= 4 &&
        frame[0] == 0x53 &&
        frame[1] == 0x53 &&
        frame[2] == 0x43 &&
        frame[3] == 0x48) {
      // v2 binary chunk frame: [4B metaLen][utf8 json meta][raw payload]
      sawBinaryMagic = true;
      final metaLen = _readUint32(frame, 4);
      final meta = jsonDecode(utf8.decode(frame.sublist(8, 8 + metaLen)));
      final payload = Uint8List.fromList(frame.sublist(8 + metaLen));
      receivedTypes.add('chunk');
      chunkPayloads.add(payload);
      _reply(socket, {
        'type': 'chunk_ack',
        'fileIndex': meta['fileIndex'],
        'chunkIndex': meta['metadata']['index'],
      });
      return;
    }

    final message = jsonDecode(utf8.decode(frame));
    receivedTypes.add(message['type'] as String);
    switch (message['type']) {
      case 'hello':
        _reply(socket, {
          'type': 'hello_ack',
          'name': 'RawPeer',
          'platform': 'test',
          'ver': version,
        });
        break;
      case 'session_start':
        _reply(socket, {'type': 'session_ack', 'received': <int, int>{}});
        break;
      case 'chunk':
        sawLegacyChunk = true;
        chunkPayloads.add(base64Decode(message['data'] as String));
        _reply(socket, {
          'type': 'chunk_ack',
          'fileIndex': message['fileIndex'],
          'chunkIndex': message['metadata']['index'],
        });
        break;
    }
  }

  void _reply(Socket socket, Map<String, dynamic> message) {
    final bytes = utf8.encode(jsonEncode(message));
    final frame = Uint8List(4 + bytes.length);
    ByteData.sublistView(frame).setUint32(0, bytes.length);
    frame.setRange(4, frame.length, bytes);
    socket.add(frame);
  }

  Future<void> close() async {
    await _server?.close();
    await _socket?.close();
  }
}

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
      await receiver.sendChunkAck(event.sessionId, event.fileIndex, event.metadata.index);
      if (gotDataEvent.isCompleted) return;
      gotDataEvent.complete();
    });

    // File-complete handshake with hash verification.
    var receivedHash = '';
    receiver.onIncomingFileComplete.listen((event) async {
      receivedHash = event.sha256;
      expect(event.sha256, sourceHash);
      expect(event.fileName, 'payload.bin');
      await receiver.sendFileCompleteAck(event.sessionId, event.fileIndex);
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
      await receiver.sendChunkError(event.sessionId, event.fileIndex, event.metadata.index);
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
      await receiver.sendChunkAck(event.sessionId, event.fileIndex, event.metadata.index);
    });
    receiver.onIncomingFileComplete.listen((event) async {
      expect(event.sha256, hashA);
      await receiver.sendFileCompleteAck(event.sessionId, event.fileIndex);
    });

    // Sender side (A) also handles B's reverse session over the same socket.
    sender.onIncomingSession.listen((session) async {
      expect(session.remoteDeviceName, 'DeviceB');
      await sender.acceptIncoming(session.sessionId, {});
    });
    sender.onChunkReceived.listen((event) async {
      receivedBySender.add(event.data);
      await sender.sendChunkAck(event.sessionId, event.fileIndex, event.metadata.index);
    });
    sender.onIncomingFileComplete.listen((event) async {
      expect(event.sha256, hashB);
      await sender.sendFileCompleteAck(event.sessionId, event.fileIndex);
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
        await receiver.sendChunkError(event.sessionId, event.fileIndex, event.metadata.index);
      } else {
        receivedData.add(event.data);
        await receiver.sendChunkAck(event.sessionId, event.fileIndex, event.metadata.index);
        if (!gotAll.isCompleted) gotAll.complete();
      }
    });

    receiver.onIncomingFileComplete.listen((event) async {
      await receiver.sendFileCompleteAck(event.sessionId, event.fileIndex);
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
      await receiver.sendChunkAck(event.sessionId, event.fileIndex, event.metadata.index);
      if (receivedParts.length == reader.totalChunks && !gotAll.isCompleted) {
        gotAll.complete();
      }
    });
    receiver.onIncomingFileComplete.listen((event) async {
      await receiver.sendFileCompleteAck(event.sessionId, event.fileIndex);
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

  test('v2 peers exchange compact binary chunk frames (SSCH magic)', () async {
    final peer = _RawPeer(2);
    final (addr, port) = await peer.start();

    await sender.connectToDevice(
      DeviceInfo(id: 'raw', name: 'Raw', address: addr, port: port),
    );
    await waitForConnected(sender);

    final resume = await sender.sendSessionStart(
      'session-bin',
      'SenderTest',
      const [
        SessionFileMeta(
          index: 0,
          fileName: 'f.bin',
          fileSize: 8,
          totalChunks: 2,
        ),
      ],
      chunkSize: 4,
    );
    expect(resume, const <int, int>{});

    const meta0 = ChunkMetadata(
      index: 0,
      offset: 0,
      size: 4,
      crc32cChecksum: 0,
      isLast: false,
    );
    const meta1 = ChunkMetadata(
      index: 1,
      offset: 4,
      size: 4,
      crc32cChecksum: 0,
      isLast: true,
    );
    final chunk0 = Uint8List.fromList([1, 2, 3, 4]);
    final chunk1 = Uint8List.fromList([5, 6, 7, 8]);
    await sender.sendChunk(0, meta0, chunk0);
    await sender.sendChunk(0, meta1, chunk1);

    expect(peer.sawBinaryMagic, isTrue);
    expect(peer.sawLegacyChunk, isFalse);
    expect(peer.chunkPayloads, [chunk0, chunk1]);
    expect(peer.receivedTypes, contains('hello'));
    await sender.disconnect();
    await peer.close();
  });

  test('v1 peers fall back to base64 JSON chunk frames', () async {
    final peer = _RawPeer(1);
    final (addr, port) = await peer.start();

    await sender.connectToDevice(
      DeviceInfo(id: 'raw', name: 'Raw', address: addr, port: port),
    );
    await waitForConnected(sender);

    await sender.sendSessionStart(
      'session-legacy',
      'SenderTest',
      const [
        SessionFileMeta(
          index: 0,
          fileName: 'f.bin',
          fileSize: 4,
          totalChunks: 1,
        ),
      ],
    );

    const meta = ChunkMetadata(
      index: 0,
      offset: 0,
      size: 4,
      crc32cChecksum: 0,
      isLast: true,
    );
    await sender.sendChunk(0, meta, Uint8List.fromList([9, 9, 9, 9]));

    expect(peer.sawBinaryMagic, isFalse);
    expect(peer.sawLegacyChunk, isTrue);
    expect(peer.chunkPayloads.single, [9, 9, 9, 9]);
    await sender.disconnect();
    await peer.close();
  });

  test(
      'owner mode: the listening side drives a session over an ACCEPTED socket '
      '(the Wi-Fi Direct group-owner path)', () async {
    // In Wi-Fi Direct the group owner has no outbound connect to make — the
    // client reaches the owner inbound. The engine is direction-neutral, so the
    // owner must be able to run a full session over a socket it merely accepted.
    final owner = LanSocketTransport();
    final client = LanSocketTransport();
    final ownerSource = '${sandbox.path}/owner-source.bin';
    await File(ownerSource).writeAsBytes(
      Uint8List.fromList(List<int>.generate(1024, (i) => i % 251)),
    );
    final reader = ChunkedFileReader(file: File(ownerSource));

    // Free the shared service port held by setUp's `receiver` so the connection
    // deterministically reaches this test's `owner` listener.
    await receiver.stopIncoming();

    await owner.startIncoming();
    // Client connects out to the owner (the listener) on loopback.
    await client.connectToDevice(const DeviceInfo(
      id: 'owner-loopback',
      name: 'Owner',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForConnected(client);
    await waitForConnected(owner);

    final receivedParts = <Uint8List>[];
    final done = Completer<void>();
    client.onIncomingSession.listen((session) async {
      await client.acceptIncoming(session.sessionId, {});
    });
    client.onChunkReceived.listen((event) async {
      receivedParts.add(event.data);
      await client.sendChunkAck(event.sessionId, event.fileIndex, event.metadata.index);
    });
    client.onIncomingFileComplete.listen((event) async {
      await client.sendFileCompleteAck(event.sessionId, event.fileIndex);
      done.complete();
    });

    // The OWNER starts the transfer from its accepted (inbound) socket.
    final ownerHash = await computeFileHash(ownerSource);
    final resume = await owner.sendSessionStart(
      'owner-session',
      'OwnerTest',
      const [
        SessionFileMeta(
          index: 0,
          fileName: 'owner.bin',
          fileSize: 1024,
          totalChunks: 1,
        ),
      ],
    );
    expect(resume, {});

    final chunk = await reader.readChunk(0);
    await owner.sendChunk(0, chunk.metadata, chunk.bytes);
    await owner.sendFileComplete(
      0,
      ownerHash,
      fileName: 'owner.bin',
      fileSize: reader.totalSize,
      totalChunks: reader.totalChunks,
    );
    await done.future.timeout(const Duration(seconds: 30));

    expect(Uint8List.fromList(receivedParts.expand((p) => p).toList()),
        await File(ownerSource).readAsBytes());
    await owner.disconnect();
    await client.disconnect();
  });

  test(
      'session_failed propagates a terminal state to the peer in BOTH '
      'directions (no more sender=failed / receiver=waiting divergence)', () async {
    // Build the loopback link: `sender` initiates out, `receiver` accepts in.
    await sender.connectToDevice(const DeviceInfo(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: LanSocketTransport.servicePort,
    ));
    await waitForConnected(sender);
    await waitForConnected(receiver);

    // Sender → receiver abort.
    final senderFailure = Completer<SessionFailed>();
    final rxSub = receiver.onSessionFailed.listen(senderFailure.complete);
    await sender.sendSessionFailed('session-a', 'source unreadable');
    final seenByReceiver =
        await senderFailure.future.timeout(const Duration(seconds: 5));
    expect(seenByReceiver.sessionId, 'session-a');
    expect(seenByReceiver.reason, contains('source unreadable'));

    // Receiver → sender abort (the receiver writes to the socket it accepted).
    final receiverFailure = Completer<SessionFailed>();
    final txSub = sender.onSessionFailed.listen(receiverFailure.complete);
    await receiver.sendSessionFailed('session-b', 'disk full');
    final seenBySender =
        await receiverFailure.future.timeout(const Duration(seconds: 5));
    expect(seenBySender.sessionId, 'session-b');
    expect(seenBySender.reason, contains('disk full'));

    await txSub.cancel();
    await rxSub.cancel();
  });
}