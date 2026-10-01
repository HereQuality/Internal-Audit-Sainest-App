import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/nc/nc_list_screen.dart';
import 'package:internal_audit_app/screens/reports/nc_report_tab.dart';
import 'package:internal_audit_app/screens/reports/repeated_ncs_tab.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The NC lists are read ONE PAGE (20) at a time: NC Monitoring ("raised by me"),
/// the auditee's "against me", the Final Report's NCs tab (20 audits a page, and
/// each opened place of its location-wise view) and the Repeated NCs tab (30 groups
/// a page). The first page loads on open / on a chip, tile, search or filter change
/// / on pull-to-refresh; the next ones as the user scrolls near the end; the status
/// chip, the search and the tile picks are the server's. Everything here is
/// answered by a fake server that filters and pages like the real one
/// (nc.controller.js: getRaisedNCs / getMyNCs / getReportNCs / getRepeatFindings).
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

  List<RequestOptions> reads(String path) => adapter.requests.where((r) => r.path == path).toList();
  NcProvider provider() => NcProvider()..setSelfEmployeeId('me');
  List<String> idsOf(Iterable<dynamic> ncs) => [for (final n in ncs) n.id as String];

  group('NC Monitoring / Against me: one page at a time', () {
    test('the first request is page 1 with limit 20 — one page, not everything', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();

      final q = reads(ApiConstants.ncsRaised).single.queryParameters;
      expect(q['page'], 1);
      expect(q['limit'], 20);
      expect(q['employeeIds'], 'me');
      expect(q.containsKey('ids'), isFalse);
      expect(q.containsKey('status'), isFalse);
      expect(p.raisedByMe, hasLength(20));
      expect(p.raisedByMe.first.id, 'nc900');
      expect(p.raisedList.total, 45, reason: 'the count is the server\'s, not what was loaded');
      expect(p.raisedList.hasMore, isTrue);
      expect(p.isLoadingRaised, isFalse);

      await p.fetchAgainstMe();
      final m = reads(ApiConstants.ncsMine).single.queryParameters;
      expect(m['page'], 1);
      expect(m['limit'], 20);
      expect(p.raisedAgainstMe, hasLength(20));
      expect(p.mineList.total, 45);
    });

    test('loadMore appends the next page, and stops when the server\'s total is on screen', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();

      await p.raisedList.loadMore();
      expect(reads(ApiConstants.ncsRaised).last.queryParameters['page'], 2);
      expect(p.raisedByMe, hasLength(40));
      expect(p.raisedList.hasMore, isTrue);

      await p.raisedList.loadMore();
      expect(reads(ApiConstants.ncsRaised).last.queryParameters['page'], 3);
      expect(p.raisedByMe, hasLength(45));
      expect(p.raisedList.hasMore, isFalse);
      expect(idsOf(p.raisedByMe).toSet(), hasLength(45), reason: 'no NC twice');
      expect(idsOf(p.raisedByMe), [for (var i = 0; i < 45; i++) 'nc${900 - i}'], reason: 'newest first, page after page');

      final before = reads(ApiConstants.ncsRaised).length;
      await p.raisedList.loadMore();
      expect(reads(ApiConstants.ncsRaised), hasLength(before), reason: 'nothing left: no request');
    });

    test('a loadMore while one is on the wire does not send a second request', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();

      final held = Completer<void>();
      server.gate = (o) => o.queryParameters['page'] == 2 ? held.future : Future<void>.value();
      final a = p.raisedList.loadMore();
      final b = p.raisedList.loadMore();
      await settle();
      expect(reads(ApiConstants.ncsRaised).where((r) => r.queryParameters['page'] == 2), hasLength(1));
      expect(p.raisedList.isLoadingMore, isTrue);

      held.complete();
      await Future.wait([a, b]);
      expect(p.raisedByMe, hasLength(40));
      expect(p.raisedList.isLoadingMore, isFalse);
    });

    test('a status chip is sent as `status`, the search as `search`, and each restarts at page 1', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();
      await p.raisedList.loadMore();
      expect(p.raisedByMe, hasLength(40));

      expect(p.raisedList.setNarrowing(chip: 'Closed'), isTrue);
      expect(p.raisedByMe, isEmpty, reason: 'what was loaded belongs to the previous chip');
      await p.fetchRaisedByMe(fresh: false);
      var q = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect(q['status'], 'Closed');
      expect(q['page'], 1);
      expect(q['limit'], 20);
      expect(q.containsKey('ids'), isFalse);
      expect(p.raisedByMe, hasLength(15));
      expect(p.raisedByMe.every((n) => n.status == 'Closed'), isTrue);
      expect(p.raisedList.total, 15);
      expect(p.raisedList.hasMore, isFalse);

      expect(p.raisedList.setNarrowing(chip: 'Closed'), isFalse, reason: 'the same chip is not a change');
      expect(p.raisedList.setNarrowing(search: 'finding 3'), isTrue);
      await p.fetchRaisedByMe(fresh: false);
      q = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect(q['search'], 'finding 3');
      expect(q['status'], 'Closed', reason: 'chip and search narrow together');
      expect(q['page'], 1);
      expect(p.raisedByMe, isNotEmpty);
      expect(p.raisedByMe.every((n) => n.title.toLowerCase().contains('finding 3') && n.status == 'Closed'), isTrue);
      expect(p.raisedList.total, p.raisedByMe.length);

      // Back to nothing: the plain list again.
      p.raisedList.setNarrowing(chip: 'All', search: '');
      await p.fetchRaisedByMe(fresh: false);
      q = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect(q.containsKey('status'), isFalse);
      expect(q.containsKey('search'), isFalse);
      expect(p.raisedByMe, hasLength(20));
    });

    test('Open means every stored status but Closed: three statuses on the auditor side, `open=true` on the auditee side', () async {
      server.ncs = _ncs(45);
      final p = provider();
      p.raisedList.setNarrowing(chip: 'Open');
      p.mineList.setNarrowing(chip: 'Open');
      await Future.wait([p.fetchRaisedByMe(), p.fetchAgainstMe()]);

      final raised = reads(ApiConstants.ncsRaised).single.queryParameters;
      expect(raised['status'], 'Raised,Response Submitted,Verification');
      expect(raised.containsKey('open'), isFalse);
      final mine = reads(ApiConstants.ncsMine).single.queryParameters;
      expect(mine['open'], 'true');
      expect(mine.containsKey('status'), isFalse);
      expect(p.raisedList.total, 30);
      expect(p.mineList.total, 30);
      expect(p.raisedByMe.any((n) => n.status == 'Closed'), isFalse);
    });

    test('a bucket chip is read by the ids the tile counted, 20 at a time — short URLs however big the bucket', () async {
      server.ncs = _ncs(90); // 30 of them Overdue
      final p = provider();
      await Future.wait([p.fetchRaisedByMe(), p.fetchRaisedStats()]);
      expect(reads(ApiConstants.ncsRaisedStats), hasLength(1));

      p.raisedList.setNarrowing(chip: 'Overdue');
      await p.fetchRaisedByMe(fresh: false);
      expect(reads(ApiConstants.ncsRaisedStats), hasLength(1), reason: 'the tile ids already held are re-used');
      var q = reads(ApiConstants.ncsRaised).last.queryParameters;
      final ids = '${q['ids']}'.split(',');
      expect(ids, hasLength(20), reason: 'one page of ids, not all 30');
      expect(ids, [for (var i = 1; i < 60; i += 3) 'nc${900 - i}'], reason: 'newest first, whatever order the stats listed them in');
      expect(q.containsKey('page'), isFalse);
      expect(q.containsKey('status'), isFalse);
      expect(p.raisedByMe, hasLength(20));
      expect(p.raisedByMe.every((n) => n.bucket == 'overdue'), isTrue);
      expect(p.raisedList.total, 30, reason: 'the tile\'s own number');
      expect(p.raisedList.hasMore, isTrue);

      await p.raisedList.loadMore();
      q = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect('${q['ids']}'.split(','), hasLength(10));
      expect(p.raisedByMe, hasLength(30));
      expect(p.raisedList.hasMore, isFalse);

      // A filter change (fresh) asks for the ids again.
      await p.fetchRaisedByMe();
      expect(reads(ApiConstants.ncsRaisedStats), hasLength(2));
    });

    test('a bucket chip with a search asks the stats to narrow the ids too (auditor side), and the auditee side searches on each slice', () async {
      server.ncs = _ncs(90);
      final p = provider();
      p.raisedList.setNarrowing(chip: 'Overdue', search: 'finding 4');
      await p.fetchRaisedByMe();
      final stats = reads(ApiConstants.ncsRaisedStats).single.queryParameters;
      expect(stats['search'], 'finding 4');
      var q = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect(q.containsKey('search'), isFalse, reason: 'the ids already are the search\'s answer');
      expect(p.raisedList.total, p.raisedByMe.length);
      expect(p.raisedByMe.every((n) => n.bucket == 'overdue' && n.title.toLowerCase().contains('finding 4')), isTrue);

      // The auditee's buckets come from /ncs/ats-summary, which has no search.
      p.mineList.setNarrowing(chip: 'Overdue', search: 'finding 4');
      await p.fetchAgainstMe();
      expect(reads(ApiConstants.ncsAtsSummary).single.queryParameters.containsKey('search'), isFalse);
      q = reads(ApiConstants.ncsMine).last.queryParameters;
      expect(q['search'], 'finding 4', reason: 'each slice of ids is searched by the server');
      expect(p.mineList.total, p.raisedAgainstMe.length);
      expect(p.raisedAgainstMe, isNotEmpty);
      expect(p.raisedAgainstMe.every((n) => n.bucket == 'overdue' && n.title.toLowerCase().contains('finding 4')), isTrue);
    });

    test('a page that lands after the chip changed is dropped', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();

      final held = Completer<void>();
      server.gate = (o) => o.queryParameters['page'] == 2 && !o.queryParameters.containsKey('status')
          ? held.future
          : Future<void>.value();
      final more = p.raisedList.loadMore();
      await settle();
      expect(p.raisedList.isLoadingMore, isTrue);

      p.raisedList.setNarrowing(chip: 'Closed');
      await p.fetchRaisedByMe(fresh: false);
      expect(p.raisedByMe, hasLength(15));

      held.complete(); // the old chip's page 2 lands last
      await more;
      expect(p.raisedByMe, hasLength(15), reason: 'the stale page was not appended');
      expect(p.raisedByMe.every((n) => n.status == 'Closed'), isTrue);
      expect(p.raisedList.total, 15);
      expect(p.raisedList.isLoadingMore, isFalse);
      expect(p.raisedList.moreError, isNull);
    });

    test('a first page that lands after a newer search was typed is dropped, with its loading flag', () async {
      server.ncs = _ncs(45);
      final p = provider();
      final slow = Completer<void>();
      server.gate = (o) => o.queryParameters['search'] == 'finding 4' ? slow.future : Future<void>.value();

      p.raisedList.setNarrowing(search: 'finding 4');
      final first = p.fetchRaisedByMe(fresh: false);
      await settle();
      expect(p.isLoadingRaised, isTrue);

      p.raisedList.setNarrowing(search: 'finding 1');
      await p.fetchRaisedByMe(fresh: false);
      expect(p.raisedByMe.every((n) => n.title.toLowerCase().contains('finding 1')), isTrue);
      expect(p.isLoadingRaised, isFalse);

      slow.complete();
      await first;
      expect(p.raisedByMe.every((n) => n.title.toLowerCase().contains('finding 1')), isTrue, reason: 'the older search did not replace the newer');
      expect(p.isLoadingRaised, isFalse);
      expect(p.raisedError, isNull);
    });

    test('a failed next page keeps what is loaded, is not retried by the scroll, and can be retried by hand', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();

      var down = true;
      server.failIf = (o) => down && o.queryParameters['page'] == 2;
      await p.raisedList.loadMore();
      expect(p.raisedByMe, hasLength(20), reason: 'the rows already loaded stay');
      expect(p.raisedList.moreError, isNotNull);
      expect(p.raisedList.isLoadingMore, isFalse);
      expect(p.raisedList.hasMore, isTrue);
      expect(p.raisedError, isNull, reason: 'it is the next page that failed, not the list');

      final before = reads(ApiConstants.ncsRaised).length;
      await p.raisedList.loadMore(); // a scroll listener asking again
      expect(reads(ApiConstants.ncsRaised), hasLength(before), reason: 'a server that is down is not hammered');

      down = false;
      await p.raisedList.loadMore(retry: true); // the footer's "Try again"
      expect(reads(ApiConstants.ncsRaised).last.queryParameters['page'], 2);
      expect(p.raisedByMe, hasLength(40));
      expect(p.raisedList.moreError, isNull);
    });

    test('a first page that fails says so, and the next success clears it', () async {
      server.ncs = _ncs(45);
      final p = provider();
      server.failIf = (o) => true;
      await p.fetchRaisedByMe();
      expect(p.raisedError, isNotNull);
      expect(p.raisedByMe, isEmpty);
      expect(p.isLoadingRaised, isFalse);

      server.failIf = null;
      await p.fetchRaisedByMe();
      expect(p.raisedError, isNull);
      expect(p.raisedByMe, hasLength(20));
    });

    test('a live update re-reads the page that is on screen in place — not cut back to page 1, no new first page', () async {
      server.ncs = _ncs(45);
      SocketService.instance.connect('jwt');
      final p = provider()..startListening();
      addTearDown(p.stopListening);
      await p.fetchRaisedByMe();
      await p.raisedList.goToPage(2);
      expect(p.raisedByMe, hasLength(20));
      expect(p.raisedList.windowPage, 2);
      final shiftedIn = server.ncs[19]['_id']; // what page 2 starts with once one NC is added on top
      final firstPages = p.raisedList.firstPageCount;

      server.ncs = [_nc(-1), ...server.ncs]; // a new NC at the top
      sockets.sockets.single.receive('new_notification', {'type': 'nc_raised'});
      await waitFor(() => p.raisedByMe.isNotEmpty && p.raisedByMe.first.id == shiftedIn);

      expect(p.raisedByMe, hasLength(20), reason: 'only the page on screen was re-read');
      expect(p.raisedList.windowPage, 2);
      expect(p.raisedList.total, 46);
      expect(p.raisedList.firstPageCount, firstPages, reason: 'not a new first page: the screen keeps its scroll position');
      expect(p.raisedList.isLoading, isFalse);
    });

    test('logout empties the lists, and a page on the wire at that moment is dropped', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchRaisedByMe();
      p.raisedList.setNarrowing(chip: 'Closed');
      expect(p.raisedList.chip, 'Closed');

      final held = Completer<void>();
      server.gate = (o) => held.future;
      final loading = p.fetchRaisedByMe(fresh: false);
      await settle();
      p.resetForLogout();
      held.complete();
      await loading;

      expect(p.raisedByMe, isEmpty);
      expect(p.raisedList.chip, 'All', reason: 'the next account starts on the default chip');
      expect(p.raisedList.search, isEmpty);
      expect(p.isLoadingRaised, isFalse);
    });

    test('the dashboard keeps ALL of the auditee\'s NCs (unpaged) and follows filter changes, while the screen\'s list stays one page', () async {
      server.ncs = _ncs(45);
      final p = provider();
      await p.fetchAgainstMeAll();
      final all = reads(ApiConstants.ncsMine).single.queryParameters;
      expect(all.containsKey('page'), isFalse);
      expect(all.containsKey('limit'), isFalse);
      expect(p.againstMeAll, hasLength(45));
      expect(p.raisedAgainstMe, isEmpty, reason: 'the paged list is the NC screen\'s own');

      adapter.requests.clear();
      await p.applyFilters(locations: ['l1']);
      final mine = reads(ApiConstants.ncsMine);
      expect(mine.where((r) => !r.queryParameters.containsKey('page')), hasLength(1), reason: 'the dashboard\'s whole list is read again');
      expect(mine.where((r) => r.queryParameters['page'] == 1), hasLength(1), reason: 'and the screen\'s list restarts at page 1');
      expect(p.againstMeAll, hasLength(45));
      expect(p.raisedAgainstMe, hasLength(20));
    });
  });

  group('Final Report NCs: one page of audits at a time', () {
    test('page 1 is 20 AUDITS (every NC of each) with groupBy=audit; the totals are the server\'s; loadMore appends and stops', () async {
      // 50 audits of two NCs each.
      server.ncs = [for (var i = 0; i < 100; i++) _nc(i, auditOf: 'A${i ~/ 2}')];
      final p = provider();
      await p.fetchNcReport();

      var q = reads(ApiConstants.ncsReport).single.queryParameters;
      expect(q['page'], 1);
      expect(q['limit'], 20);
      expect(q['groupBy'], 'audit');
      expect(q.containsKey('ids'), isFalse);
      expect(p.reportNcs, hasLength(40), reason: '20 audits, both NCs of each');
      expect(p.ncReportTotalAudits, 50);
      expect(p.ncReportTotalNcs, 100);
      expect(p.reportList.hasMore, isTrue);

      await p.reportList.loadMore();
      expect(reads(ApiConstants.ncsReport).last.queryParameters['page'], 2);
      expect(p.reportNcs, hasLength(80));
      await p.reportList.loadMore();
      expect(reads(ApiConstants.ncsReport).last.queryParameters['page'], 3);
      expect(p.reportNcs, hasLength(100));
      expect(p.reportList.hasMore, isFalse);
      expect(idsOf(p.reportNcs).toSet(), hasLength(100));
      final before = reads(ApiConstants.ncsReport).length;
      await p.reportList.loadMore();
      expect(reads(ApiConstants.ncsReport), hasLength(before));

      // Search is the server's and restarts at page 1.
      p.ncReportSearch = ' finding 9 ';
      await p.fetchNcReport();
      q = reads(ApiConstants.ncsReport).last.queryParameters;
      expect(q['search'], 'finding 9');
      expect(q['page'], 1);
      expect(p.reportNcs.every((n) => n.title.toLowerCase().contains('finding 9')), isTrue);
    });

    test('a tile pick is read by the ids the tile counted (never with groupBy), 20 at a time, and a pull-to-refresh asks the stats again', () async {
      server.ncs = _ncs(90);
      final p = provider();
      await p.fetchNcReport();
      expect(reads(ApiConstants.ncsReportStats), isEmpty);

      p.ncReportTileKeys = {'overdue'};
      expect(p.reportNcs, isEmpty, reason: 'the list of the previous pick is dropped at once');
      await p.fetchNcReport(fresh: false);
      expect(reads(ApiConstants.ncsReportStats), hasLength(1), reason: 'no stats held yet: asked once');
      var q = reads(ApiConstants.ncsReport).last.queryParameters;
      expect('${q['ids']}'.split(','), hasLength(20));
      expect(q.containsKey('groupBy'), isFalse);
      expect(q.containsKey('page'), isFalse);
      expect(p.reportNcs.every((n) => n.bucket == 'overdue'), isTrue);
      expect(p.ncReportTotalNcs, 30);
      expect(p.ncReportTotalAudits, isNull, reason: 'the server counts audits only for its own pages');

      await p.reportList.loadMore();
      expect(p.reportNcs, hasLength(30));
      expect(p.reportList.hasMore, isFalse);

      // The tile picked again: the ids held are re-used. Pull-to-refresh: asked afresh.
      p.ncReportTileKeys = {'overdue', 'pendingApproval'};
      await p.fetchNcReport(fresh: false);
      expect(reads(ApiConstants.ncsReportStats), hasLength(1));
      expect(p.ncReportTotalNcs, 60, reason: 'picked tiles OR together');
      await p.fetchNcReport();
      expect(reads(ApiConstants.ncsReportStats), hasLength(2));

      // No tile: the audit pages again.
      p.ncReportTileKeys = {};
      await p.fetchNcReport();
      q = reads(ApiConstants.ncsReport).last.queryParameters;
      expect(q['groupBy'], 'audit');
      expect(q['page'], 1);
    });

    test('an opened place reads its own NCs (the ids its header counted) a page at a time; a tile pick narrows them', () async {
      server.ncs = _ncs(90);
      server.places = [
        {'key': 'Plant A', 'label': 'Plant A', 'total': 90, 'ncIds': [for (final n in server.ncs) n['_id']]},
      ];
      final p = provider();
      await p.fetchNcReportStats();

      final place = p.ncReportPlaceList('Plant A');
      await place.loadFirst();
      var q = reads(ApiConstants.ncsReport).last.queryParameters;
      expect('${q['ids']}'.split(','), hasLength(20));
      expect(place.items, hasLength(20));
      expect(place.total, 90);
      expect(place.hasMore, isTrue);
      await place.loadMore();
      expect(place.items, hasLength(40));
      expect(identical(p.ncReportPlaceList('Plant A'), place), isTrue, reason: 'one list per place');

      // The tile pick changes what the places hold: the lists are dropped, the new
      // one reads only the tile's NCs of that place.
      p.ncReportTileKeys = {'overdue'};
      await p.fetchNcReport(fresh: false);
      final narrowed = p.ncReportPlaceList('Plant A');
      expect(identical(narrowed, place), isFalse);
      await narrowed.loadFirst();
      expect(narrowed.total, 30);
      expect(narrowed.items.every((n) => n.bucket == 'overdue'), isTrue);
    });

    test('a place list follows a live update in place (same pages, no new first page)', () async {
      server.ncs = _ncs(45);
      server.places = [
        {'key': 'Plant A', 'label': 'Plant A', 'total': 45, 'ncIds': [for (final n in server.ncs) n['_id']]},
      ];
      SocketService.instance.connect('jwt');
      final p = provider()..startListening();
      addTearDown(p.stopListening);
      p.ncReportsInUse = true;
      await p.fetchNcReportStats();
      final place = p.ncReportPlaceList('Plant A');
      await place.loadFirst();
      await place.loadMore();
      expect(place.items, hasLength(40));
      final firstPages = place.firstPageCount;

      // Two NCs more at the place; the loaded pages are re-read with the new ids.
      server.ncs = [_nc(-2), _nc(-1), ...server.ncs];
      server.places = [
        {'key': 'Plant A', 'label': 'Plant A', 'total': 47, 'ncIds': [for (final n in server.ncs) n['_id']]},
      ];
      sockets.sockets.single.receive('new_notification', {'type': 'nc_raised'});
      await waitFor(() => place.items.isNotEmpty && place.items.first.id == 'nc902');
      expect(place.items, hasLength(40));
      expect(place.firstPageCount, firstPages);
    });
  });

  group('Final Report Repeated NCs: one page of groups at a time', () {
    test('page 1 is 30 groups; further pages append by page count; the end is the server\'s total', () async {
      server.repeats = [for (var i = 0; i < 70; i++) _repeat(i)];
      final p = provider();
      await p.fetchRepeats();

      final q = reads(ApiConstants.ncsRepeats).single.queryParameters;
      expect(q['page'], 1);
      expect(q['limit'], 30);
      expect(q['minCount'], 2);
      expect(p.repeatRows, hasLength(30));
      expect(p.repeatsTotal, 70);
      expect(p.repeatsHasMore, isTrue);

      await p.fetchRepeats(more: true);
      expect(reads(ApiConstants.ncsRepeats).last.queryParameters['page'], 2);
      expect(p.repeatRows, hasLength(60));
      await p.fetchRepeats(more: true);
      expect(reads(ApiConstants.ncsRepeats).last.queryParameters['page'], 3);
      expect(p.repeatRows, hasLength(70));
      expect(p.repeatsHasMore, isFalse);
      expect({for (final g in p.repeatRows) g.key}, hasLength(70), reason: 'appended, never repeated');

      final before = reads(ApiConstants.ncsRepeats).length;
      await p.fetchRepeats(more: true);
      expect(reads(ApiConstants.ncsRepeats), hasLength(before));
    });

    test('a failed page keeps the rows, is not retried by the scroll, and can be retried; a double ask sends one request', () async {
      server.repeats = [for (var i = 0; i < 70; i++) _repeat(i)];
      final p = provider();
      await p.fetchRepeats();

      var down = true;
      server.failIf = (o) => down && o.path == ApiConstants.ncsRepeats && o.queryParameters['page'] == 2;
      await p.fetchRepeats(more: true);
      expect(p.repeatRows, hasLength(30));
      expect(p.repeatsMoreError, isNotNull);
      expect(p.isLoadingMoreRepeats, isFalse);
      expect(p.repeatsError, isNull);
      final before = reads(ApiConstants.ncsRepeats).length;
      await p.fetchRepeats(more: true);
      expect(reads(ApiConstants.ncsRepeats), hasLength(before));

      down = false;
      final held = Completer<void>();
      server.gate = (o) => held.future;
      final a = p.fetchRepeats(more: true, retry: true);
      final b = p.fetchRepeats(more: true, retry: true);
      await settle();
      expect(reads(ApiConstants.ncsRepeats), hasLength(before + 1), reason: 'the second ask found one on the wire');
      held.complete();
      await Future.wait([a, b]);
      expect(p.repeatRows, hasLength(60));
      expect(p.repeatsMoreError, isNull);
    });

    test('a page that lands after the min. times moved is dropped', () async {
      server.repeats = [for (var i = 0; i < 70; i++) _repeat(i)];
      final p = provider();
      await p.fetchRepeats();

      final held = Completer<void>();
      server.gate = (o) => o.queryParameters['page'] == 2 ? held.future : Future<void>.value();
      final more = p.fetchRepeats(more: true);
      await settle();
      p.repeatsMinCount = 3;
      await p.fetchRepeats(); // page 1 of the new pick
      expect(reads(ApiConstants.ncsRepeats).last.queryParameters['minCount'], 3);
      expect(p.repeatRows, hasLength(30));

      held.complete();
      await more;
      expect(p.repeatRows, hasLength(30), reason: 'the old pick\'s page 2 was not appended');
      expect(p.isLoadingMoreRepeats, isFalse);
    });
  });

  group('screens', () {
    testWidgets('NC Monitoring: page 1 on open, Prev/Next move between pages, the server total and page shown', (tester) async {
      server
        ..ncs = _ncs(45)
        ..statsDown = true; // no tiles: just the list
      await _pumpNcMonitoring(tester, provider());

      expect(reads(ApiConstants.ncsRaised), hasLength(1));
      expect(reads(ApiConstants.ncsRaised).single.queryParameters['page'], 1);
      expect(reads(ApiConstants.ncsRaised).single.queryParameters['limit'], 20);
      expect(find.text('Finding 0'), findsOneWidget);
      expect(find.text('Showing 20 of 45 NCs'), findsOneWidget);

      await _scrollToEnd(tester, find.byType(ListView).last);
      expect(reads(ApiConstants.ncsRaised), hasLength(1), reason: 'scrolling no longer loads anything');
      expect(find.text('Page 1 of 3'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('nc-page-prev'))).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect(reads(ApiConstants.ncsRaised), hasLength(2));
      expect(reads(ApiConstants.ncsRaised).last.queryParameters['page'], 2);
      expect(find.text('Showing 21–40 of 45 NCs'), findsOneWidget);
      expect(find.text('Finding 0'), findsNothing, reason: 'page 2 replaces page 1');
      expect(find.text('Finding 20'), findsOneWidget);

      await _scrollToEnd(tester, find.byType(ListView).last);
      expect(find.text('Page 2 of 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect(find.text('Showing 41–45 of 45 NCs'), findsOneWidget);
      await _scrollToEnd(tester, find.byType(ListView).last);
      expect(find.text('Page 3 of 3'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('nc-page-next'))).onPressed, isNull, reason: 'nothing after the last page');

      await tester.tap(find.byKey(const ValueKey('nc-page-prev')));
      await _settle(tester);
      expect(find.text('Showing 21–40 of 45 NCs'), findsOneWidget);
    });

    testWidgets('a page that fails keeps the rows and says so; Next tries it again', (tester) async {
      server
        ..ncs = _ncs(45)
        ..statsDown = true;
      var down = true;
      server.failIf = (o) => down && o.path == ApiConstants.ncsRaised && o.queryParameters['page'] == 2;
      final ncs = provider();
      await _pumpNcMonitoring(tester, ncs);

      await _scrollToEnd(tester, find.byType(ListView).last);
      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect(ncs.raisedList.moreError, isNotNull);
      expect(find.text(ncs.raisedList.moreError!), findsOneWidget, reason: 'the failure is shown under the rows');
      expect(ncs.raisedByMe, hasLength(20));
      expect(find.text('Page 1 of 3'), findsOneWidget, reason: 'still on the page that is showing');

      down = false;
      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect(ncs.raisedList.moreError, isNull);
      expect(find.text('Showing 21–40 of 45 NCs'), findsOneWidget);
      expect(ncs.raisedByMe, hasLength(20));
    });

    testWidgets('typing sends ONE search to the server after the pause and restarts at page 1; clearing it restarts at once', (tester) async {
      server
        ..ncs = [for (var i = 0; i < 45; i++) _nc(i, title: i == 7 ? 'Floor wet' : 'Finding $i')]
        ..statsDown = true;
      await _pumpNcMonitoring(tester, provider());
      expect(find.text('Showing 20 of 45 NCs'), findsOneWidget);
      final before = reads(ApiConstants.ncsRaised).length;

      final box = find.byType(TextField).last;
      await tester.enterText(box, 'w');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(box, 'we');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(box, 'wet');
      await tester.pump(const Duration(milliseconds: 300));
      expect(reads(ApiConstants.ncsRaised), hasLength(before), reason: 'still inside the pause: nothing sent yet');

      await tester.pump(const Duration(milliseconds: 200));
      await _settle(tester);
      final searched = reads(ApiConstants.ncsRaised).skip(before).toList();
      expect(searched, hasLength(1), reason: 'one request for the three keystrokes');
      expect(searched.single.queryParameters['search'], 'wet');
      expect(searched.single.queryParameters['page'], 1);
      expect(find.text('Floor wet'), findsOneWidget);
      expect(find.text('Finding 0'), findsNothing);
      expect(find.text('1 NC'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await _settle(tester);
      final cleared = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect(cleared.containsKey('search'), isFalse);
      expect(cleared['page'], 1);
      expect(find.text('Showing 20 of 45 NCs'), findsOneWidget);
    });

    testWidgets('a tile on NC Monitoring is a chip the server answers: the NCs the tile counted, 20 at a time', (tester) async {
      server.ncs = _ncs(90); // 30 Overdue
      await _pumpNcMonitoring(tester, provider());
      expect(find.byKey(const ValueKey('report-tile-overdue')), findsOneWidget);
      expect(find.text('Showing 20 of 90 NCs'), findsOneWidget);
      final statsBefore = reads(ApiConstants.ncsRaisedStats).length;

      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await _settle(tester);
      expect(reads(ApiConstants.ncsRaisedStats), hasLength(statsBefore), reason: 'the tile ids are already held');
      final q = reads(ApiConstants.ncsRaised).last.queryParameters;
      expect('${q['ids']}'.split(','), hasLength(20));
      expect(find.text('Showing 20 of 30 NCs'), findsOneWidget);

      await _scrollToEnd(tester, find.byType(ListView).last);
      expect(find.text('Page 1 of 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect('${reads(ApiConstants.ncsRaised).last.queryParameters['ids']}'.split(','), hasLength(10), reason: 'the next slice of the tile\'s ids');
      expect(find.text('Showing 21–30 of 30 NCs'), findsOneWidget);
    });

    testWidgets('the Final Report NCs tab: page 1 of audits, the server\'s totals in the count line, Prev/Next turn the pages', (tester) async {
      server.ncs = [for (var i = 0; i < 100; i++) _nc(i, auditOf: 'A${i ~/ 2}')]; // 50 audits
      await _pumpNcReportTab(tester, provider());

      expect(reads(ApiConstants.ncsReport), hasLength(1));
      expect(reads(ApiConstants.ncsReport).single.queryParameters['limit'], 20);
      expect(reads(ApiConstants.ncsReport).single.queryParameters['groupBy'], 'audit');
      expect(find.text('100 NCs · 50 audits'), findsOneWidget, reason: 'the server\'s totals, not what is shown');
      expect(find.text('1/3'), findsOneWidget, reason: '50 audits, 20 a page');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('nc-page-prev-top'))).onPressed, isNull);

      await _scrollToEnd(tester, find.byType(ListView).first);
      expect(reads(ApiConstants.ncsReport), hasLength(1), reason: 'scrolling no longer loads anything');

      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect(reads(ApiConstants.ncsReport), hasLength(2));
      expect(reads(ApiConstants.ncsReport).last.queryParameters['page'], 2);
      expect(find.text('2/3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nc-page-prev-top')));
      await _settle(tester);
      expect(reads(ApiConstants.ncsReport).last.queryParameters['page'], 1);
      expect(find.text('1/3'), findsOneWidget);
    });

    testWidgets('a tile on the NCs tab reads just its NCs by id; the count line says how many', (tester) async {
      server.ncs = _ncs(90); // 30 Overdue, every NC its own audit
      await _pumpNcReportTab(tester, provider());
      expect(find.text('90 NCs · 90 audits'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('report-tile-overdue')));
      await _settle(tester);
      final q = reads(ApiConstants.ncsReport).last.queryParameters;
      expect('${q['ids']}'.split(','), hasLength(20));
      expect(q.containsKey('groupBy'), isFalse);
      expect(find.text('30 NCs'), findsOneWidget, reason: 'the audits are counted once all of the pick has arrived');

      expect(find.text('1/2'), findsOneWidget, reason: '30 NCs, 20 a page');
      await tester.tap(find.byKey(const ValueKey('nc-page-next-top')));
      await _settle(tester);
      final next = reads(ApiConstants.ncsReport).last.queryParameters;
      expect('${next['ids']}'.split(','), hasLength(10), reason: 'the next slice of the tile\'s ids');
      expect(find.text('2/2'), findsOneWidget);
    });

    testWidgets('location-wise: an opened place loads its next page by itself as the tab scrolls to its end', (tester) async {
      server.ncs = _ncs(45);
      server.places = [
        {'key': 'Plant A', 'label': 'Plant A', 'total': 45, 'inProgress': 15, 'overdue': 15, 'pendingApproval': 0, 'delayed': 0, 'onTime': 15, 'ncIds': [for (final n in server.ncs) n['_id']]},
      ];
      final ncs = provider();
      await _pumpNcReportTab(tester, ncs);

      await tester.tap(find.widgetWithText(FilterChip, 'Group by location'));
      await _settle(tester);
      expect(find.text('Plant A'), findsOneWidget);
      expect(find.text('45 NCs'), findsOneWidget, reason: 'the header is the server\'s tally');
      expect(find.text('Finding 0'), findsNothing, reason: 'collapsed until tapped');

      final before = reads(ApiConstants.ncsReport).length;
      await tester.tap(find.text('Plant A'));
      await _settle(tester);
      final first = reads(ApiConstants.ncsReport).skip(before).toList();
      expect(first, hasLength(1));
      expect('${first.single.queryParameters['ids']}'.split(','), hasLength(20));
      expect(ncs.ncReportPlaceList('Plant A').items, hasLength(20));
      expect(find.text('Finding 0'), findsOneWidget);

      await _scrollToEnd(tester, find.byType(ListView).first);
      expect(ncs.ncReportPlaceList('Plant A').items, hasLength(40));
      await _scrollToEnd(tester, find.byType(ListView).first);
      expect(ncs.ncReportPlaceList('Plant A').items, hasLength(45));
      expect(ncs.ncReportPlaceList('Plant A').hasMore, isFalse);
    });

    testWidgets('the Repeated NCs tab: page 1 of groups, Prev/Next turn the pages, a failed page keeps the rows and says so', (tester) async {
      server.repeats = [for (var i = 0; i < 70; i++) _repeat(i)];
      var down = false;
      server.failIf = (o) => down && o.path == ApiConstants.ncsRepeats && o.queryParameters['page'] == 3;
      final ncs = provider();
      await _pumpRepeatsTab(tester, ncs);

      expect(reads(ApiConstants.ncsRepeats), hasLength(1));
      expect(reads(ApiConstants.ncsRepeats).single.queryParameters['limit'], 30);
      expect(find.text('Showing 30 of 70 repeated checkpoints'), findsOneWidget);
      expect(find.text('1/3'), findsOneWidget);

      await _scrollToEnd(tester, find.byType(ListView).first);
      expect(reads(ApiConstants.ncsRepeats), hasLength(1), reason: 'scrolling no longer loads anything');

      await tester.tap(find.byKey(const ValueKey('nc-page-next')));
      await _settle(tester);
      expect(reads(ApiConstants.ncsRepeats).last.queryParameters['page'], 2);
      expect(ncs.repeatRows, hasLength(30), reason: 'page 2 replaces page 1');
      expect(find.text('Showing 31–60 of 70 repeated checkpoints'), findsOneWidget);

      down = true;
      await tester.tap(find.byKey(const ValueKey('nc-page-next-top')));
      await _settle(tester);
      expect(ncs.repeatsMoreError, isNotNull);
      expect(ncs.repeatRows, hasLength(30), reason: 'the groups showing stay');
      expect(find.text('2/3'), findsOneWidget);

      down = false;
      await tester.tap(find.byKey(const ValueKey('nc-page-next-top')));
      await _settle(tester);
      expect(ncs.repeatsMoreError, isNull);
      expect(ncs.repeatRows, hasLength(10));
      expect(find.text('Showing 61–70 of 70 repeated checkpoints'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('nc-page-next-top'))).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('nc-page-prev-top')));
      await _settle(tester);
      expect(find.text('2/3'), findsOneWidget);
    });
  });
}

