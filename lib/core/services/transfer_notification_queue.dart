import 'dart:async';
import 'notification_service.dart';

/// Coalescing, throttled, best-effort notification writer for transfers.
///
/// The transfer engine enqueues progress/status updates here and NEVER awaits
/// them. Internally the queue keeps only the latest pending update (so it can
/// never grow unboundedly) and posts at most [maxUpdatesPerSecond] progress
/// notifications per second. Terminal messages (complete / failed / cancelled /
/// connection lost) are posted immediately without throttling.
///
/// Notification failures are swallowed on purpose: a failed notification must
/// never fail (or pause) a file transfer.
class TransferNotificationQueue {
  final NotificationService _service;

  /// Upper bound for progress notifications per second.
  static const int maxUpdatesPerSecond = 6;

  static const Duration _minInterval =
      Duration(milliseconds: 1000 ~/ maxUpdatesPerSecond);

  String? _pendingTitle;
  String? _pendingBody;
  double? _pendingProgress;

  Timer? _timer;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  TransferNotificationQueue(this._service);

  /// Enqueue a progress update. Never blocks; never throws.
  void showProgress({
    required String title,
    required String body,
    required double progress,
  }) {
    if (_disposed) return;
    _pendingTitle = title;
    _pendingBody = body;
    _pendingProgress = progress.clamp(0.0, 1.0);
    _scheduleFlush(delayed: true);
  }

  /// Enqueue a terminal/status message (complete, failed, paused, connection
  /// lost, incoming). These bypass the rate limiter so the final 100% /
  /// error / cancelled states are always delivered promptly.
  void showMessage({required String title, required String body}) {
    if (_disposed) return;
    _pendingTitle = title;
    _pendingBody = body;
    _pendingProgress = null;
    _scheduleFlush(delayed: false);
  }

  /// Cancel any pending progress notification. Safe to call at any time.
  void cancelTransferNotification() {
    _timer?.cancel();
    _timer = null;
    _pendingTitle = null;
    _pendingBody = null;
    _pendingProgress = null;
    _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
    unawaited(_service.cancelTransferNotification());
  }

  void _scheduleFlush({required bool delayed}) {
    _timer?.cancel();
    if (delayed) {
      final wait = _minInterval - DateTime.now().difference(_lastSent);
      if (wait <= Duration.zero) {
        _flushNow();
        return;
      }
      _timer = Timer(wait, _flushNow);
      return;
    }
    _flushNow();
  }

  void _flushNow() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return;
    final title = _pendingTitle;
    if (title == null) return;
    final body = _pendingBody ?? '';
    final progress = _pendingProgress;
    _pendingTitle = null;
    _pendingBody = null;
    _pendingProgress = null;
    _lastSent = DateTime.now();
    try {
      if (progress == null) {
        unawaited(_service.showTransferMessage(title: title, body: body));
      } else {
        unawaited(
          _service.showTransferProgress(
            title: title,
            body: body,
            progress: progress,
          ),
        );
      }
    } catch (_) {
      // A notification failure must never propagate to the transfer engine.
    }
  }

  /// Permanently stops the queue (call from the owning cubit's close()).
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _disposed = true;
    _pendingTitle = null;
    _pendingBody = null;
    _pendingProgress = null;
  }
}