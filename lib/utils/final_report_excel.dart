import '../core/utils/audit_status.dart';
import '../models/audit_detail_model.dart';
import '../models/nc_report_model.dart' show NcBucket;
import 'report_sections.dart';
import 'report_sheet_spec.dart';

/// utils/final_report_excel.dart
/// ───────────────────────────────
/// The sheets of the phone's three Final Report downloads (Audits | NCs |
/// Repeated NCs), as [ReportWorkbookSpec]s — a line-for-line Dart port of the web
/// app's client/src/utils/finalReportExcel.js, so a file made on the phone reads
/// exactly like the one made on the web: same sheets, same column names in the
/// same order, same tallies, same colours.
///
/// Pure — rows in, sheet descriptions out. Fetching lives in
/// final_report_download.dart, the .xlsx bytes in xlsx_report_writer.dart.
///
/// Every workbook is the same shape: a Summary (the filters applied + the stat
/// tiles the tab shows), the detail rows — ONE ROW PER AUDIT-AT-A-LOCATION / PER
/// NC, each naming its location, who raised it and who it is against, so it
/// filters and sorts in Excel — and "By Location / By Auditor / By Auditee"
/// tallies (the Excel version of the page's Group by location, and the answer to
/// "how many at this place, from this person, against that person").
///
/// The rows are the server's JSON as it arrived (GET /audits/report, /ncs/report,
/// /ncs/repeats and /ncs/repeats/rows): nothing here decides who may see what, and
/// no status, bucket or score is derived on the device — a status is the server's
/// `displayStatus`, a NC's stage its `bucket`, an audit's score its `scoreResult`.
/// The one number worked out here is a ZONE's score inside a "per-location" audit,
/// by the same sum-then-divide helper the report screen and the PDF use.

/// The three Final Report tabs — and so the three workbooks.
enum FinalReportTab { audits, ncs, repeats }

/// "Audits" / "NCs" / "Repeated NCs" — the tab's own name.
String finalReportTabLabel(FinalReportTab tab) => switch (tab) {
  FinalReportTab.audits => 'Audits',
  FinalReportTab.ncs => 'NCs',
  FinalReportTab.repeats => 'Repeated NCs',
};

