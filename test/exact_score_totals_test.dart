import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/report_stats.dart';
import 'package:internal_audit_app/core/utils/score_math.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/profile/reports_screen.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/report_pdf_builder.dart';
import 'package:internal_audit_app/utils/report_sections.dart';
import 'package:internal_audit_app/utils/report_sheet_spec.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// "Bug 6": scores must never be SHOWN with decimals, so an audit's `achieved` / `maxPossible` are whole numbers - but adding
/// up ROUNDED numbers gives wrong totals. A weighted audit of two checkpoints (weight 3 at full marks, weight 1 at half) is
/// exactly 3.5 out of 4 = 87.5% (88%); its achieved rounds to 4, so it is stored "4 of 4". Three such audits added up as
/// rounded numbers are 12 of 12 = 100%. The server now sends the exact totals beside the whole ones (`achievedExact` /
/// `maxPossibleExact`, server/utils/scoring.js); everything here that ADDS UP scores adds up those and rounds only the final
/// percentage, once - and keeps every number it SHOWS a whole one. An audit without the exact fields (an older audit or
/// server) combines exactly as it always did.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── the data: one audit of weight 3 at 10/10 and weight 1 at 5/10 ────────────────────────────────────────────────────
  const strong = ParameterNode(id: 'a', name: 'Fire exit', findingType: 'Strong Compliance', score: 10, weightage: 3);
  const half = ParameterNode(id: 'b', name: 'Bins', findingType: 'OFI', score: 5, weightage: 1);

  /// What the server stores for that audit: "4 of 4" for display, 3.5 / 4 exactly, 88%.
  Map<String, dynamic> weighted({bool withExact = true}) => {
    'achieved': 4,
    'maxPossible': 4,
    if (withExact) 'achievedExact': 3.5,
    if (withExact) 'maxPossibleExact': 4,
    'percentage': 88,
    'scoredCount': 2,
    'leafCount': 2,
    'isFullyScored': true,
  };

  AuditModel audit(
    String id, {
    bool withExact = true,
    String status = 'Completed',
    String? batch,
    String? location,
    double? got = 4,
    double? of = 4,
  }) => AuditModel(
    id: id,
    title: id,
    scope: '',
    status: status,
    timeliness: status == 'Completed' ? 'On-Time Completed' : null,
    scheduleBatchId: batch,
    location: location ?? '',
    scoreAchieved: got,
    scoreMax: of,
    scoreAchievedExact: withExact ? 3.5 : null,
    scoreMaxExact: withExact ? 4 : null,
  );

  // ── (a) the example itself ───────────────────────────────────────────────────────────────────────────────────────────
  group('the weight-3 / weight-1 example (3.5 of 4)', () {
    test('rawAchievedMax is exactly 3.5 / 4', () {
      final raw = rawAchievedMax([strong, half], 'weightage', 10);
      expect(raw.achieved, 3.5);
      expect(raw.max, 4);
    });

    test('is 88%, not the 100% that "4 of 4" would give - while the numbers shown stay whole "4 of 4"', () {
      final am = sumAchievedMax([strong, half], 'weightage', 10);
      expect(am.achieved, 4, reason: 'shown: whole');
      expect(am.max, 4, reason: 'shown: whole');
      expect(am.achievedExact, 3.5);
      expect(am.maxExact, 4);
      expect(percentageOf(am), 88);
    });

    test('percentFrom rounds the percentage once, from exact totals', () {
      expect(percentFrom(3.5, 4), 88);
      expect(percentFrom(10.5, 12), 88);
      expect(percentFrom(0, 4), 0);
      expect(percentFrom(0, 0), isNull);
      expect(percentFrom(3, 0), isNull);
    });

    test('a normal-mode group (whole scores) is unchanged: exact = whole', () {
      const l1 = ParameterNode(id: 'x', name: 'x', findingType: 'Compliance', score: 8);
      const l2 = ParameterNode(id: 'y', name: 'y', findingType: 'OFI', score: 6);
      final am = sumAchievedMax([l1, l2], 'normal', 10);
      expect([am.achieved, am.max, am.achievedExact, am.maxExact], [14, 20, 14, 20]);
      expect(percentageOf(am), 70);
    });
  });

  // ── the models read the exact fields, and fall back when they are absent ─────────────────────────────────────────────
  group('reading the exact totals', () {
    test('AuditModel parses scoreResult.achievedExact / maxPossibleExact; absent = null, falling back to the whole numbers', () {
      final withExact = AuditModel.fromJson({'_id': 'a', 'title': 't', 'status': 'Completed', 'scoreResult': weighted()});
      expect([withExact.scoreAchieved, withExact.scoreMax], [4, 4]);
      expect([withExact.scoreAchievedExact, withExact.scoreMaxExact], [3.5, 4]);
      expect([withExact.exactScoreAchieved, withExact.exactScoreMax], [3.5, 4]);

      final older = AuditModel.fromJson({'_id': 'a', 'title': 't', 'status': 'Completed', 'scoreResult': weighted(withExact: false)});
      expect([older.scoreAchievedExact, older.scoreMaxExact], [isNull, isNull]);
      expect([older.exactScoreAchieved, older.exactScoreMax], [4, 4]);

      final none = AuditModel.fromJson({'_id': 'a', 'title': 't', 'status': 'Completed'});
      expect([none.exactScoreAchieved, none.exactScoreMax], [0, 0]);
    });

    test('AuditScoreResult (the detail) parses them too, with the same fallback', () {
      final r = AuditScoreResult.fromJson(weighted());
      expect([r.achieved, r.maxPossible, r.achievedExact, r.maxPossibleExact], [4, 4, 3.5, 4]);
      expect([r.exactAchieved, r.exactMaxPossible], [3.5, 4]);
      final older = AuditScoreResult.fromJson(weighted(withExact: false));
      expect([older.achievedExact, older.maxPossibleExact], [isNull, isNull]);
      expect([older.exactAchieved, older.exactMaxPossible], [4, 4]);
    });

    test('the stats answer and each byLocation row carry them; an older server\'s answer has none', () {
      final s = ReportStats.tryParse({
        'percentage': 88,
        'achieved': 11,
        'maxPossible': 12,
        'achievedExact': 10.5,
        'maxPossibleExact': 12,
        'byLocation': [
          {'key': 'Plant A', 'label': 'Plant A', 'count': 3, 'percentage': 88, 'achieved': 11, 'maxPossible': 12, 'achievedExact': 10.5, 'maxPossibleExact': 12},
        ],
      })!;
      expect([s.percentage, s.achieved, s.maxPossible, s.achievedExact, s.maxPossibleExact], [88, 11, 12, 10.5, 12]);
      final p = s.byLocation.single;
      expect([p.percentage, p.achieved, p.maxPossible, p.achievedExact, p.maxPossibleExact], [88, 11, 12, 10.5, 12]);
      expect(s.withByLocation(const []).achievedExact, 10.5, reason: 'the narrowed breakdown keeps the tiles\' totals');

      final older = ReportStats.tryParse({
        'percentage': 100,
        'achieved': 12,
        'maxPossible': 12,
        'byLocation': [
          {'key': 'Plant A', 'label': 'Plant A', 'count': 3, 'percentage': 100, 'achieved': 12, 'maxPossible': 12},
        ],
      })!;
      expect([older.achievedExact, older.maxPossibleExact], [isNull, isNull]);
      expect([older.byLocation.single.achievedExact, older.byLocation.single.maxPossibleExact], [isNull, isNull]);
      expect(older.percentage, 100, reason: 'the server\'s percentage is shown as it is');
    });
  });

  // ── (b)(c)(d) three such audits combine to 88%, not 100% ──────────────────────────────────────────────────────────────
  group('three such audits (each stored "4 of 4", exactly 3.5 / 4)', () {
    final three = [audit('a'), audit('b'), audit('c')];

    test('finishedScoreOf: 88%, shown as 11 of 12 - NOT 12 of 12 = 100%', () {
      final s = finishedScoreOf(three);
      expect(s.percentage, 88);
      expect(s.percentage, isNot(100));
      expect(s.achieved, 11, reason: 'round(10.5), the server\'s own rollup');
      expect(s.maxPossible, 12);
      expect(s.achievedExact, 10.5);
      expect(s.maxPossibleExact, 12);
    });

    test('ReportStats.fromAudits (the on-device tiles): 88%, shown as 11 of 12', () {
      final s = ReportStats.fromAudits(three);
      expect(s.percentage, 88);
      expect(s.achieved, 11);
      expect(s.maxPossible, 12);
      expect([s.achievedExact, s.maxPossibleExact], [10.5, 12]);
    });

    test('an audit with NO exact fields (an older server) combines exactly as before: 12 of 12 = 100%', () {
      final older = [audit('a', withExact: false), audit('b', withExact: false), audit('c', withExact: false)];
      final s = finishedScoreOf(older);
      expect([s.achieved, s.maxPossible, s.percentage], [12, 12, 100]);
      final stats = ReportStats.fromAudits(older);
      expect([stats.achieved, stats.maxPossible, stats.percentage], [12, 12, 100]);
      expect([stats.achievedExact, stats.maxPossibleExact], [12, 12]);
    });

    test('old and new audits mix: each contributes its exact totals, else its whole numbers', () {
      final s = finishedScoreOf([audit('a'), audit('b'), audit('c', withExact: false)]);
      expect([s.achievedExact, s.maxPossibleExact], [11, 12]); // 3.5 + 3.5 + 4
      expect(s.percentage, 92);
    });

    test('only Completed audits count, and the numbers shown stay whole', () {
      final s = ReportStats.fromAudits([...three, audit('open', status: 'In Progress', got: 10, of: 10)]);
      expect(s.percentage, 88);
      for (final v in [s.achieved, s.maxPossible]) {
        expect(v, v.roundToDouble(), reason: 'never a decimal');
      }
    });

    test('a bundle of three zones is one 88% group (and a group of one still reads its own 88%)', () {
      final s = ReportStats.fromAudits([for (final id in ['z1', 'z2', 'z3']) audit(id, batch: 'b')]);
      expect(s.completed, 1, reason: 'one bundle');
      expect(s.percentage, 88);
      expect(finishedScoreOf([audit('solo')]).percentage, 88);
    });
  });

  // ── (e) the Excel export ─────────────────────────────────────────────────────────────────────────────────────────────
  group('the Excel export', () {
    Map<String, dynamic> emp(String name) => {'_id': name, 'employeeName': name};

    Map<String, dynamic> row(String id, {bool withExact = true, Map<String, dynamic> over = const {}}) => {
      '_id': id,
      'title': 'Safety walk',
      'auditNumber': 'AUD-$id',
      'status': 'Completed',
      'displayStatus': 'Total Closed',
      'timeliness': 'On-Time Completed',
      'scheduledDate': '2026-09-01T00:00:00.000',
      'scheduledEndDate': '2026-09-05T00:00:00.000',
      'completedDate': '2026-09-04T00:00:00.000',
      'auditorIds': [emp('Asha')],
      'auditeeIds': [emp('Ravi')],
      'locationIds': [
        {'_id': 'l1', 'name': 'Plant 1', 'code': 'P1'},
      ],
      'departmentIds': <Object>[],
      'scoreResult': weighted(withExact: withExact),
      'ncSummary': {'total': 0, 'closed': 0},
      ...over,
    };

    ReportDataSheet sheet(ReportWorkbookSpec spec, String name) => spec.sheet(name)! as ReportDataSheet;

    test('each audit row shows its whole "4 / 4" and its own 88%', () {
      final r = auditExportRows([row('1')]).rows.single;
      expect([r['achieved'], r['possible'], r['score']], [4, 4, 88]);
    });

    test('a place adds up the exact totals: 88%, shown as 11 / 12 (not 12 / 12 = 100%)', () {
      final rows = auditExportRows([row('1'), row('2'), row('3')]).rows;
      final g = tallyAuditRows(rows, (r) => [r['place'] as String]).single;
      expect(g['audits'], 3);
      expect(g['score'], 88);
      expect(g['achieved'], 11);
      expect(g['possible'], 12);
    });

    test('the By Location / By Auditor / By Auditee sheets and their totals row all say 88%', () {
      final export = auditExportRows([row('1'), row('2'), row('3')]);
      final spec = buildAuditsReport(rows: export.rows, bundles: export.bundles, generatedAt: DateTime(2026, 10, 5, 9));
      for (final name in ['By Location', 'By Auditor', 'By Auditee']) {
        final g = sheet(spec, name).rows.single;
        expect([g['achieved'], g['possible'], g['score']], [11, 12, 88], reason: name);
      }
      final totals = sheet(spec, 'By Location').totals!.values;
      expect([totals['achieved'], totals['possible'], totals['score']], [11, 12, 88]);
      // ...and the Audits sheet keeps every audit's own whole "4 / 4".
      expect(sheet(spec, 'Audits').rows.map((r) => [r['achieved'], r['possible'], r['score']]), everyElement([4, 4, 88]));
    });

    test('rows without the exact fields (an older server) combine exactly as before', () {
      final export = auditExportRows([row('1', withExact: false), row('2', withExact: false), row('3', withExact: false)]);
      final g = tallyAuditRows(export.rows, (r) => [r['place'] as String]).single;
      expect([g['achieved'], g['possible'], g['score']], [12, 12, 100]);
      final spec = buildAuditsReport(rows: export.rows, generatedAt: DateTime(2026, 10, 5, 9));
      final totals = sheet(spec, 'By Location').totals!.values;
      expect([totals['achieved'], totals['possible'], totals['score']], [12, 12, 100]);
    });

    test('the totals row adds up the places\' exact totals too, not their rounded ones', () {
      // Two places of 3.5 / 4 each: each shows 4 / 4 and 88%; together 7 / 8 = 88%, not 8 / 8 = 100%.
      Map<String, dynamic> at(String id, String place) => row(id, over: {
        'locationIds': [
          {'_id': place, 'name': place},
        ],
      });
      final export = auditExportRows([at('1', 'A'), at('2', 'B')]);
      final spec = buildAuditsReport(rows: export.rows, generatedAt: DateTime(2026, 10, 5, 9));
      expect(sheet(spec, 'By Location').rows.map((g) => [g['achieved'], g['possible'], g['score']]), [
        [4, 4, 88],
        [4, 4, 88],
      ]);
      final totals = sheet(spec, 'By Location').totals!.values;
      expect([totals['achieved'], totals['possible'], totals['score']], [7, 8, 88]);
    });

    test('a bundle\'s combined score is 88% over its three zones', () {
      final zones = [
        for (final id in ['z1', 'z2', 'z3'])
          row(id, over: {
            'scheduleBatchId': 'b',
            'locationIds': [
              {'_id': id, 'name': 'Zone $id'},
            ],
          }),
      ];
      expect(bundleScoreOf(zones), 88);
      expect(auditExportRows(zones).bundles.single['score'], 88);
      expect(bundleScoreOf([for (final z in zones) {...z, 'scoreResult': weighted(withExact: false)}]), 100, reason: 'older audits: as before');
    });

    Map<String, dynamic> leaf(String id, String finding, num score, num weightage) => {
      '_id': id,
      'name': id,
      'findingType': finding,
      'score': score,
      'weightage': weightage,
      'children': <Object>[],
    };

    test('a per-location audit\'s zones: each is 88% shown as 4 / 4, and their auditor tally adds up exact (11 / 12, 88%)', () {
      List<Map<String, dynamic>> tree() => [leaf('a', 'Strong Compliance', 10, 3), leaf('b', 'OFI', 5, 1)];
      final a = row('1', over: {
        'structureMode': 'per-location',
        'scoringSystem': 'weightage',
        'maxScore': 10,
        'locationIds': [
          for (final z in ['z1', 'z2', 'z3']) {'_id': z, 'name': 'Zone $z'},
        ],
        'locationParameters': [
          for (final z in ['z1', 'z2', 'z3']) {'locationId': z, 'parameters': tree()},
        ],
      });
      final zones = zoneSectionsOf(a);
      expect(zones.map((z) => z.pct), [88, 88, 88]);
      expect(zones.map((z) => [z.achieved, z.max]), everyElement([4, 4]));
      expect(zones.map((z) => [z.achievedExact, z.maxExact]), everyElement([3.5, 4]));

      final rows = auditExportRows([a]).rows;
      expect(rows.map((r) => [r['achieved'], r['possible'], r['score']]), everyElement([4, 4, 88]));
      final auditor = tallyAuditRows(rows, (r) => [r['auditors'] as String]).single;
      expect([auditor['achieved'], auditor['possible'], auditor['score']], [11, 12, 88]);
    });
  });

  // ── the PDF ──────────────────────────────────────────────────────────────────────────────────────────────────────────
  group('the report PDF', () {
    Map<String, dynamic> leafJson(String id, String finding, num score, num weightage) => {
      '_id': id,
      'name': 'Checkpoint $id',
      'findingType': finding,
      'score': score,
      'weightage': weightage,
      'remark': 'seen',
      'photoUrls': <String>[],
      'children': <Map<String, dynamic>>[],
    };

    /// One weighted audit: ONE group holding the weight-3 checkpoint at 10/10 and the weight-1 one at 5/10.
    AuditDetailModel zone(String id, {Map<String, dynamic>? scoreResult}) => AuditDetailModel.fromJson({
      '_id': id,
      'title': 'Safety walk',
      'status': 'Completed',
      'displayStatus': 'Closed',
      'scoringSystem': 'weightage',
      'structureMode': 'same',
      'maxScore': 10,
      'scheduledDate': '2026-10-05T00:00:00.000Z',
      'scheduledEndDate': '2026-10-08T00:00:00.000Z',
      'completedDate': '2026-10-07T09:30:00.000Z',
      'auditorIds': [
        {'_id': 'u1', 'employeeName': 'Asha Verma'},
      ],
      'locationIds': [
        {'_id': id, 'name': 'Zone $id', 'code': 'Z$id'},
      ],
      'parameters': [
        {
          '_id': 'g$id',
          'name': 'Housekeeping',
          'children': [leafJson('${id}1', 'Strong Compliance', 10, 3), leafJson('${id}2', 'OFI', 5, 1)],
        },
      ],
      'scoreResult': scoreResult ?? weighted(),
    });

    /// The text drawn on the pages, in drawing order (the `pdf` package emits one `[(word)]TJ` per word).
    String textOf(Uint8List pdf) {
      final raw = latin1.decode(pdf);
      final words = <String>[];
      for (final m in RegExp(r'(?<!end)stream\r?\n').allMatches(raw)) {
        final end = raw.indexOf('endstream', m.end);
        if (end < 0) continue;
        List<int> data;
        try {
          data = ZLibCodec().decode(pdf.sublist(m.end, end));
        } catch (_) {
          continue;
        }
        final text = latin1.decode(data, allowInvalid: true);
        for (final t in RegExp(r'\[\(((?:\\.|[^\\)])*)\)\]TJ').allMatches(text)) {
          words.add(t.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (e) => e.group(1)!));
        }
      }
      return words.join(' ');
    }

    // The em dash is drawn through a fallback font a test does not have; every pattern says "a dash, if there is one".
    const dash = r'(?:—\s+)?';

    test('one audit with no stored percentage (older server): the report works the 88% out from the raw sums, not "4 of 4"', () async {
      final text = textOf(await buildReportPdf(zone('1', scoreResult: const {})));
      expect(text, matches(RegExp('FINAL\\s+SCORE\\s+${dash}4/4\\s+${dash}88%')));
      expect(text, matches(RegExp(r'88%\s+SCORE')), reason: 'the header ring');
      expect(text, isNot(contains('100%')));
    });

    test('the group\'s AVG SCORE is out of 10 from the exact totals: 3.5 / 4 = 9 (not 10), still shown as "Total: 4/4"', () async {
      final text = textOf(await buildReportPdf(zone('1')));
      expect(text, matches(RegExp(r'AVG\s+SCORE\s+9\s*/10\s+Total:\s+4/4')));
    });

    test('a combined report of three such zones: every zone 88%, the FINAL SCORE 88% as 11 / 12 - not 12 / 12 = 100%', () async {
      final text = textOf(await buildCombinedReportPdf([zone('1'), zone('2'), zone('3')]));
      expect(text, matches(RegExp('Zone\\s+1\\s+\\(Z1\\)\\s+SUBTOTAL\\s+${dash}4/4\\s+${dash}88%')));
      expect(text, matches(RegExp('FINAL\\s+SCORE\\s+${dash}11/12\\s+${dash}88%')));
      expect(text, matches(RegExp(r'88%\s+SCORE')), reason: 'the header ring (the stored percentages, rolled up exactly)');
      expect(text, isNot(contains('100%')));
      expect(text, isNot(contains('12/12')));
    });

    test('a combined report of zones WITHOUT the exact fields (older server) rolls the whole numbers up as it always did', () async {
      final older = weighted(withExact: false);
      final text = textOf(await buildCombinedReportPdf([zone('1', scoreResult: older), zone('2', scoreResult: older)]));
      // The ring is the rolled-up stored numbers (8 / 8 = 100%), exactly as before...
      expect(text, matches(RegExp(r'100%\s+SCORE')));
      // ...while the index table, which works from the checkpoints themselves, is exact: 7 / 8 = 88%.
      expect(text, matches(RegExp('FINAL\\s+SCORE\\s+${dash}7/8\\s+${dash}88%')));
    });
  });

  // ── the Reports tab on the phone ─────────────────────────────────────────────────────────────────────────────────────
  group('Reports screen', () {
    late FakeAdapter adapter;
    List<Map<String, dynamic>> rows = [];
    Object? stats;

    Map<String, dynamic> row(
      String id, {
      bool withExact = true,
      String? batch,
      String? location,
      String? title,
    }) => {
      '_id': id,
      'title': title ?? id,
      'scope': '',
      'status': 'Completed',
      'displayStatus': 'Total Closed',
      'timeliness': 'On-Time Completed',
      'scheduleBatchId': ?batch,
      if (batch != null) 'batchDisplayStatus': 'Total Closed',
      'scheduledDate': DateTime.now().toUtc().toIso8601String(),
      'completedDate': DateTime.now().toUtc().toIso8601String(),
      'auditorIds': [
        {'_id': 'u1', 'employeeName': 'Asha'},
      ],
      'scoreResult': weighted(withExact: withExact),
      'locationIds': [
        if (location != null) {'_id': location, 'name': location},
      ],
    };

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      rows = [];
      stats = null;
      adapter = FakeAdapter()
        ..handler = (o) async {
          switch (o.path) {
            case ApiConstants.auditsReport:
              return json(200, {
                'isOk': true,
                'data': {'audits': rows, 'total': rows.length, 'page': 1, 'limit': 100},
              });
            case ApiConstants.auditsReportStats:
              return stats == null ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': stats});
          }
          return json(200, {'isOk': true, 'data': []});
        };
      DioClient.instance.dio.httpClientAdapter = adapter;
      SocketService.debugInstance = FakeSockets().service;
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuditsProvider()..setSelfEmployeeId('me')),
            ChangeNotifierProvider(create: (_) => NcProvider()..setSelfEmployeeId('me')),
            ChangeNotifierProvider(create: (_) => DashboardProvider()),
            ChangeNotifierProvider(create: (_) => AuthProvider()),
            ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
            ChangeNotifierProvider(create: (_) => ListViewMemory()),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const ReportsScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    String tile(WidgetTester tester, String id) => tester
        .widget<Text>(find.descendant(of: find.byKey(ValueKey('report-tile-$id')), matching: find.byType(Text)).first)
        .data!;

    testWidgets('no stats answer: the Total Score tile worked out from the rows is 88% (11 / 12 pts), not 100%', (tester) async {
      rows = [row('a'), row('b'), row('c')];
      stats = null; // 403: the tiles are worked out from the rows
      await pump(tester);

      expect(tile(tester, 'score'), '88%');
      expect(find.text('11 / 12 pts'), findsOneWidget, reason: 'the points shown stay whole numbers');
      expect(find.text('100%'), findsNothing);
      expect(find.text('12 / 12 pts'), findsNothing);
    });

    testWidgets('a batch of three such zones reads 88% on its row, and the on-device place header does too', (tester) async {
      rows = [for (final id in ['z1', 'z2', 'z3']) row(id, batch: 'b', title: 'Safety walk', location: 'Plant A')];
      stats = null;
      await pump(tester);

      expect(tile(tester, 'score'), '88%');
      expect(find.text('88%'), findsNWidgets(2), reason: 'the tile and the batch row');
      expect(find.text('100%'), findsNothing);

      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();
      expect(find.textContaining('· 88%'), findsOneWidget, reason: 'the Plant A header: all three audits, exactly');
      expect(find.textContaining('100%'), findsNothing);
    });

    testWidgets('rows without the exact fields (an older server) read exactly as before: 100%', (tester) async {
      rows = [row('a', withExact: false), row('b', withExact: false), row('c', withExact: false)];
      stats = null;
      await pump(tester);

      expect(tile(tester, 'score'), '100%');
      expect(find.text('12 / 12 pts'), findsOneWidget);
    });

    testWidgets('the server\'s own tiles are shown as sent: 88% and 11 / 12 pts', (tester) async {
      rows = [row('a'), row('b'), row('c')];
      stats = {
        'percentage': 88,
        'achieved': 11,
        'maxPossible': 12,
        'achievedExact': 10.5,
        'maxPossibleExact': 12,
        'isPartial': false,
        'totalAudits': 3,
        'total': 3,
        'completed': 3,
        'onTimeCompleted': 3,
        'delayedCompleted': 0,
        'byLocation': [],
      };
      await pump(tester);

      expect(tile(tester, 'score'), '88%');
      expect(find.text('11 / 12 pts'), findsOneWidget);
    });
  });

  // ── the Parameter Score chart in the PDF ─────────────────────────────────────────────────────────────────────────────
  // It used to average every checkpoint once, so a weight-3 checkpoint at 10/10 and a weight-1 one at 5/10 drew 75% while
  // the table and the header ring (which weight them) said 88%.
  group('the report PDF Parameter Score chart', () {
    final group = ParameterNode(id: 'g', name: 'Housekeeping', children: const [strong, half]);

    test('a weightage audit weights each checkpoint: 3 x 100% and 1 x 50% is 88%, matching the table', () {
      expect(parameterChartDataForTest([group], 'weightage', maxScore: 10), [('Housekeeping', 88)]);
    });

    test('a normal audit counts every checkpoint once: 100% and 50% is 75%', () {
      expect(parameterChartDataForTest([group], 'normal', maxScore: 10), [('Housekeeping', 75)]);
    });

    test('a checkpoint with no weightage counts as the audit max, and a not-scored one is left out', () {
      const plain = ParameterNode(id: 'c', name: 'Plain', findingType: 'OFI', score: 5);
      const unscored = ParameterNode(id: 'd', name: 'Not yet', weightage: 9);
      final mixed = ParameterNode(id: 'g2', name: 'Mixed', children: const [strong, plain, unscored]);
      // weights 3 (100%) and 10 (50%) -> (3 + 5) / 13 = 61.5% -> 62
      expect(parameterChartDataForTest([mixed], 'weightage', maxScore: 10), [('Mixed', 62)]);
    });
  });
}
