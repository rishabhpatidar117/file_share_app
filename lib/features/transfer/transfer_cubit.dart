import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saf/saf.dart';
import 'package:uuid/uuid.dart';
import 'transfer_state.dart';
import 'session/transfer_session.dart';
import 'session/session_repository.dart';
import '../../transport/transport_channel.dart';
import '../../transport/device_info.dart';
import '../../transport/transport_kind.dart';
import '../../transport/transfer_manager.dart';
import '../../core/services/transfer_notification_queue.dart';
import '../../core/services/network_diagnostics.dart';
import '../../core/services/transfer_foreground_service.dart';
import '../../core/utils/chunker.dart';
import '../../core/utils/crc32c.dart';
import '../../core/utils/file_categorizer.dart';
import '../file_picker/file_picker_state.dart';

/// Upper bound on how often the TransferCubit may emit UI progress updates.
/// The transfer engine keeps exact byte counters internally; the UI only needs
/// ~15 updates/sec for smooth rendering (way down from one emit per chunk).
const Duration _kUiProgressInterval = Duration(milliseconds: 66);

/// Receiver-side fsync cadence. Flushing RandomAccessFile every chunk forces a
/// disk write-through per chunk; the OS page cache already orders the writes,
/// so we only call flush() once ~8 MB of chunks accumulated or the file ends.
/// ACKs are sent after the write (not the flush), so pipelining is untouched.
const int _kIncomingFlushThresholdBytes = 8 * 1024 * 1024;

class TransferCubit extends Cubit<TransferState> {
  final TransportChannel _transport;
  final SessionRepository _sessionRepo;
  final TransferNotificationQueue _notifications;
  final NetworkDiagnostics _diagnostics;
  final TransferForegroundService _foreground;
  final Box _settingsBox;

  StreamSubscription? _stateSub;
  StreamSubscription? _incomingSessionSub;
  StreamSubscription? _incomingChunkSub;
  StreamSubscription? _incomingFileCompleteSub;
  StreamSubscription? _incomingSessionCompleteSub;
  StreamSubscription? _incomingSessionFailedSub;
  Timer? _speedTimer;

  // Sender state.
  int _currentFileIndex = 0;
  int _currentChunkIndex = 0;
  bool _isPaused = false;
  int _lastProgressBytes = 0;
  DateTime _lastSpeedSample = DateTime.now();
  DateTime _lastUiEmit = DateTime.fromMillisecondsSinceEpoch(0);
  Map<int, int> _resumePoints = {};

  // Number of full chunks already acknowledged by the receiver for the file
  // currently being sent. Drives pause markers and progress.
  int _highestAckedChunk = 0;

  /// Adaptive transfer-lane budget. Starts at the configured
  /// `maxConcurrentFiles` base and drifts ± with the measured chunk round-trip
  /// latency between files (bounded so memory stays predictable).
  int _depthBias = 0;

  /// Round-trip samples for the current file (microseconds per chunk send).
  final List<int> _chunkRttSamples = [];

  /// Most recent average chunk round-trip latency, for the diagnostics log.
  int _lastAckLatencyMicros = 0;

  // Receiver state.
  TransferSession? _incoming;
  String? _incomingSaveDir;
  int _incomingChunkSize = 512 * 1024;
  final Map<int, RandomAccessFile> _incomingRafs = {};
  String? _incomingSessionId;
  DateTime _lastIncomingUiEmit = DateTime.fromMillisecondsSinceEpoch(0);

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

  /// Bytes written to each part file since the last forced flush().
  final Map<int, int> _incomingFlushDebt = {};

  /// Files a whole-file resend is in progress for; such files always restart
  /// at chunk 0 regardless of previously acked progress.
  final Set<int> _forcedRestartFiles = {};

  /// Consecutive whole-file resend (file_retry) requests sent per file index.
  /// A resend that keeps failing past this limit is escalated to a session
  /// failure on both ends so neither side is left stuck retrying forever.
  final Map<int, int> _fileRetryCount = {};

