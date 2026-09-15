import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'history_cubit.dart';
import 'session_detail_screen.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/utils/byte_formatter.dart';
import '../../core/utils/date_group.dart';
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
  static const _dateChips = <HistoryDateGroup?, String>{
    null: 'All',
    HistoryDateGroup.today: 'Today',
    HistoryDateGroup.yesterday: 'Yesterday',
    HistoryDateGroup.twoDaysAgo: '2 days ago',
    HistoryDateGroup.thisWeek: 'This week',
    HistoryDateGroup.earlier: 'Earlier',
  };

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
              child: Text(
                'Transfer History',
                style: AppTextStyles.heading1(isDark: isDark),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: BlocBuilder<HistoryCubit, HistoryState>(
                buildWhen: (prev, next) => prev.sourceFilter != next.sourceFilter,
                builder: (context, state) {
                  return _SourceTabs(
                    current: state.sourceFilter,
                    isDark: isDark,
                    onSelected: (filter) =>
                        context.read<HistoryCubit>().setSourceFilter(filter),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: BlocBuilder<HistoryCubit, HistoryState>(
                buildWhen: (prev, next) => prev.dateFilter != next.dateFilter,
                builder: (context, state) {
                  return _DateChips(
                    current: state.dateFilter,
                    isDark: isDark,
                    onSelected: (group) =>
                        context.read<HistoryCubit>().setDateFilter(group),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: BlocBuilder<HistoryCubit, HistoryState>(
                builder: (context, state) {
                  if (state.isLoading) {
                    return const Center(
                      child: CircularProgressIndicator(color: AppColors.primary),
                    );
                  }
                  if (state.filteredSessions.isEmpty) {
                    return _buildEmpty(isDark, state.sourceFilter);
                  }
                  return _buildGroupedList(isDark, state);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupedList(bool isDark, HistoryState state) {
    final groups = <HistoryDateGroup, List<TransferSession>>{};
    for (final session in state.filteredSessions) {
      final time = session.completedAt ?? session.createdAt;
      final group = DateGrouping.groupFor(time);
      groups.putIfAbsent(group, () => []).add(session);
    }

    final orderedGroups = HistoryDateGroup.values
        .where((g) => groups.containsKey(g))
        .toList()
      ..sort((a, b) =>
          DateGrouping.sortIndex(a).compareTo(DateGrouping.sortIndex(b)));

    return CustomScrollView(
      slivers: [
        for (final group in orderedGroups) ...[
          SliverPersistentHeader(
            pinned: true,
            delegate: _GroupHeaderDelegate(
              title: DateGrouping.label(group),
              isDark: isDark,
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final session = groups[group]![index];
                return _SessionCard(
                  session: session,
                  isDark: isDark,
                  onTap: () => _openSession(context, session),
                  onArchive: () {
                    if (state.sourceFilter == HistorySourceFilter.archived) {
                      context.read<HistoryCubit>().unarchiveSession(session.id);
                      GlassToast.show(context, 'Restored from archive');
                    } else {
                      context.read<HistoryCubit>().archiveSession(session.id);
                      GlassToast.show(context, 'Session archived');
                    }
                  },
                  onDelete: () {
                    context.read<HistoryCubit>().deleteSession(session.id);
                    GlassToast.show(context, 'Session deleted');
                  },
                  showRestore: state.sourceFilter == HistorySourceFilter.archived,
                ).animate().fadeIn(duration: 300.ms).slideX(begin: 0.03);
              },
              childCount: groups[group]!.length,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEmpty(bool isDark, HistorySourceFilter filter) {
    final message = switch (filter) {
      HistorySourceFilter.all => 'No transfers yet',
      HistorySourceFilter.outgoing => 'No outgoing transfers',
      HistorySourceFilter.incoming => 'No incoming transfers',
      HistorySourceFilter.archived => 'No archived transfers',
    };
    final submessage = switch (filter) {
      HistorySourceFilter.archived =>
        'Swipe a change to archive it, or drag it to restore.',
      _ => 'Sent and received transfers will appear here.',
    };
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
            message,
            style: AppTextStyles.body(isDark: isDark).copyWith(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            submessage,
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
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SessionDetailScreen(session: session)),
      );
    }
  }
}

class _SourceTabs extends StatelessWidget {
  final HistorySourceFilter current;
  final bool isDark;
  final ValueChanged<HistorySourceFilter> onSelected;

  const _SourceTabs({
    required this.current,
    required this.isDark,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    const options = [
      (HistorySourceFilter.all, 'All'),
      (HistorySourceFilter.outgoing, 'Sent'),
      (HistorySourceFilter.incoming, 'Received'),
      (HistorySourceFilter.archived, 'Archived'),
    ];

    return Container(
      height: 40,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          for (final (filter, label) in options)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelected(filter),
                child: AnimatedContainer(
                  duration: 200.ms,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: current == filter
                        ? AppColors.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: current == filter ? Colors.white : (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DateChips extends StatelessWidget {
  final HistoryDateGroup? current;
  final bool isDark;
  final ValueChanged<HistoryDateGroup?> onSelected;

  const _DateChips({
    required this.current,
    required this.isDark,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in _HistoryScreenState._dateChips.entries) ...[
            GestureDetector(
              onTap: () => onSelected(entry.key),
              child: AnimatedContainer(
                duration: 200.ms,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: current == entry.key
                      ? AppColors.primary.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: current == entry.key
                        ? AppColors.primary.withValues(alpha: 0.6)
                        : (isDark ? Colors.white12 : Colors.black12),
                  ),
                ),
                child: Text(
                  entry.value,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: current == entry.key
                        ? AppColors.primary
                        : (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _GroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String title;
  final bool isDark;

  _GroupHeaderDelegate({required this.title, required this.isDark});

  @override
  double get minExtent => 36;
  @override
  double get maxExtent => 36;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkBackground : AppColors.lightBackground,
        border: Border(
          bottom: BorderSide(
            color: (isDark ? Colors.white : Colors.black).withValues(alpha: 0.06),
          ),
        ),
      ),
      child: Text(
        title,
        style: AppTextStyles.label(isDark: isDark).copyWith(
          color: AppColors.primary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_GroupHeaderDelegate oldDelegate) {
    return oldDelegate.title != title || oldDelegate.isDark != isDark;
  }
}

class _SessionCard extends StatelessWidget {
  final TransferSession session;
  final bool isDark;
  final VoidCallback onTap;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final bool showRestore;

  const _SessionCard({
    required this.session,
    required this.isDark,
    required this.onTap,
    required this.onArchive,
    required this.onDelete,
    required this.showRestore,
  });

  @override
  Widget build(BuildContext context) {
    final indicatorColor =
        session.isSender ? AppColors.primary : AppColors.success;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Dismissible(
        key: ValueKey('history-${session.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onArchive(),
        background: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(right: 24),
          alignment: Alignment.centerRight,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                showRestore ? Icons.unarchive_outlined : Icons.archive_outlined,
                color: AppColors.primary,
              ),
              const SizedBox(height: 4),
              Text(
                showRestore ? 'Restore' : 'Archive',
                style: const TextStyle(color: AppColors.primary, fontSize: 11),
              ),
            ],
          ),
        ),
        child: GlassCard(
          padding: const EdgeInsets.all(14),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(24),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: indicatorColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      session.isSender
                          ? Icons.arrow_upward_rounded
                          : Icons.arrow_downward_rounded,
                      color: indicatorColor,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _primaryLabel(),
                          style: AppTextStyles.body(isDark: isDark),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _secondaryLabel(),
                          style: AppTextStyles.bodySmall(isDark: isDark),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    iconColor:
                        isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
                    itemBuilder: (_) => [
                      if (!showRestore)
                        const PopupMenuItem(value: 'archive', child: Text('Archive')),
                      if (showRestore)
                        const PopupMenuItem(value: 'restore', child: Text('Restore')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                    onSelected: (value) {
                      if (value == 'delete') onDelete();
                      if (value == 'archive' || value == 'restore') onArchive();
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _primaryLabel() {
    final direction = session.isSender
        ? 'Sent to ${session.remoteDeviceName ?? "device"}'
        : 'Received from ${session.remoteDeviceName ?? "device"}';
    final first = session.files.isNotEmpty ? session.files.first.fileName : 'Unknown';
    final extra = session.files.length > 1 ? ' +${session.files.length - 1} more' : '';
    return '$direction • $first$extra';
  }

  String _secondaryLabel() {
    final count = session.files.length == 1 ? '1 file' : '${session.files.length} files';
    final size = ByteFormatter.format(session.totalBytes);
    final status = _statusLabel();
    final time = session.completedAt ?? session.createdAt;
    return '$count • $size • $status • ${_formatTime(time)}';
  }

  String _statusLabel() {
    if (session.isCompleted) return 'completed';
    switch (session.status) {
      case SessionStatus.transferring:
      case SessionStatus.resumed:
        return 'in progress';
      case SessionStatus.paused:
        return 'paused';
      case SessionStatus.failed:
        return 'failed';
      case SessionStatus.completed:
        return 'completed';
      case SessionStatus.discovering:
      case SessionStatus.connecting:
        return 'connecting';
      case SessionStatus.created:
        return 'created';
    }
  }

  String _formatTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}