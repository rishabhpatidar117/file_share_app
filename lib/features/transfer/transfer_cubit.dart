import 'dart:async';
import 'dart:io';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'transfer_state.dart';
import 'session/transfer_session.dart';
import 'session/session_repository.dart';
import '../../transport/transport_channel.dart';
import '../../core/services/notification_service.dart';
import '../../core/utils/chunker.dart';
import '../file_picker/file_picker_state.dart';

class TransferCubit extends Cubit<TransferState> {
  final TransportChannel _transport;
  final SessionRepository _sessionRepo;
  final NotificationService _notifications;
  final Box _settingsBox;

  StreamSubscription? _stateSub;
  Timer? _speedTimer;
  int _currentFileIndex = 0;
  int _currentChunkIndex = 0;
  bool _isPaused = false;
  int _lastProgressBytes = 0;
  DateTime _lastSpeedSample = DateTime.now();

  TransferCubit(
    this._transport,
    this._sessionRepo,
    this._notifications,
    this._settingsBox,
  ) : super(const TransferState()) {
    _stateSub = _transport.onStateChanged.listen(_onTransportStateChanged);
  }

  int get _chunkSize {
    final kb = _settingsBox.get('chunkSizeKB', defaultValue: 512);
    return kb * 1024;
  }

  void _onTransportStateChanged(TransportState transportState) {
    // Link dropped mid-transfer -> persist session as paused so it can be
    // resumed from the last acked chunk (reconnect/fallback path).
    final neverTransferring = state.session == null ||
        state.status != TransferStatus.transferring ||
        _isPaused;
    if (neverTransferring) return;

    if (transportState == TransportState.disconnected ||
        transportState == TransportState.error) {
      final files = state.session!.files.map((f) {
        return f.status == FileTransferStatus.transferring
            ? f.copyWith(
                status: FileTransferStatus.paused,
                lastAckedChunk: _currentChunkIndex - 1,
              )
            : f;
      }).toList();
      final paused = state.session!.copyWith(
        status: SessionStatus.paused,
        files: files,
      );
      _isPaused = true;
      _sessionRepo.saveSession(paused);
      _notifications.showTransferMessage(
        title: 'Connection lost',
        body: 'Tap Resume to reconnect and continue where it stopped.',
      );
      emit(state.copyWith(
        status: TransferStatus.paused,
        session: paused,
        errorMessage: 'Connection lost. Tap Resume to continue.',
      ));
    }
  }

  Future<void> startTransfer(List<PickedFile> files) async {
    final sessionId = const Uuid().v4();
    final chunkSize = _chunkSize;
    final manifests = files.map((f) => TransferFileManifest(
      fileName: f.name,
      filePath: f.path,
      fileSize: f.size,
      totalChunks: f.size == 0 ? 1 : (f.size / chunkSize).ceil(),
    )).toList();

    final session = TransferSession(
      id: sessionId,
      isSender: true,
      status: SessionStatus.transferring,
      files: manifests,
      createdAt: DateTime.now(),
    );

    await _sessionRepo.saveSession(session);
    _lastProgressBytes = 0;
    _lastSpeedSample = DateTime.now();

    _notifications.showTransferProgress(
      title: 'SwiftShare',
      body: 'Sending ${files.length} file(s)…',
      progress: 0,
    );

    emit(state.copyWith(
      status: TransferStatus.transferring,
      session: session,
    ));

    _startChunkedTransfer();
  }

  void _startChunkedTransfer() async {
    if (state.session == null) return;
    final session = state.session!;

    _isPaused = false;
    final chunkSize = _chunkSize;

    while (_currentFileIndex < session.files.length) {
      if (_isPaused) return;

      final fileManifest = session.files[_currentFileIndex];
      if (fileManifest.status == FileTransferStatus.completed) {
        _currentFileIndex++;
        _currentChunkIndex = 0;
        continue;
      }

      final reader = ChunkedFileReader(
        file: File(fileManifest.filePath),
        chunkSize: chunkSize,
      );

      try {
        while (_currentChunkIndex < reader.totalChunks) {
          if (_isPaused) return;

          final chunk = await reader.readChunk(_currentChunkIndex);
          await _transport.sendChunk(_currentFileIndex, chunk.metadata, chunk.bytes);

          _currentChunkIndex++;
          _updateProgress();
        }

        // File complete: verify full hash, notify receiver.
        final hash = await computeFileHash(fileManifest.filePath);
        await _transport.sendFileComplete(_currentFileIndex, hash);

        _updateFileStatus(_currentFileIndex, FileTransferStatus.completed, actualHash: hash);
        _currentFileIndex++;
        _currentChunkIndex = 0;
      } catch (e) {
        _updateFileStatus(_currentFileIndex, FileTransferStatus.failed);
        _notifications.showTransferMessage(
          title: 'Transfer failed',
          body: fileManifest.fileName,
        );
        emit(state.copyWith(
          status: TransferStatus.failed,
          errorMessage: 'Transfer failed: $e',
        ));
        return;
      }
    }

    final completedSession = state.session!.copyWith(
      status: SessionStatus.completed,
      completedAt: DateTime.now(),
    );
    await _sessionRepo.saveSession(completedSession);
    _notifications.showTransferMessage(
      title: 'Transfer complete',
      body: 'All ${session.files.length} file(s) sent.',
    );
    emit(state.copyWith(
      status: TransferStatus.completed,
      session: completedSession,
    ));
  }