// ── The fake server ───────────────────────────────────────────────────────

class _Server {
  /// Newest first — the order the server's `_id`/`startDate` descending sort gives.
  List<Map<String, dynamic>> ncs = [];
  List<Map<String, dynamic>> places = [];
  List<Map<String, dynamic>> repeats = [];

  /// Holds a request until the returned future completes.
  Future<void> Function(RequestOptions o)? gate;

  /// Answers a matching request with a network failure.
  bool Function(RequestOptions o)? failIf;

  /// The stats endpoints answer 403 (no tiles).
  bool statsDown = false;

  Future<ResponseBody> handle(RequestOptions o) async {
    final hold = gate;
    if (hold != null) await hold(o);
    final fail = failIf;
    if (fail != null && fail(o)) connectionError(o);
    final q = o.queryParameters;
    switch (o.path) {
      case ApiConstants.ncsRaised:
      case ApiConstants.ncsMine:
        return json(200, {'isOk': true, 'data': _list(q)});
      case ApiConstants.ncsReport:
        return json(200, {'isOk': true, 'data': _report(q)});
      case ApiConstants.ncsRaisedStats:
      case ApiConstants.ncsAtsSummary:
      case ApiConstants.ncsReportStats:
        return statsDown ? json(403, {'isOk': false}) : json(200, {'isOk': true, 'data': _stats(q)});
      case ApiConstants.ncsRepeats:
        final page = (q['page'] as num?)?.toInt() ?? 1;
        final limit = (q['limit'] as num?)?.toInt() ?? 15;
        return json(200, {
          'isOk': true,
          'data': {
            'rows': repeats.skip((page - 1) * limit).take(limit).toList(),
            'total': repeats.length,
            'page': page,
            'limit': limit,
            'minCount': q['minCount'],
          },
        });
      default:
        return json(200, {'isOk': true, 'data': []});
    }
  }

