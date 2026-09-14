import '../../transport/device_info.dart';

enum DiscoveryStatus {
  initial,
  searching,
  found,
  connecting,
  connected,
  error,
}

class DiscoveryState {
  final DiscoveryStatus status;
  final List<DeviceInfo> devices;
  final DeviceInfo? selectedDevice;
  final String? errorMessage;

  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.devices = const [],
    this.selectedDevice,
    this.errorMessage,
  });

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<DeviceInfo>? devices,
    DeviceInfo? selectedDevice,
    String? errorMessage,
    bool clearError = false,
    bool clearDevice = false,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      selectedDevice: clearDevice ? null : (selectedDevice ?? this.selectedDevice),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
