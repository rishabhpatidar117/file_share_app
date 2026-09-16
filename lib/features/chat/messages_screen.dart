import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'chat_cubit.dart';
import 'chat_state.dart';
import 'chat_conversation.dart';
import 'conversation_screen.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/glass_card.dart';
import '../../core/widgets/gradient_background.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: GradientBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                child: Text('Messages', style: AppTextStyles.heading1(isDark: isDark)),
              ),
              Expanded(
                child: BlocBuilder<ChatCubit, ChatState>(
                  builder: (context, state) {
                    if (state.isLoading) {
                      return const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.primary,
                        ),
                      );
                    }
                    if (state.conversations.isEmpty) {
                      return _buildEmptyState(isDark);
                    }
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                      itemCount: state.conversations.length,
                      itemBuilder: (context, index) {
                        final conversation = state.conversations[index];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _ConversationTile(
                            conversation: conversation,
                            index: index,
                            isDark: isDark,
                            onTap: () {
                              context.read<ChatCubit>();
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ConversationScreen(
                                    peerId: conversation.peerId,
                                    peerName: conversation.peerName,
                                  ),
                                ),
                              );
                            },
                          ),
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

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: (isDark ? AppColors.darkTextSecondary : AppColors.textSecondary)
                .withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            'No conversations yet',
            style: AppTextStyles.body(isDark: isDark).copyWith(
              color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect to a device and chat in real time — '
            'even while files are transferring.',
            style: AppTextStyles.bodySmall(isDark: isDark),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  final ChatConversation conversation;
  final int index;
  final bool isDark;
  final VoidCallback onTap;

  const _ConversationTile({
    required this.conversation,
    required this.index,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final last = conversation.messages.isEmpty ? null : conversation.messages.last;

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
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  gradient: AppColors.primaryGradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.person_outline, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conversation.peerName,
                      style: AppTextStyles.body(isDark: isDark),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      last?.text ?? 'Say hello…',
                      style: AppTextStyles.bodySmall(isDark: isDark),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (last != null)
                Text(
                  _formatTime(last.timestamp),
                  style: AppTextStyles.label(isDark: isDark),
                ),
            ],
          ),
        ),
      ),
    ).animate().fadeIn(delay: Duration(milliseconds: 60 * index)).slideX(begin: 0.03);
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      final h = local.hour.toString().padLeft(2, '0');
      final m = local.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    return '${local.month}/${local.day}';
  }
}