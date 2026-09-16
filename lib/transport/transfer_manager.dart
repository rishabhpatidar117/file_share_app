import 'device_info.dart';
import 'transport_kind.dart';
import '../core/services/network_diagnostics.dart';

/// Snapshot of the Android Wi-Fi Direct stack as seen from the app. All fields
/// are best-effort; on desktops/web (where the platform channel never exists)
/// [supported] stays false and the evaluator falls through to LAN handling.
class P2pGroupState {
  final bool supported;
  final bool enabled;
  final bool inGroup;
  final bool isGroupOwner;

  /// P2P interface IP of the group owner (e.g. 192.168.49.1). Null while the
  /// group is still negotiating or when the OS has not exposed the address.
  final String? ownerIp;

  const P2pGroupState({
    this.supported = false,
    this.enabled = false,
    this.inGroup = false,
    this.isGroupOwner = false,
    this.ownerIp,
  });
}

/// Result of [TransportManager.evaluate]. [confidence] is a rough 0..100
/// expression of "how sure are we the peer is reachable this way RIGHT NOW",
/// not a throughput ranking. We deliberately never score Wi-Fi 6 > Wi-Fi Direct
/// etc. — link quality can only be *measured*, not assumed from branding.
class TransportDecision {
  final TransportKind kind;
  final int confidence;
  final List<String> rationale;

  const TransportDecision({
    required this.kind,
    required this.confidence,
    required this.rationale,
  });
}

/// Chooses *which transport kind to attempt* based on what is actually
/// reachable and measured, and explains itself. The heavy lifting (which
/// network the peer is really on) still comes from discovery + [WifiLinkInfo];
/// this class only turns those facts into a decision.
class TransportManager {
  const TransportManager();

  TransportDecision evaluate({
    WifiLinkInfo? link,
    bool localDiscoveryDetected = false,
    P2pGroupState? p2p,
    bool p2pPeerSelected = false,
    DevicePlatform platform = DevicePlatform.unknown,
  }) {
    // 1. A formed Wi-Fi Direct group already carries TCP between the peers:
    //    the P2P interface is a private L2 link, no router in between.
    if (p2p != null && p2p.supported && p2p.enabled && p2p.inGroup) {
      return TransportDecision(
        kind: TransportKind.wifiDirect,
        confidence: p2pPeerSelected && p2p.ownerIp != null ? 85 : 60,
        rationale: [
          'A Wi-Fi Direct group is active on this device',
          if (p2pPeerSelected && p2p.ownerIp != null)
            'the selected peer is reachable over the P2P interface',
          if (p2p.ownerIp == null)
            'group-owner IP not exposed yet; confirm the group is fully formed',
          _platformNote(platform),
        ],
      );
    }

    // 2. Discovery verified the peer answers beacons on the local segment
    //    (shared Wi-Fi, ethernet, or a phone hotspot acting as a mini router).
    if (localDiscoveryDetected &&
        (link == null ||
            link.transportType == 'wifi' ||
            link.transportType == 'ethernet')) {
      return TransportDecision(
        kind: TransportKind.lan,
        confidence: 90,
        rationale: [
          'Peer answered a discovery beacon on the same local network',
          if (link?.isWifi == true && link?.ssid == null)
            'OS hides the network name, but beacon reachability is verified',
          _platformNote(platform),
        ],
      );
    }

    // 3. No verified shared segment, but Wi-Fi Direct could *create* one.
    if (p2p != null && p2p.supported && p2p.enabled && !p2p.inGroup) {
      return TransportDecision(
        kind: TransportKind.wifiDirect,
        confidence: 40,
        rationale: [
          'No verified shared LAN; a Wi-Fi Direct group can create a private link',
          'Group formation needs the receiving device to accept',
          _platformNote(platform),
        ],
      );
    }

    // 4. Last resort: keep the LAN engine running and let the real radio stats
    //    decide. Never pretend to be faster than the radio actually is.
    final nothingMeasured = link == null && !localDiscoveryDetected;
    return TransportDecision(
      kind: TransportKind.lan,
      confidence: nothingMeasured ? 20 : 35,
      rationale: [
        'Falling back to the LAN discovery + TCP engine',
        if (nothingMeasured) 'no Wi-Fi link info measured yet',
        _platformNote(platform),
      ],
    );
  }

  String _platformNote(DevicePlatform platform) {
    switch (platform) {
      case DevicePlatform.android:
        return 'Android exposes Wi-Fi Direct for this path';
      case DevicePlatform.windows:
        return 'Windows cannot join an Android P2P group; use shared Wi-Fi '
            'or the Android hotspot instead';
      case DevicePlatform.web:
        return 'Web build: network metadata is not measurable';
      case DevicePlatform.unknown:
        return 'platform unknown — treating as LAN-capable';
    }
  }
}