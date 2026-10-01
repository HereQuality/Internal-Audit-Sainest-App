import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/report_stats.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/profile/reports_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/report_list_fake.dart';
import 'support/session_fakes.dart';

/// The Final Report tiles must add up (owner, 2026-09-30, "total 9 kaise
/// hai..."): Total Audits = In Progress + Overdue + Not Started + On-Time +
/// Delayed + Skipped + Other, with Not Attempted counted apart (NOT in the
/// Total). The server sends every bucket's count and ids; the on-device
/// fallback works out the same buckets.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AuditModel audit(
    String id, {
    String status = 'Completed',
    String? display,
    String? timeliness,
    String? batch,
    String? batchDisplay,
  }) => AuditModel(
    id: id,
    title: id,
    scope: '',
    status: status,
    displayStatus: display,
    timeliness: timeliness,
    scheduleBatchId: batch,
    batchDisplayStatus: batchDisplay,
    scoreAchieved: 5,
    scoreMax: 10,
  );

  group('ReportStats.tryParse', () {
    test('reads the rest-of-the-total buckets, their ids and Not Attempted apart', () {
      final s = ReportStats.tryParse({
        'totalAudits': 9,
        'total': 3,
        'completed': 3,
        'inProgress': 2,
        'overdue': 1,
        'notStarted': 1,
        'onTimeCompleted': 2,
        'delayedCompleted': 1,
        'skipped': 1,
        'other': 1,
        'notAttempted': 2,
        'inProgressIds': ['p1', 'p2'],
        'overdueIds': ['o1'],
        'notStartedIds': ['n1'],
        'onTimeIds': ['t1', 't2'],
        'delayedIds': ['d1'],
        'skippedIds': ['s1'],
        'otherIds': ['x1'],
        'notAttemptedIds': ['a1', 'a2'],
      })!;
      expect(s.overdue, 1);
      expect(s.notStarted, 1);
      expect(s.skipped, 1);
      expect(s.other, 1);
      expect(s.notAttempted, 2);
      // The tiles add up to the Total; Not Attempted is not part of it.
      expect(s.bucketsTotal, s.totalAudits);
      expect(s.idsFor('overdue'), ['o1']);
      expect(s.idsFor('notStarted'), ['n1']);
      expect(s.idsFor('skipped'), ['s1']);
      expect(s.idsFor('other'), ['x1']);
      expect(s.idsFor('notAttempted'), ['a1', 'a2']);
      // The keys that were already there keep working.
      expect(s.idsFor('inProgress'), ['p1', 'p2']);
      expect(s.idsFor('onTime'), ['t1', 't2']);
      expect(s.idsFor('delayed'), ['d1']);
      expect(s.idsFor('nonsense'), isEmpty);
    });

    test('an older server without the new fields parses with 0 and empty lists', () {
      final s = ReportStats.tryParse({
        'totalAudits': 3,
        'inProgress': 1,
        'onTimeCompleted': 1,
        'delayedCompleted': 1,
      })!;
      expect(s.overdue, 0);
      expect(s.notStarted, 0);
      expect(s.skipped, 0);
      expect(s.other, 0);
      expect(s.notAttempted, 0);
      for (final key in ['overdue', 'notStarted', 'skipped', 'other', 'notAttempted']) {
        expect(s.idsFor(key), isEmpty, reason: key);
      }
    });

    test('withByLocation keeps every bucket and its ids', () {
      final s = ReportStats.tryParse({
        'totalAudits': 4,
        'inProgress': 1,
        'overdue': 1,
        'notStarted': 1,
        'skipped': 1,
        'other': 0,
        'notAttempted': 1,
        'overdueIds': ['o1'],
        'notStartedIds': ['n1'],
        'skippedIds': ['s1'],
        'notAttemptedIds': ['a1'],
      })!;
      final moved = s.withByLocation(const [ReportLocationStats(key: 'A', label: 'A', count: 1)]);
      expect(moved.byLocation, hasLength(1));
      expect(moved.overdue, 1);
      expect(moved.notStarted, 1);
      expect(moved.skipped, 1);
      expect(moved.notAttempted, 1);
      expect(moved.idsFor('overdue'), ['o1']);
      expect(moved.idsFor('notStarted'), ['n1']);
      expect(moved.idsFor('skipped'), ['s1']);
      expect(moved.idsFor('notAttempted'), ['a1']);
    });
  });

  group('ReportStats.fromAudits buckets', () {
    test('every group lands in exactly one bucket; they add up to Total Audits, Not Attempted apart', () {
      final s = ReportStats.fromAudits([
        audit('done1', timeliness: 'On-Time Completed'),
        audit('done2', timeliness: 'Delayed Completed'),
        audit('run', status: 'In Progress', display: 'In Progress'),
        audit('late', status: 'In Progress', display: 'Overdue'),
        // A bundle counts once, by its one aggregate status.
        audit('l1', status: 'In Progress', display: 'Overdue', batch: 'l', batchDisplay: 'Overdue'),
        audit('l2', status: 'In Progress', display: 'Overdue', batch: 'l', batchDisplay: 'Overdue'),
        audit('fresh', status: 'Not Started', display: 'Not Started'),
        audit('skip', status: 'Skipped', display: 'Skipped'),
        // Neither a pipeline status nor finished: the catch-all bucket.
        audit('draft', status: 'Draft', display: 'Draft'),
        // Not Attempted, on its own and as a bundle: counted apart.
        audit('never', status: 'Scheduled', display: 'Not Attempted'),
        audit('na1', status: 'Scheduled', display: 'Not Attempted', batch: 'n', batchDisplay: 'Not Attempted'),
        audit('na2', status: 'Scheduled', display: 'Not Attempted', batch: 'n', batchDisplay: 'Not Attempted'),
      ]);
      expect(s.onTimeCompleted, 1);
      expect(s.delayedCompleted, 1);
      expect(s.inProgress, 1);
      expect(s.overdue, 2, reason: 'the lone one and the bundle');
      expect(s.notStarted, 1);
      expect(s.skipped, 1);
      expect(s.other, 1);
      expect(s.notAttempted, 2, reason: 'the lone one and the bundle');
      expect(s.totalAudits, 8);
      expect(
        s.inProgress + s.overdue + s.notStarted + s.onTimeCompleted + s.delayedCompleted + s.skipped + s.other,
        s.totalAudits,
      );
      expect(s.bucketsTotal, s.totalAudits);
      // Completed is still On-Time + Delayed.
      expect(s.completed, s.onTimeCompleted + s.delayedCompleted);
    });

    test('idsFor lists every member of each bucket\'s audits, a bundle\'s zones included', () {
      final s = ReportStats.fromAudits([
        audit('run', status: 'In Progress', display: 'In Progress'),
        audit('late', status: 'In Progress', display: 'Overdue'),
        audit('l1', status: 'In Progress', display: 'Overdue', batch: 'l', batchDisplay: 'Overdue'),
        audit('l2', status: 'In Progress', display: 'Overdue', batch: 'l', batchDisplay: 'Overdue'),
        audit('fresh', status: 'Not Started', display: 'Not Started'),
        audit('skip', status: 'Skipped', display: 'Skipped'),
        audit('draft', status: 'Draft', display: 'Draft'),
        audit('never', status: 'Scheduled', display: 'Not Attempted'),
      ]);
      expect(s.idsFor('inProgress'), ['run']);
      expect(s.idsFor('overdue'), unorderedEquals(['late', 'l1', 'l2']));
      expect(s.idsFor('notStarted'), ['fresh']);
      expect(s.idsFor('skipped'), ['skip']);
      expect(s.idsFor('other'), ['draft']);
      expect(s.idsFor('notAttempted'), ['never']);
      expect(s.idsFor('onTime'), isEmpty);
      expect(s.idsFor('delayed'), isEmpty);
    });

    test('a finished audit with no timeliness is still ONE audit in the Total (other), so the sum holds', () {
      final s = ReportStats.fromAudits([
        audit('done'),
        audit('run', status: 'In Progress', display: 'In Progress'),
      ]);
      expect(s.completed, 1);
      expect(s.onTimeCompleted + s.delayedCompleted, 0);
      expect(s.other, 1);
      expect(s.idsFor('other'), ['done']);
      expect(s.totalAudits, 2);
      expect(s.bucketsTotal, s.totalAudits);
    });

    test('nothing but Not Attempted: an empty Total, the audits counted apart', () {
      final s = ReportStats.fromAudits([
        audit('never1', status: 'Scheduled', display: 'Not Attempted'),
        audit('never2', status: 'Scheduled', display: 'Not Attempted'),
      ]);
      expect(s.totalAudits, 0);
      expect(s.bucketsTotal, 0);
      expect(s.notAttempted, 2);
      expect(s.idsFor('notAttempted'), unorderedEquals(['never1', 'never2']));
    });
  });

  group('Reports screen tiles', () {
    late FakeAdapter adapter;
    List<Map<String, dynamic>> rows = [];
    Object? stats;

    Map<String, dynamic> row(String id, String title, {required String status, required String display}) => {
      '_id': id,
      'title': title,
      'scope': '',
      'status': status,
      'displayStatus': display,
      if (status == 'Completed') 'timeliness': 'On-Time Completed',
      'scheduledDate': DateTime.now().toUtc().toIso8601String(),
      'auditorIds': [
        {'_id': 'u1', 'employeeName': 'Asha'},
      ],
      'scoreResult': {'achieved': 5, 'maxPossible': 10, 'percentage': 50},
      'locationIds': [],
    };

    // Six audits: five in the Total (one per bucket) and one Not Attempted.
    List<Map<String, dynamic>> sixRows() => [
      row('run', 'Running audit', status: 'In Progress', display: 'In Progress'),
      row('over', 'Overdue audit', status: 'In Progress', display: 'Overdue'),
      row('fresh', 'Fresh audit', status: 'Not Started', display: 'Not Started'),
      row('done', 'Done audit', status: 'Completed', display: 'Total Closed'),
      row('skip', 'Skipped audit', status: 'Skipped', display: 'Skipped'),
      row('never', 'Never done', status: 'Scheduled', display: 'Not Attempted'),
    ];

    Map<String, dynamic> serverStatsForSix() => {
      'percentage': 50,
      'achieved': 5,
      'maxPossible': 10,
      'isPartial': false,
      'totalAudits': 5,
      'total': 1,
      'completed': 1,
      'inProgress': 1,
      'overdue': 1,
      'notStarted': 1,
      'onTimeCompleted': 1,
      'delayedCompleted': 0,
      'skipped': 1,
      'other': 0,
      'notAttempted': 1,
      'completedIds': ['done'],
      'inProgressIds': ['run'],
      'overdueIds': ['over'],
      'notStartedIds': ['fresh'],
      'onTimeIds': ['done'],
      'delayedIds': <String>[],
      'skippedIds': ['skip'],
      'otherIds': <String>[],
      'notAttemptedIds': ['never'],
      'byLocation': [],
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
              // The server filters by `status` and pages over groups.
              return json(200, {'isOk': true, 'data': reportListData(rows, o.queryParameters)});
            case ApiConstants.auditsReportStats:
              return stats == null ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': stats});
          }
          return json(200, {'isOk': true, 'data': []});
        };
      DioClient.instance.dio.httpClientAdapter = adapter;
      SocketService.debugInstance = FakeSockets().service;
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 2600);
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

    Finder tileKey(String id) => find.byKey(ValueKey('report-tile-$id'));

    String value(WidgetTester tester, String id) => tester
        .widget<Text>(find.descendant(of: tileKey(id), matching: find.byType(Text)).first)
        .data!;

    void expectTilesAddUp(WidgetTester tester) {
      expect(value(tester, 'total'), '5');
      expect(value(tester, 'inProgress'), '1');
      expect(value(tester, 'overdue'), '1');
      expect(value(tester, 'notStarted'), '1');
      expect(value(tester, 'onTime'), '1');
      expect(value(tester, 'delayed'), '0');
      expect(value(tester, 'skipped'), '1');
      expect(value(tester, 'notAttempted'), '1');
      expect(
        find.descendant(of: tileKey('notAttempted'), matching: find.text('Not Attempted (not in Total)')),
        findsOneWidget,
      );
      // 1 + 1 + 1 + 1 + 0 + 1 = 5, and the Not Attempted one is outside it.
      final sum = ['inProgress', 'overdue', 'notStarted', 'onTime', 'delayed', 'skipped']
          .map((k) => int.parse(value(tester, k)))
          .reduce((a, b) => a + b);
      expect(sum, int.parse(value(tester, 'total')));
    }

    testWidgets('the server\'s buckets are tiles that add up to Total Audits, Not Attempted labelled apart', (tester) async {
      rows = sixRows();
      stats = serverStatsForSix();
      await pump(tester);
      expectTilesAddUp(tester);
    });

    testWidgets('with no stats answer the same tiles are worked out from the rows', (tester) async {
      rows = sixRows();
      stats = null; // 403: the tiles are worked out from the rows
      await pump(tester);
      expectTilesAddUp(tester);
    });

    testWidgets('Overdue is always shown; Not Started, Skipped and Not Attempted only when there is one', (tester) async {
      rows = [row('done', 'Done audit', status: 'Completed', display: 'Total Closed')];
      stats = null;
      await pump(tester);

      expect(value(tester, 'overdue'), '0');
      expect(tileKey('notStarted'), findsNothing);
      expect(tileKey('skipped'), findsNothing);
      expect(tileKey('notAttempted'), findsNothing);
      expect(find.text('Not Attempted (not in Total)'), findsNothing);
    });

    testWidgets('each new tile is a tap-filter by the `status` it counts; they OR together and Total Audits clears them', (tester) async {
      rows = sixRows();
      stats = serverStatsForSix();
      await pump(tester);
      for (final title in ['Running audit', 'Overdue audit', 'Fresh audit', 'Done audit', 'Skipped audit', 'Never done']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      // Was: the screen narrowed the loaded list by each tile's ids. Now the server does, by `status`.
      String? status() => adapter.requests
          .lastWhere((r) => r.path == ApiConstants.auditsReport)
          .queryParameters['status'] as String?;

      await tester.tap(tileKey('overdue'));
      await tester.pumpAndSettle();
      expect(status(), 'Overdue');
      expect(find.text('Overdue audit'), findsOneWidget);
      expect(find.text('Running audit'), findsNothing);
      expect(find.text('Fresh audit'), findsNothing);
      expect(find.text('Done audit'), findsNothing);
      expect(find.text('Skipped audit'), findsNothing);
      expect(find.text('Never done'), findsNothing);

      await tester.tap(tileKey('notStarted'));
      await tester.pumpAndSettle();
      expect(status(), 'Overdue,Not Started');
      expect(find.text('Overdue audit'), findsOneWidget, reason: 'picked tiles OR together');
      expect(find.text('Fresh audit'), findsOneWidget);
      expect(find.text('Skipped audit'), findsNothing);

      await tester.tap(tileKey('overdue'));
      await tester.pumpAndSettle();
      await tester.tap(tileKey('notStarted'));
      await tester.pumpAndSettle();
      await tester.tap(tileKey('skipped'));
      await tester.pumpAndSettle();
      // The Skipped tile asks for the Skipped audits themselves (the server lifts its default exclusion for it).
      expect(status(), 'Skipped');
      expect(find.text('Skipped audit'), findsOneWidget);
      expect(find.text('Overdue audit'), findsNothing);
      expect(find.text('Never done'), findsNothing);

      await tester.tap(tileKey('skipped'));
      await tester.pumpAndSettle();
      await tester.tap(tileKey('notAttempted'));
      await tester.pumpAndSettle();
      expect(status(), 'Not Attempted');
      expect(find.text('Never done'), findsOneWidget);
      expect(find.text('Skipped audit'), findsNothing);
      expect(find.text('Running audit'), findsNothing);

      await tester.tap(tileKey('total'));
      await tester.pumpAndSettle();
      expect(status(), isNull);
      for (final title in ['Running audit', 'Overdue audit', 'Fresh audit', 'Done audit', 'Skipped audit', 'Never done']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
    });
  });
}
