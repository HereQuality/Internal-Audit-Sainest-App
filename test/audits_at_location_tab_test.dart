import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/audits_at_location_list.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/audits/audit_detail_screen.dart';
import 'package:internal_audit_app/screens/nc/audits_at_location_tab.dart';
import 'package:internal_audit_app/screens/nc/nc_list_screen.dart';
import 'package:internal_audit_app/widgets/audit_filter_bar.dart';
import 'package:internal_audit_app/widgets/filter_sheet.dart';
import 'package:internal_audit_app/widgets/status_badge.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The Auditee's "Audit at My Location" tab on the phone: next to "NCs" on the auditee NC screen,
/// the audits scheduled at the signed-in person's places, read ONE PAGE (20) at a time from
/// GET /audits/at-my-location in its paged mode — one row per audit, `total` the number of audits —
/// with filters of its own (Location / Department, Audit type, Date range, Status, search).
/// Everything is answered by a fake server that filters and pages like the real one
/// (audit.controller.js#pagedAuditsAtMyLocation).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Server server;
  late FakeAdapter adapter;
  late FakeSockets sockets;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    server = _Server();
    adapter = FakeAdapter()..handler = server.handle;
    DioClient.instance.dio.httpClientAdapter = adapter;
    sockets = FakeSockets();
    SocketService.debugInstance = sockets.service;
  });

  /// The paged reads of the tab (the Calendar's unpaged one carries no `page`).
  List<RequestOptions> pagedReads() => [
    for (final r in adapter.requests)
      if (r.path.startsWith(ApiConstants.auditsAtMyLocation) && r.queryParameters.containsKey('page')) r,
  ];

  // ── the model ─────────────────────────────────────────────────────────────

  group('AuditModel reads what the tab shows', () {
    Map<String, dynamic> row(Map<String, dynamic> over) => {
      '_id': 'a1',
      'title': 'T',
      'status': 'Not Started',
      ...over,
    };

    test('people with ids: the legacy auditeeId and auditeeIds merged once, then "You"', () {
      final a = AuditModel.fromJson(row({
        'auditorIds': [
          {'_id': 'u1', 'employeeName': 'Asha'},
        ],
        'auditeeId': {'_id': 'u2', 'employeeName': 'Ravi'},
        'auditeeIds': [
          {'_id': 'u2', 'employeeName': 'Ravi'},
          {'_id': 'u3', 'employeeName': 'Meena', 'isActive': false},
        ],
      }));
      expect(a.auditeePeople.map((p) => p.name), ['Ravi', 'Meena']);
      expect(a.auditeePeople.last.inactive, isTrue);
      expect(a.hasAuditor('u1'), isTrue);
      expect(a.hasAuditor('u2'), isFalse);
      expect(a.hasAuditee('u3'), isTrue);
      expect(a.hasAuditee('u1'), isFalse);
      expect(a.hasAuditee(null), isFalse);
      expect(a.hasAuditor(''), isFalse);
    });

    test('places by name, a deleted place flagged; skip details; repeat marker', () {
      final a = AuditModel.fromJson(row({
        'locationIds': [
          {'_id': 'l1', 'name': 'Zone A'},
          {'_id': 'l2', 'name': 'Old Zone', '_removed': true},
        ],
        'departmentIds': [
          {'_id': 'd1', 'departmentName': 'Packing'},
          {'_id': 'd2'},
        ],
        'status': 'Skipped',
        'skipReason': 'Plant holiday',
        'skippedByName': 'Planner',
        'recurrence': {'frequency': 'Weekly'},
      }));
      expect(a.placeLabels, ['Zone A', 'Old Zone (deleted)', 'Packing', 'Unknown place']);
      expect(a.skipReason, 'Plant holiday');
      expect(a.skippedByName, 'Planner');
      expect(a.isRepeating, isTrue, reason: 'a frequency label alone marks a repeat');
      expect(AuditModel.fromJson(row({})).isRepeating, isFalse);
      expect(AuditModel.fromJson(row({'recurrence': {'seriesId': 's1'}})).isRepeating, isTrue);
    });
  });

  // ── the list state ────────────────────────────────────────────────────────

  group('AuditsAtLocationList', () {
    AuditsAtLocationList make({int Function()? epoch, VoidCallback? onChanged}) => AuditsAtLocationList(
      dio: DioClient.instance.dio,
      epoch: epoch ?? () => 0,
      onChanged: onChanged ?? () {},
    );

    test('the first request: page 1, limit 20, the default statuses, one row per audit (no groupBy)', () async {
      server.audits = _audits(5);
      final list = make();
      await list.loadFirst();

      final q = pagedReads().single.queryParameters;
      expect(q['page'], 1);
      expect(q['limit'], 20);
      expect(q['status'], 'Not Started,In Progress,Overdue');
      expect(q.containsKey('groupBy'), isFalse);
      expect(q.containsKey('search'), isFalse);
      expect(list.items.length, 5);
      expect(list.total, 5);
      expect(list.hasMore, isFalse);
    });

    test('filters travel as their own params; "All statuses" is spelled out', () async {
      server.audits = _audits(2);
      final list = make();
      list.setQuery(
        filters: AtLocationFilters(
          locationIds: const ['l1', 'l2'],
          departmentIds: const ['d1'],
          auditTypes: const ['Safety', 'GMP'],
          dateFrom: DateTime(2026, 11, 1),
          dateTo: DateTime(2026, 11, 30),
          statuses: const [],
        ),
        search: '  zone ',
      );
      await list.loadFirst();

      final q = pagedReads().single.queryParameters;
      expect(q['locationIds'], 'l1,l2');
      expect(q['departmentIds'], 'd1');
      expect(q['auditType'], 'Safety,GMP');
      expect(q['fromDate'], '2026-11-01');
      expect(q['toDate'], '2026-11-30');
      expect(q['search'], 'zone');
      expect(q['status'], 'Not Started,In Progress,Overdue,Delayed Completed,On-Time Completed,NC Response Pending,NC Verification Pending,Total Closed,Skipped');
    });

    test('page 2 is appended, the total stays the server\'s, the end is known', () async {
      server.audits = _audits(46);
      final list = make();
      await list.loadFirst();
      expect(list.items.length, 20);
      expect(list.total, 46);
      expect(list.hasMore, isTrue);

      await list.loadMore();
      expect(list.items.length, 40);
      expect(pagedReads().last.queryParameters['page'], 2);
      await list.loadMore();
      expect(list.items.length, 46);
      expect(list.hasMore, isFalse);
      expect([for (final a in list.items) a.id], [for (var i = 0; i < 46; i++) 'a$i'], reason: 'in the server\'s order, each once');
      await list.loadMore();
      expect(pagedReads().length, 3, reason: 'nothing left to ask');
    });

    test('a new query keeps the rows until its page 1 lands, and starts at page 1', () async {
      server.audits = _audits(46);
      final list = make();
      await list.loadFirst();
      await list.loadMore();
      expect(list.items.length, 40);

      expect(list.setQuery(search: 'Audit 4'), isTrue);
      expect(list.items.length, 40, reason: 'still on screen for the screen to dim');
      expect(list.hasLoaded, isFalse);
      await list.loadFirst();
      expect(pagedReads().last.queryParameters['page'], 1);
      expect(pagedReads().last.queryParameters['search'], 'Audit 4');
      expect(list.hasLoaded, isTrue);
      expect(list.items.every((a) => a.title.contains('Audit 4')), isTrue);
      expect(list.total, list.items.length);
      // Same query again: nothing moved.
      expect(list.setQuery(search: 'Audit 4'), isFalse);
    });

    test('an older answer that lands last does not replace the newer one', () async {
      server.audits = _audits(30);
      final slow = Completer<void>();
      server.holdIf = (q) => q['search'] == 'slow';
      server.gate = slow;
      final list = make();
      list.setQuery(search: 'slow');
      final old = list.loadFirst();
      await settle();
      list.setQuery(search: '');
      await list.loadFirst();
      expect(list.items.length, 20);
      slow.complete();
      await old;
      expect(list.items.length, 20);
      expect(list.search, '');
      expect(list.hasLoaded, isTrue);
    });

    test('a failed first page: rows of the same query stay with the error, rows of another query go', () async {
      server.audits = _audits(5);
      final list = make();
      await list.loadFirst();
      server.failPaged = true;
      await list.loadFirst();
      expect(list.error, isNotNull);
      expect(list.items.length, 5, reason: 'a failed refresh keeps what is shown');

      list.setQuery(search: 'x');
      await list.loadFirst();
      expect(list.error, isNotNull);
      expect(list.items, isEmpty, reason: 'another query\'s rows are not shown under these filters');
      expect(list.total, isNull);
    });

    test('a failed next page keeps the rows and offers a retry', () async {
      server.audits = _audits(30);
      final list = make();
      await list.loadFirst();
      server.failPaged = true;
      await list.loadMore();
      expect(list.moreError, isNotNull);
      expect(list.items.length, 20);
      final before = pagedReads().length;
      await list.loadMore();
      expect(pagedReads().length, before, reason: 'no hammering a server that is down');
      server.failPaged = false;
      await list.loadMore(retry: true);
      expect(list.items.length, 30);
      expect(list.moreError, isNull);
    });

    test('a live refresh re-reads the pages on screen and swaps them in', () async {
      server.audits = _audits(30);
      final list = make();
      await list.loadFirst();
      await list.loadMore();
      expect(list.items.length, 30);
      server.audits = [_audit(99, title: 'Brand new'), ..._audits(30)];
      final before = pagedReads().length;
      await list.refreshLoaded();
      expect(pagedReads().length - before, 2, reason: 'pages 1 and 2');
      expect(list.items.first.title, 'Brand new');
      expect(list.total, 31);
    });

    test('logout empties it and puts the default query back', () async {
      server.audits = _audits(5);
      final list = make();
      list.setQuery(search: 'a', filters: const AtLocationFilters(auditTypes: ['Safety']));
      await list.loadFirst();
      list.reset();
      expect(list.items, isEmpty);
      expect(list.search, '');
      expect(list.filters.isDefault, isTrue);
      expect(list.hasLoaded, isFalse);
    });

    test('an answer for an account that has signed out is dropped', () async {
      server.audits = _audits(5);
      var epoch = 0;
      final gate = Completer<void>();
      server.holdIf = (_) => true;
      server.gate = gate;
      final list = make(epoch: () => epoch);
      final load = list.loadFirst();
      await settle();
      epoch++;
      gate.complete();
      await load;
      expect(list.items, isEmpty);
    });

    test('AuditsProvider: the Calendar\'s unpaged read is unchanged and the tab\'s list is separate', () async {
      server.audits = _audits(4);
      final p = AuditsProvider();
      await p.fetchAuditsAtMyLocation();
      final unpaged = adapter.requests.where((r) => r.path.startsWith(ApiConstants.auditsAtMyLocation)).single;
      expect(unpaged.queryParameters.containsKey('page'), isFalse);
      expect(unpaged.queryParameters.containsKey('limit'), isFalse);
      expect(unpaged.queryParameters.containsKey('status'), isFalse);
      expect(p.auditsAtMyLocation.length, 4);
      expect(p.atLocationList.items, isEmpty);

      await p.atLocationList.loadFirst();
      expect(p.atLocationList.items.length, 4);
      expect(p.auditsAtMyLocation.length, 4);

      p.resetForLogout();
      expect(p.atLocationList.items, isEmpty);
    });

    test('filters: default, count, key', () {
      const d = AtLocationFilters();
      expect(d.isDefault, isTrue);
      expect(d.activeCount, 0);
      expect(const AtLocationFilters(statuses: ['Overdue', 'Not Started', 'In Progress']).isDefault, isTrue);
      expect(const AtLocationFilters(statuses: []).activeCount, 1);
      expect(const AtLocationFilters(locationIds: ['l1'], departmentIds: ['d1'], auditTypes: ['x']).activeCount, 2);
      expect(const AtLocationFilters(auditTypes: ['a', 'b']), const AtLocationFilters(auditTypes: ['b', 'a']));
    });
  });

  // ── the screen ────────────────────────────────────────────────────────────

  group('the auditee NC screen', () {
    late _Env env;

    setUp(() => env = _Env());
    tearDown(() => env.dispose());

    testWidgets('the tab appears on the auditee side, and not on the auditor side or the two-tab layout', (tester) async {
      await env.pump(tester, mode: NcListMode.auditeeOnly);
      expect(find.text('NCs'), findsOneWidget);
      expect(find.text('Audit at My Location'), findsOneWidget);
      // Lazy: an auditee who never opens it never asks the server for it.
      expect(pagedReads(), isEmpty);
      expect(find.byType(AuditsAtLocationTab), findsNothing);

      await env.pump(tester, mode: NcListMode.auditorOnly);
      expect(find.text('Audit at My Location'), findsNothing);
      expect(find.text('NCs'), findsNothing);

      await env.pump(tester, mode: null);
      expect(find.text('Audit at My Location'), findsNothing);
      expect(find.text('Raised by me'), findsOneWidget);
      expect(find.text('Against me'), findsOneWidget);
      expect(pagedReads(), isEmpty);
    });

    testWidgets('opening it reads page 1 with the default statuses and shows the total', (tester) async {
      server.audits = _audits(46);
      await env.openTab(tester);

      final q = pagedReads().single.queryParameters;
      expect(q['page'], 1);
      expect(q['limit'], 20);
      expect(q['status'], 'Not Started,In Progress,Overdue');
      expect(find.text('Showing 20 of 46 audits'), findsOneWidget);
      expect(find.byKey(const ValueKey('at-location-a0')), findsOneWidget);
      expect(find.textContaining('Audits still to come'), findsOneWidget);
    });

    testWidgets('rows show the real fields: title, type, places, people, "Self", dates, status, repeat, "You"', (tester) async {
      server.audits = [
        // I am an auditor; a repeat; a date range; two places; a named auditee.
        _audit(
          0,
          title: 'Line 1 GMP',
          extra: {
            'auditType': 'Safety',
            'displayStatus': 'In Progress',
            'status': 'In Progress',
            'scheduledEndDate': '2026-11-12T12:00:00.000Z',
            'locationIds': [
              {'_id': 'l1', 'name': 'Zone A'},
            ],
            'departmentIds': [
              {'_id': 'd1', 'departmentName': 'Packing'},
            ],
            'auditorIds': [
              {'_id': 'me', 'employeeName': 'Me Myself'},
              {'_id': 'u2', 'employeeName': 'Asha'},
            ],
            'auditeeIds': [
              {'_id': 'u3', 'employeeName': 'Ravi'},
            ],
            'recurrence': {'seriesId': 's1', 'frequency': 'Weekly'},
          },
        ),
        // A self audit that nobody on the screen is part of.
        _audit(
          1,
          title: 'Night walk',
          extra: {
            'auditorIds': [
              {'_id': 'u2', 'employeeName': 'Asha'},
            ],
            'auditeeIds': <Object>[],
            'selfAudit': true,
            'selfAuditReason': 'not_responding',
            'selfAuditRemark': 'Called twice',
          },
        ),
        // I am the auditee.
        _audit(
          2,
          title: 'Dock check',
          extra: {
            'displayStatus': 'Overdue',
            'auditorIds': [
              {'_id': 'u2', 'employeeName': 'Asha'},
            ],
            'auditeeIds': [
              {'_id': 'me', 'employeeName': 'Me Myself'},
            ],
          },
        ),
        // Skipped, with its remark.
        _audit(
          3,
          title: 'Holiday round',
          extra: {
            'status': 'Skipped',
            'displayStatus': 'Skipped',
            'skipReason': 'Plant holiday',
            'skippedByName': 'Planner',
          },
        ),
      ];
      // Skipped audits are listed once Skipped is among the statuses asked for.
      env.memory.screen('nc-at-location').extra['filters'] = const AtLocationFilters(statuses: [...kAtLocationDefaultStatuses, 'Skipped']);
      await env.openTab(tester);

      Finder inCard(String id, Finder f) => find.descendant(of: find.byKey(ValueKey('at-location-$id')), matching: f);

      // Card 0
      expect(inCard('a0', find.text('Line 1 GMP')), findsOneWidget);
      expect(inCard('a0', find.text('Safety')), findsOneWidget);
      expect(inCard('a0', find.text('Zone A')), findsOneWidget);
      expect(inCard('a0', find.text('Packing')), findsOneWidget);
      expect(inCard('a0', find.textContaining('Auditor: Me Myself (You), Asha')), findsOneWidget);
      expect(inCard('a0', find.textContaining('Auditee: Ravi')), findsOneWidget);
      expect(inCard('a0', find.text('10 Nov 2026 – 12 Nov 2026')), findsOneWidget);
      expect(inCard('a0', find.text('In Progress')), findsOneWidget);
      expect(inCard('a0', find.byType(StatusBadge)), findsOneWidget);
      expect(inCard('a0', find.byKey(const ValueKey('at-location-repeat'))), findsOneWidget);
      expect(inCard('a0', find.text('Weekly')), findsOneWidget);
      expect(inCard('a0', find.text('You · Auditor')), findsOneWidget);

      // Card 1: a self audit reads "Self" (and why), no mark, no repeat.
      expect(inCard('a1', find.textContaining('Auditee: Self')), findsOneWidget);
      expect(inCard('a1', find.text('Auditee not responding — Called twice')), findsOneWidget);
      expect(inCard('a1', find.byKey(const ValueKey('at-location-you'))), findsNothing);
      expect(inCard('a1', find.byKey(const ValueKey('at-location-repeat'))), findsNothing);
      expect(inCard('a1', find.text('10 Nov 2026')), findsOneWidget);

      // Card 2: I am the auditee.
      expect(inCard('a2', find.text('You · Auditee')), findsOneWidget);
      expect(inCard('a2', find.textContaining('Auditee: Me Myself (You)')), findsOneWidget);
      expect(inCard('a2', find.text('Overdue')), findsOneWidget);

      // Card 3: Skipped, with its remark.
      expect(inCard('a3', find.text('Skipped')), findsOneWidget);
      expect(inCard('a3', find.text('Plant holiday · Skipped by Planner')), findsOneWidget);
      expect(find.byKey(const ValueKey('at-location-you')), findsNWidgets(2));
    });

    testWidgets('scrolling near the end appends page 2 and then page 3; the total stays', (tester) async {
      server.audits = _audits(46);
      await env.openTab(tester);
      expect(find.text('Showing 20 of 46 audits'), findsOneWidget);

      await _scrollToEnd(tester);
      expect(pagedReads().map((r) => r.queryParameters['page']).toList(), [1, 2]);
      expect(find.text('Showing 40 of 46 audits'), findsOneWidget);

      await _scrollToEnd(tester);
      expect(pagedReads().map((r) => r.queryParameters['page']).toList(), [1, 2, 3]);
      expect(find.text('46 audits'), findsOneWidget);
      expect(env.audits.atLocationList.items.length, 46);
      await _scrollToEnd(tester);
      expect(find.text('Audit 45'), findsOneWidget, reason: 'the last row is on screen');
      expect(pagedReads().length, 3, reason: 'nothing more to ask');
    });

    testWidgets('a filter change starts again at page 1 and keeps the rows (dimmed) while it loads', (tester) async {
      server.audits = _audits(46);
      await env.openTab(tester);
      await _scrollToEnd(tester);
      expect(env.audits.atLocationList.items.length, 40);

      // Hold the answer of the new search to look at the screen in between.
      final gate = Completer<void>();
      server.gate = gate;
      server.holdIf = (q) => q['search'] == 'Audit 3';
      await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'Audit 3');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 300));

      final last = pagedReads().last.queryParameters;
      expect(last['page'], 1);
      expect(last['search'], 'Audit 3');
      expect(_opacityOfRows(tester), 0.5, reason: 'the rows are dimmed while the new ones load');
      expect(find.byType(AtLocationAuditCard), findsWidgets, reason: 'and still on screen');
      // Inert while dimmed.
      expect(tester.widget<IgnorePointer>(find.ancestor(of: find.byKey(const ValueKey('at-location-list')), matching: find.byType(IgnorePointer)).first).ignoring, isTrue);

      gate.complete();
      await _settle(tester);
      expect(_opacityOfRows(tester), 1);
      expect(find.descendant(of: find.byType(AtLocationAuditCard), matching: find.text('Audit 3')), findsOneWidget);
      expect(find.byKey(const ValueKey('at-location-a0')), findsNothing);
      // 3, 30..39 (the fake matches titles containing "Audit 3").
      expect(find.text('11 audits'), findsOneWidget);
    });

    testWidgets('the Filters sheet has no Team / Members / Flag, and a status pick goes to the server from page 1', (tester) async {
      server.audits = _audits(46, mixedStatus: true);
      await env.openTab(tester);
      await _scrollToEnd(tester);
      final before = pagedReads().length;

      await tester.tap(find.byType(FilterButton));
      await _settle(tester);
      expect(find.text('Filters'), findsWidgets);
      expect(find.text('Who'), findsNothing);
      expect(find.text('Team'), findsNothing);
      expect(find.text('Members'), findsNothing);
      expect(find.text('Flag'), findsNothing);
      expect(find.text('Include skipped / reassigned audits'), findsNothing);
      expect(find.text('Status'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget, reason: 'Skipped is a status chip on this tab');
      expect(find.text('Where'), findsOneWidget);
      expect(find.text('Audit Type'), findsOneWidget);
      expect(find.text('Date range'), findsOneWidget);
      // The default three are ticked, the rest are not.
      FilterChip chip(String label) => tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));
      expect(chip('Not Started').selected, isTrue);
      expect(chip('In Progress').selected, isTrue);
      expect(chip('Overdue').selected, isTrue);
      expect(chip('Total Closed').selected, isFalse);
      // The default is not an active filter.
      expect(find.text('Apply'), findsOneWidget);

      await tester.ensureVisible(find.widgetWithText(FilterChip, 'Total Closed'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, 'Total Closed'));
      await tester.pump();
      await tester.tap(find.textContaining('Apply'));
      await _settle(tester);

      expect(pagedReads().length, before + 1);
      final q = pagedReads().last.queryParameters;
      expect(q['page'], 1);
      expect(q['status'], 'Not Started,In Progress,Overdue,Total Closed');
      // The list is the new query's, from the top: finished audits are listed newest first.
      expect(find.byKey(const ValueKey('at-location-a45')), findsOneWidget);
      // One pill per status now asked for (the row scrolls sideways, so the last may be off screen), and a Clear.
      expect(find.widgetWithText(FilterPill, 'Not Started'), findsOneWidget);
      expect(find.byKey(const ValueKey('at-location-clear')), findsOneWidget);
      expect(tester.widget<FilterButton>(find.byType(FilterButton)).activeCount, 1);
    });

    testWidgets('Clear and a pill go back to the default statuses (page 1 again)', (tester) async {
      server.audits = _audits(10, mixedStatus: true);
      env.memory.screen('nc-at-location').extra['filters'] = const AtLocationFilters(statuses: ['Total Closed', 'Overdue']);
      await env.openTab(tester);
      expect(pagedReads().first.queryParameters['status'], 'Total Closed,Overdue');
      expect(find.widgetWithText(FilterPill, 'Total Closed'), findsOneWidget);
      expect(find.widgetWithText(FilterPill, 'Overdue'), findsOneWidget);

      // Removing one pill keeps the other.
      await tester.tap(find.widgetWithText(FilterPill, 'Total Closed'));
      await _settle(tester);
      expect(pagedReads().last.queryParameters['status'], 'Overdue');
      // Removing the last status goes back to the default, not to "everything".
      await tester.tap(find.widgetWithText(FilterPill, 'Overdue'));
      await _settle(tester);
      expect(pagedReads().last.queryParameters['status'], 'Not Started,In Progress,Overdue');
      expect(find.byKey(const ValueKey('at-location-clear')), findsNothing);

      await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'Audit');
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.byKey(const ValueKey('at-location-clear')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('at-location-clear')));
      await _settle(tester);
      expect(pagedReads().last.queryParameters.containsKey('search'), isFalse);
      expect(find.byKey(const ValueKey('at-location-clear')), findsNothing);
      expect(tester.widget<TextField>(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField))).controller!.text, '');
    });

    testWidgets('the empty state says no audits match, and offers a way out when filtered', (tester) async {
      server.audits = [];
      await env.openTab(tester);
      expect(find.text('No audits at your locations match'), findsOneWidget);
      expect(find.textContaining('Nothing is scheduled at your places'), findsOneWidget);
      expect(find.text('Clear filters'), findsNothing);

      await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'zzz');
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.text('No audits at your locations match'), findsOneWidget);
      expect(find.textContaining('Try widening'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await _settle(tester);
      expect(pagedReads().last.queryParameters.containsKey('search'), isFalse);
    });

    testWidgets('loading shows a spinner; an error shows the message with Retry, and Retry reads again', (tester) async {
      server.audits = _audits(3);
      final gate = Completer<void>();
      server.gate = gate;
      server.holdIf = (_) => true;
      await env.pump(tester, mode: NcListMode.auditeeOnly);
      await tester.tap(find.byKey(const ValueKey('nc-view-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      gate.complete();
      await _settle(tester);
      expect(find.text('Audit 0'), findsOneWidget);

      // Now a failing server, on a fresh query.
      server.failPaged = true;
      server.holdIf = null;
      await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'x');
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Boom'), findsOneWidget);
      expect(find.text('Audit 0'), findsNothing, reason: 'another query\'s rows are not left under the error');

      server.failPaged = false;
      final before = pagedReads().length;
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(pagedReads().length, before + 1);
      expect(find.text('Something went wrong'), findsNothing);
    });

    testWidgets('a refresh that fails keeps the rows and says so', (tester) async {
      server.audits = _audits(3);
      await env.openTab(tester);
      server.failPaged = true;
      await tester.fling(find.byKey(const ValueKey('at-location-list')), const Offset(0, 400), 1000);
      await _settle(tester);
      expect(find.text('Audit 0'), findsOneWidget);
      expect(find.text('Boom'), findsOneWidget);
      expect(find.byKey(const ValueKey('at-location-refresh-retry')), findsOneWidget);

      server.failPaged = false;
      await tester.tap(find.byKey(const ValueKey('at-location-refresh-retry')));
      await _settle(tester);
      expect(find.text('Boom'), findsNothing);
    });

    testWidgets('pull-to-refresh reads page 1 again', (tester) async {
      server.audits = _audits(3);
      await env.openTab(tester);
      final before = pagedReads().length;
      server.audits = [..._audits(3), _audit(7, title: 'Late arrival')];
      await tester.fling(find.byKey(const ValueKey('at-location-list')), const Offset(0, 400), 1000);
      await _settle(tester);
      expect(pagedReads().length, before + 1);
      expect(pagedReads().last.queryParameters['page'], 1);
      expect(find.text('Late arrival'), findsOneWidget);
      expect(find.text('4 audits'), findsOneWidget);
    });

    testWidgets('an audit_ notification refreshes the pages on screen', (tester) async {
      server.audits = _audits(25);
      await env.openTab(tester);
      SocketService.instance.connect('jwt');
      env.audits.startListening();
      await _scrollToEnd(tester);
      expect(env.audits.atLocationList.items.length, 25);
      final before = pagedReads().length;

      server.audits = [_audit(90, title: 'Rescheduled visit'), ..._audits(25)];
      sockets.sockets.last.receive('new_notification', {'type': 'audit_created'});
      await tester.pump(const Duration(milliseconds: 700));
      await _settle(tester);

      expect(pagedReads().length - before, 2, reason: 'pages 1 and 2 re-read');
      expect(env.audits.atLocationList.items.first.title, 'Rescheduled visit');
      // Another kind of notification does not.
      final after = pagedReads().length;
      sockets.sockets.last.receive('new_notification', {'type': 'nc_raised'});
      await tester.pump(const Duration(milliseconds: 700));
      expect(pagedReads().length, after);
    });

    testWidgets('a tap opens the audit', (tester) async {
      server.audits = _audits(3);
      await env.openTab(tester);
      await tester.tap(find.byKey(const ValueKey('at-location-a1')));
      await _settle(tester);
      expect(find.byType(AuditDetailScreen), findsOneWidget);
      expect(tester.widget<AuditDetailScreen>(find.byType(AuditDetailScreen)).auditId, 'a1');
      expect(adapter.requests.where((r) => r.method == 'GET' && r.path == ApiConstants.auditById('a1')), isNotEmpty);
    });

    testWidgets('the view, the filters, the search and the scroll position are remembered across a remount', (tester) async {
      server.audits = _audits(46);
      await env.openTab(tester);
      await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'Audit 1');
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(env.memory.screen('nc-at-location').search, 'Audit 1');
      expect(env.memory.screen('nc-against-view').tab, 1);

      await tester.pumpWidget(const SizedBox());
      await env.pump(tester, mode: NcListMode.auditeeOnly);
      // Opens on the same view with the same search, without a tap.
      expect(find.byType(AuditsAtLocationTab), findsOneWidget);
      expect(tester.widget<TextField>(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField))).controller!.text, 'Audit 1');
      expect(pagedReads().last.queryParameters['search'], 'Audit 1');

      // A dashboard tile jump is about NCs: it opens on the NCs view.
      await tester.pumpWidget(const SizedBox());
      await env.pump(tester, mode: NcListMode.auditeeOnly, initialStatusFilter: 'Overdue');
      expect(find.byType(AuditsAtLocationTab).hitTestable(), findsNothing);
      expect(env.memory.screen('nc-against-view').tab, 0);
    });

    testWidgets('switching back to NCs and forth again does not reload the audits', (tester) async {
      server.audits = _audits(3);
      await env.openTab(tester);
      await tester.tap(find.byKey(const ValueKey('nc-view-0')));
      await _settle(tester);
      expect(env.audits.atLocationList.inUse, isFalse, reason: 'a hidden view does not answer live updates');
      final before = pagedReads().length;
      await tester.tap(find.byKey(const ValueKey('nc-view-1')));
      await _settle(tester);
      expect(env.audits.atLocationList.inUse, isTrue);
      // Coming back catches up with what moved meanwhile: one quiet re-read of the pages on screen.
      expect(pagedReads().length - before, 1);
      expect(find.text('Audit 0'), findsOneWidget);
    });

    testWidgets('the Calendar\'s own list is not touched by the tab', (tester) async {
      server.audits = _audits(3);
      await env.openTab(tester);
      expect(env.audits.auditsAtMyLocation, isEmpty);
      expect(adapter.requests.where((r) => r.path.startsWith(ApiConstants.auditsAtMyLocation) && !r.queryParameters.containsKey('page')), isEmpty);
    });
  });

  // ── layout ────────────────────────────────────────────────────────────────

  group('layout', () {
    late _Env env;

    setUp(() => env = _Env());
    tearDown(() => env.dispose());

    // Long everything: a long title, many places and people, the longest status, a repeat, "You" as both.
    List<Map<String, dynamic>> longRows() => [
      _audit(
        0,
        title: 'Quarterly cross-functional hygiene, housekeeping and fire-safety compliance walk-through of the whole packing hall',
        extra: {
          'auditType': 'Cross Functional Team Audit',
          'status': 'Completed',
          'displayStatus': 'NC Verification Pending',
          'timeliness': 'Delayed Completed',
          'scheduledEndDate': '2026-12-31T12:00:00.000Z',
          'locationIds': [
            for (var i = 0; i < 4; i++) {'_id': 'l$i', 'name': 'North Wing Zone $i — Cold Storage and Dispatch Annex'},
          ],
          'departmentIds': [
            {'_id': 'd1', 'departmentName': 'Quality Assurance and Regulatory Affairs'},
          ],
          'auditorIds': [
            {'_id': 'me', 'employeeName': 'Me Myself'},
            {'_id': 'u2', 'employeeName': 'Venkataraghavan Subramaniam', 'isActive': false},
            {'_id': 'u4', 'employeeName': 'Jyotirmoy Bhattacharya-Chatterjee'},
          ],
          'auditeeIds': [
            {'_id': 'me', 'employeeName': 'Me Myself'},
            {'_id': 'u3', 'employeeName': 'Lakshmi Narayanan Ramachandran'},
          ],
          'recurrence': {'seriesId': 's1', 'frequency': 'Fortnightly'},
        },
      ),
      _audit(1, extra: {'selfAudit': true, 'selfAuditReason': 'not_available', 'selfAuditRemark': 'On leave until the end of the month, called twice and left a message', 'auditeeIds': <Object>[]}),
      _audit(2, extra: {'displayStatus': 'Overdue', 'status': 'In Progress'}),
    ].reversed.toList(); // "All statuses" lists newest first, so the long row comes first

    for (final dark in [false, true]) {
      for (final width in [320.0, 360.0, 390.0]) {
        for (final scale in [1.0, 1.6]) {
          testWidgets('no overflow at ${width.toInt()} px, text x$scale, ${dark ? 'dark' : 'light'}: rows, header, empty, error, sheet', (tester) async {
            server.audits = longRows();
            // "All statuses": the long NC Verification Pending row is listed, and the pill row is on.
            env.memory.screen('nc-at-location').extra['filters'] = const AtLocationFilters(statuses: []);
            await env.openTab(tester, width: width, height: 640, textScale: scale, dark: dark);
            expect(find.byKey(const ValueKey('at-location-a0')), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'rows');

            // A filter pill row (Clear + pills) under the same constraints.
            await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'quarterly');
            await tester.pump(const Duration(milliseconds: 500));
            await _settle(tester);
            expect(find.byKey(const ValueKey('at-location-clear')), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'header with Clear');

            // Scroll the long rows.
            await tester.drag(find.byKey(const ValueKey('at-location-list')), const Offset(0, -400));
            await tester.pump();
            expect(tester.takeException(), isNull, reason: 'scrolled');

            // Empty.
            server.audits = [];
            await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'nothing');
            await tester.pump(const Duration(milliseconds: 500));
            await _settle(tester);
            expect(find.text('No audits at your locations match'), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'empty');

            // Error.
            server.failPaged = true;
            await tester.enterText(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField)), 'boom');
            await tester.pump(const Duration(milliseconds: 500));
            await _settle(tester);
            expect(find.text('Something went wrong'), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'error');

            // The filter sheet.
            await tester.tap(find.byType(FilterButton));
            await _settle(tester);
            expect(find.text('Status'), findsOneWidget);
            expect(tester.takeException(), isNull, reason: 'sheet');
          });
        }
      }
    }

    testWidgets('touch targets are at least 44 px: the view switch, search, Filters, Clear, a pill, the card', (tester) async {
      server.audits = longRows();
      env.memory.screen('nc-at-location').extra['filters'] = const AtLocationFilters(auditTypes: ['Safety'], statuses: []);
      await env.openTab(tester, width: 320, height: 700);

      double h(Finder f) => tester.getSize(f.first).height;
      double w(Finder f) => tester.getSize(f.first).width;
      expect(h(find.byKey(const ValueKey('nc-view-0'))), greaterThanOrEqualTo(48));
      expect(h(find.byKey(const ValueKey('nc-view-1'))), greaterThanOrEqualTo(48));
      expect(h(find.descendant(of: find.byType(AuditsAtLocationTab), matching: find.byType(TextField))), greaterThanOrEqualTo(44));
      expect(h(find.byType(FilterButton)), greaterThanOrEqualTo(44));
      expect(h(find.byKey(const ValueKey('at-location-clear'))), greaterThanOrEqualTo(44));
      expect(w(find.byKey(const ValueKey('at-location-clear'))), greaterThanOrEqualTo(44));
      final pill = find.widgetWithText(FilterPill, 'Safety');
      expect(pill, findsOneWidget);
      expect(h(find.descendant(of: pill, matching: find.byType(InkWell))), greaterThanOrEqualTo(44));
      expect(h(find.byKey(const ValueKey('at-location-a0'))), greaterThanOrEqualTo(44));
      // The pill's touch area really removes it.
      await tester.tapAt(tester.getTopRight(find.descendant(of: pill, matching: find.byType(InkWell))) + const Offset(-6, 22));
      await _settle(tester);
      expect(find.widgetWithText(FilterPill, 'Safety'), findsNothing);
    });

    testWidgets('the compact pills of the other lists are unchanged (no tap height)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: FilterPill(label: 'Team A', onRemove: () {})),
          ),
        ),
      );
      final size = tester.getSize(find.byType(InkWell));
      expect(size.height, lessThan(40));
    });
  });
}

