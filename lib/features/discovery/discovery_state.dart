import '../../transport/device_info.dart';

enum DiscoveryStatus {
  initial,
  searching,
  found,

  /// This device is advertising on the LAN (listen mode) with no live peer yet.
  listening,
  connecting,
  connected,
  error,
}

class DiscoveryState {
  final DiscoveryStatus status;
  final List<DeviceInfo> devices;
  final DeviceInfo? selectedDevice;

  /// Name of the peer this device is currently linked with, if any.
  final String? connectedPeer;

  final String? errorMessage;

  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.devices = const [],
    this.selectedDevice,
    this.connectedPeer,
    this.errorMessage,
  });

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<DeviceInfo>? devices,
    DeviceInfo? selectedDevice,
    String? connectedPeer,
    String? errorMessage,
    bool clearError = false,
    bool clearDevice = false,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      selectedDevice: clearDevice ? null : (selectedDevice ?? this.selectedDevice),
      connectedPeer: connectedPeer ?? this.connectedPeer,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
