import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/notifications/notification_navigation.dart';
import 'package:internal_audit_app/core/notifications/notification_scheduler.dart';
import 'package:internal_audit_app/main.dart' show RootGate;
import 'package:internal_audit_app/models/maintenance_status.dart';
import 'package:internal_audit_app/models/notification_model.dart';
import 'package:internal_audit_app/models/ticket_model.dart';
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/announcement_provider.dart';
import 'package:internal_audit_app/providers/app_mode_provider.dart';
import 'package:internal_audit_app/providers/app_update_provider.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/maintenance_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/providers/notifications_provider.dart';
import 'package:internal_audit_app/providers/tickets_provider.dart';
import 'package:internal_audit_app/screens/auth/login_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

class _GatedUpdate extends AppUpdateProvider {
  bool blocked = false;
  @override
  bool get isForceUpdateRequired => blocked;
  void poke() => notifyListeners();
}

UserModel _user(String roleType) =>
    UserModel(id: 'u1', roleType: roleType, name: 'n', username: 'u', email: 'e', mobileNumber: 'm');

/// main.dart's root gate: what is on screen for each session state, and what
/// it does on the way out of a session (reset the previous account's data,
/// close screens left over it) and once a notification tap can be acted on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late AuthProvider auth;
  late _GatedUpdate appUpdate;
  late MaintenanceProvider maintenance;
  late AppModeProvider appMode;
  late NotificationsProvider notifications;
  late NcProvider ncs;
  late AuditsProvider audits;
  late DashboardProvider dashboard;
  late TicketsProvider tickets;

  const tapPayload = 'nc_raised|nc1';
  bool openedRecord() => adapter.where('GET', ApiConstants.ncDetail('nc1')).isNotEmpty;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    NotificationScheduler.clearTray = () async {};
    adapter = FakeAdapter()
      ..handler = (o) async => o.path == ApiConstants.maintenanceStatus
          ? json(200, {'data': {'isActive': false, 'message': ''}})
          : json(404, {'isOk': false});
    DioClient.instance.dio.httpClientAdapter = adapter;
    SocketService.debugInstance = FakeSockets().service;
    clearHeldNotificationTap();

    auth = AuthProvider();
    appUpdate = _GatedUpdate();
    maintenance = MaintenanceProvider();
    appMode = AppModeProvider()..loaded = true; // picker screen: the simplest signed-in content
    notifications = NotificationsProvider();
    ncs = NcProvider();
    audits = AuditsProvider();
    dashboard = DashboardProvider();
    tickets = TicketsProvider();
  });

  tearDown(() {
    auth.dispose();
    DioClient.instance.onUnauthorized = null;
    clearHeldNotificationTap();
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<AppModeProvider>.value(value: appMode),
            ChangeNotifierProvider<AppUpdateProvider>.value(value: appUpdate),
            ChangeNotifierProvider<MaintenanceProvider>.value(value: maintenance),
            ChangeNotifierProvider(create: (_) => AnnouncementProvider()),
            ChangeNotifierProvider<NotificationsProvider>.value(value: notifications),
            ChangeNotifierProvider<NcProvider>.value(value: ncs),
            ChangeNotifierProvider<AuditsProvider>.value(value: audits),
            ChangeNotifierProvider<DashboardProvider>.value(value: dashboard),
            ChangeNotifierProvider<TicketsProvider>.value(value: tickets),
            ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ],
          child: MaterialApp(
            navigatorKey: notificationNavigatorKey,
            home: const RootGate(),
          ),
        ),
      );

  // Dio's request pipeline hops through zero-duration timers, which the
  // widget-test clock only runs when it is advanced.
  Future<void> settleUi(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  // The status flips the way AuthProvider does it, then listeners are told.
  Future<void> setStatus(WidgetTester tester, AuthStatus status, {String role = 'SuperAdmin'}) async {
    auth.status = status;
    auth.updateUser(_user(role));
    await settleUi(tester);
  }

  group('offline screen', () {
    testWidgets('a kept session that cannot be confirmed shows the retry screen, not the login screen', (tester) async {
      auth.status = AuthStatus.offline;
      await mount(tester);

      expect(find.text("Can't reach the server"), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
    });

    testWidgets('Try again asks the server again', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'auth_token': 'jwt-saved'});
      // The server says the saved session is over: that ends it (a "still
      // unreachable" answer would leave the next retry's timer pending).
      adapter.handler = (o) async => json(o.path == ApiConstants.me ? 401 : 404, {});
      auth.status = AuthStatus.offline;
      await mount(tester);

      await tester.tap(find.text('Try again'));
      await settleUi(tester);

      expect(adapter.where('GET', ApiConstants.me), hasLength(1));
    });

    testWidgets('Sign out leaves the session for the login screen', (tester) async {
      auth.status = AuthStatus.offline;
      await mount(tester);

      await tester.tap(find.text('Sign out'));
      await settleUi(tester);

      expect(auth.status, AuthStatus.unauthenticated);
      expect(find.byType(LoginScreen), findsOneWidget);
    });
  });

  group('leaving a session', () {
    testWidgets('clears the account\'s data, closes screens left over the login, drops its held tap', (tester) async {
      await mount(tester);
      await setStatus(tester, AuthStatus.authenticated);
      expect(find.byType(LoginScreen), findsNothing);

      notifications.notifications = [
        const NotificationModel(id: 'n1', title: 'Old account', message: '', type: 'audit_assigned', isRead: false),
      ];
      notifications.unreadCount = 3;
      tickets.tickets = [TicketModel.fromJson({'_id': 't1', 'subject': 'Old account ticket'})];
      ncs.setSelfEmployeeId('employee-A');
      holdNotificationTap('audit_assigned|a1'); // a tap still waiting when the session ends
      notificationNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('A deep screen')),
      );
      await settleUi(tester);
      expect(find.text('A deep screen'), findsOneWidget);

      await setStatus(tester, AuthStatus.unauthenticated);
      await settleUi(tester);

      expect(find.text('A deep screen'), findsNothing, reason: 'a screen stayed over the login screen');
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(notifications.notifications, isEmpty);
      expect(notifications.unreadCount, 0);
      expect(tickets.tickets, isEmpty);
      expect(takeHeldNotificationTap(), isNull);
    });
  });

  group('leaving a session with a request on the wire', () {
    testWidgets('a support-ticket list that lands after sign-out is not put back for the next account', (tester) async {
      final gate = Completer<void>();
      adapter.handler = (o) async {
        if (o.path != ApiConstants.tickets) return json(404, {'isOk': false});
        await gate.future;
        return json(200, {
          'data': [
            {'_id': 't1', 'subject': 'Old account ticket'},
          ],
        });
      };
      await mount(tester);
      await setStatus(tester, AuthStatus.authenticated);
      unawaited(tickets.fetchTickets());
      await settleUi(tester);
      expect(tickets.isLoadingList, isTrue);

      await setStatus(tester, AuthStatus.unauthenticated);
      await settleUi(tester);
      gate.complete(); // the previous account's answer arrives only now
      await settleUi(tester);

      expect(tickets.tickets, isEmpty);
      expect(tickets.isLoadingList, isFalse);
    });
  });

  group('a notification tap that had to wait', () {
    testWidgets('applies once signed in (cold start or a tap on the login screen), only once', (tester) async {
      holdNotificationTap(tapPayload);
      auth.status = AuthStatus.unauthenticated;
      await mount(tester);
      await settleUi(tester);
      expect(openedRecord(), isFalse);

      await setStatus(tester, AuthStatus.authenticated);
      expect(openedRecord(), isTrue);
      expect(adapter.where('GET', ApiConstants.ncDetail('nc1')), hasLength(1));

      adapter.requests.clear();
      await setStatus(tester, AuthStatus.authenticated); // any later rebuild
      expect(openedRecord(), isFalse);
    });

    testWidgets('waits for the force-update screen, then applies', (tester) async {
      appUpdate.blocked = true;
      auth.status = AuthStatus.authenticated;
      auth.user = _user('SuperAdmin');
      holdNotificationTap(tapPayload);
      await mount(tester);
      await settleUi(tester);
      expect(openedRecord(), isFalse);

      appUpdate.blocked = false;
      appUpdate.poke();
      await settleUi(tester);
      expect(openedRecord(), isTrue);
    });

    testWidgets('waits for maintenance to end for a non-SuperAdmin, then applies', (tester) async {
      maintenance.status = const MaintenanceStatus(isActive: true, message: '');
      auth.status = AuthStatus.authenticated;
      auth.user = _user('Employee');
      holdNotificationTap(tapPayload);
      await mount(tester);
      await settleUi(tester);
      expect(openedRecord(), isFalse);

      await tester.runAsync(maintenance.refreshNow); // the server says it is over
      await settleUi(tester);
      expect(openedRecord(), isTrue);
    });

    testWidgets('a warm tap on the login screen is held and applied after sign-in', (tester) async {
      auth.status = AuthStatus.unauthenticated;
      await mount(tester);

      handleLocalNotificationTap(tapPayload);
      await settleUi(tester);
      expect(openedRecord(), isFalse);

      await setStatus(tester, AuthStatus.authenticated);
      expect(openedRecord(), isTrue);
    });
  });
}
