import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/core/services/notification_service.dart';
import 'package:swiftshare/core/services/transfer_notification_queue.dart';

/// Records calls without ever touching a platform channel so the queue can be
/// tested in pure Dart.
class _RecordingNotificationService extends NotificationService {
  final List<double> progressCalls = [];
  final List<String> messageTitles = [];
  int cancelCalls = 0;

  @override
  Future<void> showTransferProgress({
    required String title,
    required String body,
    required double progress,
  }) async {
    progressCalls.add(progress);
  }

  @override
  Future<void> showTransferMessage({
    required String title,
    required String body,
  }) async {
    messageTitles.add(title);
  }

  @override
  Future<void> cancelTransferNotification() async {
    cancelCalls++;
  }
}

void main() {
  test('coalesces rapid progress updates into a bounded number of posts', () async {
    final service = _RecordingNotificationService();
    final queue = TransferNotificationQueue(service);
    addTearDown(queue.dispose);

    for (var i = 0; i <= 20; i++) {
      queue.showProgress(
        title: 'SwiftShare',
        body: 'progress update $i',
        progress: i / 20,
      );
    }
    await Future.delayed(const Duration(milliseconds: 400));

    // First update posts immediately; everything else coalesces into at most
    // one throttled follow-up carrying the latest value.
    expect(service.progressCalls.length, lessThanOrEqualTo(2));
    expect(service.progressCalls.last, closeTo(1.0, 0.001));
  });

  test('terminal messages bypass the throttle and post immediately', () async {
    final service = _RecordingNotificationService();
    final queue = TransferNotificationQueue(service);
    addTearDown(queue.dispose);

    // Seed the rate-limit window: the first update posts immediately.
    queue.showProgress(title: 't', body: 'working', progress: 0.42);
    // A follow-up is scheduled (throttled)...
    queue.showProgress(title: 't', body: 'still working', progress: 0.9);
    // ...but the terminal message supersedes it and posts right away.
    queue.showMessage(title: 'Transfer complete', body: 'done');

    await Future.delayed(Duration.zero);
    expect(service.messageTitles, ['Transfer complete']);
    // The throttled progress update was cancelled by the terminal message.
    await Future.delayed(const Duration(milliseconds: 400));
    expect(service.progressCalls, [0.42]);
  });

  test('cancel clears any pending progress and cancels on the service', () async {
    final service = _RecordingNotificationService();
    final queue = TransferNotificationQueue(service);
    addTearDown(queue.dispose);

    queue.showProgress(title: 't', body: 'working', progress: 0.7);
    // Deferred (rate-limited) update pending...
    queue.showProgress(title: 't', body: 'nearly done', progress: 0.99);
    queue.cancelTransferNotification();
    await Future.delayed(const Duration(milliseconds: 300));

    // Only the first immediate post survives; the pending update was dropped.
    expect(service.progressCalls, [0.7]);
    expect(service.cancelCalls, 1);
  });

  test('single updates are delivered at capped frequency', () async {
    final service = _RecordingNotificationService();
    final queue = TransferNotificationQueue(service);
    addTearDown(queue.dispose);

    queue.showProgress(title: 't', body: 'a', progress: 0.1);
    await Future.delayed(const Duration(milliseconds: 400));
    queue.showProgress(title: 't', body: 'b', progress: 0.9);
    await Future.delayed(const Duration(milliseconds: 400));

    expect(service.progressCalls, [0.1, 0.9]);
  });

  test('posts after dispose are safely ignored', () async {
    final service = _RecordingNotificationService();
    final queue = TransferNotificationQueue(service);
    queue.dispose();

    queue.showProgress(title: 't', body: 'x', progress: 1.0);
    queue.showMessage(title: 'm', body: 'y');
    await Future.delayed(const Duration(milliseconds: 50));

    expect(service.progressCalls, isEmpty);
    expect(service.messageTitles, isEmpty);
  });
}