import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'history_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_toast.dart';
import '../../core/widgets/gradient_background.dart';
import '../transfer/transfer_cubit.dart';
import '../transfer/transfer_screen.dart';
import '../transfer/session/transfer_session.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    context.read<HistoryCubit>().loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GradientBackground(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: Text('Transfer History', style: AppTextStyles.heading1(isDark: isDark)),
            ),
            Expanded(
              child: BlocBuilder<HistoryCubit, HistoryState>(
                builder: (context, state) {
                  if (state.isLoading) {
                    return const Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    );
                  }
                  if (state.sessions.isEmpty) {
                    return _buildEmpty(isDark);
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                    itemCount: state.sessions.length,
                    itemBuilder: (context, index) {
                      final session = state.sessions[index];
                      return _SessionCard(
                        session: session,
                        isDark: isDark,
                        onTap: () => _openSession(context, session),
                        onDelete: () {
                          context.read<HistoryCubit>().deleteSession(session.id);
                          GlassToast.show(context, 'Session removed');
                        },
                      ).animate().fadeIn(delay: Duration(milliseconds: 60 * index)).slideX(begin: 0.03);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.history,
            size: 64,
            color: (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary)
                .withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'No transfer history yet',
            style: AppTextStyles.body(isDark: isDark).copyWith(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Sent and received transfers will appear here.',
            style: AppTextStyles.bodySmall(isDark: isDark),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  void _openSession(BuildContext context, TransferSession session) {
    final completed = session.status == SessionStatus.completed && session.isCompleted;

    if (session.isSender && !completed) {
      context.read<TransferCubit>().resumeSession(session.id);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TransferScreen()),
      );
    } else if (!session.isSender && !completed) {
      GlassToast.show(
        context,
        'Open "Receive Files" on the home screen to resume this transfer.',
      );
    } else {
      final firstFile = session.files.isNotEmpty ? session.files.first.fileName : '';
      GlassToast.show(
        context,
        '${session.isSender ? "Sent" : "Received"} ${session.files.length} file(s)'
        '${firstFile.isNotEmpty ? ' • $firstFile' : ''}.',
      );
    }
  }
}

class _SessionCard extends StatelessWidget {
  final TransferSession session;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionCard({
    required this.session,
    required this.isDark,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isCompleted = session.isCompleted;
    final primary = _primaryLabel();
    final secondary = _secondaryLabel();

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(24),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(_statusIcon, color: _statusColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        primary,
                        style: AppTextStyles.body(isDark: isDark),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        secondary,
                        style: AppTextStyles.bodySmall(isDark: isDark),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!isCompleted)
                  IconButton(
                    onPressed: onTap,
                    tooltip: session.isSender ? 'Resume' : 'Details',
                    icon: const Icon(Icons.play_circle_outline, size: 20),
                    color: AppColors.success,
                  ),
                PopupMenuButton<String>(
                  iconColor: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                  onSelected: (_) => onDelete(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _primaryLabel() {
    final direction = session.isSender
        ? 'To ${session.remoteDeviceName ?? "device"}'
        : 'From ${session.remoteDeviceName ?? "device"}';
    final first = session.files.isNotEmpty ? session.files.first.fileName : 'Unknown';
    final extra = session.files.length > 1 ? ' +${session.files.length - 1} more' : '';
    return '$direction • $first$extra';
  }

  String _secondaryLabel() {
    final size = ByteFormatter.format(session.totalBytes);
    final status = _statusLabel();
    final time = session.completedAt ?? session.createdAt;
    return '$size • $status • ${_formatTime(time)}';
  }

  String _statusLabel() {
    if (session.isCompleted) return 'Completed';
    switch (session.status) {
      case SessionStatus.transferring:
        return 'In progress';
      case SessionStatus.paused:
        return 'Paused';
      case SessionStatus.failed:
        return 'Failed';
      case SessionStatus.completed:
        return 'Completed';
      case SessionStatus.discovering:
      case SessionStatus.connecting:
        return 'Connecting';
      case SessionStatus.created:
        return 'Created';
      case SessionStatus.resumed:
        return 'In progress';
    }
  }

  Color get _statusColor {
    if (session.isCompleted) return AppColors.success;
    if (session.hasFailed) return AppColors.error;
    if (session.status == SessionStatus.paused) return AppColors.warning;
    return AppColors.primary;
  }

  IconData get _statusIcon {
    if (session.isCompleted) return Icons.check_circle_outline;
    if (session.hasFailed) return Icons.error_outline;
    if (session.status == SessionStatus.paused) return Icons.pause_circle_outline;
    return Icons.sync;
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}