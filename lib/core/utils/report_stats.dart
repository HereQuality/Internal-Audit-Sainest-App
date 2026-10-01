import '../../models/audit_model.dart';
import 'audit_status.dart';

/// The score of a set of audits worked out from the FINISHED ones only — the
/// owner's rule (2026-09-30): only a Completed audit (or a Completed zone of a
/// batch) has a final score. An open, Not Attempted, Skipped or Draft one is
/// neither 0 nor 100 — it is left out, and a set with nothing finished has no
/// score at all ([percentage] null, shown as "—"). Σ achieved / Σ possible,
/// never an average of each audit's own percentage.
class FinishedScore {
  final double achieved;
  final double maxPossible;

  const FinishedScore({this.achieved = 0, this.maxPossible = 0});

  /// Whole percent, null while nothing finished has a score.
  int? get percentage =>
      maxPossible > 0 ? (achieved / maxPossible * 100).round() : null;
}

/// [FinishedScore] over the Completed members of [audits] (each audit is judged
/// on its own stored status, so a batch's finished zones count even while other
/// zones are still open — the phone's batch row and location headers).
FinishedScore finishedScoreOf(Iterable<AuditModel> audits) {
  var achieved = 0.0;
  var max = 0.0;
  for (final a in audits) {
    if (a.status != AuditStatus.completed) continue;
    achieved += a.scoreAchieved ?? 0;
    max += a.scoreMax ?? 0;
  }
  return FinishedScore(achieved: achieved, maxPossible: max);
}

/// One place's line in the Final Report's location-wise view — the SERVER's
/// `byLocation` row (audit.controller.js#getCompletedAuditStats ->
/// utils/reportLocationBreakdown.js): how many reports sit at the place and
/// their CUMULATIVE score (Σ achieved / Σ possible, never an average of each
/// report's own percentage) over the FINISHED ones only (an open / Not
/// Attempted audit still counts as a report but adds nothing to the score),
/// worked out over the whole filtered set rather than over whichever rows the
/// phone happens to have loaded.
class ReportLocationStats {
  /// The place's name — also the group's identity ("A, B" for one audit that
  /// spans two places on a shared checklist, "No location" for none).
  final String key;
  final String label;
  final int count;
  final double achieved;
  final double maxPossible;
  final int? percentage;
  final List<String> locationIds;
  final List<String> departmentIds;

  /// The audits counted here — which loaded rows belong under this header.
  final List<String> auditIds;

  const ReportLocationStats({
    required this.key,
    required this.label,
    this.count = 0,
    this.achieved = 0,
    this.maxPossible = 0,
    this.percentage,
    this.locationIds = const [],
    this.departmentIds = const [],
    this.auditIds = const [],
  });

  static ReportLocationStats? tryParse(dynamic data) {
    if (data is! Map) return null;
    final label = (data['label'] ?? data['key'] ?? '').toString();
    final pct = data['percentage'];
    return ReportLocationStats(
      key: (data['key'] ?? label).toString(),
      label: label,
      count: _int0(data['count']),
      achieved: _num0(data['achieved']),
      maxPossible: _num0(data['maxPossible']),
      percentage: pct is num ? pct.round() : null,
      locationIds: _strings(data['locationIds']),
      departmentIds: _strings(data['departmentIds']),
      auditIds: _strings(data['auditIds']),
    );
  }
}

/// One place header's rows in the location-wise view, loaded lazily a slice of
/// its audit ids at a time (AuditsProvider#loadReportPlaceRows).
class ReportPlaceRows {
  /// The rows read so far, in the server's order.
  final List<AuditModel> audits;

  /// How many of the header's [ReportLocationStats.auditIds] have been read —
  /// where the next slice starts.
  final int consumed;

  /// A slice is on its way / the last slice could not be read (what was read
  /// stays, the next call retries it).
  final bool loading;
  final String? error;

  const ReportPlaceRows({
    this.audits = const [],
    this.consumed = 0,
    this.loading = false,
    this.error,
  });
}