  // What every NC endpoint ANDs together: `status` (csv), `open`, `search`.
  List<Map<String, dynamic>> _matching(Map<String, dynamic> q) {
    var rows = ncs;
    final status = q['status'];
    if (status != null) {
      final wanted = '$status'.split(',').toSet();
      rows = [for (final r in rows) if (wanted.contains(r['status'])) r];
    }
    if (q['open'] == 'true') rows = [for (final r in rows) if (r['status'] != 'Closed') r];
    final search = '${q['search'] ?? ''}'.trim().toLowerCase();
    if (search.isNotEmpty) {
      rows = [for (final r in rows) if ('${r['title']}'.toLowerCase().contains(search)) r];
    }
    return rows;
  }

  // GET /ncs/raised and /ncs/mine: the plain array without page/limit/ids, else
  // {ncs, total, page, limit}; `ids` overrides the paging (exactly those).
  Object _list(Map<String, dynamic> q) {
    final rows = _matching(q);
    final ids = q['ids'];
    final paged = q.containsKey('page') || q.containsKey('limit') || ids != null;
    if (!paged) return rows;
    if (ids != null) {
      final wanted = '$ids'.split(',').toSet();
      final hit = [for (final r in rows) if (wanted.contains(r['_id'])) r];
      return {'ncs': hit, 'total': hit.length, 'page': 1, 'limit': hit.length};
    }
    final page = (q['page'] as num?)?.toInt() ?? 1;
    final limit = ((q['limit'] as num?)?.toInt() ?? 15).clamp(1, 100);
    return {
      'ncs': rows.skip((page - 1) * limit).take(limit).toList(),
      'total': rows.length,
      'page': page,
      'limit': limit,
    };
  }

