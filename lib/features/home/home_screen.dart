import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/glass_toast.dart';
import '../../core/widgets/gradient_background.dart';
import '../discovery/discovery_screen.dart';
import '../history/history_cubit.dart';
import '../history/history_screen.dart';
import '../settings/settings_screen.dart';
import '../transfer/session/transfer_session.dart';
import '../transfer/transfer_cubit.dart';
import '../transfer/transfer_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWide = MediaQuery.of(context).size.width > 600;

    if (isWide) {
      return _buildWideLayout(context, isDark);
    }
    return _buildMobileLayout(context, isDark);
  }

  Widget _buildWideLayout(BuildContext context, bool isDark) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            backgroundColor: isDark
                ? AppColors.darkBackground
                : AppColors.lightBackground,
            indicatorColor: AppColors.primary.withValues(alpha: 0.15),
            selectedIconTheme: IconThemeData(color: AppColors.primary),
            unselectedIconTheme: IconThemeData(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
            selectedLabelTextStyle: TextStyle(color: AppColors.primary),
            unselectedLabelTextStyle: TextStyle(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Icon(Icons.send_rounded, color: AppColors.primary, size: 28),
            ),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: Text('Home'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.history_outlined),
                selectedIcon: Icon(Icons.history),
                label: Text('History'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          Expanded(child: _buildPageContent(context, isDark)),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context, bool isDark) {
    return Scaffold(
      body: _buildPageContent(context, isDark),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        backgroundColor: isDark
            ? AppColors.darkBackground.withValues(alpha: 0.9)
            : Colors.white.withValues(alpha: 0.9),
        indicatorColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildPageContent(BuildContext context, bool isDark) {
    switch (_selectedIndex) {
      case 0:
        return _HomeContent(isDark: isDark);
      case 1:
        return const HistoryScreen();
      case 2:
        return const SettingsScreen();
      default:
        return _HomeContent(isDark: isDark);
    }
  }
}

class _HomeContent extends StatelessWidget {
  final bool isDark;

  const _HomeContent({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return GradientBackground(
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('SwiftShare', style: AppTextStyles.heading1(isDark: isDark)),
                  IconButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SettingsScreen(),
                        ),
                      );
                    },
                    icon: Icon(
                      Icons.settings_outlined,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: MediaQuery.of(context).size.width > 600 ? 2 : 1,
                childAspectRatio: 1.8,
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _ActionCard(
                    title: 'Send Files',
                    subtitle: 'Share files with nearby devices',
                    icon: Icons.send_rounded,
                    gradient: AppColors.primaryGradient,
                    isDark: isDark,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DiscoveryScreen(isSender: true),
                      ),
                    ),
                  ),
                  _ActionCard(
                    title: 'Receive Files',
                    subtitle: 'Make device visible to others',
                    icon: Icons.download_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF10B981), Color(0xFF34D399)],
                    ),
                    isDark: isDark,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const DiscoveryScreen(isSender: false),
                      ),
                    ),
                  ),
                ].animate(interval: 100.ms).fadeIn().slideY(begin: 0.1),
              ),
              const SizedBox(height: 24),
              Text('Recent Transfers', style: AppTextStyles.heading3(isDark: isDark)),
              const SizedBox(height: 12),
              const _RecentTransfers(),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecentTransfers extends StatefulWidget {
  const _RecentTransfers();

  @override
  State<_RecentTransfers> createState() => _RecentTransfersState();
}

class _RecentTransfersState extends State<_RecentTransfers> {
  @override
  void initState() {
    super.initState();
    context.read<HistoryCubit>().loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BlocBuilder<HistoryCubit, HistoryState>(
      builder: (context, state) {
        if (state.isLoading) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.primary,
              ),
            ),
          );
        }

        if (state.sessions.isEmpty) {
          return GlassCard(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.history_toggle_off,
                  color: (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary)
                      .withValues(alpha: 0.5),
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Transfers you send or receive will show up here.',
                    style: AppTextStyles.bodySmall(isDark: isDark),
                  ),
                ),
              ],
            ),
          );
        }

        final recents = state.sessions.take(3).toList();
        return Column(
          children: recents.map((session) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _RecentCard(
                session: session,
                isDark: isDark,
                onTap: () => _open(context, session),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  void _open(BuildContext context, TransferSession session) {
    final completed = session.status == SessionStatus.completed && session.isCompleted;
    if (session.isSender && !completed) {
      context.read<TransferCubit>().resumeSession(session.id);
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TransferScreen()),
      );
    } else if (completed) {
      GlassToast.show(
        context,
        ' $session.isSender ? "Sent" : "Received" ${session.files.length} file(s).',
      );
    } else {
      GlassToast.show(
        context,
        'Open "Receive Files" on the home screen to resume this transfer.',
      );
    }
  }
}

class _RecentCard extends StatelessWidget {
  final TransferSession session;
  final bool isDark;
  final VoidCallback onTap;

  const _RecentCard({
    required this.session,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final completed = session.isCompleted;
    final name = session.files.isNotEmpty
        ? session.files.first.fileName
        : 'Untitled transfer';

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
                      name,
                      style: AppTextStyles.body(isDark: isDark),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${ByteFormatter.format(session.totalBytes)} • $_statusLabel'
                      '${session.files.length > 1 ? ' • ${session.files.length} files' : ''}',
                      style: AppTextStyles.bodySmall(isDark: isDark),
                    ),
                  ],
                ),
              ),
              if (completed)
                Icon(Icons.check_circle, color: AppColors.success, size: 20)
              else if (session.isSender)
                Icon(Icons.play_circle_outline, color: AppColors.success, size: 20),
            ],
          ),
        ),
      ),
    );
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

  String get _statusLabel {
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
}

class _ActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Gradient gradient;
  final bool isDark;
  final VoidCallback onTap;

  const _ActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.gradient,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(title, style: AppTextStyles.heading3(isDark: isDark)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: AppTextStyles.bodySmall(isDark: isDark)),
                  ],
                ),
              ),
              Icon(
                Icons.arrow_forward_ios,
                size: 16,
                color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}