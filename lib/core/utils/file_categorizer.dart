import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

enum FileCategory { general, videos, audio, documents, images, compressed }

/// Categorizes incoming files into folders so the Downloads folder stays tidy.
class FileCategorizer {
  FileCategorizer._();

  static String folderName(FileCategory category) {
    switch (category) {
      case FileCategory.videos:
        return 'Videos';
      case FileCategory.audio:
        return 'Audio';
      case FileCategory.documents:
        return 'Documents';
      case FileCategory.images:
        return 'Images';
      case FileCategory.compressed:
        return 'Compressed';
      case FileCategory.general:
        return 'General';
    }
  }

  static FileCategory resolve(String fileName) {
    final lower = fileName.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return FileCategory.general;
    final ext = lower.substring(dot);

    const images = {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic', '.heif', '.tiff', '.svg', '.ico', '.avif'};
    const videos = {'.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.mpeg', '.mpg', '.ts', '.h264'};
    const audio = {'.mp3', '.wav', '.aac', '.flac', '.ogg', '.m4a', '.opus', '.wma', '.amr', '.aiff', '.mid', '.midi'};
    const documents = {'.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx', '.txt', '.rtf', '.csv', '.md', '.odt', '.ods', '.odp', '.pages', '.numbers', '.key', '.epub', '.tex'};
    const compressed = {'.zip', '.rar', '.7z', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.iso', '.z', '.jar', '.apk', '.cab', '.deb', '.rpm'};

    if (images.contains(ext)) return FileCategory.images;
    if (videos.contains(ext)) return FileCategory.videos;
    if (audio.contains(ext)) return FileCategory.audio;
    if (documents.contains(ext)) return FileCategory.documents;
    if (compressed.contains(ext)) return FileCategory.compressed;
    return FileCategory.general;
  }
}

/// Resolves the root "SwiftShare" folder, always nesting category folders inside it.
class SwiftShareStore {
  SwiftShareStore._();

  static const String rootFolderName = 'SwiftShare';

  /// Returns the path to the SwiftShare root folder, creating it (and any
  /// missing parents) if needed. Never nests SwiftShare inside itself.
  static Future<String> resolveRoot(String? userLocation) async {
    String parent;
    if (userLocation != null && userLocation.isNotEmpty) {
      parent = userLocation;
    } else {
      try {
        if (!kIsWeb) {
          final downloads = await getDownloadsDirectory();
          if (downloads != null) {
            parent = downloads.path;
          } else {
            final docs = await getApplicationDocumentsDirectory();
            parent = docs.path;
          }
        } else {
          parent = Directory.systemTemp.path;
        }
      } catch (_) {
        parent = Directory.current.path;
      }
    }
    return _ensureRoot(parent);
  }

  /// Builds the destination for an incoming file at [rootPath] slash `<category>` slash [fileName].
  static Future<File> createDestination(String rootPath, String fileName) async {
    final folder = FileCategorizer.folderName(FileCategorizer.resolve(fileName));
    final dir = Directory('$rootPath/$folder');
    await dir.create(recursive: true);
    return File('${dir.path}/$fileName');
  }

  static Future<String> _ensureRoot(String parent) async {
    final parentDir = File(parent);
    final base = parentDir.uri.pathSegments.isNotEmpty
        ? parentDir.uri.pathSegments.last
        : '';
    final root = Directory(parent);
    if (root.path.endsWith('/$rootFolderName') || root.path.endsWith('\\$rootFolderName') || base == rootFolderName) {
      await root.create(recursive: true);
      return root.path;
    }
    final rootDir = Directory('$parent/$rootFolderName');
    await rootDir.create(recursive: true);
    return rootDir.path;
  }
}