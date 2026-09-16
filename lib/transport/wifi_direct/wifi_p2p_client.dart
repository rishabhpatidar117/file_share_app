import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A remote device surfaced by Android's Wi-Fi Direct peer discovery.
class P2pDeviceInfo {
  /// MAC address used to address the peer during requestConnect.
  final String deviceAddress;
  final String? deviceName;
  final bool isGroupOwner;
  final bool isGroupClient;

  const P2pDeviceInfo({
    required this.deviceAddress,
    this.deviceName,
    this.isGroupOwner = false,
    this.isGroupClient = false,
  });

  factory P2pDeviceInfo.fromMap(Map<Object?, Object?> raw) => P2pDeviceInfo(
        deviceAddress: raw['deviceAddress'] as String? ?? '',
        deviceName: raw['deviceName'] as String?,
        isGroupOwner: raw['isGroupOwner'] as bool? ?? false,
        isGroupClient: raw['isGroupClient'] as bool? ?? false,
      );
}

/// State of the local Wi-Fi Direct group (if any).
class P2pGroupInfo {
  final bool inGroup;
  final bool isGroupOwner;

  /// Group owner MAC, if known.
  final String? groupOwnerAddress;

  /// P2P interface IP of the group owner (e.g. 192.168.49.1). This is the
  /// address the engine's TCP socket connects to client-side.
  final String? ownerIp;

  /// Friendly SSID of the P2P group, when the OS exposes it.
  final String? networkName;
  final String? passphrase;
  final List<String> clientIps;

  const P2pGroupInfo({
    this.inGroup = false,
    this.isGroupOwner = false,
    this.groupOwnerAddress,
    this.ownerIp,
    this.networkName,
    this.passphrase,
    this.clientIps = const [],
  });

  factory P2pGroupInfo.fromMap(Map<Object?, Object?> raw) {
    final clients = raw['clientIps'];
    return P2pGroupInfo(
      inGroup: raw['inGroup'] as bool? ?? false,
      isGroupOwner: raw['isGroupOwner'] as bool? ?? false,
      groupOwnerAddress: raw['groupOwnerAddress'] as String?,
      ownerIp: raw['ownerIp'] as String?,
      networkName: raw['networkName'] as String?,
      passphrase: raw['passphrase'] as String?,
      clientIps: clients is List
          ? clients.whereType<String>().toList()
          : const <String>[],
    );
  }
}

/// Dart-facing client for the native `swiftshare/wifi_p2p` platform channel.
///
/// Everything here is best-effort: on any platform where Wi-Fi Direct is not
/// available (Windows, web, or Android without the receiver registered) calls
/// return neutral defaults instead of throwing, so the caller can fall back to
/// the LAN/hotspot path. Platform exceptions are swallowed deliberately.
class WifiP2pClient {
  const WifiP2pClient();

  static const MethodChannel _channel = MethodChannel('swiftshare/wifi_p2p');

  static bool get _available => !kIsWeb && Platform.isAndroid;

  /// True when the platform advertises Wi-Fi Direct and the radio is on.
  Future<bool> isSupportedAndEnabled() async {
    if (!_available) return false;
    try {
      return await _channel.invokeMethod<bool>('isSupportedAndEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Current group membership. Null when nothing can be reported.
  Future<P2pGroupInfo?> groupInfo() async {
    if (!_available) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getGroupInfo',
      );
      if (raw == null || raw.isEmpty) return null;
      return P2pGroupInfo.fromMap(raw);
    } catch (_) {
      return null;
    }
  }

  /// Kicks off peer discovery. Peers arrive on [onPeersChanged].
  Future<bool> startDiscovery() async {
    if (!_available) return false;
    try {
      return await _channel.invokeMethod<bool>('startDiscovery') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopDiscovery() async {
    if (!_available) return;
    try {
      await _channel.invokeMethod('stopDiscovery');
    } catch (_) {}
  }

  /// Requests a group connection to a peer found with [startDiscovery].
  Future<bool> connectTo(String deviceAddress) async {
    if (!_available) return false;
    try {
      return await _channel
              .invokeMethod<bool>('connectTo', {'deviceAddress': deviceAddress}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> disconnectGroup() async {
    if (!_available) return;
    try {
      await _channel.invokeMethod('disconnectGroup');
    } catch (_) {}
  }

  /// Stream of Wi-Fi Direct peer lists from native discovery.
  Stream<List<P2pDeviceInfo>> get onPeersChanged {
    const events = EventChannel('swiftshare/wifi_p2p_events');
    return events.receiveBroadcastStream('peersChanged').map((event) {
      final peers = <P2pDeviceInfo>[];
      if (event is List) {
        for (final entry in event) {
          if (entry is Map) {
            peers.add(P2pDeviceInfo.fromMap(entry.cast<Object?, Object?>()));
          }
        }
      }
      return peers;
    });
  }
}