import 'session/transfer_session.dart';

enum TransferStatus {
  idle,
  preparing,
  transferring,
  paused,
  completed,
  failed,
  resuming,
}

class TransferState {
  final TransferStatus status;
  final TransferSession? session;
  final double overallProgress;
  final double speed;
  final String? activeChannel;
  final String? errorMessage;

  const TransferState({
    this.status = TransferStatus.idle,
    this.session,
    this.overallProgress = 0,
    this.speed = 0,
    this.activeChannel,
    this.errorMessage,
  });

  TransferState copyWith({
    TransferStatus? status,
    TransferSession? session,
    double? overallProgress,
    double? speed,
    String? activeChannel,
    String? errorMessage,
    bool clearError = false,
  }) {
    return TransferState(
      status: status ?? this.status,
      session: session ?? this.session,
      overallProgress: overallProgress ?? this.overallProgress,
      speed: speed ?? this.speed,
      activeChannel: activeChannel ?? this.activeChannel,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}