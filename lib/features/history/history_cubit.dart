import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/utils/date_group.dart';
import '../transfer/session/transfer_session.dart';
import '../transfer/session/session_repository.dart';

enum HistorySourceFilter { all, outgoing, incoming, archived }

class HistoryState {
  final List<TransferSession> sessions;
  final bool isLoading;
  final HistorySourceFilter sourceFilter;
  final HistoryDateGroup? dateFilter;

  const HistoryState({
    this.sessions = const [],
    this.isLoading = true,
    this.sourceFilter = HistorySourceFilter.all,
    this.dateFilter,
  });

  List<TransferSession> get filteredSessions {
    final source = switch (sourceFilter) {
      HistorySourceFilter.all => sessions.where((s) => !s.isArchived),
      HistorySourceFilter.outgoing => sessions.where((s) => s.isSender && !s.isArchived),
      HistorySourceFilter.incoming => sessions.where((s) => !s.isSender && !s.isArchived),
      HistorySourceFilter.archived => sessions.where((s) => s.isArchived),
    };

    if (dateFilter == null) return source.toList();

    return source
        .where((s) {
          final time = s.completedAt ?? s.createdAt;
          return DateGrouping.groupFor(time) == dateFilter;
        })
        .toList();
  }

  HistoryState copyWith({
    List<TransferSession>? sessions,
    bool? isLoading,
    HistorySourceFilter? sourceFilter,
    HistoryDateGroup? dateFilter,
    bool clearDateFilter = false,
  }) {
    return HistoryState(
      sessions: sessions ?? this.sessions,
      isLoading: isLoading ?? this.isLoading,
      sourceFilter: sourceFilter ?? this.sourceFilter,
      dateFilter: clearDateFilter ? null : (dateFilter ?? this.dateFilter),
    );
  }
}

class HistoryCubit extends Cubit<HistoryState> {
  final SessionRepository _repository;

  HistoryCubit(this._repository) : super(const HistoryState());

  Future<void> loadHistory() async {
    emit(state.copyWith(isLoading: true));
    final sessions = await _repository.getAllSessions();
    emit(state.copyWith(sessions: sessions, isLoading: false));
  }

  void setSourceFilter(HistorySourceFilter filter) {
    emit(state.copyWith(sourceFilter: filter, clearDateFilter: filter == HistorySourceFilter.archived));
  }

  void setDateFilter(HistoryDateGroup? group) {
    emit(state.copyWith(
      dateFilter: group,
      clearDateFilter: group == null,
    ));
  }

  Future<void> archiveSession(String id) async {
    await _repository.setArchived(id, true);
    await loadHistory();
  }

  Future<void> unarchiveSession(String id) async {
    await _repository.setArchived(id, false);
    await loadHistory();
  }

  Future<void> deleteSession(String id) async {
    await _repository.deleteSession(id);
    await loadHistory();
  }
}