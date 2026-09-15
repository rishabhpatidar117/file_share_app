import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import '../../transport/transport_channel.dart';

class SettingsState {
  final bool isDarkMode;
  final int chunkSizeKB;
  final int maxConcurrentFiles;
  final String deviceName;
  final String? saveLocation;

  const SettingsState({
    this.isDarkMode = false,
    this.chunkSizeKB = 512,
    this.maxConcurrentFiles = 3,
    this.deviceName = 'My Device',
    this.saveLocation,
  });

  SettingsState copyWith({
    bool? isDarkMode,
    int? chunkSizeKB,
    int? maxConcurrentFiles,
    String? deviceName,
    String? saveLocation,
    bool clearSaveLocation = false,
  }) {
    return SettingsState(
      isDarkMode: isDarkMode ?? this.isDarkMode,
      chunkSizeKB: chunkSizeKB ?? this.chunkSizeKB,
      maxConcurrentFiles: maxConcurrentFiles ?? this.maxConcurrentFiles,
      deviceName: deviceName ?? this.deviceName,
      saveLocation: clearSaveLocation ? null : (saveLocation ?? this.saveLocation),
    );
  }
}

class SettingsCubit extends Cubit<SettingsState> {
  final Box _settingsBox;
  final TransportChannel _transport;

  SettingsCubit(this._settingsBox, this._transport, {String defaultDeviceName = 'My Device'})
      : super(SettingsState(
          isDarkMode: _settingsBox.get('isDarkMode', defaultValue: false),
          chunkSizeKB: _settingsBox.get('chunkSizeKB', defaultValue: 512),
          maxConcurrentFiles: _settingsBox.get('maxConcurrentFiles', defaultValue: 3),
          deviceName: _settingsBox.get('deviceName', defaultValue: defaultDeviceName),
          saveLocation: _settingsBox.get('saveLocation'),
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

  void setSaveLocation(String? path) {
    if (path == null || path.isEmpty) {
      _settingsBox.delete('saveLocation');
      emit(state.copyWith(clearSaveLocation: true));
      return;
    }
    _settingsBox.put('saveLocation', path);
    emit(state.copyWith(saveLocation: path));
  }
}