import '../../models/audit_model.dart';

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// Every calendar day an audit is actually live on — its own scheduledDate
// through scheduledEndDate inclusive, or just scheduledDate alone for a
// single-day audit (scheduledEndDate null). Capped at 60 days so a bad/
// bogus far-future end date can't blow up into thousands of events. Shared
// by the Auditor and Auditee calendar screens (auditor_calendar_screen.dart,
// auditee_calendar_screen.dart) so a multi-day audit reads as "live" on
// every one of its days on both, not just its start date.
const maxAuditRangeDays = 60;

List<DateTime> daysInAuditRange(AuditModel audit) {
  final start = dayOnly(audit.scheduledDate!);
  final end = audit.scheduledEndDate != null ? dayOnly(audit.scheduledEndDate!) : start;
  if (end.isBefore(start)) return [start];
  final days = <DateTime>[];
  var cursor = start;
  while (!cursor.isAfter(end) && days.length < maxAuditRangeDays) {
    days.add(cursor);
    cursor = cursor.add(const Duration(days: 1));
  }
  return days;
}