double _num0(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _int0(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
List<String> _strings(dynamic v) =>
    v is List ? [for (final e in v) e.toString()] : const <String>[];

/// The Final Report's audit tiles: cumulative Total Score, Total Audits, In
/// Progress, Overdue, Not Started, On-Time Completed, Delayed Completed, Skipped
/// and Not Attempted — the same figures the web's Final Report tiles show (GET
/// /audits/report/stats, server: audit.controller.js#getCompletedAuditStats).
///
/// The identities the server guarantees: On-Time + Delayed = Completed, and
/// every audit listed (a bundle counts once) falls in exactly ONE bucket, so
/// Total Audits = In Progress + Overdue + Not Started + On-Time + Delayed +
/// Skipped + Other ([bucketsTotal]). Not Attempted is counted apart and is NOT
/// in Total Audits.
///
/// Owner's rules (2026-09-30), already applied by the server and mirrored by
/// [ReportStats.fromAudits]: Total Audits leaves out the Not Attempted ones, and
/// the Total Score is worked out from Completed audits only — never a "so far"
/// grade over open work.
class ReportStats {
  /// Σ achieved / Σ possible over the FINISHED (Completed) audits in view, as a
  /// whole percent — NEVER an average of each audit's own percentage, and never
  /// including an open, Not Attempted or Skipped audit (server: audit.
  /// controller.js#getCompletedAuditStats). Null while nothing has finished
  /// (the tile shows "—").
  final int? percentage;
  final double achieved;
  final double maxPossible;

  /// Legacy: the server used to say the score included open audits' progress.
  /// It always sends false now and the tile never draws a "*" — kept only so an
  /// older answer still parses.
  final bool isPartial;

  /// Audits listed (a bundle counts once, like the table's rows), EXCLUDING the
  /// Not Attempted ones — a repeat whose window closed unattempted was never a
  /// real audit to grade.
  final int totalAudits;

  /// Audits (a bundle counts once, by its ONE aggregate status) being worked
  /// on right now, and audits every auditor of has finished.
  final int inProgress;
  final int completed;

  /// Finished audits by timeliness (a bundle is Delayed if any zone was late).
  final int onTimeCompleted;
  final int delayedCompleted;

  /// The rest of Total Audits, so the tiles add up (owner, 2026-09-30): audits
  /// past their window and still open ([overdue]), never started ([notStarted]),
  /// [skipped], and the rare one that fits none of the buckets ([other]).
  /// [notAttempted] is counted APART — a repeat whose window closed unattempted
  /// is NOT in [totalAudits]. All 0 from an older server that does not send them.
  final int overdue;
  final int notStarted;
  final int skipped;
  final int other;
  final int notAttempted;

  /// The audit ids behind each tile — what a tap on the tile narrows the loaded
  /// list to (every member of a bundle is in its bundle's list).
  final List<String> inProgressIds;
  final List<String> completedIds;
  final List<String> onTimeIds;
  final List<String> delayedIds;
  final List<String> overdueIds;
  final List<String> notStartedIds;
  final List<String> skippedIds;
  final List<String> otherIds;
  final List<String> notAttemptedIds;

  /// One row per place, A-Z with "No location" last — empty from the on-device
  /// fallback ([ReportStats.fromAudits]) and from an older server.
  final List<ReportLocationStats> byLocation;

  const ReportStats({
    this.percentage,
    this.achieved = 0,
    this.maxPossible = 0,
    this.isPartial = false,
    this.totalAudits = 0,
    this.inProgress = 0,
    this.completed = 0,
    this.onTimeCompleted = 0,
    this.delayedCompleted = 0,
    this.overdue = 0,
    this.notStarted = 0,
    this.skipped = 0,
    this.other = 0,
    this.notAttempted = 0,
    this.inProgressIds = const [],
    this.completedIds = const [],
    this.onTimeIds = const [],
    this.delayedIds = const [],
    this.overdueIds = const [],
    this.notStartedIds = const [],
    this.skippedIds = const [],
    this.otherIds = const [],
    this.notAttemptedIds = const [],
    this.byLocation = const [],
  });

  /// The buckets [totalAudits] is made of, added up — equal to [totalAudits]
  /// whenever the numbers come from a server / fallback that knows them all.
  /// [notAttempted] is not in it, on purpose.
  int get bucketsTotal =>
      inProgress + overdue + notStarted + onTimeCompleted + delayedCompleted + skipped + other;

  /// The `status` label the list endpoint (GET /audits/report) filters by for each
  /// tile — what a tap on the tile asks the server for, instead of a long list of
  /// ids. Each is the label the tile counts ("zones in that state": a Skipped tile
  /// really returns the Skipped audits, the server lifting its default Skipped
  /// exclusion for it). Not here: 'other' (a bundle that fits no bucket has no
  /// label — it is asked by [idsFor]) and the retired 'completed'.
  static const tileStatusLabels = <String, String>{
    'inProgress': AuditStatus.inProgress,
    'overdue': AuditStatus.overdue,
    'notStarted': AuditStatus.notStarted,
    'onTime': AuditStatus.onTimeCompleted,
    'delayed': AuditStatus.delayedCompleted,
    'skipped': AuditStatus.skipped,
    'notAttempted': AuditStatus.notAttempted,
  };

  /// The comma-separated `status` value (the server ORs the labels) for the status
  /// [chip] ('All' or null = none) together with the picked [tiles]; null when
  /// nothing narrows. Deduplicated, the chip first, then the tiles in the order
  /// the tile row shows them (never in the order they were tapped, so the same
  /// picks always read as the same query).
  static String? statusCsv({String? chip, Iterable<String> tiles = const []}) {
    final picked = tiles.toSet();
    final labels = <String>{
      if (chip != null && chip != 'All') chip,
      for (final e in tileStatusLabels.entries)
        if (picked.contains(e.key)) e.value,
    };
    return labels.isEmpty ? null : labels.join(',');
  }

  /// The ids behind the tile [key] ('inProgress' | 'completed' | 'onTime' |
  /// 'delayed' | 'overdue' | 'notStarted' | 'skipped' | 'notAttempted' |
  /// 'other'), empty for anything else.
  List<String> idsFor(String key) => switch (key) {
    'inProgress' => inProgressIds,
    'completed' => completedIds,
    'onTime' => onTimeIds,
    'delayed' => delayedIds,
    'overdue' => overdueIds,
    'notStarted' => notStartedIds,
    'skipped' => skippedIds,
    'notAttempted' => notAttemptedIds,
    'other' => otherIds,
    _ => const [],
  };

  /// [this] with another response's place breakdown — the narrowed one the
  /// server sends for `onlyIds` (a tile is active), while every tile keeps the
  /// whole filtered set's numbers.
  ReportStats withByLocation(List<ReportLocationStats> rows) => ReportStats(
    percentage: percentage,
    achieved: achieved,
    maxPossible: maxPossible,
    isPartial: isPartial,
    totalAudits: totalAudits,
    inProgress: inProgress,
    completed: completed,
    onTimeCompleted: onTimeCompleted,
    delayedCompleted: delayedCompleted,
    overdue: overdue,
    notStarted: notStarted,
    skipped: skipped,
    other: other,
    notAttempted: notAttempted,
    inProgressIds: inProgressIds,
    completedIds: completedIds,
    onTimeIds: onTimeIds,
    delayedIds: delayedIds,
    overdueIds: overdueIds,
    notStartedIds: notStartedIds,
    skippedIds: skippedIds,
    otherIds: otherIds,
    notAttemptedIds: notAttemptedIds,
    byLocation: rows,
  );

  /// Reads the server's `data` object. Null for anything that isn't one (an
  /// older server, a role without Final Report access answering an error) so
  /// the caller can fall back to [ReportStats.fromAudits].
  static ReportStats? tryParse(dynamic data) {
    if (data is! Map) return null;
    final pct = data['percentage'];
    final completed = _int0(data['completed'] ?? data['total']);
    return ReportStats(
      percentage: pct is num ? pct.round() : null,
      achieved: _num0(data['achieved']),
      maxPossible: _num0(data['maxPossible']),
      isPartial: data['isPartial'] == true,
      totalAudits: _int0(data['totalAudits'] ?? data['total']),
      inProgress: _int0(data['inProgress']),
      completed: completed,
      onTimeCompleted: _int0(data['onTimeCompleted']),
      delayedCompleted: _int0(data['delayedCompleted']),
      overdue: _int0(data['overdue']),
      notStarted: _int0(data['notStarted']),
      skipped: _int0(data['skipped']),
      other: _int0(data['other']),
      notAttempted: _int0(data['notAttempted']),
      inProgressIds: _strings(data['inProgressIds']),
      completedIds: _strings(data['completedIds']),
      onTimeIds: _strings(data['onTimeIds']),
      delayedIds: _strings(data['delayedIds']),
      overdueIds: _strings(data['overdueIds']),
      notStartedIds: _strings(data['notStartedIds']),
      skippedIds: _strings(data['skippedIds']),
      otherIds: _strings(data['otherIds']),
      notAttemptedIds: _strings(data['notAttemptedIds']),
      byLocation: [
        if (data['byLocation'] is List)
          for (final e in data['byLocation'] as List)
            ?ReportLocationStats.tryParse(e),
      ],
    );
  }

  /// The same numbers worked out from the audits already loaded — ONLY the
  /// fallback for a failed stats request (the endpoint isn't reachable for this
  /// role). The list is read one page at a time now, so this describes the rows
  /// loaded SO FAR (and, with a status / tile / search narrowing, only those the
  /// server returned for it) — not the whole filtered set the server's tiles
  /// count; the screen says nothing more than the numbers. Bundles (same
  /// scheduleBatchId, more than one visible) count once.
  ///
  /// The server's two 2026-09-30 rules apply here too: [totalAudits] leaves out
  /// every group whose one aggregate status is Not Attempted, and the score
  /// ([percentage] / [achieved] / [maxPossible]) is Σ / Σ over the FINISHED
  /// groups (every zone Completed) only — an open, Not Attempted, Skipped or
  /// Draft one contributes nothing (not 0, not 100), so [isPartial] is always
  /// false and nothing finished reads as a null percentage ("—").
  ///
  /// [completed] is every group whose zones are ALL finished and [inProgress]
  /// every group whose one aggregate display status reads "In Progress" — the
  /// server's two rules, so On-Time + Delayed = Completed here too.
  ///
  /// Every group lands in exactly ONE bucket, like the server's: a finished one
  /// is On-Time or Delayed (by timeliness); an unfinished one is In Progress /
  /// Overdue / Not Started / Skipped / Not Attempted by its aggregate display
  /// status; anything else (Draft, a mixed bundle, a finished one whose
  /// timeliness is unknown) is [other]. So [totalAudits] is the sum of every
  /// bucket but Not Attempted ([bucketsTotal]).
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
    var completed = 0;
    var inProgress = 0;
    var overdue = 0;
    var notStarted = 0;
    var skipped = 0;
    var other = 0;
    var notAttempted = 0;
    final completedIds = <String>[];
    final inProgressIds = <String>[];
    final onTimeIds = <String>[];
    final delayedIds = <String>[];
    final overdueIds = <String>[];
    final notStartedIds = <String>[];
    final skippedIds = <String>[];
    final otherIds = <String>[];
    final notAttemptedIds = <String>[];
    // What a tile pick narrows the list to: the ZONES in that state, not the whole
    // bundle (an Overdue tile on a 15-zone bundle lists its overdue zone only). When
    // no zone is in the state itself the still-open zones stand in, else all of them
    // — the same rule as the server's getCompletedAuditStats.
    List<String> zoneIds(List<AuditModel> members, bool Function(AuditModel) inState) {
      final hit = members.where(inState).toList();
      if (hit.isNotEmpty) return [for (final m in hit) m.id];
      final open = members.where((m) => m.status != AuditStatus.completed).toList();
      return [for (final m in (open.isNotEmpty ? open : members)) m.id];
    }

    for (final members in groups.values) {
      final finished = members.every((m) => m.status == AuditStatus.completed);
      if (!finished) {
        // Not Attempted is counted apart and is not part of Total Audits.
        switch (auditGroupStatus(members)) {
          case AuditStatus.inProgress:
            inProgress++;
            inProgressIds.addAll(zoneIds(members, (m) => m.displayLabel == AuditStatus.inProgress));
          case AuditStatus.overdue:
            overdue++;
            overdueIds.addAll(zoneIds(members, (m) => m.displayLabel == AuditStatus.overdue));
          case AuditStatus.notStarted:
            notStarted++;
            notStartedIds.addAll(zoneIds(members, (m) => m.displayLabel == AuditStatus.notStarted));
          case AuditStatus.skipped:
            skipped++;
            skippedIds.addAll(zoneIds(members, (m) => m.status == AuditStatus.skipped));
          case AuditStatus.notAttempted:
            notAttempted++;
            notAttemptedIds.addAll(zoneIds(members, (m) => m.displayLabel == AuditStatus.notAttempted));
          default:
            other++;
            otherIds.addAll([for (final m in members) m.id]);
        }
        continue;
      }
      final ids = [for (final m in members) m.id];
      final score = finishedScoreOf(members);
      achieved += score.achieved;
      max += score.maxPossible;
      completed++;
      completedIds.addAll(ids);
      final timeliness = auditGroupTimeliness(members) ??
          (members.any((m) => m.timeliness == AuditStatus.delayedCompleted)
              ? AuditStatus.delayedCompleted
              : members.every((m) => m.timeliness == AuditStatus.onTimeCompleted)
                  ? AuditStatus.onTimeCompleted
                  : null);
      if (timeliness == AuditStatus.delayedCompleted) {
        delayed++;
        delayedIds.addAll(zoneIds(members, (m) => m.timeliness == AuditStatus.delayedCompleted));
      } else if (timeliness == AuditStatus.onTimeCompleted) {
        onTime++;
        onTimeIds.addAll(zoneIds(members, (m) => m.timeliness == AuditStatus.onTimeCompleted));
      } else {
        // Finished, but no timeliness to file it under: still ONE audit in the Total.
        other++;
        otherIds.addAll(ids);
      }
    }
    final totalAudits = inProgress + overdue + notStarted + onTime + delayed + skipped + other;
    return ReportStats(
      percentage: max > 0 ? (achieved / max * 100).round() : null,
      achieved: achieved,
      maxPossible: max,
      totalAudits: totalAudits,
      inProgress: inProgress,
      completed: completed,
      onTimeCompleted: onTime,
      delayedCompleted: delayed,
      overdue: overdue,
      notStarted: notStarted,
      skipped: skipped,
      other: other,
      notAttempted: notAttempted,
      inProgressIds: inProgressIds,
      completedIds: completedIds,
      onTimeIds: onTimeIds,
      delayedIds: delayedIds,
      overdueIds: overdueIds,
      notStartedIds: notStartedIds,
      skippedIds: skippedIds,
      otherIds: otherIds,
      notAttemptedIds: notAttemptedIds,
    );
  }
}
