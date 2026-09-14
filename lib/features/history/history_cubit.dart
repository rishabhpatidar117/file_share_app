import 'package:flutter_bloc/flutter_bloc.dart';
import '../transfer/session/transfer_session.dart';
import '../transfer/session/session_repository.dart';

class HistoryState {
  final List<TransferSession> sessions;
  final bool isLoading;

  const HistoryState({
    this.sessions = const [],
    this.isLoading = true,
  });
}

class HistoryCubit extends Cubit<HistoryState> {
  final SessionRepository _repository;

  HistoryCubit(this._repository) : super(const HistoryState());

  Future<void> loadHistory() async {
    emit(const HistoryState(isLoading: true));
    final sessions = await _repository.getAllSessions();
    emit(HistoryState(sessions: sessions, isLoading: false));
  }

  Future<void> deleteSession(String id) async {
    await _repository.deleteSession(id);
    await loadHistory();
  }
}