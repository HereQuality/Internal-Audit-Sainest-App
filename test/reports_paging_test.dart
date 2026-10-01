import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/report_stats.dart';
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

/// The Final Report's Audits list is read ONE PAGE at a time (20 groups): the first
/// page on open / on a chip, tile, search or filter change / on pull-to-refresh, the
/// next ones as the user scrolls near the end, and the chip, the search and the tile
/// picks are the server's filters (`status` / `search`). The location-wise view loads
/// each opened place's rows lazily, 20 of its audit ids at a time. Everything here is
/// answered by a fake server that filters and pages like the real one
/// (support/report_list_fake.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Server server;
  late FakeAdapter adapter;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    server = _Server();
    adapter = FakeAdapter()..handler = server.handle;
    DioClient.instance.dio.httpClientAdapter = adapter;
    SocketService.debugInstance = FakeSockets().service;
  });

  List<RequestOptions> reads() => adapter.requests.where((r) => r.path == ApiConstants.auditsReport).toList();
  List<RequestOptions> statsReads() => adapter.requests.where((r) => r.path == ApiConstants.auditsReportStats).toList();
  Map<String, dynamic> lastRead() => reads().last.queryParameters;
  List<String> idsOf(AuditsProvider p) => [for (final a in p.reportAudits) a.id];

  group('ReportStats: tiles and chip as the list endpoint\'s `status`', () {
    test('every tile has the label the server filters by; the chip comes first, the tiles in the order the row shows them', () {
      expect(ReportStats.tileStatusLabels, {
        'inProgress': 'In Progress',
        'overdue': 'Overdue',
        'notStarted': 'Not Started',
        'onTime': 'On-Time Completed',
        'delayed': 'Delayed Completed',
        'skipped': 'Skipped',
        'notAttempted': 'Not Attempted',
      });
      expect(ReportStats.statusCsv(), isNull);
      expect(ReportStats.statusCsv(chip: 'All'), isNull);
      expect(ReportStats.statusCsv(chip: 'Completed'), 'Completed');
      expect(ReportStats.statusCsv(tiles: {'delayed', 'overdue'}), 'Overdue,Delayed Completed');
      expect(ReportStats.statusCsv(chip: 'Overdue', tiles: {'overdue', 'skipped'}), 'Overdue,Skipped', reason: 'deduplicated');
      // A tile with no label (Other, the retired Completed) adds nothing.
      expect(ReportStats.statusCsv(tiles: {'other'}), isNull);
      expect(ReportStats.statusCsv(tiles: {'completed', 'skipped'}), 'Skipped');
    });
  });

  group('AuditsProvider: the Audits list, one page at a time', () {
    test('the first request is page 1 with limit 20 — one page, not all of them', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider()..setSelfEmployeeId('me');
      await p.fetchReportAudits();

      expect(reads(), hasLength(1));
      expect(lastRead()['page'], 1);
      expect(lastRead()['limit'], 20);
      expect(lastRead()['employeeIds'], 'me');
      expect(lastRead().containsKey('status'), isFalse);
      expect(lastRead().containsKey('search'), isFalse);
      expect(p.reportAudits, hasLength(20));
      expect(p.reportsTotal, 45, reason: 'the server\'s count of every match, not what is loaded');
      expect(p.reportsHasMore, isTrue);
      expect(p.isLoadingReports, isFalse);
      expect(p.reportsError, isNull);
    });

    test('loadMore appends page 2, then page 3, and stops at the total', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider();
      await p.fetchReportAudits();

      await p.fetchMoreReportAudits();
      expect(lastRead()['page'], 2);
      expect(lastRead()['limit'], 20);
      expect(p.reportAudits, hasLength(40));
      expect(p.reportsHasMore, isTrue);

      await p.fetchMoreReportAudits();
      expect(lastRead()['page'], 3);
      expect(p.reportAudits, hasLength(45));
      expect(p.reportsHasMore, isFalse, reason: 'everything the server has is loaded');
      expect(idsOf(p), [for (var i = 0; i < 45; i++) 'a$i'], reason: 'appended in the server\'s order, none twice');

      final asked = reads().length;
      await p.fetchMoreReportAudits();
      expect(reads(), hasLength(asked), reason: 'nothing left to ask for');
      expect(p.reportAudits, hasLength(45));
    });

    test('the end is worked out over GROUPS: a bundle makes a page hold more rows than its limit', () async {
      // 25 groups: one bundle of two zones and 24 single audits. Page 1 = 20 groups = 21 rows.
      server.rows = [
        _row(100, batch: 'B'),
        _row(101, batch: 'B'),
        for (var i = 0; i < 24; i++) _row(i),
      ];
      final p = AuditsProvider();
      await p.fetchReportAudits();
      expect(p.reportAudits, hasLength(21));
      expect(p.reportsTotal, 25);
      expect(p.reportsHasMore, isTrue, reason: '21 rows is nowhere near the end of 25 groups');

      await p.fetchMoreReportAudits();
      expect(p.reportAudits, hasLength(26));
      expect(p.reportsHasMore, isFalse);
    });

    test('a second request is not started while one is on its way', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider();
      await p.fetchReportAudits();

      await Future.wait([p.fetchMoreReportAudits(), p.fetchMoreReportAudits(), p.fetchMoreReportAudits()]);
      expect(reads().where((r) => r.queryParameters['page'] == 2), hasLength(1));
      expect(p.reportAudits, hasLength(40));

      // Nor a next page while the first page is still loading.
      final gate = Completer<void>();
      server.intercept = (o) => o.path == ApiConstants.auditsReport ? gate.future.then((_) => server.reportAnswer(o)) : null;
      final reload = p.fetchReportAudits();
      await settle();
      final before = reads().length;
      await p.fetchMoreReportAudits();
      expect(reads(), hasLength(before));
      gate.complete();
      await reload;
    });

    test('the chip, the search and each tile go to the server as `status` / `search`, from page 1 again', () async {
      server.rows = [
        for (var i = 0; i < 45; i++) _row(i),
        _row(45, status: 'In Progress', display: 'Overdue', timeliness: null),
        _row(46, status: 'In Progress', display: 'Overdue', timeliness: null),
        _row(47, status: 'Skipped', display: 'Skipped', timeliness: null),
      ];
      final p = AuditsProvider()..setSelfEmployeeId('me');
      await p.fetchReportAudits();
      await p.fetchMoreReportAudits();
      expect(p.reportAudits, hasLength(40));

      // The chip: back on page 1, and what was loaded is replaced by the chip's rows.
      p.reportsStatus = 'Overdue';
      await p.fetchReportAudits();
      expect(lastRead()['page'], 1);
      expect(lastRead()['limit'], 20);
      expect(lastRead()['status'], 'Overdue');
      expect(idsOf(p), ['a45', 'a46']);
      expect(p.reportsTotal, 2);
      expect(p.reportsHasMore, isFalse);

      // The search, trimmed.
      p.reportsSearch = '  Audit 46  ';
      await p.fetchReportAudits();
      expect(lastRead()['search'], 'Audit 46');
      expect(lastRead()['status'], 'Overdue');
      expect(idsOf(p), ['a46']);

      // Each tile is the label the server filters by — no ids.
      p
        ..reportsStatus = null
        ..reportsSearch = '';
      const labels = {
        'inProgress': 'In Progress',
        'overdue': 'Overdue',
        'notStarted': 'Not Started',
        'onTime': 'On-Time Completed',
        'delayed': 'Delayed Completed',
        'skipped': 'Skipped',
        'notAttempted': 'Not Attempted',
      };
      for (final e in labels.entries) {
        p.reportsTileKeys = {e.key};
        await p.fetchReportAudits();
        expect(lastRead()['status'], e.value, reason: e.key);
        expect(lastRead().containsKey('ids'), isFalse, reason: e.key);
        expect(lastRead()['page'], 1);
      }
      // The Skipped tile really returns the Skipped audits.
      p.reportsTileKeys = {'skipped'};
      await p.fetchReportAudits();
      expect(idsOf(p), ['a47']);

      // Several tiles, and the chip with a tile, OR together as one csv.
      p.reportsTileKeys = {'skipped', 'overdue'};
      await p.fetchReportAudits();
      expect(lastRead()['status'], 'Overdue,Skipped');
      expect(idsOf(p), unorderedEquals(['a45', 'a46', 'a47']));
      p
        ..reportsStatus = 'Completed'
        ..reportsTileKeys = {'overdue'};
      await p.fetchReportAudits();
      expect(lastRead()['status'], 'Completed,Overdue');
    });

    test('the Other tile has no status label: it is asked by the ids the stats counted', () async {
      server.rows = [for (var i = 0; i < 5; i++) _row(i)];
      server.stats = {..._stats(), 'other': 2, 'otherIds': ['a3', 'a4']};
      final p = AuditsProvider();
      await p.fetchReportStats();
      p.reportsTileKeys = {'other'};
      await p.fetchReportAudits();
      expect(lastRead()['ids'], 'a3,a4');
      expect(lastRead().containsKey('status'), isFalse);
      expect(idsOf(p), ['a3', 'a4']);
      expect(p.reportsHasMore, isFalse, reason: 'an id set is answered in one page');
    });

    test('the stats keep the chip and the search but never the tile picks', () async {
      final p = AuditsProvider()
        ..reportsStatus = 'Completed'
        ..reportsSearch = 'hygiene'
        ..reportsTileKeys = {'delayed'};
      await p.fetchReportStats();
      final q = statsReads().last.queryParameters;
      expect(q['status'], 'Completed', reason: 'the tiles must stay the whole set\'s numbers');
      expect(q['search'], 'hygiene');
    });

    test('an answer for a query that was left meanwhile is dropped', () async {
      server.rows = [
        for (var i = 0; i < 45; i++) _row(i),
        _row(45, status: 'In Progress', display: 'Overdue', timeliness: null),
      ];
      final gate = Completer<void>();
      var held = false;
      server.intercept = (o) {
        // The unfiltered first page waits; the filtered one is answered at once.
        if (o.path == ApiConstants.auditsReport && o.queryParameters['status'] == null && !held) {
          held = true;
          return gate.future.then((_) => server.reportAnswer(o));
        }
        return null;
      };
      final p = AuditsProvider();
      final slow = p.fetchReportAudits();
      await settle();
      expect(p.isLoadingReports, isTrue);

      p.reportsStatus = 'Overdue';
      await p.fetchReportAudits();
      expect(idsOf(p), ['a45']);

      gate.complete();
      await slow;
      expect(idsOf(p), ['a45'], reason: 'the older, slower answer must not land on top of the newer one');
      expect(p.reportsTotal, 1);
      expect(p.reportsHasMore, isFalse);
      expect(p.isLoadingReports, isFalse);
      expect(p.reportsError, isNull);
    });

    test('a next page still in flight when the filter changes is dropped, and so is the loading flag', () async {
      server.rows = [
        for (var i = 0; i < 45; i++) _row(i),
        _row(45, status: 'In Progress', display: 'Overdue', timeliness: null),
      ];
      final p = AuditsProvider();
      await p.fetchReportAudits();

      final gate = Completer<void>();
      server.intercept = (o) =>
          o.path == ApiConstants.auditsReport && o.queryParameters['page'] == 2 ? gate.future.then((_) => server.reportAnswer(o)) : null;
      final more = p.fetchMoreReportAudits();
      await settle();
      expect(p.isLoadingMoreReports, isTrue);

      p.reportsStatus = 'Overdue';
      await p.fetchReportAudits();
      expect(idsOf(p), ['a45']);
      expect(p.isLoadingMoreReports, isFalse);

      gate.complete();
      await more;
      expect(idsOf(p), ['a45'], reason: 'page 2 of the old query must not be appended to the new one');
      expect(p.reportsHasMore, isFalse);
      expect(p.isLoadingMoreReports, isFalse);
      expect(p.reportsMoreError, isNull);
    });

    test('a failed page keeps what is loaded, waits for "Try again", and can be retried', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      var failures = 1;
      server.intercept = (o) {
        if (o.path == ApiConstants.auditsReport && o.queryParameters['page'] == 2 && failures-- > 0) {
          return Future.value(json(500, {'isOk': false, 'message': 'Server is busy'}));
        }
        return null;
      };
      final p = AuditsProvider();
      await p.fetchReportAudits();
      await p.fetchMoreReportAudits();

      expect(p.reportAudits, hasLength(20), reason: 'what was loaded stays');
      expect(p.reportsMoreError, 'Server is busy');
      expect(p.reportsError, isNull, reason: 'the list itself is fine');
      expect(p.reportsHasMore, isTrue);
      expect(p.isLoadingMoreReports, isFalse);

      // A scroll listener asking again does not hammer the server...
      final asked = reads().length;
      await p.fetchMoreReportAudits();
      expect(reads(), hasLength(asked));

      // ...the footer's "Try again" does.
      await p.fetchMoreReportAudits(retry: true);
      expect(p.reportsMoreError, isNull);
      expect(p.reportAudits, hasLength(40));
      expect(lastRead()['page'], 2);
    });

    test('a failed first page says so and leaves nothing half-loaded; pull-to-refresh then loads it', () async {
      server.rows = [for (var i = 0; i < 5; i++) _row(i)];
      server.intercept = (o) => o.path == ApiConstants.auditsReport ? Future.value(json(500, {'isOk': false})) : null;
      final p = AuditsProvider();
      await p.fetchReportAudits();
      expect(p.reportsError, 'Could not load the reports.');
      expect(p.reportAudits, isEmpty);
      expect(p.isLoadingReports, isFalse);

      server.intercept = null;
      await p.fetchReportAudits();
      expect(p.reportsError, isNull);
      expect(p.reportAudits, hasLength(5));
    });

    test('pull-to-refresh reads page 1 only; a live update re-reads just the page that is on screen', () async {
      server.rows = [for (var i = 0; i < 100; i++) _row(i)];
      final p = AuditsProvider();
      await p.fetchReportAudits();
      expect(p.reportsTotalPages, 5);
      await p.goToReportPage(3);
      expect(p.reportsPage, 3);
      expect(p.reportAudits, hasLength(20), reason: 'the page replaces the one before');
      expect(p.reportAudits.first.id, _row(40)['_id']);

      adapter.requests.clear();
      await p.fetchReportAudits(quiet: true);
      expect(reads().map((r) => r.queryParameters['page']), [3], reason: 'only the page on screen');
      expect(p.reportAudits, hasLength(20));
      expect(p.reportsPage, 3);

      adapter.requests.clear();
      await p.fetchReportAudits();
      expect(reads().map((r) => r.queryParameters['page']), [1], reason: 'pull-to-refresh starts over');
      expect(p.reportAudits, hasLength(20));
      expect(p.reportsPage, 1);
    });

    test('a changed filter empties the list at once; the same query keeps it until the answer lands', () async {
      server.rows = [for (var i = 0; i < 30; i++) _row(i)];
      final p = AuditsProvider()..setSelfEmployeeId('me');
      await p.fetchReportAudits();
      expect(p.reportAudits, hasLength(20));

      final gate = Completer<void>();
      server.intercept = (o) => o.path == ApiConstants.auditsReport ? gate.future.then((_) => server.reportAnswer(o)) : null;

      final refresh = p.fetchReportAudits();
      await settle();
      expect(p.reportAudits, hasLength(20), reason: 'a refresh of the same query keeps what is shown');
      gate.complete();
      await refresh;

      final gate2 = Completer<void>();
      server.intercept = (o) => o.path == ApiConstants.auditsReport ? gate2.future.then((_) => server.reportAnswer(o)) : null;
      p.setFilterState(locations: ['zoneB']);
      final changed = p.fetchReportAudits();
      await settle();
      expect(p.reportAudits, isEmpty, reason: 'rows of another query are not left on screen');
      expect(p.isLoadingReports, isTrue);
      gate2.complete();
      await changed;
      expect(lastRead()['locationIds'], 'zoneB');
    });

    test('logout drops a page that was on the wire and empties everything the list held', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider();
      await p.fetchReportAudits();
      final gate = Completer<void>();
      server.intercept = (o) =>
          o.path == ApiConstants.auditsReport && o.queryParameters['page'] == 2 ? gate.future.then((_) => server.reportAnswer(o)) : null;
      final more = p.fetchMoreReportAudits();
      await settle();

      p.resetForLogout();
      expect(p.reportAudits, isEmpty);
      expect(p.reportsTotal, 0);
      expect(p.reportsHasMore, isFalse);
      expect(p.isLoadingMoreReports, isFalse);
      expect(p.reportsMoreError, isNull);

      gate.complete();
      await more;
      expect(p.reportAudits, isEmpty, reason: 'the previous account\'s page must not land');
      expect(p.reportsTotal, 0);
      expect(p.isLoadingMoreReports, isFalse);
    });
  });

  group('AuditsProvider: a place\'s rows in the location-wise view', () {
    ReportLocationStats place(int count) => ReportLocationStats(
      key: 'Plant A',
      label: 'Plant A',
      count: count,
      auditIds: [for (var i = 0; i < count; i++) 'a$i'],
    );

    test('read 20 of the place\'s audit ids at a time, until every one has been read', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider();
      final plant = place(45);
      List<String> askedIds() => '${lastRead()['ids']}'.split(',');

      await p.loadReportPlaceRows(plant);
      expect(askedIds(), [for (var i = 0; i < 20; i++) 'a$i']);
      expect(p.reportPlaces['Plant A']!.audits, hasLength(20));
      expect(p.reportPlaces['Plant A']!.consumed, 20);

      await p.loadReportPlaceRows(plant);
      expect(askedIds(), [for (var i = 20; i < 40; i++) 'a$i']);
      expect(p.reportPlaces['Plant A']!.audits, hasLength(40));

      await p.loadReportPlaceRows(plant);
      expect(askedIds(), [for (var i = 40; i < 45; i++) 'a$i']);
      expect(p.reportPlaces['Plant A']!.audits, hasLength(45));
      expect(p.reportPlaces['Plant A']!.consumed, 45);

      final asked = reads().length;
      await p.loadReportPlaceRows(plant);
      expect(reads(), hasLength(asked), reason: 'every id has been read');
    });

    test('the chip and the search narrow a place\'s rows; the tile picks do not (the ids already are the tile\'s audits)', () async {
      server.rows = [for (var i = 0; i < 5; i++) _row(i)];
      final p = AuditsProvider()
        ..reportsStatus = 'Completed'
        ..reportsSearch = 'Audit'
        ..reportsTileKeys = {'delayed'};
      await p.loadReportPlaceRows(place(5));
      expect(lastRead()['status'], 'Completed');
      expect(lastRead()['search'], 'Audit');
    });

    test('a failed slice keeps the rows read, says so, and is retried by asking again', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider();
      final plant = place(45);
      await p.loadReportPlaceRows(plant);

      server.intercept = (o) => Future.value(json(500, {'isOk': false, 'message': 'Server is busy'}));
      await p.loadReportPlaceRows(plant);
      final failed = p.reportPlaces['Plant A']!;
      expect(failed.error, 'Server is busy');
      expect(failed.audits, hasLength(20));
      expect(failed.consumed, 20);
      expect(failed.loading, isFalse);

      server.intercept = null;
      await p.loadReportPlaceRows(plant);
      final ok = p.reportPlaces['Plant A']!;
      expect(ok.error, isNull);
      expect(ok.audits, hasLength(40));
      expect(ok.consumed, 40);
    });

    test('asking the stats again throws the opened places away, and a slice in flight does not land', () async {
      server.rows = [for (var i = 0; i < 45; i++) _row(i)];
      final p = AuditsProvider();
      await p.loadReportPlaceRows(place(45));
      expect(p.reportPlaces, isNotEmpty);

      final gate = Completer<void>();
      server.intercept = (o) => o.path == ApiConstants.auditsReport ? gate.future.then((_) => server.reportAnswer(o)) : null;
      final slice = p.loadReportPlaceRows(place(45));
      await settle();
      await p.fetchReportStats();
      expect(p.reportPlaces, isEmpty, reason: 'the ids they were read by may have moved');

      gate.complete();
      await slice;
      expect(p.reportPlaces, isEmpty);
    });

    test('a place with no audit ids reads nothing and draws no "Show more"', () async {
      final p = AuditsProvider();
      await p.loadReportPlaceRows(const ReportLocationStats(key: 'No location', label: 'No location', count: 1));
      expect(reads(), isEmpty);
      final rows = p.reportPlaces['No location']!;
      expect(rows.audits, isEmpty);
      expect(rows.loading, isFalse);
      expect(rows.error, isNull);
    });
  });

  group('Reports screen: the Audits tab pages as it scrolls', () {
    Finder list() => find.byKey(const ValueKey('reports-audits-list'));

    Future<void> scrollUntil(WidgetTester tester, Finder target, {int max = 60}) async {
      for (var i = 0; i < max && target.evaluate().isEmpty; i++) {
        await tester.drag(list(), const Offset(0, -700));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('page 1 on open; Prev/Next turn the pages (a small pair on top, a bar at the foot), up to the server\'s total', (tester) async {
      server
        ..rows = [for (var i = 0; i < 45; i++) _row(i)]
        ..stats = _stats(totalAudits: 45);
      await _pump(tester);

      expect(reads(), hasLength(1));
      expect(lastRead()['page'], 1);
      expect(lastRead()['limit'], 20);
      expect(find.text('45 reports'), findsOneWidget, reason: 'the server\'s total, not the 20 shown');
      expect(find.text('1/3'), findsOneWidget);
      expect(find.text('Audit 0'), findsOneWidget);
      expect(find.text('Audit 25'), findsNothing);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('nc-page-prev-top'))).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('nc-page-next-top')));
      await tester.pumpAndSettle();
      expect(lastRead()['page'], 2);
      expect(find.text('2/3'), findsOneWidget);
      expect(find.text('Audit 0'), findsNothing, reason: 'page 2 replaces page 1');
      expect(find.text('Audit 20'), findsOneWidget);

      await scrollUntil(tester, find.byKey(const ValueKey('nc-page-next')));
      expect(find.text('Page 2 of 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await tester.pumpAndSettle();
      expect(reads().map((r) => r.queryParameters['page']), [1, 2, 3]);
      expect(find.text('Audit 40'), findsOneWidget);
      expect(find.text('3/3'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('nc-page-next-top'))).onPressed, isNull, reason: 'nothing after the last page');
    });

    testWidgets('a page that fails keeps the rows and says so; Next tries it again', (tester) async {
      server
        ..rows = [for (var i = 0; i < 45; i++) _row(i)]
        ..stats = _stats(totalAudits: 45);
      var failures = 1;
      server.intercept = (o) {
        if (o.path == ApiConstants.auditsReport && o.queryParameters['page'] == 2 && failures-- > 0) {
          return Future.value(json(500, {'isOk': false, 'message': 'Server is busy'}));
        }
        return null;
      };
      await _pump(tester);

      await tester.tap(find.byKey(const ValueKey('nc-page-next-top')));
      await tester.pumpAndSettle();
      expect(find.text('Server is busy'), findsNothing, reason: 'the message sits at the foot');
      await scrollUntil(tester, find.byKey(const ValueKey('reports-more-error')));
      expect(find.text('Server is busy'), findsOneWidget);
      expect(find.text('Audit 19'), findsOneWidget, reason: 'the 20 that were showing are still there');
      expect(reads().where((r) => r.queryParameters['page'] == 2), hasLength(1));

      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await tester.pumpAndSettle();
      expect(reads().where((r) => r.queryParameters['page'] == 2), hasLength(2));
      expect(find.byKey(const ValueKey('reports-more-error')), findsNothing);
      expect(find.text('Audit 20'), findsOneWidget);
    });

    testWidgets('the chip, a tile and the search each reset to page 1 and send the right status / search', (tester) async {
      server
        ..rows = [
          for (var i = 0; i < 40; i++) _row(i),
          for (var i = 40; i < 45; i++) _row(i, timeliness: 'Delayed Completed'),
          for (var i = 45; i < 48; i++) _row(i, status: 'In Progress', display: 'Overdue', timeliness: null),
        ]
        ..stats = _stats(totalAudits: 48);
      // Tall enough for the tiles, the chips and the search, short enough that 20 cards
      // fill the rest (so nothing is read ahead on its own).
      await _pump(tester, height: 1000);
      expect(find.text('48 reports'), findsOneWidget);

      // The chip: the server filters, page 1 again, the tiles ask for the same population.
      final overdueChip = find.widgetWithText(ChoiceChip, 'Overdue');
      await tester.ensureVisible(overdueChip);
      await tester.pumpAndSettle();
      await tester.tap(overdueChip);
      await tester.pumpAndSettle();
      expect(lastRead()['status'], 'Overdue');
      expect(lastRead()['page'], 1);
      expect(statsReads().last.queryParameters['status'], 'Overdue');
      expect(find.text('3 reports'), findsOneWidget);
      expect(find.text('Audit 45'), findsOneWidget);
      expect(find.text('Audit 0'), findsNothing);

      // A tile: a `status`, not ids; the chip goes back to All (one status pick).
      await tester.tap(find.byKey(const ValueKey('report-tile-delayed')));
      await tester.pumpAndSettle();
      expect(lastRead()['status'], 'Delayed Completed');
      expect(lastRead()['page'], 1);
      expect(lastRead().containsKey('ids'), isFalse);
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All')).selected, isTrue);
      expect(statsReads().last.queryParameters.containsKey('status'), isFalse, reason: 'the tiles keep counting the whole set');
      expect(find.text('5 reports'), findsOneWidget);
      expect(find.text('Audit 40'), findsOneWidget);
      expect(find.text('Audit 45'), findsNothing);

      // Several tiles OR together.
      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await tester.pumpAndSettle();
      expect(lastRead()['status'], 'Overdue,Delayed Completed');
      expect(find.text('8 reports'), findsOneWidget);

      // A chip tap drops the tiles.
      final completedChip = find.widgetWithText(ChoiceChip, 'Completed');
      await tester.ensureVisible(completedChip);
      await tester.pumpAndSettle();
      await tester.tap(completedChip);
      await tester.pumpAndSettle();
      expect(lastRead()['status'], 'Completed');
      expect(find.text('45 reports'), findsOneWidget);

      // The search waits for typing to pause (~400 ms), then asks for page 1, once.
      final before = reads().length;
      await tester.enterText(find.byKey(const ValueKey('reports-search')), 'Au');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.enterText(find.byKey(const ValueKey('reports-search')), 'Audit 4');
      await tester.pump(const Duration(milliseconds: 399));
      expect(reads(), hasLength(before), reason: 'still typing');
      await tester.pump(const Duration(milliseconds: 5));
      await tester.pumpAndSettle();
      expect(reads(), hasLength(before + 1), reason: 'one request for the whole burst of typing');
      expect(lastRead()['search'], 'Audit 4');
      expect(lastRead()['status'], 'Completed');
      expect(lastRead()['page'], 1);
      expect(statsReads().last.queryParameters['search'], 'Audit 4');
      expect(find.text('6 reports'), findsOneWidget, reason: 'Audit 4 and Audit 40..44');
    });

    testWidgets('an empty answer for a chip says so (and is not "No reports yet")', (tester) async {
      server
        ..rows = [for (var i = 0; i < 3; i++) _row(i)]
        ..stats = _stats(totalAudits: 3);
      await _pump(tester);
      final chip = find.widgetWithText(ChoiceChip, 'NC Verification Pending');
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(lastRead()['status'], 'NC Verification Pending');
      expect(find.text('No audits are NC Verification Pending'), findsOneWidget);
      expect(find.text('No reports yet'), findsNothing);
    });
  });

  group('Reports screen: Group by location pages each place', () {
    Map<String, dynamic> plantStats(int n) => {
      ..._stats(totalAudits: n),
      'byLocation': [
        {
          'key': 'Plant A',
          'label': 'Plant A',
          'count': n,
          'percentage': 80,
          'achieved': 80,
          'maxPossible': 100,
          'auditIds': [for (var i = 0; i < n; i++) 'a$i'],
        },
      ],
    };

    Future<void> openPlace(WidgetTester tester) async {
      final grouping = find.widgetWithText(FilterChip, 'Group by location');
      await tester.ensureVisible(grouping);
      await tester.pumpAndSettle();
      await tester.tap(grouping);
      await tester.pumpAndSettle();
      expect(find.text('45 reports · 80%'), findsOneWidget, reason: 'the header is the server\'s');
      expect(reads().where((r) => r.queryParameters.containsKey('ids')), isEmpty, reason: 'nothing is read for a closed place');
      await tester.tap(find.text('Plant A'));
      await tester.pumpAndSettle();
    }

    List<String> placeReads() => [
      for (final r in reads())
        if (r.queryParameters.containsKey('ids')) '${r.queryParameters['ids']}',
    ];

    testWidgets('an opened place loads 20 of its audits; "Show more" loads the next 20, until they are all there', (tester) async {
      server
        ..rows = [for (var i = 0; i < 45; i++) _row(i)]
        ..stats = plantStats(45);
      await _pump(tester);
      await openPlace(tester);

      expect(placeReads(), hasLength(1));
      expect(placeReads().single.split(','), [for (var i = 0; i < 20; i++) 'a$i']);
      expect(find.text('Audit 19'), findsOneWidget);
      expect(find.text('Audit 20'), findsNothing);

      final more = find.byKey(const ValueKey('place-more-Plant A'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      expect(more, findsOneWidget);
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(placeReads(), hasLength(2));
      expect(placeReads().last.split(','), [for (var i = 20; i < 40; i++) 'a$i']);
      expect(find.text('Audit 39'), findsOneWidget);

      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      expect(placeReads().last.split(','), [for (var i = 40; i < 45; i++) 'a$i']);
      expect(find.text('Audit 44'), findsOneWidget);
      expect(more, findsNothing, reason: 'all 45 are there');

      // The flat list's own paging stays out of the way while the places page theirs.
      expect(reads().where((r) => r.queryParameters['page'] == 2), isEmpty);
    });

    testWidgets('a place whose next slice failed shows "Try again" under the rows already read', (tester) async {
      server
        ..rows = [for (var i = 0; i < 45; i++) _row(i)]
        ..stats = plantStats(45);
      await _pump(tester);
      await openPlace(tester);

      server.intercept = (o) => o.queryParameters.containsKey('ids') ? Future.value(json(500, {'isOk': false, 'message': 'Server is busy'})) : null;
      final more = find.byKey(const ValueKey('place-more-Plant A'));
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
      final retry = find.byKey(const ValueKey('place-retry-Plant A'));
      expect(retry, findsOneWidget);
      expect(find.text('Server is busy'), findsOneWidget);
      expect(find.text('Audit 19'), findsOneWidget, reason: 'the first 20 stay');

      server.intercept = null;
      await tester.ensureVisible(retry);
      await tester.pumpAndSettle();
      await tester.tap(retry);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('place-retry-Plant A')), findsNothing);
      expect(find.text('Audit 39'), findsOneWidget);
      expect(placeReads().last.split(','), [for (var i = 20; i < 40; i++) 'a$i'], reason: 'the same slice, asked again');
    });
  });
}

