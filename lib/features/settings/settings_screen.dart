import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'settings_cubit.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/gradient_background.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return GradientBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Settings', style: AppTextStyles.heading1(isDark: isDark)),
              const SizedBox(height: 24),
              _buildSection('Appearance', isDark, [
                BlocBuilder<SettingsCubit, SettingsState>(
                  builder: (context, state) {
                    return _SettingsTile(
                      icon: Icons.dark_mode_outlined,
                      title: 'Dark Mode',
                      trailing: Switch(
                        value: state.isDarkMode,
                        onChanged: (_) => context.read<SettingsCubit>().toggleDarkMode(),
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
                      subtitle: '${state.chunkSizeKB} KB',
                      trailing: PopupMenuButton<int>(
                        onSelected: (v) => context.read<SettingsCubit>().setChunkSize(v),
                        itemBuilder: (_) => [64, 128, 256, 512, 1024]
                            .map((v) => PopupMenuItem(value: v, child: Text('$v KB')))
                            .toList(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${state.chunkSizeKB} KB',
                            style: TextStyle(color: AppColors.primary, fontSize: 13),
                          ),
                        ),
                      ),
                      isDark: isDark,
                    );
                  },
                ),
                BlocBuilder<SettingsCubit, SettingsState>(
                  builder: (context, state) {
                    return _SettingsTile(
                      icon: Icons.swap_vert,
                      title: 'Max Concurrent Files',
                      subtitle: '${state.maxConcurrentFiles}',
                      trailing: PopupMenuButton<int>(
                        onSelected: (v) => context.read<SettingsCubit>().setMaxConcurrentFiles(v),
                        itemBuilder: (_) => [1, 2, 3, 5, 8]
                            .map((v) => PopupMenuItem(value: v, child: Text('$v')))
                            .toList(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${state.maxConcurrentFiles}',
                            style: TextStyle(color: AppColors.primary, fontSize: 13),
                          ),
                        ),
                      ),
                      isDark: isDark,
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
                        onPressed: () => _showEditDialog(context, state.deviceName, isDark),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
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
        title: Text('Device Name', style: AppTextStyles.heading3(isDark: isDark)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter device name',
            hintStyle: TextStyle(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
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
      title: Text(
        title,
        style: AppTextStyles.body(isDark: isDark),
      ),
      subtitle: subtitle != null
          ? Text(subtitle!, style: AppTextStyles.bodySmall(isDark: isDark))
          : null,
      trailing: trailing,
    );
  }
}