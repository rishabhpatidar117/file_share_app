import 'dart:convert';
import 'package:hive/hive.dart';
import 'transfer_session.dart';

class SessionRepository {
  final Box _box;

  SessionRepository(this._box);

  Future<void> saveSession(TransferSession session) async {
    await _box.put(session.id, json.encode(session.toJson()));
  }

  Future<TransferSession?> getSession(String id) async {
    final data = _box.get(id);
    if (data == null) return null;
    return TransferSession.fromJson(json.decode(data));
  }

  Future<List<TransferSession>> getAllSessions() async {
    final sessions = <TransferSession>[];
    for (final key in _box.keys) {
      final data = _box.get(key);
      if (data != null) {
        sessions.add(TransferSession.fromJson(json.decode(data)));
      }
    }
    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
  }

  Future<void> deleteSession(String id) async {
    await _box.delete(id);
  }

  Future<void> setArchived(String id, bool archived) async {
    final session = await getSession(id);
    if (session == null) return;
    await saveSession(session.copyWith(isArchived: archived));
  }

  Future<void> updateSession(TransferSession session) async {
    await saveSession(session);
  }

  /// Persists the true on-disk path for one file in a session so future opens
  /// no longer fall back to a stale location.
  Future<void> updateFilePath(String sessionId, int fileIndex, String newPath) async {
    final session = await getSession(sessionId);
    if (session == null) return;
    final files = List<TransferFileManifest>.from(session.files);
    if (fileIndex < 0 || fileIndex >= files.length) return;
    files[fileIndex] = files[fileIndex].copyWith(filePath: newPath);
    await saveSession(session.copyWith(files: files));
  }
}