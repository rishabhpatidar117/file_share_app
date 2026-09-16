import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Snapshot of the active network as seen by the OS, used for transfer
/// diagnostics and path selection logging. On Android these come from a small
/// native platform channel (WifiManager + ConnectivityManager); on other
/// platforms the fields we cannot measure are left null rather than guessed.
class WifiLinkInfo {
  final String? transportType; // 'wifi' | 'cellular' | 'ethernet' | 'unknown'
  final bool? isMetered;
  final String? ssid;
  final String? bssid;

  /// TX link rate in Mbps as reported by the radio.
  final int? linkSpeedMbps;

  /// RX link rate in Mbps (Android 11+ only; null on older devices).
  final int? rxLinkSpeedMbps;

  /// Operating frequency in MHz.
  final int? frequencyMhz;
  final int? rssiDbm;
  final bool? is5GHz;
  final bool? is6GHz;
  final String? wifiStandard; // 'Wi-Fi 4' ... 'Wi-Fi 7'

  const WifiLinkInfo({
    this.transportType,
    this.isMetered,
    this.ssid,
    this.bssid,
    this.linkSpeedMbps,
    this.rxLinkSpeedMbps,
    this.frequencyMhz,
    this.rssiDbm,
    this.is5GHz,
    this.is6GHz,
    this.wifiStandard,
  });

  bool get isWifi => transportType == 'wifi';

  String get bandLabel => is6GHz == true
      ? '6 GHz'
      : is5GHz == true
          ? '5 GHz'
          : '2.4 GHz';

  String get standardLabel => wifiStandard ?? 'Unknown';

  /// Concise one-line summary for the transfer screen / diagnostics logs.
  /// e.g. "5 GHz • Wi-Fi 6 • 1201 Mbps"  or  "Unknown network".
  String get summaryLabel {
    if (transportType == null || transportType == 'unknown') {
      return transportType == null ? '' : 'Unknown network';
    }
    if (transportType == 'wifi') {
      final parts = <String>[
        if (frequencyMhz != null || is5GHz != null || is6GHz != null)
          bandLabel,
        if (wifiStandard != null) standardLabel,
        if (linkSpeedMbps != null) '$linkSpeedMbps Mbps',
      ];
      return parts.isEmpty ? 'Wi-Fi' : parts.join(' • ');
    }
    return '${transportType![0].toUpperCase()}${transportType!.substring(1)}';
  }

  factory WifiLinkInfo.fromMap(Map<Object?, Object?> raw) {
    return WifiLinkInfo(
      transportType: raw['transportType'] as String?,
      isMetered: raw['isMetered'] as bool?,
      ssid: raw['ssid'] as String?,
      bssid: raw['bssid'] as String?,
      linkSpeedMbps: (raw['linkSpeed'] as num?)?.toInt(),
      rxLinkSpeedMbps: (raw['rxLinkSpeed'] as num?)?.toInt(),
      frequencyMhz: (raw['frequency'] as num?)?.toInt(),
      rssiDbm: (raw['rssi'] as num?)?.toInt(),
      is5GHz: raw['is5GHz'] as bool?,
      is6GHz: raw['is6GHz'] as bool?,
      wifiStandard: raw['wifiStandard'] as String?,
    );
  }
}

/// Reads the active local-network characteristics so transfers can log what
/// the radio is ACTUALLY negotiated at, instead of assuming Wi-Fi branding.
class NetworkDiagnostics {
  static const MethodChannel _channel = MethodChannel('swiftshare/network_info');

  /// Returns null when the platform exposes nothing (web, or Android without
  /// network info). Never throws.
  Future<WifiLinkInfo?> getActiveWifiInfo() async {
    if (kIsWeb || !Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getActiveWifiInfo',
      );
      if (raw == null || raw.isEmpty) return null;
      return WifiLinkInfo.fromMap(raw);
    } catch (_) {
      return null;
    }
  }
}