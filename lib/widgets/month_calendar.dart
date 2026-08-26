import 'package:flutter/material.dart';

/// One thing to show on a given day — an audit's scheduledDate, or an
/// NC's targetDate. Deliberately generic (not AuditModel/NcModel
/// specific) so the same month grid serves both the Auditor and Auditee
/// calendar screens.
class CalendarEvent {
  final DateTime date;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const CalendarEvent({
    required this.date,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// Order-preserving distinct colors across one day's events — Dart's Color
// has value equality, so a plain Set collapses repeats correctly.
List<Color> _distinctColors(List<CalendarEvent> events) {
  final seen = <Color>{};
  final ordered = <Color>[];
  for (final e in events) {
    if (seen.add(e.color)) ordered.add(e.color);
  }
  return ordered;
}

/// A self-contained month-grid calendar — no external package, since the
/// only real requirement is "show which days have something on them, tap
/// a day to see it below", not a full scheduling UI. Month navigation via
/// chevrons, a dot under any day with 1+ events, selected day highlighted,
/// and that day's events listed underneath the grid.
class MonthCalendar extends StatefulWidget {
  final List<CalendarEvent> events;
  final Widget Function(BuildContext context, List<CalendarEvent> dayEvents)
  emptyDayBuilder;

  const MonthCalendar({
    super.key,
    required this.events,
    required this.emptyDayBuilder,
  });

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  late DateTime _visibleMonth;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    final today = _dayOnly(DateTime.now());
    _visibleMonth = DateTime(today.year, today.month, 1);
    _selectedDay = today;
  }

  Map<DateTime, List<CalendarEvent>> get _byDay {
    final map = <DateTime, List<CalendarEvent>>{};
    for (final e in widget.events) {
      final key = _dayOnly(e.date);
      map.putIfAbsent(key, () => []).add(e);
    }
    return map;
  }

  void _changeMonth(int delta) {
    setState(
      () => _visibleMonth = DateTime(
        _visibleMonth.year,
        _visibleMonth.month + delta,
        1,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final byDay = _byDay;
    final firstOfMonth = _visibleMonth;
    final daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    // Monday-first grid — firstOfMonth.weekday is 1 (Mon) .. 7 (Sun).
    final leadingBlanks = firstOfMonth.weekday - 1;
    final totalCells = leadingBlanks + daysInMonth;
    final rows = (totalCells / 7).ceil();
    final today = _dayOnly(DateTime.now());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${_monthName(_visibleMonth.month)} ${_visibleMonth.year}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: ['M', 'T', 'W', 'T', 'F', 'S', 'S']
                .map(
                  (d) => Expanded(
                    child: Center(
                      child: Text(
                        d,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: scheme.outline,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Column(
            children: [
              for (int r = 0; r < rows; r++)
                Row(
                  children: [
                    for (int c = 0; c < 7; c++) ...[
                      Builder(
                        builder: (context) {
                          final cellIndex = r * 7 + c;
                          final dayNum = cellIndex - leadingBlanks + 1;
                          if (dayNum < 1 || dayNum > daysInMonth) {
                            return const Expanded(child: SizedBox(height: 44));
                          }
                          final date = DateTime(
                            _visibleMonth.year,
                            _visibleMonth.month,
                            dayNum,
                          );
                          final dayEvents = byDay[date] ?? const [];
                          final isSelected = date == _selectedDay;
                          final isToday = date == today;
                          return Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedDay = date),
                              child: Container(
                                height: 44,
                                margin: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? scheme.primary
                                      : (isToday
                                            ? scheme.primaryContainer
                                                  .withValues(alpha: 0.4)
                                            : null),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      '$dayNum',
                                      style: TextStyle(
                                        fontWeight: isToday || isSelected
                                            ? FontWeight.w800
                                            : FontWeight.w500,
                                        color: isSelected
                                            ? scheme.onPrimary
                                            : scheme.onSurface,
                                        fontSize: 13,
                                      ),
                                    ),
                                    if (dayEvents.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          // Up to 3 dots, one per distinct
                                          // status color that day (not one
                                          // per event) — a day with 5
                                          // audits all "In Progress" still
                                          // reads as one calm dot, while a
                                          // day mixing e.g. Overdue +
                                          // Completed visibly shows both.
                                          children: [
                                            for (final color in _distinctColors(dayEvents).take(3))
                                              Container(
                                                margin: const EdgeInsets.symmetric(horizontal: 1),
                                                width: 5,
                                                height: 5,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: isSelected ? scheme.onPrimary : color,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _SelectedDayList(
            day: _selectedDay,
            events: byDay[_selectedDay] ?? const [],
            emptyBuilder: widget.emptyDayBuilder,
          ),
        ),
      ],
    );
  }

  String _monthName(int m) => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][m - 1];
}

class _SelectedDayList extends StatelessWidget {
  final DateTime day;
  final List<CalendarEvent> events;
  final Widget Function(BuildContext context, List<CalendarEvent> dayEvents)
  emptyBuilder;

  const _SelectedDayList({
    required this.day,
    required this.events,
    required this.emptyBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            '${_dayOnly(day) == _dayOnly(DateTime.now()) ? 'Today, ' : ''}${_weekday(day.weekday)} ${day.day} ${_shortMonth(day.month)}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: scheme.outline,
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: events.isEmpty
              ? emptyBuilder(context, events)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: events.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final e = events[i];
                    return Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: e.onTap,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Container(
                                width: 4,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: e.color,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      e.title,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      e.subtitle,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.outline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (e.onTap != null)
                                Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                  color: scheme.outline,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _weekday(int w) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][w - 1];
  String _shortMonth(int m) => const [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ][m - 1];
}
