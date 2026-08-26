/// Auditee-side NC tallies — GET /ncs/ats-summary (nc.controller.js
/// #getAtsSummary/#computeNcBuckets), same source the web app's
/// Auditee.jsx dashboard tiles use.
class AuditeeStats {
  final int total;
  final int onTime;
  final int delayed;
  final int overdue;
  final int inProgress;
  final int pendingApproval;
  // Overall blended score (Completion Rate 40% + OTC 40% + Task Quality
  // 20%, server/controllers/nc.controller.js#computeOverallAts) — the
  // one number the web app's Auditee.jsx leads with.
  final double? score;
  // ATS ("Action Taken Speed") — average of each closed NC's own
  // planned-vs-actual turnaround (computeActionTakenSpeed).
  final double? atsScore;
  // OTC ("On-Time-Completion") — % of closed NCs that closed on/before
  // their target date (computeOtcRate).
  final double? otcScore;

  const AuditeeStats({
    this.total = 0,
    this.onTime = 0,
    this.delayed = 0,
    this.overdue = 0,
    this.inProgress = 0,
    this.pendingApproval = 0,
    this.score,
    this.atsScore,
    this.otcScore,
  });

  factory AuditeeStats.fromJson(Map<String, dynamic> json) {
    return AuditeeStats(
      total: (json['total'] as num?)?.toInt() ?? 0,
      onTime: (json['onTime'] as num?)?.toInt() ?? 0,
      delayed: (json['delayed'] as num?)?.toInt() ?? 0,
      overdue: (json['overdue'] as num?)?.toInt() ?? 0,
      inProgress: (json['inProgress'] as num?)?.toInt() ?? 0,
      pendingApproval: (json['pendingApproval'] as num?)?.toInt() ?? 0,
      score: (json['score'] as num?)?.toDouble(),
      atsScore: (json['atsScore'] as num?)?.toDouble(),
      otcScore: (json['otcScore'] as num?)?.toDouble(),
    );
  }
}
