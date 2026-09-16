import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/transport/wifi_direct/wifi_direct_transport.dart';
import 'package:swiftshare/transport/wifi_direct/wifi_p2p_client.dart';
import 'package:swiftshare/transport/lan_socket/lan_socket_transport.dart';
import 'package:swiftshare/transport/device_info.dart';
import 'package:swiftshare/transport/transport_channel.dart';
import 'package:swiftshare/transport/transport_kind.dart';

/// Injectable fake P2P client so the transport's role logic can be exercised
/// without any platform channel or sockets.
class _FakeP2p extends WifiP2pClient {
  final P2pGroupInfo? group;
  _FakeP2p(this.group);

  @override
  Future<P2pGroupInfo?> groupInfo() async => group;

  @override
  Future<bool> isSupportedAndEnabled() async =>
      group?.inGroup == true || group != null;
}

void main() {
  // Wi-Fi Direct peers are discovered without a reachable IP — only the MAC
  // (in the id). The transport resolves the owner IP from the native group
  // info at connect time. A device with an explicit address (QR/manual entry)
  // skips the P2P dance entirely and connects directly (LAN fallback).
  const p2pPeer = DeviceInfo(id: 'p2p-peer', name: 'Pixel');

  group('WifiDirectTransport', () {
    test('is a LanSocketTransport subclass reusing the engine (kind: Wi-Fi Direct)',
        () {
      final t = WifiDirectTransport();
      expect(t.transportKind, TransportKind.wifiDirect);
      expect(t, isA<LanSocketTransport>());
    });

    test('no active group → soft error explaining the fallback', () async {
      final t = WifiDirectTransport(p2p: _FakeP2p(null));
      await expectLater(
        t.connectToDevice(p2pPeer),
        throwsA(isA<TransportException>()
            .having((e) => e.message, 'message', contains('no active P2P group'))),
      );
      expect(t.state, TransportState.error);
    });

    test('group exists but we are the owner → no outbound connect, clear message',
        () async {
      final t = WifiDirectTransport(
        p2p: _FakeP2p(
          const P2pGroupInfo(inGroup: true, isGroupOwner: true),
        ),
      );
      await expectLater(
        t.connectToDevice(p2pPeer),
        throwsA(isA<TransportException>()
            .having((e) => e.message, 'message', contains('group owner'))),
      );
    });

    test('group forming but owner IP missing → retry-able error', () async {
      final t = WifiDirectTransport(
        p2p: _FakeP2p(
          const P2pGroupInfo(inGroup: true, isGroupOwner: false),
        ),
      );
      await expectLater(
        t.connectToDevice(p2pPeer),
        throwsA(isA<TransportException>()
            .having((e) => e.message, 'message', contains('not exposed yet'))),
      );
    });
  });
}
