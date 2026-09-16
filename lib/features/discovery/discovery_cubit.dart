import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'discovery_state.dart';
import '../../transport/transport_channel.dart';
import '../../transport/transport_kind.dart';
import '../../transport/device_info.dart';
import '../../transport/wifi_direct/wifi_p2p_client.dart';

class DiscoveryCubit extends Cubit<DiscoveryState> {
  final TransportChannel _transport;
  StreamSubscription? _deviceSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _peerConnectedSub;
  StreamSubscription? _peerDisconnectedSub;
  StreamSubscription? _peerListSub;
  StreamSubscription? _p2pPeersSub;
  WifiP2pClient? _p2p;
  bool _receiverMode = false;

  DiscoveryCubit(this._transport) : super(const DiscoveryState()) {
    _p2p = _transport.wifiP2pClient;
    _deviceSub = _transport.onDeviceFound.listen((device) {
      if (state.status == DiscoveryStatus.connecting ||
          state.status == DiscoveryStatus.connected) {
        return;
      }
      _addDevice(device);
    });

    // Wi-Fi Direct peers discovered over the P2P stack. Each maps to a plain
    // DeviceInfo without an IP (the transport resolves the group owner IP at
    // connect time).
    _p2pPeersSub = _p2p?.onPeersChanged.listen((peers) {
      if (state.status == DiscoveryStatus.connecting ||
          state.status == DiscoveryStatus.connected) {
        return;
      }
      for (final peer in peers) {
        if (peer.deviceAddress.isEmpty) continue;
        _addDevice(
          DeviceInfo(
            id: 'p2p-${peer.deviceAddress}',
            name: peer.deviceName?.isNotEmpty == true
                ? peer.deviceName!
                : 'Wi-Fi Direct device',
            platform: DevicePlatform.android,
            quality: ConnectionQuality.excellent,
            kind: TransportKind.wifiDirect,
          ),
        );
      }
    });

    _stateSub = _transport.onStateChanged.listen((transportState) {
      switch (transportState) {
        case TransportState.discovering:
          emit(state.copyWith(status: DiscoveryStatus.searching));
          break;
        case TransportState.connecting:
          emit(state.copyWith(status: DiscoveryStatus.connecting));
          break;
        case TransportState.connected:
          if (state.status != DiscoveryStatus.connected) {
            emit(state.copyWith(status: DiscoveryStatus.connected));
          }
          break;
        case TransportState.disconnected:
          emit(state.copyWith(
            status: _receiverMode
                ? DiscoveryStatus.listening
                : DiscoveryStatus.searching,
            clearError: true,
          ));
          break;
        case TransportState.listening:
          emit(state.copyWith(status: DiscoveryStatus.listening));
          break;
        case TransportState.error:
          emit(state.copyWith(
            status: DiscoveryStatus.error,
            errorMessage: state.errorMessage ?? 'Connection failed',
          ));
          break;
        default:
          break;
      }
    });

    _peerConnectedSub = _transport.onPeerConnected.listen((peer) {
      emit(state.copyWith(
        status: DiscoveryStatus.connected,
        connectedPeer: peer.deviceName,
        clearError: true,
      ));
    });

    _peerDisconnectedSub = _transport.onPeerDisconnected.listen((name) {
      if (state.connectedPeers.isEmpty) {
        emit(state.copyWith(
          connectedPeer: null,
          status: _receiverMode
              ? DiscoveryStatus.listening
              : DiscoveryStatus.searching,
          clearError: true,
        ));
      }
    });

    // Multi-device: the transport owns the authoritative peer list. Each
    // snapshot keeps the singular `connectedPeer` (first link, for backwards
    // compatibility) in sync with the full list.
    _peerListSub = _transport.onPeerList.listen((peers) {
      emit(state.copyWith(
        connectedPeers: peers,
        status: peers.isNotEmpty ? DiscoveryStatus.connected : state.status,
        connectedPeer: peers.isNotEmpty
            ? peers.first.deviceName
            : null,
        clearError: true,
      ));
    });
  }

  void _addDevice(DeviceInfo device) {
    final devices = List<DeviceInfo>.from(state.devices);
    if (!devices.any((d) => d.id == device.id)) {
      devices.add(device);
      emit(state.copyWith(
        status: DiscoveryStatus.found,
        devices: devices,
      ));
    }
  }

