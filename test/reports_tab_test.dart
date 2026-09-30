import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/formatters.dart';
import 'package:internal_audit_app/core/utils/report_stats.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/models/nc_model.dart';
import 'package:internal_audit_app/models/nc_report_model.dart';
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/app_mode_provider.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/providers/notifications_provider.dart';
import 'package:internal_audit_app/screens/nc/nc_list_screen.dart';
import 'package:internal_audit_app/screens/nc/nc_review_screen.dart';
import 'package:internal_audit_app/screens/profile/profile_screen.dart';
import 'package:internal_audit_app/screens/profile/reports_screen.dart';
import 'package:internal_audit_app/screens/root/app_shell.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The Reports tab (Final Report): the ReportStats / NC tile models, the
/// providers' requests (the new /audits/report, /ncs/report, /ncs/repeats
/// endpoints and their stats), the three tabs on screen, both bottom bars, and
/// NC Monitoring's tiles. Every number shown here is one the fake server sent —
/// nothing is worked out on the device, which is what these tests hold it to.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Backend backend;
  late FakeAdapter adapter;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    backend = _Backend();
    adapter = FakeAdapter()..handler = backend.handle;
    DioClient.instance.dio.httpClientAdapter = adapter;
    SocketService.debugInstance = FakeSockets().service;
  });

  group('ReportStats', () {
    test('reads the new tiles, their id lists and the per-place breakdown', () {
      final s = ReportStats.tryParse({
        'percentage': 71.6,
        'achieved': 72,
        'maxPossible': 100,
        'isPartial': true,
        'totalAudits': 9,
        'total': 5,
        'completed': 5,
        'inProgress': 2,
        'onTimeCompleted': 3,
        'delayedCompleted': 2,
        'completedIds': ['a', 'b', 'c', 'd', 'e'],
        'inProgressIds': ['f', 'g'],
        'onTimeIds': ['a', 'b', 'c'],
        'delayedIds': ['d', 'e'],
        'byLocation': [
          {
            'key': 'Plant A',
            'label': 'Plant A',
            'count': 4,
            'achieved': 40,
            'maxPossible': 50,
            'percentage': 80,
            'locationIds': ['l1'],
            'departmentIds': [],
            'auditIds': ['a', 'f'],
          },
        ],
      })!;
      expect(s.percentage, 72);
      expect(s.isPartial, isTrue);
      expect(s.totalAudits, 9);
      expect(s.inProgress, 2);
      expect(s.completed, 5);
      expect(s.onTimeCompleted + s.delayedCompleted, s.completed);
      expect(s.idsFor('delayed'), ['d', 'e']);
      expect(s.idsFor('inProgress'), ['f', 'g']);
      expect(s.idsFor('nonsense'), isEmpty);
      final place = s.byLocation.single;
      expect(place.label, 'Plant A');
      expect(place.count, 4);
      expect(place.percentage, 80);
      expect(place.auditIds, ['a', 'f']);
    });

    test('an older answer without the new fields still parses (completed falls back to total)', () {
      final s = ReportStats.tryParse({'totalAudits': 3, 'total': 2, 'onTimeCompleted': 1, 'delayedCompleted': 1})!;
      expect(s.completed, 2);
      expect(s.inProgress, 0);
      expect(s.byLocation, isEmpty);
      expect(s.completedIds, isEmpty);
    });

    AuditModel audit(
      String id, {
      String status = 'Completed',
      String? display,
      String? timeliness,
      String? batch,
      String? batchDisplay,
      String? batchTimeliness,
    }) => AuditModel(
      id: id,
      title: id,
      scope: '',
      status: status,
      displayStatus: display,
      timeliness: timeliness,
      scheduleBatchId: batch,
      batchDisplayStatus: batchDisplay,
      batchTimeliness: batchTimeliness,
      scoreAchieved: 5,
      scoreMax: 10,
    );

    test('the on-device fallback keeps On-Time + Delayed = Completed and counts In Progress by display status', () {
      final s = ReportStats.fromAudits([
        audit('ontime', timeliness: 'On-Time Completed'),
        audit('late', timeliness: 'Delayed Completed'),
        // A finished bundle is ONE completed audit, Delayed if any zone was late.
        audit('z1', batch: 'b', timeliness: 'On-Time Completed', batchTimeliness: 'Delayed Completed'),
        audit('z2', batch: 'b', timeliness: 'Delayed Completed', batchTimeliness: 'Delayed Completed'),
        audit('running', status: 'In Progress', display: 'In Progress'),
        // In Progress by stored status but shown as Overdue: not "In Progress".
        audit('overdue', status: 'In Progress', display: 'Overdue'),
        // Unfinished bundle (one zone still open) is not Completed.
        audit('h1', batch: 'h', timeliness: 'On-Time Completed', batchDisplay: 'In Progress'),
        audit('h2', batch: 'h', status: 'In Progress', display: 'In Progress', batchDisplay: 'In Progress'),
      ]);
      expect(s.totalAudits, 6);
      expect(s.completed, 3);
      expect(s.onTimeCompleted, 1);
      expect(s.delayedCompleted, 2);
      expect(s.onTimeCompleted + s.delayedCompleted, s.completed);
      expect(s.inProgress, 2); // 'running' and the half-done bundle 'h'
      // A tile lists the ZONES in that state, not the whole bundle: z1 finished on time
      // and h1 is already done, so neither is under Delayed / In Progress.
      expect(s.delayedIds, unorderedEquals(['late', 'z2']));
      expect(s.inProgressIds, unorderedEquals(['running', 'h2']));
      expect(s.byLocation, isEmpty, reason: 'place numbers are the server\'s only');
    });
  });

  group('NcTileStats', () {
    test('reads the six tiles and the ids behind each', () {
      final s = NcTileStats.tryParse({
        'total': 12,
        'inProgress': 3,
        'overdue': 2,
        'pendingApproval': 1,
        'delayed': 2,
        'onTime': 4,
        'inProgressIds': ['a', 'b', 'c'],
        'overdueIds': ['d', 'e'],
        'pendingApprovalIds': ['f'],
        'delayedIds': ['g', 'h'],
        'onTimeIds': ['i', 'j', 'k', 'l'],
        'atsScore': 81.5,
        'byLocation': [
          {'key': 'Plant A', 'label': 'Plant A', 'total': 5, 'inProgress': 2, 'overdue': 1, 'pendingApproval': 0, 'delayed': 1, 'onTime': 1, 'ncIds': ['a', 'd']},
        ],
      })!;
      expect(s.hasBuckets, isTrue);
      expect(s.total, 12);
      expect(s.total, NcBucket.all.map(s.countFor).reduce((a, b) => a + b));
      expect(s.idsFor(NcBucket.delayed), ['g', 'h']);
      expect(s.atsScore, 81.5);
      expect(s.byLocation.single.total, 5);
      expect(s.byLocation.single.countFor(NcBucket.inProgress), 2);
    });

    test('an older /ncs/raised/stats answer (old four fields only) keeps parsing and says it has no buckets', () {
      final s = NcTileStats.tryParse({
        'total': 7,
        'awaitingApproval': 2,
        'overdue': 1,
        'closed': 3,
        'statusCounts': {'Raised': 2, 'Response Submitted': 1, 'Verification': 1, 'Closed': 3},
      })!;
      expect(s.hasBuckets, isFalse);
      expect(s.awaitingApproval, 2);
      expect(s.closed, 3);
      expect(s.overdue, 1);
    });
  });

  group('AuditsProvider: the Final Report list and stats', () {
    test('Me is the default, All Members sends nothing, a Location narrows — and nothing old is called', () async {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      await p.fetchReportAudits();
      expect(adapter.requests.last.path, ApiConstants.auditsReport);
      expect(adapter.requests.last.queryParameters['employeeIds'], 'me');
      expect(adapter.requests.last.queryParameters['limit'], 100);

      p.setFilterState(isTeam: true, locations: ['zoneA'], departments: ['qa'], auditTypes: ['Safety']);
      await p.fetchReportAudits();
      final q = adapter.requests.last.queryParameters;
      expect(q.containsKey('employeeIds'), isFalse, reason: 'All Members = no employeeIds');
      expect(q['locationIds'], 'zoneA');
      expect(q['departmentIds'], 'qa');
      expect(q['auditType'], 'Safety');

      expect(adapter.requests.where((r) => r.path == '/audits/mine'), isEmpty);
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsAtPlacesILead), isEmpty);
    });

    test('pages over GROUPS: the last page comes from `total`, not from how many rows arrived', () async {
      // 120 groups; the first page holds a bundle whose zones push it to 103 rows.
      Map<String, dynamic> row(int i) => {'_id': 'r$i', 'title': 'T$i', 'scope': '', 'status': 'Completed'};
      adapter.handler = (o) async {
        if (o.path != ApiConstants.auditsReport) return json(200, {'isOk': true, 'data': []});
        final page = o.queryParameters['page'] as int;
        final rows = page == 1 ? [for (var i = 0; i < 103; i++) row(i)] : [for (var i = 103; i < 123; i++) row(i)];
        return json(200, {'isOk': true, 'data': {'audits': rows, 'total': 120, 'page': page, 'limit': 100}});
      };
      final p = AuditsProvider();
      await p.fetchReportAudits();
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsReport), hasLength(2));
      expect(p.reportAudits, hasLength(123));
      expect(p.reportsError, isNull);
    });

    test('a filter change refetches the list and tiles only while the tab is showing; otherwise it is marked stale', () async {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      await p.applyFilters(locations: ['l1']);
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsReport), isEmpty);
      expect(p.reportsStale, isTrue);

      p.reportsInUse = true;
      await p.applyFilters(locations: ['l2']);
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsReport), hasLength(1));
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsReportStats), hasLength(1));
      expect(p.reportsStale, isFalse, reason: 'a loaded list is no longer stale');
    });

    test('the stats carry the chip and the search; with a tile AND location-wise the place rows are asked again over the tile\'s ids', () async {
      backend.auditStats = {
        'totalAudits': 4,
        'completed': 2,
        'onTimeCompleted': 1,
        'delayedCompleted': 1,
        'delayedIds': ['d1', 'd2'],
        'onTimeIds': ['o1'],
        'completedIds': ['d1', 'd2', 'o1'],
        'byLocation': [
          {'key': 'Plant A', 'label': 'Plant A', 'count': 4, 'percentage': 50, 'auditIds': ['d1', 'o1', 'x']},
        ],
      };
      final p = AuditsProvider()
        ..reportsStatus = 'Completed'
        ..reportsSearch = ' hygiene ';
      await p.fetchReportStats();
      expect(adapter.requests.last.queryParameters['status'], 'Completed');
      expect(adapter.requests.last.queryParameters['search'], 'hygiene');
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsReportStats), hasLength(1));

      p
        ..reportsTileKeys = {'delayed', 'onTime'}
        ..reportsByLocation = true;
      await p.fetchReportStats();
      final stats = adapter.requests.where((r) => r.path == ApiConstants.auditsReportStats).toList();
      expect(stats, hasLength(3));
      expect(stats.last.queryParameters['onlyIds'], 'd1,d2,o1');
      expect(p.reportStats!.totalAudits, 4, reason: 'tiles keep the whole set');
    });

    test('an unreadable stats answer (403) leaves the tiles to be worked out from the rows', () async {
      backend.auditStats = null;
      final p = AuditsProvider();
      await p.fetchReportStats();
      expect(p.reportStats, isNull);
      expect(p.isLoadingReportStats, isFalse);
    });
  });

  group('NcProvider: Final Report NCs, Repeated NCs and NC Monitoring tiles', () {
    test('the report request carries every shared filter, the flag and the search', () async {
      final p = NcProvider()..setSelfEmployeeId('me');
      p.setFilterState(
        isTeam: true,
        employees: ['e1', 'e2'],
        locations: ['l1'],
        departments: ['d1'],
        auditTypes: ['Safety'],
        flags: ['Major'],
        dateRange: (DateTime(2026, 1, 5), DateTime(2026, 2, 6)),
      );
      p.ncReportSearch = ' guard ';
      await p.fetchNcReport();
      final q = adapter.requests.firstWhere((r) => r.path == ApiConstants.ncsReport).queryParameters;
      expect(q['employeeIds'], 'e1,e2');
      expect(q['locationIds'], 'l1');
      expect(q['departmentIds'], 'd1');
      expect(q['auditType'], 'Safety');
      expect(q['severity'], 'Major');
      expect(q['fromDate'], '2026-01-05');
      expect(q['toDate'], '2026-02-06');
      expect(q['search'], 'guard');
      expect(q['limit'], 100);

      await p.fetchNcReportStats();
      final s = adapter.requests.firstWhere((r) => r.path == ApiConstants.ncsReportStats).queryParameters;
      expect(s['employeeIds'], 'e1,e2');
      expect(s['severity'], 'Major');
    });

    test('Me sends the caller\'s own id, All Members sends none', () async {
      final p = NcProvider()..setSelfEmployeeId('me');
      await p.fetchNcReport();
      expect(adapter.requests.last.queryParameters['employeeIds'], 'me');
      p.setFilterState(isTeam: true);
      await p.fetchNcReport();
      expect(adapter.requests.last.queryParameters.containsKey('employeeIds'), isFalse);
    });

    test('Repeated NCs: org-wide (no people), minCount, and the last six months unless a date is picked', () async {
      final p = NcProvider()..setSelfEmployeeId('me');
      p.setFilterState(employees: ['e1'], teams: ['t1'], teamMembers: ['e1'], locations: ['l1'], flags: ['Minor']);
      p.repeatsMinCount = 3;
      expect(p.repeatsUseDefaultWindow, isTrue);
      await p.fetchRepeats();
      final q = adapter.requests.firstWhere((r) => r.path == ApiConstants.ncsRepeats).queryParameters;
      expect(q.containsKey('employeeIds'), isFalse);
      expect(q['minCount'], 3);
      expect(q['locationIds'], 'l1');
      expect(q['severity'], 'Minor');
      final from = DateTime.parse(q['fromDate'] as String);
      final sixMonthsAgo = NcProvider.repeatDefaultFrom();
      expect(from.year, sixMonthsAgo.year);
      expect(from.month, sixMonthsAgo.month);
      expect(q.containsKey('toDate'), isFalse);

      p.setFilterState(dateRange: (DateTime(2026, 3, 1), null));
      expect(p.repeatsUseDefaultWindow, isFalse);
      await p.fetchRepeats();
      final picked = adapter.requests.lastWhere((r) => r.path == ApiConstants.ncsRepeats).queryParameters;
      expect(picked['fromDate'], '2026-03-01');
    });

    test('a filter change refetches all three NC lists while the tab shows, else marks it stale', () async {
      final p = NcProvider()..setSelfEmployeeId('me');
      await p.applyFilters(locations: ['l1']);
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsReport), isEmpty);
      expect(p.ncReportsStale, isTrue);
      // NC Monitoring's own list and tiles do follow every filter change.
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsRaised), hasLength(1));
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsRaisedStats), hasLength(1));

      adapter.requests.clear();
      p.ncReportsInUse = true;
      await p.applyFilters(locations: ['l2']);
      for (final path in [ApiConstants.ncsReport, ApiConstants.ncsReportStats, ApiConstants.ncsRepeats]) {
        expect(adapter.requests.where((r) => r.path == path), hasLength(1), reason: path);
      }
    });

    test('NC Monitoring\'s list AND tiles send Team/Members, Location/Department, Audit Type, Flag and Date', () async {
      final p = NcProvider()..setSelfEmployeeId('me');
      p.setFilterState(
        employees: ['e1'],
        locations: ['l1'],
        departments: ['d1'],
        auditTypes: ['Safety', 'Quality'],
        flags: ['Major'],
        dateRange: (DateTime(2026, 4, 1), DateTime(2026, 4, 30)),
      );
      await Future.wait([p.fetchRaisedByMe(), p.fetchRaisedStats()]);
      for (final path in [ApiConstants.ncsRaised, ApiConstants.ncsRaisedStats]) {
        final q = adapter.requests.firstWhere((r) => r.path == path).queryParameters;
        expect(q['employeeIds'], 'e1', reason: path);
        expect(q['locationIds'], 'l1', reason: path);
        expect(q['departmentIds'], 'd1', reason: path);
        expect(q['auditType'], 'Safety,Quality', reason: path);
        expect(q['severity'], 'Major', reason: path);
        expect(q['fromDate'], '2026-04-01', reason: path);
        expect(q['toDate'], '2026-04-30', reason: path);
      }
    });

    test('logout empties the report lists and the tab flags', () async {
      backend.ncs = [_nc('1')];
      final p = NcProvider()..setSelfEmployeeId('me');
      p.ncReportsInUse = true;
      await p.fetchNcReport();
      expect(p.reportNcs, hasLength(1));
      p.resetForLogout();
      expect(p.reportNcs, isEmpty);
      expect(p.ncReportsInUse, isFalse);
      expect(p.repeatsMinCount, 2);
    });
  });

  group('Reports screen', () {
    testWidgets('three tabs share ONE filter bar, and the Audits tab shows the six tiles with the server\'s numbers', (tester) async {
      backend
        ..audits = [_audit('1', title: 'Weekly hygiene', location: 'Plant A'), _audit('2', title: 'One-off', location: 'Plant B')]
        // The tiles are the server's only while they agree with the rows listed.
        ..auditStats = _auditStats(totalAudits: 2);
      await _pumpReports(tester);

      expect(find.descendant(of: find.byType(TabBar), matching: find.text('Audits')), findsOneWidget);
      expect(find.descendant(of: find.byType(TabBar), matching: find.text('NCs')), findsOneWidget);
      expect(find.descendant(of: find.byType(TabBar), matching: find.text('Repeated NCs')), findsOneWidget);
      expect(find.text('Filters'), findsOneWidget, reason: 'one shared filter bar');

      for (final label in ['Total Score', 'Total Audits', 'In Progress', 'On-Time Completed', 'Delayed Completed']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      // The tiles, every value the server's.
      String valueOf(String id) => tester
          .widget<Text>(find.descendant(of: find.byKey(ValueKey('report-tile-$id')), matching: find.byType(Text)).first)
          .data!;
      // The Total Score is from Completed audits only (owner, 2026-09-30): never starred.
      expect(valueOf('score'), '72%');
      expect(valueOf('total'), '2');
      expect(valueOf('inProgress'), '2');
      // No separate Completed tile any more: On-Time + Delayed are the completed ones.
      expect(find.byKey(const ValueKey('report-tile-completed')), findsNothing);
      expect(valueOf('onTime'), '3');
      expect(valueOf('delayed'), '2');
      expect(find.text('72 / 100 pts'), findsOneWidget);
      expect(find.textContaining('Includes audits still in progress'), findsNothing);
      expect(find.textContaining('*'), findsNothing);
      // The old "My audits / My locations" switch is gone.
      expect(find.text('My locations'), findsNothing);
      expect(find.text('Weekly hygiene'), findsOneWidget);
    });

    testWidgets('an audit tile is a tap-filter by the ids the server counted; Total Audits clears it', (tester) async {
      backend
        ..audits = [
          _audit('d1', title: 'Late one'),
          _audit('o1', title: 'On time one', timeliness: 'On-Time Completed'),
          _audit('p1', title: 'Running one', status: 'In Progress', display: 'In Progress', timeliness: null),
        ]
        ..auditStats = _auditStats(totalAudits: 3);
      await _pumpReports(tester);
      expect(find.text('Late one'), findsOneWidget);
      expect(find.text('On time one'), findsOneWidget);
      expect(find.text('Running one'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('report-tile-delayed')));
      await tester.pumpAndSettle();
      expect(find.text('Late one'), findsOneWidget);
      expect(find.text('On time one'), findsNothing);
      expect(find.text('Running one'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('report-tile-inProgress')));
      await tester.pumpAndSettle();
      expect(find.text('Late one'), findsOneWidget, reason: 'picked tiles OR together');
      expect(find.text('Running one'), findsOneWidget);
      expect(find.text('On time one'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('report-tile-total')));
      await tester.pumpAndSettle();
      expect(find.text('On time one'), findsOneWidget);
    });

    testWidgets('location-wise: the headers are the server\'s byLocation (count and cumulative score), not the loaded rows\'', (tester) async {
      backend
        ..audits = [
          _audit('d1', title: 'Late one', location: 'Plant A', got: 1, of: 10),
          _audit('o1', title: 'On time one', location: 'Plant A', got: 1, of: 10),
        ]
        ..auditStats = {
          ..._auditStats(totalAudits: 2),
          'byLocation': [
            // 37 reports at 84%: nothing the two loaded rows (10%) could produce.
            {'key': 'Plant A', 'label': 'Plant A', 'count': 37, 'percentage': 84, 'achieved': 840, 'maxPossible': 1000, 'auditIds': ['d1', 'o1']},
            {'key': 'No location', 'label': 'No location', 'count': 1, 'percentage': null, 'auditIds': []},
          ],
        };
      await _pumpReports(tester);

      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();
      expect(find.text('Plant A'), findsOneWidget);
      expect(find.text('37 reports · 84%'), findsOneWidget);
      expect(find.text('1 report'), findsOneWidget);
      // Collapsed until tapped.
      expect(find.text('Late one'), findsNothing);
      await tester.tap(find.text('Plant A'));
      await tester.pumpAndSettle();
      expect(find.text('Late one'), findsOneWidget);
      expect(find.text('On time one'), findsOneWidget);
    });

    testWidgets('location-wise with a tile picked asks the server for headers over just the tile\'s audits', (tester) async {
      backend
        ..audits = [_audit('d1', title: 'Late one', location: 'Plant A')]
        ..auditStats = {
          ..._auditStats(totalAudits: 1),
          'byLocation': [
            {'key': 'Plant A', 'label': 'Plant A', 'count': 2, 'percentage': 50, 'auditIds': ['d1']},
          ],
        };
      await _pumpReports(tester);
      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();
      expect(adapter.requests.where((r) => r.queryParameters.containsKey('onlyIds')), isEmpty);

      await tester.tap(find.byKey(const ValueKey('report-tile-delayed')));
      await tester.pumpAndSettle();
      final narrowed = adapter.requests.where((r) => r.path == ApiConstants.auditsReportStats && r.queryParameters.containsKey('onlyIds'));
      expect(narrowed, isNotEmpty);
      expect(narrowed.last.queryParameters['onlyIds'], 'd1,d2');
    });

    testWidgets('the NCs tab shows the six counts, tap-filters by id lists and lists each NC with its server bucket', (tester) async {
      backend
        ..ncs = [
          _nc('n1', title: 'Guard missing', bucket: 'inProgress', place: 'Plant A', audit: 'Weekly hygiene'),
          _nc('n2', title: 'Floor wet', bucket: 'overdue', place: 'Plant B', status: 'Raised', audit: 'Monthly 5S'),
          _nc('n3', title: 'Label faded', bucket: 'onTime', status: 'Closed', severity: 'Minor', audit: 'Store audit', place: 'Plant C'),
        ]
        ..ncStats = _ncStats();
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');

      String valueOf(String id) => tester
          .widget<Text>(find.descendant(of: find.byKey(ValueKey('report-tile-$id')), matching: find.byType(Text)).first)
          .data!;
      expect(valueOf('total'), '12');
      expect(valueOf('inProgress'), '3');
      expect(valueOf('overdue'), '2');
      expect(valueOf('pendingApproval'), '1');
      expect(valueOf('delayed'), '2');
      expect(valueOf('onTime'), '4');
      for (final (id, label) in [
        ('total', 'Total NC'),
        ('inProgress', 'In Progress'),
        ('overdue', 'Overdue'),
        ('pendingApproval', 'Pending Approval'),
        ('delayed', 'Delayed'),
        ('onTime', 'On Time Completion'),
      ]) {
        expect(
          find.descendant(of: find.byKey(ValueKey('report-tile-$id')), matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
      }

      // A row: title, id, audit, place, raiser -> auditee, dates, bucket + flag pills.
      expect(find.text('Guard missing'), findsOneWidget);
      expect(find.text('NC-n1'), findsOneWidget);
      expect(find.text('Weekly hygiene'), findsOneWidget);
      expect(find.text('Plant A'), findsOneWidget);
      expect(find.text('Raised by Asha → Ravi (auditee)'), findsWidgets);
      expect(find.text('Major'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await tester.pumpAndSettle();
      expect(find.text('Floor wet'), findsOneWidget);
      expect(find.text('Guard missing'), findsNothing);
      expect(find.text('Label faded'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('report-tile-total')));
      await tester.pumpAndSettle();
      expect(find.text('Guard missing'), findsOneWidget);
      expect(find.text('Label faded'), findsOneWidget);
    });

    testWidgets('NC location-wise headers show the server\'s total and bucket tallies', (tester) async {
      backend
        ..ncs = [_nc('n1', title: 'Guard missing', place: 'Plant A')]
        ..ncStats = {
          ..._ncStats(),
          'byLocation': [
            {
              'key': 'Plant A',
              'label': 'Plant A',
              'total': 9,
              'inProgress': 4,
              'overdue': 2,
              'pendingApproval': 0,
              'delayed': 1,
              'onTime': 2,
              'ncIds': ['n1'],
            },
          ],
        };
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');

      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();
      expect(find.text('9 NCs'), findsOneWidget);
      expect(find.text('4 In Progress'), findsOneWidget);
      expect(find.text('2 Overdue'), findsOneWidget);
      expect(find.text('1 Delayed'), findsOneWidget);
      expect(find.text('2 On Time'), findsOneWidget);
      expect(find.text('0 Pending Approval'), findsNothing, reason: 'an empty bucket is not listed');
      expect(find.text('Guard missing'), findsNothing, reason: 'collapsed until tapped');

      await tester.tap(find.text('Plant A'));
      await tester.pumpAndSettle();
      expect(find.text('Guard missing'), findsOneWidget);
    });

    testWidgets('the search goes to the server so the NC list and tiles describe the same NCs', (tester) async {
      backend
        ..ncs = [_nc('n1', title: 'Guard missing')]
        ..ncStats = _ncStats();
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');
      adapter.requests.clear();

      await tester.enterText(find.widgetWithText(TextField, '').last, 'guard');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsReport && r.queryParameters['search'] == 'guard'), isNotEmpty);
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsReportStats && r.queryParameters['search'] == 'guard'), isNotEmpty);
    });

    testWidgets('Repeated NCs: rows show x-count, open count, place and dates; opening one lists every NC with id, date, audit, raiser and auditee', (tester) async {
      backend
        ..repeats = [
          {
            'key': 'guard missing|l1',
            'title': 'Guard missing',
            'locationName': 'Plant A',
            'count': 3,
            'openCount': 2,
            'firstDate': '2026-03-02T00:00:00.000Z',
            'lastDate': '2026-09-01T00:00:00.000Z',
            'latestStatus': 'Raised',
            'ncIds': ['n1', 'n2', 'n3'],
          },
        ]
        ..ncById = {
          'n1': _nc('n1', ncId: 'NC-101', title: 'Guard missing', audit: 'Audit March', raiser: 'Asha', auditee: 'Ravi', start: '2026-03-02T00:00:00.000Z', status: 'Closed', severity: 'Minor'),
          'n2': _nc('n2', ncId: 'NC-140', title: 'Guard missing', audit: 'Audit June', raiser: 'Meera', auditee: 'Dev', start: '2026-06-10T00:00:00.000Z', status: 'Response Submitted'),
          'n3': _nc('n3', ncId: 'NC-188', title: 'Guard missing', audit: 'Audit Sept', raiser: 'Asha', auditee: 'Ravi', start: '2026-09-01T00:00:00.000Z', status: 'Verification'),
        };
      await _pumpReports(tester);
      await _openTab(tester, 'Repeated NCs');

      expect(find.text('×3'), findsOneWidget);
      expect(find.text('Guard missing'), findsOneWidget);
      expect(find.text('2 open'), findsOneWidget);
      expect(find.textContaining('Plant A'), findsOneWidget);
      expect(find.textContaining('${Formatters.date(DateTime.parse('2026-03-02T00:00:00.000Z'))} → ${Formatters.date(DateTime.parse('2026-09-01T00:00:00.000Z'))}'), findsOneWidget);
      expect(find.textContaining('Team / Members do not narrow this tab'), findsOneWidget);
      expect(find.textContaining('last 6 months'), findsOneWidget);

      await tester.tap(find.text('Guard missing'));
      await tester.pumpAndSettle();
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsRepeatRows).single.queryParameters['ids'], 'n1,n2,n3');
      for (final id in ['NC-101', 'NC-140', 'NC-188']) {
        expect(find.text(id), findsOneWidget, reason: id);
      }
      // Every fact carries its own label.
      expect(find.text('Raised'), findsNWidgets(3));
      expect(find.text('Audit'), findsNWidgets(3));
      expect(find.text('Raised by'), findsNWidgets(3));
      expect(find.text('Against'), findsNWidgets(3));
      expect(find.text('Audit June'), findsOneWidget);
      expect(find.text('Meera'), findsOneWidget);
      expect(find.text('Dev'), findsOneWidget);
      expect(find.text(Formatters.date(DateTime.parse('2026-06-10T00:00:00.000Z'))), findsOneWidget);
      expect(find.text('Major'), findsNWidgets(2));
      expect(find.text('Minor'), findsOneWidget);
      expect(find.text('Verification'), findsOneWidget);
      expect(find.text('Response Submitted'), findsOneWidget);
      expect(find.text('Closed'), findsOneWidget);
    });

    testWidgets('min. times picker re-requests with that minCount', (tester) async {
      backend.repeats = [];
      await _pumpReports(tester);
      await _openTab(tester, 'Repeated NCs');
      expect(find.text('No repeats in this window'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('repeat-min-times')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5+').last);
      await tester.pumpAndSettle();
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsRepeats).last.queryParameters['minCount'], 5);
    });

    testWidgets('tapping a repeated NC opens its read-only thread, with no "your response" footer for a stranger', (tester) async {
      backend
        ..repeats = [
          {'key': 'k', 'title': 'Guard missing', 'locationName': 'Plant A', 'count': 2, 'openCount': 1, 'ncIds': ['n1']},
        ]
        ..ncById = {'n1': _nc('n1', ncId: 'NC-101', title: 'Guard missing', status: 'Verification')};
      // The thread's bubbles are sized for real fonts; the test font is ~1.8x wider.
      await _pumpReports(tester, width: 800);
      await _openTab(tester, 'Repeated NCs');
      await tester.tap(find.text('Guard missing'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('NC-101'));
      await tester.pumpAndSettle();

      expect(find.byType(NcReviewScreen), findsOneWidget);
      expect(tester.widget<NcReviewScreen>(find.byType(NcReviewScreen)).readOnly, isTrue);
      expect(find.text('Waiting for the auditor to review your response.'), findsNothing);
      expect(find.text('Approve & Close'), findsNothing);
    });

    testWidgets('the screen keeps its picked tab, tiles and scroll state across a remount (ListViewMemory)', (tester) async {
      backend
        ..ncs = [_nc('n1', title: 'Guard missing', bucket: 'inProgress'), _nc('n2', title: 'Floor wet', bucket: 'overdue')]
        ..ncStats = _ncStats();
      final memory = ListViewMemory();
      await _pumpReports(tester, memory: memory);
      await _openTab(tester, 'NCs');
      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await tester.pumpAndSettle();
      expect(find.text('Guard missing'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await _pumpReports(tester, memory: memory);
      // Back on the NCs tab, the overdue tile still picked.
      expect(find.text('Floor wet'), findsOneWidget);
      expect(find.text('Guard missing'), findsNothing);
    });
  });

  group('bundles that list only some of their zones', () {
    AuditModel zone(String id, {int? total}) =>
        AuditModel(id: id, title: 'Bundle', scope: '', status: 'Completed', scheduleBatchId: 'b1', batchZoneCount: total);

    test('batchZoneCount is read as a nullable int', () {
      expect(AuditModel.fromJson({'_id': 'a', 'batchZoneCount': 5}).batchZoneCount, 5);
      expect(AuditModel.fromJson({'_id': 'a', 'batchZoneCount': 5.0}).batchZoneCount, 5);
      expect(AuditModel.fromJson({'_id': 'a'}).batchZoneCount, isNull);
    });

    test('partial only when the card holds fewer zones than the bundle has', () {
      expect(isPartialBundle([zone('1', total: 5), zone('2', total: 5)]), isTrue);
      expect(bundleLocationsLabel([zone('1', total: 5), zone('2', total: 5)]), '2 of 5 locations');
      expect(isPartialBundle([zone('1', total: 2), zone('2', total: 2)]), isFalse);
      expect(bundleLocationsLabel([zone('1', total: 2), zone('2', total: 2)]), '2 locations');
      // An older server says nothing: never guess "partial".
      expect(isPartialBundle([zone('1'), zone('2')]), isFalse);
      expect(bundleLocationsLabel([zone('1'), zone('2')]), '2 locations');
    });

    test('fetchBatchReport sends zoneIds (comma-joined) only when asked to', () async {
      final p = AuditsProvider();
      await p.fetchBatchReport('b1');
      expect(adapter.requests.last.path, ApiConstants.auditBatchReport('b1'));
      expect(adapter.requests.last.queryParameters.containsKey('zoneIds'), isFalse);
      await p.fetchBatchReport('b1', zoneIds: const []);
      expect(adapter.requests.last.queryParameters.containsKey('zoneIds'), isFalse);
      await p.fetchBatchReport('b1', zoneIds: ['z1', 'z2']);
      expect(adapter.requests.last.queryParameters['zoneIds'], 'z1,z2');
    });

    Future<void> pumpBundle(WidgetTester tester, {int? total}) async {
      backend
        ..audits = [
          _audit('z1', title: 'Bundle', batch: 'b1', zoneCount: total, location: 'Plant A'),
          _audit('z2', title: 'Bundle', batch: 'b1', zoneCount: total, location: 'Plant B'),
        ]
        ..auditStats = _auditStats(totalAudits: 1);
      await _pumpReports(tester);
    }

    testWidgets('the card says "N of M locations" when it lists fewer zones than the bundle has', (tester) async {
      await pumpBundle(tester, total: 5);
      expect(find.text('2 of 5 locations'), findsOneWidget);
      expect(find.text('2 locations'), findsNothing);
    });

    testWidgets('a card holding every zone (or an older server) keeps "N locations"', (tester) async {
      await pumpBundle(tester, total: 2);
      expect(find.text('2 locations'), findsOneWidget);
      expect(find.textContaining(' of '), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await pumpBundle(tester);
      expect(find.text('2 locations'), findsOneWidget);
    });

    testWidgets('the combined PDF asks for exactly the card\'s zones when it is partial, the whole batch otherwise', (tester) async {
      Iterable<RequestOptions> batchRequests() =>
          adapter.requests.where((r) => r.path == ApiConstants.auditBatchReport('b1'));

      await pumpBundle(tester, total: 5);
      await tester.tap(find.byTooltip('Download PDF'));
      await tester.pumpAndSettle();
      expect(batchRequests(), hasLength(1));
      expect(
        '${batchRequests().single.queryParameters['zoneIds']}'.split(',').toSet(),
        {'z1', 'z2'},
        reason: 'exactly the zones the card lists',
      );

      adapter.requests.clear();
      await tester.pumpWidget(const SizedBox());
      await pumpBundle(tester, total: 2);
      await tester.tap(find.byTooltip('Download PDF'));
      await tester.pumpAndSettle();
      expect(batchRequests(), hasLength(1));
      expect(batchRequests().single.queryParameters.containsKey('zoneIds'), isFalse);
    });
  });

  group('NCs of one audit read as one bundle', () {
    // Three NCs of ONE audit (two places, two raisers, two auditees, two flags, two
    // stages) and one NC of another audit.
    List<Map<String, dynamic>> bundle({String? batch}) => [
      _nc('n1', title: 'Guard missing', auditOf: 'A1', batch: batch, bucket: 'overdue', place: 'Plant A', raiser: 'Asha', auditee: 'Ravi', severity: 'Major', start: '2026-09-03T00:00:00.000Z'),
      _nc('n2', title: 'Floor wet', auditOf: 'A1', batch: batch, bucket: 'overdue', place: 'Plant B', raiser: 'Asha', auditee: 'Dev', severity: 'Minor', start: '2026-09-01T00:00:00.000Z'),
      _nc('n3', title: 'Label faded', auditOf: 'A1', batch: batch, bucket: 'inProgress', place: 'Plant A', raiser: 'Meera', auditee: 'Ravi', severity: 'Major', start: '2026-09-02T00:00:00.000Z'),
      _nc('n4', title: 'Lone finding', audit: 'Store audit', bucket: 'onTime', status: 'Closed', place: 'Plant C', start: '2026-09-05T00:00:00.000Z'),
    ];

    test('groupNcsByAudit: by audit key, newest first, a deleted audit still groups, a nameless NC stays single', () {
      final ncs = [
        for (final row in [
          _nc('a', auditOf: 'A1'),
          _nc('b', auditOf: 'B1'),
          _nc('c', auditOf: 'A1'),
          _nc('d', auditOf: 'gone', auditDeleted: true),
          _nc('e', auditOf: 'gone', auditDeleted: true),
          {..._nc('f'), 'auditKey': null, 'auditId': null},
        ])
          NcModel.fromJson(row),
      ];
      final groups = groupNcsByAudit(ncs);
      expect(groups.map((g) => g.ncs.map((n) => n.id).toList()).toList(), [
        ['a', 'c'],
        ['b'],
        ['d', 'e'],
        ['f'],
      ]);
      expect(groups.map((g) => g.isBundle).toList(), [true, false, true, false]);
      expect(groups[2].auditDeleted, isTrue);
      expect(groups[0].auditDeleted, isFalse);
    });

    testWidgets('a 3-NC audit is ONE card (audit, count, place, people, dates, stages, flags) that expands to its 3 NCs; a lone NC is a plain card', (tester) async {
      backend
        ..ncs = bundle(batch: 'bat1')
        ..ncStats = _ncStats();
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');

      // One bundle card, not three rows: its NCs are folded away.
      expect(find.text('Weekly hygiene'), findsOneWidget);
      expect(find.text('3 NCs'), findsOneWidget);
      expect(find.text('Bundle'), findsOneWidget);
      expect(find.text('Guard missing'), findsNothing);
      expect(find.text('Floor wet'), findsNothing);
      expect(find.text('Label faded'), findsNothing);
      // Where / who: a common value, else "Multiple".
      expect(find.text('Multiple'), findsOneWidget); // place (Plant A, Plant B)
      expect(find.text('Raised by Multiple → Multiple (auditee)'), findsOneWidget);
      // Earliest raised / earliest due.
      expect(find.text('Raised ${Formatters.date(DateTime.parse('2026-09-01T00:00:00.000Z'))} · Due ${Formatters.date(DateTime.parse('2026-09-20T00:00:00.000Z'))}'), findsOneWidget);
      // The stages (each row's own server bucket, counted) and the flags.
      expect(find.text('Overdue ×2'), findsOneWidget);
      expect(find.text('In Progress ×1'), findsOneWidget);
      expect(find.text('Major ×2'), findsOneWidget);
      expect(find.text('Minor ×1'), findsOneWidget);
      // The other audit's single NC is a plain card: visible, no "N NCs".
      expect(find.text('Lone finding'), findsOneWidget);
      expect(find.text('NC-n4'), findsOneWidget);
      expect(find.text('Store audit'), findsOneWidget);

      await tester.tap(find.text('Weekly hygiene'));
      await tester.pumpAndSettle();
      for (final t in ['Guard missing', 'Floor wet', 'Label faded']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      for (final id in ['NC-n1', 'NC-n2', 'NC-n3']) {
        expect(find.text(id), findsOneWidget, reason: id);
      }
      // Inside the bundle the audit is the card's own title, not repeated per NC.
      expect(find.text('Weekly hygiene'), findsOneWidget);

      await tester.tap(find.text('Weekly hygiene'));
      await tester.pumpAndSettle();
      expect(find.text('Guard missing'), findsNothing);
    });

    testWidgets('a stand-alone audit carries no Bundle marker; one common place / person is named, not "Multiple"', (tester) async {
      backend
        ..ncs = [
          _nc('n1', auditOf: 'A1', place: 'Plant A', raiser: 'Asha', auditee: 'Ravi'),
          _nc('n2', auditOf: 'A1', place: 'Plant A', raiser: 'Asha', auditee: 'Ravi'),
        ]
        ..ncStats = _ncStats();
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');
      expect(find.text('2 NCs'), findsOneWidget);
      expect(find.text('Bundle'), findsNothing);
      expect(find.text('Multiple'), findsNothing);
      expect(find.text('Plant A'), findsOneWidget);
      expect(find.text('Raised by Asha → Ravi (auditee)'), findsOneWidget);
    });

    testWidgets('the NCs of a deleted audit still form one bundle, titled "Audit deleted" (muted, italic)', (tester) async {
      backend
        ..ncs = [
          _nc('n1', auditOf: 'gone', auditDeleted: true),
          _nc('n2', auditOf: 'gone', auditDeleted: true),
          _nc('n3', auditOf: 'gone2', auditDeleted: true, title: 'Orphan finding'),
        ]
        ..ncStats = _ncStats();
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');

      expect(find.text('2 NCs'), findsOneWidget);
      // The bundle's title and the lone NC's audit line, both "Audit deleted".
      expect(find.text('Audit deleted'), findsNWidgets(2));
      for (final t in tester.widgetList<Text>(find.text('Audit deleted'))) {
        expect(t.style?.fontStyle, FontStyle.italic);
      }
      expect(find.text('Orphan finding'), findsOneWidget, reason: 'a lone NC is a plain card');
    });

    testWidgets('the count line reads the server\'s totals: NCs and audits', (tester) async {
      backend
        ..ncs = bundle()
        ..ncStats = _ncStats();
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');
      expect(find.text('4 NCs · 2 audits'), findsOneWidget);
    });

    testWidgets('a tile pick leaves only its NCs inside the bundle (and its counts)', (tester) async {
      backend
        ..ncs = bundle()
        ..ncStats = {
          ..._ncStats(),
          'overdueIds': ['n1', 'n2'],
          'inProgressIds': ['n3'],
        };
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');

      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await tester.pumpAndSettle();
      expect(find.text('2 NCs'), findsOneWidget, reason: 'the bundle holds just the tile\'s NCs');
      expect(find.text('Overdue ×2'), findsOneWidget);
      expect(find.text('In Progress ×1'), findsNothing);
      expect(find.text('Lone finding'), findsNothing);
      expect(find.text('2 NCs · 1 audit'), findsOneWidget);
    });

    testWidgets('location-wise: a place\'s own NCs of one audit are a bundle inside that place', (tester) async {
      backend
        ..ncs = bundle()
        ..ncStats = {
          ..._ncStats(),
          'byLocation': [
            {'key': 'Plant A', 'label': 'Plant A', 'total': 2, 'inProgress': 1, 'overdue': 1, 'pendingApproval': 0, 'delayed': 0, 'onTime': 0, 'ncIds': ['n1', 'n3']},
            {'key': 'Plant C', 'label': 'Plant C', 'total': 1, 'inProgress': 0, 'overdue': 0, 'pendingApproval': 0, 'delayed': 0, 'onTime': 1, 'ncIds': ['n4']},
          ],
        };
      await _pumpReports(tester);
      await _openTab(tester, 'NCs');
      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Plant A'));
      await tester.pumpAndSettle();
      // Only Plant A's two NCs of the audit, as one bundle.
      expect(find.text('Weekly hygiene'), findsOneWidget);
      expect(find.text('2 NCs'), findsNWidgets(2)); // the place header and the bundle
      expect(find.text('Guard missing'), findsNothing);

      await tester.tap(find.text('Weekly hygiene'));
      await tester.pumpAndSettle();
      expect(find.text('Guard missing'), findsOneWidget);
      expect(find.text('Label faded'), findsOneWidget);
      expect(find.text('Floor wet'), findsNothing, reason: 'that one is at Plant B');
    });

    test('groupBy=audit goes with every paged NC request (never with ids), pages by AUDIT, and the totals are the server\'s', () async {
      Map<String, dynamic> one(int i) => _nc('r$i');
      adapter.handler = (o) async {
        if (o.path != ApiConstants.ncsReport) return json(200, {'isOk': true, 'data': []});
        final page = o.queryParameters['page'] as int;
        // 120 audits; the first page holds a 3-NC audit, so more rows than `limit`.
        final rows = page == 1
            ? [for (var i = 0; i < 102; i++) one(i)]
            : [for (var i = 102; i < 122; i++) one(i)];
        return json(200, {
          'isOk': true,
          'data': {'ncs': rows, 'total': 120, 'totalNcs': 122, 'page': page, 'limit': 100},
        });
      };
      final p = NcProvider()..setSelfEmployeeId('me');
      await p.fetchNcReport();
      final paged = adapter.requests.where((r) => r.path == ApiConstants.ncsReport).toList();
      expect(paged, hasLength(2), reason: 'the last page comes from the audit total');
      for (final r in paged) {
        expect(r.queryParameters['groupBy'], 'audit');
        expect(r.queryParameters.containsKey('ids'), isFalse);
        expect(r.queryParameters['limit'], 100);
      }
      expect(p.reportNcs, hasLength(122));
      expect(p.ncReportTotalAudits, 120);
      expect(p.ncReportTotalNcs, 122);

      // Tile stats are not paged: no groupBy there.
      await p.fetchNcReportStats();
      expect(adapter.requests.firstWhere((r) => r.path == ApiConstants.ncsReportStats).queryParameters.containsKey('groupBy'), isFalse);
    });
  });

  group('NC Monitoring tab (auditor)', () {
    testWidgets('shows the same six tiles, each a tap-filter by the server\'s id list', (tester) async {
      backend
        ..raised = [_nc('n1', title: 'Guard missing'), _nc('n2', title: 'Floor wet'), _nc('n3', title: 'Label faded')]
        ..raisedStats = {
          ..._ncStats(),
          'awaitingApproval': 1,
          'closed': 4,
          'statusCounts': {'Raised': 5, 'Response Submitted': 1, 'Verification': 0, 'Closed': 4},
          'inProgressIds': ['n1'],
          'overdueIds': ['n2'],
          'pendingApprovalIds': [],
          'delayedIds': [],
          'onTimeIds': ['n3'],
        };
      await _pumpNcMonitoring(tester);

      for (final label in ['Total NC', 'In Progress', 'Overdue', 'Pending Approval', 'Delayed', 'On Time Completion']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Guard missing'), findsOneWidget);
      expect(find.text('Floor wet'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await tester.pumpAndSettle();
      expect(find.text('Floor wet'), findsOneWidget);
      expect(find.text('Guard missing'), findsNothing);
      expect(find.text('Label faded'), findsNothing);

      // Tapping the same tile again lifts the filter.
      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await tester.pumpAndSettle();
      expect(find.text('Guard missing'), findsOneWidget);
    });

    testWidgets('an older answer (no buckets) draws no tiles and leaves the list alone', (tester) async {
      backend
        ..raised = [_nc('n1', title: 'Guard missing')]
        ..raisedStats = {'total': 1, 'awaitingApproval': 0, 'overdue': 0, 'closed': 0};
      await _pumpNcMonitoring(tester);
      expect(find.byKey(const ValueKey('report-tile-overdue')), findsNothing);
      expect(find.text('Guard missing'), findsOneWidget);
    });
  });

  group('bottom bar', () {
    Future<void> pumpShell(WidgetTester tester, AppMode mode) async {
      // AppShell asks for the notification permission on its first frame.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async => call.method == 'requestPermissions' ? <int, int>{} : null,
      );
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('flutter.baseflow.com/permissions/methods'), null));
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final audits = AuditsProvider()..setSelfEmployeeId('me');
      final ncs = NcProvider()..setSelfEmployeeId('me');
      final notifications = NotificationsProvider();
      addTearDown(notifications.resetForLogout);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => AppModeProvider()..mode = mode..loaded = true),
          ChangeNotifierProvider.value(value: notifications),
          ChangeNotifierProvider(create: (_) => DashboardProvider()..setSelfEmployeeId('me')),
          ChangeNotifierProvider.value(value: audits),
          ChangeNotifierProvider.value(value: ncs),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider(create: (_) => ListViewMemory()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const AppShell()),
      ));
      await tester.pumpAndSettle();
      addTearDown(() async {
        audits.stopListening();
        ncs.stopListening();
      });
    }

    Finder bar(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

    testWidgets('Auditor panel: Dashboard, Audits, NC Monitoring, Reports — and Reports opens the three tabs', (tester) async {
      backend.auditStats = _auditStats();
      await pumpShell(tester, AppMode.auditor);
      for (final label in ['Dashboard', 'Audits', 'NC Monitoring', 'Reports']) {
        expect(bar(label), findsOneWidget, reason: label);
      }
      expect(find.byType(TabBar), findsNothing);

      await tester.tap(bar('Reports'));
      await tester.pumpAndSettle();
      // The shell owns the only AppBar: titled Final Report, no second one.
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Final Report')), findsOneWidget);
      expect(find.byType(TabBar), findsOneWidget);
      for (final tab in ['Audits', 'NCs', 'Repeated NCs']) {
        expect(find.descendant(of: find.byType(TabBar), matching: find.text(tab)), findsOneWidget, reason: tab);
      }
      // First opening loads all three lists under the default Me scope.
      expect(adapter.requests.where((r) => r.path == ApiConstants.auditsReport), isNotEmpty);
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsReport), isNotEmpty);
      expect(adapter.requests.where((r) => r.path == ApiConstants.ncsRepeats), isNotEmpty);
      expect(adapter.requests.firstWhere((r) => r.path == ApiConstants.auditsReport).queryParameters['employeeIds'], 'me');
    });

    testWidgets('Auditee panel: Dashboard, NCs, Reports — and the three tabs switch', (tester) async {
      backend
        ..auditStats = _auditStats()
        ..ncs = [_nc('n1', title: 'Guard missing')]
        ..ncStats = _ncStats()
        ..repeats = [
          {'key': 'k', 'title': 'Repeated wording', 'locationName': 'Plant A', 'count': 2, 'openCount': 0, 'ncIds': []},
        ];
      await pumpShell(tester, AppMode.auditee);
      for (final label in ['Dashboard', 'NCs', 'Reports']) {
        expect(bar(label), findsOneWidget, reason: label);
      }
      expect(bar('Audits'), findsNothing);

      await tester.tap(bar('Reports'));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(AppBar), matching: find.text('Final Report')), findsOneWidget);
      expect(find.byKey(const ValueKey('report-tile-score')), findsOneWidget, reason: 'Audits tab first');

      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('NCs')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-tile-overdue')), findsOneWidget);
      expect(find.text('Guard missing'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Repeated NCs')));
      await tester.pumpAndSettle();
      expect(find.text('Repeated wording'), findsOneWidget);

      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Audits')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-tile-score')), findsOneWidget);
    });

    testWidgets('the Dashboard stat-tile jump indices are unchanged (NC Monitoring is still tab 2, Audits tab 1)', (tester) async {
      await pumpShell(tester, AppMode.auditor);
      final destinations = tester.widget<NavigationBar>(find.byType(NavigationBar)).destinations;
      expect(destinations.map((d) => (d as NavigationDestination).label).toList(),
          ['Dashboard', 'Audits', 'NC Monitoring', 'Reports']);
    });

    testWidgets('Profile no longer links to Reports (it is a bottom-bar tab now, not a second entry)', (tester) async {
      final auth = AuthProvider()
        ..updateUser(UserModel(id: 'u1', roleType: 'Employee', name: 'Asha', username: 'asha', email: 'a@x.com', mobileNumber: '1'));
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => AppModeProvider()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const ProfileScreen()),
      ));
      await tester.pumpAndSettle();
      // The signed-in Profile is on screen with its other entries...
      expect(find.text('Edit Profile'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Support'), findsOneWidget);
      // ...and no Reports row.
      expect(find.text('Reports'), findsNothing);
    });
  });
}

