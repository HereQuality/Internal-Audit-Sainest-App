import 'self_audit.dart';

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

// Mongo sends every date as a UTC ISO string, and DateTime.tryParse keeps
// it that way — so `DateTime(d.year, d.month, d.day)` on the raw value
// buckets by the UTC calendar day while Formatters (core/utils/formatters
// .dart, which every screen prints through) formats in LOCAL time. In a
// +5:30 timezone that quietly disagrees for anything scheduled late in the
// local evening: the card reads "5 Sep" while the agenda files it under
// 4 Sep. Convert once, here, so day-bucketing and display can never drift.
DateTime? _localDate(dynamic v) =>
    DateTime.tryParse(v?.toString() ?? '')?.toLocal();

// Ids of a populated (or bare) ref list, blanks dropped.
List<String> _refIds(dynamic list) => [
  if (list is List)
    for (final e in list)
      if ((e is Map ? e['_id'] : e)?.toString().isNotEmpty ?? false) (e is Map ? e['_id'] : e).toString(),
];

// null for an absent field AND for a present-but-empty string, so
// callers can treat "no audit type" / "not part of a series" as one
// falsy case instead of also having to check for ''.
String? _nonEmpty(dynamic v) {
  if (v == null) return null;
  final s = v.toString().trim();
  return s.isEmpty ? null : s;
}

// Server-computed per-audit NC tally (audit.controller.js attaches it next
// to `displayStatus`) — what "NC Response Pending" / "NC Verification
// Pending" were decided from. Carried for display/debugging only: the app
// never re-derives a status from it (status contract, client rule 1).
class AuditNcSummary {
  final int total;
  final int responsePending;
  final int verificationPending;
  final int closed;

  const AuditNcSummary({
    this.total = 0,
    this.responsePending = 0,
    this.verificationPending = 0,
    this.closed = 0,
  });

  // null (not an all-zero summary) for an absent / non-object field, so an
  // older server that never sends it is distinguishable from "0 NCs".
  static AuditNcSummary? tryParse(dynamic json) {
    if (json is! Map) return null;
    int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    return AuditNcSummary(
      total: asInt(json['total']),
      responsePending: asInt(json['responsePending']),
      verificationPending: asInt(json['verificationPending']),
      closed: asInt(json['closed']),
    );
  }
}

