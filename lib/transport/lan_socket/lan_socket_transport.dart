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
  static const int servicePort = kSwiftShareServicePort;
  static const int discoveryPort = 48733;

  /// Android emulator alias for the host machine's loopback interface.
  /// Broadcasts stay inside the emulator's NAT, so also unicast beacons here
  /// so a desktop app on the host can discover the emulator (paired with
  /// `adb forward tcp:48732 tcp:48732` so the host can connect back).
  static const String androidEmulatorHostAlias = '10.0.2.2';

  ServerSocket? _serverSocket;
  Socket? _connectedSocket;
  RawDatagramSocket? _discoverySocket;
  StreamSubscription<RawSocketEvent>? _discoverySub;
  final List<DeviceInfo> _discoveredDevices = [];

  /// Live peer sockets (outbound initiator + accepted incoming) with which the
  /// hello/hello_ack handshake has completed.
  final Set<Socket> _peerSockets = {};
  final Map<Socket, String> _peerNames = {};
  final Set<Socket> _pendingConnections = {};
  Timer? _beaconTimer;
  Timer? _scanTimeout;
  String _deviceName = 'My Device';
  final String _instanceId = DateTime.now().microsecondsSinceEpoch.toRadixString(16);

  // Message framing buffer.
  final List<int> _receiveBuffer = [];
  final Map<Socket, Future<void>> _writeChains = {};
  bool _listening = false;
  bool _discovering = false;

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
      reusePort: Platform.isLinux || Platform.isMacOS,
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
      'platform': _platformString,
      'port': servicePort,
    }));
    try {
      _discoverySocket!.send(
        beacon,
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (_) {}
    // The Android emulator's broadcast stays in its own NAT, so also unicast
    // to the host loopback alias the desktop app listens on.
    if (Platform.isAndroid) {
      try {
        _discoverySocket!.send(
          beacon,
          InternetAddress(androidEmulatorHostAlias),
          discoveryPort,
        );
      } catch (_) {}
    }
  }

  @override
  Future<void> startDiscovery({Duration timeout = const Duration(seconds: 15)}) async {
    if (_discovering) return;
    updateState(TransportState.discovering);
    _discovering = true;
    _discoveredDevices.clear();

    await _ensureDiscoverySocket();
    _scanTimeout?.cancel();
    _scanTimeout = Timer(timeout, () => stopDiscovery());

    _startBeaconTimer();
    _sendBeacon();
  }

  void _startBeaconTimer() {
    if (_beaconTimer != null) return;
    _beaconTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendBeacon();
    });
  }

  void _stopBeaconTimer() {
    _beaconTimer?.cancel();
    _beaconTimer = null;
  }

  void _closeDiscoverySocketIfIdle() {
    if (_listening || _discovering) return;
    _discoverySub?.cancel();
    _discoverySub = null;
    _discoverySocket?.close();
    _discoverySocket = null;
  }

  @override
  Future<void> stopDiscovery() async {
    _scanTimeout?.cancel();
    _scanTimeout = null;
    _discovering = false;
    if (!_listening) {
      _stopBeaconTimer();
    }
    if (state == TransportState.discovering) {
      updateState(TransportState.disconnected);
    }
    _closeDiscoverySocketIfIdle();
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

  String get _platformString {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    return 'other';
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
        'platform': _platformString,
      });
    } catch (e) {
      updateState(TransportState.error);
      throw TransportException('Connection failed', e);
    }
  }

  /// Marks a socket as a live, handshaked peer. Emits the peer-connected signal
  /// and moves the transport to `connected` the first time a peer link exists.
  void _establishPeer(Socket socket, String name) {
    final firstPeer = _peerSockets.isEmpty;
    _peerSockets.add(socket);
    _peerNames[socket] = name;
    _pendingConnections.remove(socket);
    _remoteDeviceName = name;
    if (firstPeer) {
      updateState(TransportState.connected);
      peerConnectedController.add(PeerConnection(deviceName: name));
    } else if (state != TransportState.connected) {
      updateState(TransportState.connected);
    }
  }

  /// Removes a socket from all peer bookkeeping. Emits the peer-disconnected
  /// signal and drops back to `listening`/`disconnected` when the last peer
  /// link is gone.
  void _removePeer(Socket socket) {
    final wasPeer = _peerSockets.remove(socket);
    _peerNames.remove(socket);
    _pendingConnections.remove(socket);
    _writeChains.remove(socket);
    if (identical(socket, _connectedSocket)) _connectedSocket = null;
    if (identical(socket, _incomingSocket)) _incomingSocket = null;
    if (!wasPeer) return;
    if (_peerSockets.isEmpty) {
      if (_peerNames.isNotEmpty) _peerNames.clear();
      peerDisconnectedController.add(_remoteDeviceName);
      updateState(_listening ? TransportState.listening : TransportState.disconnected);
    }
  }

  Future<void> _closePeerSocket(Socket socket) async {
    try {
      await _sendMessage(socket, {'type': 'disconnect'});
    } catch (_) {}
    try {
      socket.close();
    } catch (_) {}
    _removePeer(socket);
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
      // Advertise so senders can find this receiver in discovery.
      await _ensureDiscoverySocket();
      _startBeaconTimer();
      _sendBeacon();
    } catch (_) {
      // Another listening instance already owns the port; keep going.
    }
  }

  @override
  Future<void> stopIncoming() async {
    await _serverSocket?.close();
    _serverSocket = null;
    _listening = false;
    _closeDiscoverySocketIfIdle();
    if (!_discovering) {
      _stopBeaconTimer();
    }
  }

  void _handleIncomingConnection(Socket socket) {
    _pendingConnections.add(socket);
    socket.done.then((_) => _removePeer(socket));
    _setupDataListener(socket);
    _sendMessage(socket, {
      'type': 'hello_ack',
      'name': _deviceName,
      'platform': _platformString,
    });
  }

  void _setupDataListener(Socket socket) {
    socket.listen(
      (data) {
        _receiveBuffer.addAll(data);
        _processBuffer(socket);
      },
      onError: (_) => _handleSocketClosed(socket),
      onDone: () => _handleSocketClosed(socket),
    );
  }

  void _handleSocketClosed(Socket socket) {
    final wasPeer = _peerSockets.contains(socket);
    if (identical(socket, _connectedSocket) && !wasPeer) {
      // Connection dropped before the hello/hello_ack handshake completed.
      _connectedSocket = null;
      updateState(TransportState.disconnected);
      return;
    }
    _removePeer(socket);
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
        _establishPeer(socket, message['name'] as String? ?? 'Unknown');
        _sendMessage(socket, {
          'type': 'hello_ack',
          'name': _deviceName,
          'platform': _platformString,
        });
        break;

      case 'hello_ack':
        _establishPeer(socket, message['name'] as String? ?? 'Unknown');
        break;

      case 'disconnect':
        _closePeerSocket(socket);
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

    // dart:io sockets only allow one un-flushed add() at a time
    // (io_sink's flush() binds the sink), so serialize writes per socket.
    final previous = _writeChains[socket] ?? Future<void>.value();
    final next = previous
        .catchError((_) {})
        .then((_) async {
          socket.add(frame);
          await socket.flush();
        });
    _writeChains[socket] = next;
    return next;
  }

  // ---------------------------------------------------------------------------
  // Sender API
  // ---------------------------------------------------------------------------

  /// The socket used to push our outgoing sessions. Prefers the socket this
  /// device initiated; otherwise falls back to a peer socket we accepted, so a
  /// receiver can send files back across the same established link.
  Socket get _senderSocket {
    if (_connectedSocket != null) return _connectedSocket!;
    if (_peerSockets.isNotEmpty) return _peerSockets.first;
    throw TransportException('Not connected to any device');
  }

  @override
  Future<ResumePoints> sendSessionStart(
    String sessionId,
    String deviceName,
    List<SessionFileMeta> files, {
    int? chunkSize,
  }) async {
    final socket = _senderSocket;
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
    final socket = _senderSocket;
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
    final socket = _senderSocket;
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
    final socket = _senderSocket;
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
    if (_peerSockets.isNotEmpty) {
      updateState(TransportState.connected);
    }
  }

  @override
  Future<void> disconnectPeers() async {
    final sockets = List<Socket>.from(_peerSockets);
    for (final s in sockets) {
      await _closePeerSocket(s);
    }
    _connectedSocket = null;
    _incomingSocket = null;
    _activeIncomingSessionId = null;
    _sessionStartWaiter = null;
    if (state != TransportState.disconnected && state != TransportState.connecting) {
      updateState(_listening ? TransportState.listening : TransportState.disconnected);
    }
  }

  @override
  Future<void> disconnect() async {
    final sockets = <Socket>{};
    if (_connectedSocket != null) sockets.add(_connectedSocket!);
    sockets.addAll(_pendingConnections);
    sockets.addAll(_peerSockets);
    for (final s in sockets) {
      try {
        await _sendMessage(s, {'type': 'disconnect'});
      } catch (_) {}
      try {
        s.close();
      } catch (_) {}
    }
    _connectedSocket = null;
    _pendingConnections.clear();
    _peerSockets.clear();
    _peerNames.clear();
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