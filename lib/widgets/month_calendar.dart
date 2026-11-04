import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/utils/calendar_entries.dart';
import 'calendar_layers.dart';

const _monthNames = [
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
];

const _weekdayNames = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// "November 2026".
String calendarMonthLabel(DateTime month) => '${_monthNames[month.month - 1]} ${month.year}';

/// "Tuesday 3 November 2026" — the long form a screen reader or a day heading reads.
String calendarLongDay(DateTime day) =>
    '${_weekdayNames[day.weekday - 1]} ${day.day} ${_monthNames[day.month - 1]} ${day.year}';

/// The bar above the grid: ‹ previous · "November 2026 ▾" (tap to pick a month and
/// a year) · next › · and a way back to today when the view is somewhere else.
/// Every control is at least 44 px; the title scales down rather than overflowing
/// at 320 px or a large text size.
class CalendarMonthBar extends StatelessWidget {
  final DateTime month;
  final bool showToday;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPick;
  final VoidCallback onToday;

  const CalendarMonthBar({
    super.key,
    required this.month,
    required this.showToday,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
    required this.onToday,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = calendarMonthLabel(month);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The word "Today" only when there is room for it beside a readable title;
        // otherwise the same control as an icon (tooltip and semantics unchanged).
        final roomy = constraints.maxWidth >= 360 && MediaQuery.textScalerOf(context).scale(14) <= 14 * 1.3;
        return Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: onPrev,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Semantics(
                button: true,
                label: '$label, choose month',
                excludeSemantics: true,
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: onPick,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              label,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            Icon(Icons.arrow_drop_down, color: scheme.outline),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            ),
            if (showToday)
              roomy
                  ? TextButton.icon(
                      onPressed: onToday,
                      icon: const Icon(Icons.today_outlined, size: 18),
                      label: const Text('Today'),
                      style: TextButton.styleFrom(minimumSize: const Size(44, 48)),
                    )
                  : IconButton(
                      tooltip: 'Today',
                      onPressed: onToday,
                      icon: const Icon(Icons.today_outlined),
                    ),
          ],
        );
      },
    );
  }
}

