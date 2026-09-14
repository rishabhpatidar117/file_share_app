import '../transport_channel.dart';
import '../lan_socket/lan_socket_transport.dart';

/// Native (dart:io) transport selection.
/// Desktop + mobile all use LAN sockets (UDP beacon discovery + TCP data).
/// The Nearby Connections wrapper is kept for a future Wi-Fi Direct upgrade,
/// but the stub is not usable yet, so Android/iOS fall back to LAN sockets.
TransportChannel createPlatformTransport() => LanSocketTransport();