class AuditModel {
  final String id;
  final String title;
  final String scope;
  // The stored/derived status (Draft | Not Started | In Progress | Completed |
  // Skipped) — what every permission/gating check reads (can score, final
  // report, edit). NEVER use it as the label: see [displayLabel].
  final String status;
  // The unified lifecycle status the owner asked every screen to show —
  // Not Started / In Progress / Overdue / NC Response Pending / NC
  // Verification Pending / Total Closed (+ Draft / Skipped) — computed
  // server-side (utils/auditLifecycleStatus.js), never derived here. Null
  // from an older server or cached data: [displayLabel] falls back to
  // `status` then.
  final String? displayStatus;
  // "On-Time Completed" | "Delayed Completed", only for a stored-Completed
  // audit (null otherwise). These two are never a [displayStatus]: they are
  // the small secondary pill next to a completed audit's badge and the
  // "completed on time / late" filter + dashboard tile.
  final String? timeliness;
  final AuditNcSummary? ncSummary;
  // Same vocabulary as [displayStatus], aggregated over the zones of this
  // audit's scheduleBatchId that the response holds (the one status a
  // multi-zone batch's parent row shows); null for a non-batch audit. On
  // GET /audits/report that is only the zones the filters matched — see
  // [batchZoneCount]. [batchTimeliness] is set only once those zones are
  // completed (Delayed if any was late).
  final String? batchDisplayStatus;
  final String? batchTimeliness;
  // How many zones the bundle has IN TOTAL (GET /audits/report sends it on every
  // row of a bundle). A list that carries fewer of them than this — "Me" lists
  // only the zones you are on — is a partial view of the bundle, and says so
  // ("2 of 5 locations"). Null for a non-batch audit / an older server.
  final int? batchZoneCount;
  final DateTime? scheduledDate;
  final DateTime? scheduledEndDate;
  final DateTime? completedDate;
  final AuditeeInfo auditee;
  // Every named auditee (auditeeIds, the source of truth — [auditee] above is only the first one), and whether the
  // auditor conducted the audit WITHOUT one ("Self", models/self_audit.dart). Read [auditeeLabel] / [isSelfAudit].
  final List<String> auditeeNames;
  // The ids of everyone named as the auditee (auditeeId and auditeeIds, populated or bare) — the Calendar's "you are the
  // auditee" mark. Unlike [auditeeNames] it also reads from /audits/at-my-location, which leaves auditeeIds unpopulated.
  final List<String> auditeeIdList;
  final bool selfAudit;
  final String? selfAuditReason;
  final String selfAuditRemark;
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
  // scoreResult.achievedExact/maxPossibleExact — the EXACT totals the whole numbers above were rounded from (a weighted
  // audit of exactly 3.5 out of 4 is stored as "4 of 4"). Never shown: only ever ADDED UP, so several audits combine to the
  // right percentage (3 such audits are 87.5%, not 12/12 = 100%). Null from an older audit / server — see [exactScoreAchieved].
  final double? scoreAchievedExact;
  final double? scoreMaxExact;
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
  // The audit's category name (models/Audit.js#auditType is a plain
  // trimmed String, not a ref — whichever AuditType name was picked at
  // creation time). Needed on mobile now that the Dashboard/Audits/
  // Calendar filters can narrow by it, and shown on the agenda card so a
  // day with several audits is scannable without opening each one.
  final String? auditType;
  // A recurring ("Frequency") audit generates one real Audit document per
  // occurrence, all sharing recurrence.seriesId (see models/Audit.js's own
  // header comment) — the phone agenda collapses a whole series down to
  // one group row inside its month bucket instead of repeating N
  // near-identical cards, same idea as the web app's CreateAudit.jsx/
  // AuditorDashboard.jsx series collapse.
  final String? seriesId;
  final String? frequency;
  final int? occurrenceIndex;
  final int? occurrenceCount;
  bool get isRecurring => seriesId != null && seriesId!.isNotEmpty;

  // ── What a place leader needs to swap an auditor (rows of GET
  // /audits/at-places-i-lead only; empty / false everywhere else) ──
  /// The auditors on the audit, id + name in the same order, so "who is not
  /// coming?" can name one of them. [auditorNames] above is the names alone.
  final List<({String id, String name, bool inactive})> auditors;
  /// The audited place ids (locations, then departments) — who may replace an
  /// auditor is that place's own members.
  final List<String> locationIdList;
  final List<String> departmentIdList;
  /// Cross Functional Team audit: its place's members may NOT be its auditor.
  final bool isCFT;
  /// The server's verdict for THIS person right now (utils/reassign.js) and,
  /// when false, the reason it gives — shown under the disabled button.
  final bool canReassign;
  final String? reassignBlockedReason;
  /// How many checkpoints are already scored — the swap keeps them, and the
  /// dialog says so.
  final int scoredCount;

  // ── What the "Audit at My Location" tab shows (rows of GET /audits/at-my-location) ──
  /// Everyone on the auditee side with their id: the legacy single `auditeeId` and the `auditeeIds` list, merged and
  /// de-duplicated by id like the web table does. Empty for a self audit (the Auditee then reads "Self").
  final List<({String id, String name, bool inactive})> auditeePeople;

  /// The audited places by name (locations, then departments), each one its own entry; a place that was deleted after
  /// the audit was scheduled comes back flagged and is labelled "(deleted)". [location] above is the same joined.
  final List<String> placeLabels;

  /// A Skipped audit's remark and who skipped it (server fillSkipDetails); null / '' on any other audit.
  final String? skipReason;
  final String skippedByName;

  /// Part of a repeat series: the series link or a frequency label is enough (old rows carry only one of them),
  /// like the web's isRecurringAudit.
  bool get isRepeating => isRecurring || (frequency ?? '').isNotEmpty;

  /// Whether [employeeId] is one of the auditors / on the auditee side — what the "You" mark reads.
  bool hasAuditor(String? employeeId) =>
      employeeId != null && employeeId.isNotEmpty && auditors.any((p) => p.id == employeeId);
  bool hasAuditee(String? employeeId) =>
      employeeId != null && employeeId.isNotEmpty && auditeePeople.any((p) => p.id == employeeId);

