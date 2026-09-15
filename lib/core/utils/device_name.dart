import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Resolves a human-friendly default device name from the underlying OS,
/// falling back to 'My Device' when nothing better is available.
class DeviceName {
  DeviceName._();

  static Future<String> resolve() async {
    try {
      if (kIsWeb) return 'Web Browser';
      final info = DeviceInfoPlugin();
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final android = await info.androidInfo;
          final model = android.model.trim();
          final manufacturer = android.manufacturer.trim();
          if (model.isEmpty) return manufacturer.isNotEmpty ? manufacturer : 'Android Device';
          return manufacturer.isNotEmpty && model.toLowerCase() != manufacturer.toLowerCase()
              ? '$manufacturer $model'
              : model;
        case TargetPlatform.iOS:
          final ios = await info.iosInfo;
          final name = ios.name.trim();
          return name.isNotEmpty ? name : 'iPhone';
        case TargetPlatform.macOS:
          return 'Mac';
        case TargetPlatform.windows:
          final windows = await info.windowsInfo;
          final computerName = windows.computerName.trim();
          return computerName.isNotEmpty ? computerName : 'Windows Device';
        case TargetPlatform.linux:
          return 'Linux Device';
        default:
          return 'My Device';
      }
    } catch (_) {
      return 'My Device';
    }
  }
}