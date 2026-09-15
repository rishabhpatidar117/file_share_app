import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/utils/file_categorizer.dart';
import '../../core/utils/file_opener.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_toast.dart';
import '../../core/widgets/gradient_background.dart';
import '../transfer/transfer_cubit.dart';
import '../transfer/transfer_screen.dart';
import '../transfer/session/transfer_session.dart';

class SessionDetailScreen extends StatelessWidget {
  final TransferSession session;

  const SessionDetailScreen({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isCompleted = session.isCompleted;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: Icon(
                        isDark ? Icons.arrow_back : Icons.arrow_back_ios_new,
                        color: isDark
                            ? AppColors.darkTextPrimary
                            : AppColors.textPrimary,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.isSender ? 'Sent files' : 'Received files',
                            style: AppTextStyles.heading1(isDark: isDark).copyWith(
                              fontSize: 20,
                            ),
                          ),
                          if (session.remoteDeviceName != null)
                            Text(
                              session.remoteDeviceName!,
                              style: AppTextStyles.bodySmall(isDark: isDark),
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    _StatusBadge(isCompleted: isCompleted, isDark: isDark),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  children: [
                    _SummaryCard(session: session, isDark: isDark),
                    const SizedBox(height: 16),
                    Text(
                      '${session.files.length} file(s)',
                      style: AppTextStyles.label(isDark: isDark).copyWith(
                        color: AppColors.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GlassCard(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        children: [
                          for (var i = 0; i < session.files.length; i++)
                            _FileTile(
                              file: session.files[i],
                              isDark: isDark,
                              onOpen: session.files[i].status ==
                                      FileTransferStatus.completed
                                  ? () => _openFile(context, session.files[i])
                                  : null,
                            ),
                        ],
                      ),
                    ),
                    if (!isCompleted && session.isSender) ...[
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _resume(context),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.play_circle_outline),
                          label: const Text(
                            'Resume Transfer',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openFile(BuildContext context, TransferFileManifest file) async {
    final exists = await _fileExists(file.filePath);
    if (!exists) {
      if (context.mounted) {
        GlassToast.show(context, 'File not found on this device', isError: true);
      }
      return;
    }
    if (context.mounted) {
      await FileOpener.open(context, file.filePath);
    }
  }

  Future<bool> _fileExists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  void _resume(BuildContext context) {
    context.read<TransferCubit>().resumeSession(session.id);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const TransferScreen()),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final TransferSession session;
  final bool isDark;

  const _SummaryCard({required this.session, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final total = session.totalBytes;
    final transferred = session.transferredBytes;
    final time = session.completedAt ?? session.createdAt;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: AppColors.primaryGradient,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              session.isSender
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.isSender
                      ? 'Sent to ${session.remoteDeviceName ?? "device"}'
                      : 'Received from ${session.remoteDeviceName ?? "device"}',
                  style: AppTextStyles.body(isDark: isDark),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${ByteFormatter.format(total)} • '
                  '${session.isCompleted ? ByteFormatter.format(transferred) : "${(session.progress * 100).toStringAsFixed(0)}%"}',
                  style: AppTextStyles.bodySmall(isDark: isDark),
                ),
              ],
            ),
          ),
          Text(
            _timeAgo(time),
            style: AppTextStyles.bodySmall(isDark: isDark),
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }
}

class _FileTile extends StatelessWidget {
  final TransferFileManifest file;
  final bool isDark;
  final VoidCallback? onOpen;

  const _FileTile({required this.file, required this.isDark, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final category = FileCategorizer.resolve(file.fileName);
    final icon = _iconFor(category);
    final isCompleted = file.status == FileTransferStatus.completed;

    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: AppColors.primary, size: 20),
      ),
      title: Text(
        file.fileName,
        style: AppTextStyles.body(isDark: isDark),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${ByteFormatter.format(file.fileSize)} • ${_statusLabel()}',
        style: AppTextStyles.bodySmall(isDark: isDark),
      ),
      trailing: isCompleted && onOpen != null
          ? TextButton(
              onPressed: onOpen,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: const Text('Open'),
            )
          : Icon(
              isCompleted
                  ? Icons.check_circle_outline
                  : Icons.schedule,
              size: 18,
              color: isCompleted ? AppColors.success : AppColors.textSecondary,
            ),
    );
  }

  IconData _iconFor(FileCategory category) {
    switch (category) {
      case FileCategory.videos:
        return Icons.videocam_outlined;
      case FileCategory.audio:
        return Icons.music_note_outlined;
      case FileCategory.documents:
        return Icons.description_outlined;
      case FileCategory.images:
        return Icons.image_outlined;
      case FileCategory.compressed:
        return Icons.folder_zip_outlined;
      case FileCategory.general:
        return Icons.insert_drive_file_outlined;
    }
  }

  String _statusLabel() {
    switch (file.status) {
      case FileTransferStatus.completed:
        return 'Completed';
      case FileTransferStatus.transferring:
        return 'Transferring';
      case FileTransferStatus.failed:
        return 'Failed';
      case FileTransferStatus.paused:
        return 'Paused';
      case FileTransferStatus.pending:
        return 'Pending';
    }
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isCompleted;
  final bool isDark;

  const _StatusBadge({required this.isCompleted, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: (isCompleted ? AppColors.success : AppColors.warning)
            .withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isCompleted ? 'Completed' : 'Pending',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: isCompleted ? AppColors.success : AppColors.warning,
        ),
      ),
    );
  }
}