  /// What a badge/tile/filter/PDF prints for this audit: the server's
  /// unified [displayStatus], else the raw [status] (older server, cached
  /// data). Every label the user reads goes through this; every behavioural
  /// gate keeps reading [status].
  String get displayLabel => displayStatus ?? status;

  /// Self only while nobody is named: a named auditee always wins over a stale flag.
  bool get isSelfAudit => selfAudit && auditeeNames.isEmpty && (auditee.name ?? '').isEmpty;

  /// "Auditee not responding — Called twice, no answer" for a self audit, else ''.
  String get selfAuditNote => isSelfAudit ? selfAuditNoteOf(selfAuditReason, selfAuditRemark) : '';

  /// What the Auditee field says: the names, else "Self", else [fallback].
  String auditeeLabel({String fallback = '—'}) {
    if (auditeeNames.isNotEmpty) return auditeeNames.join(', ');
    if ((auditee.name ?? '').isNotEmpty) return auditee.name!;
    return isSelfAudit ? kSelfLabel : fallback;
  }

  /// The status a multi-zone batch's parent row shows — [batchDisplayStatus]
  /// (aggregated over ALL zones, so it can differ from this one zone's own),
  /// else this audit's own [displayLabel] for a non-batch audit / older
  /// server.
  String get batchLabel => batchDisplayStatus ?? displayLabel;

  const AuditModel({
    required this.id,
    required this.title,
    required this.scope,
    required this.status,
    this.displayStatus,
    this.timeliness,
    this.ncSummary,
    this.batchDisplayStatus,
    this.batchTimeliness,
    this.batchZoneCount,
    this.scheduledDate,
    this.scheduledEndDate,
    this.completedDate,
    this.auditee = const AuditeeInfo(),
    this.auditeeNames = const [],
    this.auditeeIdList = const [],
    this.selfAudit = false,
    this.selfAuditReason,
    this.selfAuditRemark = '',
    this.location = '',
    this.scorePercentage,
    this.scoreAchieved,
    this.scoreMax,
    this.scoreAchievedExact,
    this.scoreMaxExact,
    this.auditorNames = const [],
    this.scheduleBatchId,
    this.structureMode = 'same',
    this.locationCount = 0,
    this.auditType,
    this.seriesId,
    this.frequency,
    this.occurrenceIndex,
    this.occurrenceCount,
    this.auditors = const [],
    this.locationIdList = const [],
    this.departmentIdList = const [],
    this.isCFT = false,
    this.canReassign = false,
    this.reassignBlockedReason,
    this.scoredCount = 0,
    this.auditeePeople = const [],
    this.placeLabels = const [],
    this.skipReason,
    this.skippedByName = '',
  });

  /// The totals to ADD UP when scores are combined (server: scoring.js#achievedOf / #maxPossibleOf): the exact figure,
  /// else the whole number for an audit saved before the exact ones existed, else 0.
  double get exactScoreAchieved => scoreAchievedExact ?? scoreAchieved ?? 0;
  double get exactScoreMax => scoreMaxExact ?? scoreMax ?? 0;