  void _updateFileStatus(int index, FileTransferStatus status, {String? actualHash}) {
    if (state.session == null) return;
    final files = List<TransferFileManifest>.from(state.session!.files);
    files[index] = files[index].copyWith(
      status: status,
      chunksSent: status == FileTransferStatus.completed
          ? files[index].totalChunks
          : files[index].chunksSent,
      lastAckedChunk: status == FileTransferStatus.completed
          ? files[index].totalChunks - 1
          : files[index].lastAckedChunk,
      actualHash: actualHash,
    );
    final session = state.session!.copyWith(files: files);
    emit(state.copyWith(session: session));
  }

  void _updateProgress() {
    if (state.session == null) return;
    final session = state.session!;

    final files = List<TransferFileManifest>.from(session.files);
    if (_currentFileIndex < files.length) {
      files[_currentFileIndex] = files[_currentFileIndex].copyWith(
        chunksSent: _currentChunkIndex,
        lastAckedChunk: _currentChunkIndex - 1,
        status: FileTransferStatus.transferring,
      );
    }

    final updatedSession = session.copyWith(files: files);
    final totalBytes = updatedSession.totalBytes;
    final transferredBytes = updatedSession.transferredBytes;

    final now = DateTime.now();
    final elapsed = now.difference(_lastSpeedSample).inMilliseconds;
    double speed = state.speed;
    if (elapsed >= 800) {
      final delta = transferredBytes - _lastProgressBytes;
      speed = delta * 1000 / elapsed;
      _lastProgressBytes = transferredBytes;
      _lastSpeedSample = now;
    }

    emit(state.copyWith(
      session: updatedSession,
      overallProgress: totalBytes > 0 ? transferredBytes / totalBytes : 0,
      speed: speed,
    ));

    _notifications.showTransferProgress(
      title: 'SwiftShare',
      body:
          '${(totalBytes > 0 ? transferredBytes / totalBytes : 0) * 100 ~/ 1}%'
          ' • ${files[_currentFileIndex].fileName}'
          ' ($_currentChunkIndex/${files[_currentFileIndex].totalChunks})',
      progress: totalBytes > 0 ? transferredBytes / totalBytes : 0,
    );
  }

  void pauseTransfer() {
    if (state.session == null) return;
    _isPaused = true;
    _transport.pause();

    final files = List<TransferFileManifest>.from(state.session!.files);
    if (_currentFileIndex < files.length) {
      files[_currentFileIndex] = files[_currentFileIndex].copyWith(
        status: FileTransferStatus.paused,
        lastAckedChunk: _currentChunkIndex - 1,
      );
    }

    final session = state.session!.copyWith(
      status: SessionStatus.paused,
      files: files,
    );
    _sessionRepo.saveSession(session);
    _notifications.showTransferMessage(
      title: 'Transfer paused',
      body: 'Resume anytime to continue where it stopped.',
    );
    emit(state.copyWith(
      status: TransferStatus.paused,
      session: session,
    ));
  }

  Future<void> resumeTransfer() async {
    if (state.session == null) return;
    _isPaused = false;
    _transport.resume();

    emit(state.copyWith(
      status: TransferStatus.resuming,
      errorMessage: null,
    ));

    await Future.delayed(const Duration(milliseconds: 400));
    emit(state.copyWith(status: TransferStatus.transferring));
    _startChunkedTransfer();
  }

  Future<void> resumeSession(String sessionId) async {
    final session = await _sessionRepo.getSession(sessionId);
    if (session == null) return;

    // Find where to resume from the last acked chunk per file.
    for (int i = 0; i < session.files.length; i++) {
      if (session.files[i].status != FileTransferStatus.completed) {
        _currentFileIndex = i;
        _currentChunkIndex = session.files[i].lastAckedChunk + 1;
        break;
      }
    }

    final resumedSession = session.copyWith(status: SessionStatus.transferring);
    await _sessionRepo.saveSession(resumedSession);
    emit(state.copyWith(
      status: TransferStatus.transferring,
      session: resumedSession,
    ));

    _startChunkedTransfer();
  }

  void cancelTransfer() {
    _isPaused = true;
    _transport.disconnect();
    _notifications.cancelTransferNotification();

    emit(const TransferState());
  }

  @override
  Future<void> close() {
    _stateSub?.cancel();
    _speedTimer?.cancel();
    return super.close();
  }
}