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
  final String title;
  final String description;
  final String status; // Raised | Response Submitted | Verification | Closed
  // Major | Minor | Observation — server defaults new NCs to 'Minor'
  // (models/NonConformance.js) and, per server/utils/ncScoring.js
  // #resolveSeverity, a pre-severity legacy record can come back with the
  // key missing entirely from a lean response — the ?? fallback below
  // mirrors that same default rather than assuming it's always present.
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

  const NcModel({
    required this.id,
    required this.ncId,
    required this.auditId,
    required this.auditTitle,
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
  });

  factory NcModel.fromJson(Map<String, dynamic> json) {
    final auditRef = json['auditId'];
    return NcModel(
      id: (json['_id'] ?? '').toString(),
      ncId: json['ncId']?.toString() ?? '',
      auditId: (auditRef is Map ? auditRef['_id'] : auditRef)?.toString() ?? '',
      auditTitle: auditRef is Map ? (auditRef['title']?.toString() ?? '') : '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      status: json['status']?.toString() ?? 'Raised',
      severity: json['severity']?.toString() ?? 'Minor',
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
    );
  }
}
