import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'discovery_cubit.dart';
import 'discovery_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/gradient_background.dart';
import '../../transport/device_info.dart';
import '../file_picker/file_picker_screen.dart';

class DiscoveryScreen extends StatefulWidget {
  final bool isSender;

  const DiscoveryScreen({super.key, this.isSender = true});

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  @override
  void initState() {
    super.initState();
    context.read<DiscoveryCubit>().startDiscovery();
  }

  @override
  void dispose() {
    context.read<DiscoveryCubit>().stopDiscovery();
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
                        context.read<DiscoveryCubit>().stopDiscovery();
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.arrow_back_ios_new),
                    ),
                    Expanded(
                      child: Text(
                        widget.isSender ? 'Select Device' : 'Waiting for Connection',
                        style: AppTextStyles.heading2(isDark: isDark),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const SizedBox(height: 8),
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
              ),
              Expanded(
                child: BlocBuilder<DiscoveryCubit, DiscoveryState>(
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
                            onTap: () {
                              context.read<DiscoveryCubit>().connectToDevice(device);
                              if (widget.isSender) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => const FilePickerScreen(),
                                  ),
                                );
                              }
                            },
                          ).animate().fadeIn(delay: Duration(milliseconds: 80 * index))
                              .slideX(begin: 0.05),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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
        ],
      ),
    );
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
