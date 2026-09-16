import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/di/service_locator.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/services/share_receiver_service.dart';
import 'transfer_cubit.dart';
import 'transfer_state.dart';
import 'transfer_screen.dart';
import 'session/transfer_session.dart';

/// App-level overlay that keeps an in-progress send or receive visible from
/// every screen (home tabs, discovery, chat, file picker…). Transfers run on
/// the transport singleton, so navigating away no longer hides — or worse,
/// stops — the transfer; the user can always tap this banner to jump straight
/// back to the transfer screen.
///
/// It is wired into the [MaterialApp.builder] so it sits above the navigator,
/// which means it stays up even across pushed routes and is the only overlay
/// position that can guarantee visibility regardless of navigation depth.
class TransferOverlay extends StatelessWidget {
  const TransferOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return BlocBuilder<TransferCubit, TransferState>(
      builder: (context, state) {
        final hasActiveTransfer = _hasActiveTransfer(state);
        if (!hasActiveTransfer) {
          return const SizedBox.shrink();
        }

        // Sender session takes display priority; otherwise show the receiver.
        final isSender = state.session != null &&
            (state.status == TransferStatus.preparing ||
                state.status == TransferStatus.transferring ||
                state.status == TransferStatus.paused ||
                state.status == TransferStatus.resuming);

        final progress =
            isSender ? state.overallProgress : state.incomingProgress;
        final label = isSender
            ? 'Sending ${state.session?.files.length ?? 0} file(s)…'
            : 'Receiving from '
                '${state.incomingSession?.remoteDeviceName ?? "peer"}…';

        return Positioned(
          left: 24,
          right: 24,
          bottom: 12,
          child: SafeArea(
            top: false,
            child: GestureDetector(
              onTap: () => _openTransferScreen(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppColors.darkBackground.withValues(alpha: 0.96)
                      : Colors.white.withValues(alpha: 0.97),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.2),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isSender
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          color: AppColors.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            label,
                            style: AppTextStyles.bodySmall(isDark: isDark),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${(progress.clamp(0.0, 1.0) * 100).toInt()}%',
                          style:
                              AppTextStyles.bodySmall(isDark: isDark).copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        backgroundColor:
                            AppColors.primary.withValues(alpha: 0.1),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(AppColors.primary),
                        minHeight: 3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool _hasActiveTransfer(TransferState state) {
    final hasSenderTransfer =
        state.status == TransferStatus.preparing ||
        state.status == TransferStatus.transferring ||
        state.status == TransferStatus.paused ||
        state.status == TransferStatus.resuming;
    final hasReceiverTransfer = state.incomingSession != null &&
        state.incomingSession!.status != SessionStatus.completed;
    return hasSenderTransfer || hasReceiverTransfer;
  }

  void _openTransferScreen(BuildContext context) {
    final navigator = getIt<ShareReceiverService>().navigatorKey.currentState;
    final navigatorContext = navigator?.context;
    if (navigatorContext == null) return;
    Navigator.push(
      navigatorContext,
      MaterialPageRoute(builder: (_) => const TransferScreen()),
    );
  }
}