// ── Fake server ───────────────────────────────────────────────────────────

class _Server {
  List<Map<String, dynamic>> rows = [];
  Object? stats = _stats();

  /// Answers a request itself (to fail it, or to hold it back); null = the normal answer.
  Future<ResponseBody>? Function(RequestOptions options)? intercept;

  ResponseBody reportAnswer(RequestOptions o) => json(200, {'isOk': true, 'data': reportListData(rows, o.queryParameters)});

  Future<ResponseBody> handle(RequestOptions o) async {
    final held = intercept?.call(o);
    if (held != null) return held;
    switch (o.path) {
      case ApiConstants.auditsReport:
        return reportAnswer(o);
      case ApiConstants.auditsReportStats:
        return stats == null ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': stats});
      case ApiConstants.ncsReport:
        return json(200, {
          'isOk': true,
          'data': {'ncs': [], 'total': 0, 'page': 1, 'limit': 20},
        });
      case ApiConstants.ncsReportStats:
        return json(200, {'isOk': true, 'data': <String, dynamic>{}});
      case ApiConstants.ncsRepeats:
        return json(200, {
          'isOk': true,
          'data': {'rows': [], 'total': 0, 'page': 1, 'limit': 30, 'minCount': 2},
        });
      default:
        return json(200, {'isOk': true, 'data': []});
    }
  }
}

