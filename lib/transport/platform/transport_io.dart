import 'dart:io';
import '../transport_channel.dart';
import '../lan_socket/lan_socket_transport.dart';
import '../wifi_direct/wifi_direct_transport.dart';

/// Native (dart:io) transport selection.
///
/// On Android, [WifiDirectTransport] is used so the transport can both drive
/// normal LAN transfers (via the inherited engine) and resolve Wi-Fi Direct
/// group owner IPs when a P2P link has been established.
/// Windows / Linux / macOS / iOS keep pure LAN sockets.
TransportChannel createPlatformTransport() {
  if (Platform.isAndroid) {
    return WifiDirectTransport();
  }
  return LanSocketTransport();
}