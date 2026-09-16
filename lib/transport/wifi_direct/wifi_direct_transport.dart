import 'package:flutter/foundation.dart' show debugPrint;
import '../transport_channel.dart';
import '../device_info.dart';
import '../transport_kind.dart';
import '../lan_socket/lan_socket_transport.dart';
import 'wifi_p2p_client.dart';

/// Wi-Fi Direct transport that reuses the LAN engine verbatim.
///
/// [LanSocketTransport] already has the full transfer protocol (hello /
/// session / chunk / ack / resume / retry over framed TCP) and its sender path
/// is *direction-neutral* (sendSessionStart works over any established peer
/// socket, inbound or outbound). So Wi-Fi Direct is not a second engine: it
/// differs only in HOW the TCP socket gets its peer — via the P2P group's
/// interface IP instead of a LAN discovery beacon.
///
/// Group model (Android Wi-Fi Direct):
///  * The device that calls `requestConnect`/forms the group becomes the
///    **group owner**, holding `192.168.49.1` on the P2P interface.
///  * The other device joins as a **client** and can reach the owner there.
///  * Our engine listens on 0.0.0.0 (startIncoming), which covers the P2P
///    interface too, so either role can accept an inbound TCP connection and
///    still drive the transfer through the exact same code path.
///
/// Current behaviour is deliberately conservative and documented:
///  * File sender = P2P **client**: [connectToDevice] resolves the owner IP
///    from the native group info and connects the normal way.
///  * File sender = P2P **owner**: no outbound connect exists (the peer is on
///    our own link); the owner stays in [startIncoming] and waits for the
///    client's inbound TCP connection. [connectToDevice] reports that state
///    clearly until a peer socket exists.
///
/// Windows/web have no P2P stack reachable from Dart; all calls here fail
/// softly and surface a [TransportException] explaining the LAN/hotspot path.
class WifiDirectTransport extends LanSocketTransport {
  final WifiP2pClient _p2p;

  WifiDirectTransport({WifiP2pClient? p2p})
      : _p2p = p2p ?? const WifiP2pClient(),
        super(kind: TransportKind.wifiDirect);

  /// Exposes the P2P client so the DiscoveryCubit can drive peer discovery
  /// independently from the transport.
  @override
  WifiP2pClient? get wifiP2pClient => _p2p;

  @override
  Future<void> connectToDevice(DeviceInfo device) async {
    // If the caller supplied a reachable IP address (e.g. scanned QR code or
    // manual IP entry), skip the P2P group dance and connect directly over the
    // normal TCP path. Wi-Fi Direct peer-discovered devices carry no address
    // (only the MAC), so they must go through group resolution below.
    if (device.address != null && device.address!.isNotEmpty) {
      return super.connectToDevice(device);
    }

    final group = await _p2p.groupInfo();

    if (group == null || !group.inGroup) {
      updateState(TransportState.error);
      throw TransportException(
        'Wi-Fi Direct is not connected: no active P2P group. Start discovery '
        'and connect on the receiving Android device first. '
        '(On Windows use shared Wi-Fi or the Android hotspot instead.)',
      );
    }

    if (group.isGroupOwner) {
      updateState(TransportState.error);
      throw TransportException(
        'This device is the group owner of the Wi-Fi Direct group — there is '
        'no outbound connect to make. Keep listening (startIncoming) and wait '
        'for the peer\'s inbound connection.',
      );
    }

    final ownerIp = group.ownerIp;
    if (ownerIp == null || ownerIp.isEmpty) {
      updateState(TransportState.error);
      throw TransportException(
        'Wi-Fi Direct group is forming but the owner IP is not exposed yet; '
        'retry in a moment.',
      );
    }

    debugPrint(
      '[WIFIDIRECT] connecting to group owner $ownerIp on the P2P interface',
    );
    await super.connectToDevice(device.copyWith(address: ownerIp));
  }

  @override
  String toString() => 'WifiDirectTransport(${transportKind.label})';
}