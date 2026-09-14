import '../transport_channel.dart';
import '../webrtc/webrtc_transport.dart';

/// Web transport selection — P2P over WebRTC DataChannels.
TransportChannel createPlatformTransport() {
  return WebRtcTransport();
}