  factory AuditModel.fromJson(Map<String, dynamic> json) {
    final scoreResult = json['scoreResult'];
    final rawBatchId = json['scheduleBatchId'];
    final locIds = json['locationIds'];
    final recurrence = json['recurrence'];
    return AuditModel(
      id: (json['_id'] ?? '').toString(),
      title: json['title']?.toString() ?? 'Untitled Audit',
      scope: json['scope']?.toString() ?? '',
      status: json['status']?.toString() ?? 'Scheduled',
      displayStatus: _nonEmpty(json['displayStatus']),
      timeliness: _nonEmpty(json['timeliness']),
      ncSummary: AuditNcSummary.tryParse(json['ncSummary']),
      batchDisplayStatus: _nonEmpty(json['batchDisplayStatus']),
      batchTimeliness: _nonEmpty(json['batchTimeliness']),
      batchZoneCount: (json['batchZoneCount'] as num?)?.toInt(),
      scheduledDate: _localDate(json['scheduledDate']),
      scheduledEndDate: _localDate(json['scheduledEndDate']),
      completedDate: _localDate(json['completedDate']),
      auditee: AuditeeInfo.fromJson(json['auditeeId']),
      auditeeNames: (json['auditeeIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e['employeeName']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      auditeeIdList: {
        ..._refIds([json['auditeeId'], ...(json['auditeeIds'] is List ? json['auditeeIds'] as List : const [])]),
      }.toList(),
      selfAudit: json['selfAudit'] == true,
      selfAuditReason: json['selfAuditReason']?.toString(),
      selfAuditRemark: json['selfAuditRemark']?.toString() ?? '',
      location: _locationLabel(json),
      scorePercentage: scoreResult is Map ? (scoreResult['percentage'] as num?)?.toDouble() : null,
      scoreAchieved: scoreResult is Map ? (scoreResult['achieved'] as num?)?.toDouble() : null,
      scoreMax: scoreResult is Map ? (scoreResult['maxPossible'] as num?)?.toDouble() : null,
      scoreAchievedExact: scoreResult is Map ? (scoreResult['achievedExact'] as num?)?.toDouble() : null,
      scoreMaxExact: scoreResult is Map ? (scoreResult['maxPossibleExact'] as num?)?.toDouble() : null,
      auditorNames: (json['auditorIds'] as List? ?? [])
          .whereType<Map>()
          .map((e) => e['employeeName']?.toString() ?? '')
          .where((n) => n.isNotEmpty)
          .toList(),
      scheduleBatchId: rawBatchId == null ? null : (rawBatchId is Map ? rawBatchId['_id'] : rawBatchId)?.toString(),
      structureMode: json['structureMode']?.toString() ?? 'same',
      locationCount: locIds is List ? locIds.length : 0,
      auditType: _nonEmpty(json['auditType']),
      // recurrence.seriesId is an unpopulated ObjectId today, but read the
      // populated {_id: ...} shape too so a future .populate() on this
      // endpoint can't silently turn every occurrence back into its own
      // ungrouped row.
      seriesId: _nonEmpty(recurrence is Map
          ? (recurrence['seriesId'] is Map ? recurrence['seriesId']['_id'] : recurrence['seriesId'])
          : null),
      frequency: _nonEmpty(recurrence is Map ? recurrence['frequency'] : null),
      occurrenceIndex: recurrence is Map ? (recurrence['occurrenceIndex'] as num?)?.toInt() : null,
      occurrenceCount: recurrence is Map ? (recurrence['occurrenceCount'] as num?)?.toInt() : null,
      auditors: [
        for (final e in (json['auditorIds'] as List? ?? []).whereType<Map>())
          if ((e['_id'] ?? '').toString().isNotEmpty)
            (
              id: e['_id'].toString(),
              name: e['employeeName']?.toString() ?? 'Unknown employee',
              inactive: e['isActive'] == false,
            ),
      ],
      locationIdList: _refIds(json['locationIds']),
      departmentIdList: _refIds(json['departmentIds']),
      isCFT: json['isCFT'] == true,
      canReassign: json['canReassign'] == true,
      reassignBlockedReason: _nonEmpty(json['reassignBlockedReason']),
      scoredCount: scoreResult is Map ? (scoreResult['scoredCount'] as num?)?.toInt() ?? 0 : 0,
      auditeePeople: _auditeePeople(json),
      placeLabels: _placeLabels(json),
      skipReason: _nonEmpty(json['skipReason']),
      skippedByName: json['skippedByName']?.toString() ?? '',
    );
  }
}

// The auditee side with ids: the legacy `auditeeId` first, then `auditeeIds`, each person once. A person with neither
// an id nor a name is dropped (a bare ObjectId that was never populated tells the reader nothing).
List<({String id, String name, bool inactive})> _auditeePeople(Map<String, dynamic> json) {
  final seen = <String>{};
  final people = <({String id, String name, bool inactive})>[];
  void add(dynamic e) {
    if (e is! Map) return;
    final id = (e['_id'] ?? '').toString();
    final name = e['employeeName']?.toString() ?? '';
    if (id.isEmpty || name.isEmpty || !seen.add(id)) return;
    people.add((id: id, name: name, inactive: e['isActive'] == false));
  }

  add(json['auditeeId']);
  if (json['auditeeIds'] is List) {
    for (final e in json['auditeeIds'] as List) {
      add(e);
    }
  }
  return people;
}

// Each audited place by name — locations, then departments. A place deleted since the audit was scheduled is a
// placeholder that still carries its frozen name, flagged `_removed`.
List<String> _placeLabels(Map<String, dynamic> json) {
  String label(Map e, String key) {
    final name = (e[key] ?? e['name'] ?? e['departmentName'])?.toString().trim() ?? '';
    final removed = e['_removed'] == true || e['isDeleted'] == true;
    return '${name.isEmpty ? 'Unknown place' : name}${removed ? ' (deleted)' : ''}';
  }

  return [
    if (json['locationIds'] is List)
      for (final e in (json['locationIds'] as List).whereType<Map>()) label(e, 'name'),
    if (json['departmentIds'] is List)
      for (final e in (json['departmentIds'] as List).whereType<Map>()) label(e, 'departmentName'),
  ];
}

class AuditorStats {
  final int assignedAudits;
  final int inProgress;
  final int ncPending;
  final int completed;
  // The unified-status tallies behind the dashboard's tiles (server/
  // controllers/audit.controller.js#getAuditorStats). Named for the status
  // they count, NOT for their JSON keys: `assigned` there means Not Started
  // (and would read as a clone of [assignedAudits], the total, here), and
  // `ongoing` means In Progress WITHOUT the overdue ones (which [inProgress]
  // above still includes).
  //   notStarted/ongoing/overdue — by the audit's own date window;
  //   delayed/onTimeCompleted    — stored-Completed audits by timeliness,
  //                                whatever their NC stage;
  //   ncResponsePending/ncVerificationPending/totalClosed — completed
  //                                audits by their NC stage.
  // An audit can therefore sit in a timeliness tile AND an NC tile at once —
  // intended (status contract, "Stats").
  final int notStarted;
  final int ongoing;
  final int overdue;
  final int delayed;
  final int onTimeCompleted;
  final int ncResponsePending;
  final int ncVerificationPending;
  final int totalClosed;
  // Whether the server sent the three NC-stage tallies above at all. Those are
  // the newest keys: an older server sends the timeliness tallies (delayed /
  // onTimeCompleted) but not these, and showing them as 0 would put
  // "On-Time + Delayed = 12" next to "NC Response + Verification + Closed =
  // 0" — the two sides are the same set of audits (every audit its auditor
  // has completed) and must agree, so the dashboard hides the NC-stage tiles
  // rather than print zeros it does not know.
  final bool hasNcStageCounts;
  // Member audit ids per tile, same names as the counts above. The app's
  // tile taps route through the client-side status filter today (see
  // MyAuditsScreen), so nothing reads these yet — parsed so a tile can pass
  // them back as `ids=` (the web dashboard's pattern) without another model
  // change.
  final List<String> notStartedIds;
  final List<String> ongoingIds;
  final List<String> overdueIds;
  final List<String> delayedIds;
  final List<String> onTimeCompletedIds;
  final List<String> ncResponsePendingIds;
  final List<String> ncVerificationPendingIds;
  final List<String> totalClosedIds;
  // This auditor's own ATS/OTC — based on THEIR audits' Start/Due/Completed
  // dates (server/controllers/audit.controller.js#getAuditorStats ->
  // computeAuditAtsScore/computeAuditOtcRate), same fields the web app's
  // AuditorDashboard.jsx reads off this identical endpoint for its
  // Performance Scorecard. NOT the NC-closure-based ATS/OTC (that's
  // AuditeeStats, a different GET /ncs/ats-summary metric for how well
  // someone responds to NCs raised against them).
  final double? auditAtsScore;
  final double? auditOtcScore;
  // The auditor scorecard's figures (same GET /audits/auditor-stats response;
  // ATS/OTC above are no longer shown for an auditor's own audits — they are
  // the auditee's, for their NCs). totalAudits = every audit in the plan
  // pipeline (Not Started + In Progress + Overdue + Delayed + On-Time + Not
  // Attempted); overall/last score are null until an audit has been scored.
  final int totalAudits;
  final int activeAudits;
  final double? overallScore;
  final double? lastAuditScore;

