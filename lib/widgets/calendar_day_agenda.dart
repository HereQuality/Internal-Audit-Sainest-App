import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/calendar_entries.dart';
import '../models/audit_model.dart';
import '../models/nc_model.dart';
import 'calendar_layers.dart';
import 'month_calendar.dart' show calendarLongDay;
import 'status_badge.dart';

/// The heading of the day agenda under the grid: "Today · Tuesday 3 November
/// 2026" and how many items it holds (and how many the layer switches hide).
class CalendarDayHeader extends StatelessWidget {
  final DateTime day;
  final DateTime today;
  final int shown;
  final int hidden;

  const CalendarDayHeader({super.key, required this.day, required this.today, required this.shown, required this.hidden});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final summary = [
      if (shown > 0) '$shown ${shown == 1 ? 'item' : 'items'}',
      if (hidden > 0) '$hidden hidden by the switches above',
    ].join(' · ');
    return Semantics(
      header: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${day == today ? 'Today · ' : ''}${calendarLongDay(day)}',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            if (summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(summary, style: TextStyle(fontSize: 12.5, color: scheme.outline)),
              ),
          ],
        ),
      ),
    );
  }
}

/// What the agenda says when a day has nothing to list.
class CalendarDayEmpty extends StatelessWidget {
  /// Every layer is switched off.
  final bool allLayersOff;

  /// Entries exist that day but the switches hide them.
  final int hidden;
  final DateTime day;

