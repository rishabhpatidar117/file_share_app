/// Time buckets used to group and filter history sessions.
enum HistoryDateGroup {
  today,
  yesterday,
  twoDaysAgo,
  thisWeek,
  earlier,
}

class DateGrouping {
  DateGrouping._();

  /// Groups a date relative to today: today, yesterday, 2 days ago,
  /// earlier this calendar week, or before this week.
  static HistoryDateGroup groupFor(DateTime date, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    final d = DateTime(date.year, date.month, date.day);

    final diff = today.difference(d).inDays;
    if (diff <= 0) return HistoryDateGroup.today;
    if (diff == 1) return HistoryDateGroup.yesterday;
    if (diff == 2) return HistoryDateGroup.twoDaysAgo;
    final startOfWeek = today.subtract(Duration(days: today.weekday - 1));
    if (!d.isBefore(startOfWeek)) return HistoryDateGroup.thisWeek;
    return HistoryDateGroup.earlier;
  }

  static String label(HistoryDateGroup group) {
    switch (group) {
      case HistoryDateGroup.today:
        return 'Today';
      case HistoryDateGroup.yesterday:
        return 'Yesterday';
      case HistoryDateGroup.twoDaysAgo:
        return '2 days ago';
      case HistoryDateGroup.thisWeek:
        return 'This week';
      case HistoryDateGroup.earlier:
        return 'Earlier';
    }
  }

  static int sortIndex(HistoryDateGroup group) {
    switch (group) {
      case HistoryDateGroup.today:
        return 0;
      case HistoryDateGroup.yesterday:
        return 1;
      case HistoryDateGroup.twoDaysAgo:
        return 2;
      case HistoryDateGroup.thisWeek:
        return 3;
      case HistoryDateGroup.earlier:
        return 4;
    }
  }
}