/// The month grid: weekday header and one cell per day, Monday first, the
/// neighbouring months' days dimmed in the first and last week.
///
/// A cell shows its day number (today is a filled circle, the selected day a ring
/// and a tint) and, per layer that has something that day, the layer's icon in the
/// colour of the most pressing audit status — with the count beside it when there
/// is more than one. Each audit is counted once, under the first of its layers that
/// is switched on ([CalendarEntry.primaryLayer]).
///
/// Swipe sideways to step a month. The cells span the full width — 45 px each on a
/// 320 px phone — and grow with the text size, so the numbers stay legible and every
/// day is a comfortable tap target.
class CalendarMonthGrid extends StatelessWidget {
  final DateTime month;
  final DateTime today;
  final DateTime selectedDay;
  final Map<DateTime, List<CalendarEntry>> byDay;
  final Set<CalendarLayer> layers;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const CalendarMonthGrid({
    super.key,
    required this.month,
    required this.today,
    required this.selectedDay,
    required this.byDay,
    required this.layers,
    required this.onSelect,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = DateTime(month.year, month.month, 1);
    final leading = first.weekday - 1; // Monday first
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final rows = (leading + daysInMonth + 6) ~/ 7;
    final scaler = MediaQuery.textScalerOf(context);
    final numberBox = math.max(28.0, scaler.scale(14) * 1.2 + 6);
    // The markers grow with the text size too (up to 1.5x): a 12 px icon beside a 22 px day number is a speck.
    final markerScale = (scaler.scale(14) / 14).clamp(1.0, 1.5);
    final markerHeight = 14 * markerScale;
    final cellHeight = math.max(58.0, numberBox + markerHeight + 12);

    return GestureDetector(
      // A sideways flick steps the month; the vertical scroll of the page is untouched.
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v <= -250) {
          onNext();
        } else if (v >= 250) {
          onPrev();
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Semantics(
                    label: _weekdayNames[i],
                    excludeSemantics: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Center(
                        child: Text(
                          _weekdayNames[i].substring(0, 1),
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          for (var r = 0; r < rows; r++)
            Row(
              children: [
                for (var c = 0; c < 7; c++)
                  Builder(
                    builder: (context) {
                      final day = DateTime(month.year, month.month, 1 - leading + r * 7 + c);
                      return Expanded(
                        child: _DayCell(
                          day: day,
                          month: month,
                          today: today,
                          selected: day == selectedDay,
                          entries: byDay[day] ?? const [],
                          layers: layers,
                          height: cellHeight,
                          numberBox: numberBox,
                          markerScale: markerScale,
                          onTap: onSelect,
                        ),
                      );
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final DateTime day;
  final DateTime month;
  final DateTime today;
  final bool selected;
  final List<CalendarEntry> entries;
  final Set<CalendarLayer> layers;
  final double height;
  final double numberBox;
  final double markerScale;
  final ValueChanged<DateTime> onTap;

  const _DayCell({
    required this.day,
    required this.month,
    required this.today,
    required this.selected,
    required this.entries,
    required this.layers,
    required this.height,
    required this.numberBox,
    required this.markerScale,
    required this.onTap,
  });

  String _semanticLabel() {
    final parts = <String>[calendarLongDay(day)];
    if (day == today) parts.add('today');
    for (final layer in CalendarLayer.values) {
      if (!layers.contains(layer)) continue;
      final n = entries.where((e) => e.primaryLayer(layers) == layer).length;
      if (n == 0) continue;
      parts.add(switch (layer) {
        CalendarLayer.mine => '$n of my audit${n == 1 ? '' : 's'}',
        CalendarLayer.location => '$n audit${n == 1 ? '' : 's'} at my location',
        CalendarLayer.nc => '$n NC${n == 1 ? '' : 's'}',
      });
    }
    if (parts.length == 1 || (parts.length == 2 && day == today)) parts.add('nothing scheduled');
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inMonth = day.month == month.month && day.year == month.year;
    final isToday = day == today;
    final numberColor = isToday
        ? scheme.onPrimary
        : (inMonth ? scheme.onSurface : scheme.onSurfaceVariant.withValues(alpha: 0.6));

    return Semantics(
      button: true,
      selected: selected,
      label: _semanticLabel(),
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('calendar-day-${calendarDayKey(day)}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => onTap(day),
        child: Container(
          height: height,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer.withValues(alpha: 0.55) : null,
            border: selected ? Border.all(color: scheme.primary, width: 2) : null,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Today is a filled pill hugging the number (not stretched across the cell).
              ConstrainedBox(
                constraints: BoxConstraints(minWidth: 30, minHeight: numberBox),
                child: DecoratedBox(
                  decoration: isToday
                      ? BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(999))
                      : const BoxDecoration(),
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: Text(
                        '${day.day}',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: isToday || selected ? FontWeight.w800 : FontWeight.w500,
                          color: numberColor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 14 * markerScale,
                child: Opacity(
                  opacity: inMonth ? 1 : 0.55,
                  child: _Markers(entries: entries, layers: layers, scale: markerScale),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The marks under a day number: per layer that has something that day, its icon
/// coloured by the most pressing audit status (red for NCs), with the count when
/// more than one. Scaled down as a whole to fit a narrow cell.
class _Markers extends StatelessWidget {
  final List<CalendarEntry> entries;
  final Set<CalendarLayer> layers;
  final double scale;

  const _Markers({required this.entries, required this.layers, required this.scale});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final marks = <Widget>[];
    for (final layer in CalendarLayer.values) {
      if (!layers.contains(layer)) continue;
      final group = entries.where((e) => e.primaryLayer(layers) == layer).toList();
      if (group.isEmpty) continue;
      final status = mostUrgentStatus(group);
      final color = status == null ? layer.color(context) : calendarStatusColor(context, status);
      if (marks.isNotEmpty) marks.add(const SizedBox(width: 3));
      marks.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(layer.icon, size: 12 * scale, color: color),
            if (group.length > 1)
              Text(
                '${group.length}',
                textScaler: TextScaler.noScaling,
                style: TextStyle(fontSize: 10 * scale, fontWeight: FontWeight.w800, color: color, height: 1),
              ),
          ],
        ),
      );
    }
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(mainAxisSize: MainAxisSize.min, children: marks),
    );
  }
}

/// A small month-and-year chooser: the year steps, the twelve months are one tap
/// each (every button at least 44 px). Resolves to the 1st of the chosen month,
/// or null when dismissed.
Future<DateTime?> showCalendarMonthPicker(BuildContext context, {required DateTime month}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _MonthPickerDialog(initial: month),
  );
}

class _MonthPickerDialog extends StatefulWidget {
  final DateTime initial;

  const _MonthPickerDialog({required this.initial});

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late int _year = widget.initial.year;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous year',
                    onPressed: () => setState(() => _year--),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        '$_year',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next year',
                    onPressed: () => setState(() => _year++),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = (constraints.maxWidth - 16) / 3;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var m = 1; m <= 12; m++)
                        SizedBox(
                          width: width,
                          height: 48,
                          child: _MonthButton(
                            label: _monthNames[m - 1].substring(0, 3),
                            fullLabel: '${_monthNames[m - 1]} $_year',
                            selected: widget.initial.year == _year && widget.initial.month == m,
                            onTap: () => Navigator.of(context).pop(DateTime(_year, m, 1)),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: scheme.onSurfaceVariant),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonthButton extends StatelessWidget {
  final String label;
  final String fullLabel;
  final bool selected;
  final VoidCallback onTap;

  const _MonthButton({required this.label, required this.fullLabel, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: fullLabel,
      excludeSemantics: true,
      child: Material(
        color: selected ? scheme.primary : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.onPrimary : scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
