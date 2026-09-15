import 'dart:ffi' as ffi;
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32_registry/win32_registry.dart';

/// A single app that can open a file type, found via the Windows registry.
class OpenApp {
  final String name;
  final String? exePath;
  final bool isDefault;

  const OpenApp({required this.name, this.exePath, this.isDefault = false});
}

/// Enumerates Windows apps that can handle a file extension by scanning the
/// registry (HKEY_CLASSES_ROOT) for extension handlers, then launches the
/// chosen app with `ShellExecuteW`.
class WindowsOpenWith {
  WindowsOpenWith._();

  static List<OpenApp> enumerate(String filePath) {
    final lower =
        filePath.toLowerCase().substring(filePath.toLowerCase().lastIndexOf('.'));
    final ext = lower.startsWith('.') ? lower : '.$lower';
    final apps = <String, OpenApp>{};

    final defaultApp = _defaultHandler(ext);
    if (defaultApp != null) {
      apps[defaultApp.name.toLowerCase()] = defaultApp;
    }

    _progidsFor(ext).forEach((app) {
      apps.putIfAbsent(app.name.toLowerCase(), () => app);
    });

    _openWithListFor(ext).forEach((app) {
      apps.putIfAbsent(app.name.toLowerCase(), () => app);
    });

    _applicationsFor(ext).forEach((app) {
      apps.putIfAbsent(app.name.toLowerCase(), () => app);
    });

    final result = apps.values.toList()
      ..sort((a, b) {
        if (a.isDefault) return -1;
        if (b.isDefault) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return result;
  }

  /// Launches an app with the given file. Falls back to the OS "Open with"
  /// dialog when [exePath] is unavailable.
  static bool launchApp(String exePath, String filePath) {
    if (!File(exePath).existsSync()) {
      showSystemChooser(filePath);
      return false;
    }
    final result = _shellExecute('open', exePath, '"$filePath"');
    return result <= 32 ? false : true;
  }

  /// Brings up the classic Windows "How do you want to open this file?" dialog.
  static void showSystemChooser(String filePath) {
    _shellExecute('openas', filePath, '');
  }

  static OpenApp? _defaultHandler(String ext) {
    try {
      final extKey = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: ext,
      );
      final command = _readString(extKey, r'shell\open\command');
      final friendlyName = extKey.getStringValue('');
      extKey.close();
      if (command == null || command.isEmpty) return null;
      final exe = _extractExe(command);
      if (exe == null) return null;
      return OpenApp(
        name: _friendlyName(friendlyName, exe),
        exePath: exe,
        isDefault: true,
      );
    } catch (_) {
      return null;
    }
  }

  static List<OpenApp> _progidsFor(String ext) {
    final results = <OpenApp>[];
    try {
      final key = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: '$ext\\OpenWithProgids',
      );
      for (final value in key.values) {
        if (value is! StringValue) continue;
        final programId = value.name;
        if (programId.isEmpty) continue;
        final app = _fromProgramId(programId);
        if (app != null) results.add(app);
      }
      key.close();
    } catch (_) {}
    return results;
  }

  static OpenApp? _fromProgramId(String programId) {
    try {
      final progKey = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: programId,
      );
      final command = _readString(progKey, r'shell\open\command');
      final friendlyName = progKey.getStringValue('');
      progKey.close();
      if (command == null || command.isEmpty) return null;
      final exe = _extractExe(command);
      if (exe == null) return null;
      return OpenApp(
        name: _friendlyName(friendlyName, exe),
        exePath: exe,
      );
    } catch (_) {
      return null;
    }
  }

  static List<OpenApp> _openWithListFor(String ext) {
    final results = <OpenApp>[];
    try {
      final key = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: '$ext\\OpenWithList',
      );
      for (final value in key.values) {
        if (value is! StringValue || value.name.isEmpty) continue;
        final exe = value.value.trim();
        if (exe.isEmpty || !File(exe).existsSync()) continue;
        results.add(OpenApp(name: _friendlyName(null, exe), exePath: exe));
      }
      key.close();
    } catch (_) {}
    return results;
  }

  static List<OpenApp> _applicationsFor(String ext) {
    final results = <OpenApp>[];
    try {
      final appsKey = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: r'Applications',
      );
      for (final subkey in appsKey.subkeyNames) {
        final app = _fromApplication(subkey, ext);
        if (app != null) results.add(app);
      }
      appsKey.close();
    } catch (_) {}
    return results;
  }

  static OpenApp? _fromApplication(String appName, String ext) {
    try {
      final appKey = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: 'Applications\\$appName',
      );
      final friendly = appKey.getStringValue('');
      appKey.close();
      if (!_appSupportsExtension(appName, ext)) return null;

      final command = _fromProgramId('Applications\\$appName');
      if (command == null) return null;
      final clean = friendly?.trim() ?? '';
      return OpenApp(
        name: clean.isNotEmpty
            ? clean
            : _friendlyName(null, command.exePath ?? appName),
        exePath: command.exePath,
      );
    } catch (_) {
      return null;
    }
  }

  static bool _appSupportsExtension(String appName, String ext) {
    try {
      final supportedKey = Registry.openPath(
        RegistryHive.classesRoot,
        desiredAccessRights: AccessRights.readOnly,
        path: 'Applications\\$appName\\SupportedTypes',
      );
      final matches = supportedKey.values.any((v) => v.name.toLowerCase() == ext);
      supportedKey.close();
      return matches;
    } catch (_) {
      return false;
    }
  }

  static String? _readString(RegistryKey key, String subPath) {
    final value = key.getValue('', path: subPath, expandPaths: true);
    return switch (value) {
      StringValue(:final value) => value,
      UnexpandedStringValue(:final value) => value,
      _ => null,
    };
  }

  static String? _extractExe(String command) {
    if (command.isEmpty) return null;
    var cmd = command.trim();
    if (cmd.startsWith('"')) {
      final end = cmd.indexOf('"', 1);
      if (end < 0) return null;
      return cmd.substring(1, end).trim();
    }
    final end = cmd.indexOf(' ');
    cmd = end < 0 ? cmd : cmd.substring(0, end);
    return cmd.trim().isEmpty ? null : cmd.trim();
  }

  static String _friendlyName(String? friendly, String exe) {
    if (friendly != null && friendly.trim().isNotEmpty) {
      final clean = friendly.trim().replaceFirst(RegExp(r'\s+\(.*\)$'), '');
      if (clean.isNotEmpty) return clean;
    }
    return exe.split(r'\').last.split('/').last;
  }

  static int _shellExecute(String operation, String file, String parameters) {
    final dylib = ffi.DynamicLibrary.open('shell32.dll');
    final shellExecute = dylib.lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer,
          ffi.Uint32,
        ),
        int Function(
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer,
          ffi.Pointer,
          int,
        )>('ShellExecuteW');

    final operationP = operation.toNativeUtf16();
    final fileP = file.toNativeUtf16();
    final paramsP = parameters.toNativeUtf16();
    const swShowNormal = 1;
    try {
      return shellExecute(
        ffi.nullptr,
        operationP,
        fileP,
        paramsP,
        ffi.nullptr,
        swShowNormal,
      );
    } finally {
      calloc.free(operationP);
      calloc.free(fileP);
      calloc.free(paramsP);
    }
  }
}