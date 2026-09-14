import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/gradient_background.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

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
              child: _buildDemoHistory(isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDemoHistory(bool isDark) {
    final demoSessions = [
      _DemoSession('documents.zip', '24.5 MB', 'Completed', true, DateTime.now().subtract(const Duration(hours: 2))),
      _DemoSession('vacation_photos', '156 MB', 'Completed', true, DateTime.now().subtract(const Duration(days: 1))),
      _DemoSession('presentation.pptx', '8.2 MB', 'Failed', false, DateTime.now().subtract(const Duration(days: 2))),
    ];

    if (demoSessions.isEmpty) {
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
              'No transfer history',
              style: AppTextStyles.body(isDark: isDark).copyWith(
                color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      itemCount: demoSessions.length,
      itemBuilder: (context, index) {
        final session = demoSessions[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (session.success ? AppColors.success : AppColors.error)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    session.success ? Icons.check_circle_outline : Icons.error_outline,
                    color: session.success ? AppColors.success : AppColors.error,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(session.name, style: AppTextStyles.body(isDark: isDark)),
                      const SizedBox(height: 2),
                      Text(
                        '${session.size} • ${session.status} • ${_formatTime(session.time)}',
                        style: AppTextStyles.bodySmall(isDark: isDark),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () {},
                  icon: Icon(
                    Icons.more_vert,
                    size: 18,
                    color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: Duration(milliseconds: 80 * index)).slideX(begin: 0.03),
        );
      },
    );
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class _DemoSession {
  final String name;
  final String size;
  final String status;
  final bool success;
  final DateTime time;

  _DemoSession(this.name, this.size, this.status, this.success, this.time);
}