// ── helpers ──────────────────────────────────────────────────────────────────

double _opacityOfRows(WidgetTester tester) => tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('at-location-rows'))).opacity;

// A paged list keeps a small spinner at its foot while more pages are left, so pumpAndSettle never settles
// on it: pump a fixed span of time instead (long enough for any fake answer and animation).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  await tester.drag(find.byKey(const ValueKey('at-location-list')), const Offset(0, -9000));
  await _settle(tester);
}

class _Env {
  final audits = AuditsProvider()..setSelfEmployeeId('me');
  final ncs = NcProvider()..setSelfEmployeeId('me');
  final memory = ListViewMemory();
  final auth = AuthProvider()..user = UserModel.fromJson({'_id': 'me', 'roleType': 'Employee', 'employeeName': 'Me Myself'});
  final options = FilterOptionsProvider();
  final dashboard = DashboardProvider();

  Future<void> pump(
    WidgetTester tester, {
    NcListMode? mode = NcListMode.auditeeOnly,
    String? initialStatusFilter,
    double width = 390,
    double height = 900,
    double textScale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuditsProvider>.value(value: audits),
          ChangeNotifierProvider<NcProvider>.value(value: ncs),
          ChangeNotifierProvider<DashboardProvider>.value(value: dashboard),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<FilterOptionsProvider>.value(value: options),
          ChangeNotifierProvider<ListViewMemory>.value(value: memory),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          // A fresh State per pump (the app never changes the mode of a mounted NcListScreen).
          home: Scaffold(body: NcListScreen(key: UniqueKey(), mode: mode, initialStatusFilter: initialStatusFilter)),
        ),
      ),
    );
    await _settle(tester);
  }

  /// The auditee NC screen with the "Audit at My Location" view opened.
  Future<void> openTab(
    WidgetTester tester, {
    double width = 390,
    double height = 900,
    double textScale = 1,
    bool dark = false,
  }) async {
    await pump(tester, width: width, height: height, textScale: textScale, dark: dark);
    await tester.tap(find.byKey(const ValueKey('nc-view-1')));
    await _settle(tester);
  }

  void dispose() {
    audits.dispose();
    ncs.dispose();
    memory.dispose();
    auth.dispose();
    options.dispose();
    dashboard.dispose();
  }
}

