import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/transport/wifi_direct/wifi_p2p_client.dart';

void main() {
  group('P2pGroupInfo.fromMap', () {
    test('parses a full owner-side group map', () {
      final group = P2pGroupInfo.fromMap({
        'inGroup': true,
        'isGroupOwner': true,
        'groupOwnerAddress': 'aa:bb:cc:00:11:22',
        'ownerIp': '192.168.49.1',
        'networkName': 'DIRECT-xx-SwiftShare',
        'passphrase': 'abc123',
        'clientIps': <String>['192.168.49.2', '192.168.49.3'],
      });
      expect(group.inGroup, isTrue);
      expect(group.isGroupOwner, isTrue);
      expect(group.ownerIp, '192.168.49.1');
      expect(group.clientIps, ['192.168.49.2', '192.168.49.3']);
    });

    test('unknown keys / nulls fall back to neutral defaults', () {
      final group = P2pGroupInfo.fromMap(const {});
      expect(group.inGroup, isFalse);
      expect(group.isGroupOwner, isFalse);
      expect(group.ownerIp, isNull);
      expect(group.clientIps, isEmpty);
    });

    test('clientIps tolerates non-string entries', () {
      final group = P2pGroupInfo.fromMap({
        'inGroup': true,
        'clientIps': <Object?>['192.168.49.2', 42, null],
      });
      expect(group.clientIps, ['192.168.49.2']);
    });

    test('reads a string list returned by MethodChannel', () {
      // MethodChannel returns List<Object?>, not List<String>.
      final group = P2pGroupInfo.fromMap(<Object?, Object?>{
        'inGroup': true,
        'ownerIp': '192.168.49.1',
        'clientIps': <Object?>['192.168.49.2'],
      });
      expect(group.inGroup, isTrue);
      expect(group.ownerIp, '192.168.49.1');
      expect(group.clientIps, ['192.168.49.2']);
    });
  });

  group('P2pDeviceInfo.fromMap', () {
    test('parses peer metadata', () {
      final peer = P2pDeviceInfo.fromMap(<Object?, Object?>{
        'deviceAddress': 'aa:bb:cc:00:11:22',
        'deviceName': 'Pixel',
        'isGroupOwner': true,
      });
      expect(peer.deviceAddress, 'aa:bb:cc:00:11:22');
      expect(peer.deviceName, 'Pixel');
      expect(peer.isGroupOwner, isTrue);
    });
  });

  group('WifiP2pClient platform guard', () {
    // On the test VM (not Android) the client must answer with neutral defaults
    // without ever touching the method channel.
    test('isSupportedAndEnabled is false off-Android', () async {
      expect(await WifiP2pClient().isSupportedAndEnabled(), isFalse);
    });

    test('groupInfo is null off-Android', () async {
      expect(await WifiP2pClient().groupInfo(), isNull);
    });

    test('startDiscovery is refused off-Android', () async {
      expect(await WifiP2pClient().startDiscovery(), isFalse);
    });
  });
}
