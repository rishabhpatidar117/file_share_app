import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'discovery_cubit.dart';
import 'discovery_state.dart';
import 'qr_scanner_screen.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/utils/network_info.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_toast.dart';
import '../../core/widgets/gradient_background.dart';
import '../../transport/device_info.dart';
import '../../transport/qr_connect_payload.dart';
import '../../transport/transport_channel.dart' show kSwiftShareServicePort;
import '../settings/settings_cubit.dart';
import '../transfer/transfer_cubit.dart';
import '../transfer/transfer_state.dart';
import '../transfer/session/transfer_session.dart';
import '../file_picker/file_picker_screen.dart';

class DiscoveryScreen extends StatefulWidget {
  final bool isSender;

  const DiscoveryScreen({super.key, this.isSender = true});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  late final DiscoveryCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = context.read<DiscoveryCubit>();
    if (widget.isSender) {
      _cubit.startDiscovery();
    } else {
      _cubit.startReceive();
    }
  }

  @override
  void dispose() {
    if (widget.isSender) {
      _cubit.stopDiscovery();
    } else {
      _cubit.stopListening();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
                      onPressed: () {
                        if (widget.isSender) {
                          _cubit.stopDiscovery();
                        } else {
                          _cubit.stopListening();
                        }
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.arrow_back_ios_new),
                    ),
                    Expanded(
                      child: Text(
                        widget.isSender ? 'Select Device' : 'Receive Files',
                        style: AppTextStyles.heading2(isDark: isDark),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (widget.isSender) ...[
                      IconButton(
                        onPressed: _promptScanQrCode,
                        icon: const Icon(Icons.qr_code_scanner),
                        tooltip: 'Scan QR code to connect',
                      ),
                      IconButton(
                        onPressed: _promptManualConnection,
                        icon: const Icon(Icons.link),
                        tooltip: 'Connect by IP address',
                      ),
                    ] else
                      const SizedBox(width: 48),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (widget.isSender)
                BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  builder: (context, state) {
                    if (state.status == DiscoveryStatus.searching) {
                      return _buildSearchingIndicator(isDark);
                    }
                    if (state.status == DiscoveryStatus.connecting) {
                      return _buildConnectingIndicator(state.selectedDevice, isDark);
                    }
                    if (state.status == DiscoveryStatus.error) {
                      return _buildErrorState(state.errorMessage, isDark);
                    }
                    return const SizedBox.shrink();
                  },
                )
              else
                BlocBuilder<DiscoveryCubit, DiscoveryState>(
                  builder: (context, state) {
                    if (state.status == DiscoveryStatus.error) {
                      return _buildErrorState(state.errorMessage, isDark);
                    }
                    return _buildListeningIndicator(isDark);
                  },
                ),
              Expanded(
                child: widget.isSender
                    ? _buildDeviceList(isDark)
                    : _buildReceiveMode(isDark),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _promptManualConnection() async {
    final ipController = TextEditingController();
    final portController = TextEditingController(text: '48732');

    final result = await showDialog<DeviceInfo>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: const Text('Connect by IP address'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ipController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'IP address',
                hintText: 'e.g. 192.168.1.20',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: portController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
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
              final ip = ipController.text.trim();
              final port = int.tryParse(portController.text.trim());
              if (ip.isEmpty || port == null || port <= 0 || port > 65535) {
                GlassToast.show(context, 'Enter a valid IP address and port');
                return;
              }
              Navigator.pop(
                context,
                DeviceInfo(
                  id: 'manual-$ip:$port',
                  name: 'Manual ($ip)',
                  platform: DevicePlatform.unknown,
                  quality: ConnectionQuality.good,
                  address: ip,
                  port: port,
                ),
              );
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );

    if (result == null || !mounted) return;
    final connected = await _cubit.connectToDevice(result);
    if (!mounted) return;
    if (!connected) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FilePickerScreen()),
    );
  }

  Future<void> _promptScanQrCode() async {
    final result = await Navigator.push<DeviceInfo>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (result == null || !mounted) return;
    final connected = await _cubit.connectToDevice(result);
    if (!mounted) return;
    if (!connected) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FilePickerScreen()),
    );
  }

  Widget _buildDeviceList(bool isDark) {
    return BlocBuilder<DiscoveryCubit, DiscoveryState>(
      builder: (context, state) {
        if (state.devices.isEmpty) {
          return _buildEmptyState(isDark);
        }
        return ListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: state.devices.length,
          itemBuilder: (context, index) {
            final device = state.devices[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _DeviceCard(
                device: device,
                isDark: isDark,
                onTap: () async {
                  final connected = await _cubit.connectToDevice(device);
                  if (!mounted || !connected) return;
                  Navigator.push(
                    this.context,
                    MaterialPageRoute(
                      builder: (_) => const FilePickerScreen(),
                    ),
                  );
                },
              ).animate().fadeIn(delay: Duration(milliseconds: 80 * index))
                  .slideX(begin: 0.05),
            );
          },
        );
      },
    );
  }

  Widget _buildReceiveMode(bool isDark) {
    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        final incoming = state.incomingSession;

        if (incoming == null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.swap_vert_circle_outlined,
                    color: AppColors.success,
                    size: 44,
                  ),
                )
                    .animate(onPlay: (c) => c.repeat())
                    .shimmer(duration: 1800.ms),
                const SizedBox(height: 20),
                Text(
                  'Waiting for incoming files…',
                  style: AppTextStyles.heading3(isDark: isDark),
                ),
                const SizedBox(height: 8),
                Text(
                  'The sender will see this device appear automatically.',
                  style: AppTextStyles.bodySmall(isDark: isDark),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: _MyInfoPanel(compact: true),
                ),
              ],
            ),
          );
        }

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: GlassCard(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.download_rounded,
                          color: AppColors.primary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Receiving from ${incoming.remoteDeviceName ?? "peer"}',
                              style: AppTextStyles.body(isDark: isDark),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${incoming.files.length} file(s) • '
                              '${ByteFormatter.format(incoming.totalBytes)}'
                              '${state.incomingError != null ? ' • ${state.incomingError!}' : ''}',
                              style: AppTextStyles.bodySmall(isDark: isDark),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                child: Text('Files', style: AppTextStyles.heading3(isDark: isDark)),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final file = incoming.files[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _IncomingFileCard(file: file, isDark: isDark),
                    );
                  },
                  childCount: incoming.files.length,
                ),
              ),
            ),
            if (incoming.status == SessionStatus.completed)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: ElevatedButton.icon(
                    onPressed: () {
                      GlassToast.show(
                        context,
                        'Saved to ${state.saveDirectory ?? "Downloads"}',
                      );
                    },
                    icon: const Icon(Icons.folder_open, size: 20),
                    label: const Text('View save location'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.success,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildListeningIndicator(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: AppColors.success,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Listening for incoming transfers…',
                style: AppTextStyles.body(isDark: isDark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchingIndicator(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 14),
            Text(
              'Scanning for nearby devices...',
              style: AppTextStyles.body(isDark: isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectingIndicator(DeviceInfo? device, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 14),
            Text(
              'Connecting to ${device?.name ?? "device"}...',
              style: AppTextStyles.body(isDark: isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState(String? message, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.error, size: 20),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                message ?? 'An error occurred',
                style: AppTextStyles.body(isDark: isDark).copyWith(color: AppColors.error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        children: [
          Icon(
            Icons.devices_other,
            size: 64,
            color: (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary)
                .withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No devices found nearby',
            style: AppTextStyles.body(isDark: isDark).copyWith(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Make sure SwiftShare is open on the other device',
            style: AppTextStyles.bodySmall(isDark: isDark),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _promptManualConnection,
            icon: const Icon(Icons.link, size: 18),
            label: const Text('Connect by IP address'),
          ),
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: _promptScanQrCode,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Scan QR code'),
          ),
          const SizedBox(height: 16),
          const _MyInfoPanel(compact: true),
        ],
      ),
    );
  }
}

class _IncomingFileCard extends StatelessWidget {
  final TransferFileManifest file;
  final bool isDark;

  const _IncomingFileCard({required this.file, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final color = _color;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      file.fileName,
                      style: AppTextStyles.body(isDark: isDark),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${ByteFormatter.format(file.fileSize)} • $_label',
                      style: AppTextStyles.bodySmall(isDark: isDark),
                    ),
                  ],
                ),
              ),
              if (file.status == FileTransferStatus.completed)
                const Icon(Icons.check_circle, color: AppColors.success, size: 20),
            ],
          ),
          if (file.status == FileTransferStatus.transferring ||
              file.status == FileTransferStatus.paused)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: file.progress,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                  minHeight: 4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Color get _color {
    switch (file.status) {
      case FileTransferStatus.completed:
        return AppColors.success;
      case FileTransferStatus.failed:
        return AppColors.error;
      case FileTransferStatus.transferring:
        return AppColors.primary;
      case FileTransferStatus.paused:
        return AppColors.warning;
      case FileTransferStatus.pending:
        return Colors.grey;
    }
  }

  IconData get _icon {
    switch (file.status) {
      case FileTransferStatus.completed:
        return Icons.check_circle_outline;
      case FileTransferStatus.failed:
        return Icons.error_outline;
      case FileTransferStatus.transferring:
        return Icons.sync;
      case FileTransferStatus.paused:
        return Icons.pause_circle_outline;
      case FileTransferStatus.pending:
        return Icons.schedule;
    }
  }

  String get _label {
    switch (file.status) {
      case FileTransferStatus.completed:
        return 'Saved';
      case FileTransferStatus.failed:
        return 'Failed - resending';
      case FileTransferStatus.transferring:
        return '${(file.progress * 100).toInt()}%';
      case FileTransferStatus.paused:
        return 'Paused';
      case FileTransferStatus.pending:
        return 'Waiting';
    }
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceInfo device;
  final bool isDark;
  final VoidCallback onTap;

  const _DeviceCard({
    required this.device,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  _platformIcon(device.platform),
                  color: AppColors.primary,
                  size: 26,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: AppTextStyles.heading3(isDark: isDark),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device.platform.displayName,
                      style: AppTextStyles.bodySmall(isDark: isDark),
                    ),
                  ],
                ),
              ),
              _QualityIndicator(quality: device.quality),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_ios,
                size: 14,
                color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _platformIcon(DevicePlatform platform) {
    switch (platform) {
      case DevicePlatform.android:
        return Icons.android;
      case DevicePlatform.windows:
        return Icons.desktop_windows;
      case DevicePlatform.web:
        return Icons.language;
      case DevicePlatform.unknown:
        return Icons.device_unknown;
    }
  }
}

