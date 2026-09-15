import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';
import 'package:uuid/uuid.dart';
import 'transfer_state.dart';
import 'session/transfer_session.dart';
import 'session/session_repository.dart';
import '../../transport/transport_channel.dart';
import '../../core/services/notification_service.dart';
import '../../core/utils/chunker.dart';
import '../../core/utils/crc32c.dart';
import '../../core/utils/file_categorizer.dart';
import '../file_picker/file_picker_state.dart';

class TransferCubit extends Cubit<TransferState> {
  final TransportChannel _transport;
  final SessionRepository _sessionRepo;
  final NotificationService _notifications;
  final Box _settingsBox;

  StreamSubscription? _stateSub;
  StreamSubscription? _incomingSessionSub;
  StreamSubscription? _incomingChunkSub;
  StreamSubscription? _incomingFileCompleteSub;
  StreamSubscription? _incomingSessionCompleteSub;
  Timer? _speedTimer;

  // Sender state.
  int _currentFileIndex = 0;
  int _currentChunkIndex = 0;
  bool _isPaused = false;
  int _lastProgressBytes = 0;
  DateTime _lastSpeedSample = DateTime.now();
  Map<int, int> _resumePoints = {};

  // Number of full chunks already acknowledged by the receiver for the file
  // currently being sent. Drives pause markers and progress.
  int _highestAckedChunk = 0;

  // Receiver state.
  TransferSession? _incoming;
  String? _incomingSaveDir;
  int _incomingChunkSize = 512 * 1024;
  final Map<int, RandomAccessFile> _incomingRafs = {};
  String? _incomingSessionId;

  /// Serializes disk writes per file so concurrent inbound chunks can never
  /// interleave offsets on the same RandomAccessFile.
  final Map<int, Future<void>> _incomingWriteChains = {};

  /// Number of contiguous chunks ([0, n)) already flushed to disk per file.
  /// Never recedes, so progress and resume points stay accurate even with
  /// out-of-order retransmits.
  final Map<int, int> _incomingContiguousChunks = {};

  /// Chunks accepted from the wire but not yet writable because a lower index
  /// is still being retransmitted. Bounded by the sender's in-flight window.
  final Map<int, Map<int, Uint8List>> _incomingPendingChunks = {};

  /// Files a whole-file resend is in progress for; such files always restart
  /// at chunk 0 regardless of previously acked progress.
  final Set<int> _forcedRestartFiles = {};

  TransferCubit(
    this._transport,
    this._sessionRepo,
    this._notifications,
    this._settingsBox,
  ) : super(const TransferState()) {
    _stateSub = _transport.onStateChanged.listen(_onTransportStateChanged);
    _incomingSessionSub =
        _transport.onIncomingSession.listen((request) => _onIncomingSession(request));
    _incomingChunkSub =
        _transport.onChunkReceived.listen((event) => _onIncomingChunk(event));
    _incomingFileCompleteSub =
        _transport.onIncomingFileComplete.listen(_onIncomingFileComplete);
    _incomingSessionCompleteSub =
        _transport.onIncomingSessionComplete.listen((_) => _onIncomingSessionComplete());
  }

  int get _chunkSize {
    final kb = _settingsBox.get('chunkSizeKB', defaultValue: 512);
    return kb * 1024;
  }

  /// How many chunks may be in flight before the sender waits for an ack.
  /// Reuses the persisted "max concurrent files" knob as the parallel-window
  /// depth. Bounded (max 16) so large transfers never buffer the whole file.
  int get _pipelineDepth =>
      (_settingsBox.get('maxConcurrentFiles', defaultValue: 3) as int)
          .clamp(1, 16);

  String get _deviceName =>
      _settingsBox.get('deviceName', defaultValue: 'My Device');

