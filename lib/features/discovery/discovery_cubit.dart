import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'discovery_state.dart';
import '../../transport/transport_channel.dart';
import '../../transport/device_info.dart';

class DiscoveryCubit extends Cubit<DiscoveryState> {
  final TransportChannel _transport;
  StreamSubscription? _deviceSub;
  StreamSubscription? _stateSub;

  DiscoveryCubit(this._transport) : super(const DiscoveryState()) {
    _deviceSub = _transport.onDeviceFound.listen((device) {
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
          emit(state.copyWith(status: DiscoveryStatus.connected));
          break;
        case TransportState.error:
          emit(state.copyWith(
            status: DiscoveryStatus.error,
            errorMessage: 'Connection failed',
          ));
          break;
        default:
          break;
      }
    });
  }

  Future<void> startDiscovery() async {
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
    emit(state.copyWith(
      status: DiscoveryStatus.searching,
      devices: [],
      clearError: true,
    ));
    try {
      await _transport.startIncoming();
      emit(state.copyWith(status: DiscoveryStatus.connected, clearError: true));
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
        state.status == DiscoveryStatus.searching) {
      emit(state.copyWith(status: DiscoveryStatus.initial));
    }
  }

  Future<void> connectToDevice(DeviceInfo device) async {
    emit(state.copyWith(
      status: DiscoveryStatus.connecting,
      selectedDevice: device,
    ));
    try {
      await _transport.connectToDevice(device);
    } catch (e) {
      emit(state.copyWith(
        status: DiscoveryStatus.error,
        errorMessage: 'Failed to connect to ${device.name}: $e',
      ));
    }
  }

  void reset() {
    emit(const DiscoveryState());
  }

  @override
  Future<void> close() {
    _deviceSub?.cancel();
    _stateSub?.cancel();
    return super.close();
  }
}
