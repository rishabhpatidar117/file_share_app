import 'dart:async';
import 'dart:typed_data';
import '../transport_channel.dart';
import '../device_info.dart';
import '../../core/utils/chunker.dart';

/// Android Nearby Connections transport.
///
/// Wraps Google's Nearby Connections API which uses Bluetooth/BLE for
/// discovery and initial handshake, then automatically upgrades the data
/// channel to Wi-Fi Direct for high-bandwidth payload transfer.
///
/// NOTE: This is a structural implementation of the transport interface.
/// The actual platform channel hookup to the `nearby_connections` plugin
/// is performed in the platform integration layer (lib/transport/nearby/).
class NearbyTransport extends TransportChannel {
  String _deviceName = 'Android Device';

  @override
  void setDeviceName(String name) => _deviceName = name;
  @override
  String get deviceName => _deviceName;

  @override
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 15)}) async {
    updateState(TransportState.discovering);

    // In production, this would call:
    // NearbyConnections.startDiscovery(serviceId, _deviceName, Strategy.P2P_STAR)
    // and emit discovered endpoints via deviceFoundController.

    await Future.delayed(const Duration(seconds: 2));
  }

  @override
  Future<void> stopDiscovery() async {
    // NearbyConnections.stopDiscovery()
    if (state == TransportState.discovering) {
      updateState(TransportState.disconnected);
    }
  }

  @override
  Future<void> connectToDevice(DeviceInfo device) async {
    updateState(TransportState.connecting);

    // In production:
    // NearbyConnections.requestConnection(_deviceName, device.id,
    //   connectionLifecycleCallback)

    await Future.delayed(const Duration(seconds: 1));
    updateState(TransportState.connected);
  }

  @override
  List<PeerConnection> get connectedPeers => const [];

  @override
  Future<void> sendChat(String peerId, String text) async {}

  @override
  Future<void> sendChatBroadcast(String text) async {}

  @override
  Future<void> disconnect() async {
    // NearbyConnections.disconnectFromEndpoint(endpointId)
    updateState(TransportState.disconnected);
  }

  @override
  Future<void> disconnectPeers() async {
    // Stub transport mirrors disconnect semantics.
    updateState(TransportState.disconnected);
  }

  @override
  Future<void> sendChunk(int fileIndex, ChunkMetadata metadata, Uint8List data) async {
    if (state == TransportState.paused) return;
    updateState(TransportState.transferring);

    // In production:
    // NearbyConnections.sendPayloadBytes(endpointId, serialized payload)

    await Future.delayed(const Duration(milliseconds: 5));
  }

  @override
  Future<void> sendFileComplete(
    int fileIndex,
    String fileHash, {
    String fileName = '',
    int fileSize = 0,
    int totalChunks = 0,
  }) async {
    // Send a completion marker payload.
  }

  @override
  Future<ResumePoints> sendSessionStart(
    String sessionId,
    String deviceName,
    List<SessionFileMeta> files, {
    int? chunkSize,
    String? peerId,
  }) async {
    return <int, int>{};
  }

  @override
  Future<void> sendSessionComplete(String sessionId) async {}

  @override
  Future<void> sendSessionFailed(String sessionId, String reason) async {}

  @override
  Future<void> startIncoming() async {
    // In production: NearbyConnections.startAdvertising(...)
  }

  @override
  Future<void> stopIncoming() async {}

  @override
  Future<void> acceptIncoming(String sessionId, ResumePoints resumePoints) async {}

  @override
  Future<void> sendChunkAck(String sessionId, int fileIndex, int chunkIndex) async {}

  @override
  Future<void> sendChunkError(String sessionId, int fileIndex, int chunkIndex) async {}

  @override
  Future<void> sendFileCompleteAck(String sessionId, int fileIndex) async {}

  @override
  Future<void> sendFileRetry(String sessionId, int fileIndex) async {}

  @override
  void pause() {
    updateState(TransportState.paused);
  }

  @override
  void resume() {
    updateState(TransportState.connected);
  }
}