  void _onTransportStateChanged(TransportState transportState) {
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
                lastAckedChunk: (_highestAckedChunk - 1).clamp(-1, f.totalChunks - 1),
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

  // ---------------------------------------------------------------------------
  // Sender flow
  // ---------------------------------------------------------------------------

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

    emit(state.copyWith(status: TransferStatus.preparing, session: session));

    // Negotiate the session: the receiver replies with resume points based on
    // any partially received files on disk.
    try {
      final meta = <SessionFileMeta>[];
      for (var i = 0; i < manifests.length; i++) {
        meta.add(SessionFileMeta(
          index: i,
          fileName: manifests[i].fileName,
          fileSize: manifests[i].fileSize,
          totalChunks: manifests[i].totalChunks,
        ));
      }
      final resume = await _transport.sendSessionStart(
        sessionId,
        _deviceName,
        meta,
        chunkSize: chunkSize,
      );
      _resumePoints = Map.from(resume);
    } catch (e) {
      emit(state.copyWith(
        status: TransferStatus.failed,
        errorMessage: 'Could not start session: $e',
      ));
      return;
    }

    await _sessionRepo.saveSession(session);
    _currentFileIndex = 0;
    _currentChunkIndex = 0;
    _highestAckedChunk = 0;
    _lastProgressBytes = 0;
    _lastSpeedSample = DateTime.now();
    _isPaused = false;
    _forcedRestartFiles.clear();

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
    _isPaused = false;
    final chunkSize = _chunkSize;
    final depth = _pipelineDepth;

    while (_currentFileIndex < state.session!.files.length) {
      if (_isPaused) return;

      final fileManifest = state.session!.files[_currentFileIndex];
      if (fileManifest.status == FileTransferStatus.completed) {
        _currentFileIndex++;
        continue;
      }

      // SAF picks return `content://` URIs (no cache copy), so resolve them to
      // a live native fd path the reader/hash can open like a plain file. The
      // descriptor stays open for the whole file and is closed in the cleanup
      // below.
      SafOpenFd? contentFd;
      String sourcePath = fileManifest.filePath;
      final ChunkedFileReader reader;
      try {
        final resolved = await _resolveSourceForSend(fileManifest.filePath);
        sourcePath = resolved.$1;
        contentFd = resolved.$2;
        reader = ChunkedFileReader(file: File(sourcePath), chunkSize: chunkSize);
      } catch (e) {
        if (contentFd != null) {
          try {
            await Saf().closeFileDescriptor(contentFd.fd);
          } catch (_) {}
        }
        _failTransfer(e, fileManifest);
        return;
      }

      Object? failure;
      var fileOk = false;
      String hash = '';
      try {
        final receiverStart = _resumePoints[_currentFileIndex] ?? 0;
        final fromLastAck = fileManifest.lastAckedChunk + 1;
        // Whole-file resends (rejected file) start from scratch; otherwise
        // continue from whichever side knows more data is already on disk.
        var current = _forcedRestartFiles.contains(_currentFileIndex)
            ? 0
            : (receiverStart > fromLastAck ? receiverStart : fromLastAck);
        if (current < 0) current = 0;
        _currentChunkIndex = current;
        _highestAckedChunk = current;

        // Sliding window of chunk sends: fire up to [depth] chunks before
        // waiting on an ack. Memory stays bounded (a few chunks) regardless of
        // file size; the reader's read-ahead feeds the window while awaiting.
        final inFlight = <Future<void>>[];
        var sent = 0;
        var acked = current;
        Object? sendError;

        while (current < reader.totalChunks) {
          if (_isPaused) return;
          if (inFlight.length >= depth) {
            await inFlight.removeAt(0);
            acked++;
          }

          final chunk = await reader.readChunk(current);
          inFlight.add(
            _sendChunkWithRetry(_currentFileIndex, chunk).then<void>(
              (_) {},
              onError: (Object e, StackTrace st) => sendError ??= e,
            ),
          );
          current++;
          sent++;
          _currentChunkIndex = current;
          _highestAckedChunk = acked;
          _updateProgress(chunksSent: sent, ackedChunks: acked);
        }

        while (inFlight.isNotEmpty) {
          await inFlight.removeAt(0);
          acked++;
        }
        _highestAckedChunk = acked;
        _updateProgress(chunksSent: sent, ackedChunks: acked);

        if (sendError != null) {
          failure = sendError;
        } else if (!_isPaused) {
          hash = await computeFileHash(sourcePath);
          try {
            await _transport.sendFileComplete(
              _currentFileIndex,
              hash,
              fileName: fileManifest.fileName,
              fileSize: fileManifest.fileSize,
              totalChunks: reader.totalChunks,
            );
            fileOk = true;
          } on TransportException {
            // Receiver flagged a corrupt whole file (or never acked it):
            // resend every chunk from scratch instead of trusting old progress.
            _resumePoints[_currentFileIndex] = 0;
            _forcedRestartFiles.add(_currentFileIndex);
          }
        }
      } catch (e) {
        failure = e;
      } finally {
        await reader.close();
        if (contentFd != null) {
          try {
            await Saf().closeFileDescriptor(contentFd.fd);
          } catch (_) {}
        }
      }

      if (failure != null) {
        _failTransfer(failure, fileManifest);
        return;
      }
      if (_isPaused) return;
      if (!fileOk) continue;

      _updateFileStatus(_currentFileIndex, FileTransferStatus.completed,
          actualHash: hash);
      _forcedRestartFiles.remove(_currentFileIndex);
      _currentFileIndex++;
      _resumePoints.clear();
    }

    final completedSession = state.session!.copyWith(
      status: SessionStatus.completed,
      completedAt: DateTime.now(),
    );
    await _sessionRepo.saveSession(completedSession);
    await _transport.sendSessionComplete(completedSession.id);
    _notifications.showTransferMessage(
      title: 'Transfer complete',
      body: 'All ${completedSession.files.length} file(s) sent.',
    );
    emit(state.copyWith(
      status: TransferStatus.completed,
      session: completedSession,
    ));
  }

