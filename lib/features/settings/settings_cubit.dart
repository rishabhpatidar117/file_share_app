import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import '../../transport/transport_channel.dart';

class SettingsState {
  final bool isDarkMode;
  final int chunkSizeKB;
  final int maxConcurrentFiles;
  final String deviceName;

  const SettingsState({
    this.isDarkMode = false,
    this.chunkSizeKB = 512,
    this.maxConcurrentFiles = 3,
    this.deviceName = 'My Device',
  });

  SettingsState copyWith({
    bool? isDarkMode,
    int? chunkSizeKB,
    int? maxConcurrentFiles,
    String? deviceName,
  }) {
    return SettingsState(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      chunkSizeKB: chunkSizeKB ?? this.chunkSizeKB,
      maxConcurrentFiles: maxConcurrentFiles ?? this.maxConcurrentFiles,
      deviceName: deviceName ?? this.deviceName,
    );
  }
}

class SettingsCubit extends Cubit<SettingsState> {
  final Box _settingsBox;
  final TransportChannel _transport;

  SettingsCubit(this._settingsBox, this._transport)
      : super(SettingsState(
          isDarkMode: _settingsBox.get('isDarkMode', defaultValue: false),
          chunkSizeKB: _settingsBox.get('chunkSizeKB', defaultValue: 512),
          maxConcurrentFiles: _settingsBox.get('maxConcurrentFiles', defaultValue: 3),
          deviceName: _settingsBox.get('deviceName', defaultValue: 'My Device'),
        ));

  void toggleDarkMode() {
    final newMode = !state.isDarkMode;
    _settingsBox.put('isDarkMode', newMode);
    emit(state.copyWith(isDarkMode: newMode));
  }

  void setChunkSize(int kb) {
    _settingsBox.put('chunkSizeKB', kb);
    emit(state.copyWith(chunkSizeKB: kb));
  }

  void setMaxConcurrentFiles(int count) {
    _settingsBox.put('maxConcurrentFiles', count);
    emit(state.copyWith(maxConcurrentFiles: count));
  }

  void setDeviceName(String name) {
    _settingsBox.put('deviceName', name);
    _transport.setDeviceName(name);
    emit(state.copyWith(deviceName: name));
  }
}