  const AuditorStats({
    this.assignedAudits = 0,
    this.inProgress = 0,
    this.ncPending = 0,
    this.completed = 0,
    this.notStarted = 0,
    this.ongoing = 0,
    this.overdue = 0,
    this.delayed = 0,
    this.onTimeCompleted = 0,
    this.ncResponsePending = 0,
    this.ncVerificationPending = 0,
    this.totalClosed = 0,
    this.hasNcStageCounts = true,
    this.notStartedIds = const [],
    this.ongoingIds = const [],
    this.overdueIds = const [],
    this.delayedIds = const [],
    this.onTimeCompletedIds = const [],
    this.ncResponsePendingIds = const [],
    this.ncVerificationPendingIds = const [],
    this.totalClosedIds = const [],
    this.auditAtsScore,
    this.auditOtcScore,
    this.totalAudits = 0,
    this.activeAudits = 0,
    this.overallScore,
    this.lastAuditScore,
  });

  /// The tally for one status label of the unified vocabulary (0 for a label
  /// that has no tile, e.g. Draft/Skipped) — lets the dashboard build its
  /// tiles from the label list instead of repeating a field per tile.
  int countFor(String status) => switch (status) {
    'Not Started' => notStarted,
    'In Progress' => ongoing,
    'Overdue' => overdue,
    'Delayed Completed' => delayed,
    'On-Time Completed' => onTimeCompleted,
    'NC Response Pending' => ncResponsePending,
    'NC Verification Pending' => ncVerificationPending,
    'Total Closed' => totalClosed,
    _ => 0,
  };