  // GET /ncs/report: with groupBy=audit (and no ids) a page is `limit` whole audits
  // and `total` counts audits (`totalNcs` the NCs); otherwise like the lists above.
  Map<String, dynamic> _report(Map<String, dynamic> q) {
    final rows = _matching(q);
    final ids = q['ids'];
    if (ids != null) {
      final wanted = '$ids'.split(',').toSet();
      final hit = [for (final r in rows) if (wanted.contains(r['_id'])) r];
      return {'ncs': hit, 'total': hit.length, 'page': 1, 'limit': hit.length};
    }
    final page = (q['page'] as num?)?.toInt() ?? 1;
    final limit = ((q['limit'] as num?)?.toInt() ?? 100).clamp(1, 100);
    if (q['groupBy'] == 'audit') {
      final groups = <String, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        groups.putIfAbsent('${r['auditKey']}', () => []).add(r);
      }
      final slice = groups.values.skip((page - 1) * limit).take(limit);
      return {
        'ncs': [for (final g in slice) ...g],
        'total': groups.length,
        'totalNcs': rows.length,
        'page': page,
        'limit': limit,
      };
    }
    return {
      'ncs': rows.skip((page - 1) * limit).take(limit).toList(),
      'total': rows.length,
      'page': page,
      'limit': limit,
    };
  }

  // The six tiles and the id list behind each (they follow the search, not a chip).
  // The ids come oldest first on purpose: the app orders them itself.
  Map<String, dynamic> _stats(Map<String, dynamic> q) {
    final rows = _matching({'search': q['search']});
    List<String> idsOf(String bucket) => [
      for (final r in rows.reversed)
        if (r['bucket'] == bucket) '${r['_id']}',
    ];
    return {
      'total': rows.length,
      for (final b in const ['inProgress', 'overdue', 'pendingApproval', 'delayed', 'onTime']) ...{
        b: idsOf(b).length,
        '${b}Ids': idsOf(b),
      },
      'byLocation': places,
    };
  }
}