// ── Fake server ───────────────────────────────────────────────────────────

class _Backend {
  List<Map<String, dynamic>> audits = [];
  Object? auditStats = <String, dynamic>{};
  List<Map<String, dynamic>> ncs = [];
  Object? ncStats = <String, dynamic>{};
  List<Map<String, dynamic>> repeats = [];
  Map<String, Map<String, dynamic>> ncById = {};
  List<Map<String, dynamic>> raised = [];
  Object? raisedStats;

  Future<ResponseBody> handle(RequestOptions o) async {
    switch (o.path) {
      case ApiConstants.auditsReport:
        return json(200, {
          'isOk': true,
          'data': {'audits': audits, 'total': audits.length, 'page': 1, 'limit': 100},
        });
      case ApiConstants.auditsReportStats:
        return auditStats == null ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': auditStats});
      case ApiConstants.ncsReport:
        // groupBy=audit (never with ids): `total` counts AUDITS, `totalNcs` the NCs.
        final grouped = o.queryParameters['groupBy'] == 'audit' && !o.queryParameters.containsKey('ids');
        final audits = {
          for (final n in ncs) '${n['auditKey'] ?? (n['auditId'] is Map ? n['auditId']['_id'] : n['_id'])}',
        };
        return json(200, {
          'isOk': true,
          'data': {
            'ncs': ncs,
            'total': grouped ? audits.length : ncs.length,
            'page': 1,
            'limit': 100,
            if (grouped) 'totalNcs': ncs.length,
          },
        });
      case ApiConstants.ncsReportStats:
        return ncStats == null ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': ncStats});
      case ApiConstants.ncsRepeats:
        return json(200, {
          'isOk': true,
          'data': {'rows': repeats, 'total': repeats.length, 'page': 1, 'limit': 30, 'minCount': o.queryParameters['minCount']},
        });
      case ApiConstants.ncsRepeatRows:
        final ids = '${o.queryParameters['ids']}'.split(',');
        return json(200, {
          'isOk': true,
          'data': [for (final id in ids) if (ncById[id] != null) ncById[id]],
        });
      case ApiConstants.ncsRaised:
        return json(200, {'isOk': true, 'data': raised});
      case ApiConstants.ncsRaisedStats:
        return raisedStats == null ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': raisedStats});
      default:
        return json(200, {'isOk': true, 'data': []});
    }
  }
}

