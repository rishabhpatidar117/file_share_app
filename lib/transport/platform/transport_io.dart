import 'dart:io' show Platform;
import '../transport_channel.dart';
import '../lan_socket/lan_socket_transport.dart';
import '../nearby/nearby_transport.dart';

/// Native (dart:io) transport selection.
/// Android/iOS use Nearby Connections; desktop uses LAN sockets.
TransportChannel createPlatformTransport() {
  if (Platform.isAndroid || Platform.isIOS) {
    return NearbyTransport();
  }
  return LanSocketTransport();
}