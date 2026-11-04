import 'audit_date_range.dart';

/// The stretch of days the Calendar asks the server for — the phone's twin of
/// the web Calendar's `windowFrom` / `windowTo` (client/src/pages/Calendar.jsx).
///
/// The web loads only the 42-day grid on screen (padded by one day on each
/// edge: the audit day turns over at 01:00 IST, so an item stored as the
/// previous UTC day can still belong on a visible edge day, and the server reads
/// a bare toDate as the end of a day in its own timezone). The phone grid also
/// shows the neighbouring months' days, and it goes one month either way
/// ([CalendarWindow.around]) so stepping to the next or previous month is
/// instant — it only asks again once the grid leaves what it already holds
/// ([covers]).
///
/// Both ends are inclusive, date-only, local.
class CalendarWindow {
  /// First and last day, inclusive.
  final DateTime from;
  final DateTime to;

  const CalendarWindow(this.from, this.to);

  /// The first and last cell of the Monday-first month grid for [month]: the
  /// leading days of the month before and the trailing days of the month after
  /// that fill the first and last week.
  factory CalendarWindow.gridOf(DateTime month) {
    final first = DateTime(month.year, month.month, 1);
    final last = DateTime(month.year, month.month + 1, 0);
    return CalendarWindow(
      DateTime(first.year, first.month, 1 - (first.weekday - 1)),
      DateTime(last.year, last.month, last.day + (DateTime.sunday - last.weekday)),
    );
  }

  /// What must be loaded for [month]'s grid to be right: the grid, a day wider
  /// each way (see the class doc).
  factory CalendarWindow.forGrid(DateTime month) {
    final grid = CalendarWindow.gridOf(month);
    return CalendarWindow(_shift(grid.from, -1), _shift(grid.to, 1));
  }

  /// What is asked for while [month] is on screen: the grids of the month
  /// before, the month and the month after — so a step either way is already
  /// loaded (every grid is at most a week wider than its month, and
  /// [CalendarWindow.forGrid]'s one-day pad is inside the same margin).
  factory CalendarWindow.around(DateTime month) {
    final before = CalendarWindow.forGrid(DateTime(month.year, month.month - 1, 1));
    final after = CalendarWindow.forGrid(DateTime(month.year, month.month + 1, 1));
    return CalendarWindow(before.from, after.to);
  }

  /// Whether every day of [other] is inside this window.
  bool covers(CalendarWindow other) => !from.isAfter(other.from) && !to.isBefore(other.to);

  /// The first day to ask for AUDITS: a multi-day audit that began before the
  /// window can still be live inside it, and the calendar marks an audit on at
  /// most [maxAuditRangeDays] days from its start (daysInAuditRange). The server
  /// windows an audit by its start date only.
  DateTime get auditFrom => _shift(from, -maxAuditRangeDays);

  /// `yyyy-MM-dd`, what the server's fromDate / toDate / dueFrom / dueTo read.
  static String param(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) => other is CalendarWindow && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'CalendarWindow(${param(from)}..${param(to)})';

  // Calendar arithmetic, not Duration: a Duration of 24h across a clock change
  // lands on the wrong day.
  static DateTime _shift(DateTime day, int days) => DateTime(day.year, day.month, day.day + days);
}