  /// Start scanning for devices so this device can initiate a transfer.
  /// Also kicks off Wi-Fi Direct peer discovery on transports that support it.
  Future<void> startDiscovery() async {
    _receiverMode = false;
    emit(state.copyWith(
      status: DiscoveryStatus.searching,
      devices: [],
      clearError: true,
    ));
    try {
      final p2p = _p2p;
      if (p2p != null) {
        // Best-effort: Wi-Fi Direct discovery on Android surfaces nearby P2P
        // devices in parallel with LAN beacons. Failures are ignored and the
        // LAN path still works.
        unawaited(p2p.startDiscovery());
      }
      await _transport.startDiscovery();
    } catch (e) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Discovery failed: $e',
      ));
    }
  }

  Future<void> stopDiscovery() async {
    await _transport.stopDiscovery();
    try {
      await _p2p?.stopDiscovery();
    } catch (_) {}
  }

  /// Bind a listener so remote devices can start an incoming transfer.
  Future<void> startReceive() async {
    _receiverMode = true;
    emit(state.copyWith(
      status: DiscoveryStatus.listening,
      devices: [],
      clearError: true,
    ));
    try {
      await _transport.startIncoming();
      emit(state.copyWith(
        status: DiscoveryStatus.listening,
        clearError: true,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to listen: $e',
      ));
    }
  }

  Future<void> stopListening() async {
    await _transport.stopIncoming();
    if (state.status == DiscoveryStatus.connected ||
        state.status == DiscoveryStatus.listening ||
        state.status == DiscoveryStatus.searching) {
      emit(state.copyWith(
        status: DiscoveryStatus.initial,
        connectedPeer: null,
      ));
    }
  }

  Future<bool> connectToDevice(DeviceInfo device) async {
    emit(state.copyWith(
      status: DiscoveryStatus.connecting,
      selectedDevice: device,
      clearError: true,
    ));
    try {
      await _transport.connectToDevice(device);
      emit(state.copyWith(status: DiscoveryStatus.connected, clearError: true));
      return true;
    } catch (e) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to connect to ${device.name}: $e',
      ));
      return false;
    }
  }

  /// Connect to a peer that was discovered over Wi-Fi Direct.
  ///
  /// This is a two-step dance on the native side: form/join the P2P group
  /// with the peer's MAC, wait until the group reports an owner IP, then let
  /// the transport open its usual TCP control socket to that IP. The receive
  /// side auto-accepts the group request (see MainActivity), so no manual
  /// accept is required.
  ///
  /// When the P2P group is unavailable (not on Android, P2P off), we report a
  /// clear error and the LAN/QR path remains the fallback.
  Future<bool> connectWifiDirect(DeviceInfo device) async {
    final p2p = _p2p;
    if (p2p == null) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage:
            'Wi-Fi Direct is not available on this device. Use "Connect by '
            'IP address" or scan the QR code on the same network instead.',
      ));
      return false;
    }

    // MAC address is embedded in the id (p2p-<mac>) so the raw connect call
    // can be addressed without changing the engine's DeviceInfo contract.
    final mac = device.id.startsWith('p2p-')
        ? device.id.substring(4)
        : device.id;
    if (mac.isEmpty) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'No Wi-Fi Direct address for ${device.name}.',
      ));
      return false;
    }

    emit(state.copyWith(
      status: DiscoveryStatus.connecting,
      selectedDevice: device,
      clearError: true,
    ));

    try {
      final started = await p2p.connectTo(mac);
      if (!started) {
        emit(state.copyWith(
          status: DiscoveryStatus.error,
          errorMessage:
              'Could not start a Wi-Fi Direct connection to ${device.name}. '
              'Both devices must have Wi-Fi enabled.',
        ));
        return false;
      }

      // Poll the group info until the owner IP is exposed (group formation
      // is async on Android). Time out after ~30 s rather than spinning.
      final resolved = await _resolveWifiDirectOwnerIp(p2p);
      if (resolved == null) {
        emit(state.copyWith(
          status: DiscoveryStatus.error,
          errorMessage:
              'Wi-Fi Direct connection to ${device.name} timed out. Retry, or '
              'fall back to the IP/QR connect on the shared network.',
        ));
        return false;
      }

      if (resolved.isEmpty) {
        // We became the group owner; the peer connects inbound over the P2P
        // interface. Make sure the listener is bound so its TCP connect lands.
        debugPrint('[DISCOVERY] this device is the P2P group owner; listening');
        try {
          await _transport.startIncoming();
        } catch (_) {}
        emit(state.copyWith(
          status: DiscoveryStatus.connected,
          clearError: true,
        ));
        return true;
      }

      debugPrint('[DISCOVERY] P2P group formed, connecting to owner $resolved');
      await _transport.connectToDevice(
        device.copyWith(address: resolved, kind: TransportKind.wifiDirect),
      );
      emit(state.copyWith(status: DiscoveryStatus.connected, clearError: true));
      return true;
    } catch (e) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to connect to ${device.name}: $e',
      ));
      return false;
    }
  }

  Future<String?> _resolveWifiDirectOwnerIp(WifiP2pClient p2p) async {
    for (var attempt = 0; attempt < 60; attempt++) {
      final group = await p2p.groupInfo();
      if (group != null && group.inGroup) {
        if (group.isGroupOwner) {
          // We are the group owner; the peer connects inbound over the P2P
          // interface while we keep listening. No outbound connect is made —
          // the engine's startIncoming listener covers the p2p interface.
          debugPrint(
            '[DISCOVERY] this device is the P2P group owner; waiting for peer',
          );
          return '';
        }
        final ownerIp = group.ownerIp;
        if (ownerIp != null && ownerIp.isNotEmpty) {
          return ownerIp;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return null;
  }

  /// Tear down the current peer link; both devices return to a listening /
  /// scanning state and can link again.
  Future<void> disconnectPeer() async {
    await _transport.disconnectPeers();
    emit(state.copyWith(
      status: _receiverMode
          ? DiscoveryStatus.listening
          : DiscoveryStatus.searching,
      connectedPeer: null,
      clearError: true,
    ));
  }

  void reset() {
    emit(const DiscoveryState());
  }

  @override
  Future<void> close() {
    _deviceSub?.cancel();
    _stateSub?.cancel();
    _peerConnectedSub?.cancel();
    _peerDisconnectedSub?.cancel();
    _peerListSub?.cancel();
    _p2pPeersSub?.cancel();
    return super.close();
  }
}