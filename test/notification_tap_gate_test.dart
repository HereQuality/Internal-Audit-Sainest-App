import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/notifications/notification_navigation.dart';
import 'package:internal_audit_app/models/maintenance_status.dart';
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/app_update_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/maintenance_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

class _ForceUpdate extends AppUpdateProvider {
  @override
  bool get isForceUpdateRequired => true;
}

UserModel _user(String roleType) =>
    UserModel(id: 'u1', roleType: roleType, name: 'n', username: 'u', email: 'e', mobileNumber: 'm');

/// A notification tap on a live process must never push a record over a
/// login / update / maintenance screen; it is held and applied once the app
/// can act on it (main.dart's _RootGate takes it). The launch tap is read
/// from two sources that must not cost each other their read.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('notificationTapsAllowed', () {
    test('only signed in, past the update gate, and not blocked by maintenance', () {
      bool allowed(AuthStatus s, {bool update = false, bool maintenance = false}) => notificationTapsAllowed(
            status: s,
            forceUpdateRequired: update,
            maintenanceBlocked: maintenance,
          );
      expect(allowed(AuthStatus.authenticated), isTrue);
      expect(allowed(AuthStatus.unauthenticated), isFalse);
      expect(allowed(AuthStatus.unknown), isFalse);
      expect(allowed(AuthStatus.offline), isFalse);
      expect(allowed(AuthStatus.authenticated, update: true), isFalse);
      expect(allowed(AuthStatus.authenticated, maintenance: true), isFalse);
    });
  });

  group('the held tap', () {
    tearDown(clearHeldNotificationTap);

    test('is handed out once', () {
      holdNotificationTap('audit_assigned|a1');
      expect(takeHeldNotificationTap(), 'audit_assigned|a1');
      expect(takeHeldNotificationTap(), isNull);
    });

    test('a newer tap replaces it', () {
      holdNotificationTap('audit_assigned|a1');
      holdNotificationTap('nc_raised|n1');
      expect(takeHeldNotificationTap(), 'nc_raised|n1');
    });

    test('is forgotten on logout', () {
      holdNotificationTap('audit_assigned|a1');
      clearHeldNotificationTap();
      expect(takeHeldNotificationTap(), isNull);
    });
  });

  group('resolveLaunchPayload', () {
    const quick = Duration(milliseconds: 50);

    test('an iOS push tap survives the local read throwing', () async {
      final payload = await resolveLaunchPayload(
        local: () async => throw StateError('channel broke'),
        fcm: () async => 'nc_raised|n1',
      );
      expect(payload, 'nc_raised|n1');
    });

    test('an iOS push tap survives the local read hanging', () async {
      final payload = await resolveLaunchPayload(
        local: () => Completer<String?>().future,
        fcm: () async => 'nc_raised|n1',
        timeout: quick,
      );
      expect(payload, 'nc_raised|n1');
    });

    test('a local banner tap survives the FCM read failing or hanging', () async {
      expect(
        await resolveLaunchPayload(
          local: () async => 'audit_assigned|a1',
          fcm: () async => throw StateError('no Firebase'),
        ),
        'audit_assigned|a1',
      );
      expect(
        await resolveLaunchPayload(
          local: () async => 'audit_assigned|a1',
          fcm: () => Completer<String?>().future,
          timeout: quick,
        ),
        'audit_assigned|a1',
      );
    });

    test('the local read wins when both have something; nothing is null', () async {
      expect(
        await resolveLaunchPayload(local: () async => 'local|1', fcm: () async => 'fcm|2'),
        'local|1',
      );
      expect(await resolveLaunchPayload(local: () async => null, fcm: () async => null), isNull);
    });

    test('both sources hanging costs one timeout, not two', () async {
      final watch = Stopwatch()..start();
      final payload = await resolveLaunchPayload(
        local: () => Completer<String?>().future,
        fcm: () => Completer<String?>().future,
        timeout: const Duration(milliseconds: 200),
      );
      expect(payload, isNull);
      expect(watch.elapsedMilliseconds, lessThan(380));
    });
  });

  group('handleLocalNotificationTap', () {
    late FakeAdapter adapter;
    late AuthProvider auth;
    late AppUpdateProvider appUpdate;
    late MaintenanceProvider maintenance;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      adapter = FakeAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
      SocketService.debugInstance = FakeSockets().service;
      auth = AuthProvider();
      appUpdate = AppUpdateProvider();
      maintenance = MaintenanceProvider();
      clearHeldNotificationTap();
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
              ChangeNotifierProvider<AppUpdateProvider>.value(value: appUpdate),
              ChangeNotifierProvider<MaintenanceProvider>.value(value: maintenance),
              ChangeNotifierProvider(create: (_) => NcProvider()),
            ],
            child: MaterialApp(
              navigatorKey: notificationNavigatorKey,
              home: const Scaffold(body: Text('root')),
            ),
          ),
        );

    // 'nc_*' is the routed type that fetches first, so "it tried to open the
    // record" is observable without building a real screen.
    const payload = 'nc_raised|nc1';
    bool openedRecord() => adapter.where('GET', ApiConstants.ncDetail('nc1')).isNotEmpty;
    // The record's fetch runs on real async work (storage, HTTP), which a
    // widget test's fake clock doesn't advance — so the tap itself happens
    // inside runAsync, where its futures are real ones.
    Future<void> tap(WidgetTester tester, String? p) => tester.runAsync(() async {
          handleLocalNotificationTap(p);
          await settle(20);
        }).then((_) {});

    testWidgets('signed out: held, nothing opened', (tester) async {
      auth.status = AuthStatus.unauthenticated;
      await mount(tester);

      await tap(tester, payload);

      expect(openedRecord(), isFalse);
      expect(takeHeldNotificationTap(), payload);
    });

    testWidgets('still confirming the saved session (offline / starting): held', (tester) async {
      await mount(tester);
      for (final status in [AuthStatus.unknown, AuthStatus.offline]) {
        auth.status = status;
        handleLocalNotificationTap(payload);
        expect(takeHeldNotificationTap(), payload, reason: '$status');
      }
      expect(openedRecord(), isFalse);
    });

    testWidgets('force-update screen up: held', (tester) async {
      appUpdate = _ForceUpdate();
      auth.status = AuthStatus.authenticated;
      await mount(tester);

      handleLocalNotificationTap(payload);

      expect(openedRecord(), isFalse);
      expect(takeHeldNotificationTap(), payload);
    });

    testWidgets('maintenance blocking this user: held; a SuperAdmin is not blocked', (tester) async {
      maintenance.status = const MaintenanceStatus(isActive: true, message: '');
      auth.status = AuthStatus.authenticated;
      auth.user = _user('Employee');
      await mount(tester);

      handleLocalNotificationTap(payload);
      expect(openedRecord(), isFalse);
      expect(takeHeldNotificationTap(), payload);

      auth.user = _user('SuperAdmin');
      await tap(tester, payload);
      expect(takeHeldNotificationTap(), isNull);
      expect(openedRecord(), isTrue);
    });

    testWidgets('signed in and nothing blocking: opened at once, not held', (tester) async {
      auth.status = AuthStatus.authenticated;
      await mount(tester);

      await tap(tester, payload);

      expect(openedRecord(), isTrue);
      expect(takeHeldNotificationTap(), isNull);
    });

    testWidgets('a held tap is applied once the gate clears (what _RootGate does)', (tester) async {
      auth.status = AuthStatus.unauthenticated;
      await mount(tester);
      handleLocalNotificationTap(payload);
      expect(openedRecord(), isFalse);

      auth.status = AuthStatus.authenticated; // signed in
      final held = takeHeldNotificationTap();
      await tap(tester, held);

      expect(openedRecord(), isTrue);
      expect(takeHeldNotificationTap(), isNull);
    });

    testWidgets('no navigator mounted yet: held rather than dropped', (tester) async {
      auth.status = AuthStatus.authenticated;
      handleLocalNotificationTap(payload);
      expect(takeHeldNotificationTap(), payload);
    });

    testWidgets('a payload that routes nowhere is ignored, not held', (tester) async {
      auth.status = AuthStatus.unauthenticated;
      await mount(tester);
      handleLocalNotificationTap('');
      handleLocalNotificationTap(null);
      handleLocalNotificationTap('no separator');
      expect(takeHeldNotificationTap(), isNull);
    });
  });
}
