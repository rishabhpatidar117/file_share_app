/// The transport *class* a channel uses to put two devices on a shared
/// network segment. The transfer engine (chunking, retry, resume, CRC,
/// ack/scheduling) is identical across every kind — the kind only describes
/// *how the link was formed*.
enum TransportKind {
  lan(
    'LAN',
    'Peer answered on the local network (same Wi-Fi / hotspot / ethernet subnet)',
  ),
  wifiDirect(
    'Wi-Fi Direct',
    'Android Wi-Fi Direct P2P group; TCP runs over the P2P interface',
  ),
  unknown('Unknown', '');

  const TransportKind(this.label, this.description);

  final String label;
  final String description;

  static TransportKind fromName(String? name) {
    for (final kind in TransportKind.values) {
      if (kind.name == name) return kind;
    }
    return TransportKind.unknown;
  }
}