  TransferCubit(
    this._transport,
    this._sessionRepo,
    this._notifications,
    this._diagnostics,
    this._foreground,
    this._settingsBox,
  ) : super(const TransferState()) {
    _stateSub = _transport.onStateChanged.listen(_onTransportStateChanged);
    _incomingSessionSub = _transport.onIncomingSession.listen(
      (request) => _onIncomingSession(request).catchError((Object e) {
        try {
          _transport.sendSessionFailed(request.sessionId, 'Incoming session failed: $e');
        } catch (_) {}
        return _failIncomingSession('Incoming session failed: $e');
      }),
    );
    _incomingChunkSub =
        _transport.onChunkReceived.listen((event) => _onIncomingChunk(event));
    _incomingFileCompleteSub =
        _transport.onIncomingFileComplete.listen(_onIncomingFileComplete);
    _incomingSessionCompleteSub =
        _transport.onIncomingSessionComplete.listen((_) => _onIncomingSessionComplete());
    _incomingSessionFailedSub =
        _transport.onSessionFailed.listen(_onSessionFailed);
  }

  /// Sender AND receiver converge on failure from the same [SessionFailed] frame.
  ///
  /// - If we are the receiver of the named session, fail that incoming session.
  /// - If we are the sender of a live outgoing session and the peer reports it
  ///   cannot continue (e.g. disk full), fail our side promptly instead of
  ///   retrying chunks into the void until a 30 s ack timeout.
  void _onSessionFailed(SessionFailed failure) {
    final outgoing = state.session;
    if (outgoing != null &&
        outgoing.isSender &&
        state.status == TransferStatus.transferring &&
        (failure.sessionId.isEmpty || failure.sessionId == outgoing.id)) {
      _isPaused = true;
      unawaited(_foreground.stop());
      _notifications.showMessage(
        title: 'Transfer failed',
        body: failure.reason,
      );
      emit(state.copyWith(
        status: TransferStatus.failed,
        errorMessage: failure.reason,
      ));
      return;
    }
    final activeIncoming = _incoming;
    if (activeIncoming != null &&
        activeIncoming.id == failure.sessionId) {
      unawaited(_failIncomingSession('Sender aborted: ${failure.reason}'));
    }
  }

  int get _chunkSize {
    final kb = _settingsBox.get('chunkSizeKB', defaultValue: 512);
    return kb * 1024;
  }

  /// How many chunks may be in flight before the sender waits for an ack.
  /// Starts from the persisted "max concurrent files" knob and is adjusted
  /// between files by measured round-trip latency. Bounded (max 16) so large
  /// transfers never buffer the whole file.
  int get _pipelineDepth {
    final base =
        (_settingsBox.get('maxConcurrentFiles', defaultValue: 3) as int)
            .clamp(1, 8);
    return (base + _depthBias).clamp(1, 16);
  }

  String get _deviceName =>
      _settingsBox.get('deviceName', defaultValue: 'My Device');

void _onTransportStateChanged(TransportState transportState) {
  // A live incoming session has no "pause later" option: if the link dies mid
  // receive, fail the session on this side too, so the receiver never stays
  // "Waiting" while the sender has already failed.
  if (_incoming != null &&
      (transportState == TransportState.disconnected ||
          transportState == TransportState.error)) {
    unawaited(_failIncomingSession('Connection lost while receiving.'));
    return;
  }

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
      unawaited(_foreground.stop());
      _sessionRepo.saveSession(paused);
      _notifications.showMessage(
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
      unawaited(_notifyPeerSessionFailed('Could not start session: $e'));
      return;
    }

    await _sessionRepo.saveSession(session);
    _currentFileIndex = 0;
    _currentChunkIndex = 0;
    _highestAckedChunk = 0;
    _lastProgressBytes = 0;
    _lastSpeedSample = DateTime.now();
    _lastUiEmit = DateTime.fromMillisecondsSinceEpoch(0);
    _isPaused = false;
    _forcedRestartFiles.clear();

    _notifications.showProgress(
      title: 'SwiftShare',
      body: 'Sending ${files.length} file(s)…',
      progress: 0,
    );

    unawaited(_captureNetworkInfo());
    unawaited(_logTransportDecision());

    unawaited(_foreground.start());

    emit(state.copyWith(
      status: TransferStatus.transferring,
      session: session,
    ));

    _startChunkedTransfer();
  }