/// The file name WITHOUT ".xlsx": `Final-Report-<Audits|NCs|Repeated-NCs>-<yyyy-MM-dd>`,
/// the day it was made (the phone's own calendar day).
String finalReportFileBase(FinalReportTab tab, DateTime when) {
  final d = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final word = switch (tab) {
    FinalReportTab.audits => 'Audits',
    FinalReportTab.ncs => 'NCs',
    FinalReportTab.repeats => 'Repeated-NCs',
  };
  return 'Final-Report-$word-${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// [finalReportFileBase] with its extension.
String finalReportFileName(FinalReportTab tab, DateTime when) => '${finalReportFileBase(tab, when)}.xlsx';

// ── Cell colours (the same families the app's badges use) ───────────────────

const _green = '#15803d';
const _amber = '#b45309';
const _red = '#b91c1c';

/// Whole-percent score, thresholds as everywhere else in the app (75 / 50). No
/// score (null / blank) is no colour — never red, and never 0%.
ReportTone? scoreTone(Object? pct) {
  final n = _asNum(pct);
  if (n == null) return null;
  return ReportTone(fg: n >= 75 ? _green : n >= 50 ? _amber : _red);
}

// The web's AUDIT_STATUS_COLORS (utils/auditDisplayStatus.js), text colour only.
const _auditStatusFg = <String, String>{
  'Draft': '#64748b',
  AuditStatus.notStarted: '#6b7280',
  AuditStatus.inProgress: '#2563eb',
  AuditStatus.overdue: '#e11d48',
  AuditStatus.delayedCompleted: '#ea580c',
  AuditStatus.onTimeCompleted: '#16a34a',
  AuditStatus.ncResponsePending: '#ca8a04',
  AuditStatus.ncVerificationPending: '#7c3aed',
  AuditStatus.totalClosed: '#0d9488',
  AuditStatus.completed: '#16a34a',
  AuditStatus.skipped: '#ef4444',
};

ReportTone? auditStatusTone(Object? label) {
  final fg = _auditStatusFg[label];
  return fg == null ? null : ReportTone(fg: fg);
}

ReportTone? timelinessTone(Object? label) =>
    label == 'On-Time' ? const ReportTone(fg: _green) : label == 'Delayed' ? const ReportTone(fg: _red) : null;

ReportTone? flagTone(Object? flag) =>
    flag == 'Major' ? const ReportTone(fg: '#dc2626') : flag == 'Minor' ? const ReportTone(fg: '#d97706') : null;

/// The five NC stages (the NC tiles) with the colour each is drawn in — the web's NC_BUCKET_META.
const _bucketColors = <String, String>{
  NcBucket.inProgress: '#0ea5e9',
  NcBucket.overdue: '#ef4444',
  NcBucket.pendingApproval: '#db2777',
  NcBucket.delayed: '#f59e0b',
  NcBucket.onTime: '#22c55e',
};

ReportTone? stageTone(Object? label) {
  for (final b in NcBucket.all) {
    if (NcBucket.label(b) == label) return ReportTone(fg: _bucketColors[b]);
  }
  return null;
}

// The NC's own lifecycle status in the words the NC screens use.
const _ncStatusLabel = <String, String>{
  'Raised': 'Awaiting response',
  'Response Submitted': 'Response submitted',
  'Verification': 'Under verification',
  'Closed': 'Closed',
};
const _ncStatusColor = <String, String>{
  'Awaiting response': '#dc2626',
  'Response submitted': '#d97706',
  'Under verification': '#7c3aed',
  'Closed': '#16a34a',
};

ReportTone? ncStatusTone(Object? label) {
  final fg = _ncStatusColor[label];
  return fg == null ? null : ReportTone(fg: fg);
}

/// Major stays Major; everything else (Minor, the retired "Observation", nothing) is Minor.
String flagOf(Object? severity) => severity == 'Major' ? 'Major' : 'Minor';

// ── Small shared helpers ────────────────────────────────────────────────────

num? _asNum(Object? v) {
  if (v is num) return v;
  if (v is String && v.trim().isNotEmpty) return num.tryParse(v);
  return null;
}

num _num0(Object? v) => _asNum(v) ?? 0;

String _str(Object? v) => v == null ? '' : v.toString();

Map? _asMap(Object? v) => v is Map ? v : null;

List _asList(Object? v) => v is List ? v : const [];

/// A date field (an ISO string from the server, or already a DateTime) as the
/// phone's own local time — the DAY the person sees on screen.
DateTime? asLocalDate(Object? v) {
  if (v is DateTime) return v.toLocal();
  if (v is String && v.trim().isNotEmpty) return DateTime.tryParse(v.trim())?.toLocal();
  return null;
}

/// Whole calendar days from [from] to [to] (negative when [to] is earlier); null
/// when either is missing or unreadable.
int? daysBetween(Object? from, Object? to) {
  final a = asLocalDate(from);
  final b = asLocalDate(to);
  if (a == null || b == null) return null;
  final da = DateTime(a.year, a.month, a.day);
  final db = DateTime(b.year, b.month, b.day);
  // Hours / 24, rounded: a daylight-saving day is 23 or 25 hours long.
  return (db.difference(da).inHours / 24).round();
}

String _nameOf(Object? employee) => _str(_asMap(employee)?['employeeName']);

String _namesOf(Object? list) => [for (final e in _asList(list)) _nameOf(e)].where((n) => n.isNotEmpty).join(', ');

String _distinctNames(Iterable<String> values) => <String>{...values.where((v) => v.isNotEmpty)}.join(', ');

/// `auditeeIds` (plural) is the source of truth; `auditeeId` only a fallback for an older record.
String auditeesOf(Map a) {
  final many = _namesOf(a['auditeeIds']);
  return many.isNotEmpty ? many : _nameOf(a['auditeeId']);
}

String _placeName(Object? l) {
  final m = _asMap(l);
  final name = _str(m?['name']);
  final code = _str(m?['code']);
  return '${name.isNotEmpty ? name : 'Deleted location'}${code.isNotEmpty ? ' ($code)' : ''}';
}

String _departmentName(Object? d) {
  final m = _asMap(d);
  final name = _str(m?['departmentName']);
  final code = _str(m?['departmentCode']);
  return '${name.isNotEmpty ? name : 'Deleted department'}${code.isNotEmpty ? ' ($code)' : ''}';
}

/// Where an audit is held: its locations and departments by name (with codes).
String auditPlaceLabel(Map a) => [
  for (final l in _asList(a['locationIds']))
    if (l != null) _placeName(l),
  for (final d in _asList(a['departmentIds']))
    if (d != null) _departmentName(d),
].join(', ');

int? _pctOf(num achieved, num possible) => possible > 0 ? (achieved / possible * 100).round() : null;

int _byCountThenName(Map<String, Object?> a, Map<String, Object?> b, String key) {
  final byCount = (b[key] as int).compareTo(a[key] as int);
  return byCount != 0 ? byCount : _localeCompare(_str(a['name']), _str(b['name']));
}

// JavaScript's localeCompare, near enough for names: case-insensitive first, a
// lower-case letter before its capital on a tie.
int _localeCompare(String a, String b) {
  final byLetters = a.toLowerCase().compareTo(b.toLowerCase());
  return byLetters != 0 ? byLetters : b.compareTo(a);
}

// ── Audits ──────────────────────────────────────────────────────────────────

/// One zone of a "per-location" audit with its own score.
class ZoneSection {
  final String label;

  /// Whole percent over the zone's assessed checkpoints; null when none was
  /// assessed (a zone of only Not Applicable ones has no score — never 0%).
  final int? pct;
  final num achieved;
  final num max;

  const ZoneSection({required this.label, required this.pct, required this.achieved, required this.max});
}

typedef ZoneSectionsOf = List<ZoneSection> Function(Map audit);

/// The zones of ONE "per-location" audit document and each one's own score — the
/// web page's `ownZoneSections`: sum-then-divide over just that zone's scored
/// checkpoints (utils/report_sections.dart, the Dart port of
/// AuditReportShared.jsx), a Not Applicable checkpoint left out of both sums.
/// The Final Report list keeps the zone trees of such an audit, so no extra read
/// is needed. One section (or none) means a plain audit.
List<ZoneSection> zoneSectionsOf(Map audit) {
  final detail = AuditDetailModel.fromJson(Map<String, dynamic>.from(audit));
  final system = detail.scoringSystem == 'weightage' ? 'weightage' : 'normal';
  return [
    for (final section in buildReportSections(detail))
      () {
        final am = sumAchievedMax(collectScoredLeaves(section.tree), system, detail.maxScore);
        return ZoneSection(label: section.label, pct: percentageOf(am), achieved: am.achieved, max: am.max);
      }(),
  ];
}

/// Σ achieved / Σ possible over the COMPLETED zones of a bundle — never an average
/// of each zone's own %. Null while no zone has finished.
int? bundleScoreOf(List<Map> members) {
  num achieved = 0;
  num max = 0;
  for (final m in members) {
    if (m['status'] != AuditStatus.completed) continue;
    final sr = _asMap(m['scoreResult']);
    achieved += _num0(sr?['achieved']);
    max += _num0(sr?['maxPossible']);
  }
  return _pctOf(achieved, max);
}

String? _batchIdOf(Map a) {
  final raw = a['scheduleBatchId'];
  final id = raw is Map ? raw['_id'] : raw;
  final s = _str(id);
  return s.isEmpty ? null : s;
}

/// The audits an export lists (one entry per bundle) and the bundle id -> members
/// map — the web's groupAuditsForExport, minus the tile row tests: on the phone a
/// tile pick is a `status` the SERVER already filtered by.
({List<Map> visible, Map<String, List<Map>> groups}) groupAuditsForExport(List<Map> audits) {
  final groups = <String, List<Map>>{};
  for (final a in audits) {
    final id = _batchIdOf(a);
    if (id != null) groups.putIfAbsent(id, () => []).add(a);
  }
  final seen = <String>{};
  final visible = <Map>[];
  for (final a in audits) {
    final id = _batchIdOf(a);
    if (id == null || (groups[id]?.length ?? 0) <= 1 || seen.add(id)) visible.add(a);
  }
  return (visible: visible, groups: groups);
}

Map<String, Object?> _auditRow(Map a, {String bundle = '', ZoneSection? zone}) {
  final finished = a['status'] == AuditStatus.completed;
  final sr = _asMap(a['scoreResult']);
  final nc = _asMap(a['ncSummary']);
  final ncTotal = _num0(nc?['total']).toInt();
  final ncClosed = _num0(nc?['closed']).toInt();
  final recurrence = _asMap(a['recurrence']);
  final timeliness = switch (_str(a['timeliness'])) {
    AuditStatus.onTimeCompleted => 'On-Time',
    AuditStatus.delayedCompleted => 'Delayed',
    _ => '',
  };
  final status = _str(a['displayStatus']).isNotEmpty ? _str(a['displayStatus']) : _str(a['status']);
  return {
    'auditNo': _str(a['auditNumber']),
    'title': _str(a['title']),
    'type': _str(a['auditType']),
    'bundle': bundle,
    'place': zone?.label ?? auditPlaceLabel(a),
    'auditors': _namesOf(a['auditorIds']),
    'auditees': auditeesOf(a),
    'start': asLocalDate(a['scheduledDate']),
    'due': asLocalDate(a['scheduledEndDate']),
    'completed': asLocalDate(a['completedDate']),
    'status': status,
    'timeliness': timeliness,
    // Only a COMPLETED audit has a final score (the screen shows "—" otherwise), and
    // one with nothing assessed has a null percentage — blank here, never 0%.
    'score': zone != null ? (finished ? zone.pct : null) : (finished ? _asNum(sr?['percentage']) : null),
    'achieved': zone != null ? (finished ? zone.achieved : null) : (finished ? _num0(sr?['achieved']) : null),
    'possible': zone != null ? (finished ? zone.max : null) : (finished ? _num0(sr?['maxPossible']) : null),
    'ncTotal': ncTotal,
    'ncOpen': (ncTotal - ncClosed) < 0 ? 0 : ncTotal - ncClosed,
    'repeat': _str(recurrence?['frequency']),
    'finished': finished,
  };
}

/// The rows of the Audits sheet and the bundle summaries.
class AuditExport {
  final List<Map<String, Object?>> rows;
  final List<Map<String, Object?>> bundles;

  const AuditExport({required this.rows, required this.bundles});
}

/// One row per audit at a location. A bundle (several audits sharing
/// scheduleBatchId) gives a row per zone, each under its own location; a
/// "per-location" audit gives a row per zone (via [sectionsOf], the page's own
/// per-zone scorer); a plain audit is one row. Returns the rows plus one summary
/// per bundle. [audits] is every audit the server returned, in its order.
AuditExport auditExportRows(
  List<Map> audits, {
  ZoneSectionsOf? sectionsOf = zoneSectionsOf,
  int? Function(List<Map> members) bundleScore = bundleScoreOf,
}) {
  final grouped = groupAuditsForExport(audits);
  final rows = <Map<String, Object?>>[];
  final bundles = <Map<String, Object?>>[];
  for (final a in grouped.visible) {
    final id = _batchIdOf(a);
    final members = id == null ? null : grouped.groups[id];
    if (members != null && members.length > 1) {
      for (final m in members) {
        rows.add(_auditRow(m, bundle: _str(a['title'])));
      }
      String batchStatus = '';
      for (final m in members) {
        if (_str(m['batchDisplayStatus']).isNotEmpty) {
          batchStatus = _str(m['batchDisplayStatus']);
          break;
        }
      }
      DateTime? lastCompleted;
      for (final m in members) {
        final d = asLocalDate(m['completedDate']);
        if (d != null && (lastCompleted == null || d.isAfter(lastCompleted))) lastCompleted = d;
      }
      bundles.add({
        'title': _str(a['title']),
        'zones': members.length,
        'auditors': _distinctNames([for (final m in members) _namesOf(m['auditorIds'])]),
        'auditees': _distinctNames([for (final m in members) auditeesOf(m)]),
        'status': batchStatus.isNotEmpty
            ? batchStatus
            : _distinctNames([
                for (final m in members) _str(m['displayStatus']).isNotEmpty ? _str(m['displayStatus']) : _str(m['status']),
              ]),
        'completed': lastCompleted,
        'score': bundleScore(members),
      });
      continue;
    }
    if (a['structureMode'] == 'per-location' && sectionsOf != null) {
      final sections = sectionsOf(a);
      if (sections.length > 1) {
        for (final s in sections) {
          rows.add(_auditRow(a, zone: s));
        }
        continue;
      }
    }
    rows.add(_auditRow(a));
  }
  return AuditExport(rows: rows, bundles: bundles);
}

/// Per-key tallies of audit rows ("By Location" / "By Auditor" / "By Auditee").
/// [keysOf] may name several keys (an audit with two auditors counts for each);
/// the score is Σ achieved / Σ possible over the finished rows — never an average
/// of percentages.
List<Map<String, Object?>> tallyAuditRows(List<Map<String, Object?>> rows, List<String> Function(Map<String, Object?> row) keysOf) {
  final map = <String, Map<String, Object?>>{};
  for (final r in rows) {
    for (final key in <String>{...keysOf(r).where((k) => k.isNotEmpty)}) {
      final g = map.putIfAbsent(key, () => {
        'name': key,
        'audits': 0,
        'inProgress': 0,
        'overdue': 0,
        'notStarted': 0,
        'onTime': 0,
        'delayed': 0,
        'skipped': 0,
        'notAttempted': 0,
        'achieved': 0.0,
        'possible': 0.0,
      });
      void bump(String k) => g[k] = (g[k] as int) + 1;
      bump('audits');
      switch (r['status']) {
        case AuditStatus.inProgress:
          bump('inProgress');
        case AuditStatus.overdue:
          bump('overdue');
        case AuditStatus.notStarted:
          bump('notStarted');
        case AuditStatus.skipped:
          bump('skipped');
        case AuditStatus.notAttempted:
          bump('notAttempted');
      }
      if (r['finished'] == true) {
        if (r['timeliness'] == 'On-Time') {
          bump('onTime');
        } else if (r['timeliness'] == 'Delayed') {
          bump('delayed');
        }
        g['achieved'] = (g['achieved'] as double) + _num0(r['achieved']);
        g['possible'] = (g['possible'] as double) + _num0(r['possible']);
      }
    }
  }
  final out = [
    for (final g in map.values) {...g, 'score': _pctOf(g['achieved'] as double, g['possible'] as double)},
  ]..sort((a, b) => _byCountThenName(a, b, 'audits'));
  return out;
}

List<String> _splitNames(Object? text) => _str(text).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

List<ReportColumn> _auditTallyColumns(String label) => [
  ReportColumn(header: label, key: 'name', width: 34, wrap: true),
  const ReportColumn(header: 'Audits', key: 'audits', width: 10, format: ReportFormat.integer),
  const ReportColumn(header: 'In Progress', key: 'inProgress', width: 12, format: ReportFormat.integer),
  const ReportColumn(header: 'Overdue', key: 'overdue', width: 10, format: ReportFormat.integer),
  const ReportColumn(header: 'Not Started', key: 'notStarted', width: 12, format: ReportFormat.integer),
  const ReportColumn(header: 'On-Time Completed', key: 'onTime', width: 14, format: ReportFormat.integer),
  const ReportColumn(header: 'Delayed Completed', key: 'delayed', width: 14, format: ReportFormat.integer),
  const ReportColumn(header: 'Skipped', key: 'skipped', width: 10, format: ReportFormat.integer),
  const ReportColumn(header: 'Not Attempted', key: 'notAttempted', width: 13, format: ReportFormat.integer),
  const ReportColumn(header: 'Marks Achieved', key: 'achieved', width: 13, format: ReportFormat.number),
  const ReportColumn(header: 'Marks Possible', key: 'possible', width: 13, format: ReportFormat.number),
  const ReportColumn(header: 'Score %', key: 'score', width: 10, format: ReportFormat.percent, tone: _scoreToneFn),
];

ReportTone? _scoreToneFn(Object? v, Map<String, Object?> row) => scoreTone(v);
ReportTone? _auditStatusToneFn(Object? v, Map<String, Object?> row) => auditStatusTone(v);
ReportTone? _timelinessToneFn(Object? v, Map<String, Object?> row) => timelinessTone(v);
ReportTone? _flagToneFn(Object? v, Map<String, Object?> row) => flagTone(v);
ReportTone? _stageToneFn(Object? v, Map<String, Object?> row) => stageTone(v);
ReportTone? _ncStatusToneFn(Object? v, Map<String, Object?> row) => ncStatusTone(v);
ReportTone? _redWhenPositive(Object? v, Map<String, Object?> row) {
  final n = _asNum(v);
  return n != null && n > 0 ? const ReportTone(fg: '#dc2626') : null;
}

ReportTotals _auditTotals(List<Map<String, Object?>> tallies) {
  num sum(String key) => tallies.fold<num>(0, (n, g) => n + (g[key] as num));
  final achieved = sum('achieved');
  final possible = sum('possible');
  return ReportTotals(values: {
    'audits': sum('audits'),
    'inProgress': sum('inProgress'),
    'overdue': sum('overdue'),
    'notStarted': sum('notStarted'),
    'onTime': sum('onTime'),
    'delayed': sum('delayed'),
    'skipped': sum('skipped'),
    'notAttempted': sum('notAttempted'),
    'achieved': achieved,
    'possible': possible,
    'score': _pctOf(achieved, possible),
  });
}

/// What the Summary says when the stat tiles could not be read for this file.
const statsMissingNote =
    'The stat tiles could not be loaded for this file — the detail sheets below are complete.';

/// The Audits tab's workbook. [stats] is the SAME tile data the tab shows (GET
/// /audits/report/stats), so the Summary's tiles are exactly what is on screen;
/// null (the request failed) leaves the tiles out and says so.
ReportWorkbookSpec buildAuditsReport({
  required List<Map<String, Object?>> rows,
  List<Map<String, Object?>> bundles = const [],
  Map? stats,
  List<ReportFilterLine> filters = const [],
  String generatedBy = '',
  required DateTime generatedAt,
  List<String> extraNotes = const [],
}) {
  final numbered = [for (var i = 0; i < rows.length; i++) {...rows[i], 'no': i + 1}];
  final places = tallyAuditRows(rows, (r) => [_str(r['place']).isEmpty ? '—' : _str(r['place'])]);
  final auditors = tallyAuditRows(rows, (r) => _splitNames(r['auditors']));
  final auditees = tallyAuditRows(rows, (r) => _splitNames(r['auditees']));

  ReportTileGroup? overview;
  if (stats != null) {
    final s = stats;
    final pct = _asNum(s['percentage']);
    int count(String k) => _num0(s[k]).toInt();
    overview = ReportTileGroup(title: 'Audit overview', tiles: [
      ReportTile(
        label: 'Total Score',
        value: pct,
        format: ReportFormat.percent,
        color: pct == null ? '#64748b' : pct >= 75 ? '#16a34a' : pct >= 50 ? '#d97706' : '#dc2626',
        note: s['isPartial'] == true ? 'Includes audits still in progress' : 'Marks achieved / marks possible',
      ),
      ReportTile(label: 'Total Audits', value: _asNum(s['totalAudits'] ?? s['total']) ?? 0, color: '#6366f1'),
      ReportTile(label: 'In Progress', value: count('inProgress'), color: '#0ea5e9'),
      ReportTile(label: 'Overdue', value: count('overdue'), color: '#dc2626'),
      if (count('notStarted') > 0) ReportTile(label: 'Not Started', value: count('notStarted'), color: '#64748b'),
      ReportTile(label: 'On-Time Completed', value: count('onTimeCompleted'), color: '#16a34a'),
      ReportTile(label: 'Delayed Completed', value: count('delayedCompleted'), color: '#dc2626'),
      if (count('skipped') > 0) ReportTile(label: 'Skipped', value: count('skipped'), color: '#94a3b8'),
      // The phone's own "Other" tile (a bundle that fits no bucket), so the tiles add up to Total Audits.
      if (count('other') > 0) ReportTile(label: 'Other', value: count('other'), color: '#64748b'),
      if (count('notAttempted') > 0)
        ReportTile(label: 'Not Attempted', value: count('notAttempted'), color: '#b91c1c', note: 'Not counted in Total Audits'),
    ]);
  }

  final sheets = <ReportSheet>[
    ReportSummarySheet(
      tileGroups: [
        ?overview,
        ReportTileGroup(title: 'In this file', tiles: [
          ReportTile(label: 'Rows (audit × location)', value: rows.length, color: '#6366f1'),
          ReportTile(label: 'Locations', value: places.length, color: '#0ea5e9'),
          ReportTile(label: 'Auditors', value: auditors.length, color: '#16a34a'),
          ReportTile(label: 'Auditees', value: auditees.length, color: '#d97706'),
          if (bundles.isNotEmpty) ReportTile(label: 'Multi-location bundles', value: bundles.length, color: '#7c3aed'),
        ]),
      ],
      notes: [
        'Each row of the Audits sheet is one audit at one location. A multi-location bundle or a per-location audit has a row per location.',
        'Score is marks achieved / marks possible over finished audits — never an average of percentages.',
        'A blank Score % means no score is calculated: the audit is not finished, or every checkpoint was Not Applicable.',
        if (stats == null) statsMissingNote,
        ...extraNotes,
      ],
    ),
    ReportDataSheet(
      name: 'Audits',
      title: 'Final Report — Audits',
      freezeColumns: 3,
      columns: const [
        ReportColumn(header: '#', key: 'no', width: 6, format: ReportFormat.integer),
        ReportColumn(header: 'Audit No.', key: 'auditNo', width: 14),
        ReportColumn(header: 'Audit', key: 'title', width: 34, wrap: true),
        ReportColumn(header: 'Audit Type', key: 'type', width: 18, wrap: true),
        ReportColumn(header: 'Location / Zone', key: 'place', width: 28, wrap: true),
        ReportColumn(header: 'Auditor(s)', key: 'auditors', width: 24, wrap: true),
        ReportColumn(header: 'Auditee(s)', key: 'auditees', width: 24, wrap: true),
        ReportColumn(header: 'Bundle', key: 'bundle', width: 24, wrap: true),
        ReportColumn(header: 'Repeats', key: 'repeat', width: 12),
        ReportColumn(header: 'Start', key: 'start', width: 13, format: ReportFormat.date),
        ReportColumn(header: 'Due', key: 'due', width: 13, format: ReportFormat.date),
        ReportColumn(header: 'Completed', key: 'completed', width: 13, format: ReportFormat.date),
        ReportColumn(header: 'Status', key: 'status', width: 24, wrap: true, tone: _auditStatusToneFn),
        ReportColumn(header: 'Timeliness', key: 'timeliness', width: 12, tone: _timelinessToneFn),
        ReportColumn(header: 'Score %', key: 'score', width: 10, format: ReportFormat.percent, tone: _scoreToneFn),
        ReportColumn(header: 'Marks Achieved', key: 'achieved', width: 12, format: ReportFormat.number),
        ReportColumn(header: 'Marks Possible', key: 'possible', width: 12, format: ReportFormat.number),
        ReportColumn(header: 'NCs Raised', key: 'ncTotal', width: 11, format: ReportFormat.integer),
        ReportColumn(header: 'NCs Open', key: 'ncOpen', width: 10, format: ReportFormat.integer),
      ],
      rows: numbered,
    ),
    if (bundles.isNotEmpty)
      ReportDataSheet(
        name: 'Bundles',
        title: 'Final Report — Multi-location bundles',
        columns: const [
          ReportColumn(header: 'Bundle', key: 'title', width: 36, wrap: true),
          ReportColumn(header: 'Locations', key: 'zones', width: 11, format: ReportFormat.integer),
          ReportColumn(header: 'Auditor(s)', key: 'auditors', width: 28, wrap: true),
          ReportColumn(header: 'Auditee(s)', key: 'auditees', width: 28, wrap: true),
          ReportColumn(header: 'Status', key: 'status', width: 24, wrap: true, tone: _auditStatusToneFn),
          ReportColumn(header: 'Last Completed', key: 'completed', width: 14, format: ReportFormat.date),
          ReportColumn(header: 'Combined Score %', key: 'score', width: 16, format: ReportFormat.percent, tone: _scoreToneFn),
        ],
        rows: bundles,
      ),
    ReportDataSheet(
      name: 'By Location',
      title: 'Final Report — Audits by location',
      columns: _auditTallyColumns('Location / Zone'),
      rows: places,
      totals: _auditTotals(places),
    ),
    ReportDataSheet(name: 'By Auditor', title: 'Final Report — Audits by auditor', columns: _auditTallyColumns('Auditor'), rows: auditors),
    ReportDataSheet(name: 'By Auditee', title: 'Final Report — Audits by auditee', columns: _auditTallyColumns('Auditee'), rows: auditees),
  ];
  return ReportWorkbookSpec(
    filename: finalReportFileBase(FinalReportTab.audits, generatedAt),
    title: 'Final Report — Audits',
    filters: filters,
    generatedBy: generatedBy,
    generatedAt: generatedAt,
    sheets: sheets,
  );
}

// ── NCs ─────────────────────────────────────────────────────────────────────

/// One row per NC — location, who raised it (auditor) and who it is against
/// (auditee) included. [now] only decides "days open" / "days late" for an NC
/// that is not closed yet.
List<Map<String, Object?>> ncExportRows(List<Map> ncs, {DateTime? now}) {
  final at = now ?? DateTime.now();
  return [
    for (var i = 0; i < ncs.length; i++)
      () {
        final n = ncs[i];
        final completion = asLocalDate(n['completionDate']);
        final closed = n['status'] == 'Closed' && completion != null;
        final end = completion ?? at;
        final late = asLocalDate(n['targetDate']) != null ? daysBetween(n['targetDate'], end) : null;
        final audit = _asMap(n['auditId']);
        final bucket = _str(n['bucket']);
        final status = _str(n['status']);
        return <String, Object?>{
          'no': i + 1,
          'ncId': _str(n['ncId']),
          'title': _str(n['title']),
          'description': _str(n['description']),
          'flag': flagOf(n['severity']),
          'audit': _str(audit?['title']).isNotEmpty ? _str(audit?['title']) : 'Audit deleted',
          'auditType': _str(audit?['auditType']),
          'place': [n['placeLabel'], n['locationName'], n['departmentName']].map(_str).firstWhere((s) => s.isNotEmpty, orElse: () => ''),
          'raisedBy': _nameOf(n['raisedByEmployeeId']),
          'against': _nameOf(n['auditeeEmployeeId']),
          'raised': asLocalDate(n['startDate']),
          'target': asLocalDate(n['targetDate']),
          'completed': closed ? completion : null,
          'stage': NcBucket.all.contains(bucket) ? NcBucket.label(bucket) : '',
          'bucket': bucket,
          'status': _ncStatusLabel[status] ?? status,
          'daysTaken': daysBetween(n['startDate'], end),
          'daysLate': late != null && late > 0 ? late : null,
          'ats': _asNum(n['atsScore']),
          'repeats': _num0(n['repeatCount']).toInt(),
          'reopened': _num0(n['reopenCount']).toInt(),
          'correction': _str(n['correctionAction']),
          'rootCause': _str(n['rootCause']),
          'corrective': _str(n['correctiveAction']),
          'preventive': _str(n['preventiveAction']),
          'verification': _str(n['verificationNote']),
        };
      }(),
  ];
}

List<Map<String, Object?>> tallyNcRows(List<Map<String, Object?>> rows, List<String> Function(Map<String, Object?> row) keysOf) {
  final map = <String, Map<String, Object?>>{};
  for (final r in rows) {
    for (final key in <String>{...keysOf(r).where((k) => k.isNotEmpty)}) {
      final g = map.putIfAbsent(key, () => {
        'name': key,
        'total': 0,
        for (final b in NcBucket.all) b: 0,
        'major': 0,
        'minor': 0,
        'repeats': 0,
      });
      void bump(String k) => g[k] = (g[k] as int) + 1;
      bump('total');
      final bucket = _str(r['bucket']);
      if (NcBucket.all.contains(bucket)) bump(bucket);
      bump(r['flag'] == 'Major' ? 'major' : 'minor');
      if ((r['repeats'] as int? ?? 0) > 0) bump('repeats');
    }
  }
  return map.values.toList()..sort((a, b) => _byCountThenName(a, b, 'total'));
}

List<ReportColumn> _ncTallyColumns(String label) => [
  ReportColumn(header: label, key: 'name', width: 34, wrap: true),
  const ReportColumn(header: 'Total NC', key: 'total', width: 10, format: ReportFormat.integer),
  for (final b in NcBucket.all)
    ReportColumn(
      header: NcBucket.label(b),
      key: b,
      width: 14,
      format: ReportFormat.integer,
      tone: (v, row) => (_asNum(v) ?? 0) > 0 ? ReportTone(fg: _bucketColors[b]) : null,
    ),
  const ReportColumn(header: 'Major', key: 'major', width: 9, format: ReportFormat.integer),
  const ReportColumn(header: 'Minor', key: 'minor', width: 9, format: ReportFormat.integer),
  const ReportColumn(header: 'Repeat NCs', key: 'repeats', width: 11, format: ReportFormat.integer),
];

ReportTotals _ncTotals(List<Map<String, Object?>> tallies) {
  num sum(String key) => tallies.fold<num>(0, (n, g) => n + (g[key] as num));
  return ReportTotals(values: {
    for (final k in ['total', ...NcBucket.all, 'major', 'minor', 'repeats']) k: sum(k),
  });
}

/// The NCs tab's workbook. [stats] = GET /ncs/report/stats under the filters
/// WITHOUT the lit tile (what the tiles show); null leaves the tiles out and says so.
ReportWorkbookSpec buildNcsReport({
  required List<Map<String, Object?>> rows,
  Map? stats,
  List<ReportFilterLine> filters = const [],
  String generatedBy = '',
  required DateTime generatedAt,
  List<String> extraNotes = const [],
}) {
  final places = tallyNcRows(rows, (r) => [_str(r['place']).isEmpty ? '—' : _str(r['place'])]);
  final raisers = tallyNcRows(rows, (r) => [_str(r['raisedBy'])]);
  final targets = tallyNcRows(rows, (r) => [_str(r['against'])]);
  final major = rows.where((r) => r['flag'] == 'Major').length;

  final groups = <ReportTileGroup>[];
  if (stats != null) {
    final s = stats;
    groups.add(ReportTileGroup(title: 'NC overview', tiles: [
      ReportTile(
        label: 'Total NC',
        value: _asNum(s['total']) ?? 0,
        color: '#6366f1',
        note: 'In Progress + Overdue + Pending Approval + Delayed + On Time',
      ),
      for (final b in NcBucket.all) ReportTile(label: NcBucket.label(b), value: _asNum(s[b]) ?? 0, color: _bucketColors[b]!),
    ]));
    groups.add(ReportTileGroup(title: 'Speed of action', tiles: [
      ReportTile(
        label: 'Action-taken speed (ATS)',
        value: _asNum(s['atsScore']),
        format: ReportFormat.percent,
        decimals: 1,
        color: '#16a34a',
        note: "Average of closed NCs' turnaround scores",
      ),
      ReportTile(
        label: 'On-time closure (OTC)',
        value: _asNum(s['otcScore']),
        format: ReportFormat.percent,
        decimals: 1,
        color: '#0ea5e9',
        note: 'Closed on time / all due',
      ),
    ]));
  }
  groups.add(ReportTileGroup(title: 'In this file', tiles: [
    ReportTile(label: 'NCs listed', value: rows.length, color: '#6366f1'),
    ReportTile(label: 'Major', value: major, color: '#dc2626'),
    ReportTile(label: 'Minor', value: rows.length - major, color: '#d97706'),
    ReportTile(label: 'Locations', value: places.length, color: '#0ea5e9'),
    ReportTile(label: 'Raised by (auditors)', value: raisers.length, color: '#16a34a'),
    ReportTile(label: 'Against (auditees)', value: targets.length, color: '#7c3aed'),
  ]));

  return ReportWorkbookSpec(
    filename: finalReportFileBase(FinalReportTab.ncs, generatedAt),
    title: 'Final Report — NCs',
    filters: filters,
    generatedBy: generatedBy,
    generatedAt: generatedAt,
    sheets: [
      ReportSummarySheet(
        tileGroups: groups,
        notes: [
          "The tiles count every NC the filters match; the NCs sheet lists the NCs under the lit stat tile (none lit = all of them).",
          if (stats == null) statsMissingNote,
          ...extraNotes,
        ],
      ),
      ReportDataSheet(
        name: 'NCs',
        title: 'Final Report — NCs',
        freezeColumns: 3,
        columns: const [
          ReportColumn(header: '#', key: 'no', width: 6, format: ReportFormat.integer),
          ReportColumn(header: 'NC ID', key: 'ncId', width: 10),
          ReportColumn(header: 'NC / Checkpoint', key: 'title', width: 36, wrap: true),
          ReportColumn(header: 'Flag', key: 'flag', width: 9, tone: _flagToneFn),
          ReportColumn(header: 'Location / Zone', key: 'place', width: 26, wrap: true),
          ReportColumn(header: 'Raised By (Auditor)', key: 'raisedBy', width: 22, wrap: true),
          ReportColumn(header: 'Against (Auditee)', key: 'against', width: 22, wrap: true),
          ReportColumn(header: 'Audit', key: 'audit', width: 30, wrap: true),
          ReportColumn(header: 'Audit Type', key: 'auditType', width: 16, wrap: true),
          ReportColumn(header: 'Raised On', key: 'raised', width: 13, format: ReportFormat.date),
          ReportColumn(header: 'Target Date', key: 'target', width: 13, format: ReportFormat.date),
          ReportColumn(header: 'Completed On', key: 'completed', width: 13, format: ReportFormat.date),
          ReportColumn(header: 'Stage', key: 'stage', width: 18, tone: _stageToneFn),
          ReportColumn(header: 'Status', key: 'status', width: 19, tone: _ncStatusToneFn),
          ReportColumn(header: 'Days Taken / Open', key: 'daysTaken', width: 12, format: ReportFormat.integer),
          ReportColumn(header: 'Days Late', key: 'daysLate', width: 10, format: ReportFormat.integer, tone: _redWhenPositive),
          ReportColumn(header: 'ATS %', key: 'ats', width: 9, format: ReportFormat.percent),
          ReportColumn(header: 'Times Before', key: 'repeats', width: 11, format: ReportFormat.integer, tone: _redWhenPositive),
          ReportColumn(header: 'Reopened', key: 'reopened', width: 10, format: ReportFormat.integer),
          ReportColumn(header: 'Description', key: 'description', width: 40, wrap: true),
          ReportColumn(header: 'Correction', key: 'correction', width: 34, wrap: true),
          ReportColumn(header: 'Root Cause', key: 'rootCause', width: 34, wrap: true),
          ReportColumn(header: 'Corrective Action', key: 'corrective', width: 34, wrap: true),
          ReportColumn(header: 'Preventive Action', key: 'preventive', width: 34, wrap: true),
          ReportColumn(header: "Auditor's Note", key: 'verification', width: 34, wrap: true),
        ],
        rows: rows,
      ),
      ReportDataSheet(name: 'By Location', title: 'Final Report — NCs by location', columns: _ncTallyColumns('Location / Zone'), rows: places, totals: _ncTotals(places)),
      ReportDataSheet(name: 'By Auditor', title: 'Final Report — NCs by who raised them', columns: _ncTallyColumns('Raised By (Auditor)'), rows: raisers, totals: _ncTotals(raisers)),
      ReportDataSheet(name: 'By Auditee', title: 'Final Report — NCs by who they are against', columns: _ncTallyColumns('Against (Auditee)'), rows: targets, totals: _ncTotals(targets)),
    ],
  );
}

// ── Repeated NCs ────────────────────────────────────────────────────────────

String _repeatPlace(Map row) {
  final parts = [_str(row['locationName']), _str(row['departmentName'])].where((s) => s.isNotEmpty);
  return parts.isEmpty ? 'No place' : parts.join(' · ');
}

/// [groups] = the repeated checkpoints (GET /ncs/repeats rows), [ncsById] = id ->
/// NC (GET /ncs/repeats/rows). A group lists at most its newest ncIds, so `listed`
/// may be less than `count` (the Details sheet says which time each one was).
({List<Map<String, Object?>> groupRows, List<Map<String, Object?>> detailRows}) repeatExportRows(
  List<Map> groups,
  Map<String, Map> ncsById,
) {
  final groupRows = <Map<String, Object?>>[];
  final detailRows = <Map<String, Object?>>[];
  for (var gi = 0; gi < groups.length; gi++) {
    final g = groups[gi];
    final ncs = [
      for (final id in _asList(g['ncIds']))
        if (ncsById[_str(id)] != null) ncsById[_str(id)]!,
    ]..sort((a, b) {
        final da = asLocalDate(a['startDate']) ?? asLocalDate(a['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        final db = asLocalDate(b['startDate']) ?? asLocalDate(b['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0);
        return da.compareTo(db);
      });
    final place = _repeatPlace(g);
    final count = _num0(g['count']).toInt();
    final openCount = _num0(g['openCount']).toInt();
    final latest = _str(g['latestStatus']);
    groupRows.add({
      'no': gi + 1,
      'title': _str(g['title']),
      'place': place,
      'count': count,
      'open': openCount,
      'closed': (count - openCount) < 0 ? 0 : count - openCount,
      'first': asLocalDate(g['firstDate']),
      'last': asLocalDate(g['lastDate']),
      'latest': _ncStatusLabel[latest] ?? latest,
      'raisedBy': _distinctNames([for (final n in ncs) _nameOf(n['raisedByEmployeeId'])]),
      'against': _distinctNames([for (final n in ncs) _nameOf(n['auditeeEmployeeId'])]),
      'audits': {
        for (final n in ncs)
          () {
            final a = n['auditId'];
            return _str(a is Map ? a['_id'] : a);
          }(),
      }.length,
      'listed': ncs.length,
      'key': _str(g['key']),
    });
    final skippedOlder = (count - ncs.length) < 0 ? 0 : count - ncs.length;
    for (var idx = 0; idx < ncs.length; idx++) {
      final n = ncs[idx];
      final status = _str(n['status']);
      detailRows.add({
        'title': _str(g['title']),
        'place': place,
        'occurrence': skippedOlder + idx + 1,
        'count': count,
        'ncId': _str(n['ncId']),
        'audit': _str(_asMap(n['auditId'])?['title']).isNotEmpty ? _str(_asMap(n['auditId'])?['title']) : 'Audit deleted',
        'raised': asLocalDate(n['startDate']),
        'raisedBy': _nameOf(n['raisedByEmployeeId']),
        'against': _nameOf(n['auditeeEmployeeId']),
        'flag': flagOf(n['severity']),
        'status': _ncStatusLabel[status] ?? status,
        'target': asLocalDate(n['targetDate']),
        'completed': status == 'Closed' ? asLocalDate(n['completionDate']) : null,
        'closed': status == 'Closed',
        'groupKey': _str(g['key']),
      });
    }
  }
  return (groupRows: groupRows, detailRows: detailRows);
}

List<Map<String, Object?>> _tallyRepeatPlaces(List<Map<String, Object?>> groupRows, List<Map<String, Object?>> detailRows) {
  final map = <String, Map<String, Object?>>{};
  for (final g in groupRows) {
    final place = _str(g['place']);
    final t = map.putIfAbsent(place, () => {'name': place, 'checkpoints': 0, 'ncs': 0, 'open': 0, 'major': 0});
    t['checkpoints'] = (t['checkpoints'] as int) + 1;
    t['ncs'] = (t['ncs'] as int) + (g['count'] as int);
    t['open'] = (t['open'] as int) + (g['open'] as int);
  }
  for (final d in detailRows) {
    final t = map[_str(d['place'])];
    if (d['flag'] == 'Major' && t != null) t['major'] = (t['major'] as int) + 1;
  }
  return map.values.toList()..sort((a, b) => _byCountThenName(a, b, 'ncs'));
}

List<Map<String, Object?>> _tallyRepeatPeople(List<Map<String, Object?>> detailRows, String Function(Map<String, Object?> d) personOf) {
  final map = <String, Map<String, Object?>>{};
  for (final d in detailRows) {
    final key = personOf(d);
    if (key.isEmpty) continue;
    final t = map.putIfAbsent(key, () => {'name': key, 'ncs': 0, 'open': 0, 'checkpoints': <String>{}, 'places': <String>{}, 'major': 0});
    t['ncs'] = (t['ncs'] as int) + 1;
    if (d['closed'] != true) t['open'] = (t['open'] as int) + 1;
    if (d['flag'] == 'Major') t['major'] = (t['major'] as int) + 1;
    (t['checkpoints'] as Set<String>).add(_str(d['groupKey']));
    (t['places'] as Set<String>).add(_str(d['place']));
  }
  return [
    for (final t in map.values)
      {...t, 'checkpoints': (t['checkpoints'] as Set<String>).length, 'places': (t['places'] as Set<String>).length},
  ]..sort((a, b) => _byCountThenName(a, b, 'ncs'));
}

/// The Repeated NCs tab's workbook. [minCount] is the "Min. times" pick.
ReportWorkbookSpec buildRepeatsReport({
  required List<Map> groups,
  required Map<String, Map> ncsById,
  int minCount = 2,
  List<ReportFilterLine> filters = const [],
  String generatedBy = '',
  required DateTime generatedAt,
  List<String> extraNotes = const [],
}) {
  final built = repeatExportRows(groups, ncsById);
  final groupRows = built.groupRows;
  final detailRows = built.detailRows;
  final places = _tallyRepeatPlaces(groupRows, detailRows);
  final raisers = _tallyRepeatPeople(detailRows, (d) => _str(d['raisedBy']));
  final targets = _tallyRepeatPeople(detailRows, (d) => _str(d['against']));
  final totalNcs = groupRows.fold<int>(0, (n, g) => n + (g['count'] as int));
  final openNcs = groupRows.fold<int>(0, (n, g) => n + (g['open'] as int));
  Map<String, Object?>? worst;
  for (final g in groupRows) {
    if (worst == null || (g['count'] as int) > (worst['count'] as int)) worst = g;
  }
  final trimmed = groupRows.where((g) => (g['listed'] as int) < (g['count'] as int)).length;
  final min = minCount < 2 ? 2 : minCount;

  List<ReportColumn> personColumns(String label) => [
    ReportColumn(header: label, key: 'name', width: 34, wrap: true),
    const ReportColumn(header: 'Repeat NCs', key: 'ncs', width: 12, format: ReportFormat.integer),
    const ReportColumn(header: 'Still Open', key: 'open', width: 11, format: ReportFormat.integer),
    const ReportColumn(header: 'Major', key: 'major', width: 9, format: ReportFormat.integer),
    const ReportColumn(header: 'Checkpoints', key: 'checkpoints', width: 12, format: ReportFormat.integer),
    const ReportColumn(header: 'Locations', key: 'places', width: 11, format: ReportFormat.integer),
  ];

  final notes = <String>[
    'A repeated checkpoint is the same checkpoint wording raised $min+ times at the same place — capitals, extra spaces and trailing punctuation do not make a different wording.',
    if (trimmed > 0)
      '$trimmed checkpoint${trimmed == 1 ? '' : 's'} were raised more often than the list holds — the Repeat NC Details sheet shows the newest NCs of those ("Time #" says which time each one was).',
    ...extraNotes,
  ];

  num sumOf(List<Map<String, Object?>> list, String k) => list.fold<num>(0, (n, p) => n + (p[k] as num));

  return ReportWorkbookSpec(
    filename: finalReportFileBase(FinalReportTab.repeats, generatedAt),
    title: 'Final Report — Repeated NCs',
    filters: filters,
    generatedBy: generatedBy,
    generatedAt: generatedAt,
    sheets: [
      ReportSummarySheet(
        tileGroups: [
          ReportTileGroup(title: 'Repeated NC overview', tiles: [
            ReportTile(label: 'Repeated checkpoints', value: groupRows.length, color: '#dc2626', note: 'Raised $min+ times at one place'),
            ReportTile(label: 'NCs in these repeats', value: totalNcs, color: '#6366f1'),
            ReportTile(label: 'Still open', value: openNcs, color: '#d97706'),
            ReportTile(label: 'Fully closed checkpoints', value: groupRows.where((g) => g['open'] == 0).length, color: '#16a34a'),
            ReportTile(label: 'Locations affected', value: places.length, color: '#0ea5e9'),
            ReportTile(
              label: 'Most repeated',
              value: worst != null ? '×${worst['count']}' : '—',
              color: '#7c3aed',
              note: worst != null ? _str(worst['title']) : '',
            ),
          ]),
        ],
        notes: notes,
      ),
      ReportDataSheet(
        name: 'Repeated Checkpoints',
        title: 'Final Report — Repeated checkpoints',
        freezeColumns: 3,
        columns: [
          const ReportColumn(header: '#', key: 'no', width: 6, format: ReportFormat.integer),
          const ReportColumn(header: 'Checkpoint', key: 'title', width: 40, wrap: true),
          const ReportColumn(header: 'Location / Zone', key: 'place', width: 28, wrap: true),
          ReportColumn(
            header: 'Times Raised',
            key: 'count',
            width: 12,
            format: ReportFormat.integer,
            tone: (v, row) {
              final n = _asNum(v) ?? 0;
              return n >= 5 ? const ReportTone(fg: '#dc2626') : n >= 3 ? const ReportTone(fg: '#d97706') : null;
            },
          ),
          ReportColumn(
            header: 'Open',
            key: 'open',
            width: 9,
            format: ReportFormat.integer,
            tone: (v, row) => (_asNum(v) ?? 0) > 0 ? const ReportTone(fg: '#d97706') : const ReportTone(fg: '#16a34a'),
          ),
          const ReportColumn(header: 'Closed', key: 'closed', width: 9, format: ReportFormat.integer),
          const ReportColumn(header: 'First Raised', key: 'first', width: 13, format: ReportFormat.date),
          const ReportColumn(header: 'Last Raised', key: 'last', width: 13, format: ReportFormat.date),
          const ReportColumn(header: 'Latest Status', key: 'latest', width: 19, tone: _ncStatusToneFn),
          const ReportColumn(header: 'Raised By (Auditors)', key: 'raisedBy', width: 30, wrap: true),
          const ReportColumn(header: 'Against (Auditees)', key: 'against', width: 30, wrap: true),
          const ReportColumn(header: 'Audits', key: 'audits', width: 9, format: ReportFormat.integer),
        ],
        rows: groupRows,
      ),
      ReportDataSheet(
        name: 'Repeat NC Details',
        title: 'Final Report — Every NC of the repeated checkpoints',
        freezeColumns: 2,
        columns: const [
          ReportColumn(header: 'Checkpoint', key: 'title', width: 38, wrap: true),
          ReportColumn(header: 'Location / Zone', key: 'place', width: 26, wrap: true),
          ReportColumn(header: 'Time #', key: 'occurrence', width: 8, format: ReportFormat.integer),
          ReportColumn(header: 'Of Total', key: 'count', width: 9, format: ReportFormat.integer),
          ReportColumn(header: 'NC ID', key: 'ncId', width: 10),
          ReportColumn(header: 'Raised On', key: 'raised', width: 13, format: ReportFormat.date),
          ReportColumn(header: 'Audit', key: 'audit', width: 30, wrap: true),
          ReportColumn(header: 'Raised By (Auditor)', key: 'raisedBy', width: 22, wrap: true),
          ReportColumn(header: 'Against (Auditee)', key: 'against', width: 22, wrap: true),
          ReportColumn(header: 'Flag', key: 'flag', width: 9, tone: _flagToneFn),
          ReportColumn(header: 'Status', key: 'status', width: 19, tone: _ncStatusToneFn),
          ReportColumn(header: 'Target Date', key: 'target', width: 13, format: ReportFormat.date),
          ReportColumn(header: 'Completed On', key: 'completed', width: 13, format: ReportFormat.date),
        ],
        rows: detailRows,
      ),
      ReportDataSheet(
        name: 'By Location',
        title: 'Final Report — Repeats by location',
        columns: const [
          ReportColumn(header: 'Location / Zone', key: 'name', width: 34, wrap: true),
          ReportColumn(header: 'Repeated Checkpoints', key: 'checkpoints', width: 20, format: ReportFormat.integer),
          ReportColumn(header: 'NCs in Repeats', key: 'ncs', width: 15, format: ReportFormat.integer),
          ReportColumn(header: 'Still Open', key: 'open', width: 11, format: ReportFormat.integer),
          ReportColumn(header: 'Major (listed)', key: 'major', width: 13, format: ReportFormat.integer),
        ],
        rows: places,
        totals: ReportTotals(values: {
          'checkpoints': sumOf(places, 'checkpoints'),
          'ncs': sumOf(places, 'ncs'),
          'open': sumOf(places, 'open'),
          'major': sumOf(places, 'major'),
        }),
      ),
      ReportDataSheet(name: 'By Auditor', title: 'Final Report — Repeat NCs by who raised them', columns: personColumns('Raised By (Auditor)'), rows: raisers),
      ReportDataSheet(name: 'By Auditee', title: 'Final Report — Repeat NCs by who they are against', columns: personColumns('Against (Auditee)'), rows: targets),
    ],
  );
}
