import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/providers/notifications_provider.dart';
import 'package:internal_audit_app/providers/tickets_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// Every provider here lives for the whole process, so on a shared phone the
/// next account would open onto the previous account's data — and a request
/// that was already on the wire at sign-out must not put it back afterwards.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late FakeSockets sockets;
  // Requests parked until a test lets them answer.
  late Completer<void> gate;

  Map<String, dynamic> notification(String id, {bool read = false}) =>
      {'_id': id, 'title': 'Audit $id assigned', 'message': 'm', 'type': 'audit_assigned', 'isRead': read};

  // A request that is on the wire when the account signs out and then FAILS
  // must leave what the next account's own request is showing alone: no error
  // message of its own, and its loading flag not ended early.
  Future<void> expectStaleFailureIgnored({
    required Future<void> Function() fetch,
    required void Function() signOut,
    required bool Function() loading,
    required String? Function() error,
    // What the next account's request is answered with: the shape its parser expects.
    Object freshBody = const {'data': []},
  }) async {
    final gates = <Completer<void>>[];
    adapter.handler = (o) async {
      final index = gates.length;
      final g = Completer<void>();
      gates.add(g);
      await g.future;
      if (index == 0) connectionError(o);
      return json(200, freshBody);
    };
    final stale = fetch();
    await settle();
    signOut();
    final fresh = fetch(); // the next account's own request
    await settle();
    expect(loading(), isTrue);

    gates[0].complete(); // the previous account's request fails first
    await stale;
    expect(error(), isNull, reason: "the previous account's failure was shown to the next one");
    expect(loading(), isTrue, reason: "the previous account's request ended the next one's loading state");

    gates[1].complete();
    await fresh;
    expect(loading(), isFalse);
    expect(error(), isNull);
  }

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    gate = Completer<void>()..complete();
    adapter = FakeAdapter()
      ..handler = (o) async {
        await gate.future;
        if (o.path == ApiConstants.auditById('a1')) {
          return json(200, {'data': {'_id': 'a1', 'title': 'Old account audit'}});
        }
        if (o.path == ApiConstants.ncDetail('nc1')) {
          return json(200, {'data': {'_id': 'nc1', 'title': 'Old account NC'}});
        }
        if (o.path == ApiConstants.locations) {
          return json(200, {'data': [{'_id': 'l1', 'name': 'Old account plant'}]});
        }
        if (o.path == ApiConstants.employeesByLocation(['l1'])) {
          return json(200, {'data': [{'_id': 'e1', 'employeeName': 'Old account person'}]});
        }
        if (o.path == ApiConstants.tickets) {
          return json(200, {
            'data': o.method == 'POST'
                ? {'_id': 't-new', 'subject': 'Created by the old account'}
                : [{'_id': 't1', 'subject': 'Old account ticket'}],
          });
        }
        if (o.path == ApiConstants.ticketById('t1') || o.path == ApiConstants.ticketReply('t1')) {
          return json(200, {'data': {'_id': 't1', 'subject': 'Old account ticket'}});
        }
        switch (o.path) {
          case ApiConstants.notifications:
            return json(200, {'data': [notification('n1'), notification('n2', read: true)]});
          case ApiConstants.notificationsUnreadCount:
            return json(200, {'unreadCount': 7});
          case ApiConstants.myAudits:
          case ApiConstants.auditsAtMyLocation:
            return json(200, {'data': [{'_id': 'a1', 'title': 'Old account audit'}]});
          case ApiConstants.ncsRaised:
          case ApiConstants.ncsMine:
            return json(200, {'data': [{'_id': 'nc1', 'title': 'Old account NC'}]});
          case ApiConstants.auditorStats:
            return json(200, {'data': {'assignedAudits': 9, 'inProgress': 4}});
          case ApiConstants.ncsAtsSummary:
            return json(200, {'data': {'total': 12}});
          default:
            return json(200, {'data': []});
        }
      };
    DioClient.instance.dio.httpClientAdapter = adapter;
    sockets = FakeSockets();
    SocketService.debugInstance = sockets.service;
  });

  group('NotificationsProvider', () {
    late NotificationsProvider provider;
    setUp(() => provider = NotificationsProvider());
    tearDown(() => provider.resetForLogout()); // detaches the lifecycle observer

    test('logout empties the list and the badge', () async {
      await provider.fetchNotifications();
      expect(provider.notifications, hasLength(2));
      expect(provider.unreadCount, 1);

      provider.resetForLogout();

      expect(provider.notifications, isEmpty);
      expect(provider.unreadCount, 0);
      expect(provider.errorMessage, isNull);
      expect(provider.isLoading, isFalse);
    });

    test('a list request that was on the wire at logout is dropped when it lands', () async {
      gate = Completer<void>();
      final inFlight = provider.fetchNotifications();
      await settle();

      provider.resetForLogout();
      gate.complete();
      await inFlight;

      expect(provider.notifications, isEmpty);
      expect(provider.unreadCount, 0);
      expect(provider.isLoading, isFalse);
    });

    test('so is a badge-count request', () async {
      gate = Completer<void>();
      final inFlight = provider.fetchUnreadCount();
      await settle();

      provider.resetForLogout();
      gate.complete();
      await inFlight;

      expect(provider.unreadCount, 0);
    });

    test('the next session is not disturbed by the previous one\'s stale answer', () async {
      gate = Completer<void>();
      final stale = provider.fetchNotifications();
      await settle();
      provider.resetForLogout();
      gate.complete();

      await provider.fetchNotifications(); // the new account's own fetch
      await stale;
      expect(provider.notifications, hasLength(2));
      expect(provider.isLoading, isFalse);
    });

    test('a stale answer landing mid-way through the new session\'s fetch does not end its loading state', () async {
      final gates = <Completer<void>>[];
      adapter.handler = (o) async {
        final g = Completer<void>();
        gates.add(g);
        await g.future;
        return json(200, {'data': [notification('n1')]});
      };
      final stale = provider.fetchNotifications();
      await settle();
      provider.resetForLogout();
      final fresh = provider.fetchNotifications();
      await settle();
      expect(provider.isLoading, isTrue);

      gates[0].complete(); // the previous account's request answers first
      await stale;
      expect(provider.isLoading, isTrue);
      expect(provider.notifications, isEmpty);

      gates[1].complete();
      await fresh;
      expect(provider.isLoading, isFalse);
      expect(provider.notifications, hasLength(1));
    });

    test('live events are handled on the socket of a re-login (after the logout reset)', () {
      SocketService.instance.connect('jwt-A');
      provider.startListening();
      sockets.sockets[0].receive('new_notification', notification('n9'));
      expect(provider.unreadCount, 1);

      SocketService.instance.disconnect();
      provider.resetForLogout();
      expect(provider.unreadCount, 0);

      SocketService.instance.connect('jwt-B');
      provider.startListening(); // AppShell.initState of the next session
      sockets.sockets[1].receive('new_notification', notification('n10'));
      expect(provider.unreadCount, 1);
      expect(provider.notifications.single.id, 'n10');
      expect(sockets.sockets[1].listenerCount('new_notification'), 1);
    });

    test('the reset detaches every listener it attached', () {
      SocketService.instance.connect('jwt-A');
      provider.startListening();
      expect(sockets.sockets[0].listenerCount('new_notification'), 1);
      expect(sockets.sockets[0].listenerCount('refresh_unread_count'), 1);
      expect(sockets.sockets[0].listenerCount('connect'), greaterThanOrEqualTo(2)); // join + catch-up

      provider.resetForLogout();
      expect(sockets.sockets[0].listenerCount('new_notification'), 0);
      expect(sockets.sockets[0].listenerCount('refresh_unread_count'), 0);
    });

    test('a socket reconnect refetches the badge and a list that was loaded', () async {
      SocketService.instance.connect('jwt-A');
      provider.startListening();
      await provider.fetchNotifications();
      adapter.requests.clear();

      sockets.sockets[0].receive('connect');
      await settle();

      expect(adapter.where('GET', ApiConstants.notificationsUnreadCount), hasLength(1));
      expect(adapter.where('GET', ApiConstants.notifications), hasLength(1));
    });

    test('a reconnect with nothing loaded refetches only the badge', () async {
      SocketService.instance.connect('jwt-A');
      provider.startListening();
      sockets.sockets[0].receive('connect');
      await waitFor(() => provider.unreadCount == 7);

      expect(adapter.where('GET', ApiConstants.notificationsUnreadCount), hasLength(1));
      expect(adapter.where('GET', ApiConstants.notifications), isEmpty);
    });

    test('coming back to the foreground catches the badge up', () async {
      SocketService.instance.connect('jwt-A');
      provider.startListening();
      expect(provider.unreadCount, 0);

      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitFor(() => provider.unreadCount == 7);
    });

    test('backgrounding does not fetch', () async {
      provider.startListening();
      provider.didChangeAppLifecycleState(AppLifecycleState.paused);
      await settle();
      expect(adapter.requests, isEmpty);
    });
  });

  group('NcProvider', () {
    late NcProvider provider;
    setUp(() => provider = NcProvider());

    test('logout empties both lists, the open NC and the scope', () async {
      provider.setSelfEmployeeId('employee-A');
      provider.isTeamScope = true;
      await Future.wait([provider.fetchRaisedByMe(), provider.fetchAgainstMe()]);
      expect(provider.raisedByMe, isNotEmpty);
      expect(provider.raisedAgainstMe, isNotEmpty);

      provider.resetForLogout();

      expect(provider.raisedByMe, isEmpty);
      expect(provider.raisedAgainstMe, isEmpty);
      expect(provider.activeNc, isNull);
      expect(provider.isTeamScope, isFalse);
    });

    test('the previous employee\'s id is not sent for the next account (a SuperAdmin never sets one)', () async {
      provider.setSelfEmployeeId('employee-A');
      provider.resetForLogout();
      adapter.requests.clear();

      await provider.fetchRaisedByMe();
      expect(adapter.requests.single.queryParameters, isEmpty);
    });

    test('an answer that was on the wire at logout is dropped', () async {
      gate = Completer<void>();
      final raised = provider.fetchRaisedByMe();
      final mine = provider.fetchAgainstMe();
      await settle();

      provider.resetForLogout();
      gate.complete();
      await Future.wait([raised, mine]);

      expect(provider.raisedByMe, isEmpty);
      expect(provider.raisedAgainstMe, isEmpty);
    });

    test('a request that fails after logout does not touch the next account\'s raised list', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchRaisedByMe,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingRaised,
        error: () => provider.raisedError,
      );
    });

    test('nor its list of NCs against them', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchAgainstMe,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingMine,
        error: () => provider.mineError,
      );
    });

    test('an NC opened from a notification that lands after logout is dropped, not made the open NC', () async {
      gate = Completer<void>();
      final opening = provider.fetchById('nc1');
      await settle();

      provider.resetForLogout();
      gate.complete();

      expect(await opening, isNull);
      expect(provider.activeNc, isNull);
    });

    test('and one that lands in time is opened as before', () async {
      final nc = await provider.fetchById('nc1');
      expect(nc?.id, 'nc1');
      expect(provider.activeNc?.id, 'nc1');
    });
  });

  group('AuditsProvider', () {
    late AuditsProvider provider;
    setUp(() => provider = AuditsProvider());

    test('logout empties every audit list and the open audit, and the filters', () async {
      provider.setSelfEmployeeId('employee-A');
      await Future.wait([provider.fetchMyAudits(), provider.fetchAuditsAtMyLocation(), provider.fetchReportAudits()]);
      expect(provider.audits, isNotEmpty);
      expect(provider.auditsAtMyLocation, isNotEmpty);
      expect(provider.reportAudits, isNotEmpty);
      provider.isTeamScope = true;
      provider.locationFilter = const ['loc1'];

      provider.resetForLogout();

      expect(provider.audits, isEmpty);
      expect(provider.auditsAtMyLocation, isEmpty);
      expect(provider.reportAudits, isEmpty);
      expect(provider.activeAudit, isNull);
      expect(provider.isTeamScope, isFalse);
      expect(provider.locationFilter, isEmpty);
    });

    test('the previous employee\'s id is not sent for the next account', () async {
      provider.setSelfEmployeeId('employee-A');
      provider.resetForLogout();
      adapter.requests.clear();

      await provider.fetchMyAudits();
      expect(adapter.requests.single.queryParameters, isNot(contains('employeeIds')));
    });

    test('an answer that was on the wire at logout is dropped', () async {
      gate = Completer<void>();
      final fetches = [provider.fetchMyAudits(), provider.fetchAuditsAtMyLocation(), provider.fetchReportAudits()];
      await settle();

      provider.resetForLogout();
      gate.complete();
      await Future.wait(fetches);

      expect(provider.audits, isEmpty);
      expect(provider.auditsAtMyLocation, isEmpty);
      expect(provider.reportAudits, isEmpty);
    });

    test('an open audit, the location pickers and their people that were on the wire at logout are dropped', () async {
      gate = Completer<void>();
      final fetches = [
        provider.fetchAuditDetail('a1'),
        provider.fetchAllLocations(),
        provider.fetchLocationEmployees(['l1']),
      ];
      await settle();

      provider.resetForLogout();
      gate.complete();
      await Future.wait(fetches);

      expect(provider.activeAudit, isNull);
      expect(provider.allLocations, isEmpty);
      expect(provider.auditeeCandidates, isEmpty);
      expect(provider.isLoadingDetail, isFalse);
    });

    test('the same requests, when the account is still the current one, land as before', () async {
      await Future.wait([
        provider.fetchAuditDetail('a1'),
        provider.fetchAllLocations(),
        provider.fetchLocationEmployees(['l1']),
      ]);
      expect(provider.activeAudit?.id, 'a1');
      expect(provider.allLocations.single.id, 'l1');
      expect(provider.auditeeCandidates.single.id, 'e1');
    });

    test('a request that fails after logout does not touch the next account\'s audit list', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchMyAudits,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoading,
        error: () => provider.errorMessage,
      );
    });

    test('nor its open audit', () {
      return expectStaleFailureIgnored(
        fetch: () => provider.fetchAuditDetail('a1'),
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingDetail,
        error: () => provider.detailError,
        freshBody: {'data': {'_id': 'a1'}},
      );
    });

    test('nor its reports', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchReportAudits,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingReports,
        error: () => provider.reportsError,
      );
    });

    test('nor its audits at its locations', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchAuditsAtMyLocation,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingAtMyLocation,
        error: () => null, // fails quietly by design
      );
    });
  });

  group('TicketsProvider', () {
    late TicketsProvider provider;
    setUp(() => provider = TicketsProvider());

    test('logout empties the list, the open ticket and their state', () async {
      await provider.fetchTickets();
      await provider.fetchTicketDetail('t1');
      expect(provider.tickets, isNotEmpty);
      expect(provider.activeTicket, isNotNull);

      provider.resetForLogout();

      expect(provider.tickets, isEmpty);
      expect(provider.activeTicket, isNull);
      expect(provider.listError, isNull);
      expect(provider.detailError, isNull);
      expect(provider.isLoadingList, isFalse);
      expect(provider.isLoadingDetail, isFalse);
    });

    test('a list and an open ticket that were on the wire at logout are dropped', () async {
      gate = Completer<void>();
      final fetches = [provider.fetchTickets(), provider.fetchTicketDetail('t1')];
      await settle();

      provider.resetForLogout();
      gate.complete();
      await Future.wait(fetches);

      expect(provider.tickets, isEmpty);
      expect(provider.activeTicket, isNull);
      expect(provider.isLoadingList, isFalse);
      expect(provider.isLoadingDetail, isFalse);
    });

    test('a request that fails after logout does not touch the next account\'s list', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchTickets,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingList,
        error: () => provider.listError,
      );
    });

    test('a ticket created just before logout is not put into the next account\'s list', () async {
      gate = Completer<void>();
      final creating = provider.createTicket(subject: 's', description: 'd', priority: 'Low');
      await settle();

      provider.resetForLogout();
      gate.complete();

      expect(await creating, isNull, reason: 'it was created on the server all the same');
      expect(provider.tickets, isEmpty);
    });

    test('a reply that is answered after logout neither opens its ticket nor ends the next send', () async {
      provider.openTicketRoom('t1');
      gate = Completer<void>();
      final replying = provider.reply(ticketId: 't1', message: 'hello');
      await settle();
      expect(provider.isSendingReply, isTrue);

      provider.resetForLogout(); // the next account starts a reply of its own
      provider.isSendingReply = true;
      gate.complete();
      await replying;

      expect(provider.activeTicket, isNull);
      expect(provider.isSendingReply, isTrue, reason: 'the previous account\'s reply ended the next one\'s sending state');
      provider.closeTicketRoom('t1');
    });

    test('a list that lands while the account is still the current one is kept', () async {
      await provider.fetchTickets();
      expect(provider.tickets.single.id, 't1');
      expect(provider.isLoadingList, isFalse);
    });
  });

  group('DashboardProvider', () {
    late DashboardProvider provider;
    setUp(() => provider = DashboardProvider());

    test('logout zeroes the tiles and the scores', () async {
      await provider.refreshAll();
      expect(provider.stats.assignedAudits, 9);
      expect(provider.auditeeStats.total, 12);

      provider.resetForLogout();

      expect(provider.stats.assignedAudits, 0);
      expect(provider.stats.inProgress, 0);
      expect(provider.auditeeStats.total, 0);
      expect(provider.errorMessage, isNull);
    });

    test('an answer that was on the wire at logout is dropped', () async {
      gate = Completer<void>();
      final inFlight = provider.refreshAll();
      await settle();

      provider.resetForLogout();
      gate.complete();
      await inFlight;

      expect(provider.stats.assignedAudits, 0);
      expect(provider.auditeeStats.total, 0);
    });

    test('a request that fails after logout does not touch the next account\'s tiles', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchStats,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoading,
        error: () => provider.errorMessage,
        freshBody: {'data': {}},
      );
    });

    test('nor its NC summary', () {
      return expectStaleFailureIgnored(
        fetch: provider.fetchAuditeeStats,
        signOut: provider.resetForLogout,
        loading: () => provider.isLoadingAuditee,
        error: () => provider.auditeeErrorMessage,
        freshBody: {'data': {}},
      );
    });

    test('the previous employee\'s id is not sent for the next account', () async {
      provider.setSelfEmployeeId('employee-A');
      provider.resetForLogout();
      adapter.requests.clear();

      await provider.fetchStats();
      expect(adapter.requests.single.queryParameters, isNot(contains('employeeIds')));
    });
  });

  test('a failed request still surfaces its error to a session that is still current', () async {
    adapter.handler = (o) async => connectionError(o);
    final provider = NotificationsProvider();
    await provider.fetchNotifications();
    expect(provider.errorMessage, isNotNull);
    expect(provider.isLoading, isFalse);
    provider.resetForLogout();
  });
}
