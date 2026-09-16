import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'transfer_cubit.dart';
import 'transfer_state.dart';
import 'session/transfer_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_toast.dart';
import '../../core/widgets/gradient_background.dart';
import '../../core/widgets/progress_ring.dart';

class TransferScreen extends StatelessWidget {
  const TransferScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: BlocListener<TransferCubit, TransferState>(
        listener: (context, state) {
          if (state.status == TransferStatus.completed) {
            GlassToast.show(context, 'Transfer completed successfully!');
          } else if (state.status == TransferStatus.failed) {
            GlassToast.show(context, state.errorMessage ?? 'Transfer failed', isError: true);
          }
        },
        child: GradientBackground(
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () {
                          context.read<TransferCubit>().cancelTransfer();
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.arrow_back_ios_new),
                      ),
                      Expanded(
                        child: Text(
                          'Transfer',
                          style: AppTextStyles.heading2(isDark: isDark),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                Expanded(
                  child: BlocBuilder<TransferCubit, TransferState>(
                    builder: (context, state) {
                      if (state.status == TransferStatus.idle &&
                          state.incomingSession == null) {
                        return _buildIdleState(isDark);
                      }
                      return _buildTransferContent(context, state, isDark);
                    },
                  ),
                ),
                BlocBuilder<TransferCubit, TransferState>(
                  builder: (context, state) => _buildControls(context, state),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIdleState(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.send_rounded,
            size: 64,
            color: AppColors.primary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No active transfer',
            style: AppTextStyles.heading3(isDark: isDark),
          ),
        ],
      ),
    );
  }

  Widget _buildTransferContent(BuildContext context, TransferState state, bool isDark) {
    // Receiving: the incoming session owns the realtime progress.  Sending:
    // the outgoing session does.  If both are active (we sent a file while
    // also receiving) the outgoing session wins, matching the network layer.
    final isReceiver = state.status == TransferStatus.idle &&
        state.incomingSession != null;
    final session =
        isReceiver ? state.incomingSession : state.session;
    if (session == null) return const SizedBox.shrink();
    final progress =
        isReceiver ? state.incomingProgress : state.overallProgress;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: GlassCard(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  ProgressRing(
                    progress: progress,
                    size: 100,
                    strokeWidth: 8,
                    child: Text(
                      '${(progress * 100).toInt()}%',
                      style: AppTextStyles.heading2(isDark: isDark),
                    ),
                  ).animate().scale(),
                  const SizedBox(height: 16),
                  Text(
                    isReceiver && state.incomingSession?.status ==
                            SessionStatus.completed
                        ? 'Completed'
                        : isReceiver
                            ? 'Receiving...'
                            : state.status == TransferStatus.transferring
                                ? 'Transferring...'
                                : state.status == TransferStatus.paused
                                    ? 'Paused'
                                    : state.status == TransferStatus.completed
                                        ? 'Completed'
                                        : 'Preparing...',
                    style: AppTextStyles.body(isDark: isDark),
                  ),
                  if (state.speed > 0) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${ByteFormatter.formatSpeed(state.speed.round())} • ${state.activeChannel ?? "Wi-Fi"}',
                      style: AppTextStyles.bodySmall(isDark: isDark),
                    ),
                  ],
                  if (state.networkInfo != null &&
                      state.networkInfo!.summaryLabel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      state.networkInfo!.summaryLabel,
                      style: AppTextStyles.bodySmall(
                        isDark: isDark,
                      ).copyWith(fontSize: 11),
                    ),
                  ],
                  if (state.transportLabel != null &&
                      state.transportLabel!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      state.transportLabel!,
                      style: AppTextStyles.bodySmall(
                        isDark: isDark,
                      ).copyWith(fontSize: 10),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    '${ByteFormatter.format(session.transferredBytes)} / ${ByteFormatter.format(session.totalBytes)}',
                    style: AppTextStyles.label(isDark: isDark),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Files', style: AppTextStyles.heading3(isDark: isDark)),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final file = session.files[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _FileProgressCard(file: file, isDark: isDark)
                      .animate()
                      .fadeIn(delay: Duration(milliseconds: 60 * index)),
                );
              },
              childCount: session.files.length,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls(BuildContext context, TransferState state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: EdgeInsets.fromLTRB(
        24, 12, 24,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.darkBackground.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.9),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (state.status == TransferStatus.transferring) ...[
            _ControlButton(
              icon: Icons.pause,
              label: 'Pause',
              color: AppColors.warning,
              onTap: () => context.read<TransferCubit>().pauseTransfer(),
            ),
            const SizedBox(width: 24),
            _ControlButton(
              icon: Icons.cancel,
              label: 'Cancel',
              color: AppColors.error,
              onTap: () {
                context.read<TransferCubit>().cancelTransfer();
                Navigator.pop(context);
              },
            ),
          ] else if (state.status == TransferStatus.paused) ...[
            _ControlButton(
              icon: Icons.play_arrow,
              label: 'Resume',
              color: AppColors.success,
              onTap: () => context.read<TransferCubit>().resumeTransfer(),
            ),
            const SizedBox(width: 24),
            _ControlButton(
              icon: Icons.cancel,
              label: 'Cancel',
              color: AppColors.error,
              onTap: () {
                context.read<TransferCubit>().cancelTransfer();
                Navigator.pop(context);
              },
            ),
          ] else if (state.status == TransferStatus.completed) ...[
            _ControlButton(
              icon: Icons.check_circle,
              label: 'Done',
              color: AppColors.success,
              onTap: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
            ),
          ] else if (state.incomingSession != null &&
              state.incomingSession!.status == SessionStatus.completed) ...[
            _ControlButton(
              icon: Icons.check_circle,
              label: 'Done',
              color: AppColors.success,
              onTap: () => Navigator.pop(context),
            ),
          ] else if (state.incomingSession != null) ...[
            _ControlButton(
              icon: Icons.download_done,
              label: 'Receiving',
              color: AppColors.primary,
              onTap: () => Navigator.pop(context),
            ),
          ],
        ],
      ),
    );
  }
}

class _FileProgressCard extends StatelessWidget {
  final TransferFileManifest file;
  final bool isDark;

  const _FileProgressCard({required this.file, required this.isDark});

  @override
  Widget build(BuildContext context) {
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
                  color: _statusColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_statusIcon, color: _statusColor, size: 18),
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
                      '${ByteFormatter.format(file.fileSize)} • $_statusText',
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
              file.status == FileTransferStatus.paused) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: file.progress,
                backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                valueColor: AlwaysStoppedAnimation<Color>(_statusColor),
                minHeight: 4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color get _statusColor {
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

  IconData get _statusIcon {
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

  String get _statusText {
    switch (file.status) {
      case FileTransferStatus.completed:
        return 'Done';
      case FileTransferStatus.failed:
        return 'Failed';
      case FileTransferStatus.transferring:
        return '${(file.progress * 100).toInt()}%';
      case FileTransferStatus.paused:
        return 'Paused';
      case FileTransferStatus.pending:
        return 'Waiting';
    }
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}