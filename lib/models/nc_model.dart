/// The two Flags an NC can be given — what every picker offers, in this
/// order. The user-facing name is "Flag"; the wire/DB field is still
/// `severity` (models/NonConformance.js), so only labels say "Flag".
const kNcFlags = ['Major', 'Minor'];

/// The Flag to SHOW for a stored `severity` value: 'Major' stays Major and
/// everything else reads as 'Minor'. That covers the legacy "Observation"
/// value (no longer a Flag — the server only tolerates it on old NCs),
/// an NC that predates the field and comes back with no severity at all,
/// and anything unrecognised. Mirrors how the server and web read those
/// same records (Minor, weight 1). Every place that displays a Flag, or
/// seeds a Flag picker from an existing NC, goes through this rather than
/// using the raw value — the stored value itself is never rewritten by
/// merely reading it.
String flagOf(String? severity) => severity == 'Major' ? 'Major' : 'Minor';

// The id of a populated ({_id}) or bare ref, null when absent/blank.
String? _refId(dynamic v) {
  final id = (v is Map ? v['_id'] : v)?.toString() ?? '';
  return id.isEmpty ? null : id;
}

/// Mirrors server/models/NonConformance.js — one NC's full lifecycle,
/// including responseHistory (one entry per submit-then-verify cycle),
/// which is what lets the mobile review screen show the same "NC1, NC2, ..."
/// thread as the web app's NC Monitoring page.
class NcPersonRef {
  final String id;
  final String name;
  final String? profilePic;

  const NcPersonRef({required this.id, required this.name, this.profilePic});

  factory NcPersonRef.fromJson(dynamic json) {
    if (json is Map) {
      return NcPersonRef(
        id: (json['_id'] ?? '').toString(),
        name: json['employeeName']?.toString() ?? 'Unknown',
        profilePic: json['profilePic']?.toString(),
      );
    }
    return const NcPersonRef(id: '', name: 'Unknown');
  }
}

class NcResponseEntry {
  final int cycle;
  final String? correctionAction;
  final String? rootCause;
  final String? correctiveAction;
  final String? preventiveAction;
  final List<String> photos;
  final DateTime? submittedAt;
  final String? verificationAction; // "Accept" | "Reject" | null
  final String? verificationNote;
  final DateTime? verifiedAt;

  const NcResponseEntry({
    required this.cycle,
    this.correctionAction,
    this.rootCause,
    this.correctiveAction,
    this.preventiveAction,
    this.photos = const [],
    this.submittedAt,
    this.verificationAction,
    this.verificationNote,
    this.verifiedAt,
  });