// An NC. The id carries its age: `nc900` is newer than `nc899`, so the ids sort the
// way the server's `_id` descending order does.
Map<String, dynamic> _nc(
  int i, {
  String? title,
  String? status,
  String? bucket,
  String? auditOf,
}) {
  final kind = i.abs() % 3; // 0 Closed/onTime, 1 Raised/overdue, 2 Response Submitted/pendingApproval
  final id = 'nc${900 - i}';
  return {
    '_id': id,
    'ncId': 'NC-$id',
    'title': title ?? 'Finding $i',
    'status': status ?? const ['Closed', 'Raised', 'Response Submitted'][kind],
    'severity': 'Major',
    'bucket': bucket ?? const ['onTime', 'overdue', 'pendingApproval'][kind],
    'placeLabel': 'Plant A',
    'auditKey': auditOf ?? 'a-$id',
    'auditId': {'_id': auditOf ?? 'a-$id', 'title': 'Audit ${auditOf ?? id}', 'auditType': 'Safety'},
    'raisedByEmployeeId': {'_id': 'u-asha', 'employeeName': 'Asha'},
    'auditeeEmployeeId': {'_id': 'u-ravi', 'employeeName': 'Ravi'},
    'startDate': '2026-09-01T00:00:00.000Z',
    'targetDate': '2026-09-20T00:00:00.000Z',
  };
}

