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

// Months are compared and stored as their own 1st here, so a caller can
// hand over any date inside the month it means (and so two DateTimes for
// "March 2026" built from different days still compare equal, which the
// didUpdateWidget echo check below depends on).
DateTime _monthOnly(DateTime d) => DateTime(d.year, d.month, 1);

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
///
/// The visible month can optionally be driven from outside as well — see
/// [visibleMonth]/[onVisibleMonthChanged] and _MonthCalendarState's own
/// _visibleMonth for how the two directions are reconciled. Both props are
/// optional and omitting them leaves this widget behaving exactly as it
/// always has.
class MonthCalendar extends StatefulWidget {
  final List<CalendarEvent> events;
  final Widget Function(BuildContext context, List<CalendarEvent> dayEvents)
  emptyDayBuilder;
  // Optional dot+label legend rendered between the month-nav row and the
  // weekday header — same placement as the web calendar's own legend row
  // (Calendar.jsx), above the grid. Null keeps this widget usable by any
  // future caller that doesn't have a fixed color scheme worth spelling
  // out (e.g. a single-category list with no ambiguity to label).
  final Widget? legend;

  /// The month to render, given as any date inside it (normalised to the
  /// 1st internally). OPTIONAL, and null keeps the historical behaviour
  /// exactly: the grid picks the current month in initState and nothing
  /// outside it can ever move the view again.
  ///
  /// Passed by screens/calendar/calendar_screen.dart, where a control that
  /// lives OUTSIDE the grid — the filter sheet's Month section — also has
  /// to be able to jump the month. That sheet is opened with the month
  /// currently on screen (widgets/filter_sheet.dart's `month` argument), so
  /// the two have to agree on what "currently on screen" is.
  final DateTime? visibleMonth;

  /// Fired whenever this widget's OWN chevrons move the month, so a parent
  /// that passes [visibleMonth] can keep its copy current. Without it the
  /// parent's month goes stale the instant the user taps a chevron, and the
  /// next filter-sheet open would offer the month from before those taps —
  /// the classic half-controlled-widget bug, where the data flows down but
  /// never back up.
  final ValueChanged<DateTime>? onVisibleMonthChanged;

  const MonthCalendar({
    super.key,
    required this.events,
    required this.emptyDayBuilder,
    this.legend,
    this.visibleMonth,
    this.onVisibleMonthChanged,
  });

  @override
  State<MonthCalendar> createState() => _MonthCalendarState();
}

class _MonthCalendarState extends State<MonthCalendar> {
  /// The month actually being rendered — and deliberately still State, not
  /// a straight read of [MonthCalendar.visibleMonth]: this widget is only
  /// half-controlled on purpose.
  ///
  /// Making it fully controlled (render the prop, route chevron taps out
  /// through the callback and wait for a new prop to come back) would mean
  /// every chevron tap costs a parent rebuild round-trip to repaint, and
  /// would freeze the grid outright for any caller that wires up
  /// [MonthCalendar.onVisibleMonthChanged] but forgets to feed the result
  /// back into [MonthCalendar.visibleMonth] — or passes no props at all,
  /// which is still a supported way to use this widget. So both directions
  /// land on this one cursor instead: the prop PUSHES into it
  /// (didUpdateWidget), the chevrons move it and then TELL the parent
  /// (onVisibleMonthChanged). It is the single source of truth for what is
  /// drawn either way.
  late DateTime _visibleMonth;
  late DateTime _selectedDay;

  @override
  void initState() {
    super.initState();
    _visibleMonth = _monthOnly(widget.visibleMonth ?? DateTime.now());
    _selectedDay = _selectionForMonth(_visibleMonth);
  }

  @override
  void didUpdateWidget(covariant MonthCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.visibleMonth;
    // A caller that never passes the prop keeps full local control.
    if (incoming == null) {
      return;
    }
    final normalised = _monthOnly(incoming);
    // Almost every rebuild lands here with the month we ourselves just
    // reported through onVisibleMonthChanged, so this equality check is
    // what stops the two-way sync from ping-ponging (and from stomping the
    // selected day back to today on every unrelated parent rebuild).
    if (normalised == _visibleMonth) {
      return;
    }
    setState(() {
      _visibleMonth = normalised;
      _selectedDay = _selectionForMonth(normalised);
    });
  }

  /// Which day to select when the grid lands on [month].
  ///
  /// The day-detail list under the grid has to be showing a day that is
  /// actually IN the grid, so a month change can't just leave the previous
  /// selection alone — jumping from March to April used to leave "Fri 15
  /// Mar" and its events listed under an April grid. Rule: today if today
  /// is in the new month (overwhelmingly the day you want, and it matches
  /// where the screen opens), otherwise the 1st — the first cell of the
  /// month and an obvious, stable landing spot, as opposed to "keep the
  /// same day number", which needs clamping for 29-31 and lands somewhere
  /// arbitrary anyway.
  DateTime _selectionForMonth(DateTime month) {
    final today = _dayOnly(DateTime.now());
    if (today.year == month.year && today.month == month.month) {
      return today;
    }
    return DateTime(month.year, month.month, 1);
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
    // DateTime rolls month 0 / month 13 over into the neighbouring year on
    // its own, so December -> January needs no special case here.
    final next = DateTime(_visibleMonth.year, _visibleMonth.month + delta, 1);
    setState(() {
      _visibleMonth = next;
      _selectedDay = _selectionForMonth(next);
    });
    // Told AFTER the local move, never instead of it (see _visibleMonth's
    // own comment). A parent that feeds this straight back into
    // [MonthCalendar.visibleMonth] hits the equality check in
    // didUpdateWidget and simply rebuilds, so there is no second setState
    // and no loop.
    widget.onVisibleMonthChanged?.call(next);
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
        if (widget.legend != null) widget.legend!,
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
