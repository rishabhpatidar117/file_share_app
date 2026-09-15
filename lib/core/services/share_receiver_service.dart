import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_handler/share_handler.dart';

import '../../features/discovery/discovery_screen.dart';

/// Captures files shared into SwiftShare from the system share sheet (Android
/// SEND / SEND_MULTIPLE) and opens the send-to-device flow with them preloaded.
class ShareReceiverService {
  /// Used by the app's [MaterialApp] so incoming shares can navigate the UI.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  final List<String> _pendingPaths = [];
  bool _uiReady = false;
  StreamSubscription<SharedMedia>? _subscription;

  List<String> get pendingPaths => List.unmodifiable(_pendingPaths);
  int get pendingCount => _pendingPaths.length;

  Future<void> initialize() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      _subscription = ShareHandler.instance.sharedMediaStream.listen(_process);
      final initial = await ShareHandler.instance.getInitialSharedMedia();
      if (initial != null) {
        await ShareHandler.instance.resetInitialSharedMedia();
        _process(initial);
      }
    } catch (_) {
      // Share receiving is best-effort; the app keeps working without it.
    }
  }

  /// Called once the Flutter UI is attached so a cold-start share can navigate.
  void notifyUiReady() {
    _uiReady = true;
    if (_pendingPaths.isNotEmpty) _openSendFlow();
  }

  Future<void> _process(SharedMedia media) async {
    final paths = <String>[];
    final attachments = media.attachments ?? const <SharedAttachment?>[];
    for (var i = 0; i < attachments.length; i++) {
      final path = attachments[i]?.path;
      if (path == null || path.isEmpty) continue;
      final staged = await _stageFile(path, i);
      if (staged != null) paths.add(staged);
    }

    final content = media.content?.trim();
    if (paths.isEmpty && content != null && content.isNotEmpty) {
      final textFile = await _writeTextFile(content);
      if (textFile != null) paths.add(textFile);
    }
    if (paths.isEmpty) return;

    _pendingPaths
      ..clear()
      ..addAll(paths);

    if (_uiReady) _openSendFlow();
  }

  void _openSendFlow() {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    final paths = List<String>.from(_pendingPaths);
    navigator.push(
      MaterialPageRoute(
        builder: (_) => DiscoveryScreen(initialFilePaths: paths),
      ),
    );
  }

  /// Copies a shared file (staged by the share handler into its own cache) into
  /// a dedicated SwiftShare folder so it stays readable during the transfer.
  Future<String?> _stageFile(String sourcePath, int index) async {
    try {
      final dir = await _shareDir();
      final source = File(sourcePath);
      if (!await source.exists()) return null;

      final base = sourcePath.split(Platform.pathSeparator).last;
      final name = base.isEmpty ? 'shared_item_$index' : base;
      final target = File('${dir.path}/$name');
      if (target.path == source.path) return target.path;
      if (await target.exists()) await target.delete();
      await source.copy(target.path);
      return target.path;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _writeTextFile(String content) async {
    try {
      final dir = await _shareDir();
      final file = File(
        '${dir.path}/shared_text_${DateTime.now().millisecondsSinceEpoch}.txt',
      );
      await file.writeAsString(content);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _shareDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/swiftshare_share');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> dispose() => _subscription?.cancel() ?? Future.value();
}