Map<String, dynamic> _row(
  int i, {
  String status = 'Completed',
  String? display,
  String? timeliness = 'On-Time Completed',
  String? batch,
}) => {
  '_id': 'a$i',
  'title': 'Audit $i',
  'scope': '',
  'status': status,
  'displayStatus': display ?? (status == 'Completed' ? 'Total Closed' : 'In Progress'),
  'timeliness': timeliness,
  'scheduleBatchId': ?batch,
  'scheduledDate': DateTime.now().toUtc().toIso8601String(),
  'completedDate': DateTime.now().toUtc().toIso8601String(),
  'scoreResult': {'achieved': 8, 'maxPossible': 10, 'percentage': 80},
  'locationIds': [],
};

/// What GET /audits/report/stats answers: [totalAudits] audits, all completed on time.
Map<String, dynamic> _stats({int totalAudits = 9}) => {
  'percentage': 80,
  'achieved': 80,
  'maxPossible': 100,
  'isPartial': false,
  'totalAudits': totalAudits,
  'total': totalAudits,
  'completed': totalAudits,
  'inProgress': 0,
  'onTimeCompleted': totalAudits,
  'delayedCompleted': 0,
  'completedIds': <String>[],
  'inProgressIds': <String>[],
  'onTimeIds': <String>[],
  'delayedIds': <String>[],
  'byLocation': [],
};

Future<void> _pump(WidgetTester tester, {double height = 800}) async {
  tester.view.physicalSize = Size(390, height);
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
