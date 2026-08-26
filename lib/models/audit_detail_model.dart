import 'nc_model.dart';

/// Full-detail audit — the scoring workspace's own model, separate from
/// the lightweight AuditModel used by the My Audits list. Mirrors
/// server/models/Audit.js#AuditNodeSchema and the audit document shape
/// returned by GET /audits/:id (server/controllers/audit.controller.js
/// #getAuditDetails) — same endpoint the web app's AuditReportDetail.jsx
/// reads.
class ParameterNode {
  final String id;
  final String name;
  final double? weight;
  // Weightage-mode-only "how much this leaf counts toward the overall %"
  // (models/Audit.js — separate from `weight`, which bounds the leaf's OWN
  // score). Falls back to `weight` (then 1) when unset — see leafWeightage
  // in AuditReportShared.jsx, mirrored by ReportPdfBuilder.leafWeightage.
  final double? weightage;
  final String? findingType; // "Strong Compliance" | "Compliance" | "OFI" | "NC" | null
  final double? score;
  final String? remark;
  final List<String> photoUrls;
  final String? ncId;
  final List<ParameterNode> children;

  const ParameterNode({
    required this.id,
    required this.name,
    this.weight,
    this.weightage,
    this.findingType,
    this.score,
    this.remark,
    this.photoUrls = const [],
    this.ncId,
    this.children = const [],
  });

  bool get isLeaf => children.isEmpty;

