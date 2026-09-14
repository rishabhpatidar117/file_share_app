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

  /// Session currently being received from a remote sender.
  final TransferSession? incomingSession;

  /// Directory where incoming files are being saved.
  final String? saveDirectory;

  final String? incomingError;

  const TransferState({
    this.status = TransferStatus.idle,
    this.session,
    this.overallProgress = 0,
    this.speed = 0,
    this.activeChannel,
    this.errorMessage,
    this.incomingSession,
    this.saveDirectory,
    this.incomingError,
  });

  double get incomingProgress {
    final incoming = incomingSession;
    if (incoming == null) return 0;
    return incoming.progress;
  }

  TransferState copyWith({
    TransferStatus? status,
    TransferSession? session,
    double? overallProgress,
    double? speed,
    String? activeChannel,
    String? errorMessage,
    bool clearError = false,
    TransferSession? incomingSession,
    String? saveDirectory,
    String? incomingError,
    bool clearIncoming = false,
    bool clearIncomingError = false,
  }) {
    return TransferState(
      status: status ?? this.status,
      session: session ?? this.session,
      overallProgress: overallProgress ?? this.overallProgress,
      speed: speed ?? this.speed,
      activeChannel: activeChannel ?? this.activeChannel,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      incomingSession: clearIncoming ? null : (incomingSession ?? this.incomingSession),
      saveDirectory: clearIncoming ? null : (saveDirectory ?? this.saveDirectory),
      incomingError: clearIncomingError ? null : (incomingError ?? this.incomingError),
    );
  }
}