/// One row of GET /audits/at-my-location.
Map<String, dynamic> _audit(int i, {String? title, Map<String, dynamic> extra = const {}}) => {
  '_id': 'a$i',
  'title': title ?? 'Audit $i',
  'status': 'Not Started',
  'displayStatus': 'Not Started',
  'scheduledDate': '2026-11-10T12:00:00.000Z',
  'locationIds': [
    {'_id': 'l1', 'name': 'Zone A'},
  ],
  'departmentIds': <Object>[],
  'auditorIds': [
    {'_id': 'u2', 'employeeName': 'Asha'},
  ],
  'auditeeIds': [
    {'_id': 'u3', 'employeeName': 'Ravi'},
  ],
  ...extra,
};

List<Map<String, dynamic>> _audits(int n, {bool mixedStatus = false}) => [
  for (var i = 0; i < n; i++)
    _audit(
      i,
      extra: mixedStatus && i.isOdd ? {'status': 'Completed', 'displayStatus': 'Total Closed'} : const {},
    ),
];

/// Filters and pages like pagedAuditsAtMyLocation: `status` (a csv of display statuses), `search` on the title,
/// open statuses nearest first (the stored order) and the rest newest first, a page past the end serves the last.
class _Server {
  List<Map<String, dynamic>> audits = [];
  bool failPaged = false;

