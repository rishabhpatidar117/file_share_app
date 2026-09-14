import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:window_manager/window_manager.dart';
import 'app/app.dart';
import 'core/di/service_locator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Hive.initFlutter();
  await initServiceLocator();

  await _configureWindowAndOverlays();

  runApp(const SwiftShareApp());
}

Future<void> _configureWindowAndOverlays() async {
  // Immersive edge-to-edge: transparent status/nav bars.
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
  ));

  try {
    final isDesktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);

    if (isDesktop) {
      final windowManager = getIt<WindowManager>();
      await windowManager.ensureInitialized();
      await windowManager.setTitle('SwiftShare');
      await windowManager.setMinimumSize(const Size(640, 520));
    }
  } catch (_) {
    // Desktop window chrome is optional; fall back gracefully.
  }
}