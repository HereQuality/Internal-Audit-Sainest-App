import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/models/employee_option.dart';
import 'package:internal_audit_app/models/location_option.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/utils/final_report_download.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/final_report_export_service.dart';
import 'package:internal_audit_app/utils/final_report_request.dart';
import 'package:internal_audit_app/utils/report_file_share.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/report_list_fake.dart';
import 'support/session_fakes.dart';

/// The whole "Download Excel" job with nothing faked but the network's far end and the OS:
/// the providers' filters -> the queries the screen's lists send -> every page read through
/// the app's real Dio client -> the workbook written in a background isolate -> the file
/// handed to the share plugin (at its method channel). Then the file is opened again and
/// read back — what a person would find in Excel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory temp;
  late FakeAdapter adapter;
  final shared = <Map<Object?, Object?>>[];

  late AuditsProvider audits;
  late NcProvider ncs;
  late FilterOptionsProvider options;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    temp = Directory.systemTemp.createTempSync('final_report_e2e');
    shared.clear();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async => temp.path);
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.add(Map<Object?, Object?>.from(call.arguments as Map));
      return 'dev.fluttercommunity.plus/share/success';
    });
    adapter = FakeAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    audits = AuditsProvider()..setSelfEmployeeId('me');
    ncs = NcProvider()..setSelfEmployeeId('me');
    options = FilterOptionsProvider()
      ..employees = [const EmployeeOption(id: 'me', name: 'Asha Rao')]
      ..locations = [const LocationOption(id: 'l1', name: 'Plant 1', code: 'P1', locationType: 'Zone')];
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Map<String, dynamic> emp(String name) => {'_id': name, 'employeeName': name};

  Future<xl.Excel> sharedWorkbook() async {
    final path = (shared.single['paths'] as List).single as String;
    expect(path, matches(RegExp(r'Final-Report-[A-Za-z-]+-\d{4}-\d{2}-\d{2}\.xlsx$')));
    expect((shared.single['mimeTypes'] as List).single, xlsxMimeType);
    return xl.Excel.decodeBytes(Uint8List.fromList(await File(path).readAsBytes()));
  }

  test('Audits: every page of what the filters match ends up in the file the share sheet is given', () async {
    final rows = [
      for (var i = 0; i < 230; i++)
        {
          '_id': 'a$i',
          'title': 'Audit $i',
          'auditNumber': 'AUD-$i',
          'scope': '',
          'status': 'Completed',
          'displayStatus': i.isEven ? 'Total Closed' : 'NC Response Pending',
          'timeliness': 'On-Time Completed',
          'auditorIds': [emp('Asha')],
          'auditeeIds': [emp('Ravi')],
          'locationIds': [
            {'_id': 'l1', 'name': 'Plant 1', 'code': 'P1'},
          ],
          'scoreResult': {'achieved': 8, 'maxPossible': 10, 'percentage': 80},
          'ncSummary': {'total': 2, 'closed': 1},
          'scheduledDate': '2026-09-01T00:00:00.000Z',
        },
    ];
    adapter.handler = (o) async {
      if (o.path == ApiConstants.auditsReport) return json(200, {'isOk': true, 'data': reportListData(rows, o.queryParameters)});
      if (o.path == ApiConstants.auditsReportStats) {
        return json(200, {
          'isOk': true,
          'data': {'percentage': 80, 'achieved': 1840, 'maxPossible': 2300, 'totalAudits': 230, 'inProgress': 0, 'onTimeCompleted': 230, 'delayedCompleted': 0},
        });
      }
      return json(200, {'isOk': true, 'data': <Object>[]});
    };
    audits
      ..setFilterState(isTeam: true, locations: ['l1'])
      ..reportsStatus = 'Completed'
      ..reportsSearch = 'Audit';

    final request = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options, generatedBy: 'Asha Rao');
    final progress = <ExportProgress>[];
    final result = await FinalReportExportService().export(request, onProgress: progress.add, shareOrigin: const Rect.fromLTWH(0, 0, 100, 44));

    expect(result.rowCount, 230);
    expect(result.warnings, isEmpty);
    expect(result.fileName, startsWith('Final-Report-Audits-'));
    expect(progress.where((p) => !p.building).last.text, 'Preparing Excel… 230 of 230 reports');

    // Every page was asked with the screen's own filters.
    final pages = adapter.where('GET', ApiConstants.auditsReport).toList();
    expect(pages.map((r) => r.queryParameters['page']).toList()..sort(), [1, 2, 3]);
    for (final r in pages) {
      expect(r.queryParameters['locationIds'], 'l1');
      expect(r.queryParameters['status'], 'Completed');
      expect(r.queryParameters['search'], 'Audit');
      expect(r.queryParameters['limit'], 100);
    }
    expect(adapter.where('GET', ApiConstants.auditsReportStats).single.queryParameters['status'], 'Completed');

    // ...and the file has them all.
    final book = await sharedWorkbook();
    expect(book.tables.keys.toList(), ['Summary', 'Audits', 'By Location', 'By Auditor', 'By Auditee']);
    expect(book['Audits'].maxRows, 4 + 230);
    expect((book['Audits'].cell(xl.CellIndex.indexByString('C5')).value as xl.TextCellValue).value.text, 'Audit 0');
    expect((book['Audits'].cell(xl.CellIndex.indexByString('C234')).value as xl.TextCellValue).value.text, 'Audit 229');
    String summary(String ref) => (book['Summary'].cell(xl.CellIndex.indexByString(ref)).value as xl.TextCellValue).value.text!;
    expect(summary('A5'), 'Team');
    expect(summary('A7'), 'Location');
    expect(summary('B6'), 'All members');
    expect(summary('B7'), 'Plant 1 (P1)');
    expect(book['By Location'].cell(xl.CellIndex.indexByString('B5')).value, isNotNull);
  });

  test('NCs: reads every NC page by tile name, and the Summary tiles come from the tiles\' own request', () async {
    final all = [
      for (var i = 0; i < 130; i++)
        {
          '_id': 'n$i',
          'ncId': 'NC-$i',
          'title': 'Guard missing $i',
          'severity': i % 2 == 0 ? 'Major' : 'Minor',
          'status': 'Raised',
          'bucket': 'overdue',
          'placeLabel': 'Plant ${i % 2}',
          'auditId': {'_id': 'a1', 'title': 'Safety walk', 'auditType': 'Safety'},
          'raisedByEmployeeId': emp('Asha'),
          'auditeeEmployeeId': emp('Ravi'),
          'startDate': '2026-09-01T00:00:00.000Z',
          'targetDate': '2026-09-10T00:00:00.000Z',
          'repeatCount': 0,
        },
    ];
    adapter.handler = (o) async {
      if (o.path == ApiConstants.ncsReport) {
        final page = o.queryParameters['page'] as int;
        final limit = o.queryParameters['limit'] as int;
        return json(200, {
          'isOk': true,
          'data': {'ncs': all.skip((page - 1) * limit).take(limit).toList(), 'total': all.length, 'page': page, 'limit': limit},
        });
      }
      if (o.path == ApiConstants.ncsReportStats) {
        return json(200, {
          'isOk': true,
          'data': {'total': 130, 'inProgress': 0, 'overdue': 130, 'pendingApproval': 0, 'delayed': 0, 'onTime': 0, 'atsScore': 40.5, 'otcScore': 0},
        });
      }
      return json(200, {'isOk': true, 'data': <Object>[]});
    };
    ncs
      ..setFilterState(isTeam: true, flags: ['Major', 'Minor'])
      ..ncReportTileKeys = {'overdue'};

    final request = buildFinalReportRequest(tab: FinalReportTab.ncs, audits: audits, ncs: ncs, options: options);
    final result = await FinalReportExportService().export(request);
    expect(result.rowCount, 130);

    final pages = adapter.where('GET', ApiConstants.ncsReport).toList();
    expect(pages.map((r) => r.queryParameters['page']).toList()..sort(), [1, 2]);
    expect(pages.every((r) => r.queryParameters['bucket'] == 'overdue' && !r.queryParameters.containsKey('groupBy')), isTrue);
    final stats = adapter.where('GET', ApiConstants.ncsReportStats).single;
    expect(stats.queryParameters.containsKey('bucket'), isFalse);
    expect(stats.queryParameters['omitIds'], '1');

    final book = await sharedWorkbook();
    expect(book.tables.keys.toList(), ['Summary', 'NCs', 'By Location', 'By Auditor', 'By Auditee']);
    expect(book['NCs'].maxRows, 4 + 130);
    final raisedBy = book['NCs'].cell(xl.CellIndex.indexByString('F5')).value as xl.TextCellValue;
    expect(raisedBy.value.text, 'Asha');
    final against = book['NCs'].cell(xl.CellIndex.indexByString('G5')).value as xl.TextCellValue;
    expect(against.value.text, 'Ravi');
    expect((book['By Auditee'].cell(xl.CellIndex.indexByString('A5')).value as xl.TextCellValue).value.text, 'Ravi');
    expect((book['By Auditee'].cell(xl.CellIndex.indexByString('B5')).value as xl.IntCellValue).value, 130);
  });

  test('Repeated NCs: the checkpoints, then every NC behind them, written as two sheets and the tallies', () async {
    final groups = [
      {'key': 'k1', 'title': 'Guard missing', 'locationName': 'Plant 1', 'count': 2, 'openCount': 1, 'firstDate': '2026-07-01', 'lastDate': '2026-09-01', 'latestStatus': 'Raised', 'ncIds': ['b', 'a']},
    ];
    final byId = {
      'a': {'_id': 'a', 'ncId': 'NC-a', 'startDate': '2026-07-01', 'status': 'Closed', 'completionDate': '2026-07-09', 'auditId': {'_id': 'x', 'title': 'Audit x'}, 'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Ravi')},
      'b': {'_id': 'b', 'ncId': 'NC-b', 'startDate': '2026-09-01', 'status': 'Raised', 'severity': 'Major', 'auditId': {'_id': 'y', 'title': 'Audit y'}, 'raisedByEmployeeId': emp('Bo'), 'auditeeEmployeeId': emp('Ravi')},
    };
    adapter.handler = (o) async {
      if (o.path == ApiConstants.ncsRepeats) {
        return json(200, {
          'isOk': true,
          'data': {'rows': groups, 'total': 1, 'page': 1, 'limit': 100},
        });
      }
      if (o.path == ApiConstants.ncsRepeatRows) {
        final ids = '${o.queryParameters['ids']}'.split(',');
        return json(200, {
          'isOk': true,
          'data': [for (final id in ids) byId[id]],
        });
      }
      return json(200, {'isOk': true, 'data': <Object>[]});
    };
    ncs.repeatsMinCount = 2;
    final request = buildFinalReportRequest(tab: FinalReportTab.repeats, audits: audits, ncs: ncs, options: options);
    final result = await FinalReportExportService().export(request);
    expect(result.rowCount, 1);
    expect(adapter.where('GET', ApiConstants.ncsRepeats).single.queryParameters['minCount'], 2);
    expect(adapter.where('GET', ApiConstants.ncsRepeatRows).single.queryParameters['ids'], 'b,a');

    final book = await sharedWorkbook();
    expect(book.tables.keys.toList(), ['Summary', 'Repeated Checkpoints', 'Repeat NC Details', 'By Location', 'By Auditor', 'By Auditee']);
    expect(book['Repeat NC Details'].maxRows, 4 + 2);
    // Oldest first, "Time #" 1 then 2.
    expect((book['Repeat NC Details'].cell(xl.CellIndex.indexByString('E5')).value as xl.TextCellValue).value.text, 'NC-a');
    expect((book['Repeat NC Details'].cell(xl.CellIndex.indexByString('C6')).value as xl.IntCellValue).value, 2);
  });

  test('Download All: the three tabs read one after the other and written as ONE workbook, read back from the shared file', () async {
    final auditRows = [
      for (var i = 0; i < 3; i++)
        {
          '_id': 'a$i', 'title': 'Audit $i', 'status': 'Completed', 'displayStatus': 'Total Closed', 'timeliness': 'On-Time Completed',
          'auditorIds': [emp('Asha')], 'auditeeIds': [emp('Ravi')],
          'locationIds': [{'_id': 'l1', 'name': 'Plant 1', 'code': 'P1'}],
          'scoreResult': {'achieved': 8, 'maxPossible': 10, 'percentage': 80},
        },
    ];
    final ncRows = [
      for (var i = 0; i < 4; i++)
        {
          '_id': 'n$i', 'ncId': 'NC-$i', 'title': 'Guard $i', 'severity': 'Major', 'status': 'Raised', 'bucket': 'overdue', 'placeLabel': 'Plant 1',
          'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Ravi'), 'startDate': '2026-09-01T00:00:00.000Z',
        },
    ];
    final groups = [
      {'key': 'k1', 'title': 'Wet floor', 'locationName': 'Plant 1', 'count': 2, 'openCount': 1, 'latestStatus': 'Raised', 'ncIds': ['r2', 'r1']},
    ];
    final order = <String>[];
    adapter.handler = (o) async {
      order.add(o.path);
      switch (o.path) {
        case ApiConstants.auditsReport:
          return json(200, {'isOk': true, 'data': reportListData(auditRows, o.queryParameters)});
        case ApiConstants.auditsReportStats:
          return json(200, {'isOk': true, 'data': {'percentage': 80, 'totalAudits': 3, 'onTimeCompleted': 3}});
        case ApiConstants.ncsReport:
          return json(200, {
            'isOk': true,
            'data': {'ncs': ncRows, 'total': ncRows.length, 'page': 1, 'limit': 100},
          });
        case ApiConstants.ncsReportStats:
          return json(200, {'isOk': true, 'data': {'total': 4, 'overdue': 4}});
        case ApiConstants.ncsRepeats:
          return json(200, {
            'isOk': true,
            'data': {'rows': groups, 'total': 1, 'page': 1, 'limit': 100},
          });
        case ApiConstants.ncsRepeatRows:
          return json(200, {
            'isOk': true,
            'data': [
              {'_id': 'r1', 'ncId': 'NC-r1', 'startDate': '2026-07-01', 'status': 'Closed', 'completionDate': '2026-07-09', 'auditId': {'_id': 'x', 'title': 'X'}, 'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Ravi')},
              {'_id': 'r2', 'ncId': 'NC-r2', 'startDate': '2026-09-01', 'status': 'Raised', 'auditId': {'_id': 'y', 'title': 'Y'}, 'raisedByEmployeeId': emp('Bo'), 'auditeeEmployeeId': emp('Ravi')},
            ],
          });
      }
      return json(200, {'isOk': true, 'data': <Object>[]});
    };
    audits
      ..setFilterState(isTeam: true, locations: ['l1'])
      ..reportsStatus = 'Completed';
    ncs
      ..setFilterState(isTeam: true, locations: ['l1'], flags: ['Major'])
      ..ncReportTileKeys = {'overdue'}
      ..repeatsMinCount = 2
      ..repeatsSearch = 'wet';

    final request = buildFinalReportAllRequest(audits: audits, ncs: ncs, options: options, generatedBy: 'Asha Rao');
    final progress = <ExportProgress>[];
    final result = await FinalReportExportService().exportAll(request, onProgress: progress.add);

    expect(result.rowCount, 3 + 4 + 1);
    expect(result.fileName, matches(RegExp(r'^Final-Report-All-\d{4}-\d{2}-\d{2}\.xlsx$')));
    // One part after the other.
    bool isAudits(String p) => p == ApiConstants.auditsReport || p == ApiConstants.auditsReportStats;
    bool isNcs(String p) => p == ApiConstants.ncsReport || p == ApiConstants.ncsReportStats;
    expect(order.lastIndexWhere(isAudits), lessThan(order.indexWhere(isNcs)));
    expect(order.lastIndexWhere(isNcs), lessThan(order.indexWhere((p) => !isAudits(p) && !isNcs(p))));
    expect({for (final p in progress) if (!p.building) p.part}.toList(), ['Audits', 'NCs', 'Repeated NCs']);
    // Each part asked under its own tab's filters, the search on the Repeated NCs request.
    expect(adapter.where('GET', ApiConstants.auditsReport).single.queryParameters['status'], 'Completed');
    expect(adapter.where('GET', ApiConstants.ncsReport).single.queryParameters['bucket'], 'overdue');
    final repeats = adapter.where('GET', ApiConstants.ncsRepeats).single;
    expect(repeats.uri.toString(), contains('search=wet'));
    expect(repeats.queryParameters['minCount'], 2);

    // The shared file reads back with the right sheets in the right order.
    final book = await sharedWorkbook();
    expect(book.tables.keys.toList(), [
      'Summary',
      'Audits', 'Audits By Location', 'Audits By Auditor', 'Audits By Auditee',
      'NCs', 'NCs By Location', 'NCs By Auditor', 'NCs By Auditee',
      'Repeated Checkpoints', 'Repeat NC Details', 'Repeats By Location', 'Repeats By Auditor', 'Repeats By Auditee',
    ]);
    expect(book['Audits'].maxRows, 4 + 3);
    expect(book['NCs'].maxRows, 4 + 4);
    expect(book['Repeat NC Details'].maxRows, 4 + 2);
    final texts = [
      for (final row in book['Summary'].rows)
        for (final cell in row)
          if (cell?.value is xl.TextCellValue) (cell!.value as xl.TextCellValue).value.text!,
    ];
    expect(texts, containsAll(['Repeated NCs · Search', '"wet"', 'Repeated NCs · Minimum repeats', 'NCs · Flag']));
    expect(texts.where((t) => t == 'Location'), hasLength(1));
  });

  test('a failed read leaves nothing to share, and says why', () async {
    adapter.handler = (o) async => json(403, {'isOk': false, 'message': 'You do not have access to the Final Report.'});
    final request = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options);
    await expectLater(
      FinalReportExportService().export(request),
      throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'You do not have access to the Final Report.')),
    );
    expect(shared, isEmpty);
    expect(Directory('${temp.path}${Platform.pathSeparator}final_report_exports').existsSync(), isFalse);
  });

  test('a phone with no signal: the page is retried, then a clear message — the screen is left as it was', () async {
    adapter.handler = (o) async => connectionError(o);
    final request = buildFinalReportRequest(tab: FinalReportTab.ncs, audits: audits, ncs: ncs, options: options);
    await expectLater(
      FinalReportExportService(retryDelays: const [Duration.zero, Duration.zero]).export(request),
      throwsA(isA<ReportExportException>().having((e) => e.message, 'message', 'Could not reach the server. Check your connection and try again.')),
    );
    // The first NC page was asked three times (try + two retries); the tiles three times as well.
    expect(adapter.where('GET', ApiConstants.ncsReport), hasLength(3));
    expect(shared, isEmpty);
  });

  test('cancelling while pages are being read shares nothing', () async {
    final rows = [for (var i = 0; i < 500; i++) {'_id': 'a$i', 'title': 'Audit $i', 'status': 'Completed', 'displayStatus': 'Total Closed'}];
    final token = ExportCancelToken();
    adapter.handler = (o) async {
      if (o.path == ApiConstants.auditsReport) return json(200, {'isOk': true, 'data': reportListData(rows, o.queryParameters)});
      return json(200, {'isOk': true, 'data': <String, dynamic>{}});
    };
    final request = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options);
    await expectLater(
      FinalReportExportService().export(request, cancel: token, onProgress: (p) {
        if (!p.building && p.done >= 100) token.cancel();
      }),
      throwsA(isA<ExportCancelled>()),
    );
    expect(shared, isEmpty);
    expect(adapter.where('GET', ApiConstants.auditsReport), hasLength(1));
  });
}