class _QualityIndicator extends StatelessWidget {
  final ConnectionQuality quality;

  const _QualityIndicator({required this.quality});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (quality) {
      case ConnectionQuality.excellent:
        color = AppColors.success;
        break;
      case ConnectionQuality.good:
        color = AppColors.success.withValues(alpha: 0.7);
        break;
      case ConnectionQuality.fair:
        color = AppColors.warning;
        break;
      case ConnectionQuality.poor:
        color = AppColors.error;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final barHeight = 8.0 + i * 3;
        final isActive = i <= quality.index;
        return Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Container(
            width: 3,
            height: barHeight,
            decoration: BoxDecoration(
              color: isActive ? color : color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        );
      }),
    );
  }
}

/// Displays this device's IPv4 addresses (copyable) and, when in receive mode,
/// a QR code the sender can scan.
class _MyInfoPanel extends StatefulWidget {
  final bool compact;
  const _MyInfoPanel({this.compact = false});

  @override
  State<_MyInfoPanel> createState() => _MyInfoPanelState();
}

class _MyInfoPanelState extends State<_MyInfoPanel> {
  late final Future<List<String>> _ipFuture;

  @override
  void initState() {
    super.initState();
    _ipFuture = getLocalIPv4Addresses();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) GlassToast.show(context, 'Copied $text');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final deviceName =
        context.select<SettingsCubit, String>((c) => c.state.deviceName);

