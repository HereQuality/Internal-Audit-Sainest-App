import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/report_sheet_spec.dart';

/// The sheets of the phone's three Final Report Excel downloads — a port of the web app's
/// client/src/utils/finalReportExcel.test.js, case for case, so a file made on the phone
/// says what the web's says. Rows in, sheet descriptions out: no file, no network.
void main() {
  Map<String, dynamic> emp(String name) => {'_id': name, 'employeeName': name};

  Map<String, dynamic> audit({
    String id = 'a1',
    Map<String, dynamic> over = const {},
  }) => {
    '_id': id,
    'title': 'Safety walk',
    'auditNumber': 'AUD-1',
    'auditType': 'Safety',
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
    'scoreResult': {'achieved': 40, 'maxPossible': 50, 'percentage': 80},
    'ncSummary': {'total': 3, 'closed': 1},
    ...over,
  };

  ReportDataSheet dataSheet(ReportWorkbookSpec spec, String name) => spec.sheet(name)! as ReportDataSheet;
  List<String> headers(ReportDataSheet s) => [for (final c in s.columns) c.header];
  final generatedAt = DateTime(2026, 10, 5, 9, 0);

  group('helpers', () {
    test('names an audit\'s places with their codes, locations then departments', () {
      expect(auditPlaceLabel(audit()), 'Plant 1 (P1)');
      expect(
        auditPlaceLabel(audit(over: {
          'locationIds': [
            {'name': 'A'},
            {'name': 'B'},
          ],
          'departmentIds': [
            {'departmentName': 'QA', 'departmentCode': 'Q'},
          ],
        })),
        'A, B, QA (Q)',
      );
      expect(
        auditPlaceLabel(audit(over: {
          'locationIds': [
            {'_id': 'x'},
          ],
        })),
        'Deleted location',
      );
      expect(auditPlaceLabel({}), '');
    });

    test('reads auditeeIds first, then the single auditeeId', () {
      expect(auditeesOf(audit(over: {'auditeeIds': [emp('A'), emp('B')]})), 'A, B');
      expect(auditeesOf(audit(over: {'auditeeIds': <Object>[], 'auditeeId': emp('Solo')})), 'Solo');
      expect(auditeesOf({}), '');
    });

    test('counts whole calendar days, null when a date is missing', () {
      expect(daysBetween('2026-09-01T00:00:00', '2026-09-05T00:00:00'), 4);
      expect(daysBetween('2026-09-05T00:00:00', '2026-09-01T00:00:00'), -4);
      expect(daysBetween(null, '2026-09-01'), isNull);
      expect(daysBetween('2026-09-01', 'garbage'), isNull);
    });

    test('colours scores at the app\'s 75 / 50 thresholds — the web\'s exact colours', () {
      expect(scoreTone(80)!.fg, '#15803d');
      expect(scoreTone(75)!.fg, '#15803d');
      expect(scoreTone(74.9)!.fg, '#b45309');
      expect(scoreTone(60)!.fg, '#b45309');
      expect(scoreTone(50)!.fg, '#b45309');
      expect(scoreTone(49)!.fg, '#b91c1c');
      expect(scoreTone(10)!.fg, '#b91c1c');
      // No score is no colour — never red, never 0%.
      expect(scoreTone(null), isNull);
      expect(scoreTone(''), isNull);
    });

    test('the other tones are the web\'s: timeliness, flag, status, NC stage', () {
      expect(timelinessTone('On-Time')!.fg, '#15803d');
      expect(timelinessTone('Delayed')!.fg, '#b91c1c');
      expect(timelinessTone(''), isNull);
      expect(flagTone('Major')!.fg, '#dc2626');
      expect(flagTone('Minor')!.fg, '#d97706');
      expect(auditStatusTone('Overdue')!.fg, '#e11d48');
      expect(auditStatusTone('Total Closed')!.fg, '#0d9488');
      expect(auditStatusTone('Not Attempted'), isNull);
      expect(stageTone('Pending Approval')!.fg, '#db2777');
      expect(stageTone('On Time Completion')!.fg, '#22c55e');
      expect(ncStatusTone('Awaiting response')!.fg, '#dc2626');
      expect(ncStatusTone('Closed')!.fg, '#16a34a');
    });
  });

  group('file name', () {
    test('Final-Report-<Audits|NCs|Repeated-NCs>-<yyyy-MM-dd>.xlsx, the day it was made', () {
      final day = DateTime(2026, 11, 3, 23, 59);
      expect(finalReportFileName(FinalReportTab.audits, day), 'Final-Report-Audits-2026-11-03.xlsx');
      expect(finalReportFileName(FinalReportTab.ncs, day), 'Final-Report-NCs-2026-11-03.xlsx');
      expect(finalReportFileName(FinalReportTab.repeats, day), 'Final-Report-Repeated-NCs-2026-11-03.xlsx');
      expect(finalReportFileName(FinalReportTab.ncs, DateTime(2027, 1, 9)), 'Final-Report-NCs-2027-01-09.xlsx');
    });

    test('each workbook carries its own file name (without the extension)', () {
      expect(buildAuditsReport(rows: const [], generatedAt: generatedAt).filename, 'Final-Report-Audits-2026-10-05');
      expect(buildNcsReport(rows: const [], generatedAt: generatedAt).filename, 'Final-Report-NCs-2026-10-05');
      expect(
        buildRepeatsReport(groups: const [], ncsById: const {}, generatedAt: generatedAt).filename,
        'Final-Report-Repeated-NCs-2026-10-05',
      );
    });
  });

  group('auditExportRows', () {
    test('makes one row per plain audit, carrying place, people, dates, status and score', () {
      final export = auditExportRows([audit()]);
      expect(export.rows, hasLength(1));
      expect(export.bundles, isEmpty);
      final r = export.rows.single;
      expect(r['place'], 'Plant 1 (P1)');
      expect(r['auditors'], 'Asha');
      expect(r['auditees'], 'Ravi');
      expect(r['auditNo'], 'AUD-1');
      expect(r['type'], 'Safety');
      expect(r['status'], 'Total Closed');
      expect(r['timeliness'], 'On-Time');
      expect(r['score'], 80);
      expect(r['achieved'], 40);
      expect(r['possible'], 50);
      expect(r['ncTotal'], 3);
      expect(r['ncOpen'], 2);
      expect(r['finished'], true);
      expect(r['start'], DateTime(2026, 9, 1));
      expect(r['due'], DateTime(2026, 9, 5));
      expect(r['completed'], DateTime(2026, 9, 4));
    });

    test('gives an unfinished audit no score', () {
      final r = auditExportRows([
        audit(over: {'status': 'In Progress', 'displayStatus': 'In Progress', 'timeliness': null}),
      ]).rows.single;
      expect(r['score'], isNull);
      expect(r['achieved'], isNull);
      expect(r['finished'], false);
      expect(r['timeliness'], '');
    });

    test('an audit with nothing assessed (all Not Applicable) has no percentage: blank, never 0%', () {
      final r = auditExportRows([
        audit(over: {
          'scoreResult': {'achieved': 0, 'maxPossible': 0, 'percentage': null},
        }),
      ]).rows.single;
      expect(r['finished'], true);
      expect(r['score'], isNull);
      // ...and it adds nothing to a place's marks, so the place has no score either.
      final tally = tallyAuditRows([r], (row) => [row['place'] as String]).single;
      expect(tally['score'], isNull);
    });

    test('lists a bundle as a row per zone under its own location, plus one bundle summary', () {
      final m1 = audit(id: 'm1', over: {
        'scheduleBatchId': 'b1',
        'locationIds': [
          {'name': 'Zone A'},
        ],
        'batchDisplayStatus': 'In Progress',
      });
      final m2 = audit(id: 'm2', over: {
        'scheduleBatchId': 'b1',
        'locationIds': [
          {'name': 'Zone B'},
        ],
        'status': 'In Progress',
        'displayStatus': 'In Progress',
        'completedDate': null,
        'batchDisplayStatus': 'In Progress',
      });
      final export = auditExportRows([m1, m2], bundleScore: (_) => 80);
      expect(export.rows.map((r) => r['place']), ['Zone A', 'Zone B']);
      expect(export.rows.every((r) => r['bundle'] == 'Safety walk'), isTrue);
      expect(export.bundles, hasLength(1));
      expect(export.bundles.single['zones'], 2);
      expect(export.bundles.single['score'], 80);
      expect(export.bundles.single['status'], 'In Progress');
    });

    test('a bundle\'s combined score is Σ achieved / Σ possible over its COMPLETED zones, null when none finished', () {
      final done = audit(id: 'm1', over: {'scheduleBatchId': 'b', 'scoreResult': {'achieved': 9, 'maxPossible': 10}});
      final bigger = audit(id: 'm2', over: {'scheduleBatchId': 'b', 'scoreResult': {'achieved': 10, 'maxPossible': 100}});
      final open = audit(id: 'm3', over: {
        'scheduleBatchId': 'b',
        'status': 'In Progress',
        'scoreResult': {'achieved': 0, 'maxPossible': 90},
      });
      expect(auditExportRows([done, bigger, open]).bundles.single['score'], 17); // 19/110, not 50
      expect(
        auditExportRows([
          audit(id: 'x', over: {'scheduleBatchId': 'c', 'status': 'In Progress'}),
          audit(id: 'y', over: {'scheduleBatchId': 'c', 'status': 'In Progress'}),
        ]).bundles.single['score'],
        isNull,
      );
    });

    test('a bundle with a single member is just an audit', () {
      final export = auditExportRows([audit(over: {'scheduleBatchId': 'solo'})]);
      expect(export.rows, hasLength(1));
      expect(export.bundles, isEmpty);
    });

    Map<String, dynamic> leaf(String id, String? finding, {num? score}) => {
      '_id': id,
      'name': id,
      'findingType': finding,
      'score': score,
      'children': <Object>[],
    };

    test('a zone with Not Applicable checkpoints is scored on what was assessed; a zone of only N/A has no score, not 0%', () {
      // The same case as the web test — the zone scores come from the same sum-then-divide helper the report screen uses.
      final a = audit(over: {
        'structureMode': 'per-location',
        'scoringSystem': 'normal',
        'maxScore': 10,
        'locationIds': [
          {'_id': 'z1', 'name': 'Zone 1'},
          {'_id': 'z2', 'name': 'Zone 2'},
        ],
        'locationParameters': [
          {
            'locationId': 'z1',
            'parameters': [
              {
                '_id': 'g1',
                'name': 'G',
                'children': [leaf('a', 'Compliance', score: 8), leaf('b', 'Not Applicable'), leaf('c', 'Compliance', score: 6)],
              },
            ],
          },
          {
            'locationId': 'z2',
            'parameters': [
              {
                '_id': 'g2',
                'name': 'H',
                'children': [leaf('d', 'Not Applicable'), leaf('e', 'Not Applicable')],
              },
            ],
          },
        ],
      });
      final rows = auditExportRows([a]).rows;
      expect(
        rows.map((r) => [r['place'], r['score'], r['achieved'], r['possible']]).toList(),
        [
          ['Zone 1', 70, 14, 20],
          ['Zone 2', null, 0, 0],
        ],
      );
    });

    test('a zone is only scored once the audit is Completed', () {
      final a = audit(over: {
        'status': 'In Progress',
        'structureMode': 'per-location',
        'locationParameters': [
          {'locationId': 'z1', 'parameters': [leaf('a', 'Compliance', score: 8)]},
          {'locationId': 'z2', 'parameters': [leaf('b', 'Compliance', score: 8)]},
        ],
        'locationIds': [
          {'_id': 'z1', 'name': 'Zone 1'},
          {'_id': 'z2', 'name': 'Zone 2'},
        ],
      });
      final rows = auditExportRows([a]).rows;
      expect(rows.map((r) => r['place']), ['Zone 1', 'Zone 2']);
      expect(rows.map((r) => r['score']), [null, null]);
      expect(rows.map((r) => r['achieved']), [null, null]);
    });

    test('lists a per-location audit as a row per zone with the zone\'s own score', () {
      final a = audit(over: {'structureMode': 'per-location'});
      final export = auditExportRows([a], sectionsOf: (_) => const [
        ZoneSection(label: 'Zone 1', pct: 90, achieved: 18, max: 20),
        ZoneSection(label: 'Zone 2', pct: 70, achieved: 14, max: 20),
      ]);
      expect(
        export.rows.map((r) => [r['place'], r['score'], r['achieved'], r['possible']]).toList(),
        [
          ['Zone 1', 90, 18, 20],
          ['Zone 2', 70, 14, 20],
        ],
      );
    });

    test('a per-location audit with one zone is a plain row', () {
      final a = audit(over: {'structureMode': 'per-location'});
      final export = auditExportRows([a], sectionsOf: (_) => const [ZoneSection(label: 'Only', pct: 90, achieved: 18, max: 20)]);
      expect(export.rows.single['place'], 'Plant 1 (P1)');
    });
  });

  group('tallyAuditRows', () {
    final rows = <Map<String, Object?>>[
      {'place': 'A', 'auditors': 'Asha, Bo', 'status': 'Total Closed', 'finished': true, 'timeliness': 'On-Time', 'achieved': 40, 'possible': 50},
      {'place': 'A', 'auditors': 'Asha', 'status': 'Total Closed', 'finished': true, 'timeliness': 'Delayed', 'achieved': 10, 'possible': 50},
      {'place': 'B', 'auditors': 'Bo', 'status': 'Overdue', 'finished': false, 'timeliness': '', 'achieved': null, 'possible': null},
    ];

    test('scores a place as marks achieved over marks possible, never an average of percentages', () {
      final tallies = tallyAuditRows(rows, (r) => [r['place'] as String]);
      final a = tallies[0];
      final b = tallies[1];
      expect(a['name'], 'A');
      expect(a['audits'], 2);
      expect(a['achieved'], 50);
      expect(a['possible'], 100);
      expect(a['score'], 50);
      expect(a['onTime'], 1);
      expect(a['delayed'], 1);
      expect(b['overdue'], 1);
      expect(b['score'], isNull);
    });

    test('weights by marks, not by audit count', () {
      final g = tallyAuditRows([
        {'place': 'P', 'status': 'Total Closed', 'finished': true, 'timeliness': 'On-Time', 'achieved': 9, 'possible': 10},
        {'place': 'P', 'status': 'Total Closed', 'finished': true, 'timeliness': 'On-Time', 'achieved': 10, 'possible': 100},
      ], (r) => [r['place'] as String]).single;
      expect(g['score'], (19 / 110 * 100).round()); // 17, not the 50 an average of 90% and 10% would give
    });

    test('counts a shared audit once for each of its auditors, and orders by audits then name', () {
      final people = tallyAuditRows(rows, (r) => (r['auditors'] as String).split(',').map((s) => s.trim()).toList());
      expect(people.map((p) => [p['name'], p['audits']]).toList(), [
        ['Asha', 2],
        ['Bo', 2],
      ]);
    });

    test('counts every status the web counts, including Skipped and Not Attempted', () {
      final g = tallyAuditRows([
        {'place': 'P', 'status': 'In Progress', 'finished': false},
        {'place': 'P', 'status': 'Not Started', 'finished': false},
        {'place': 'P', 'status': 'Skipped', 'finished': false},
        {'place': 'P', 'status': 'Not Attempted', 'finished': false},
      ], (r) => ['P']).single;
      expect([g['inProgress'], g['notStarted'], g['skipped'], g['notAttempted'], g['overdue']], [1, 1, 1, 1, 0]);
    });
  });

  group('buildAuditsReport', () {
    final export = auditExportRows([
      audit(),
      audit(id: 'a2', over: {
        'locationIds': [
          {'name': 'Plant 2'},
        ],
        'auditorIds': [emp('Bo')],
        'status': 'In Progress',
        'displayStatus': 'In Progress',
        'timeliness': null,
      }),
    ]);
    final stats = {
      'percentage': 80,
      'isPartial': false,
      'totalAudits': 2,
      'inProgress': 1,
      'overdue': 0,
      'onTimeCompleted': 1,
      'delayedCompleted': 0,
      'skipped': 0,
      'notAttempted': 2,
    };
    final spec = buildAuditsReport(
      rows: export.rows,
      bundles: export.bundles,
      stats: stats,
      filters: const [('Location', 'All locations')],
      generatedBy: 'Asha',
      generatedAt: generatedAt,
    );

    test('has a Summary, the Audits rows and By Location / By Auditor / By Auditee', () {
      expect(spec.sheets.map((s) => s.name), ['Summary', 'Audits', 'By Location', 'By Auditor', 'By Auditee']);
      final audits = dataSheet(spec, 'Audits');
      expect(audits.rows, hasLength(2));
      expect(audits.rows.map((r) => r['no']), [1, 2]);
    });

    test('the Audits sheet has the web\'s columns in the web\'s order', () {
      expect(headers(dataSheet(spec, 'Audits')), [
        '#', 'Audit No.', 'Audit', 'Audit Type', 'Location / Zone', 'Auditor(s)', 'Auditee(s)', 'Bundle', 'Repeats',
        'Start', 'Due', 'Completed', 'Status', 'Timeliness', 'Score %', 'Marks Achieved', 'Marks Possible', 'NCs Raised', 'NCs Open',
      ]);
      expect(headers(dataSheet(spec, 'By Location')), [
        'Location / Zone', 'Audits', 'In Progress', 'Overdue', 'Not Started', 'On-Time Completed', 'Delayed Completed',
        'Skipped', 'Not Attempted', 'Marks Achieved', 'Marks Possible', 'Score %',
      ]);
      expect(dataSheet(spec, 'By Auditor').columns.first.header, 'Auditor');
      expect(dataSheet(spec, 'By Auditee').columns.first.header, 'Auditee');
      expect(dataSheet(spec, 'Audits').freezeColumns, 3);
    });

    test('shows the tab\'s own tiles, only the optional tiles that have a count', () {
      final summary = spec.sheet('Summary')! as ReportSummarySheet;
      final tiles = summary.tileGroups.first.tiles;
      final labels = tiles.map((t) => t.label).toList();
      expect(labels, ['Total Score', 'Total Audits', 'In Progress', 'Overdue', 'On-Time Completed', 'Delayed Completed', 'Not Attempted']);
      expect(tiles.first.value, 80);
      expect(tiles.first.format, ReportFormat.percent);
      expect(tiles.first.note, 'Marks achieved / marks possible');
      expect(summary.tileGroups[1].title, 'In this file');
      expect(summary.tileGroups[1].tiles.first.value, 2);
    });

    test('says so when the tiles could not be loaded, and still lists every row', () {
      final noStats = buildAuditsReport(rows: export.rows, generatedAt: generatedAt);
      final summary = noStats.sheet('Summary')! as ReportSummarySheet;
      expect(summary.tileGroups.map((g) => g.title), ['In this file']);
      expect(summary.notes, contains(statsMissingNote));
      expect(dataSheet(noStats, 'Audits').rows, hasLength(2));
    });

    test('explains a blank score in the notes', () {
      final summary = spec.sheet('Summary')! as ReportSummarySheet;
      expect(summary.notes.join(' '), contains('blank Score %'));
    });

    test('adds a Bundles sheet only when there are bundles', () {
      final m1 = audit(id: 'm1', over: {'scheduleBatchId': 'b'});
      final m2 = audit(id: 'm2', over: {'scheduleBatchId': 'b'});
      final b = auditExportRows([m1, m2]);
      final withBundles = buildAuditsReport(rows: b.rows, bundles: b.bundles, generatedAt: generatedAt);
      expect(withBundles.sheets.map((s) => s.name), ['Summary', 'Audits', 'Bundles', 'By Location', 'By Auditor', 'By Auditee']);
      expect(dataSheet(withBundles, 'Bundles').rows.single['zones'], 2);
    });

    test('the By Location sheet ends in a total row', () {
      final totals = dataSheet(spec, 'By Location').totals!;
      expect(totals.values['audits'], 2);
      expect(totals.values['achieved'], 40);
      expect(totals.values['score'], 80);
    });

    test('an empty result still builds every sheet, with no rows', () {
      final empty = buildAuditsReport(rows: const [], stats: {'totalAudits': 0}, generatedAt: generatedAt);
      expect(empty.sheets.map((s) => s.name), ['Summary', 'Audits', 'By Location', 'By Auditor', 'By Auditee']);
      expect(dataSheet(empty, 'Audits').rows, isEmpty);
      expect(dataSheet(empty, 'By Location').rows, isEmpty);
      expect(dataSheet(empty, 'By Location').totals!.values['audits'], 0);
      expect(dataSheet(empty, 'By Location').totals!.values['score'], isNull);
    });

    test('keeps the filters it was given, for the Summary\'s "Filters applied" block', () {
      expect(spec.filters, [('Location', 'All locations')]);
      expect(spec.generatedBy, 'Asha');
      expect(spec.generatedAt, generatedAt);
    });
  });

  group('ncExportRows', () {
    final now = DateTime(2026, 10, 5, 10, 0);
    Map<String, dynamic> nc({Map<String, dynamic> over = const {}}) => {
      '_id': 'n1',
      'ncId': 'NC-3',
      'title': 'Guard missing',
      'description': 'd',
      'severity': 'Major',
      'status': 'Raised',
      'bucket': 'overdue',
      'placeLabel': 'Plant 1',
      'auditId': {'_id': 'a1', 'title': 'Safety walk', 'auditType': 'Safety'},
      'raisedByEmployeeId': emp('Asha'),
      'auditeeEmployeeId': emp('Ravi'),
      'startDate': '2026-09-20T00:00:00',
      'targetDate': '2026-09-30T00:00:00',
      'completionDate': null,
      'repeatCount': 2,
      'reopenCount': 1,
      'rootCause': 'rc',
      ...over,
    };

    test('names the location, who raised it and who it is against', () {
      final r = ncExportRows([nc()], now: now).single;
      expect(r['place'], 'Plant 1');
      expect(r['raisedBy'], 'Asha');
      expect(r['against'], 'Ravi');
      expect(r['stage'], 'Overdue');
      expect(r['status'], 'Awaiting response');
      expect(r['flag'], 'Major');
      expect(r['repeats'], 2);
      expect(r['reopened'], 1);
      expect(r['rootCause'], 'rc');
      expect(r['audit'], 'Safety walk');
      expect(r['auditType'], 'Safety');
    });

    test('counts days open and days late for an NC that is still open', () {
      final r = ncExportRows([nc()], now: now).single;
      expect(r['daysTaken'], 15); // 20 Sep -> 5 Oct
      expect(r['daysLate'], 5); // due 30 Sep
      expect(r['completed'], isNull);
    });

    test('measures a closed NC up to its completion, and leaves "days late" blank when it was on time', () {
      final late = ncExportRows([nc(over: {'status': 'Closed', 'bucket': 'delayed', 'completionDate': '2026-10-02T00:00:00'})], now: now).single;
      expect(late['daysTaken'], 12);
      expect(late['daysLate'], 2);
      expect(late['completed'], isNotNull);
      final onTime = ncExportRows([nc(over: {'status': 'Closed', 'bucket': 'onTime', 'completionDate': '2026-09-28T00:00:00'})], now: now).single;
      expect(onTime['daysLate'], isNull);
    });

    test('reads a retired or missing flag as Minor, and a deleted audit as such', () {
      final rows = ncExportRows([nc(over: {'severity': 'Observation'}), nc(over: {'severity': null, 'auditId': null})], now: now);
      expect(rows[0]['flag'], 'Minor');
      expect(rows[1]['flag'], 'Minor');
      expect(rows[1]['audit'], 'Audit deleted');
    });

    test('falls back from the place label to the location, then the department name', () {
      expect(ncExportRows([nc(over: {'placeLabel': null, 'locationName': 'Shed'})], now: now).single['place'], 'Shed');
      expect(ncExportRows([nc(over: {'placeLabel': '', 'departmentName': 'QA'})], now: now).single['place'], 'QA');
    });

    test('carries the ATS score the server computed', () {
      expect(ncExportRows([nc(over: {'atsScore': 82.5})], now: now).single['ats'], 82.5);
      expect(ncExportRows([nc()], now: now).single['ats'], isNull);
    });
  });

  group('tallyNcRows / buildNcsReport', () {
    final rows = ncExportRows([
      {'_id': '1', 'ncId': 'NC-1', 'title': 't', 'severity': 'Major', 'status': 'Raised', 'bucket': 'overdue', 'placeLabel': 'P1', 'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Ravi'), 'repeatCount': 1},
      {'_id': '2', 'ncId': 'NC-2', 'title': 't', 'severity': 'Minor', 'status': 'Closed', 'bucket': 'onTime', 'placeLabel': 'P1', 'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Mia'), 'repeatCount': 0, 'completionDate': '2026-09-01'},
      {'_id': '3', 'ncId': 'NC-3', 'title': 't', 'severity': 'Major', 'status': 'Raised', 'bucket': 'inProgress', 'placeLabel': 'P2', 'raisedByEmployeeId': emp('Bo'), 'auditeeEmployeeId': emp('Ravi'), 'repeatCount': 0},
    ]);

    test('tallies stages, flags and repeats per key', () {
      final tallies = tallyNcRows(rows, (r) => [r['place'] as String]);
      final p1 = tallies[0];
      final p2 = tallies[1];
      expect([p1['name'], p1['total'], p1['overdue'], p1['onTime'], p1['major'], p1['minor'], p1['repeats']], ['P1', 2, 1, 1, 1, 1, 1]);
      expect([p2['name'], p2['total'], p2['inProgress']], ['P2', 1, 1]);
    });

    test('answers "against this person" and "from this person"', () {
      expect(tallyNcRows(rows, (r) => [r['against'] as String]).map((g) => [g['name'], g['total']]).toList(), [
        ['Ravi', 2],
        ['Mia', 1],
      ]);
      expect(tallyNcRows(rows, (r) => [r['raisedBy'] as String]).map((g) => [g['name'], g['total']]).toList(), [
        ['Asha', 2],
        ['Bo', 1],
      ]);
    });

    test('builds the workbook with the NC tiles from the stats (not from the listed rows) and a total row per tally', () {
      final spec = buildNcsReport(
        rows: rows,
        stats: {'total': 10, 'inProgress': 3, 'overdue': 2, 'pendingApproval': 1, 'delayed': 1, 'onTime': 3, 'atsScore': 71.4, 'otcScore': 66.7},
        generatedAt: generatedAt,
      );
      expect(spec.sheets.map((s) => s.name), ['Summary', 'NCs', 'By Location', 'By Auditor', 'By Auditee']);
      final summary = spec.sheet('Summary')! as ReportSummarySheet;
      expect(summary.tileGroups.first.tiles.map((t) => [t.label, t.value]).toList(), [
        ['Total NC', 10],
        ['In Progress', 3],
        ['Overdue', 2],
        ['Pending Approval', 1],
        ['Delayed', 1],
        ['On Time Completion', 3],
      ]);
      expect(summary.tileGroups[1].tiles.first.value, 71.4);
      expect(summary.tileGroups[1].tiles.first.decimals, 1);
      expect(dataSheet(spec, 'By Location').totals!.values['total'], 3);
      expect(headers(dataSheet(spec, 'NCs')), [
        '#', 'NC ID', 'NC / Checkpoint', 'Flag', 'Location / Zone', 'Raised By (Auditor)', 'Against (Auditee)', 'Audit', 'Audit Type',
        'Raised On', 'Target Date', 'Completed On', 'Stage', 'Status', 'Days Taken / Open', 'Days Late', 'ATS %', 'Times Before', 'Reopened',
        'Description', 'Correction', 'Root Cause', 'Corrective Action', 'Preventive Action', "Auditor's Note",
      ]);
      expect(headers(dataSheet(spec, 'By Auditor')), [
        'Raised By (Auditor)', 'Total NC', 'In Progress', 'Overdue', 'Pending Approval', 'Delayed', 'On Time Completion', 'Major', 'Minor', 'Repeat NCs',
      ]);
    });

    test('the In-this-file tiles count the rows, major and minor', () {
      final spec = buildNcsReport(rows: rows, stats: {'total': 3}, generatedAt: generatedAt);
      final tiles = (spec.sheet('Summary')! as ReportSummarySheet).tileGroups.last.tiles;
      expect(tiles.map((t) => [t.label, t.value]).toList(), [
        ['NCs listed', 3],
        ['Major', 2],
        ['Minor', 1],
        ['Locations', 2],
        ['Raised by (auditors)', 2],
        ['Against (auditees)', 2],
      ]);
    });

    test('says so when the tiles could not be loaded', () {
      final spec = buildNcsReport(rows: rows, generatedAt: generatedAt);
      final summary = spec.sheet('Summary')! as ReportSummarySheet;
      expect(summary.tileGroups.map((g) => g.title), ['In this file']);
      expect(summary.notes, contains(statsMissingNote));
    });

    test('an empty result still builds every sheet, with no rows and zero totals', () {
      final spec = buildNcsReport(rows: const [], stats: {'total': 0}, generatedAt: generatedAt);
      expect(dataSheet(spec, 'NCs').rows, isEmpty);
      expect(dataSheet(spec, 'By Auditee').totals!.values['total'], 0);
      final tiles = (spec.sheet('Summary')! as ReportSummarySheet).tileGroups.last.tiles;
      expect(tiles.first.value, 0);
    });

    test('colours the stage columns of the tally with the NC tile colours', () {
      final spec = buildNcsReport(rows: rows, stats: {}, generatedAt: generatedAt);
      final overdue = dataSheet(spec, 'By Location').columns.firstWhere((c) => c.header == 'Overdue');
      expect(overdue.tone!(1, const {})!.fg, '#ef4444');
      expect(overdue.tone!(0, const {}), isNull);
    });
  });

  group('repeats', () {
    final groups = <Map<String, dynamic>>[
      {'key': 'k1', 'title': 'Guard missing', 'locationName': 'Plant 1', 'departmentName': null, 'count': 3, 'openCount': 2, 'firstDate': '2026-07-01', 'lastDate': '2026-09-01', 'latestStatus': 'Raised', 'ncIds': ['c', 'b', 'a']},
      {'key': 'k2', 'title': 'Floor wet', 'locationName': 'Plant 2', 'departmentName': 'QA', 'count': 2, 'openCount': 0, 'firstDate': '2026-08-01', 'lastDate': '2026-08-20', 'latestStatus': 'Closed', 'ncIds': ['e', 'd']},
    ];
    MapEntry<String, Map> n(String id, String date, String raised, String against, [Map<String, dynamic> over = const {}]) => MapEntry(id, {
      '_id': id,
      'ncId': 'NC-$id',
      'startDate': date,
      'severity': 'Minor',
      'status': 'Raised',
      'auditId': {'_id': 'au-$id', 'title': 'Audit $id'},
      'raisedByEmployeeId': emp(raised),
      'auditeeEmployeeId': emp(against),
      ...over,
    });
    final ncsById = <String, Map>{
      for (final e in [
        n('a', '2026-07-01', 'Asha', 'Ravi'),
        n('b', '2026-08-01', 'Asha', 'Mia'),
        n('c', '2026-09-01', 'Bo', 'Ravi', {'severity': 'Major'}),
        n('d', '2026-08-01', 'Bo', 'Ravi', {'status': 'Closed', 'completionDate': '2026-08-10'}),
        n('e', '2026-08-20', 'Bo', 'Ravi', {'status': 'Closed', 'completionDate': '2026-08-25'}),
      ])
        e.key: e.value,
    };

    test('summarises each repeated checkpoint with its place, counts and who raised / who it was against', () {
      final g = repeatExportRows(groups, ncsById).groupRows;
      expect(g[0]['place'], 'Plant 1');
      expect(g[1]['place'], 'Plant 2 · QA');
      expect([g[0]['count'], g[0]['open'], g[0]['closed']], [3, 2, 1]);
      expect(g[0]['raisedBy'], 'Asha, Bo');
      expect(g[0]['against'], 'Ravi, Mia');
      expect(g[0]['audits'], 3);
      expect(g[1]['latest'], 'Closed');
    });

    test('lists every NC oldest first with which time it was', () {
      final details = repeatExportRows(groups, ncsById).detailRows;
      final first = details.where((d) => d['groupKey'] == 'k1').toList();
      expect(first.map((d) => [d['ncId'], d['occurrence'], d['count']]).toList(), [
        ['NC-a', 1, 3],
        ['NC-b', 2, 3],
        ['NC-c', 3, 3],
      ]);
      expect(first[2]['flag'], 'Major');
      expect(details.firstWhere((d) => d['ncId'] == 'NC-d')['completed'], DateTime(2026, 8, 10));
      expect(details.firstWhere((d) => d['ncId'] == 'NC-a')['completed'], isNull);
    });

    test('numbers the listed NCs from the end when the list holds only the newest ones', () {
      final built = repeatExportRows([
        {...groups[0], 'count': 10, 'ncIds': ['c', 'b']},
      ], ncsById);
      expect(built.detailRows.map((d) => d['occurrence']), [9, 10]);
      expect(built.groupRows.single['listed'], 2);
    });

    test('skips an NC id the server did not return', () {
      final details = repeatExportRows([
        {...groups[0], 'ncIds': ['c', 'zzz']},
      ], ncsById).detailRows;
      expect(details, hasLength(1));
    });

    test('builds the workbook: tiles, by location, by auditor, by auditee', () {
      final spec = buildRepeatsReport(
        groups: [
          ...groups,
          {...groups[0], 'count': 10, 'ncIds': ['c'], 'key': 'k3', 'title': 'Trimmed'},
        ],
        ncsById: ncsById,
        minCount: 2,
        generatedAt: generatedAt,
      );
      expect(spec.sheets.map((s) => s.name), ['Summary', 'Repeated Checkpoints', 'Repeat NC Details', 'By Location', 'By Auditor', 'By Auditee']);
      final summary = spec.sheet('Summary')! as ReportSummarySheet;
      final tiles = summary.tileGroups.single.tiles;
      expect(tiles[0].value, 3);
      expect(tiles[1].value, 3 + 2 + 10);
      expect(tiles[5].value, '×10');
      expect(summary.notes.join(' '), contains('raised more often than the list holds'));
      final byAgainst = dataSheet(spec, 'By Auditee').rows;
      expect(byAgainst[0]['name'], 'Ravi');
      expect([byAgainst[0]['ncs'], byAgainst[0]['checkpoints'], byAgainst[0]['places']], [5, 3, 2]);
      expect(headers(dataSheet(spec, 'Repeated Checkpoints')), [
        '#', 'Checkpoint', 'Location / Zone', 'Times Raised', 'Open', 'Closed', 'First Raised', 'Last Raised', 'Latest Status',
        'Raised By (Auditors)', 'Against (Auditees)', 'Audits',
      ]);
      expect(headers(dataSheet(spec, 'Repeat NC Details')), [
        'Checkpoint', 'Location / Zone', 'Time #', 'Of Total', 'NC ID', 'Raised On', 'Audit', 'Raised By (Auditor)', 'Against (Auditee)',
        'Flag', 'Status', 'Target Date', 'Completed On',
      ]);
    });

    test('colours how often a checkpoint came back (3+ amber, 5+ red) and whether any is still open', () {
      final spec = buildRepeatsReport(groups: groups, ncsById: ncsById, generatedAt: generatedAt);
      final cols = dataSheet(spec, 'Repeated Checkpoints').columns;
      final times = cols.firstWhere((c) => c.header == 'Times Raised').tone!;
      expect(times(2, const {}), isNull);
      expect(times(3, const {})!.fg, '#d97706');
      expect(times(5, const {})!.fg, '#dc2626');
      final open = cols.firstWhere((c) => c.header == 'Open').tone!;
      expect(open(2, const {})!.fg, '#d97706');
      expect(open(0, const {})!.fg, '#16a34a');
    });

    test('an empty result still builds every sheet, with a "—" for the most repeated', () {
      final spec = buildRepeatsReport(groups: const [], ncsById: const {}, generatedAt: generatedAt);
      expect(spec.sheets, hasLength(6));
      final tiles = (spec.sheet('Summary')! as ReportSummarySheet).tileGroups.single.tiles;
      expect(tiles.first.value, 0);
      expect(tiles.last.value, '—');
      expect(dataSheet(spec, 'Repeated Checkpoints').rows, isEmpty);
    });

    test('the "Min. times" pick is in the note', () {
      final spec = buildRepeatsReport(groups: groups, ncsById: ncsById, minCount: 5, generatedAt: generatedAt);
      expect((spec.sheet('Summary')! as ReportSummarySheet).notes.first, contains('5+ times'));
    });
  });
}
