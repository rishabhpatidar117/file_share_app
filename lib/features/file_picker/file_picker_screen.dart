import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'file_picker_cubit.dart';
import 'file_picker_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/gradient_background.dart';
import '../transfer/transfer_cubit.dart';
import '../transfer/transfer_screen.dart';

class FilePickerScreen extends StatefulWidget {
  /// Existing file paths to preload, e.g. files captured from the system share
  /// sheet. When provided the send flow starts with these files selected.
  final List<String> initialPaths;

  const FilePickerScreen({super.key, this.initialPaths = const []});

  @override
  State<FilePickerScreen> createState() => _FilePickerScreenState();
}

class _FilePickerScreenState extends State<FilePickerScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.initialPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cubit = context.read<FilePickerCubit>();
        cubit.pickFilesFromPath(widget.initialPaths);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BlocProvider(
      create: (_) => FilePickerCubit(context.read<TransferCubit>()),
      child: Scaffold(
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
                          'Select Files',
                          style: AppTextStyles.heading2(isDark: isDark),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(width: 48),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                BlocBuilder<FilePickerCubit, FilePickerState>(
                  builder: (context, state) {
                    if (state.totalSize > 0) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: GlassCard(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.folder_open, color: AppColors.primary, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                '${state.files.length} file(s) • ${ByteFormatter.format(state.totalSize)}',
                                style: AppTextStyles.body(isDark: isDark),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                Expanded(
                  child: BlocBuilder<FilePickerCubit, FilePickerState>(
                    builder: (context, state) {
                      if (state.files.isEmpty) {
                        return _buildEmptyPicker(context, state, isDark);
                      }
                      return _buildFileList(context, state, isDark);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: BlocBuilder<FilePickerCubit, FilePickerState>(
          builder: (context, state) {
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
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: state.files.isEmpty
                      ? null
                      : () {
                          context.read<FilePickerCubit>().startTransfer();
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const TransferScreen(),
                            ),
                          );
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.3),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    'Start Transfer',
                    style: AppTextStyles.buttonText().copyWith(fontSize: 16),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmptyPicker(BuildContext context, FilePickerState state, bool isDark) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.add_photo_alternate_outlined,
              size: 44,
              color: AppColors.primary,
            ),
          ).animate().scale(),
          const SizedBox(height: 24),
          Text(
            'Tap to select files',
            style: AppTextStyles.heading3(isDark: isDark),
          ),
          const SizedBox(height: 8),
          Text(
            'Choose any files to share',
            style: AppTextStyles.bodySmall(isDark: isDark),
          ),
          const SizedBox(height: 32),
          ElevatedButton.icon(
            onPressed: () => context.read<FilePickerCubit>().pickFiles(),
            icon: const Icon(Icons.folder_open, size: 20),
            label: const Text('Browse Files'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ).animate().fadeIn(delay: 200.ms),
          if (state.status == FilePickerStatus.error && state.errorMessage != null) ...[
            const SizedBox(height: 16),
            Text(
              state.errorMessage!,
              style: TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFileList(BuildContext context, FilePickerState state, bool isDark) {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
            itemCount: state.files.length,
            itemBuilder: (context, index) {
              final file = state.files[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: GlassCard(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _fileIcon(file.name),
                          color: AppColors.primary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              file.name,
                              style: AppTextStyles.body(isDark: isDark),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              ByteFormatter.format(file.size),
                              style: AppTextStyles.bodySmall(isDark: isDark),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => context.read<FilePickerCubit>().removeFile(index),
                        icon: const Icon(Icons.close, size: 18),
                        color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                      ),
                    ],
                  ),
                ).animate().fadeIn(delay: Duration(milliseconds: 60 * index)).slideX(begin: 0.03),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          child: TextButton.icon(
            onPressed: () => context.read<FilePickerCubit>().pickFiles(),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add more files'),
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          ),
        ),
      ],
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
        return Icons.image_outlined;
      case 'mp4':
      case 'mov':
      case 'avi':
      case 'mkv':
        return Icons.video_file_outlined;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
        return Icons.audio_file_outlined;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip_outlined;
      case 'doc':
      case 'docx':
        return Icons.description_outlined;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}