import 'transport_channel.dart';
import 'platform/transport_stub.dart'
    if (dart.library.io) 'platform/transport_io.dart'
    if (dart.library.html) 'platform/transport_web.dart';

/// Creates the appropriate [TransportChannel] for the current platform.
class TransportFactory {
  TransportFactory._();

  static TransportChannel create() => createPlatformTransport();
}