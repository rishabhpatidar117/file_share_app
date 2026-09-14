import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/gradient_background.dart';
import '../../core/widgets/glass_toast.dart';
import '../../transport/device_info.dart';
import '../../transport/qr_connect_payload.dart';

/// Lets the sender scan a QR code shown by the receiver. Returns the parsed
/// [DeviceInfo] via [Navigator.pop] when a valid SwiftShare payload is found,
/// or null if the user dismisses the screen.
///
/// Camera scanning uses the `mobile_scanner` plugin (Android/iOS/macOS/Web).
/// On desktop (Windows/Linux) the plugin has no implementation, so the screen
/// falls back to manual pasting of the connection payload.
class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  final MobileScannerController _controller =
      MobileScannerController(formats: const <BarcodeFormat>[
        BarcodeFormat.qrCode,
      ]);

  bool get _cameraSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      default:
        return false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null) return;
    final payload = QrConnectPayload.tryDecode(raw);
    if (payload == null) return;
    final device = DeviceInfo(
      id: 'qr-${payload.ip}:${payload.port}',
      name: payload.name,
      platform: DevicePlatform.unknown,
      quality: ConnectionQuality.good,
      address: payload.ip,
      port: payload.port,
    );
    _controller.stop();
    if (mounted) Navigator.of(context).pop(device);
  }

  Future<void> _submitManualCode() async {
    final controller = TextEditingController();
    final device = await showDialog<DeviceInfo>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('Enter connection code'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Paste the swiftshare:// code shown on the other device. '
              'You can also connect by IP address instead.',
              style: AppTextStyles.bodySmall(isDark: _isDark),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'swiftshare://v1/...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final payload =
                  QrConnectPayload.tryDecode(controller.text.trim());
              if (payload == null) {
                GlassToast.show(context, 'That code is not valid');
                return;
              }
              Navigator.pop(
                context,
                DeviceInfo(
                  id: 'qr-${payload.ip}:${payload.port}',
                  name: payload.name,
                  platform: DevicePlatform.unknown,
                  quality: ConnectionQuality.good,
                  address: payload.ip,
                  port: payload.port,
                ),
              );
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (device != null && mounted) Navigator.of(context).pop(device);
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_ios_new),
                    ),
                    Expanded(
                      child: Text(
                        'Scan QR Code',
                        style: AppTextStyles.heading2(isDark: _isDark),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Expanded(
                child: _cameraSupported
                    ? _buildCameraScanner()
                    : _buildDesktopFallback(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraScanner() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                placeholderBuilder: (context) => Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: const CircularProgressIndicator(
                    color: Colors.white,
                  ),
                ),
                errorBuilder: (context, error) => Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Camera unavailable',
                    style: AppTextStyles.body(isDark: false)
                        .copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Text(
            'Point the camera at the QR code shown on the receiving device.',
            style: AppTextStyles.bodySmall(isDark: _isDark),
            textAlign: TextAlign.center,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: TextButton.icon(
            onPressed: _submitManualCode,
            icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
            label: const Text('Enter code manually'),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopFallback() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.no_photography_outlined,
              size: 64,
              color: (AppColors.primary).withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              'Camera scanning is not supported on this device',
              style: AppTextStyles.body(isDark: _isDark),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Use the code entry below, or connect by IP address from the '
              'previous screen.',
              style: AppTextStyles.bodySmall(isDark: _isDark),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _submitManualCode,
              icon: const Icon(Icons.keyboard_alt_outlined),
              label: const Text('Enter code manually'),
            ),
          ],
        ),
      ),
    );
  }
}