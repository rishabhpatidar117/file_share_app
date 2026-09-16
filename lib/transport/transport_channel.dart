import 'dart:async';
import 'package:flutter/foundation.dart';
import 'device_info.dart';
import 'transport_kind.dart';
import '../core/utils/chunker.dart';

/// Default TCP service port shared across LAN transports.
const int kSwiftShareServicePort = 48732;

enum TransportState {
  disconnected,
  discovering,

  /// Receiver is advertising on the LAN, no live peer yet.
  listening,
  connecting,
  connected,
  transferring,
  paused,
  error,
}

class TransportException implements Exception {
  final String message;
  final Object? cause;
  const TransportException(this.message, [this.cause]);
  @override
  String toString() => 'TransportException: $message${cause != null ? ' ($cause)' : ''}';
}

/// Metadata for one file offered by a remote device.
class SessionFileMeta {
  final int index;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final int receivedChunks;
  final String? sha256;

  const SessionFileMeta({
    required this.index,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
    this.receivedChunks = 0,
    this.sha256,
  });

  Map<String, dynamic> toJson() => {
    'index': index,
    'fileName': fileName,
    'fileSize': fileSize,
    'totalChunks': totalChunks,
    'receivedChunks': receivedChunks,
    'sha256': sha256,
  };

  factory SessionFileMeta.fromJson(Map<String, dynamic> json) => SessionFileMeta(
    index: json['index'] as int,
    fileName: json['fileName'] as String,
    fileSize: json['fileSize'] as int,
    totalChunks: json['totalChunks'] as int,
    receivedChunks: json['receivedChunks'] as int? ?? 0,
    sha256: json['sha256'] as String?,
  );
}

/// A remote device wants to send us files.
class IncomingSession {
  final String sessionId;
  final String remoteDeviceName;
  final List<SessionFileMeta> files;
  final int chunkSize;

  const IncomingSession({
    required this.sessionId,
    required this.remoteDeviceName,
    required this.files,
    this.chunkSize = 512 * 1024,
  });

  int get totalBytes => files.fold(0, (sum, f) => sum + f.fileSize);
}

/// A remote sender finished transferring one file; receiver must verify the
/// SHA-256 and ack (or request a resend of the whole file).
class IncomingFileComplete {
  final String sessionId;
  final int fileIndex;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final String sha256;

  const IncomingFileComplete({
    required this.sessionId,
    required this.fileIndex,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
    required this.sha256,
  });
}

/// Resume negotiation result: fileIndex -> number of chunks already received.
typedef ResumePoints = Map<int, int>;

abstract class TransportChannel {
  @protected
  final StreamController<DeviceInfo> deviceFoundController =
      StreamController<DeviceInfo>.broadcast();
  @protected
  final StreamController<TransportState> stateController =
      StreamController<TransportState>.broadcast();
  @protected
  final StreamController<ChunkReceivedEvent> chunkReceivedController =
      StreamController<ChunkReceivedEvent>.broadcast();
  @protected
  final StreamController<TransferProgress> progressController =
      StreamController<TransferProgress>.broadcast();
  @protected
  final StreamController<IncomingSession> incomingSessionController =
      StreamController<IncomingSession>.broadcast();
  @protected
  final StreamController<IncomingFileComplete> incomingFileCompleteController =
      StreamController<IncomingFileComplete>.broadcast();
  @protected
  final StreamController<void> incomingSessionCompleteController =
      StreamController<void>.broadcast();
  @protected
  final StreamController<PeerConnection> peerConnectedController =
      StreamController<PeerConnection>.broadcast();
  @protected
  final StreamController<String> peerDisconnectedController =
      StreamController<String>.broadcast();

  Stream<DeviceInfo> get onDeviceFound => deviceFoundController.stream;
  Stream<TransportState> get onStateChanged => stateController.stream;
  Stream<ChunkReceivedEvent> get onChunkReceived => chunkReceivedController.stream;
  Stream<TransferProgress> get onProgress => progressController.stream;
  Stream<IncomingSession> get onIncomingSession => incomingSessionController.stream;
  Stream<IncomingFileComplete> get onIncomingFileComplete =>
      incomingFileCompleteController.stream;
  Stream<void> get onIncomingSessionComplete =>
      incomingSessionCompleteController.stream;