    return GlassCard(
      padding: EdgeInsets.all(widget.compact ? 14 : 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'This device',
            style: AppTextStyles.bodySmall(isDark: isDark),
          ),
          Text(
            deviceName,
            style: AppTextStyles.body(isDark: isDark),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<String>>(
            future: _ipFuture,
            builder: (context, snapshot) {
              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                return Text(
                  'No local IP available',
                  style: AppTextStyles.bodySmall(isDark: isDark),
                );
              }
              final ips = snapshot.data!;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final ip in ips)
                    InkWell(
                      onTap: () => _copy(ip),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color:
                              AppColors.primary.withValues(alpha: isDark ? 0.18 : 0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.copy, size: 14, color: AppColors.primary),
                            const SizedBox(width: 4),
                            Text(
                              '$ip : $kSwiftShareServicePort',
                              style: AppTextStyles.bodySmall(isDark: isDark)
                                  .copyWith(color: AppColors.primary),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (!widget.compact) ...[
            const SizedBox(height: 12),
            FutureBuilder<List<String>>(
              future: _ipFuture,
              builder: (context, snapshot) {
                final ips = snapshot.data ?? const <String>[];
                if (ips.isEmpty) return const SizedBox.shrink();
                final payload = QrConnectPayload(
                  name: deviceName,
                  ip: ips.first,
                  port: kSwiftShareServicePort,
                ).encode();
                return Container(
                  width: 136,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 12,
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: payload,
                    version: QrVersions.auto,
                    size: 116,
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}