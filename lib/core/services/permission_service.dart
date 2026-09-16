import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'notification_service.dart';

/// Centralized runtime permission handling.
///
/// The LAN transport only needs the INTERNET permission, which on Android is
/// a normal (install-time) permission and is granted automatically. The only
/// runtime-granted permission this app ever requests is POST_NOTIFICATIONS on
/// Android 13+ so transfer progress/complete notifications still display.
class PermissionService {
  final NotificationService _notifications;

  static const MethodChannel _permissionChannel =
      MethodChannel('swiftshare/permissions');

  PermissionService(this._notifications);

  /// Returns true when network access is usable; on Android this requires no
  /// runtime prompt (INTERNET is granted at install time), so it only reports
  /// the current result on platforms where that could fail.
  Future<bool> ensureNetworkAccess() async {
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android) {
      return true;
    }
    return true;
  }

  /// Request the Android 13+ notification permission so progress/completion
  /// notifications are visible. Best-effort; returns true if permitted.
  Future<bool> requestNotificationPermission() async {
    if (kIsWeb) return true;
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        final android = _notifications
            .plugin
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        return await android?.requestNotificationsPermission() ?? true;
      } catch (_) {
        return true;
      }
    }
    return true;
  }

  /// Request the runtime permissions needed for Wi-Fi Direct on Android
  /// (ACCESS_FINE_LOCATION on API ≤32, NEARBY_WIFI_DEVICES on API 33+).
  /// No-op on other platforms. Returns true when the permissions are granted.
  Future<bool> requestWifiDirectPermissions() async {
    if (kIsWeb) return true;
    if (!Platform.isAndroid) return true;
    try {
      return await _permissionChannel.invokeMethod<bool>(
            'requestWifiDirect',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
}