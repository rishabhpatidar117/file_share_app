import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'discovery_state.dart';
import '../../transport/transport_channel.dart';
import '../../transport/device_info.dart';

class DiscoveryCubit extends Cubit<DiscoveryState> {
  final TransportChannel _transport;
  StreamSubscription? _deviceSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _peerConnectedSub;
  StreamSubscription? _peerDisconnectedSub;
  bool _receiverMode = false;

  DiscoveryCubit(this._transport) : super(const DiscoveryState()) {
    _deviceSub = _transport.onDeviceFound.listen((device) {
      if (state.status == DiscoveryStatus.connecting ||
          state.status == DiscoveryStatus.connected) {
        return;
      }
      final devices = List<DeviceInfo>.from(state.devices);
      if (!devices.any((d) => d.id == device.id)) {
        devices.add(device);
        emit(state.copyWith(
          status: DiscoveryStatus.found,
          devices: devices,
        ));
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
      emit(state.copyWith(
        connectedPeer: null,
        status: _receiverMode
            ? DiscoveryStatus.listening
            : DiscoveryStatus.searching,
        clearError: true,
      ));
    });
  }

  /// Start scanning for devices so this device can initiate a transfer.
  Future<void> startDiscovery() async {
    _receiverMode = false;
    emit(state.copyWith(
      status: DiscoveryStatus.searching,
      devices: [],
      clearError: true,
    ));
    try {
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
    return super.close();
  }
}