  /// A live peer link was established (either this device initiated it or the
  /// pair completed the hello/hello_ack handshake).
  Stream<PeerConnection> get onPeerConnected => peerConnectedController.stream;

  /// A previously established peer link was torn down (disconnect, error or
  /// socket close). Emits the peer's name.
  Stream<String> get onPeerDisconnected => peerDisconnectedController.stream;

  TransportState _state = TransportState.disconnected;
  TransportState get state => _state;

  @protected
  void updateState(TransportState newState) {
    _state = newState;
    stateController.add(newState);
  }

  /// Configures the device name announced during discovery.
  void setDeviceName(String name) {}

  /// The transport class this implementation uses to put the peers on a shared
  /// network segment. Transfer semantics (chunking, retry, resume, CRC,
  /// scheduling) are identical across every kind; only the link is different.
  TransportKind get transportKind => TransportKind.lan;

  // ---- Sender (outgoing) side ----

  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 15)});
  Future<void> stopDiscovery();
  Future<void> connectToDevice(DeviceInfo device);

  /// Declare an outgoing transfer session. Resolves once the receiver
  /// acknowledges with its resume points.
  Future<ResumePoints> sendSessionStart(
    String sessionId,
    String deviceName,
    List<SessionFileMeta> files, {
    int? chunkSize,
  });

  /// Send one chunk; completes when the receiver acknowledges it.
  /// Throws [TransportException] if the receiver rejected the chunk, in which
  /// case the sender should retry the same chunk.
  Future<void> sendChunk(int fileIndex, ChunkMetadata metadata, Uint8List data);

  /// Send a file-complete marker; resolves when the receiver confirms the
  /// whole file (SHA-256) matches.
  Future<void> sendFileComplete(
    int fileIndex,
    String fileHash, {
    String fileName = '',
    int fileSize = 0,
    int totalChunks = 0,
  });

  /// Notify the receiver that all files have been sent and verified.
  Future<void> sendSessionComplete(String sessionId);

  /// Release the peer links (sends a disconnect frame so the peer notices too),
  /// keeping any local listener/discovery sockets running.
  Future<void> disconnectPeers();

  Future<void> disconnect();

  // ---- Receiver (incoming) side ----

  /// Start listening for incoming transfer requests.
  Future<void> startIncoming();
  Future<void> stopIncoming();

  /// Accept an incoming session, telling the sender where to resume from.
  Future<void> acceptIncoming(String sessionId, ResumePoints resumePoints);

  /// Confirm a received chunk (CRC ok) so the sender continues.
  Future<void> sendChunkAck(int fileIndex, int chunkIndex);

  /// Report a bad chunk so the sender retransmits it.
  Future<void> sendChunkError(int fileIndex, int chunkIndex);

  /// Confirm the whole file verified (SHA-256) so the sender moves on.
  Future<void> sendFileCompleteAck(int fileIndex);

  /// Request the sender retransmit every chunk of a corrupt file.
  Future<void> sendFileRetry(int fileIndex);

  void pause();
  void resume();

  void dispose() {
    deviceFoundController.close();
    stateController.close();
    chunkReceivedController.close();
    progressController.close();
    incomingSessionController.close();
    incomingFileCompleteController.close();
    incomingSessionCompleteController.close();
    peerConnectedController.close();
    peerDisconnectedController.close();
  }
}

/// A live, handshaked peer link.
class PeerConnection {
  final String deviceName;
  const PeerConnection({required this.deviceName});
}

class ChunkReceivedEvent {
  final int fileIndex;
  final ChunkMetadata metadata;
  final Uint8List data;

  const ChunkReceivedEvent({
    required this.fileIndex,
    required this.metadata,
    required this.data,
  });
}

class TransferProgress {
  final int fileIndex;
  final int chunksSent;
  final int totalChunks;
  final int bytesTransferred;
  final int totalBytes;
  final double speed; // bytes per second
  final Duration? estimatedTimeRemaining;

  const TransferProgress({
    required this.fileIndex,
    required this.chunksSent,
    required this.totalChunks,
    required this.bytesTransferred,
    required this.totalBytes,
    this.speed = 0,
    this.estimatedTimeRemaining,
  });

  double get fraction => totalChunks > 0 ? chunksSent / totalChunks : 0;
}