  /// Resolves the path given to the sender into something [dart:io] can open.
  ///
  /// Regular files pass through unchanged. `content://` URIs (from SAF picks)
  /// are bridged to a native fd via `/proc/self/fd/<fd>`, which the
  /// existing [ChunkedFileReader] and [computeFileHash] can stream like any
  /// file — no whole-file copy into app cache. The caller must close the
  /// returned fd once the file is done.
  Future<(String, SafOpenFd?)> _resolveSourceForSend(String filePath) async {
    if (!filePath.startsWith('content://')) return (filePath, null);
    final fd = await Saf().openFileDescriptor(filePath, 'r');
    return (fd.path, fd);
  }

  Future<void> _sendChunkWithRetry(int fileIndex, ChunkData chunk) async {
    const maxAttempts = 100;
    var attempts = 0;
    while (true) {
      attempts++;
      try {
        await _transport.sendChunk(fileIndex, chunk.metadata, chunk.bytes);
        return;
      } on TransportException {
        // If the transport is paused (socket closed, user tapped pause) the
        // transfer loop will notice on the next iteration — just return here.
        if (_isPaused) return;
        final ts = _transport.state;
        if (ts == TransportState.disconnected ||
            ts == TransportState.paused ||
            ts == TransportState.error) {
          return;
        }
        if (attempts >= maxAttempts) rethrow;
        final backoff = 250 * (1 << (attempts - 1).clamp(0, 4));
        await Future.delayed(Duration(milliseconds: backoff));
      }
    }
  }

