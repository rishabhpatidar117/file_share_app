import 'dart:async';
import 'package:flutter/foundation.dart';
import 'device_info.dart';
import '../core/utils/chunker.dart';

enum TransportState {
  disconnected,
  discovering,
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

  Stream<DeviceInfo> get onDeviceFound => deviceFoundController.stream;
  Stream<TransportState> get onStateChanged => stateController.stream;
  Stream<ChunkReceivedEvent> get onChunkReceived => chunkReceivedController.stream;
  Stream<TransferProgress> get onProgress => progressController.stream;

  TransportState _state = TransportState.disconnected;
  TransportState get state => _state;

  @protected
  void updateState(TransportState newState) {
    _state = newState;
    stateController.add(newState);
  }

  /// Configures the device name announced during discovery.
  void setDeviceName(String name) {}

  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 15)});
  Future<void> stopDiscovery();
  Future<void> connectToDevice(DeviceInfo device);
  Future<void> disconnect();

  Future<void> sendChunk(int fileIndex, ChunkMetadata metadata, Uint8List data);
  Future<void> sendFileComplete(int fileIndex, String fileHash);

  void pause();
  void resume();

  void dispose() {
    deviceFoundController.close();
    stateController.close();
    chunkReceivedController.close();
    progressController.close();
  }
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