/// lib/core/utils/nc_timeliness.dart
/// ────────────────────────────────────
/// Mirrors server/utils/dueDate.js (effectiveDeadline/computeTurnaroundRatio)
/// and server/utils/ncScoring.js#computeAtsScore exactly, so a verdict/ats
/// computed here for one NC never disagrees with what the server itself
/// would compute for that same NC. Pure date arithmetic, no I/O.
///
/// Every date is normalized to UTC before its calendar components (year/
/// month/day/hour/...) are read — same reasoning as dueDate.js's own
/// comment: server Date fields serialize to JSON with a 'Z' suffix, so
/// treating them as UTC here is what keeps "is this a bare calendar date"
/// and "which day is this" answered the same way on both sides, regardless
/// of the host device's own timezone.
library;

const _msPerDay = 24 * 60 * 60 * 1000;

// A "bare" calendar date (midnight, no real time-of-day) vs. one that
// deliberately carries an hour/minute — e.g. a due date set to "5pm today".
bool _hasTimeComponent(DateTime d) {
  final u = d.toUtc();
  return u.hour != 0 || u.minute != 0 || u.second != 0 || u.millisecond != 0 || u.microsecond != 0;
}

DateTime _startOfDayUtc(DateTime d) {
  final u = d.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

/// effectiveDeadline — the actual instant a due date expires.
///
/// A bare calendar date means "by end of that day": push to one
/// millisecond before the next UTC midnight, so anything finished later
/// that same day still reads as on time. A due date that DOES carry a real
/// time (e.g. "5pm today") means exactly that instant — nothing is pushed.
DateTime effectiveDeadline(DateTime targetDate) {
  if (_hasTimeComponent(targetDate)) return targetDate;
  return _startOfDayUtc(targetDate).add(const Duration(milliseconds: _msPerDay - 1));
}

/// computeTurnaroundRatio — the "planned ÷ actual" duration score, 0-100,
/// for something that finished LATE (caller is responsible for checking
/// completionDate > effectiveDeadline(targetDate) first — this doesn't
/// re-check on-time-ness itself).
///
///   Case 1 (targetDate carries real Hours & Minutes — not exactly midnight):
///     use full date+time for start/target/completion.
///   Case 2 (targetDate is a bare date — exactly midnight):
///     truncate start/target/completion to UTC midnight first, i.e.
///     compare dates only.
///   Then, in whichever unit case 1/2 leaves them in (days):
///     start != target:  (target - start) / (completion - start)
///     start == target:  1 / (completion - start)
///   ...× 100, clamped to [0, 100].
int computeTurnaroundRatio(DateTime startDate, DateTime targetDate, DateTime completionDate) {
  final dateOnly = !_hasTimeComponent(targetDate);
  final start = dateOnly ? _startOfDayUtc(startDate) : startDate;
  final targetForCalc = dateOnly ? _startOfDayUtc(targetDate) : targetDate;
  final actual = dateOnly ? _startOfDayUtc(completionDate) : completionDate;

  final plannedDays = targetForCalc.difference(start).inMilliseconds / _msPerDay;
  final actualDays = actual.difference(start).inMilliseconds / _msPerDay;
  if (actualDays <= 0) return 100; // date-only truncation collapsed onto/before start — nothing to penalize

  final raw = plannedDays != 0 ? (plannedDays / actualDays) * 100 : (1 / actualDays) * 100;
  return raw.clamp(0, 100).round();
}

enum NcTimelinessVerdict {
  onTime, // Completed at/before the effective deadline.
  delayed, // Completed after the effective deadline.
  overdue, // Not completed, and the effective deadline has already passed.
  inProgress, // Not completed, deadline hasn't arrived yet.
  unscored, // No startDate/targetDate to judge against at all.
}

class NcTimeliness {
  final NcTimelinessVerdict verdict;
  final int? ats; // null while inProgress/unscored — nothing to score yet.

  const NcTimeliness({required this.verdict, this.ats});
}

/// Mirrors server/utils/ncScoring.js#computeAtsScore's four-case branching
/// exactly (see that file's own doc comment for the case numbering this
/// follows) — S = startDate, T = targetDate, A = completionDate.
NcTimeliness computeNcTimeliness({
  required DateTime? startDate,
  required DateTime? targetDate,
  required DateTime? completionDate,
  DateTime? now,
}) {
  if (startDate == null || targetDate == null) {
    return const NcTimeliness(verdict: NcTimelinessVerdict.unscored);
  }
  final deadline = effectiveDeadline(targetDate);
  final clock = now ?? DateTime.now();

  if (completionDate == null) {
    return clock.isAfter(deadline)
        ? const NcTimeliness(verdict: NcTimelinessVerdict.overdue, ats: 0)
        : const NcTimeliness(verdict: NcTimelinessVerdict.inProgress);
  }

  if (!completionDate.isAfter(deadline)) {
    return const NcTimeliness(verdict: NcTimelinessVerdict.onTime, ats: 100);
  }

  return NcTimeliness(
    verdict: NcTimelinessVerdict.delayed,
    ats: computeTurnaroundRatio(startDate, targetDate, completionDate),
  );
}
