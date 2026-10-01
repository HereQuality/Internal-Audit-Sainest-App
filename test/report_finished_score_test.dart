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

import 'support/session_fakes.dart';

/// The owner's 2026-09-30 Final Report rules on the phone: Total Audits leaves
/// out the Not Attempted ones, and every score — the Total Score tile, an audit
/// row, a batch row, a series row, a location header — is worked out from
/// COMPLETED audits only. An open, Not Attempted, Skipped or Draft audit shows
/// "—" (never 0, never 100); a batch with no finished zone shows "—", one with
/// some finished zones keeps the "*" meaning "finished zones only".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AuditModel audit(
    String id, {
    String status = 'Completed',
    String? display,
    String? timeliness,
    String? batch,
    String? batchDisplay,
    double? got = 5,
    double? of = 10,
  }) => AuditModel(
    id: id,
    title: id,
    scope: '',
    status: status,
    displayStatus: display,
    timeliness: timeliness,
    scheduleBatchId: batch,
    batchDisplayStatus: batchDisplay,
    scoreAchieved: got,
    scoreMax: of,
  );

  group('finishedScoreOf', () {
    test('sums achieved / possible over the Completed audits only', () {
      final s = finishedScoreOf([
        audit('a', got: 8, of: 10),
        audit('b', got: 1, of: 90),
        // Open work has a "so far" score that must not count.
        audit('open', status: 'In Progress', got: 10, of: 10),
        audit('skipped', status: 'Skipped', got: 10, of: 10),
        audit('draft', status: 'Draft', got: 10, of: 10),
      ]);
      expect(s.achieved, 9);
      expect(s.maxPossible, 100);
      // Σ / Σ, not the 50% an average of 80% and 1% would give.
      expect(s.percentage, 9);
    });

    test('nothing finished has no score at all (never 0, never 100)', () {
      expect(
        finishedScoreOf([
          audit('open', status: 'In Progress', got: 10, of: 10),
          audit('na', status: 'Scheduled', display: 'Not Attempted', got: 0, of: 10),
        ]).percentage,
        isNull,
      );
      expect(finishedScoreOf(const []).percentage, isNull);
      // A finished audit with no score recorded is not a 0% either.
      expect(finishedScoreOf([audit('a', got: null, of: null)]).percentage, isNull);
    });
  });

  group('ReportStats.fromAudits (the on-device fallback)', () {
    test('Total Audits leaves out the Not Attempted ones', () {
      final s = ReportStats.fromAudits([
        audit('done', timeliness: 'On-Time Completed'),
        audit('running', status: 'In Progress', display: 'In Progress'),
        audit('never', status: 'Scheduled', display: 'Not Attempted'),
        // A bundle whose one aggregate status is Not Attempted is not counted either.
        audit('b1', status: 'Scheduled', batch: 'b', batchDisplay: 'Not Attempted'),
        audit('b2', status: 'Scheduled', batch: 'b', batchDisplay: 'Not Attempted'),
        // Skipped still counts, as on the server.
        audit('skipped', status: 'Skipped', display: 'Skipped'),
      ]);
      expect(s.totalAudits, 3, reason: 'done + running + skipped');
      expect(s.completed, 1);
      expect(s.inProgress, 1);
    });

    test('the score is worked out from Completed audits only and is never partial', () {
      final s = ReportStats.fromAudits([
        audit('a', got: 8, of: 10, timeliness: 'On-Time Completed'),
        audit('b', got: 6, of: 10, timeliness: 'Delayed Completed'),
        // High "so far" scores on open work must not lift the total.
        audit('open', status: 'In Progress', display: 'In Progress', got: 10, of: 10),
        audit('overdue', status: 'In Progress', display: 'Overdue', got: 10, of: 10),
        audit('na', status: 'Scheduled', display: 'Not Attempted', got: 10, of: 10),
        audit('skipped', status: 'Skipped', got: 10, of: 10),
      ]);
      expect(s.achieved, 14);
      expect(s.maxPossible, 20);
      expect(s.percentage, 70);
      expect(s.isPartial, isFalse);
    });

    test('a bundle contributes only once EVERY zone is Completed', () {
      final s = ReportStats.fromAudits([
        audit('z1', got: 8, of: 10, batch: 'b', timeliness: 'On-Time Completed'),
        audit('z2', status: 'In Progress', display: 'In Progress', got: 10, of: 10, batch: 'b'),
        audit('solo', got: 5, of: 10, timeliness: 'On-Time Completed'),
      ]);
      // The half-done bundle adds nothing: just the finished 'solo'.
      expect(s.percentage, 50);
      expect(s.completed, 1);
    });

    test('nothing finished: no percentage at all, so the tile reads "—"', () {
      final s = ReportStats.fromAudits([
        audit('open', status: 'In Progress', display: 'In Progress', got: 9, of: 10),
        audit('na', status: 'Scheduled', display: 'Not Attempted'),
      ]);
      expect(s.percentage, isNull);
      expect(s.maxPossible, 0);
      expect(s.isPartial, isFalse);
      expect(s.totalAudits, 1);
    });
  });

  group('Reports screen', () {
    late FakeAdapter adapter;
    List<Map<String, dynamic>> rows = [];
    Object? stats;

    Map<String, dynamic> row(
      String id, {
      String? title,
      String status = 'Completed',
      String? display,
      String? batchDisplay,
      String? batch,
      String? series,
      String? location,
      double got = 8,
      double of = 10,
    }) => {
      '_id': id,
      'title': title ?? id,
      'scope': '',
      'status': status,
      'displayStatus': display ?? (status == 'Completed' ? 'Total Closed' : 'In Progress'),
      if (status == 'Completed') 'timeliness': 'On-Time Completed',
      if (batch != null) 'scheduleBatchId': batch,
      if (batchDisplay != null) 'batchDisplayStatus': batchDisplay,
      if (series != null) 'recurrence': {'seriesId': series, 'frequency': 'Weekly', 'occurrenceCount': 3},
      'scheduledDate': DateTime.now().toUtc().toIso8601String(),
      'completedDate': DateTime.now().toUtc().toIso8601String(),
      'auditorIds': [
        {'_id': 'u1', 'employeeName': 'Asha'},
      ],
      'scoreResult': {'achieved': got, 'maxPossible': of, 'percentage': (got / of * 100).round()},
      'locationIds': [
        if (location != null) {'_id': location, 'name': location},
      ],
    };

    Map<String, dynamic> serverStats({
      int? percentage,
      double achieved = 0,
      double max = 0,
      int totalAudits = 0,
      int completed = 0,
    }) => {
      'percentage': percentage,
      'achieved': achieved,
      'maxPossible': max,
      'isPartial': false,
      'totalAudits': totalAudits,
      'total': completed,
      'completed': completed,
      'inProgress': 0,
      'onTimeCompleted': completed,
      'delayedCompleted': 0,
      'completedIds': <String>[],
      'inProgressIds': <String>[],
      'onTimeIds': <String>[],
      'delayedIds': <String>[],
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
        .widget<Text>(
          find
              .descendant(
                of: find.byKey(ValueKey('report-tile-$id')),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;

    testWidgets('nothing finished: the Total Score tile reads "—", and open / skipped rows show "—" too (never 0 or 100)', (tester) async {
      rows = [
        row('Running audit', status: 'In Progress', got: 6, of: 10),
        row('Skipped audit', status: 'Skipped', display: 'Skipped', got: 5, of: 10),
      ];
      stats = serverStats(totalAudits: 2);
      await pump(tester);

      expect(tile(tester, 'score'), '—');
      expect(tile(tester, 'total'), '2');
      // Tile + the two rows; none shows a number.
      expect(find.text('—'), findsNWidgets(3));
      expect(find.text('60%'), findsNothing);
      expect(find.text('50%'), findsNothing);
      expect(find.text('0%'), findsNothing);
      expect(find.text('100%'), findsNothing);
      expect(find.textContaining('*'), findsNothing);
    });

    testWidgets('a finished audit shows its own score; the tile is the server\'s, never starred', (tester) async {
      rows = [row('Done audit', got: 8, of: 10), row('Open audit', status: 'In Progress', got: 10, of: 10)];
      stats = serverStats(percentage: 80, achieved: 8, max: 10, totalAudits: 2, completed: 1);
      await pump(tester);

      expect(tile(tester, 'score'), '80%');
      expect(find.text('80%'), findsNWidgets(2), reason: 'the tile and the finished row');
      expect(find.text('100%'), findsNothing, reason: 'the open audit has no score yet');
      expect(find.textContaining('*'), findsNothing);
      expect(find.textContaining('Includes audits still in progress'), findsNothing);
    });

    testWidgets('no stats answer: Total Audits skips Not Attempted and the score counts Completed audits only', (tester) async {
      rows = [
        row('Done audit', got: 8, of: 10),
        row('Running audit', status: 'In Progress', got: 10, of: 10),
        row('Never done', status: 'Scheduled', display: 'Not Attempted', got: 0, of: 10),
      ];
      stats = null; // 403: the tiles are worked out from the rows
      await pump(tester);

      expect(tile(tester, 'total'), '2', reason: 'the Not Attempted audit is left out');
      expect(tile(tester, 'score'), '80%');
    });

    testWidgets('a batch: no finished zone shows "—"; some finished zones keep the "*"; all finished is plain', (tester) async {
      rows = [
        // Nothing finished: "—" however far along the zones are.
        row('open1', title: 'Open batch', status: 'In Progress', batch: 'open', batchDisplay: 'In Progress', got: 9, of: 10),
        row('open2', title: 'Open batch', status: 'In Progress', batch: 'open', batchDisplay: 'In Progress', got: 9, of: 10),
        // Half finished: the finished zone's 8/10 only (not 8+9+0 over 30).
        row('half1', title: 'Half batch', batch: 'half', batchDisplay: 'In Progress', got: 8, of: 10),
        row('half2', title: 'Half batch', status: 'In Progress', batch: 'half', batchDisplay: 'In Progress', got: 9, of: 10),
        row('half3', title: 'Half batch', status: 'Scheduled', display: 'Not Attempted', batch: 'half', batchDisplay: 'In Progress', got: 0, of: 10),
        // All finished: a plain, final score.
        row('done1', title: 'Done batch', batch: 'done', batchDisplay: 'Total Closed', got: 6, of: 10),
        row('done2', title: 'Done batch', batch: 'done', batchDisplay: 'Total Closed', got: 8, of: 10),
      ];
      stats = null;
      await pump(tester);

      expect(find.text('80%*'), findsOneWidget, reason: 'the half-finished batch: finished zone only, starred');
      // 14 / 20 on the finished batch's own row AND on the tile (the only group that is finished).
      expect(find.text('70%'), findsNWidgets(2));
      expect(find.text('90%'), findsNothing);
      expect(find.text('90%*'), findsNothing);
      expect(find.text('57%*'), findsNothing, reason: 'never the open zones\' progress folded in');
      // The all-open batch reads "—", however far along its zones are.
      expect(find.text('—'), findsWidgets);
      expect(find.text('100%'), findsNothing);
    });

    testWidgets('a series row scores its Completed occurrences only; none finished shows "—"', (tester) async {
      rows = [
        row('a1', title: 'Weekly A', series: 'sa', got: 6, of: 10),
        row('a2', title: 'Weekly A', status: 'In Progress', series: 'sa', got: 10, of: 10),
        row('a3', title: 'Weekly A', status: 'In Progress', series: 'sa', got: 10, of: 10),
        row('b1', title: 'Weekly B', status: 'In Progress', series: 'sb', got: 10, of: 10),
        row('b2', title: 'Weekly B', status: 'In Progress', series: 'sb', got: 10, of: 10),
        // A finished one-off, so the tile (16 / 20) is not the same number as the series row.
        row('Solo audit', got: 10, of: 10),
      ];
      stats = null;
      await pump(tester);

      expect(tile(tester, 'score'), '80%');
      // Series A: its one finished occurrence (60%), never the 10/10s of the open ones
      // folded in (which would read 87%).
      expect(find.text('60%'), findsOneWidget);
      expect(find.text('87%'), findsNothing);
      // Series B: nothing finished, so "—".
      expect(find.text('—'), findsWidgets);
      expect(find.textContaining('*'), findsNothing);
    });

    testWidgets('location headers score their Completed audits only; none finished draws no score', (tester) async {
      rows = [
        row('Done A', location: 'Plant A', got: 8, of: 10),
        row('Open A', status: 'In Progress', location: 'Plant A', got: 10, of: 10),
        row('Open B', status: 'In Progress', location: 'Plant B', got: 10, of: 10),
      ];
      stats = null; // no server breakdown: the phone groups the rows itself
      await pump(tester);

      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();
      expect(find.text('2 reports · 80%'), findsOneWidget, reason: 'Plant A counts both, scores the finished one');
      expect(find.text('1 report'), findsOneWidget, reason: 'Plant B: nothing finished, no score');
      expect(find.textContaining('100%'), findsNothing);
      expect(find.text('0%'), findsNothing);
    });

    testWidgets('a server location header with no finished audit draws no score (the breakdown is finished-only)', (tester) async {
      rows = [row('Open A', status: 'In Progress', location: 'Plant A', got: 10, of: 10)];
      stats = {
        ...serverStats(totalAudits: 1),
        'byLocation': [
          {'key': 'Plant A', 'label': 'Plant A', 'count': 1, 'percentage': null, 'achieved': 0, 'maxPossible': 0, 'auditIds': ['Open A']},
        ],
      };
      await pump(tester);
      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();
      // The list's own count line and the place header both read "1 report"; the header carries no score
      // ("1 report", not "1 report · 0%").
      expect(find.text('1 report'), findsNWidgets(2));
      expect(find.textContaining('1 report ·'), findsNothing);
    });
  });
}
