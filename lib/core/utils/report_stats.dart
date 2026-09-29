import '../../models/audit_model.dart';
import 'audit_status.dart';

/// The four Final Report tiles: cumulative Total Score, Total Audits,
/// On-Time Completed and Delayed Completed — the same figures the web's
/// Final Report tiles show (GET /audits/stats/completed, server:
/// audit.controller.js#getCompletedAuditStats).
class ReportStats {
  /// Σ achieved / Σ possible over every audit in view, as a whole percent —
  /// NEVER an average of each audit's own percentage. Includes a still-open
  /// audit's own scoring progress so far (server: audit.controller.js#
  /// getCompletedAuditStats' isPartial), a Skipped one excluded either way.
  /// Null while nothing at all has been scored yet.
  final int? percentage;
  final double achieved;
  final double maxPossible;
  /// Whether [percentage] includes anything not yet fully finished — the "*"
  /// a row's own partial score already carries (reports_screen.dart).
  final bool isPartial;

  /// Audits listed (a bundle counts once, like the table's rows).
  final int totalAudits;

  /// Finished audits by timeliness (a bundle is Delayed if any zone was late).
  final int onTimeCompleted;
  final int delayedCompleted;

  const ReportStats({
    this.percentage,
    this.achieved = 0,
    this.maxPossible = 0,
    this.isPartial = false,
    this.totalAudits = 0,
    this.onTimeCompleted = 0,
    this.delayedCompleted = 0,
  });

  /// Reads the server's `data` object. Null for anything that isn't one (an
  /// older server, a role without Final Report access answering an error) so
  /// the caller can fall back to [ReportStats.fromAudits].
  static ReportStats? tryParse(dynamic data) {
    if (data is! Map) return null;
    double num0(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
    int int0(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    final pct = data['percentage'];
    return ReportStats(
      percentage: pct is num ? pct.round() : null,
      achieved: num0(data['achieved']),
      maxPossible: num0(data['maxPossible']),
      isPartial: data['isPartial'] == true,
      totalAudits: int0(data['totalAudits'] ?? data['total']),
      onTimeCompleted: int0(data['onTimeCompleted']),
      delayedCompleted: int0(data['delayedCompleted']),
    );
  }

  /// The same numbers worked out from the audits already loaded — the
  /// fallback when the stats endpoint isn't reachable for this role, and what
  /// keeps the tiles honest for exactly the rows on screen. Bundles (same
  /// scheduleBatchId, more than one visible) count once. Every group's own
  /// scored-so-far achieved/max counts (a Skipped member excluded, mirroring
  /// the server's own rule) even while it is not yet finished — [isPartial]
  /// then says so, same as the server's own field.
  factory ReportStats.fromAudits(List<AuditModel> audits) {
    final groups = <String, List<AuditModel>>{};
    for (final a in audits) {
      final key = a.scheduleBatchId != null ? 'b:${a.scheduleBatchId}' : 's:${a.id}';
      groups.putIfAbsent(key, () => []).add(a);
    }
    var achieved = 0.0;
    var max = 0.0;
    var onTime = 0;
    var delayed = 0;
    var anyUnfinishedScored = false;
    for (final members in groups.values) {
      final finished = members.every((m) => m.status == AuditStatus.completed);
      final live = members.where((m) => m.status != AuditStatus.skipped && m.status != AuditStatus.draft);
      final groupMax = live.fold<double>(0, (sum, m) => sum + (m.scoreMax ?? 0));
      if (!finished && groupMax > 0) anyUnfinishedScored = true;
      for (final m in live) {
        achieved += m.scoreAchieved ?? 0;
        max += m.scoreMax ?? 0;
      }
      if (!finished) continue;
      final timeliness = auditGroupTimeliness(members) ??
          (members.any((m) => m.timeliness == AuditStatus.delayedCompleted)
              ? AuditStatus.delayedCompleted
              : members.every((m) => m.timeliness == AuditStatus.onTimeCompleted)
                  ? AuditStatus.onTimeCompleted
                  : null);
      if (timeliness == AuditStatus.delayedCompleted) {
        delayed++;
      } else if (timeliness == AuditStatus.onTimeCompleted) {
        onTime++;
      }
    }
    return ReportStats(
      percentage: max > 0 ? (achieved / max * 100).round() : null,
      achieved: achieved,
      maxPossible: max,
      isPartial: anyUnfinishedScored,
      totalAudits: groups.length,
      onTimeCompleted: onTime,
      delayedCompleted: delayed,
    );
  }
}
