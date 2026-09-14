import '../transport_channel.dart';

/// Stub for platforms without a dedicated transport implementation.
/// Replaced by [transport_io] or [transport_web] via conditional imports.
TransportChannel createPlatformTransport() {
  throw UnsupportedError('No transport implementation for this platform');
}