  factory NcResponseEntry.fromJson(Map<String, dynamic> json) {
    return NcResponseEntry(
      cycle: (json['cycle'] as num?)?.toInt() ?? 1,
      correctionAction: json['correctionAction']?.toString(),
      rootCause: json['rootCause']?.toString(),
      correctiveAction: json['correctiveAction']?.toString(),
      preventiveAction: json['preventiveAction']?.toString(),
      photos: (json['photos'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      submittedAt: DateTime.tryParse(json['submittedAt']?.toString() ?? ''),
      verificationAction: json['verificationAction']?.toString(),
      verificationNote: json['verificationNote']?.toString(),
      verifiedAt: DateTime.tryParse(json['verifiedAt']?.toString() ?? ''),
    );
  }
}

class NcModel {
  final String id;
  final String ncId;
  final String auditId;
  final String auditTitle;
  // The audit's kind and dates — server: controllers/nc.controller.js
  // populates `auditId` with these (title auditType scheduledDate
  // scheduledEndDate), same fields the web app's NC popups show.
  final String? auditType;
  final DateTime? auditScheduledDate;
  final DateTime? auditScheduledEndDate;
  // The audit's scheduleBatchId, when it is one zone-document of a multi-zone
  // bundle — the Final Report's NC groups mark such an audit "Bundle". Null for
  // a stand-alone audit.
  final String? auditBatchId;
  // The audit's id as the NC stores it (GET /ncs/report sends it on every row): it
  // outlives the audit being deleted — `auditId` then comes back null (no title,
  // no bundle marker) but this is still there, so the NCs of one deleted audit
  // still group together.
  final String? auditKey;
  // Where the NC was raised — server: nc.controller.js#withPlaceNames (a
  // frozen name if the place was since renamed/deleted, else the live one).
  final String? locationName;
  final String? departmentName;
  // How many times the SAME checkpoint wording was raised at this SAME place
  // before this one — server: nc.controller.js#withRepeatCounts. 0 = not a
  // repeat.
  final int repeatCount;
  final String title;
  final String description;
  final String status; // Raised | Response Submitted | Verification | Closed
  // The NC's Flag: Major | Minor (the field keeps its wire name,
  // `severity`). Server defaults new NCs to 'Minor'
  // (models/NonConformance.js). A legacy record can still carry
  // "Observation", or — per server/utils/ncScoring.js#resolveSeverity — come
  // back with the key missing entirely from a lean response; fromJson reads
  // both as Minor via [flagOf] rather than assuming the key is present.
  final String severity;
  final NcPersonRef raisedBy;
  final NcPersonRef auditee;
  final DateTime? startDate;
  final DateTime? targetDate;
  final DateTime? completionDate;
  final int? atsScore;
  final int reopenCount;
  final String? verificationNote;
  final List<NcResponseEntry> responseHistory;
  // Only the Final Report's NC list (GET /ncs/report) sends these two, both
  // worked out by the SERVER so a row can never be labelled differently from
  // the tile a tap on it came from — the device renders them, never derives
  // them: the bucket the NC is counted under (nc_report_model.dart's
  // NcBucket: inProgress | overdue | pendingApproval | delayed | onTime) and
  // where it belongs (its own place, else its audit's places, else "No
  // location"). Null on every other list.
  final String? bucket;
  final String? placeLabel;

  const NcModel({
    required this.id,
    required this.ncId,
    required this.auditId,
    required this.auditTitle,
    this.auditType,
    this.auditScheduledDate,
    this.auditScheduledEndDate,
    this.auditBatchId,
    this.auditKey,
    this.locationName,
    this.departmentName,
    this.repeatCount = 0,
    required this.title,
    required this.description,
    required this.status,
    this.severity = 'Minor',
    required this.raisedBy,
    required this.auditee,
    this.startDate,
    this.targetDate,
    this.completionDate,
    this.atsScore,
    this.reopenCount = 0,
    this.verificationNote,
    this.responseHistory = const [],
    this.bucket,
    this.placeLabel,
  });

  /// The audit this NC was raised in no longer exists (the populated ref is null).
  bool get auditDeleted => auditId.isEmpty;

  factory NcModel.fromJson(Map<String, dynamic> json) {
    final auditRef = json['auditId'];
    return NcModel(
      id: (json['_id'] ?? '').toString(),
      ncId: json['ncId']?.toString() ?? '',
      auditId: (auditRef is Map ? auditRef['_id'] : auditRef)?.toString() ?? '',
      auditTitle: auditRef is Map ? (auditRef['title']?.toString() ?? '') : '',
      auditType: auditRef is Map ? auditRef['auditType']?.toString() : null,
      auditScheduledDate: auditRef is Map ? DateTime.tryParse(auditRef['scheduledDate']?.toString() ?? '') : null,
      auditScheduledEndDate: auditRef is Map ? DateTime.tryParse(auditRef['scheduledEndDate']?.toString() ?? '') : null,
      auditBatchId: auditRef is Map ? _refId(auditRef['scheduleBatchId']) : null,
      auditKey: _refId(json['auditKey']),
      locationName: json['locationName']?.toString(),
      departmentName: json['departmentName']?.toString(),
      repeatCount: (json['repeatCount'] as num?)?.toInt() ?? 0,
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      status: json['status']?.toString() ?? 'Raised',
      severity: flagOf(json['severity']?.toString()),
      raisedBy: NcPersonRef.fromJson(json['raisedByEmployeeId']),
      auditee: NcPersonRef.fromJson(json['auditeeEmployeeId']),
      startDate: DateTime.tryParse(json['startDate']?.toString() ?? ''),
      targetDate: DateTime.tryParse(json['targetDate']?.toString() ?? ''),
      completionDate: DateTime.tryParse(json['completionDate']?.toString() ?? ''),
      atsScore: (json['atsScore'] as num?)?.toInt(),
      reopenCount: (json['reopenCount'] as num?)?.toInt() ?? 0,
      verificationNote: json['verificationNote']?.toString(),
      responseHistory: (json['responseHistory'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcResponseEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      bucket: json['bucket']?.toString(),
      placeLabel: json['placeLabel']?.toString(),
    );
  }
}
