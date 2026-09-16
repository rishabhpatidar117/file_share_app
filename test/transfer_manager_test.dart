import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/transport/transfer_manager.dart';
import 'package:swiftshare/transport/transport_kind.dart';
import 'package:swiftshare/transport/device_info.dart';
import 'package:swiftshare/core/services/network_diagnostics.dart';

void main() {
  const manager = TransportManager();
  const wifi5 = WifiLinkInfo(
    transportType: 'wifi',
    isMetered: false,
    ssid: 'Home-5G',
    linkSpeedMbps: 1201,
    rxLinkSpeedMbps: 1201,
    frequencyMhz: 5180,
    rssiDbm: -48,
    is5GHz: true,
    wifiStandard: 'Wi-Fi 6',
  );

  group('TransportManager.evaluate', () {
    test('formed P2P group with selected peer → Wi-Fi Direct, high confidence',
        () {
      const p2p = P2pGroupState(
        supported: true,
        enabled: true,
        inGroup: true,
        isGroupOwner: false,
        ownerIp: '192.168.49.1',
      );
      final d = manager.evaluate(p2p: p2p, p2pPeerSelected: true);
      expect(d.kind, TransportKind.wifiDirect);
      expect(d.confidence, greaterThanOrEqualTo(80));
      expect(d.rationale.join(' '), contains('P2P'));
    });

    test('active group but owner IP unknown → still Wi-Fi Direct, lower score',
        () {
      const p2p = P2pGroupState(
        supported: true,
        enabled: true,
        inGroup: true,
        isGroupOwner: true,
      );
      final d = manager.evaluate(p2p: p2p);
      expect(d.kind, TransportKind.wifiDirect);
      expect(d.confidence, 60);
      expect(d.rationale.join(' '), contains('IP not exposed'));
    });

    test('peer found on the same Wi-Fi → LAN, high confidence', () {
      final d = manager.evaluate(link: wifi5, localDiscoveryDetected: true);
      expect(d.kind, TransportKind.lan);
      expect(d.confidence, 90);
      expect(d.rationale.join(' '), contains('beacon'));
    });

    test('no shared LAN but P2P available and idle → offer Wi-Fi Direct',
        () {
      const p2p = P2pGroupState(supported: true, enabled: true);
      final d = manager.evaluate(link: wifi5, p2p: p2p);
      expect(d.kind, TransportKind.wifiDirect);
      expect(d.confidence, 40);
      expect(d.rationale.join(' '), contains('create a private link'));
    });

    test('nothing measured → LAN fallback with lowest confidence', () {
      final d = manager.evaluate();
      expect(d.kind, TransportKind.lan);
      expect(d.confidence, 20);
    });

    test('Windows note never advertises Wi-Fi Direct to it', () {
      final d = manager.evaluate(
        link: wifi5,
        localDiscoveryDetected: true,
        platform: DevicePlatform.windows,
      );
      expect(d.kind, TransportKind.lan);
      expect(d.rationale.join(' '), contains('Windows'));
    });

    test('never ranks Wi-Fi 6 over Wi-Fi Direct or claims a fixed rate', () {
      for (final result in [
        manager.evaluate(link: wifi5, localDiscoveryDetected: true),
        manager.evaluate(p2p: const P2pGroupState(
          supported: true,
          enabled: true,
          inGroup: true,
          ownerIp: '192.168.49.1',
        )),
      ]) {
        expect(
          result.rationale.join(' ').toLowerCase(),
          isNot(contains('faster')),
        );
        expect(result.rationale.join(' ').toLowerCase(),
            isNot(contains('mbps is guaranteed')));
      }
    });
  });
}
