import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../transport_channel.dart';
import '../device_info.dart';
import '../../core/utils/chunker.dart';

class LanSocketTransport extends TransportChannel {
  static const int _defaultPort = 48732;
  static const int _discoveryPort = 48733;
  
  ServerSocket? _serverSocket;
  Socket? _connectedSocket;
  ServerSocket? _discoveryServer;
  RawDatagramSocket? _broadcastSocket;
  final List<DeviceInfo> _discoveredDevices = [];
  Timer? _broadcastTimer;
  String _deviceName = 'Desktop';
  
  final StreamController<Uint8List> _dataController =
      StreamController<Uint8List>.broadcast();
  Uint8List _receiveBuffer = Uint8List(0);

  @override
  void setDeviceName(String name) => _deviceName = name;

  @override
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 15)}) async {
    updateState(TransportState.discovering);
    _discoveredDevices.clear();

    try {
      _discoveryServer = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
      );
      _discoveryServer!.listen(_handleDiscoveryConnection);

      _broadcastSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      _broadcastSocket!.broadcastEnabled = true;

      _broadcastTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _sendDiscoveryBeacon(),
      );
      _sendDiscoveryBeacon();

      await Future.delayed(timeout);
      await stopDiscovery();
    } catch (e) {
      updateState(TransportState.error);
      throw TransportException('Discovery failed', e);
    }
  }

  void _sendDiscoveryBeacon() {
    if (_broadcastSocket == null) return;
    final beacon = utf8.encode(json.encode({
      'type': 'swiftshare_beacon',
      'name': _deviceName,
      'platform': 'windows',
      'port': _defaultPort,
    }));
    try {
      _broadcastSocket!.send(
        beacon,
        InternetAddress('255.255.255.255'),
        _discoveryPort,
      );
    } catch (_) {}
  }

  void _handleDiscoveryConnection(Socket socket) {
    socket.listen(
      (data) {
        try {
          final json = utf8.decode(data);
          final map = jsonDecode(json);
          if (map['type'] == 'swiftshare_beacon') {
            final device = DeviceInfo(
              id: socket.remoteAddress.address,
              name: map['name'] ?? 'Unknown',
              platform: _platformFromString(map['platform']),
              quality: ConnectionQuality.good,
              address: socket.remoteAddress.address,
            );
            if (!_discoveredDevices.any((d) => d.id == device.id)) {
              _discoveredDevices.add(device);
              deviceFoundController.add(device);
            }
          }
        } catch (_) {}
      },
      onError: (_) {},
    );
  }

  DevicePlatform _platformFromString(String? p) {
    switch (p) {
      case 'android':
        return DevicePlatform.android;
      case 'windows':
        return DevicePlatform.windows;
      case 'web':
        return DevicePlatform.web;
      default:
        return DevicePlatform.unknown;
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _broadcastTimer?.cancel();
    _broadcastSocket?.close();
    _broadcastSocket = null;
    await _discoveryServer?.close();
    _discoveryServer = null;
    if (state == TransportState.discovering) {
      updateState(TransportState.disconnected);
    }
  }

  @override
  Future<void> connectToDevice(DeviceInfo device) async {
    updateState(TransportState.connecting);

    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        _defaultPort,
      );

      final completer = Completer<void>();
      _serverSocket!.listen(
        (socket) {
          _connectedSocket = socket;
          _setupDataListener(socket);
          updateState(TransportState.connected);
          if (!completer.isCompleted) completer.complete();
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      );

      _connectedSocket = await Socket.connect(
        device.address ?? device.id,
        _defaultPort,
      );
      _setupDataListener(_connectedSocket!);
      updateState(TransportState.connected);
      if (!completer.isCompleted) completer.complete();

      await completer.future;
    } catch (e) {
      updateState(TransportState.error);
      throw TransportException('Connection failed', e);
    }
  }

  void _setupDataListener(Socket socket) {
    socket.listen(
      (data) {
        _receiveBuffer = Uint8List.fromList([..._receiveBuffer, ...data]);
        _processBuffer();
      },
      onError: (_) {
        updateState(TransportState.error);
      },
      onDone: () {
        updateState(TransportState.disconnected);
      },
    );
  }

  void _processBuffer() {
    while (_receiveBuffer.length >= 4) {
      final length = ByteData.sublistView(_receiveBuffer).getUint32(0);
      if (_receiveBuffer.length < 4 + length) break;

      final messageBytes = _receiveBuffer.sublist(4, 4 + length);
      _receiveBuffer = _receiveBuffer.sublist(4 + length);

      try {
        final json = utf8.decode(messageBytes);
        final message = jsonDecode(json);
        _handleMessage(message);
      } catch (_) {}
    }
  }

  void _handleMessage(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == 'chunk') {
      final metadata = ChunkMetadata.fromJson(message['metadata']);
      final data = base64Decode(message['data']);
      chunkReceivedController.add(ChunkReceivedEvent(
        fileIndex: message['fileIndex'],
        metadata: metadata,
        data: data,
      ));
    } else if (type == 'ack') {
      // Chunk acknowledged by receiver
    } else if (type == 'progress') {
      progressController.add(TransferProgress(
        fileIndex: message['fileIndex'] ?? 0,
        chunksSent: message['chunksSent'] ?? 0,
        totalChunks: message['totalChunks'] ?? 0,
        bytesTransferred: message['bytesTransferred'] ?? 0,
        totalBytes: message['totalBytes'] ?? 0,
        speed: (message['speed'] ?? 0).toDouble(),
      ));
    }
  }

  Future<void> _sendMessage(Map<String, dynamic> message) async {
    if (_connectedSocket == null) return;
    final bytes = utf8.encode(json.encode(message));
    final lengthBytes = ByteData(4)..setUint32(0, bytes.length);
    _connectedSocket!.add([...lengthBytes.buffer.asUint8List(), ...bytes]);
    await _connectedSocket!.flush();
  }

  @override
  Future<void> sendChunk(int fileIndex, ChunkMetadata metadata, Uint8List data) async {
    updateState(TransportState.transferring);
    await _sendMessage({
      'type': 'chunk',
      'fileIndex': fileIndex,
      'metadata': metadata.toJson(),
      'data': base64Encode(data),
    });
  }

  @override
  Future<void> sendFileComplete(int fileIndex, String fileHash) async {
    await _sendMessage({
      'type': 'file_complete',
      'fileIndex': fileIndex,
      'hash': fileHash,
    });
  }

  @override
  void pause() {
    updateState(TransportState.paused);
  }

  @override
  void resume() {
    updateState(TransportState.connected);
  }

  @override
  Future<void> disconnect() async {
    _connectedSocket?.close();
    _connectedSocket = null;
    await _serverSocket?.close();
    _serverSocket = null;
    updateState(TransportState.disconnected);
  }

  @override
  void dispose() {
    _dataController.close();
    disconnect();
    super.dispose();
  }
}
