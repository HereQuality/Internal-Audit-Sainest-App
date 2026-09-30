import '../../models/audit_model.dart';

/// core/utils/audit_status.dart
/// ─────────────────────────────
/// The unified audit-status vocabulary the owner asked every screen to show
/// (Not Started → In Progress → Overdue → Delayed / On-Time Completed → NC
/// Response Pending → NC Verification Pending → Total Closed), and the small
/// pure helpers the list screens share around it.
///
/// The SERVER decides which status an audit is in (`displayStatus`,
/// `timeliness`, `batchDisplayStatus` — see AuditModel); nothing in here
/// derives one. This file only names the labels and answers "does this audit
/// match that filter chip" over the values the server already sent.
class AuditStatus {
  AuditStatus._();

  static const notStarted = 'Not Started';
  static const inProgress = 'In Progress';
  static const overdue = 'Overdue';
  static const delayedCompleted = 'Delayed Completed';
  static const onTimeCompleted = 'On-Time Completed';
  static const ncResponsePending = 'NC Response Pending';
  static const ncVerificationPending = 'NC Verification Pending';
  static const totalClosed = 'Total Closed';

  // The two non-pipeline states that still exist on an audit.
  static const draft = 'Draft';
  static const skipped = 'Skipped';

  // A repeat whose window closed without it ever being done — a `displayStatus`
  // the server sends but that is not one of the eight pipeline chips. Never a
  // real audit to grade: the Final Report's Total Audits leaves it out and its
  // score is "—" (owner, 2026-09-30).
  static const notAttempted = 'Not Attempted';

  // The stored status of an audit its auditor has finished, whatever its NC
  // stage — the raw `status`, kept as a filter value for the Final Report
  // list's default view (which must keep showing every finished audit).
  static const completed = 'Completed';

  /// The eight pipeline labels in the order the owner listed them — also the
  /// dashboard tile order and the filter chip order.
  static const pipeline = [
    notStarted,
    inProgress,
    overdue,
    delayedCompleted,
    onTimeCompleted,
    ncResponsePending,
    ncVerificationPending,
    totalClosed,
  ];

  /// Not a `displayStatus` (an audit that finished late is shown by its NC
  /// stage, see the status contract) but the `timeliness` value of a
  /// stored-Completed audit — a filter / tile meaning "finished on time /
  /// late, whatever its NC stage".
  static bool isTimeliness(String label) =>
      label == delayedCompleted || label == onTimeCompleted;

  /// The three post-completion stages — the ones a completed audit is in,
  /// which together always account for the same audits as the two timeliness
  /// labels.
  static bool isNcStage(String label) =>
      label == ncResponsePending ||
      label == ncVerificationPending ||
      label == totalClosed;
}

/// "All" plus the eight statuses — the audit list's filter chips.
///
/// Draft is deliberately absent (same reasoning MyAuditsScreen always had:
/// the row is for triaging ACTIVE work; a Draft still shows under "All") and
/// so is Skipped, which /audits/mine never returns.
const auditStatusFilterOptions = ['All', ...AuditStatus.pipeline];

/// Whether [audit] belongs under the status chip [filter].
///
///  * 'All' matches everything.
///  * 'On-Time Completed' / 'Delayed Completed' match the audits the server
///    gave that `timeliness` — at ANY NC stage, so a late audit still waiting
///    on NC responses is under Delayed Completed AND under NC Response
///    Pending. No client-side gate on top (say, "and stored status is
///    Completed"): the server sends a timeliness for exactly the audits its
///    auditor has completed, which is what makes the two timeliness tiles add
///    up to the three NC-stage tiles — a second rule here could only make the
///    list disagree with the tile it was opened from.
///  * 'Completed' (legacy) matches every stored-Completed audit — the Final
///    Report list's default. Gated on the raw `status` on purpose.
///  * everything else (Not Started, In Progress, Overdue, the NC stages,
///    Total Closed, Draft, Skipped) matches the label the badge shows — the
///    server's `displayStatus`, falling back to the raw `status` for an
///    older server (so Not Started / In Progress keep working there, and the
///    labels an old server cannot express simply match nothing).
bool auditMatchesStatusFilter(AuditModel audit, String filter) {
  if (filter == 'All') return true;
  if (AuditStatus.isTimeliness(filter)) {
    return audit.timeliness == filter;
  }
  if (filter == AuditStatus.completed) {
    return audit.status == AuditStatus.completed;
  }
  return audit.displayLabel == filter;
}

/// Headline of the "nothing under this chip" empty state. Reads for every
/// label the chips can hold: "No audits are Overdue", "No audits are Not
/// Started", "No audits are NC Response Pending".
String auditStatusEmptyTitle(String filter) => 'No audits are $filter';

/// The one status a multi-zone batch's parent row shows.
///
/// The server aggregates it over EVERY zone of the batch (including ones this
/// employee is not on) and stamps it on each zone as `batchDisplayStatus`, so
/// the first zone that carries it is the answer. Only when none does (an
/// older server) does the old client rule apply: the zones' own labels if
/// they all agree, else "Mixed" — a label that no longer exists on a current
/// server, where this branch is unreachable.
String auditGroupStatus(List<AuditModel> members) {
  for (final m in members) {
    final b = m.batchDisplayStatus;
    if (b != null && b.isNotEmpty) return b;
  }
  final first = members.first.displayLabel;
  return members.every((m) => m.displayLabel == first) ? first : 'Mixed';
}

/// The batch's timeliness ("On-Time Completed" / "Delayed Completed"), set by
/// the server only once every zone is completed; null before that and on an
/// older server.
String? auditGroupTimeliness(List<AuditModel> members) {
  for (final m in members) {
    final t = m.batchTimeliness;
    if (t != null && t.isNotEmpty) return t;
  }
  return null;
}
