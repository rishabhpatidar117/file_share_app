import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../transport_channel.dart';
import '../device_info.dart';
import '../../core/utils/chunker.dart';

/// LAN transport: real UDP beacon discovery + framed TCP data channel.
///
/// Protocol (length-prefixed JSON frames over TCP):
///   hello / hello_ack
///   session_start / session_ack (with resume points)
///   chunk / chunk_ack / chunk_error
///   file_complete / file_complete_ack / file_retry
///   session_complete
///
/// Direction rule: the device that opens the TCP connection is the SENDER for
/// that connection; the listening device is the RECEIVER.
class LanSocketTransport extends TransportChannel {
  static const int servicePort = 48732;
  static const int discoveryPort = 48733;

  ServerSocket? _serverSocket;
  Socket? _connectedSocket;
  RawDatagramSocket? _discoverySocket;
  StreamSubscription<RawSocketEvent>? _discoverySub;
  final List<DeviceInfo> _discoveredDevices = [];
  final Map<String, Socket> _pendingConnections = {};
  Timer? _beaconTimer;
  Timer? _scanTimeout;
  String _deviceName = 'My Device';
  final String _instanceId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);

  // Message framing buffer.
  final List<int> _receiveBuffer = [];
  bool _listening = false;

  // Sender-side futures awaiting receiver acks.
  final Map<String, Completer<void>> _chunkAckWaiters = {};
  final Map<int, Completer<void>> _fileAckWaiters = {};
  Completer<ResumePoints>? _sessionStartWaiter;
  final Map<int, int> _resumePoints = {};

  // Receiver-side state.
  String? _activeIncomingSessionId;
  Socket? _incomingSocket;
  String _remoteDeviceName = 'Unknown';

  @override
  void setDeviceName(String name) => _deviceName = name;

  // ---------------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------------

  Future<void> _ensureDiscoverySocket() async {
    if (_discoverySocket != null) return;
    _discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    _discoverySocket!.broadcastEnabled = true;
    _discoverySub = _discoverySocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = _discoverySocket!.receive();
      if (datagram == null) return;
      _handleBeaconDatagram(datagram);
    });
  }

  void _handleBeaconDatagram(Datagram datagram) {
    try {
      final map = jsonDecode(utf8.decode(datagram.data));
      if (map['type'] != 'swiftshare_beacon') return;
      if (map['id'] == _instanceId) return; // our own beacon
      final senderAddr = datagram.address.address;

      final device = DeviceInfo(
        id: map['id'] ?? senderAddr,
        name: map['name'] ?? 'Unknown',
        platform: _platformFromString(map['platform']),
        quality: ConnectionQuality.good,
        address: senderAddr,
        port: (map['port'] as int?) ?? servicePort,
      );
      final existing = _discoveredDevices.indexWhere((d) => d.id == device.id);
      if (existing >= 0) {
        _discoveredDevices[existing] = device;
      } else {
        _discoveredDevices.add(device);
        deviceFoundController.add(device);
      }
    } catch (_) {}
  }

  void _sendBeacon() {
    if (_discoverySocket == null) return;
    final beacon = utf8.encode(json.encode({
      'type': 'swiftshare_beacon',
      'id': _instanceId,
      'name': _deviceName,
      'platform': 'windows',
      'port': servicePort,
    }));
    try {
      _discoverySocket!.send(
        beacon,
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (_) {}
  }

  @override
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 15)}) async {
    if (state == TransportState.discovering) return;
    updateState(TransportState.discovering);
    _discoveredDevices.clear();

    await _ensureDiscoverySocket();
    _scanTimeout?.cancel();
    _scanTimeout = Timer(timeout, () => stopDiscovery());

    _beaconTimer?.cancel();
    _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendBeacon();
    });
    _sendBeacon();
  }

  @override
  Future<void> stopDiscovery() async {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    if (state == TransportState.discovering) {
      updateState(TransportState.disconnected);
    }
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

  // ---------------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------------

  @override
  Future<void> connectToDevice(DeviceInfo device) async {
    updateState(TransportState.connecting);
    try {
      final socket = await Socket.connect(
        device.address!,
        device.port ?? servicePort,
        timeout: const Duration(seconds: 10),
      );
      _connectedSocket = socket;
      _remoteDeviceName = device.name;
      _setupDataListener(socket);
      await _sendMessage(socket, {
        'type': 'hello',
        'name': _deviceName,
        'platform': 'windows',
      });
      updateState(TransportState.connected);
    } catch (e) {
      updateState(TransportState.error);
      throw TransportException('Connection failed', e);
    }
  }

  @override
  Future<void> startIncoming() async {
    if (_listening) return;
    try {
      _serverSocket = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        servicePort,
        shared: true,
      );
      _listening = true;
      _serverSocket!.listen(_handleIncomingConnection);
    } catch (_) {
      // Another listening instance already owns the port; keep going.
    }
  }

  @override
  Future<void> stopIncoming() async {
    await _serverSocket?.close();
    _serverSocket = null;
    _listening = false;
  }

  void _handleIncomingConnection(Socket socket) {
    final remoteAddress = socket.remoteAddress.address;
    _pendingConnections[remoteAddress] = socket;
    socket.done.then((_) => _pendingConnections.remove(remoteAddress));
    _setupDataListener(socket);
    _sendMessage(socket, {
      'type': 'hello_ack',
      'name': _deviceName,
      'platform': 'windows',
    });
  }

  void _setupDataListener(Socket socket) {
    socket.listen(
      (data) {
        _receiveBuffer.addAll(data);
        _processBuffer(socket);
      },
      onError: (_) {
        if (identical(socket, _connectedSocket)) {
          updateState(TransportState.error);
        }
      },
      onDone: () {
        if (identical(socket, _connectedSocket)) {
          updateState(TransportState.disconnected);
        }
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Framing + message dispatch
  // ---------------------------------------------------------------------------

  void _processBuffer(Socket socket) {
    while (_receiveBuffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(_receiveBuffer))
          .getUint32(0);
      if (length > 64 * 1024 * 1024) {
        _receiveBuffer.clear();
        return;
      }
      if (_receiveBuffer.length < 4 + length) break;

      final messageBytes = _receiveBuffer.sublist(4, 4 + length);
      _receiveBuffer.removeRange(0, 4 + length);

      try {
        final message = jsonDecode(utf8.decode(messageBytes));
        if (message is Map<String, dynamic>) {
          _handleMessage(socket, message);
        }
      } catch (_) {}
    }
  }

  void _handleMessage(Socket socket, Map<String, dynamic> message) {
    final type = message['type'];

    switch (type) {
      case 'hello':
        _remoteDeviceName = message['name'] ?? 'Unknown';
        _sendMessage(socket, {
          'type': 'hello_ack',
          'name': _deviceName,
          'platform': 'windows',
        });
        break;

      case 'hello_ack':
        _remoteDeviceName = message['name'] ?? _remoteDeviceName;
        if (state == TransportState.connecting) {
          updateState(TransportState.connected);
        }
        break;

      case 'session_start':
        _activeIncomingSessionId = message['sessionId'];
        _remoteDeviceName = message['deviceName'] ?? _remoteDeviceName;
        _incomingSocket = socket;
        final chunkSize = message['chunkSize'] as int? ?? 512 * 1024;
        final files = (message['files'] as List)
            .map((f) => SessionFileMeta.fromJson(f))
            .toList();
        incomingSessionController.add(IncomingSession(
          sessionId: _activeIncomingSessionId!,
          remoteDeviceName: _remoteDeviceName,
          files: files,
          chunkSize: chunkSize,
        ));
        break;

      case 'session_ack':
        final received = message['received'];
        if (received is Map) {
          _resumePoints.clear();
          received.forEach((k, v) => _resumePoints[int.parse('$k')] = v as int);
        }
        _sessionStartWaiter?.complete(_resumePoints);
        _sessionStartWaiter = null;
        break;

      case 'chunk':
        final fileIndex = message['fileIndex'] as int;
        final metadata = ChunkMetadata.fromJson(message['metadata']);
        final data = base64Decode(message['data']);
        chunkReceivedController.add(ChunkReceivedEvent(
          fileIndex: fileIndex,
          metadata: metadata,
          data: data,
        ));
        break;

      case 'chunk_ack':
        final key = _chunkKey(message['fileIndex'], message['chunkIndex']);
        _chunkAckWaiters.remove(key)?.complete();
        break;

      case 'chunk_error':
        final key = _chunkKey(message['fileIndex'], message['chunkIndex']);
        _chunkAckWaiters.remove(key)?.completeError(
          TransportException('Receiver rejected chunk '
              '${message['fileIndex']}:${message['chunkIndex']}'),
        );
        break;

      case 'file_complete':
        incomingFileCompleteController.add(IncomingFileComplete(
          sessionId: _activeIncomingSessionId ?? '',
          fileIndex: message['fileIndex'] as int,
          fileName: message['name'] ?? '',
          fileSize: message['size'] ?? 0,
          totalChunks: message['totalChunks'] ?? 0,
          sha256: message['hash'] ?? '',
        ));
        break;

      case 'file_complete_ack':
        _fileAckWaiters.remove(message['fileIndex'] as int)?.complete();
        break;

      case 'file_retry':
        final fileIndex = message['fileIndex'] as int;
        _fileAckWaiters.remove(fileIndex)?.completeError(
          TransportException('Receiver requested a resend of file $fileIndex'),
        );
        break;

      case 'session_complete':
        incomingSessionCompleteController.add(null);
        break;
    }
  }

  String _chunkKey(int fileIndex, int chunkIndex) => '$fileIndex:$chunkIndex';

  Future<void> _sendMessage(Socket socket, Map<String, dynamic> message) async {
    final bytes = utf8.encode(json.encode(message));
    final frame = Uint8List(4 + bytes.length);
    ByteData.sublistView(frame).setUint32(0, bytes.length);
    frame.setRange(4, frame.length, bytes);
    socket.add(frame);
    await socket.flush();
  }

  // ---------------------------------------------------------------------------
  // Sender API
  // ---------------------------------------------------------------------------

  @override
  Future<ResumePoints> sendSessionStart(
    String sessionId,
    String deviceName,
    List<SessionFileMeta> files, {
    int? chunkSize,
  }) async {
    final socket = _connectedSocket;
    if (socket == null) {
      throw TransportException('Not connected to any device');
    }
    final completer = Completer<ResumePoints>();
    _sessionStartWaiter = completer;
    await _sendMessage(socket, {
      'type': 'session_start',
      'sessionId': sessionId,
      'deviceName': deviceName,
      'chunkSize': chunkSize ?? 512 * 1024,
      'files': files.map((f) => f.toJson()).toList(),
    });
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => <int, int>{},
    );
  }

  @override
  Future<void> sendChunk(int fileIndex, ChunkMetadata metadata, Uint8List data) async {
    final socket = _connectedSocket;
    if (socket == null) throw TransportException('Not connected');
    updateState(TransportState.transferring);

    final key = _chunkKey(fileIndex, metadata.index);
    final completer = Completer<void>();
    _chunkAckWaiters[key] = completer;
    await _sendMessage(socket, {
      'type': 'chunk',
      'fileIndex': fileIndex,
      'metadata': metadata.toJson(),
      'data': base64Encode(data),
    });
    await completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _chunkAckWaiters.remove(key);
        throw TransportException('Chunk $metadata.index timed out');
      },
    );
  }

  @override
  Future<void> sendFileComplete(
    int fileIndex,
    String fileHash, {
    String fileName = '',
    int fileSize = 0,
    int totalChunks = 0,
  }) async {
    final socket = _connectedSocket;
    if (socket == null) throw TransportException('Not connected');
    final completer = Completer<void>();
    _fileAckWaiters[fileIndex] = completer;
    await _sendMessage(socket, {
      'type': 'file_complete',
      'fileIndex': fileIndex,
      'hash': fileHash,
      'name': fileName,
      'size': fileSize,
      'totalChunks': totalChunks,
    });
    await completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => completer.complete(),
    );
    _fileAckWaiters.remove(fileIndex);
  }

  @override
  Future<void> sendSessionComplete(String sessionId) async {
    final socket = _connectedSocket;
    if (socket == null) return;
    await _sendMessage(socket, {
      'type': 'session_complete',
      'sessionId': sessionId,
    });
  }

  // ---------------------------------------------------------------------------
  // Receiver API
  // ---------------------------------------------------------------------------

  @override
  Future<void> acceptIncoming(String sessionId, ResumePoints resumePoints) async {
    final socket = _incomingSocket;
    if (socket == null) return;
    await _sendMessage(socket, {
      'type': 'session_ack',
      'sessionId': sessionId,
      'received': resumePoints.map((k, v) => MapEntry('$k', v)),
    });
  }

  @override
  Future<void> sendChunkAck(int fileIndex, int chunkIndex) async {
    final socket = _incomingSocket;
    if (socket == null) return;
    await _sendMessage(socket, {
      'type': 'chunk_ack',
      'fileIndex': fileIndex,
      'chunkIndex': chunkIndex,
    });
  }

  @override
  Future<void> sendChunkError(int fileIndex, int chunkIndex) async {
    final socket = _incomingSocket;
    if (socket == null) return;
    await _sendMessage(socket, {
      'type': 'chunk_error',
      'fileIndex': fileIndex,
      'chunkIndex': chunkIndex,
    });
  }

  @override
  Future<void> sendFileCompleteAck(int fileIndex) async {
    final socket = _incomingSocket;
    if (socket == null) return;
    await _sendMessage(socket, {
      'type': 'file_complete_ack',
      'fileIndex': fileIndex,
    });
  }

  @override
  Future<void> sendFileRetry(int fileIndex) async {
    final socket = _incomingSocket;
    if (socket == null) return;
    await _sendMessage(socket, {
      'type': 'file_retry',
      'fileIndex': fileIndex,
    });
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

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
    final sockets = <Socket>{};
    if (_connectedSocket != null) sockets.add(_connectedSocket!);
    sockets.addAll(_pendingConnections.values);
    for (final s in sockets) {
      try {
        s.close();
      } catch (_) {}
    }
    _connectedSocket = null;
    _pendingConnections.clear();
    _incomingSocket = null;
    _activeIncomingSessionId = null;
    await stopIncoming();
    await stopDiscovery();
    _receiveBuffer.clear();
    _chunkAckWaiters.clear();
    _fileAckWaiters.clear();
    updateState(TransportState.disconnected);
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    disconnect();
    super.dispose();
  }
}