  void _failTransfer(Object e, TransferFileManifest manifest) {
    _updateFileStatus(_currentFileIndex, FileTransferStatus.failed);
    _notifications.showTransferMessage(
      title: 'Transfer failed',
      body: manifest.fileName,
    );
    emit(state.copyWith(
      status: TransferStatus.failed,
      errorMessage: 'Transfer failed: $e',
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

  void _updateProgress({required int chunksSent, required int ackedChunks}) {
    if (state.session == null) return;
    final session = state.session!;

    final files = List<TransferFileManifest>.from(session.files);
    if (_currentFileIndex < files.length) {
      files[_currentFileIndex] = files[_currentFileIndex].copyWith(
        chunksSent: chunksSent,
        lastAckedChunk: ackedChunks - 1,
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
        lastAckedChunk: (_highestAckedChunk - 1).clamp(-1, files[_currentFileIndex].totalChunks - 1),
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

    if (!session.isSender) {
      emit(state.copyWith(
        incomingSession: session,
        saveDirectory: _incomingSaveDir,
        incomingError: 'Open Receive mode to continue. Already received '
            'files resume automatically.',
        status: state.status,
      ));
      return;
    }

    // Re-negotiate so the receiver reports how far along it is.
    try {
      final meta = <SessionFileMeta>[];
      for (var i = 0; i < session.files.length; i++) {
        final f = session.files[i];
        meta.add(SessionFileMeta(
          index: i,
          fileName: f.fileName,
          fileSize: f.fileSize,
          totalChunks: f.totalChunks,
        ));
      }
      final resume = await _transport.sendSessionStart(
        session.id,
        _deviceName,
        meta,
        chunkSize: _chunkSize,
      );
      _resumePoints = Map.from(resume);
    } catch (e) {
      emit(state.copyWith(
        status: TransferStatus.failed,
        errorMessage: 'Could not reconnect: $e',
      ));
      return;
    }

    for (int i = 0; i < session.files.length; i++) {
      if (session.files[i].status != FileTransferStatus.completed) {
        _currentFileIndex = i;
        final fromReceiver = _resumePoints[i];
        _currentChunkIndex = fromReceiver ?? session.files[i].lastAckedChunk + 1;
        _highestAckedChunk = _currentChunkIndex;
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
    for (final raf in _incomingRafs.values) {
      try {
        raf.closeSync();
      } catch (_) {}
    }
    _incomingRafs.clear();
    _incomingWriteChains.clear();
    _incomingPendingChunks.clear();
    _incomingContiguousChunks.clear();
    _incomingSessionId = null;

    emit(const TransferState());
  }

  // ---------------------------------------------------------------------------
  // Receiver flow
  // ---------------------------------------------------------------------------

  Future<void> _onIncomingSession(IncomingSession request) async {
    final saveDir = await _resolveSaveDirectory();
    final manifests = <TransferFileManifest>[];
    for (final meta in request.files) {
      final dest = await SwiftShareStore.createDestination(saveDir, meta.fileName);
      manifests.add(TransferFileManifest(
        fileName: meta.fileName,
        filePath: dest.path,
        fileSize: meta.fileSize,
        expectedHash: meta.sha256,
        totalChunks: meta.totalChunks,
        lastAckedChunk: -1,
      ));
    }

    final incoming = TransferSession(
      id: request.sessionId,
      remoteDeviceName: request.remoteDeviceName,
      isSender: false,
      status: SessionStatus.transferring,
      files: manifests,
      createdAt: DateTime.now(),
    );
    _incoming = incoming;
    _incomingSaveDir = saveDir;
    _incomingChunkSize = request.chunkSize > 0 ? request.chunkSize : _chunkSize;

    // Reset all receiver bookkeeping when a genuinely new session arrives.
    // When the same session is re-negotiated (pause/resume) the warm prefix
    // maps are kept so we don't need to re-verify data already on disk.
    if (_incomingSessionId != request.sessionId) {
      _incomingSessionId = request.sessionId;
      for (final raf in _incomingRafs.values) {
        try {
          await raf.close();
        } catch (_) {}
      }
      _incomingRafs.clear();
      _incomingWriteChains.clear();
      _incomingPendingChunks.clear();
      _incomingContiguousChunks.clear();
    }

    // Resume from the contiguous on-disk prefix when available (accurate
    // for both offset-based retransmits and sequential writes).  Fall back
    // to the legacy length heuristic for cold-starts after app restarts
    // when the warm maps were lost.
    final resume = <int, int>{};
    for (var i = 0; i < request.files.length; i++) {
      final manifest = manifests[i];
      final warmPrefix = _incomingContiguousChunks[i];
      if (warmPrefix != null && warmPrefix > 0) {
        // The sender starts at the reported index, so reporting a fully
        // received file (== totalChunks) makes it skip straight to the
        // file_complete verification.
        resume[i] = warmPrefix;
      } else {
        final part = File('${manifest.filePath}.swiftshare.part');
        if (await part.exists()) {
          final len = await part.length();
          resume[i] = _nextChunkForBytes(len, request.files[i].totalChunks);
        } else {
          resume[i] = 0;
        }
      }
    }

    await _sessionRepo.saveSession(incoming);
    await _transport.acceptIncoming(request.sessionId, resume);

    _notifications.showTransferMessage(
      title: 'Incoming transfer',
      body: '${request.remoteDeviceName} is sending ${request.files.length} file(s).',
    );
    emit(state.copyWith(incomingSession: incoming, saveDirectory: saveDir));
  }

  Future<void> _onIncomingChunk(ChunkReceivedEvent event) async {
    final incoming = _incoming;
    if (incoming == null) return;

    // Serialize per-file writes: broadcast streams may deliver multiple chunk
    // events while an earlier async handler is still flushing.  Chaining
    // ensures each file's RandomAccessFile sees setPosition/write calls in the
    // order they arrive, and retried chunks land at their correct offset
    // regardless of when they showed up.
    final chain =
        _incomingWriteChains[event.fileIndex] ?? Future<void>.value();
    final next = chain.catchError((_) {}).then(
          (_) => _processIncomingChunk(event),
        );
    _incomingWriteChains[event.fileIndex] = next.catchError((_) {});
    return next;
  }

  Future<void> _processIncomingChunk(ChunkReceivedEvent event) async {
    final incoming = _incoming;
    if (incoming == null) return;
    final fileIndex = event.fileIndex;
    final manifest = incoming.files[fileIndex];
    final partPath = '${manifest.filePath}.swiftshare.part';

    try {
      final actualCrc = Crc32c.hash(event.data);
      if (actualCrc != event.metadata.crc32cChecksum) {
        await _transport.sendChunkError(fileIndex, event.metadata.index);
        return;
      }

      final prefix = _incomingContiguousChunks[fileIndex] ?? 0;

      if (event.metadata.index < prefix) {
        // A retransmitted chunk whose data is already on disk — ack and move on.
        await _transport.sendChunkAck(fileIndex, event.metadata.index);
        return;
      }

      if (event.metadata.index > prefix) {
        // An earlier chunk (the gap) is being retransmitted. Hold this one in
        // memory (bounded by the sender's in-flight window) until the missing
        // chunk arrives, then flush everything in order. Writing strictly in
        // order keeps the part file contiguous, so a late retransmit can never
        // corrupt other chunks' data.
        (_incomingPendingChunks[fileIndex] ??= <int, Uint8List>{})
            [event.metadata.index] = event.data;
        await _transport.sendChunkAck(fileIndex, event.metadata.index);
        return;
      }

      // Sequential chunk: append right after the contiguous prefix.
      final raf = _incomingRafs[fileIndex] ??=
          await File(partPath).open(mode: FileMode.append);
      await raf.writeFrom(event.data);

      _incomingContiguousChunks[fileIndex] = prefix + 1;

      // Flush any buffered chunks that are now contiguous, strictly in order.
      var next = prefix + 1;
      final pending = _incomingPendingChunks[fileIndex];
      if (pending != null) {
        while (pending.containsKey(next)) {
          await raf.writeFrom(pending.remove(next)!);
          next++;
        }
      }
      await raf.flush();
      _incomingContiguousChunks[fileIndex] = next;

      _pumpIncomingProgress(fileIndex, next);
      await _transport.sendChunkAck(fileIndex, event.metadata.index);
    } catch (e) {
      await _transport.sendChunkError(fileIndex, event.metadata.index);
    }
  }

  Future<void> _onIncomingFileComplete(IncomingFileComplete event) async {
    final incoming = _incoming;
    if (incoming == null) return;
    final manifest = incoming.files[event.fileIndex];
    final partPath = '${manifest.filePath}.swiftshare.part';
    final partFile = File(partPath);

    final raf = _incomingRafs.remove(event.fileIndex);
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {}
    }

    if (!await partFile.exists()) {
      // A duplicate marker (or crash after rename) can leave the part file
      // gone but the final file already in place.  Verify and ack rather
      // than triggering a needless full resend.
      final finalFile = File(manifest.filePath);
      if (await finalFile.exists() &&
          await finalFile.length() == manifest.fileSize) {
        if (event.sha256.isNotEmpty) {
          final existingHash = await computeFileHash(manifest.filePath);
          if (existingHash != event.sha256) {
            await _incomingFailFile(event.fileIndex);
            return;
          }
        }
        await _transport.sendFileCompleteAck(event.fileIndex);
        final files = List<TransferFileManifest>.from(_incoming!.files);
        files[event.fileIndex] = files[event.fileIndex].copyWith(
          status: FileTransferStatus.completed,
          chunksSent: files[event.fileIndex].totalChunks,
          lastAckedChunk: files[event.fileIndex].totalChunks - 1,
        );
        _incoming = _incoming!.copyWith(files: files);
        emit(state.copyWith(incomingSession: _incoming, incomingError: null));
        return;
      }
      await _incomingFailFile(event.fileIndex);
      return;
    }

    if (await partFile.length() != manifest.fileSize) {
      await _incomingFailFile(event.fileIndex);
      return;
    }

    final actualHash = await computeFileHash(partPath);
    if (event.sha256.isNotEmpty && actualHash != event.sha256) {
      await _incomingFailFile(event.fileIndex);
      return;
    }

    final finalFile = File(manifest.filePath);
    if (await finalFile.exists()) await finalFile.delete();
    await partFile.rename(manifest.filePath);
    await _transport.sendFileCompleteAck(event.fileIndex);

    final files = List<TransferFileManifest>.from(_incoming!.files);
    files[event.fileIndex] = files[event.fileIndex].copyWith(
      status: FileTransferStatus.completed,
      chunksSent: files[event.fileIndex].totalChunks,
      lastAckedChunk: files[event.fileIndex].totalChunks - 1,
      actualHash: actualHash,
    );
    _incoming = _incoming!.copyWith(files: files);
    _incomingContiguousChunks.remove(event.fileIndex);
    _incomingPendingChunks.remove(event.fileIndex);
    emit(state.copyWith(incomingSession: _incoming, incomingError: null));
  }

  Future<void> _incomingFailFile(int fileIndex) async {
    if (_incoming == null) return;
    // Delete the corrupt partial file so the resend starts from scratch.
    final manifest = _incoming!.files[fileIndex];
    final partFile = File('${manifest.filePath}.swiftshare.part');
    try {
      if (await partFile.exists()) await partFile.delete();
    } catch (_) {}
    final raf = _incomingRafs.remove(fileIndex);
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _incomingPendingChunks.remove(fileIndex);
    _incomingContiguousChunks.remove(fileIndex);

    final files = List<TransferFileManifest>.from(_incoming!.files);
    files[fileIndex] = files[fileIndex].copyWith(
      status: FileTransferStatus.failed,
    );
    _incoming = _incoming!.copyWith(files: files);
    emit(state.copyWith(
      incomingSession: _incoming,
      incomingError: 'File verification failed; requesting resend…',
    ));
    await _transport.sendFileRetry(fileIndex);
  }

  Future<void> _onIncomingSessionComplete() async {
    final incoming = _incoming;
    if (incoming == null) return;
    for (final raf in _incomingRafs.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _incomingRafs.clear();
    _incomingWriteChains.clear();
    _incomingPendingChunks.clear();
    _incomingContiguousChunks.clear();
    _incomingSessionId = null;

    final completed = incoming.copyWith(
      status: SessionStatus.completed,
      completedAt: DateTime.now(),
    );
    await _sessionRepo.saveSession(completed);
    _notifications.showTransferMessage(
      title: 'Transfer complete',
      body: '${completed.files.length} file(s) saved to ${_incomingSaveDir ?? ''}',
    );
    emit(state.copyWith(incomingSession: completed));
    _incoming = null;
  }

  void _pumpIncomingProgress(int fileIndex, int chunksReceived) {
    if (_incoming == null) return;
    final files = List<TransferFileManifest>.from(_incoming!.files);
    files[fileIndex] = files[fileIndex].copyWith(
      status: FileTransferStatus.transferring,
      chunksSent: chunksReceived,
      lastAckedChunk: chunksReceived - 1,
    );
    _incoming = _incoming!.copyWith(files: files);
    emit(state.copyWith(incomingSession: _incoming));
  }

  int _nextChunkForBytes(int bytes, int totalChunks) {
    if (bytes <= 0) return 0;
    final chunkSize = _incomingChunkSize;
    final n = (bytes / chunkSize).ceil();
    return n >= totalChunks ? totalChunks : n;
  }

  Future<String> _resolveSaveDirectory() async {
    final userLocation = _settingsBox.get('saveLocation') as String?;
    try {
      return await SwiftShareStore.resolveRoot(userLocation);
    } catch (_) {
      try {
        if (!kIsWeb) {
          final docs = await getApplicationDocumentsDirectory();
          return docs.path;
        }
      } catch (_) {}
      return Directory.current.path;
    }
  }

  @override
  Future<void> close() {
    _stateSub?.cancel();
    _speedTimer?.cancel();
    _incomingSessionSub?.cancel();
    _incomingChunkSub?.cancel();
    _incomingFileCompleteSub?.cancel();
    _incomingSessionCompleteSub?.cancel();
    return super.close();
  }
}