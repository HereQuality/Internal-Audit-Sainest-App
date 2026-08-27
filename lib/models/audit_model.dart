class AuditeeInfo {
  final String? name;
  final String? profilePic;

  const AuditeeInfo({this.name, this.profilePic});

  factory AuditeeInfo.fromJson(dynamic json) {
    if (json is Map) {
      return AuditeeInfo(
        name: json['employeeName']?.toString(),
        profilePic: json['profilePic']?.toString(),
      );
    }
    return const AuditeeInfo();
  }
}

// Where the audit is actually happening — locationIds (Area/Zone/SubZone)
// and departmentIds are two independent scope arrays server-side (see
// models/Audit.js), so this joins whichever of them are populated into one
// display string, e.g. "Zone A, Zone B" or "Zone A, Warehouse Dept" — this
// is what tells an auditor which physical place/team an audit card is for,
// which the (usually-empty, see Audit.js#auditeeId's own comment on why)
// auditee field never reliably does.
String _locationLabel(dynamic json) {
  final labels = <String>[];
  if (json['locationIds'] is List) {
    for (final l in (json['locationIds'] as List).whereType<Map>()) {
      final name = l['name']?.toString();
      if (name != null && name.isNotEmpty) labels.add(name);
    }
  }
  if (json['departmentIds'] is List) {
    for (final d in (json['departmentIds'] as List).whereType<Map>()) {
      final name = d['departmentName']?.toString();
      if (name != null && name.isNotEmpty) labels.add(name);
    }
  }
  return labels.join(', ');
}

class AuditModel {
  final String id;
  final String title;
  final String scope;
  final String status; // Scheduled | In Progress | Completed
  final DateTime? scheduledDate;
  final DateTime? scheduledEndDate;
  final DateTime? completedDate;
  final AuditeeInfo auditee;
  final String location;
  // scoreResult.percentage, same field CompletedAudits.jsx reads for its
  // "Show Report" list row's score column — null until fully scored.
  final double? scorePercentage;
  // scoreResult.achieved/maxPossible — needed alongside the pre-computed
  // percentage above to combine several zones of the same batch into one
  // sum-then-divide percentage (ReportsScreen's batch card), never an
  // average of each zone's own %, same rule every other multi-audit
  // rollup in this app uses (see pages/CompletedAudits.jsx#batchScore).
  final double? scoreAchieved;
  final double? scoreMax;
  final List<String> auditorNames;
  // A multi-zone Schedule/Frequency Audit submission creates one separate
  // Audit document per zone, all sharing this same id (see
  // server/controllers/audit.controller.js#createAudit and the web app's
  // pages/CompletedAudits.jsx#batchGroups) — null for a single-zone audit.
  // When this employee is personally assigned to more than one zone of the
  // same batch, /audits/mine returns each of those zones as its own
  // AuditModel; ReportsScreen groups them back into one expandable card by
  // this field, same idea as the web Final Report page's own grouping.
  final String? scheduleBatchId;
  // "same" | "per-location" — mirrors the web app's identical field
  // (models/Audit.js#structureMode). locationIds.length at parse time —
  // together these tell ReportsScreen whether this single audit document
  // is actually spread across several zones (locationParameters), same
  // idea as scheduleBatchId's separate-documents case above, just a
  // single document splitting its own tree internally instead.
  //
  // Deliberately locationIds only, NOT also departmentIds (unlike
  // _locationLabel's display string above, which joins both) —
  // AuditDetailModel only ever parses locationParameters, never
  // departmentParameters (models/audit_detail_model.dart has no
  // department fields at all yet), so a department-scoped per-location
  // audit's own zone breakdown can't actually be computed client-side
  // right now. Leaving this locationIds-only means such an audit still
  // renders as a plain card instead of an expand that would show one
  // fake "zone" with no real score, until that gap is closed.
  final String structureMode;
  final int locationCount;
  bool get hasMultipleZones => structureMode == 'per-location' && locationCount > 1;

  const AuditModel({
    required this.id,
    required this.title,
    required this.scope,
    required this.status,
    this.scheduledDate,
    this.scheduledEndDate,
    this.completedDate,
    this.auditee = const AuditeeInfo(),
    this.location = '',
    this.scorePercentage,
    this.scoreAchieved,
    this.scoreMax,
    this.auditorNames = const [],
    this.scheduleBatchId,
    this.structureMode = 'same',
    this.locationCount = 0,
  });

  factory AuditModel.fromJson(Map<String, dynamic> json) {
    final scoreResult = json['scoreResult'];
    final rawBatchId = json['scheduleBatchId'];
    final locIds = json['locationIds'];
    return AuditModel(
      id: (json['_id'] ?? '').toString(),
      title: json['title']?.toString() ?? 'Untitled Audit',
      scope: json['scope']?.toString() ?? '',
      status: json['status']?.toString() ?? 'Scheduled',
      scheduledDate: DateTime.tryParse(json['scheduledDate']?.toString() ?? ''),
      scheduledEndDate: DateTime.tryParse(json['scheduledEndDate']?.toString() ?? ''),
      completedDate: DateTime.tryParse(json['completedDate']?.toString() ?? ''),
      auditee: AuditeeInfo.fromJson(json['auditeeId']),
      location: _locationLabel(json),
      scorePercentage: scoreResult is Map ? (scoreResult['percentage'] as num?)?.toDouble() : null,
      scoreAchieved: scoreResult is Map ? (scoreResult['achieved'] as num?)?.toDouble() : null,
      scoreMax: scoreResult is Map ? (scoreResult['maxPossible'] as num?)?.toDouble() : null,
      auditorNames: (json['auditorIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e['employeeName']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      scheduleBatchId: rawBatchId == null ? null : (rawBatchId is Map ? rawBatchId['_id'] : rawBatchId)?.toString(),
      structureMode: json['structureMode']?.toString() ?? 'same',
      locationCount: locIds is List ? locIds.length : 0,
    );
  }
}

class AuditorStats {
  final int assignedAudits;
  final int inProgress;
  final int ncPending;
  final int completed;
  // This auditor's own ATS/OTC — based on THEIR audits' Start/Due/Completed
  // dates (server/controllers/audit.controller.js#getAuditorStats ->
  // computeAuditAtsScore/computeAuditOtcRate), same fields the web app's
  // AuditorDashboard.jsx reads off this identical endpoint for its
  // Performance Scorecard. NOT the NC-closure-based ATS/OTC (that's
  // AuditeeStats, a different GET /ncs/ats-summary metric for how well
  // someone responds to NCs raised against them).
  final double? auditAtsScore;
  final double? auditOtcScore;

  const AuditorStats({
    this.assignedAudits = 0,
    this.inProgress = 0,
    this.ncPending = 0,
    this.completed = 0,
    this.auditAtsScore,
    this.auditOtcScore,
  });

  factory AuditorStats.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    return AuditorStats(
      assignedAudits: asInt(json['assignedAudits']),
      inProgress: asInt(json['inProgress']),
      ncPending: asInt(json['ncPending']),
      completed: asInt(json['completed']),
      auditAtsScore: (json['auditAtsScore'] as num?)?.toDouble(),
      auditOtcScore: (json['auditOtcScore'] as num?)?.toDouble(),
    );
  }
}
