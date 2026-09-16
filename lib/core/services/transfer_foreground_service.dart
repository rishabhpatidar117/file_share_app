import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Best-effort Android foreground service lifecycle. Calling [start] while
/// already active is a harmless no-op; calling [stop] when not started is
/// equally harmless. Every platform call is wrapped in a silent catch so the
/// transfer engine never blocks or crashes on this layer.
class TransferForegroundService {
  static const MethodChannel _channel =
      MethodChannel('swiftshare/transfer_lifecycle');

  bool _active = false;

  Future<void> start() async {
    if (kIsWeb || !Platform.isAndroid || _active) return;
    _active = true;
    try {
      await _channel.invokeMethod('startTransfer');
    } catch (_) {
      _active = false;
    }
  }

  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    try {
      await _channel.invokeMethod('stopTransfer');
    } catch (_) {}
  }

  void dispose() {
    if (_active) stop();
  }
}