  const CalendarDayEmpty({super.key, required this.allLayersOff, required this.hidden, required this.day});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final String title;
    final String subtitle;
    final IconData icon;
    if (allLayersOff) {
      title = 'Everything is switched off';
      subtitle = 'Turn on My audits, Audit at My Location or My NCs above to see what is on this day.';
      icon = Icons.visibility_off_outlined;
    } else if (hidden > 0) {
      title = 'Nothing shown this day';
      subtitle = '$hidden ${hidden == 1 ? 'item is' : 'items are'} hidden by the switches above.';
      icon = Icons.filter_list_off_outlined;
    } else {
      title = 'Nothing scheduled this day';
      subtitle = 'No audits or NCs on ${calendarLongDay(day)}.';
      icon = Icons.event_available_outlined;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        children: [
          Icon(icon, size: 40, color: scheme.outline),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// One row of the agenda: an audit card or an NC card.
class CalendarEntryCard extends StatelessWidget {
  final CalendarEntry entry;
  final DateTime today;
  final Set<CalendarLayer> layers;

  /// The signed-in employee — decides whether an NC is theirs to respond to.
  final String? selfEmployeeId;
  final ValueChanged<String> onOpenAudit;
  final ValueChanged<NcModel> onOpenNc;

  const CalendarEntryCard({
    super.key,
    required this.entry,
    required this.today,
    required this.layers,
    required this.selfEmployeeId,
    required this.onOpenAudit,
    required this.onOpenNc,
  });

  @override
  Widget build(BuildContext context) {
    return entry.isAudit
        ? CalendarAuditCard(entry: entry, layers: layers, onOpen: () => onOpenAudit(entry.audit!.id))
        : CalendarNcCard(entry: entry, today: today, selfEmployeeId: selfEmployeeId, onOpen: () => onOpenNc(entry.nc!));
  }
}

/// A small icon + text line of a card.
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool emphasise;

  const _InfoRow({required this.icon, required this.label, required this.value, this.emphasise = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: emphasise ? scheme.primary : scheme.outline),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  if (label.isNotEmpty) TextSpan(text: '$label ', style: TextStyle(color: scheme.outline)),
                  TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// A rounded tinted chip with an optional icon.
class _Chip extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;

  const _Chip({required this.label, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Flexible(
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The audit card: title, status, what it is to me (mine / at my location / I am
/// the auditee), when, WHO IS COMING first when it is not mine, the auditee (or
/// "Self") and where. Tapping opens the audit.
class CalendarAuditCard extends StatelessWidget {
  final CalendarEntry entry;
  final Set<CalendarLayer> layers;
  final VoidCallback onOpen;

  const CalendarAuditCard({super.key, required this.entry, required this.layers, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final AuditModel a = entry.audit!;
    final statusColor = calendarStatusColor(context, a.displayLabel);
    final frequency = (a.frequency ?? '').trim();
    final repeating = a.isRecurring || frequency.isNotEmpty;
    final auditors = a.auditorNames.isEmpty ? '—' : a.auditorNames.join(', ');
    final note = a.selfAuditNote;
    final hasTimeliness = TimelinessPill.shortLabel(a.timeliness) != null;

    final when = _InfoRow(
      icon: Icons.event_outlined,
      label: '',
      value: entry.isMultiDay
          ? '${calendarRangeLabel(a.scheduledDate!, a.scheduledEndDate)} · day ${entry.dayNumber} of ${entry.dayCount}'
          : calendarRangeLabel(a.scheduledDate!, a.scheduledEndDate),
    );
    final who = _InfoRow(
      icon: Icons.person_outline,
      label: entry.isOthers ? 'Coming to audit:' : 'Auditor${a.auditorNames.length == 1 ? '' : 's'}:',
      value: auditors,
      emphasise: entry.isOthers,
    );
    // Like the web card, nothing is said about an auditee nobody has named yet (the auditor names
    // them when starting the audit) — and a self audit says "Self".
    final auditeeText = a.auditeeLabel(fallback: '');
    final auditee = auditeeText.isEmpty
        ? const SizedBox.shrink()
        : _InfoRow(icon: Icons.groups_outlined, label: 'Auditee:', value: auditeeText);
    final where = _InfoRow(
      icon: Icons.place_outlined,
      label: '',
      value: a.location.isNotEmpty ? a.location : 'No location set',
    );

    return Semantics(
      container: true,
      button: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: statusColor, width: 5))),
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    StatusBadge(label: a.displayLabel, color: AppColors.forAuditStatus(a.displayLabel)),
                    if (hasTimeliness) TimelinessPill(timeliness: a.timeliness),
                    ..._whoseChips(context),
                    if (a.auditType != null)
                      _Chip(label: a.auditType!, color: scheme.onSurfaceVariant, icon: Icons.category_outlined),
                    if (repeating)
                      _Chip(
                        label: [
                          if (frequency.isNotEmpty) frequency else 'Repeats',
                          if (a.occurrenceIndex != null && a.occurrenceCount != null)
                            '${a.occurrenceIndex} of ${a.occurrenceCount}',
                        ].join(' · '),
                        color: scheme.onSurfaceVariant,
                        icon: Icons.repeat,
                      ),
                  ],
                ),
                if (a.scope.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      a.scope.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                    ),
                  ),
                // Somebody else's audit at my place: who is coming leads, because that is
                // the question being asked. My own audit leads with when and where.
                if (entry.isOthers) ...[who, when, auditee, where] else ...[when, where, who, auditee],
                if (note.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 24),
                    child: Text(note, style: TextStyle(fontSize: 12, color: scheme.outline)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The "whose is this" chips: one per layer the audit belongs to that is on
  /// (mine / at my location), and the auditee mark.
  List<Widget> _whoseChips(BuildContext context) {
    final mine = CalendarLayer.mine;
    final loc = CalendarLayer.location;
    final chips = <Widget>[];
    if (entry.isMine && entry.atMyLocation) {
      chips.add(_Chip(label: 'At my location — your audit', color: loc.color(context), icon: loc.icon));
    } else if (entry.isMine) {
      chips.add(_Chip(label: 'My audit', color: mine.color(context), icon: mine.icon));
    } else if (entry.iAmAuditee) {
      chips.add(_Chip(
        label: 'At my location — you are the auditee',
        color: loc.color(context),
        icon: Icons.how_to_reg_outlined,
      ));
    } else {
      chips.add(_Chip(label: 'Not yours — at my location', color: loc.color(context), icon: loc.icon));
    }
    if (entry.isMine && entry.iAmAuditee) {
      chips.add(_Chip(label: 'You are the auditee', color: loc.color(context), icon: Icons.how_to_reg_outlined));
    }
    return chips;
  }
}

/// The NC card: id and status, title, the raised and due dates, the audit it came
/// from, who raised it, and the action — Respond (it is waiting for my answer),
/// Review (a response is waiting for review) or View. Tapping the card does the same.
class CalendarNcCard extends StatelessWidget {
  final CalendarEntry entry;
  final DateTime today;
  final String? selfEmployeeId;
  final VoidCallback onOpen;

  const CalendarNcCard({
    super.key,
    required this.entry,
    required this.today,
    required this.selfEmployeeId,
    required this.onOpen,
  });

  /// Respond only when it is waiting for an answer AND is mine to answer (the server
  /// enforces the same); another person's NC (All Members) is only viewed.
  static bool canRespond(NcModel nc, String? selfEmployeeId) =>
      nc.status == 'Raised' && (selfEmployeeId == null || nc.auditee.id == selfEmployeeId);

  static String actionLabel(NcModel nc, String? selfEmployeeId) {
    if (canRespond(nc, selfEmployeeId)) return 'Respond';
    if (nc.status == 'Response Submitted' || nc.status == 'Verification') return 'Review';
    return 'View';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final NcModel nc = entry.nc!;
    final red = CalendarLayer.nc.color(context);
    final isDue = entry.kind == CalendarEntryKind.ncDue;
    final overdue = isDue && entry.day.isBefore(today) && nc.status != 'Closed';
    final action = actionLabel(nc, selfEmployeeId);
    String date(DateTime? d) => d == null ? '—' : calendarRangeLabel(d.toLocal());

    return Semantics(
      container: true,
      button: true,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: red, width: 5))),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(CalendarLayer.nc.icon, size: 16, color: red),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        nc.ncId.isEmpty ? 'Non-conformance' : nc.ncId,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: red),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  nc.title.isEmpty ? 'Untitled NC' : nc.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
                    _Chip(
                      label: isDue ? (entry.day == today ? 'Due today' : 'Due this day') : 'Raised this day',
                      color: red,
                      icon: isDue ? Icons.flag_outlined : Icons.add_alert_outlined,
                    ),
                    if (overdue) _Chip(label: 'Overdue', color: AppColors.readable(context, AppColors.red)),
                    _Chip(label: '${nc.severity} flag', color: scheme.onSurfaceVariant),
                  ],
                ),
                _InfoRow(icon: Icons.event_outlined, label: 'Raised', value: date(nc.startDate)),
                _InfoRow(icon: Icons.flag_outlined, label: 'Due', value: date(nc.targetDate), emphasise: isDue),
                if (nc.auditTitle.isNotEmpty)
                  _InfoRow(icon: Icons.assignment_outlined, label: 'Audit:', value: nc.auditTitle),
                if (nc.raisedBy.name.isNotEmpty && nc.raisedBy.name != 'Unknown')
                  _InfoRow(icon: Icons.person_outline, label: 'Raised by:', value: nc.raisedBy.name),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: onOpen,
                    icon: Icon(action == 'Respond' ? Icons.reply_outlined : Icons.visibility_outlined, size: 18),
                    label: Text(action),
                    style: FilledButton.styleFrom(minimumSize: const Size(44, 44)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