  /// When [holdIf] says so for a paged request, the answer waits for [gate].
  bool Function(Map<String, dynamic> query)? holdIf;
  Completer<void>? gate;

  /// What a request without `status` is answered with (the server's own default).
  List<String> defaultStatuses = ['Not Started', 'In Progress', 'Overdue'];

  static const _open = {'Not Started', 'In Progress', 'Overdue'};

  Future<ResponseBody> handle(RequestOptions o) async {
    if (o.path.startsWith(ApiConstants.auditsAtMyLocation)) {
      final q = o.queryParameters;
      if (!q.containsKey('page') && !q.containsKey('limit')) {
        // The Calendar's read: the plain array.
        return json(200, {'isOk': true, 'data': audits});
      }
      if (holdIf != null && holdIf!(q) && gate != null) await gate!.future;
      if (failPaged) return json(500, {'isOk': false, 'message': 'Boom'});
      final statuses = q['status'] == null ? defaultStatuses : (q['status'] as String).split(',');
      final search = (q['search'] ?? '').toString().toLowerCase();
      var rows = [
        for (final a in audits)
          if (statuses.contains(a['displayStatus']) && (search.isEmpty || (a['title'] as String).toLowerCase().contains(search))) a,
      ];
      if (!statuses.every(_open.contains)) rows = rows.reversed.toList();
      final limit = int.parse('${q['limit']}');
      final pages = math.max(1, (rows.length / limit).ceil());
      final served = math.min(int.parse('${q['page']}'), pages);
      return json(200, {
        'isOk': true,
        'data': {
          'audits': rows.skip((served - 1) * limit).take(limit).toList(),
          'total': rows.length,
          'page': served,
          'pages': pages,
          'limit': limit,
        },
      });
    }
    if (o.path.startsWith(ApiConstants.auditById('')) && o.method == 'GET') {
      return json(404, {'isOk': false, 'message': 'Audit not found'});
    }
    // Everything else the NC screen and the filter sheet read: an empty page / list.
    return json(200, {
      'isOk': true,
      'data': {'ncs': <Object>[], 'total': 0, 'page': 1, 'limit': 20},
    });
  }
}
