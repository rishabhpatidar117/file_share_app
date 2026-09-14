class DeviceInfo {
  final String id;
  final String name;
  final DevicePlatform platform;
  final ConnectionQuality quality;
  final String? address;
  final int? port;

  const DeviceInfo({
    required this.id,
    required this.name,
    this.platform = DevicePlatform.unknown,
    this.quality = ConnectionQuality.good,
    this.address,
    this.port,
  });

  DeviceInfo copyWith({
    String? id,
    String? name,
    DevicePlatform? platform,
    ConnectionQuality? quality,
    String? address,
    int? port,
  }) {
    return DeviceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      quality: quality ?? this.quality,
      address: address ?? this.address,
      port: port ?? this.port,
    );
  }
}

enum DevicePlatform {
  android,
  windows,
  web,
  unknown;

  String get displayName {
    switch (this) {
      case DevicePlatform.android:
        return 'Android';
      case DevicePlatform.windows:
        return 'Windows';
      case DevicePlatform.web:
        return 'Web';
      case DevicePlatform.unknown:
        return 'Unknown';
    }
  }

  String get iconName {
    switch (this) {
      case DevicePlatform.android:
        return 'android';
      case DevicePlatform.windows:
        return 'desktop_windows';
      case DevicePlatform.web:
        return 'language';
      case DevicePlatform.unknown:
        return 'device_unknown';
    }
  }
}

enum ConnectionQuality {
  excellent,
  good,
  fair,
  poor;

  double get score {
    switch (this) {
      case ConnectionQuality.excellent:
        return 1.0;
      case ConnectionQuality.good:
        return 0.75;
      case ConnectionQuality.fair:
        return 0.5;
      case ConnectionQuality.poor:
        return 0.25;
    }
  }
}