Map<String, dynamic> _audit(
  String id, {
  String title = 'Report',
  String? location,
  String status = 'Completed',
  String? display,
  String? timeliness = 'Delayed Completed',
  double got = 8,
  double of = 10,
  String? batch,
  int? zoneCount,
}) => {
  '_id': id,
  'title': title,
  'scope': '',
  'scheduleBatchId': batch,
  'batchZoneCount': zoneCount,
  'status': status,
  'displayStatus': display ?? (status == 'Completed' ? 'Total Closed' : 'In Progress'),
  'timeliness': timeliness,
  'scheduledDate': DateTime.now().toUtc().toIso8601String(),
  'completedDate': DateTime.now().toUtc().toIso8601String(),
  'scoreResult': {'achieved': got, 'maxPossible': of, 'percentage': (got / of * 100).round()},
  'locationIds': [
    if (location != null) {'_id': location, 'name': location},
  ],
};

/// What GET /audits/report/stats answers in these tests — 9 audits, 2 in progress,
/// 5 completed (3 on time + 2 delayed), a score over the completed ones only
/// (the server always sends isPartial: false since 2026-09-30).
Map<String, dynamic> _auditStats({int totalAudits = 9}) => {
  'percentage': 71.6,
  'achieved': 72,
  'maxPossible': 100,
  'isPartial': false,
  'totalAudits': totalAudits,
  'total': 5,
  'completed': 5,
  'inProgress': 2,
  'onTimeCompleted': 3,
  'delayedCompleted': 2,
  'completedIds': ['d1', 'd2', 'o1', 'o2', 'o3'],
  'inProgressIds': ['p1', 'p2'],
  'onTimeIds': ['o1', 'o2', 'o3'],
  'delayedIds': ['d1', 'd2'],
  'byLocation': [],
};