  /// Round-trips a node back to the server's own shape — needed because
  /// PATCH /audits/:id/save-draft replaces the WHOLE `parameters` array
  /// (server/controllers/audit.controller.js#applyAuditFields does a
  /// direct field assign, not a tree merge), same as the web app's own
  /// InstantAudit.jsx#handleAddCheckpoint. Sending back every existing
  /// node's current state (including `_id`, so Mongoose keeps its
  /// identity instead of minting a new one) is what stops "add one
  /// checkpoint" from silently wiping out every checkpoint already
  /// scored. Omit `_id` entirely for a brand-new node — Mongoose assigns
  /// one on save.
  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) '_id': id,
        'name': name,
        'weight': weight,
        'weightage': weightage,
        'findingType': findingType,
        'score': score,
        'remark': remark,
        'photoUrls': photoUrls,
        'ncId': ncId,
        'children': children.map((c) => c.toJson()).toList(),
      };

  factory ParameterNode.fromJson(Map<String, dynamic> json) {
    return ParameterNode(
      id: (json['_id'] ?? '').toString(),
      name: json['name']?.toString() ?? '',
      weight: (json['weight'] as num?)?.toDouble(),
      weightage: (json['weightage'] as num?)?.toDouble(),
      findingType: json['findingType']?.toString(),
      score: (json['score'] as num?)?.toDouble(),
      remark: json['remark']?.toString(),
      photoUrls: (json['photoUrls'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      ncId: json['ncId']?.toString(),
      children: (json['children'] as List? ?? [])
          .whereType<Map>()
          .map((e) => ParameterNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

class LocationLabel {
  final String id;
  final String name;
  final String? code;

  const LocationLabel({required this.id, required this.name, this.code});

  String get display => code != null && code!.isNotEmpty ? '$name ($code)' : name;

  factory LocationLabel.fromJson(Map<String, dynamic> json) {
    return LocationLabel(
      id: (json['_id'] ?? '').toString(),
      name: json['name']?.toString() ?? 'Location',
      code: json['code']?.toString(),
    );
  }
}

class LocationParameterGroup {
  final String locationId;
  final List<ParameterNode> parameters;

  const LocationParameterGroup({required this.locationId, required this.parameters});

  /// See ParameterNode.toJson's doc comment — same "send back the whole
  /// thing" requirement applies per-location here.
  Map<String, dynamic> toJson() => {
        'locationId': locationId,
        'parameters': parameters.map((p) => p.toJson()).toList(),
      };

  factory LocationParameterGroup.fromJson(Map<String, dynamic> json) {
    return LocationParameterGroup(
      locationId: (json['locationId'] is Map ? json['locationId']['_id'] : json['locationId'])?.toString() ?? '',
      parameters: (json['parameters'] as List? ?? [])
          .whereType<Map>()
          .map((e) => ParameterNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// Department is a separate collection from Location (models/Department.js)
/// — a parallel sibling to LocationLabel/LocationParameterGroup above, same
/// as server/models/Audit.js#departmentIds/departmentParameters being a
/// parallel pair to locationIds/locationParameters rather than folded in.
class DepartmentLabel {
  final String id;
  final String name;
  final String? code;

  const DepartmentLabel({required this.id, required this.name, this.code});

  String get display => code != null && code!.isNotEmpty ? '$name ($code)' : name;

  factory DepartmentLabel.fromJson(Map<String, dynamic> json) {
    return DepartmentLabel(
      id: (json['_id'] ?? '').toString(),
      name: json['departmentName']?.toString() ?? 'Department',
      code: json['departmentCode']?.toString(),
    );
  }
}

class DepartmentParameterGroup {
  final String departmentId;
  final List<ParameterNode> parameters;

  const DepartmentParameterGroup({required this.departmentId, required this.parameters});

  /// See ParameterNode.toJson's doc comment — same "send back the whole
  /// thing" requirement applies per-department here.
  Map<String, dynamic> toJson() => {
        'departmentId': departmentId,
        'parameters': parameters.map((p) => p.toJson()).toList(),
      };

  factory DepartmentParameterGroup.fromJson(Map<String, dynamic> json) {
    return DepartmentParameterGroup(
      departmentId: (json['departmentId'] is Map ? json['departmentId']['_id'] : json['departmentId'])?.toString() ?? '',
      parameters: (json['parameters'] as List? ?? [])
          .whereType<Map>()
          .map((e) => ParameterNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// One scoped hand-out — same shape as models/Audit.js#assignments; only
/// ever set once distributionMode is "location" or "parameter".
class AuditAssignment {
  final String scopeType; // "location" | "parameter"
  final String? locationId;
  final String? parameterNodeId;
  final String auditorId;

  const AuditAssignment({required this.scopeType, this.locationId, this.parameterNodeId, required this.auditorId});

  factory AuditAssignment.fromJson(Map<String, dynamic> json) {
    dynamic idOf(dynamic v) => v is Map ? v['_id'] : v;
    return AuditAssignment(
      scopeType: json['scopeType']?.toString() ?? 'location',
      locationId: idOf(json['locationId'])?.toString(),
      parameterNodeId: json['parameterNodeId']?.toString(),
      auditorId: idOf(json['auditorId'])?.toString() ?? '',
    );
  }
}

class AuditScoreResult {
  final double achieved;
  final double maxPossible;
  final double? percentage;
  final int scoredCount;
  final int leafCount;
  final bool isFullyScored;

  const AuditScoreResult({
    this.achieved = 0,
    this.maxPossible = 0,
    this.percentage,
    this.scoredCount = 0,
    this.leafCount = 0,
    this.isFullyScored = false,
  });

  factory AuditScoreResult.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AuditScoreResult();
    return AuditScoreResult(
      achieved: (json['achieved'] as num?)?.toDouble() ?? 0,
      maxPossible: (json['maxPossible'] as num?)?.toDouble() ?? 0,
      percentage: (json['percentage'] as num?)?.toDouble(),
      scoredCount: (json['scoredCount'] as num?)?.toInt() ?? 0,
      leafCount: (json['leafCount'] as num?)?.toInt() ?? 0,
      isFullyScored: json['isFullyScored'] as bool? ?? false,
    );
  }
}

class AuditDetailModel {
  final String id;
  final String title;
  final String scope;
  final String status;
  final String scoringSystem; // "normal" | "weightage"
  final String structureMode; // "same" | "per-location"
  final String distributionMode; // "whole" | "location" | "parameter" — legacy, unused by new audits
  final bool isDistributed; // legacy, unused by new audits
  final bool isSelfAudit;
  final DateTime? scheduledDate;
  // true when scheduledDate is still in the future — scoring/evidence
  // upload is server-blocked until then (audit.controller.js's
  // isBeforeScheduledDate), Instant Audits exempt.
  final bool scheduledInFuture;
  // An Instant Audit stays in "Draft" status for its whole build-and-score
  // life (server forces this on every save) — screens that gate scoring on
  // status (this app reuses one screen for every audit type, unlike the
  // web app's dedicated InstantAudit.jsx) need to know to treat Draft as
  // active for THIS one audit type. See audit.controller.js#getAuditDetails.
  final bool isInstant;
  // Set via the mandatory "select representative auditee" step (see
  // AuditsProvider.setAuditRepresentative) — a default for who this
  // location's findings are raised against, not a hard restriction (the
  // per-NC picker still offers every location member). Null for a
  // Self Audit (never asked/needed) or an audit not yet gated through
  // that step.
  final String? auditeeId;
  final String? auditeeName;
  // The representative picker now allows more than one — these are the
  // source of truth going forward; auditeeId/auditeeName above are kept
  // as a same-value (first-entry) fallback for a record predating that
  // change, same convention models/Audit.js#auditeeIds documents.
  final List<String> auditeeIds;
  final List<String> auditeeNames;
  final List<String> auditorIds;
  // Populated alongside auditorIds (server populates "employeeName
  // profilePic") — kept as a parallel display-name list rather than
  // reshaping auditorIds itself, since scoreCheckpoint/other call sites
  // still expect auditorIds as plain id strings.
  final List<String> auditorNames;
  final DateTime? scheduledEndDate;
  final DateTime? completedDate;
  final String? finalAuditorRemark;
  // Weightage-mode-only overall scale a leaf's Weightage is normalized
  // against (models/Audit.js#maxScore) — falls back to 10 when unset, same
  // as AuditFullReport.jsx's own scoreScale fallback.
  final double? maxScore;
  final String? plannedByEmployeeId;
  final List<ParameterNode> parameters;
  final List<LocationParameterGroup> locationParameters;
  final List<LocationLabel> locationLabels;
  // CFT audits' department-scoped sibling to locationParameters/
  // locationLabels above — see DepartmentParameterGroup's doc comment.
  final List<DepartmentParameterGroup> departmentParameters;
  final List<DepartmentLabel> departmentLabels;
  final List<AuditAssignment> assignments;
  final AuditScoreResult scoreResult;
  // Full NC documents, not just id+status — GET /audits/:id already
  // returns the same shape NcModel.fromJson parses everywhere else
  // (auditId just comes back unpopulated/absent here, which
  // NcModel.fromJson already degrades gracefully for).
  final List<NcModel> ncs;
  // "full" (everything) or "scoped" (this viewer's own assigned slice
  // only) — see audit.controller.js#getAuditDetails; parameters/
  // locationParameters/ncs above are already narrowed server-side when
  // this is "scoped", not filtered again on the client.
  final String accessLevel;

  const AuditDetailModel({
    required this.id,
    required this.title,
    required this.scope,
    required this.status,
    required this.scoringSystem,
    required this.structureMode,
    required this.distributionMode,
    required this.isDistributed,
    this.isSelfAudit = false,
    this.scheduledDate,
    this.scheduledInFuture = false,
    this.isInstant = false,
    this.auditeeId,
    this.auditeeName,
    this.auditeeIds = const [],
    this.auditeeNames = const [],
    this.auditorIds = const [],
    this.auditorNames = const [],
    this.scheduledEndDate,
    this.completedDate,
    this.finalAuditorRemark,
    this.maxScore,
    this.plannedByEmployeeId,
    this.parameters = const [],
    this.locationParameters = const [],
    this.locationLabels = const [],
    this.departmentParameters = const [],
    this.departmentLabels = const [],
    this.assignments = const [],
    this.scoreResult = const AuditScoreResult(),
    this.ncs = const [],
    this.accessLevel = 'full',
  });

  int get openNcCount => ncs.where((n) => n.status != 'Closed').length;

  // Fast lookup for checkpoint_card.dart — every leaf's ncId (see
  // ParameterNode.ncId) maps 1:1 onto one of these full NC documents.
  Map<String, NcModel> get ncsById => {for (final n in ncs) n.id: n};

  factory AuditDetailModel.fromJson(Map<String, dynamic> json) {
    dynamic idOf(dynamic v) => v is Map ? v['_id'] : v;
    return AuditDetailModel(
      id: (json['_id'] ?? '').toString(),
      title: json['title']?.toString() ?? 'Untitled Audit',
      scope: json['scope']?.toString() ?? '',
      status: json['status']?.toString() ?? 'Not Started',
      scoringSystem: json['scoringSystem']?.toString() ?? 'normal',
      structureMode: json['structureMode']?.toString() ?? 'same',
      distributionMode: json['distributionMode']?.toString() ?? 'whole',
      isDistributed: json['isDistributed'] as bool? ?? false,
      isSelfAudit: json['isSelfAudit'] as bool? ?? false,
      scheduledDate: json['scheduledDate'] != null ? DateTime.tryParse(json['scheduledDate'].toString()) : null,
      scheduledInFuture: json['scheduledInFuture'] as bool? ?? false,
      isInstant: json['isInstant'] as bool? ?? false,
      auditeeId: idOf(json['auditeeId'])?.toString(),
      auditeeName: json['auditeeId'] is Map ? (json['auditeeId']['employeeName']?.toString()) : null,
      auditeeIds: (json['auditeeIds'] as List? ?? []).map((e) => idOf(e)?.toString() ?? '').toList(),
      auditeeNames: (json['auditeeIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e['employeeName']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      auditorIds: (json['auditorIds'] as List? ?? []).map((e) => idOf(e)?.toString() ?? '').toList(),
      auditorNames: (json['auditorIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e['employeeName']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      scheduledEndDate: json['scheduledEndDate'] != null ? DateTime.tryParse(json['scheduledEndDate'].toString()) : null,
      completedDate: json['completedDate'] != null ? DateTime.tryParse(json['completedDate'].toString()) : null,
      finalAuditorRemark: json['finalAuditorRemark']?.toString(),
      maxScore: (json['maxScore'] as num?)?.toDouble(),
      plannedByEmployeeId: idOf(json['plannedByEmployeeId'])?.toString(),
      parameters: (json['parameters'] as List? ?? [])
          .whereType<Map>()
          .map((e) => ParameterNode.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      locationParameters: (json['locationParameters'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LocationParameterGroup.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      locationLabels: (json['locationIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LocationLabel.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      departmentParameters: (json['departmentParameters'] as List? ?? [])
          .whereType<Map>()
          .map((e) => DepartmentParameterGroup.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      departmentLabels: (json['departmentIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => DepartmentLabel.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      assignments: (json['assignments'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditAssignment.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      scoreResult: AuditScoreResult.fromJson(json['scoreResult'] as Map<String, dynamic>?),
      ncs: (json['ncs'] as List? ?? []).whereType<Map>().map((e) => NcModel.fromJson(Map<String, dynamic>.from(e))).toList(),
      accessLevel: json['accessLevel']?.toString() ?? 'full',
    );
  }
}