  /// [countFor]'s member ids (empty for a label with no tile).
  List<String> idsFor(String status) => switch (status) {
    'Not Started' => notStartedIds,
    'In Progress' => ongoingIds,
    'Overdue' => overdueIds,
    'Delayed Completed' => delayedIds,
    'On-Time Completed' => onTimeCompletedIds,
    'NC Response Pending' => ncResponsePendingIds,
    'NC Verification Pending' => ncVerificationPendingIds,
    'Total Closed' => totalClosedIds,
    _ => const [],
  };

  factory AuditorStats.fromJson(Map<String, dynamic> json) {
    int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;
    List<String> asIds(dynamic v) => v is List ? v.map((e) => e.toString()).toList() : const [];
    return AuditorStats(
      assignedAudits: asInt(json['assignedAudits']),
      inProgress: asInt(json['inProgress']),
      ncPending: asInt(json['ncPending']),
      completed: asInt(json['completed']),
      notStarted: asInt(json['assigned']),
      // `inProgress` only as a fallback for a server too old to send
      // `ongoing` at all: it over-counts (it includes overdue), but a tile
      // reading 0 next to a non-empty list is the worse lie.
      ongoing: asInt(json.containsKey('ongoing') ? json['ongoing'] : json['inProgress']),
      overdue: asInt(json['overdue']),
      delayed: asInt(json['delayed']),
      onTimeCompleted: asInt(json['onTimeCompleted']),
      ncResponsePending: asInt(json['ncResponsePending']),
      ncVerificationPending: asInt(json['ncVerificationPending']),
      totalClosed: asInt(json['totalClosed']),
      hasNcStageCounts:
          json.containsKey('ncResponsePending') &&
          json.containsKey('ncVerificationPending') &&
          json.containsKey('totalClosed'),
      notStartedIds: asIds(json['assignedIds']),
      ongoingIds: asIds(json['ongoingIds']),
      overdueIds: asIds(json['overdueIds']),
      delayedIds: asIds(json['delayedIds']),
      onTimeCompletedIds: asIds(json['onTimeCompletedIds']),
      ncResponsePendingIds: asIds(json['ncResponsePendingIds']),
      ncVerificationPendingIds: asIds(json['ncVerificationPendingIds']),
      totalClosedIds: asIds(json['totalClosedIds']),
      auditAtsScore: (json['auditAtsScore'] as num?)?.toDouble(),
      auditOtcScore: (json['auditOtcScore'] as num?)?.toDouble(),
      totalAudits: asInt(json['totalAudits']),
      activeAudits: asInt(json['activeAudits']),
      overallScore: (json['overallScore'] as num?)?.toDouble(),
      lastAuditScore: (json['lastAuditScore'] as num?)?.toDouble(),
    );
  }
}
