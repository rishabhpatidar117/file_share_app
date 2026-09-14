import 'dart:io';

Future<List<String>> getLocalIPv4Addresses() async {
  final addresses = <String>{};
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip == '0.0.0.0') continue;
        if (ip.startsWith('169.254.')) continue;
        addresses.add(ip);
      }
    }
  } catch (_) {}
  // Prefer private LAN ranges first, then everything else.
  final list = addresses.toList()
    ..sort((a, b) => _rank(a).compareTo(_rank(b)));
  return list;
}

int _rank(String ip) {
  if (ip.startsWith('192.168.')) return 0;
  if (ip.startsWith('10.')) return 1;
  if (ip.startsWith('172.')) return 2;
  return 3;
}