  /// Logs which transport class the engine is actually running on, plus the
/// recommendation the [TransportManager] would make given the measured link.
/// Diagnostic only — never blocks the transfer, never changes behaviour.
Future<void> _logTransportDecision() async {
  final decision = const TransportManager().evaluate(
    link: state.networkInfo,
    localDiscoveryDetected: true,
    platform: _transport.transportKind == TransportKind.wifiDirect
        ? DevicePlatform.android
        : DevicePlatform.unknown,
  );
  debugPrint(
    '[TRANSPORT] actual=${_transport.transportKind.label} '
    'recommended=${decision.kind.label} (${decision.confidence}%) — '
    '${decision.rationale.join(' | ')}',
  );
  if (!isClosed) {
    emit(state.copyWith(
      transportLabel: '${_transport.transportKind.label} • '
          '${decision.kind.label} (${decision.confidence}%)',
    ));
  }
}

/// Reads the active radio's negotiated parameters (band, Wi-Fi standard,
  /// link speed) and reflects them into the UI + logs. Best-effort and never
  /// allowed to block or fail the transfer.
  Future<void> _captureNetworkInfo() async {
    try {
      final info = await _diagnostics.getActiveWifiInfo();
      if (info != null) {
        debugPrint(
          '[TRANSFER] network=${info.summaryLabel} '
          'ssid=${info.ssid ?? "?"} rssi=${info.rssiDbm ?? 0}dBm',
        );
        if (!isClosed) emit(state.copyWith(networkInfo: info));
      }
    } catch (_) {}
  }

