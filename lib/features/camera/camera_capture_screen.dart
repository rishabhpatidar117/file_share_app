import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/gradient_background.dart';
import '../../core/widgets/glass_toast.dart';

/// A full-screen camera preview that supports photo capture and video
/// recording.  Returns the [XFile] path of the captured media via
/// [Navigator.pop] or null if the user cancels.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? _controller;
  bool _initialising = true;
  String? _error;
  bool _isRecording = false;
  bool _isBusy = false;

  bool get _isDesktop {
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return true;
      default:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _error = 'No camera found';
          _initialising = false;
        });
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      _controller = CameraController(
        camera,
        _isDesktop ? ResolutionPreset.high : ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();
      if (mounted) setState(() => _initialising = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not initialise camera: $e';
          _initialising = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _takePicture() async {
    if (_controller == null || !_controller!.value.isInitialized || _isBusy) return;
    setState(() => _isBusy = true);
    try {
      final file = await _controller!.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(<String>[file.path]);
    } catch (e) {
      if (mounted) GlassToast.show(context, 'Capture failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _toggleRecording() async {
    if (_controller == null || !_controller!.value.isInitialized || _isBusy) return;
    setState(() => _isBusy = true);
    try {
      if (_isRecording) {
        final file = await _controller!.stopVideoRecording();
        if (!mounted) return;
        setState(() => _isRecording = false);
        Navigator.of(context).pop(<String>[file.path]);
      } else {
        await _controller!.startVideoRecording();
        if (mounted) setState(() => _isRecording = true);
      }
    } catch (e) {
      if (mounted) GlassToast.show(context, 'Recording failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(child: _buildBody()),
              _buildControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
          ),
          const Expanded(
            child: Text(
              'Camera',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_initialising) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_off_outlined,
                size: 64,
                color: Colors.white.withValues(alpha: 0.4),
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: AppTextStyles.body(isDark: true).copyWith(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final controller = _controller!;
    Widget preview = CameraPreview(controller);
    // camera_desktop on Windows doesn't mirror, flip for selfie-like UX.
    if (_isDesktop) {
      preview = Transform(
        alignment: Alignment.center,
        transform: Matrix4.diagonal3Values(-1, 1, 1),
        child: preview,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(0),
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: preview,
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        MediaQuery.of(context).padding.bottom + 16,
      ),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Photo button
          _CaptureButton(
            icon: Icons.camera_alt,
            label: 'Photo',
            isActive: !_isRecording,
            onTap: _isRecording ? null : _takePicture,
            isBusy: _isBusy && !_isRecording,
          ),
          // Record button
          _CaptureButton(
            icon: _isRecording ? Icons.stop : Icons.videocam,
            label: _isRecording ? 'Stop' : 'Video',
            isActive: true,
            isRecording: _isRecording,
            onTap: _toggleRecording,
            isBusy: _isBusy,
          ),
        ],
      ),
    );
  }
}

class _CaptureButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback? onTap;
  final bool isBusy;
  final bool isRecording;

  const _CaptureButton({
    required this.icon,
    required this.label,
    required this.isActive,
    this.onTap,
    this.isBusy = false,
    this.isRecording = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isActive ? onTap : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isRecording
                  ? Colors.red
                  : isActive
                      ? AppColors.primary
                      : Colors.grey.withValues(alpha: 0.3),
            ),
            child: isBusy
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2.5,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.grey,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
