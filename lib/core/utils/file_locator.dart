import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'file_categorizer.dart';

/// Tries to find a transferred file on disk even when the recorded absolute path
/// is stale (user changed save folder, app update, OneDrive redirect, etc).
class FileLocator {
  FileLocator._();

  /// Returns a readable local path for [fileName] or `null` when nothing could
  /// be found.
  ///
  /// Search order:
  /// 1. [recordedPath] still exists.
  /// 2. SwiftShare roots the user may currently be using (custom save location,
  ///    downloads, documents).
  /// 3. Non-recursive scan up the directory tree from [recordedPath].
  static Future<String?> locate({
    required String recordedPath,
    required String fileName,
    String? saveLocation,
  }) async {
    // 1. The session still points to a live file.
    try {
      if (recordedPath.isNotEmpty && await File(recordedPath).exists()) {
        return recordedPath;
      }
    } catch (_) {}

    // 2. Walk every SwiftShare root we currently know about.
    for (final rootPath in await _candidateRoots(saveLocation)) {
      final match = await _findInRoot(rootPath, fileName);
      if (match != null) return match;
    }

    // 3. Walk upward from the recorded parent directory.
    try {
      final match = await _walkUp(recordedPath, fileName);
      if (match != null) return match;
    } catch (_) {}

    return null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static Future<List<String>> _candidateRoots(String? saveLocation) async {
    final paths = <String>[];
    String add(String p) {
      if (!paths.contains(p)) paths.add(p);
      return p;
    }

    if (saveLocation != null && saveLocation.isNotEmpty) {
      add(saveLocation);
    }

    if (!kIsWeb) {
      try {
        final d = await getDownloadsDirectory();
        if (d != null) add(d.path);
      } catch (_) {}
      try {
        final d = await getApplicationDocumentsDirectory();
        add(d.path);
      } catch (_) {}
    }

    // Resolve SwiftShare nesting for each so sibling category folders are found.
    final resolved = <String>[];
    for (final p in List.of(paths)) {
      try {
        resolved.add(await SwiftShareStore.resolveRoot(p));
      } catch (_) {}
    }
    paths.addAll(resolved.where((p) => !paths.contains(p)));
    return paths;
  }

  static Future<String?> _findInRoot(String rootPath, String fileName) async {
    final root = Directory(rootPath);
    try {
      if (!await root.exists()) return null;

      // Check category subfolders (Images/, Videos/ …) plus the root itself.
      await for (final entity in root.list(followLinks: false)) {
        if (entity is File) {
          if (_baseName(entity.path) == fileName) return entity.path;
        }
        if (entity is Directory) {
          final candidate = File('${entity.path}/$fileName');
          try {
            if (await candidate.exists()) return candidate.path;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  /// Walks up the tree looking for the file inside any folder we encounter.
  static Future<String?> _walkUp(String recordedPath, String fileName) async {
    var dir = await _parent(recordedPath);
    const maxDepth = 6;
    for (var i = 0; i < maxDepth && dir != null; i++) {
      final candidate = File('${dir.path}/$fileName');
      try {
        if (await candidate.exists()) return candidate.path;
      } catch (_) {}

      // Also scan one level for the common SwiftShare layout.
      final parent = dir;
      try {
        await for (final child in parent.list(followLinks: false).take(200)) {
          if (child is File && _baseName(child.path) == fileName) {
            return child.path;
          }
          if (child is Directory) {
            final nested = File('${child.path}/$fileName');
            try {
              if (await nested.exists()) return nested.path;
            } catch (_) {}
          }
        }
      } catch (_) {}
      dir = await _parent(dir.path);
    }
    return null;
  }

  static Future<Directory?> _parent(String path) async {
    try {
      final parent = File(path).parent;
      return parent.existsSync() ? parent : null;
    } catch (_) {
      return null;
    }
  }

  static String _baseName(String path) => path.split(Platform.pathSeparator).last;
}
