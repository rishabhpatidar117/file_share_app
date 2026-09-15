import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'settings_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_toast.dart';
import '../../core/widgets/gradient_background.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const List<int> _chunkSizeOptions = [
    5, 20, 50, 100, 200, 512, 700, 1024, 1228, 1536, 2048, 3072,
    5120, 10240, 15360, 20480, 30720,
  ];

  static String _formatChunkSize(int kb) {
    if (kb >= 1024 && kb % 1024 == 0) return '${kb ~/ 1024} MB';
    if (kb > 1024) return '${(kb / 1024).toStringAsFixed(1)} MB';
    return '$kb KB';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (Navigator.canPop(context)) ...[
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.arrow_back_ios_new),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      'Settings',
                      style: AppTextStyles.heading1(isDark: isDark),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _buildSection('Appearance', isDark, [
                  BlocBuilder<SettingsCubit, SettingsState>(
                    builder: (context, state) {
                      return _SettingsTile(
                        icon: Icons.dark_mode_outlined,
                        title: 'Dark Mode',
                        trailing: Switch(
                          value: state.isDarkMode,
                          onChanged: (_) =>
                              context.read<SettingsCubit>().toggleDarkMode(),
                          activeThumbColor: AppColors.primary,
                        ),
                        isDark: isDark,
                      );
                    },
                  ),
                ]),
                const SizedBox(height: 16),
                _buildSection('Transfer', isDark, [
                  BlocBuilder<SettingsCubit, SettingsState>(
                    builder: (context, state) {
                      return _SettingsTile(
                        icon: Icons.sd_card_outlined,
                        title: 'Chunk Size',
                        subtitle: _formatChunkSize(state.chunkSizeKB),
                        trailing: _DropdownMenu<int>(
                          value: state.chunkSizeKB,
                          items: _chunkSizeOptions,
                          labelBuilder: (v) => _formatChunkSize(v),
                          onChanged: (v) =>
                              context.read<SettingsCubit>().setChunkSize(v),
                        ),
                        isDark: isDark,
                      );
                    },
                  ),
                  BlocBuilder<SettingsCubit, SettingsState>(
                    builder: (context, state) {
                      return _SettingsTile(
                        icon: Icons.swap_vert,
                        title: 'Parallel Chunks',
                        subtitle: '${state.maxConcurrentFiles} in flight',
                        trailing: _DropdownMenu<int>(
                          value: state.maxConcurrentFiles,
                          items: List.generate(8, (i) => i + 1),
                          labelBuilder: (v) => '$v',
                          onChanged: (v) => context
                              .read<SettingsCubit>()
                              .setMaxConcurrentFiles(v),
                        ),
                        isDark: isDark,
                      );
                    },
                  ),
                  BlocBuilder<SettingsCubit, SettingsState>(
                    builder: (context, state) {
                      final location = state.saveLocation;
                      return _SettingsTile(
                        icon: Icons.folder_outlined,
                        title: 'Save Location',
                        subtitle: location ?? 'Default (Downloads)',
                        isDark: isDark,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (location != null)
                              IconButton(
                                tooltip: 'Reset to default',
                                onPressed: () => context
                                    .read<SettingsCubit>()
                                    .setSaveLocation(null),
                                icon: const Icon(Icons.restart_alt, size: 18),
                                color: isDark
                                    ? AppColors.darkTextSecondary
                                    : AppColors.textSecondary,
                              )
                            else
                              const SizedBox.shrink(),
                            IconButton(
                              tooltip: 'Choose folder',
                              onPressed: () => _pickSaveLocation(context),
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              color: AppColors.primary,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ]),
                const SizedBox(height: 16),
                _buildSection('Device', isDark, [
                  BlocBuilder<SettingsCubit, SettingsState>(
                    builder: (context, state) {
                      return _SettingsTile(
                        icon: Icons.phone_android,
                        title: 'Device Name',
                        subtitle: state.deviceName,
                        trailing: IconButton(
                          onPressed: () => _showEditDialog(
                            context,
                            state.deviceName,
                            isDark,
                          ),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          color: isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.textSecondary,
                        ),
                        isDark: isDark,
                      );
                    },
                  ),
                ]),
                const SizedBox(height: 32),
                Center(
                  child: Text(
                    'SwiftShare v1.0.0',
                    style: AppTextStyles.bodySmall(isDark: isDark),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSection(String title, bool isDark, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTextStyles.label(isDark: isDark).copyWith(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        GlassCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      ],
    );
  }

  void _showEditDialog(BuildContext context, String currentName, bool isDark) {
    final controller = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E1432) : Colors.white,
        title: Text(
          'Device Name',
          style: AppTextStyles.heading3(isDark: isDark),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter device name',
            hintStyle: TextStyle(
              color: isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              context.read<SettingsCubit>().setDeviceName(controller.text);
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSaveLocation(BuildContext context) async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose save location',
      );
      if (!context.mounted) return;
      if (dir != null && dir.isNotEmpty) {
        context.read<SettingsCubit>().setSaveLocation(dir);
        GlassToast.show(context, 'Save location updated');
      }
    } catch (_) {
      if (!context.mounted) return;
      GlassToast.show(context, 'Could not open folder picker', isError: true);
    }
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final bool isDark;

  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.trailing,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primary, size: 22),
      title: Text(title, style: AppTextStyles.body(isDark: isDark)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: AppTextStyles.bodySmall(isDark: isDark))
          : null,
      trailing: trailing,
    );
  }
}

class _DropdownMenu<T> extends StatelessWidget {
  final T value;
  final List<T> items;
  final String Function(T) labelBuilder;
  final ValueChanged<T> onChanged;

  const _DropdownMenu({
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(12),
          items: items
              .map((v) => DropdownMenuItem(value: v, child: Text(labelBuilder(v))))
              .toList(),
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          icon: const Icon(Icons.arrow_drop_down, color: AppColors.primary, size: 22),
        ),
      ),
    );
  }
}