Map<String, dynamic> _ncStats() => {
  'total': 12,
  'inProgress': 3,
  'overdue': 2,
  'pendingApproval': 1,
  'delayed': 2,
  'onTime': 4,
  'inProgressIds': ['n1'],
  'overdueIds': ['n2'],
  'pendingApprovalIds': <String>[],
  'delayedIds': <String>[],
  'onTimeIds': ['n3'],
  'byLocation': [],
};

Map<String, dynamic> _nc(
  String id, {
  String? ncId,
  String title = 'Guard missing',
  String status = 'Raised',
  String bucket = 'inProgress',
  String place = 'Plant A',
  String audit = 'Weekly hygiene',
  String raiser = 'Asha',
  String auditee = 'Ravi',
  String severity = 'Major',
  String start = '2026-09-01T00:00:00.000Z',
  String? auditOf, // the audit's id; default: one audit per NC
  String? batch, // the audit's scheduleBatchId
  bool auditDeleted = false, // `auditId` comes back null, `auditKey` survives
}) => {
  '_id': id,
  'ncId': ncId ?? 'NC-$id',
  'title': title,
  'status': status,
  'severity': severity,
  'bucket': bucket,
  'placeLabel': place,
  'auditKey': auditOf ?? 'a-$id',
  'auditId': auditDeleted
      ? null
      : {'_id': auditOf ?? 'a-$id', 'title': audit, 'auditType': 'Safety', 'scheduleBatchId': batch},
  'raisedByEmployeeId': {'_id': 'u-$raiser', 'employeeName': raiser},
  'auditeeEmployeeId': {'_id': 'u-$auditee', 'employeeName': auditee},
  'startDate': start,
  'targetDate': '2026-09-20T00:00:00.000Z',
};

// ── Screens ───────────────────────────────────────────────────────────────

Future<void> _pumpReports(WidgetTester tester, {ListViewMemory? memory, double width = 390}) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final audits = AuditsProvider()..setSelfEmployeeId('me');
  final ncs = NcProvider()..setSelfEmployeeId('me');
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: audits),
      ChangeNotifierProvider.value(value: ncs),
      ChangeNotifierProvider(create: (_) => DashboardProvider()),
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
      ChangeNotifierProvider<ListViewMemory>.value(value: memory ?? ListViewMemory()),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: const ReportsScreen()),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String name) async {
  await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text(name)));
  await tester.pumpAndSettle();
}

Future<void> _pumpNcMonitoring(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuditsProvider()),
      ChangeNotifierProvider(create: (_) => NcProvider()..setSelfEmployeeId('me')),
      ChangeNotifierProvider(create: (_) => DashboardProvider()),
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
      ChangeNotifierProvider(create: (_) => ListViewMemory()),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: NcListScreen(mode: NcListMode.auditorOnly)),
    ),
  ));
  await tester.pumpAndSettle();
}
