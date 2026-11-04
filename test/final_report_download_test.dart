import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/utils/final_report_download.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/final_report_export_service.dart';
import 'package:internal_audit_app/utils/report_file_share.dart';
import 'package:internal_audit_app/utils/report_sheet_spec.dart';

/// Reading EVERY row the filters match, page by page: the paging, retry, cancel and
/// cap rules of the Excel download, against a fake server that answers like the real
/// endpoints do (GET /audits/report pages over groups, /ncs/report flat pages,
/// /ncs/repeats pages then /ncs/repeats/rows by ids).
void main() {
  Map<String, dynamic> emp(String name) => {'_id': name, 'employeeName': name};

  Map<String, dynamic> audit(int i, {String? batch}) => {
    '_id': 'a$i',
    'title': 'Audit $i',
    'status': 'Completed',
    'displayStatus': 'Total Closed',
    'timeliness': 'On-Time Completed',
    'scheduleBatchId': batch,
    'auditorIds': [emp('Asha')],
    'locationIds': [
      {'_id': 'l1', 'name': 'Plant ${i % 3}'},
    ],
    'scoreResult': {'achieved': 8, 'maxPossible': 10, 'percentage': 80},
    'ncSummary': {'total': 1, 'closed': 0},
  };

  Map<String, dynamic> nc(int i) => {
    '_id': 'n$i',
    'ncId': 'NC-$i',
    'title': 'NC $i',
    'severity': 'Minor',
    'status': 'Raised',
    'bucket': 'inProgress',
    'placeLabel': 'Plant 1',
    'raisedByEmployeeId': emp('Asha'),
    'auditeeEmployeeId': emp('Ravi'),
    'startDate': '2026-09-01',
  };

  DioException httpError(String path, int status, {String? message}) => DioException(
    requestOptions: RequestOptions(path: path),
    type: DioExceptionType.badResponse,
    response: Response(
      requestOptions: RequestOptions(path: path),
      statusCode: status,
      data: {'isOk': false, 'message': ?message},
    ),
  );

  DioException offline(String path) => DioException(requestOptions: RequestOptions(path: path), type: DioExceptionType.connectionError);

  const noWait = [Duration.zero, Duration.zero];

  FinalReportDownloader downloader(
    ReportJsonGet get, {
    ExportCancelToken? cancel,
    List<ExportProgress>? progress,
    int pageSize = 100,
    int maxPages = 400,
    int idsPerRequest = 150,
    List<Duration> retryDelays = noWait,
  }) => FinalReportDownloader(
    get: get,
    cancel: cancel,
    onProgress: progress?.add,
    retryDelays: retryDelays,
    pageSize: pageSize,
    maxPages: maxPages,
    idsPerRequest: idsPerRequest,
    clock: () => DateTime(2026, 11, 3, 10),
  );

  FinalReportRequest auditsRequest({Map<String, dynamic>? list, bool withStats = true}) => FinalReportRequest(
    tab: FinalReportTab.audits,
    listQuery: list ?? {'employeeIds': 'me', 'status': 'Overdue', 'search': 'press'},
    statsQuery: withStats ? {'employeeIds': 'me', 'status': 'Overdue', 'search': 'press'} : null,
    filters: const [('Members', 'Only me (Asha)')],
    generatedBy: 'Asha',
  );

  /// A fake GET /audits/report over [audits] groups of one audit each (page + limit are honoured).
  ReportJsonGet auditsServer(List<Map<String, dynamic>> audits, {List<({String path, Map<String, dynamic> query})>? calls, Object? statsAnswer}) {
    return (path, query) async {
      calls?.add((path: path, query: query));
      if (path == ApiConstants.auditsReportStats) {
        return statsAnswer ?? {'isOk': true, 'data': {'percentage': 80, 'totalAudits': audits.length}};
      }
      final byIds = query.containsKey('ids');
      final page = byIds ? 1 : query['page'] as int;
      final limit = byIds ? audits.length : query['limit'] as int;
      return {
        'isOk': true,
        'data': {'audits': audits.skip((page - 1) * limit).take(limit).toList(), 'total': audits.length, 'page': page, 'limit': limit},
      };
    };
  }

  group('Audits', () {
    test('reads EVERY page the filters match, not just the first, with the screen\'s own query on each request', () async {
      final audits = [for (var i = 0; i < 250; i++) audit(i)];
      final calls = <({String path, Map<String, dynamic> query})>[];
      final progress = <ExportProgress>[];
      final build = await downloader(auditsServer(audits, calls: calls), progress: progress).run(auditsRequest());

      expect(build.rowCount, 250);
      final listCalls = calls.where((c) => c.path == ApiConstants.auditsReport).toList();
      expect(listCalls.map((c) => c.query['page']).toList()..sort(), [1, 2, 3]);
      for (final c in listCalls) {
        expect(c.query['limit'], 100);
        // The very filters the list sent: status, search, who.
        expect(c.query['status'], 'Overdue');
        expect(c.query['search'], 'press');
        expect(c.query['employeeIds'], 'me');
      }
      // The tiles are asked with the tiles' own query.
      final stats = calls.singleWhere((c) => c.path == ApiConstants.auditsReportStats);
      expect(stats.query, {'employeeIds': 'me', 'status': 'Overdue', 'search': 'press'});

      final sheet = build.spec.sheet('Audits')! as ReportDataSheet;
      expect(sheet.rows, hasLength(250));
      expect(sheet.rows.first['title'], 'Audit 0');
      expect(sheet.rows.last['title'], 'Audit 249');
      expect(build.spec.filters, auditsRequest().filters);
      expect(build.spec.generatedBy, 'Asha');
      expect(build.warnings, isEmpty);

      // Progress counts what the list pages by, ends complete, then says it is building the file.
      final counts = progress.where((p) => !p.building).toList();
      expect(counts.first.noun, 'reports');
      expect(counts.first.done, 100);
      expect(counts.first.total, 250);
      expect(counts.last.done, 250);
      expect(counts.last.text, 'Preparing Excel… 250 of 250 reports');
      expect(progress.last.building, isTrue);
    });

    test('a tile that is asked by ids (the "other" tile) is one unpaged request', () async {
      final audits = [for (var i = 0; i < 5; i++) audit(i)];
      final calls = <({String path, Map<String, dynamic> query})>[];
      final build = await downloader(auditsServer(audits, calls: calls)).run(auditsRequest(list: {'ids': 'a0,a1,a2,a3,a4'}));
      final listCalls = calls.where((c) => c.path == ApiConstants.auditsReport).toList();
      expect(listCalls, hasLength(1));
      expect(listCalls.single.query.containsKey('page'), isFalse);
      expect(listCalls.single.query.containsKey('limit'), isFalse);
      expect(build.rowCount, 5);
    });

    test('a bundle arrives whole and is listed as a row per zone with one bundle summary', () async {
      final audits = [audit(1, batch: 'B'), audit(2, batch: 'B'), audit(3)];
      final build = await downloader(auditsServer(audits)).run(auditsRequest());
      expect(build.rowCount, 3);
      expect(build.spec.sheet('Bundles'), isNotNull);
    });

    test('reads three pages at a time at most', () async {
      final audits = [for (var i = 0; i < 1000; i++) audit(i)];
      var inFlight = 0;
      var peak = 0;
      final inner = auditsServer(audits);
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        inFlight++;
        peak = peak > inFlight ? peak : inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        try {
          return await inner(path, q);
        } finally {
          inFlight--;
        }
      }

      final build = await downloader(get).run(auditsRequest(withStats: false));
      expect(build.rowCount, 1000);
      expect(peak, 3);
    });

    test('a row seen twice (the list grew while it was read) is kept once', () async {
      // Page 1 holds a0..a1, then the list grows by one: page 2 starts with a1 again.
      final pages = <int, List<Map<String, dynamic>>>{
        1: [audit(0), audit(1)],
        2: [audit(1), audit(2)],
      };
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        return {
          'isOk': true,
          'data': {'audits': pages[q['page']] ?? [], 'total': 4, 'page': q['page'], 'limit': 2},
        };
      }

      final build = await downloader(get, pageSize: 2).run(auditsRequest());
      expect(build.rowCount, 3);
    });

    test('an empty result builds the workbook with no rows', () async {
      final build = await downloader(auditsServer(const [])).run(auditsRequest());
      expect(build.rowCount, 0);
      expect((build.spec.sheet('Audits')! as ReportDataSheet).rows, isEmpty);
      expect(build.spec.sheets.map((s) => s.name), ['Summary', 'Audits', 'By Location', 'By Auditor', 'By Auditee']);
    });

    test('the tiles failing does not stop the export: the file says so', () async {
      final audits = [for (var i = 0; i < 3; i++) audit(i)];
      final server = auditsServer(audits);
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) throw httpError(path, 500);
        return server(path, q);
      }

      final build = await downloader(get).run(auditsRequest());
      expect(build.rowCount, 3);
      expect(build.warnings, contains(statsMissingNote));
      final summary = build.spec.sheet('Summary')! as ReportSummarySheet;
      expect(summary.notes, contains(statsMissingNote));
      expect(summary.tileGroups.map((g) => g.title), ['In this file']);
    });

    test('a safety ceiling on the pages is said out loud — in the warnings and in the file — never a silent cut', () async {
      final audits = [for (var i = 0; i < 55; i++) audit(i)];
      final build = await downloader(auditsServer(audits), pageSize: 10, maxPages: 2).run(auditsRequest());
      expect(build.rowCount, 20);
      expect(build.warnings.single, contains('Only the first 20 of 55 reports'));
      expect((build.spec.sheet('Summary')! as ReportSummarySheet).notes.join(' '), contains('Only the first 20 of 55 reports'));
    });

    test('an answer without a total is read on until a page comes back empty', () async {
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        final page = q['page'] as int;
        return {
          'isOk': true,
          'data': {'audits': page <= 3 ? [audit(page * 10), audit(page * 10 + 1)] : <Object>[]},
        };
      }

      final build = await downloader(get, pageSize: 2).run(auditsRequest());
      expect(build.rowCount, 6);
    });
  });

  group('retry, failure and cancel', () {
    test('a page that fails once is asked again and the export completes', () async {
      final audits = [for (var i = 0; i < 150; i++) audit(i)];
      final inner = auditsServer(audits);
      var failedOnce = false;
      var attemptsOnPage2 = 0;
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReport && q['page'] == 2) {
          attemptsOnPage2++;
          if (!failedOnce) {
            failedOnce = true;
            throw offline(path);
          }
        }
        return inner(path, q);
      }

      final build = await downloader(get).run(auditsRequest());
      expect(build.rowCount, 150);
      expect(attemptsOnPage2, 2);
    });

    test('retries wait between attempts', () async {
      var calls = 0;
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        calls++;
        if (calls < 3) throw httpError(path, 503);
        return {
          'isOk': true,
          'data': {'audits': <Object>[], 'total': 0, 'limit': 100},
        };
      }

      final watch = Stopwatch()..start();
      await downloader(get, retryDelays: const [Duration(milliseconds: 40), Duration(milliseconds: 40)]).run(auditsRequest(withStats: false));
      expect(calls, 3);
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(70));
    });

    test('a page that keeps failing ends the export with a clear message — no half-empty file', () async {
      var attempts = 0;
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        attempts++;
        throw offline(path);
      }

      await expectLater(
        downloader(get).run(auditsRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'Could not reach the server. Check your connection and try again.')),
      );
      expect(attempts, 3); // the first try + two retries
    });

    test('the server\'s own words are shown, and a client error (no access) is not asked again', () async {
      var attempts = 0;
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        attempts++;
        throw httpError(path, 403, message: 'You do not have access to the Final Report.');
      }

      await expectLater(
        downloader(get).run(auditsRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'You do not have access to the Final Report.')),
      );
      expect(attempts, 1);
    });

    test('a 5xx without a message falls back to a plain sentence', () async {
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        throw httpError(path, 500);
      }

      await expectLater(
        downloader(get).run(auditsRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', contains('Could not download the data'))),
      );
    });

    test('an answer that cannot be read is a plain failure, not a crash', () async {
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        return 'not json';
      }

      await expectLater(
        downloader(get).run(auditsRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', contains('Could not read the data'))),
      );
    });

    test('cancelling stops the export between pages — nothing more is asked', () async {
      final audits = [for (var i = 0; i < 1000; i++) audit(i)];
      final calls = <({String path, Map<String, dynamic> query})>[];
      final token = ExportCancelToken();
      final dl = FinalReportDownloader(
        get: auditsServer(audits, calls: calls),
        cancel: token,
        retryDelays: noWait,
        onProgress: (p) {
          if (!p.building && p.done >= 100) token.cancel();
        },
      );
      await expectLater(dl.run(auditsRequest()), throwsA(isA<ExportCancelled>()));
      final pages = calls.where((c) => c.path == ApiConstants.auditsReport).map((c) => c.query['page']).toSet();
      expect(pages, {1});
    });

    test('cancelling while a request is on the wire ends it as a cancel, not as an error', () async {
      final token = ExportCancelToken();
      final started = Completer<void>();
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {}};
        started.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        throw DioException(requestOptions: RequestOptions(path: path), type: DioExceptionType.cancel);
      }

      final run = downloader(get, cancel: token).run(auditsRequest());
      await started.future;
      token.cancel();
      await expectLater(run, throwsA(isA<ExportCancelled>()));
    });
  });

  group('NCs', () {
    FinalReportRequest ncsRequest({Map<String, dynamic>? list}) => FinalReportRequest(
      tab: FinalReportTab.ncs,
      listQuery: list ?? {'employeeIds': 'me', 'severity': 'Major', 'bucket': 'overdue,inProgress', 'search': 'guard'},
      statsQuery: {'employeeIds': 'me', 'severity': 'Major', 'search': 'guard', 'omitIds': '1'},
      generatedBy: 'Asha',
    );

    test('reads every NC page flat (no groupBy), by tile NAME, and the tiles without the tile', () async {
      final ncs = [for (var i = 0; i < 230; i++) nc(i)];
      final calls = <({String path, Map<String, dynamic> query})>[];
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        calls.add((path: path, query: q));
        if (path == ApiConstants.ncsReportStats) {
          return {
            'isOk': true,
            'data': {'total': 230, 'inProgress': 230, 'overdue': 0, 'pendingApproval': 0, 'delayed': 0, 'onTime': 0},
          };
        }
        final page = q['page'] as int;
        final limit = q['limit'] as int;
        return {
          'isOk': true,
          'data': {'ncs': ncs.skip((page - 1) * limit).take(limit).toList(), 'total': ncs.length, 'page': page, 'limit': limit},
        };
      }

      final progress = <ExportProgress>[];
      final build = await downloader(get, progress: progress).run(ncsRequest());
      expect(build.rowCount, 230);
      final listCalls = calls.where((c) => c.path == ApiConstants.ncsReport).toList();
      expect(listCalls.map((c) => c.query['page']).toList()..sort(), [1, 2, 3]);
      for (final c in listCalls) {
        expect(c.query.containsKey('groupBy'), isFalse);
        expect(c.query['bucket'], 'overdue,inProgress');
        expect(c.query['severity'], 'Major');
        expect(c.query['search'], 'guard');
        expect(c.query['limit'], 100);
      }
      final stats = calls.singleWhere((c) => c.path == ApiConstants.ncsReportStats);
      expect(stats.query.containsKey('bucket'), isFalse); // the tiles describe the whole set
      expect(stats.query['omitIds'], '1');
      expect(progress.where((p) => !p.building).last.text, 'Preparing Excel… 230 of 230 NCs');

      final rows = (build.spec.sheet('NCs')! as ReportDataSheet).rows;
      expect(rows, hasLength(230));
      expect(rows.first['ncId'], 'NC-0');
      final tiles = (build.spec.sheet('Summary')! as ReportSummarySheet).tileGroups.first.tiles;
      expect(tiles.first.value, 230);
    });

    test('the file is stamped with the day it was made', () async {
      Future<dynamic> get(String path, Map<String, dynamic> q) async => path == ApiConstants.ncsReportStats
          ? {'isOk': true, 'data': {}}
          : {
              'isOk': true,
              'data': {'ncs': <Object>[], 'total': 0, 'page': 1, 'limit': 100},
            };
      final build = await downloader(get).run(ncsRequest());
      expect(build.spec.filename, 'Final-Report-NCs-2026-11-03');
      expect(build.rowCount, 0);
    });
  });

  group('Repeated NCs', () {
    FinalReportRequest repeatsRequest() => const FinalReportRequest(
      tab: FinalReportTab.repeats,
      listQuery: {'minCount': 3, 'fromDate': '2026-05-03', 'locationIds': 'l1'},
      generatedBy: 'Asha',
      minCount: 3,
    );

    test('reads every repeated checkpoint, then every NC behind them in id chunks, and builds both sheets', () async {
      // 5 groups of 2 NCs each; the listing is paged 2 at a time and the NCs are fetched 4 ids at a time.
      final groups = [
        for (var g = 0; g < 5; g++)
          {
            'key': 'k$g',
            'title': 'Checkpoint $g',
            'locationName': 'Plant 1',
            'count': 2,
            'openCount': 1,
            'firstDate': '2026-07-01',
            'lastDate': '2026-09-01',
            'latestStatus': 'Raised',
            'ncIds': ['g${g}b', 'g${g}a'],
          },
      ];
      final ncs = {
        for (final g in groups)
          for (final id in g['ncIds'] as List) id.toString(): {...nc(0), '_id': id, 'ncId': 'NC-$id', 'startDate': id.toString().endsWith('a') ? '2026-07-01' : '2026-09-01'},
      };
      final calls = <({String path, Map<String, dynamic> query})>[];
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        calls.add((path: path, query: q));
        if (path == ApiConstants.ncsRepeats) {
          final page = q['page'] as int;
          final limit = q['limit'] as int;
          return {
            'isOk': true,
            'data': {'rows': groups.skip((page - 1) * limit).take(limit).toList(), 'total': groups.length, 'page': page, 'limit': limit},
          };
        }
        final ids = '${q['ids']}'.split(',');
        return {
          'isOk': true,
          'data': [for (final id in ids) ncs[id]],
        };
      }

      final progress = <ExportProgress>[];
      final build = await downloader(get, pageSize: 2, idsPerRequest: 4, progress: progress).run(repeatsRequest());

      final listCalls = calls.where((c) => c.path == ApiConstants.ncsRepeats).toList();
      expect(listCalls.map((c) => c.query['page']).toList()..sort(), [1, 2, 3]);
      for (final c in listCalls) {
        expect(c.query['minCount'], 3);
        expect(c.query['fromDate'], '2026-05-03');
        expect(c.query['locationIds'], 'l1');
      }
      final rowCalls = calls.where((c) => c.path == ApiConstants.ncsRepeatRows).toList();
      expect(rowCalls, hasLength(3)); // 10 ids, 4 at a time
      expect(rowCalls.map((c) => '${c.query['ids']}'.split(',').length).toList()..sort(), [2, 4, 4]);

      expect(build.rowCount, 5);
      final details = (build.spec.sheet('Repeat NC Details')! as ReportDataSheet).rows;
      expect(details, hasLength(10));
      expect((build.spec.sheet('Repeated Checkpoints')! as ReportDataSheet).rows, hasLength(5));
      expect((build.spec.sheet('Summary')! as ReportSummarySheet).notes.first, contains('3+ times'));
      expect(progress.map((p) => p.noun).toSet(), containsAll(['repeated checkpoints', 'NCs in those checkpoints']));
      expect(progress.last.building, isTrue);
    });

    test('an NC the server did not return is simply left out of the details', () async {
      final groups = [
        {'key': 'k', 'title': 'T', 'locationName': 'P', 'count': 2, 'openCount': 0, 'latestStatus': 'Closed', 'ncIds': ['x', 'y']},
      ];
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.ncsRepeats) {
          return {
            'isOk': true,
            'data': {'rows': groups, 'total': 1, 'page': 1, 'limit': 100},
          };
        }
        return {
          'isOk': true,
          'data': [
            {...nc(0), '_id': 'x'},
          ],
        };
      }

      final build = await downloader(get).run(repeatsRequest());
      expect((build.spec.sheet('Repeat NC Details')! as ReportDataSheet).rows, hasLength(1));
    });

    test('a failing NC-details request is retried, then stops the export', () async {
      final groups = [
        {'key': 'k', 'title': 'T', 'locationName': 'P', 'count': 2, 'openCount': 0, 'ncIds': ['x', 'y']},
      ];
      var detailAttempts = 0;
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.ncsRepeats) {
          return {
            'isOk': true,
            'data': {'rows': groups, 'total': 1, 'page': 1, 'limit': 100},
          };
        }
        detailAttempts++;
        throw offline(path);
      }

      await expectLater(downloader(get).run(repeatsRequest()), throwsA(isA<ReportExportException>()));
      expect(detailAttempts, 3);
    });

    test('no repeated checkpoints at all still builds an (empty) workbook', () async {
      Future<dynamic> get(String path, Map<String, dynamic> q) async => {
        'isOk': true,
        'data': {'rows': <Object>[], 'total': 0, 'page': 1, 'limit': 100},
      };
      final build = await downloader(get).run(repeatsRequest());
      expect(build.rowCount, 0);
      expect(build.spec.sheets, hasLength(6));
    });
  });

  group('Download All', () {
    FinalReportRequest ncsPart() => const FinalReportRequest(
      tab: FinalReportTab.ncs,
      listQuery: {'employeeIds': 'me', 'severity': 'Major', 'bucket': 'overdue', 'search': 'guard'},
      statsQuery: {'employeeIds': 'me', 'severity': 'Major', 'search': 'guard', 'omitIds': '1'},
      filters: [('Flag', 'Major')],
    );
    FinalReportRequest repeatsPart() => const FinalReportRequest(
      tab: FinalReportTab.repeats,
      listQuery: {'minCount': 3, 'fromDate': '2026-05-03', 'search': 'floor'},
      filters: [('Search', '"floor"'), ('Minimum repeats', '3+ times at the same place')],
      minCount: 3,
    );
    FinalReportAllRequest allRequest() => FinalReportAllRequest(
      audits: auditsRequest(),
      ncs: ncsPart(),
      repeats: repeatsPart(),
      generatedBy: 'Asha',
    );

    /// One fake server for the three tabs' endpoints; every request is logged in order.
    ReportJsonGet server({
      required List<String> log,
      int audits = 120,
      int ncs = 130,
      Future<dynamic> Function(String path, Map<String, dynamic> q)? override,
    }) {
      final auditRows = [for (var i = 0; i < audits; i++) audit(i)];
      final ncRows = [for (var i = 0; i < ncs; i++) nc(i)];
      final repeatGroups = [
        {'key': 'k1', 'title': 'Wet floor', 'locationName': 'Plant 1', 'count': 2, 'openCount': 1, 'firstDate': '2026-07-01', 'lastDate': '2026-09-01', 'latestStatus': 'Raised', 'ncIds': ['r2', 'r1']},
      ];
      return (path, q) async {
        log.add(path);
        final custom = await override?.call(path, q);
        if (custom != null) return custom;
        switch (path) {
          case ApiConstants.auditsReportStats:
            return {'isOk': true, 'data': {'percentage': 80, 'totalAudits': audits}};
          case ApiConstants.auditsReport:
            return {
              'isOk': true,
              'data': {'audits': auditRows.skip(((q['page'] as int) - 1) * 100).take(100).toList(), 'total': audits, 'page': q['page'], 'limit': 100},
            };
          case ApiConstants.ncsReportStats:
            return {'isOk': true, 'data': {'total': ncs, 'overdue': ncs}};
          case ApiConstants.ncsReport:
            return {
              'isOk': true,
              'data': {'ncs': ncRows.skip(((q['page'] as int) - 1) * 100).take(100).toList(), 'total': ncs, 'page': q['page'], 'limit': 100},
            };
          case ApiConstants.ncsRepeats:
            return {
              'isOk': true,
              'data': {'rows': repeatGroups, 'total': 1, 'page': 1, 'limit': 100},
            };
          default:
            return {
              'isOk': true,
              'data': [
                {...nc(0), '_id': 'r1', 'ncId': 'NC-r1', 'startDate': '2026-07-01'},
                {...nc(0), '_id': 'r2', 'ncId': 'NC-r2', 'startDate': '2026-09-01'},
              ],
            };
        }
      };
    }

    bool isAudits(String p) => p == ApiConstants.auditsReport || p == ApiConstants.auditsReportStats;
    bool isNcs(String p) => p == ApiConstants.ncsReport || p == ApiConstants.ncsReportStats;

    test('reads the three parts ONE AFTER THE OTHER — Audits, then NCs, then Repeated NCs — never together', () async {
      final log = <String>[];
      final inner = server(log: log);
      var inFlight = 0;
      var partsInFlight = 0;
      var maxParts = 0;
      final live = <String, int>{};
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        final part = isAudits(path) ? 'a' : isNcs(path) ? 'n' : 'r';
        live[part] = (live[part] ?? 0) + 1;
        inFlight++;
        partsInFlight = live.values.where((v) => v > 0).length;
        maxParts = maxParts > partsInFlight ? maxParts : partsInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 3));
        try {
          return await inner(path, q);
        } finally {
          live[part] = live[part]! - 1;
          inFlight--;
        }
      }

      final build = await downloader(get).runAll(allRequest());
      expect(inFlight, 0);
      expect(maxParts, 1, reason: 'two parts were being read at the same time');
      final lastAudit = log.lastIndexWhere(isAudits);
      final firstNc = log.indexWhere(isNcs);
      final lastNc = log.lastIndexWhere(isNcs);
      final firstRepeat = log.indexWhere((p) => !isAudits(p) && !isNcs(p));
      expect(lastAudit, lessThan(firstNc));
      expect(lastNc, lessThan(firstRepeat));
      // 120 reports = 2 pages, 130 NCs = 2 pages.
      expect(log.where((p) => p == ApiConstants.auditsReport), hasLength(2));
      expect(log.where((p) => p == ApiConstants.ncsReport), hasLength(2));
      expect(build.rowCount, 120 + 130 + 1);
    });

    test('each part is read under ITS OWN tab\'s query, frozen at the tap', () async {
      final calls = <({String path, Map<String, dynamic> query})>[];
      final inner = server(log: []);
      Future<dynamic> get(String path, Map<String, dynamic> q) {
        calls.add((path: path, query: q));
        return inner(path, q);
      }

      final request = allRequest();
      await downloader(get).runAll(request);
      for (final c in calls.where((c) => c.path == ApiConstants.auditsReport)) {
        expect(c.query['status'], 'Overdue');
        expect(c.query['search'], 'press');
        expect(c.query.containsKey('bucket'), isFalse);
      }
      for (final c in calls.where((c) => c.path == ApiConstants.ncsReport)) {
        expect(c.query['bucket'], 'overdue');
        expect(c.query['severity'], 'Major');
        expect(c.query['search'], 'guard');
      }
      final repeats = calls.singleWhere((c) => c.path == ApiConstants.ncsRepeats);
      expect(repeats.query['minCount'], 3);
      expect(repeats.query['fromDate'], '2026-05-03');
      expect(repeats.query['search'], 'floor');
      expect(calls.singleWhere((c) => c.path == ApiConstants.ncsReportStats).query['omitIds'], '1');
      expect(calls.singleWhere((c) => c.path == ApiConstants.auditsReportStats).query['status'], 'Overdue');
    });

    test('the progress line names the part being read, and "Building" comes once, at the very end', () async {
      final progress = <ExportProgress>[];
      await downloader(server(log: []), progress: progress).runAll(allRequest());
      final texts = progress.map((p) => p.text).toList();
      expect(texts, contains('Audits — 100 of 120 reports'));
      expect(texts, contains('Audits — 120 of 120 reports'));
      expect(texts, contains('NCs — 100 of 130 NCs'));
      expect(texts, contains('NCs — 130 of 130 NCs'));
      expect(texts, contains('Repeated NCs — 1 of 1 repeated checkpoints'));
      expect(texts, contains('Repeated NCs — 2 of 2 NCs in those checkpoints'));
      // Parts come in order, and each line carries its part.
      final parts = [for (final p in progress) if (!p.building) p.part];
      expect(parts.first, 'Audits');
      expect(parts.last, 'Repeated NCs');
      expect(parts.indexOf('NCs'), greaterThan(parts.lastIndexOf('Audits')));
      expect(parts.indexOf('Repeated NCs'), greaterThan(parts.lastIndexOf('NCs')));
      expect(parts.every((p) => p.isNotEmpty), isTrue);
      // "Building the Excel file…" once, last — not between the parts.
      expect(progress.where((p) => p.building), hasLength(1));
      expect(progress.last.building, isTrue);
    });

    test('folds the three parts into ONE workbook: one Summary, then the tabs\' sheets, named for the day', () async {
      final build = await downloader(server(log: [])).runAll(allRequest());
      expect(build.spec.filename, 'Final-Report-All-2026-11-03');
      expect(build.spec.sheets.map((s) => s.name), [
        'Summary',
        'Audits', 'Audits By Location', 'Audits By Auditor', 'Audits By Auditee',
        'NCs', 'NCs By Location', 'NCs By Auditor', 'NCs By Auditee',
        'Repeated Checkpoints', 'Repeat NC Details', 'Repeats By Location', 'Repeats By Auditor', 'Repeats By Auditee',
      ]);
      expect((build.spec.sheet('Audits')! as ReportDataSheet).rows, hasLength(120));
      expect((build.spec.sheet('NCs')! as ReportDataSheet).rows, hasLength(130));
      expect((build.spec.sheet('Repeat NC Details')! as ReportDataSheet).rows, hasLength(2));
      expect(build.spec.generatedBy, 'Asha');
      // The Search the Repeated NCs part carries is in the file, led by its tab.
      expect(build.spec.filters, contains(('Repeated NCs · Search', '"floor"')));
      expect(build.spec.filters, contains(('Repeated NCs · Minimum repeats', '3+ times at the same place')));
    });

    test('if ANY part fails the whole download fails — and nothing after it is read', () async {
      final log = <String>[];
      final ncsDown = server(log: log, override: (path, q) async {
        if (path == ApiConstants.ncsReport) throw httpError(path, 403, message: 'No access to the NCs.');
        return null;
      });
      await expectLater(
        downloader(ncsDown).runAll(allRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'No access to the NCs.')),
      );
      expect(log.any((p) => p == ApiConstants.ncsRepeats), isFalse, reason: 'the Repeated NCs part must not even start');

      // The LAST part failing loses the first two too: no file with a part missing.
      final repeatsDown = server(log: [], override: (path, q) async {
        if (path == ApiConstants.ncsRepeats) throw offline(path);
        return null;
      });
      await expectLater(
        downloader(repeatsDown).runAll(allRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'Could not reach the server. Check your connection and try again.')),
      );

      // The FIRST part failing: nothing else is asked.
      final log2 = <String>[];
      final auditsDown = server(log: log2, override: (path, q) async {
        if (path == ApiConstants.auditsReport) throw httpError(path, 500);
        return null;
      });
      await expectLater(downloader(auditsDown).runAll(allRequest()), throwsA(isA<ReportExportException>()));
      expect(log2.any(isNcs), isFalse);
    });

    test('a page of a part that fails once is asked again — each part retries like its own tab does', () async {
      var failed = false;
      var ncPage2 = 0;
      final inner = server(log: []);
      Future<dynamic> get(String path, Map<String, dynamic> q) async {
        if (path == ApiConstants.ncsReport && q['page'] == 2) {
          ncPage2++;
          if (!failed) {
            failed = true;
            throw offline(path);
          }
        }
        return inner(path, q);
      }

      final build = await downloader(get).runAll(allRequest());
      expect(build.rowCount, 251);
      expect(ncPage2, 2);
    });

    test('cancelling at any point stops it: nothing further is read', () async {
      // During the NCs part.
      final log = <String>[];
      final token = ExportCancelToken();
      final dl = FinalReportDownloader(
        get: server(log: log),
        cancel: token,
        retryDelays: noWait,
        onProgress: (p) {
          if (p.part == 'NCs' && !p.building && p.done >= 100) token.cancel();
        },
      );
      await expectLater(dl.runAll(allRequest()), throwsA(isA<ExportCancelled>()));
      expect(log.any((p) => p == ApiConstants.ncsRepeats), isFalse);

      // During the very first part.
      final log2 = <String>[];
      final token2 = ExportCancelToken();
      final dl2 = FinalReportDownloader(
        get: server(log: log2),
        cancel: token2,
        retryDelays: noWait,
        onProgress: (p) {
          if (p.part == 'Audits' && !p.building) token2.cancel();
        },
      );
      await expectLater(dl2.runAll(allRequest()), throwsA(isA<ExportCancelled>()));
      expect(log2.any(isNcs), isFalse);

      // During the last (Repeated NCs) part, between its two requests.
      final token3 = ExportCancelToken();
      final dl3 = FinalReportDownloader(
        get: server(log: []),
        cancel: token3,
        retryDelays: noWait,
        onProgress: (p) {
          if (p.part == 'Repeated NCs' && p.noun == 'repeated checkpoints') token3.cancel();
        },
      );
      await expectLater(dl3.runAll(allRequest()), throwsA(isA<ExportCancelled>()));
    });

    test('a part whose tiles could not be loaded still goes in, and the file and the warnings say which', () async {
      final noTiles = server(log: [], override: (path, q) async {
        if (path == ApiConstants.ncsReportStats) throw httpError(path, 500);
        return null;
      });
      final build = await downloader(noTiles).runAll(allRequest());
      expect(build.warnings, ['NCs: $statsMissingNote']);
      final summary = build.spec.sheet('Summary')! as ReportSummarySheet;
      expect(summary.notes, contains('NCs: $statsMissingNote'));
      expect(summary.tileGroups.map((g) => g.title), isNot(contains('NCs — NC overview')));
      expect(summary.tileGroups.map((g) => g.title), contains('Audits — Audit overview'));
    });

    test('an empty result in every part still builds the whole workbook', () async {
      final build = await downloader(server(log: [], audits: 0, ncs: 0, override: (path, q) async {
        if (path == ApiConstants.ncsRepeats) {
          return {
            'isOk': true,
            'data': {'rows': <Object>[], 'total': 0, 'page': 1, 'limit': 100},
          };
        }
        return null;
      })).runAll(allRequest());
      expect(build.rowCount, 0);
      expect(build.spec.sheets, hasLength(14));
    });

    test('the combined file\'s warnings travel with the service result and its name is Final-Report-All-…', () async {
      final events = <String>[];
      final svc = FinalReportExportService(
        getter: (cancel) => server(log: []),
        encode: (spec) async {
          events.add('encode ${spec.sheets.length} sheets');
          return Uint8List.fromList([1, 2]);
        },
        sharer: _FakeSharer(events),
        retryDelays: noWait,
      );
      final result = await svc.exportAll(allRequest(), shareOrigin: const Rect.fromLTWH(1, 2, 3, 4));
      expect(result.fileName, matches(RegExp(r'^Final-Report-All-\d{4}-\d{2}-\d{2}\.xlsx$')));
      expect(result.rowCount, 251);
      expect(events, ['encode 14 sheets', 'share ${result.fileName} 2 bytes']);
    });

    test('a failing part leaves nothing to write or share', () async {
      final events = <String>[];
      final svc = FinalReportExportService(
        getter: (cancel) => server(log: [], override: (path, q) async {
          if (path == ApiConstants.ncsRepeats) throw httpError(path, 500);
          return null;
        }),
        encode: (spec) async {
          events.add('encode');
          return Uint8List.fromList([1]);
        },
        sharer: _FakeSharer(events),
        retryDelays: noWait,
      );
      await expectLater(svc.exportAll(allRequest()), throwsA(isA<ReportExportException>()));
      expect(events, isEmpty);
    });
  });

  group('ExportProgress', () {
    test('says what is counted, a fraction for the bar, and builds', () {
      const p = ExportProgress(noun: 'NCs', done: 120, total: 340);
      expect(p.text, 'Preparing Excel… 120 of 340 NCs');
      expect(p.fraction, closeTo(0.3529, 1e-3));
      expect(const ExportProgress(noun: 'NCs', done: 12).text, 'Preparing Excel… 12 NCs');
      expect(const ExportProgress(noun: 'NCs', done: 12).fraction, isNull);
      expect(const ExportProgress(noun: '').text, 'Preparing Excel…');
      expect(const ExportProgress.building().text, 'Building the Excel file…');
      expect(const ExportProgress.building().fraction, isNull);
      expect(const ExportProgress(noun: 'NCs', done: 500, total: 340).fraction, 1.0);
      // In "Download All" the line names the part being read.
      expect(const ExportProgress(noun: 'reports', done: 120, total: 340, part: 'Audits').text, 'Audits — 120 of 340 reports');
      expect(const ExportProgress(noun: 'NCs', done: 12, part: 'NCs').text, 'NCs — 12 NCs');
      expect(const ExportProgress(part: 'Repeated NCs').text, 'Repeated NCs — preparing…');
      expect(const ExportProgress(noun: 'NCs', done: 1, total: 2).forPart('NCs').text, 'NCs — 1 of 2 NCs');
      expect(const ExportProgress.building().forPart('NCs').text, 'Building the Excel file…');
    });
  });

  group('FinalReportExportService', () {
    final events = <String>[];
    setUp(events.clear);

    ReportJsonGet Function(ExportCancelToken) okServer() => (cancel) => (path, query) async {
      events.add('get $path');
      if (path == ApiConstants.auditsReportStats) return {'isOk': true, 'data': {'totalAudits': 1}};
      return {
        'isOk': true,
        'data': {'audits': [audit(1)], 'total': 1, 'page': 1, 'limit': 100},
      };
    };

    FinalReportExportService service({
      Future<Uint8List> Function(ReportWorkbookSpec)? encode,
      ReportFileSharer? sharer,
      ReportJsonGet Function(ExportCancelToken)? getter,
    }) => FinalReportExportService(
      getter: getter ?? okServer(),
      encode: encode ?? (spec) async {
        events.add('encode ${spec.filename}');
        return Uint8List.fromList([1, 2, 3]);
      },
      sharer: sharer ?? _FakeSharer(events),
      retryDelays: noWait,
    );

    test('reads, writes the file, then opens the share sheet with the right name', () async {
      final result = await service().export(auditsRequest());
      expect(result.fileName, matches(RegExp(r'^Final-Report-Audits-\d{4}-\d{2}-\d{2}\.xlsx$')));
      expect(result.rowCount, 1);
      expect(result.shareOutcome, ReportShareOutcome.shared);
      expect(events.where((e) => !e.startsWith('get')).toList(), [
        'encode ${result.fileName.replaceAll('.xlsx', '')}',
        'share ${result.fileName} 3 bytes',
      ]);
    });

    test('hands the share sheet the origin it was given (the iPad popover anchor)', () async {
      final sharer = _FakeSharer(events);
      await service(sharer: sharer).export(auditsRequest(), shareOrigin: const Rect.fromLTWH(10, 20, 30, 40));
      expect(sharer.origin, const Rect.fromLTWH(10, 20, 30, 40));
    });

    test('a download that was cancelled never reaches the share sheet', () async {
      final token = ExportCancelToken();
      final svc = service(encode: (spec) async {
        token.cancel();
        return Uint8List.fromList([1]);
      });
      await expectLater(svc.export(auditsRequest(), cancel: token), throwsA(isA<ExportCancelled>()));
      expect(events.any((e) => e.startsWith('share')), isFalse);
    });

    test('a file that cannot be written says so', () async {
      final svc = service(encode: (spec) async => throw StateError('disk'));
      await expectLater(
        svc.export(auditsRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'Could not create the Excel file. Please try again.')),
      );
    });

    test('a share sheet that cannot be opened says so', () async {
      final svc = service(sharer: _FakeSharer(events, fail: true));
      await expectLater(
        svc.export(auditsRequest()),
        throwsA(isA<ReportExportException>().having((e) => e.message, 'message', contains('could not be opened for sharing'))),
      );
    });

    test('a failed read never gets as far as writing a file', () async {
      final svc = service(getter: (cancel) => (path, query) async => throw httpError(path, 403, message: 'No access'));
      await expectLater(svc.export(auditsRequest()), throwsA(isA<ReportExportException>()));
      expect(events.any((e) => e.startsWith('encode')), isFalse);
    });

    test('warnings (the tiles were missing) travel with the result', () async {
      final svc = service(getter: (cancel) => (path, query) async {
        if (path == ApiConstants.auditsReportStats) throw httpError(path, 500);
        return {
          'isOk': true,
          'data': {'audits': <Object>[], 'total': 0, 'page': 1, 'limit': 100},
        };
      });
      final result = await svc.export(auditsRequest());
      expect(result.warnings, [statsMissingNote]);
    });
  });
}

class _FakeSharer implements ReportFileSharer {
  _FakeSharer(this.events, {this.fail = false});

  final List<String> events;
  final bool fail;
  Rect? origin;

  @override
  Future<ReportShareOutcome> shareXlsx({required String fileName, required Uint8List bytes, Rect? origin}) async {
    if (fail) throw StateError('no share sheet');
    this.origin = origin;
    events.add('share $fileName ${bytes.length} bytes');
    return ReportShareOutcome.shared;
  }
}
