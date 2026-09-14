import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Post transfer progress/pause/complete notifications.
///
/// On Android this keeps the user informed while the app is backgrounded.
/// Desktop Linux/Windows show a system notification where supported;
/// on Web this is a no-op.
class NotificationService {
  static const int _transferNotificationId = 7001;
  static const String _channelId = 'swiftshare_transfers';
  static const String _channelName = 'Transfer Progress';
  static const String _channelDescription = 'Live status of file transfers';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (kIsWeb) return;
    if (_initialized) return;

    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');

      DarwinInitializationSettings? darwin;
      LinuxInitializationSettings? linux;
      WindowsInitializationSettings? windows;

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        windows = const WindowsInitializationSettings(
          appName: 'SwiftShare',
          appUserModelId: 'com.swiftshare.app',
          guid: '7c4dff00-0001-0002-7c4d-000000000001',
        );
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        darwin = DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        );
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
        linux = const LinuxInitializationSettings(
          defaultActionName: 'Open',
        );
      }

      final settings = InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
        linux: linux,
        windows: windows,
      );

      // ignore: avoid_void_async
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: null,
      );
      _initialized = true;
    } catch (_) {
      // Notifications are best-effort; never crash the app.
      _initialized = false;
    }
  }

  Future<void> showTransferProgress({
    required String title,
    required String body,
    required double progress,
  }) async {
    if (!_initialized) return;
    try {
      await _plugin.show(
        _transferNotificationId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            maxProgress: 1000,
            progress: (progress.clamp(0.0, 1.0) * 1000).round(),
            onlyAlertOnce: true,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  Future<void> showTransferMessage({
    required String title,
    required String body,
  }) async {
    if (!_initialized) return;
    try {
      await _plugin.show(
        _transferNotificationId,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.low,
            priority: Priority.low,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  Future<void> cancelTransferNotification() async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(_transferNotificationId);
    } catch (_) {}
  }
}