  void _startChunkedTransfer() async {
    if (state.session == null) return;
    _isPaused = false;
    unawaited(_foreground.start());
    final chunkSize = _chunkSize;

    while (_currentFileIndex < state.session!.files.length) {
      if (_isPaused) return;

      final fileManifest = state.session!.files[_currentFileIndex];
      if (fileManifest.status == FileTransferStatus.completed) {
        _currentFileIndex++;
        continue;
      }

      // SAF picks return `content://` URIs (no cache copy), which dart:io
      // cannot open directly. `_resolveSourceForSend` bridges such URIs into a
      // private cache file first (the `/proc/self/fd/<n>` pseudo-path some
      // providers hand out fails to re-open with EACCES on Android), so the
      // reader and hash run against a real file. The temp copy is deleted once
      // this file has been sent or failed.
      var tempCopy = false;
      String sourcePath = fileManifest.filePath;
      final ChunkedFileReader reader;
      try {
        final resolved = await _resolveSourceForSend(
          fileManifest.filePath,
          fileManifest.fileName,
        );
        sourcePath = resolved.$1;
        tempCopy = resolved.$2;
        reader = ChunkedFileReader(file: File(sourcePath), chunkSize: chunkSize);
      } catch (e) {
        if (tempCopy) {
          try {
            await File(sourcePath).delete();
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
        final depth = _pipelineDepth;
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
          final sw = Stopwatch()..start();
          inFlight.add(
            _sendChunkWithRetry(_currentFileIndex, chunk).then<void>(
              (_) {
                sw.stop();
                _chunkRttSamples.add(sw.elapsedMicroseconds);
              },
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
        _updateProgress(chunksSent: sent, ackedChunks: acked, force: true);

        if (sendError != null) {
          failure = sendError;
        } else if (!_isPaused) {
          hash = await computeFileHashInBackground(sourcePath);
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
        if (tempCopy) {
          try {
            await File(sourcePath).delete();
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
      _adjustLaneBudget();
      _chunkRttSamples.clear();
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
    _notifications.showMessage(
      title: 'Transfer complete',
      body: 'All ${completedSession.files.length} file(s) sent.',
    );
    unawaited(_foreground.stop());
    emit(state.copyWith(
      status: TransferStatus.completed,
      session: completedSession,
    ));
  }

  /// Resolves the path given to the sender into something [dart:io] can open.
  ///
  /// Regular files pass through unchanged. `content://` URIs (from SAF picks)
  /// are bridged into a private temporary cache file via
  /// [Saf.copyToLocalFile], which streams through the granted content resolver.
  /// Dart's [File] cannot safely re-open the `/proc/self/fd/<fd>` pseudo-path a
  /// provider hands out — the kernel denies a fresh `open()` of that symlink
  /// with EACCES on Android. Stream-copying once avoids that entirely; the
  /// caller deletes the temp file when the file is done.
  Future<(String, bool)> _resolveSourceForSend(
    String filePath,
    String displayName,
  ) async {
    if (!filePath.startsWith('content://')) return (filePath, false);
    final tmpDir = await getTemporaryDirectory();
    final base =
        (displayName.isEmpty ? 'file' : displayName).replaceAll(
          RegExp(r'[\\/:*?"<>|]'),
          '_',
        );
    final tmpPath =
        '${tmpDir.path}/ss_${DateTime.now().microsecondsSinceEpoch}_$base';
    await Saf().copyToLocalFile(filePath, tmpPath);
    return (tmpPath, true);
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

  /// Grows/shrinks the in-flight lane budget based on measured chunk round-trip
  /// latency. Running on the measured link, so it makes no claims about Wi-Fi
  /// branding. Bounded drift keeps memory use predictable.
  void _adjustLaneBudget() {
    if (_chunkRttSamples.length < 2) return;
    var sum = 0;
    for (final sample in _chunkRttSamples) {
      sum += sample;
    }
    final avgMicros = sum ~/ _chunkRttSamples.length;
    _lastAckLatencyMicros = avgMicros;
    if (avgMicros < 8000) {
      _depthBias = (_depthBias + 1).clamp(-2, 8);
    } else if (avgMicros > 50000) {
      _depthBias = (_depthBias - 1).clamp(-2, 8);
    }
    debugPrint(
      '[TRANSFER] lanes=$_pipelineDepth avgChunkRtt=${_lastAckLatencyMicros}us',
    );
  }

  void _failTransfer(Object e, TransferFileManifest manifest) {
    _updateFileStatus(_currentFileIndex, FileTransferStatus.failed);
    unawaited(_foreground.stop());
    _notifications.showMessage(
      title: 'Transfer failed',
      body: manifest.fileName,
    );
    emit(state.copyWith(
      status: TransferStatus.failed,
      errorMessage: 'Transfer failed: $e',
    ));
    // Tell the peer the session is dead so the receiver stops showing
    // "Waiting" and converges on "Failed" too.
    unawaited(_notifyPeerSessionFailed('Transfer failed: $e'));
  }

  /// Best-effort `session_failed` frame to the peer. Never throws; if the link
  /// is already gone the peer's own transport-disconnect handler will converge
  /// on a failed state.
  Future<void> _notifyPeerSessionFailed(String reason) async {
    final sessionId = state.session?.id ?? '';
    if (sessionId.isEmpty) return;
    try {
      await _transport.sendSessionFailed(sessionId, reason);
    } catch (_) {}
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

  void _updateProgress({
  required int chunksSent,
  required int ackedChunks,
  bool force = false,
}) {
  if (state.session == null) return;
  final session = state.session!;
  if (_currentFileIndex >= session.files.length) return;

  final files = List<TransferFileManifest>.from(session.files);
  files[_currentFileIndex] = files[_currentFileIndex].copyWith(
    chunksSent: chunksSent,
    lastAckedChunk: ackedChunks - 1,
    status: FileTransferStatus.transferring,
  );

  final updatedSession = session.copyWith(files: files);
  final totalBytes = updatedSession.totalBytes;
  final transferredBytes = updatedSession.transferredBytes;
  final progress = totalBytes > 0 ? transferredBytes / totalBytes : 0.0;

  final now = DateTime.now();
  final elapsed = now.difference(_lastSpeedSample).inMilliseconds;
  double speed = state.speed;
  if (elapsed >= 800) {
    final delta = transferredBytes - _lastProgressBytes;
    speed = delta * 1000 / elapsed;
    _lastProgressBytes = transferredBytes;
    _lastSpeedSample = now;
  }

  // Throttle UI emissions to ~15/sec (the transfer engine keeps its own exact
  // byte counters above). `force` guarantees the final state is emitted.
  final shouldEmit = force ||
      now.difference(_lastUiEmit) >= _kUiProgressInterval;
  if (shouldEmit) {
    _lastUiEmit = now;
    emit(state.copyWith(
      session: updatedSession,
      overallProgress: progress,
      speed: speed,
    ));
  }

  _notifications.showProgress(
    title: 'SwiftShare',
    body: '${(progress * 100).toInt()}%'
        ' • ${files[_currentFileIndex].fileName}'
        ' ($_currentChunkIndex/${files[_currentFileIndex].totalChunks})',
    progress: progress,
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
    _notifications.showMessage(
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
      unawaited(_notifyPeerSessionFailed('Could not reconnect: $e'));
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
    try {
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
        _incomingFlushDebt.clear();
        _fileRetryCount.clear();
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

      _notifications.showMessage(
        title: 'Incoming transfer',
        body: '${request.remoteDeviceName} is sending '
            '${request.files.length} file(s).',
      );
      unawaited(_foreground.start());
      emit(state.copyWith(incomingSession: incoming, saveDirectory: saveDir));
    } catch (e) {
      // Destination creation / save-directory resolution failed (permissions,
      // disk error, invalid path). This cannot succeed on retry: abort the
      // session on both ends instead of leaving the sender pumping chunks into
      // the void while this device still shows a stale welcome state.
      try {
        await _transport.sendSessionFailed(
          request.sessionId,
          'Could not prepare incoming files: $e',
        );
      } catch (_) {}
      final failedSession = TransferSession(
        id: request.sessionId,
        remoteDeviceName: request.remoteDeviceName,
        isSender: false,
        status: SessionStatus.failed,
        files: request.files
            .map((m) => TransferFileManifest(
                  fileName: m.fileName,
                  filePath: '${_incomingSaveDir ?? ''}/${m.fileName}',
                  fileSize: m.fileSize,
                  totalChunks: m.totalChunks,
                  status: FileTransferStatus.failed,
                ))
            .toList(),
        createdAt: DateTime.now(),
      );
      _incoming = null;
      _incomingSessionId = null;
      await _sessionRepo.saveSession(failedSession);
      unawaited(_foreground.stop());
      _notifications.showMessage(
        title: 'Transfer failed',
        body: 'Incoming files could not be opened.',
      );
      emit(state.copyWith(
        incomingSession: failedSession,
        incomingError: 'Could not prepare incoming files: $e',
      ));
    }
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

      // Coalesce fsync: flush once ~8 MB accumulated (or at file end) instead
      // of once per chunk. The chunk ack goes out after the write completes,
      // which keeps the sender's pipeline full; the OS page cache orders the
      // writes, and resume uses the contiguous-chunk prefix / part length which
      // are still accurate (worst case after a crash the sender resends a few
      // chunks the receiver re-verifies by CRC).
      var flushDebt = (_incomingFlushDebt[fileIndex] ?? 0) + event.data.length;
      if (flushDebt >= _kIncomingFlushThresholdBytes ||
          next >= manifest.totalChunks) {
        await raf.flush();
        flushDebt = 0;
      }
      _incomingFlushDebt[fileIndex] = flushDebt;
      _incomingContiguousChunks[fileIndex] = next;

      _pumpIncomingProgress(
        fileIndex,
        next,
        force: next >= manifest.totalChunks,
      );
      await _transport.sendChunkAck(fileIndex, event.metadata.index);
    } catch (e) {
      // The CRC check is routed above, so reaching this catch means the chunk
      // could not be WRITTEN (disk full, file removed, permissions). Retrying
      // the same chunk is guaranteed to fail again, so abort the whole session
      // on both ends instead of looping chunk_error → retransmit → error.
      try {
        await _transport.sendSessionFailed(
          _incomingSessionId ?? '',
          'Could not save incoming data: $e',
        );
      } catch (_) {}
      await _failIncomingSession('Could not save incoming data: $e');
      return;
    }
  }

  Future<void> _onIncomingFileComplete(IncomingFileComplete event) async {
    final incoming = _incoming;
    if (incoming == null) return;
    try {
      final manifest = incoming.files[event.fileIndex];
      final partPath = '${manifest.filePath}.swiftshare.part';
      final partFile = File(partPath);

      final raf = _incomingRafs.remove(event.fileIndex);
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      _incomingFlushDebt.remove(event.fileIndex);

      if (!await partFile.exists()) {
        // A duplicate marker (or crash after rename) can leave the part file
        // gone but the final file already in place.  Verify and ack rather
        // than triggering a needless full resend.
        final finalFile = File(manifest.filePath);
        if (await finalFile.exists() &&
            await finalFile.length() == manifest.fileSize) {
          if (event.sha256.isNotEmpty) {
            final existingHash = await computeFileHashInBackground(manifest.filePath);
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
          _fileRetryCount.remove(event.fileIndex);
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

      final actualHash = await computeFileHashInBackground(partPath);
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
      _fileRetryCount.remove(event.fileIndex);
      _incoming = _incoming!.copyWith(files: files);
      _incomingContiguousChunks.remove(event.fileIndex);
      _incomingPendingChunks.remove(event.fileIndex);
      emit(state.copyWith(incomingSession: _incoming, incomingError: null));
    } catch (e) {
      // Verification/I/O error while finalizing the file (rename, hash read,
      // delete). A resend cannot heal a disk-level failure, so abort the whole
      // session on both ends.
      try {
        await _transport.sendSessionFailed(
          event.sessionId,
          'Incoming file verification failed: $e',
        );
      } catch (_) {}
      await _failIncomingSession('Incoming file verification failed: $e');
    }
  }

  /// Marks the active incoming session as failed on this device, cleans up all
  /// receive bookkeeping, and surfaces a visible "Failed" state so the receiver
  /// converges with the sender instead of sitting on "Waiting" forever.
  Future<void> _failIncomingSession(String reason) async {
    final incoming = _incoming;
    if (incoming == null || incoming.status == SessionStatus.completed) return;
    for (final raf in _incomingRafs.values) {
      try {
        await raf.close();
      } catch (_) {}
    }
    _incomingRafs.clear();
    _incomingWriteChains.clear();
    _incomingPendingChunks.clear();
    _incomingContiguousChunks.clear();
    _incomingFlushDebt.clear();
    _incomingSessionId = null;
    _fileRetryCount.clear();

    final failedFiles = incoming.files
        .map((f) => f.status == FileTransferStatus.completed
            ? f
            : f.copyWith(status: FileTransferStatus.failed))
        .toList();
    final failed = incoming.copyWith(
      status: SessionStatus.failed,
      files: failedFiles,
    );
    await _sessionRepo.saveSession(failed);
    unawaited(_foreground.stop());
    _notifications.showMessage(
      title: 'Transfer failed',
      body: reason,
    );
    emit(state.copyWith(
      incomingSession: failed,
      incomingError: reason,
    ));
    _incoming = null;
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
    _incomingFlushDebt.remove(fileIndex);

    final files = List<TransferFileManifest>.from(_incoming!.files);
    files[fileIndex] = files[fileIndex].copyWith(
      status: FileTransferStatus.failed,
    );
    _incoming = _incoming!.copyWith(files: files);
    emit(state.copyWith(
      incomingSession: _incoming,
      incomingError: 'File verification failed; requesting resend…',
    ));

    // A whole-file resend that keeps failing is not going to fix itself:
    // escalate to a session failure so both ends stop retrying forever.
    final retries = (_fileRetryCount[fileIndex] ?? 0) + 1;
    _fileRetryCount[fileIndex] = retries;
    if (retries >= 3) {
      try {
        await _transport.sendSessionFailed(
          _incomingSessionId ?? '',
          'File failed verification after repeated resends.',
        );
      } catch (_) {}
      await _failIncomingSession('File failed verification after repeated resends.');
      return;
    }
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
    _notifications.showMessage(
      title: 'Transfer complete',
      body: '${completed.files.length} file(s) saved to ${_incomingSaveDir ?? ''}',
    );
    unawaited(_foreground.stop());
    emit(state.copyWith(incomingSession: completed));
    _incoming = null;
  }

  void _pumpIncomingProgress(int fileIndex, int chunksReceived, {bool force = false}) {
  if (_incoming == null) return;
  final now = DateTime.now();
  if (!force && now.difference(_lastIncomingUiEmit) < _kUiProgressInterval) {
    return;
  }
  if (!force) _lastIncomingUiEmit = now;

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
    _incomingSessionFailedSub?.cancel();
    _notifications.dispose();
    _foreground.dispose();
    return super.close();
  }
}