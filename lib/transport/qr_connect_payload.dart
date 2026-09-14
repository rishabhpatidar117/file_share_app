import 'dart:convert';

/// Encodes/decodes the QR payload used by the "scan to connect" feature.
///
/// Payload format (kept short so the QR stays dense and scannable):
///   swiftshare://v1/base64url JSON
///
/// JSON fields:
///   name  - device display name
///   ip    - reachable IPv4 address of this device
///   port  - TCP service port
class QrConnectPayload {
  static const String scheme = 'swiftshare://';
  static const String version = 'v1';

  final String name;
  final String ip;
  final int port;

  const QrConnectPayload({
    required this.name,
    required this.ip,
    required this.port,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'ip': ip,
    'port': port,
  };

  factory QrConnectPayload.fromJson(Map<String, dynamic> json) {
    return QrConnectPayload(
      name: json['name'] as String? ?? 'Unknown',
      ip: json['ip'] as String,
      port: json['port'] as int,
    );
  }

  String encode() {
    final body = base64UrlEncode(utf8.encode(json.encode(toJson())));
    return '$scheme$version/$body';
  }

  static QrConnectPayload? tryDecode(String raw) {
    final input = raw.trim();
    if (!input.startsWith(scheme)) return null;
    final rest = input.substring(scheme.length);
    if (!rest.startsWith('$version/')) return null;
    final encoded = rest.substring(version.length + 1);
    try {
      final json = jsonDecode(utf8.decode(base64Url.decode(encoded)));
      if (json is! Map<String, dynamic>) return null;
      return QrConnectPayload.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}