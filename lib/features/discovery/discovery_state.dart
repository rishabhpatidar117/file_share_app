import '../../transport/device_info.dart';
import '../../transport/transport_channel.dart';

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

  /// Every device with a live, handshaked link right now (multi-device).
  final List<PeerConnection> connectedPeers;

  final String? errorMessage;

  const DiscoveryState({
    this.status = DiscoveryStatus.initial,
    this.devices = const [],
    this.selectedDevice,
    this.connectedPeer,
    this.connectedPeers = const [],
    this.errorMessage,
  });

  DiscoveryState copyWith({
    DiscoveryStatus? status,
    List<DeviceInfo>? devices,
    DeviceInfo? selectedDevice,
    String? connectedPeer,
    List<PeerConnection>? connectedPeers,
    String? errorMessage,
    bool clearError = false,
    bool clearDevice = false,
  }) {
    return DiscoveryState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      selectedDevice: clearDevice ? null : (selectedDevice ?? this.selectedDevice),
      connectedPeer: connectedPeer ?? this.connectedPeer,
      connectedPeers: connectedPeers ?? this.connectedPeers,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
