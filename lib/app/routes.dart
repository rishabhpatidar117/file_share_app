import 'package:flutter/material.dart';
import '../features/home/home_screen.dart';
import '../features/discovery/discovery_screen.dart';
import '../features/file_picker/file_picker_screen.dart';
import '../features/transfer/transfer_screen.dart';
import '../features/history/history_screen.dart';
import '../features/settings/settings_screen.dart';

class AppRoutes {
  static const String home = '/';
  static const String discovery = '/discovery';
  static const String filePicker = '/file-picker';
  static const String transfer = '/transfer';
  static const String history = '/history';
  static const String settings = '/settings';

  static Map<String, WidgetBuilder> get routes => {
    home: (_) => const HomeScreen(),
    discovery: (_) => const DiscoveryScreen(),
    filePicker: (_) => const FilePickerScreen(),
    transfer: (_) => const TransferScreen(),
    history: (_) => const HistoryScreen(),
    settings: (_) => const SettingsScreen(),
  };
}