import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/utils/report_pdf_builder.dart';
import 'package:internal_audit_app/utils/report_sections.dart';

/// A checkpoint marked "Not Applicable" in the phone's reports (ported from the reference app, adapted to this one's rule).
///
/// It is HANDLED (the server counts it as scored, so the audit can be completed without it) but stands outside the score:
/// it adds nothing to the achieved total AND nothing to the maximum. The numbers here are the server's own
/// (server/utils/scoring.test.js uses the same cases), so the phone's report can never disagree with the web's.
///
/// What this app's report shows of it: the checkpoint is still LISTED — a grey "N/A" row in the index, a grey card in the
/// findings — but is not calculated: no tile, tally, average, subtotal or FINAL SCORE counts it, and a group of nothing but
/// Not Applicable checkpoints shows "—" (never 0) for its score.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ParameterNode scored(String id, String finding, double score, {double? weightage}) =>
      ParameterNode(id: id, name: id, findingType: finding, score: score, weightage: weightage, remark: 'seen');
  ParameterNode notApplicable(String id, {double? score, double? weightage}) =>
      ParameterNode(id: id, name: id, findingType: 'Not Applicable', score: score, weightage: weightage);
  ParameterNode blank(String id) => ParameterNode(id: id, name: id);

  Map<String, dynamic> leafJson(String id, String name, String? finding, {num? score, String? remark, num? weightage}) => {
    '_id': id,
    'name': name,
    'findingType': finding,
    'score': score,
    'remark': remark,
    'weightage': weightage,
    'photoUrls': <String>[],
    'children': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> groupJson(String id, String name, List<Map<String, dynamic>> children) => {
    '_id': id,
    'name': name,
    'children': children,
  };

  const places = {
    'L1': {'_id': 'L1', 'name': 'Assembly Line 1', 'code': 'AL1'},
    'L2': {'_id': 'L2', 'name': 'Paint Shop', 'code': 'PS'},
  };

  AuditDetailModel audit({
    required Map<String, List<Map<String, dynamic>>> trees,
    required Map<String, dynamic> scoreResult,
    String status = 'Completed',
    String scoringSystem = 'normal',
  }) => AuditDetailModel.fromJson({
    '_id': 'a1',
    'title': '5S Review - Plant 1',
    'status': status,
    'displayStatus': status == 'Completed' ? 'Closed' : 'In Progress',
    'scoringSystem': scoringSystem,
    'structureMode': 'per-location',
    'maxScore': 10,
    'scheduledDate': '2026-10-05T00:00:00.000Z',
    'scheduledEndDate': '2026-10-08T00:00:00.000Z',
    'completedDate': status == 'Completed' ? '2026-10-07T09:30:00.000Z' : null,
    'auditorIds': [
      {'_id': 'u1', 'employeeName': 'Asha Verma'},
    ],
    'locationIds': [for (final id in trees.keys) places[id]],
    'locationParameters': [
      for (final e in trees.entries) {'locationId': e.key, 'parameters': e.value},
    ],
    'parameters': <Map<String, dynamic>>[],
    'scoreResult': scoreResult,
  });

  group('collecting the leaves', () {
    final tree = [
      ParameterNode(
        id: 'g',
        name: 'Group',
        children: [scored('a', 'Compliance', 5), notApplicable('b'), blank('c')],
      ),
      notApplicable('d'),
      scored('e', 'NC', 0),
    ];

    test('the assessed ones are the findings only: a Not Applicable one and a blank one are not among them', () {
      expect(collectScoredLeaves(tree).map((n) => n.id), ['a', 'e']);
    });

    test('the Not Applicable ones are collected on their own, at any depth', () {
      expect(collectNotApplicableLeaves(tree).map((n) => n.id), ['b', 'd']);
      expect(collectNotApplicableLeaves(const []), isEmpty);
    });

    test('the note says how many are left out of the score', () {
      expect(notApplicableNote(1), '1 checkpoint not applicable — left out of the score');
      expect(notApplicableNote(3), '3 checkpoints not applicable — left out of the score');
    });

    test('the report still has every section and every checkpoint — Not Applicable ones are listed, not removed', () {
      final a = audit(
        trees: {
          'L1': [leafJson('c1', 'Floor is clean', 'Compliance', score: 10, remark: 'ok')],
          'L2': [leafJson('n1', 'Booth filters changed', 'Not Applicable')],
        },
        scoreResult: const {},
      );
      final sections = buildReportSections(a);
      expect(sections.map((s) => s.label), ['Assembly Line 1 (AL1)', 'Paint Shop (PS)']);
      expect(sections.last.tree.single.isNotApplicable, isTrue);
    });
  });

  group('the score leaves it out (the server\'s scoring.test.js, case for case)', () {
    test('normal: the percentage is what it would be without the checkpoint', () {
      final withNa = [scored('a', 'Compliance', 5), scored('b', 'Compliance', 3), notApplicable('c')];
      final without = [scored('a', 'Compliance', 5), scored('b', 'Compliance', 3)];
      final am = sumAchievedMax(collectScoredLeaves(withNa), 'normal', 5);
      expect(am.achieved, 8);
      expect(am.max, 10);
      expect(percentageOf(am), 80);
      expect(percentageOf(sumAchievedMax(collectScoredLeaves(without), 'normal', 5)), 80);
    });

    test('an NC (scored 0) still pulls it down — only Not Applicable is excluded', () {
      final tree = [scored('a', 'Compliance', 5), scored('b', 'NC', 0), notApplicable('c')];
      final am = sumAchievedMax(collectScoredLeaves(tree), 'normal', 5);
      expect(percentageOf(am), 50);
      expect(am.max, 10);
    });

    test('across several places it is summed first and divided once', () {
      final place1 = [
        ParameterNode(id: 'g', name: 'Group', children: [scored('a', 'Compliance', 5), notApplicable('b')]),
      ];
      final place2 = [scored('c', 'Compliance', 2), notApplicable('d')];
      final raw1 = rawAchievedMax(collectScoredLeaves(place1), 'normal', 5);
      final raw2 = rawAchievedMax(collectScoredLeaves(place2), 'normal', 5);
      expect(raw1.achieved + raw2.achieved, 7);
      expect(raw1.max + raw2.max, 10);
    });

    test('weightage: it adds neither its ratio nor its weightage', () {
      final tree = [
        scored('a', 'Compliance', 5, weightage: 20),
        scored('b', 'NC', 0, weightage: 20),
        notApplicable('c', weightage: 60),
      ];
      final am = sumAchievedMax(collectScoredLeaves(tree), 'weightage', 5);
      expect(am.achieved, 20);
      expect(am.max, 40);
      expect(percentageOf(am), 50);
    });

    test('a stray score on one is ignored, even if the leaf is handed in directly', () {
      final am = rawAchievedMax([scored('a', 'Compliance', 5), notApplicable('b', score: 5)], 'normal', 5);
      expect(am.achieved, 5);
      expect(am.max, 5);
    });

    test('when EVERY checkpoint is Not Applicable there is nothing to grade: no percentage, never 0%', () {
      final tree = [notApplicable('a'), notApplicable('b')];
      final am = sumAchievedMax(collectScoredLeaves(tree), 'normal', 5);
      expect(am.achieved, 0);
      expect(am.max, 0);
      expect(percentageOf(am), isNull);
    });

    test('a group of only Not Applicable ones has no percentage (shows —), while a mixed group does', () {
      final onlyNa = ParameterNode(id: 'g', name: 'g', children: [notApplicable('a'), notApplicable('b')]);
      final mixed = ParameterNode(id: 'm', name: 'm', children: [scored('c', 'Compliance', 10), notApplicable('d')]);
      expect(percentageOf(sumAchievedMax(collectScoredLeaves([onlyNa]), 'normal', 10)), isNull);
      expect(percentageOf(sumAchievedMax(collectScoredLeaves([mixed]), 'normal', 10)), 100);
    });
  });

  // ── the report PDF ────────────────────────────────────────────────────────

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

  int occurrences(String text, String needle) => RegExp(RegExp.escape(needle)).allMatches(text).length;

  // The em dash is drawn through the fallback font the app fetches at run time, which a test does not have: it drops out of
  // the extracted text. Every pattern below says "a dash, if there is one", so it holds with and without the font.
  const dash = r'(?:—\s+)?';

  // Two places. Assembly Line 1: Housekeeping [Compliance 10, OFI 6, N/A], Strong 10. Paint Shop: a group that is ALL Not
  // Applicable, and one OFI 6.
  //   assessed: 10 + 6 + 10 + 6 = 32 of 40 = 80%   (Assembly Line 1 26/30 = 87%, Paint Shop 6/10 = 60%)
  const mixedScore = {
    'achieved': 32,
    'maxPossible': 40,
    'percentage': 80,
    'scoredCount': 7,
    'leafCount': 7,
    'notApplicableCount': 3,
    'isFullyScored': true,
  };
  AuditDetailModel mixed({String status = 'Completed'}) => audit(
    status: status,
    trees: {
      'L1': [
        groupJson('g1', 'Housekeeping', [
          leafJson('c1', 'Floor is clean', 'Compliance', score: 10, remark: 'In order'),
          leafJson('c2', 'Bins are emptied', 'OFI', score: 6, remark: 'Mostly'),
          leafJson('n1', 'Overhead crane checked', 'Not Applicable'),
        ]),
        leafJson('c3', 'Fire exit is clear', 'Strong Compliance', score: 10, remark: 'Clear'),
      ],
      'L2': [
        groupJson('g2', 'Spray booth', [
          leafJson('n2', 'Booth filters changed', 'Not Applicable'),
          leafJson('n3', 'Solvent store locked', 'Not Applicable'),
        ]),
        leafJson('c4', 'Paint is labelled', 'OFI', score: 6, remark: 'Some missing'),
      ],
    },
    scoreResult: mixedScore,
  );

  group('the report PDF lists Not Applicable checkpoints in grey but does not calculate them', () {
    late String text;
    setUpAll(() async {
      text = textOf(await buildReportPdf(mixed()));
    });

    test('each one is a grey "N/A" row in the index and a "NOT APPLICABLE" card in the findings, with no score and no remark body', () {
      for (final name in ['Overhead crane checked', 'Booth filters changed', 'Solvent store locked']) {
        expect(text, contains(name), reason: name);
      }
      expect(text, matches(RegExp(r'1\.3\s+Overhead\s+crane\s+checked\s+N/A\s+2\s+Fire')), reason: 'index row: status N/A, no score cell');
      expect(occurrences(text, 'NOT APPLICABLE'), 3, reason: 'one findings card each');
      // The three cards have no AUDITOR REMARK / EVIDENCE block: only the four assessed ones do.
      expect(occurrences(text, 'AUDITOR REMARK'), 4);
      expect(occurrences(text, 'AUDITOR EVIDENCE'), 4);
    });

    test('the tiles count only what was assessed: Total Checks 4, the tallies, no N/A tile — and a line says how many are left out', () {
      expect(RegExp(r'(\d+)\s+TOTAL\s+CHECKS').firstMatch(text)!.group(1), '4');
      expect(text, matches(RegExp(r'80%\s+SCORE\s+1\s+STRONG\s+1\s+COMPLIANT\s+2\s+OFI\s+0\s+RAISE\s+NC\s+4\s+TOTAL\s+CHECKS')));
      expect(text, matches(RegExp(r'3\s+checkpoints\s+not\s+applicable\s+(?:—\s+)?left\s+out\s+of\s+the\s+score')));
    });

    test('each place\'s subtotal and the FINAL SCORE leave them out', () {
      expect(text, matches(RegExp('Assembly\\s+Line\\s+1\\s+\\(AL1\\)\\s+SUBTOTAL\\s+${dash}26/30\\s+${dash}87%')));
      expect(text, matches(RegExp('Paint\\s+Shop\\s+\\(PS\\)\\s+SUBTOTAL\\s+${dash}6/10\\s+${dash}60%')));
      expect(text, matches(RegExp('FINAL\\s+SCORE\\s+${dash}32/40\\s+${dash}80%')));
    });

    test('a group of only Not Applicable checkpoints shows no score in the index (—), and "Not calculated" in the findings', () {
      expect(text, matches(RegExp(r'1\s+Spray\s+booth\s+1\.1\s+Booth\s+filters\s+changed')), reason: 'no total, no percent between the group and its first row');
      expect(text, contains('Not calculated'));
      expect(occurrences(text, 'AVG SCORE'), 2, reason: 'Housekeeping has an average; Spray booth has none to give');
      expect(text, matches(RegExp(r'Spray\s+booth\s+2\s+N/A\s+AVG\s+SCORE\s+Not\s+calculated')));
    });

    test('the charts leave them out: Spray booth has no bar, Housekeeping is the average of its two assessed checkpoints', () {
      expect(text, matches(RegExp(r'PARAMETER\s+SCORE\s+80%\s+Housekeeping\s+100%\s+Fire\s+exit\s+is\s+clear\s+60%\s+Paint\s+is\s+labelled')));
    });
  });

  group('an audit that is still open', () {
    test('a blank checkpoint stays "Not scored yet", a Not Applicable one is grey N/A and not counted', () async {
      final open = audit(
        status: 'In Progress',
        trees: {
          'L1': [
            leafJson('c1', 'Floor is clean', 'Compliance', score: 10, remark: 'In order'),
            leafJson('n1', 'Overhead crane checked', 'Not Applicable'),
            leafJson('b1', 'Guards are fitted', null),
          ],
        },
        scoreResult: {'achieved': 10, 'maxPossible': 10, 'percentage': 100, 'scoredCount': 2, 'leafCount': 3, 'notApplicableCount': 1, 'isFullyScored': false},
      );
      final text = textOf(await buildReportPdf(open));
      expect(occurrences(text, 'Not scored yet'), 1);
      expect(text, matches(RegExp(r'Guards\s+are\s+fitted\s+Not\s+scored\s+yet')));
      expect(text, contains('Overhead crane checked'));
      expect(text, contains('NOT APPLICABLE'));
      expect(text, contains('Audit in progress'));
    });
  });

  group('every checkpoint Not Applicable', () {
    test('the PDF is still a valid, readable report: no percentage anywhere (never a 0%), and no crash', () async {
      final all = audit(
        trees: {
          'L1': [leafJson('n1', 'Overhead crane checked', 'Not Applicable'), leafJson('n2', 'Solvent store locked', 'Not Applicable')],
        },
        scoreResult: {'achieved': 0, 'maxPossible': 0, 'percentage': null, 'scoredCount': 2, 'leafCount': 2, 'notApplicableCount': 2, 'isFullyScored': true},
      );
      final bytes = await buildReportPdf(all);
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final text = textOf(bytes);
      expect(text, contains('5S Review - Plant 1'));
      expect(text, contains('Overhead crane checked'));
      expect(text, isNot(contains('PARAMETER SCORE')));
      expect(text, isNot(contains('LOCATION-WISE SCORE')));
      expect(text, isNot(matches(RegExp(r'\d+%'))), reason: 'no percentage anywhere, and never a 0%');
    });
  });

  group('weightage scoring', () {
    test('a Not Applicable checkpoint adds nothing to either side and shows no weightage or score', () async {
      final w = audit(
        scoringSystem: 'weightage',
        trees: {
          'L1': [
            leafJson('a', 'Guards are fitted', 'Strong Compliance', score: 10, remark: 'ok', weightage: 20),
            leafJson('c', 'Overhead crane checked', 'Not Applicable', weightage: 60),
            leafJson('b', 'Bins are emptied', 'NC', score: 0, remark: 'overflowing', weightage: 20),
          ],
        },
        scoreResult: {'achieved': 20, 'maxPossible': 40, 'percentage': 50, 'scoredCount': 3, 'leafCount': 3, 'notApplicableCount': 1, 'isFullyScored': true},
      );
      final text = textOf(await buildReportPdf(w));
      expect(text, matches(RegExp('FINAL\\s+SCORE\\s+${dash}20/40\\s+${dash}50%')));
      expect(RegExp(r'(\d+)\s+TOTAL\s+CHECKS').firstMatch(text)!.group(1), '2');
      // Its index row carries neither its own weightage (60) nor a score.
      expect(text, matches(RegExp(r'2\s+Overhead\s+crane\s+checked\s+N/A\s+3\s+Bins')));
    });
  });
}