List<Map<String, dynamic>> _ncs(int n) => [for (var i = 0; i < n; i++) _nc(i)];

Map<String, dynamic> _repeat(int i) => {
  'key': 'k$i',
  'title': 'Repeat $i',
  'locationName': 'Plant A',
  'count': 3,
  'openCount': 1,
  'firstDate': '2026-03-02T00:00:00.000Z',
  'lastDate': '2026-09-01T00:00:00.000Z',
  'latestStatus': 'Raised',
  'ncIds': ['x$i'],
};

// ── Screens ───────────────────────────────────────────────────────────────

void _phone(WidgetTester tester) {
  // Short enough that one page of 20 cards is far taller than the screen.
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _scrollToEnd(WidgetTester tester, Finder list) async {
  await tester.drag(list, const Offset(0, -9000));
  await _settle(tester);
}

Future<void> _pumpNcMonitoring(WidgetTester tester, NcProvider ncs) async {
  _phone(tester);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => AuditsProvider()),
      ChangeNotifierProvider.value(value: ncs),
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
  await _settle(tester);
}

// A paged list keeps a small spinner at its foot while more pages are left, so pumpAndSettle never
// settles on it: pump a fixed span of time instead (long enough for any fake answer and animation).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

// The NCs / Repeated NCs tabs without their host (ReportsScreen): the loads the host
// makes when the tab opens are made here.
Future<void> _pumpReportTab(WidgetTester tester, NcProvider ncs, Widget tab, List<Future<void> Function()> loads) async {
  _phone(tester);
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: ncs),
      ChangeNotifierProvider(create: (_) => AuthProvider()),
      ChangeNotifierProvider(create: (_) => ListViewMemory()),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: Scaffold(body: tab)),
  ));
  for (final load in loads) {
    unawaited(load());
  }
  await _settle(tester);
}

Future<void> _pumpNcReportTab(WidgetTester tester, NcProvider ncs) =>
    _pumpReportTab(tester, ncs, const NcReportTab(), [ncs.fetchNcReport, ncs.fetchNcReportStats]);

Future<void> _pumpRepeatsTab(WidgetTester tester, NcProvider ncs) =>
    _pumpReportTab(tester, ncs, const RepeatedNcsTab(), [ncs.fetchRepeats]);
