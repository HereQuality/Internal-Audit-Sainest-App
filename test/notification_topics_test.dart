import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/notifications/event_poll.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/notifications/notification_prefs.dart';
import 'package:internal_audit_app/core/notifications/overdue_poll.dart';
import 'package:internal_audit_app/core/notifications/push_check.dart' show PushRegistration;
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/profile_provider.dart';
import 'package:internal_audit_app/providers/theme_provider.dart';
import 'package:internal_audit_app/screens/profile/settings_screen.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the server's GET/PUT /auth/me/preferences: keeps the state,
/// merges every PUT the way profile.controller.js does, answers with the full
/// effective preferences, and can be told to hold or refuse a PUT.
class _FakeServer implements HttpClientAdapter {
  final Map<String, bool> email = {
    for (final t in kNotificationTopics)
      if (t.emailApplies) t.key: true,
  };
  final Map<String, bool> push = {
    for (final t in kNotificationTopics) t.key: true,
  };
  bool emailMaster = true;
  bool pushMaster = true;
  final List<Map<String, dynamic>> puts = [];
  Completer<void>? hold;
  bool refuse = false;

  // The phone's own push registration: POST /device-tokens/register (answered
  // by registerStatus/registerBody, and held while registerHold is set) and
  // the test push, POST /device-tokens/test (its bodies are kept).
  int registerStatus = 200;
  Map<String, dynamic> registerBody = {'isOk': true, 'pushReady': true};
  Completer<void>? registerHold;
  Map<String, dynamic> testBody = _testAnswer(ok: true);
  final List<Map<String, dynamic>> tests = [];

  Map<String, dynamic> get payload => {
    'emailNotifications': emailMaster,
    'pushNotifications': pushMaster,
    'themeMode': 'light',
    'showDashboardClock': true,
    'shortcuts': <String>[],
    'emailNotificationTypes': Map<String, bool>.from(email),
    'pushNotificationTypes': Map<String, bool>.from(push),
  };

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' && options.path == ApiConstants.deviceTokenRegister) {
      await registerHold?.future;
      return _json(registerBody, registerStatus);
    }
    if (options.method == 'POST' && options.path == ApiConstants.deviceTokenTest) {
      tests.add(Map<String, dynamic>.from(options.data as Map));
      return _json(testBody, 200);
    }
    if (options.method == 'PUT') {
      final body = Map<String, dynamic>.from(options.data as Map);
      puts.add(body);
      await hold?.future;
      if (refuse) return _json({'isOk': false, 'message': 'Server says no'}, 500);
      if (body['emailNotifications'] is bool) emailMaster = body['emailNotifications'] as bool;
      if (body['pushNotifications'] is bool) pushMaster = body['pushNotifications'] as bool;
      email.addAll(UserPreferences.parseTypeMap(body['emailNotificationTypes']));
      push.addAll(UserPreferences.parseTypeMap(body['pushNotificationTypes']));
    }
    return _json({'isOk': true, 'data': payload}, 200);
  }

  @override
  void close({bool force = false}) {}
}

/// The server's answer to a test push aimed at this phone's token: one row.
Map<String, dynamic> _testAnswer({required bool ok, String? code, String? hint}) => {
  'isOk': true,
  'data': {
    'sent': ok ? 1 : 0,
    'failed': ok ? 0 : 1,
    'results': [
      {
        'tokenId': 'row-1',
        'platform': 'android',
        'ok': ok,
        'code': ok ? null : code,
        'hint': ?hint,
      },
    ],
    'serverProjects': ['proj-server'],
  },
};

UserModel _user() => const UserModel(
  id: 'u1',
  roleType: 'Employee',
  name: 'Asha',
  username: 'asha',
  email: 'asha@example.com',
  mobileNumber: '9876543210',
);

Finder _rowSwitches(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Row)).first,
  matching: find.byType(Switch),
);

bool _isOn(WidgetTester tester, Finder switches, int index) =>
    tester.widget<Switch>(switches.at(index)).value;

bool _isEnabled(WidgetTester tester, Finder switches, int index) =>
    tester.widget<Switch>(switches.at(index)).onChanged != null;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeServer server;
  late AuthProvider auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    server = _FakeServer();
    final dio = DioClient.instance.dio;
    dio.interceptors.clear();
    dio.httpClientAdapter = server;
    // permission_handler asks the OS through this channel; 1 = granted.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter.baseflow.com/permissions/methods'),
          (call) async => call.method == 'checkPermissionStatus' ? 1 : null,
        );
    auth = AuthProvider()..user = _user();
  });

  Future<void> openSettings(WidgetTester tester, {double width = 360}) async {
    tester.view.physicalSize = Size(width, 5200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider(create: (_) => ProfileProvider()),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    // initState's refreshPreferences + the permission read.
    await tester.pumpAndSettle();
  }

  group('UserPreferences', () {
    test('a payload without the per-topic maps reads every topic as on', () {
      final prefs = UserPreferences.fromJson({'pushNotifications': true});
      expect(prefs.pushTypeOn('nc_rejected'), isTrue);
      expect(prefs.emailTypeOn('morning_summary'), isTrue);
    });

    test('non-boolean entries are ignored, booleans kept', () {
      final prefs = UserPreferences.fromJson({
        'pushNotificationTypes': {'nc_raised': false, 'nc_overdue': 'nope'},
        'emailNotificationTypes': 'garbage',
      });
      expect(prefs.pushTypeOn('nc_raised'), isFalse);
      expect(prefs.pushTypeOn('nc_overdue'), isTrue);
      expect(prefs.emailNotificationTypes, isEmpty);
    });

    test('a socket event merges the maps key by key and keeps what it omits', () {
      const held = UserPreferences(
        emailNotifications: false,
        pushNotificationTypes: {'nc_raised': false, 'audit_created': false},
        emailNotificationTypes: {'nc_raised': false},
      );
      final merged = held.mergedWithEvent({
        'pushNotifications': false,
        'pushNotificationTypes': {'audit_created': true},
      });
      expect(merged.emailNotifications, isFalse);
      expect(merged.pushNotifications, isFalse);
      expect(merged.pushNotificationTypes, {'nc_raised': false, 'audit_created': true});
      expect(merged.emailNotificationTypes, {'nc_raised': false});
    });

    test('an old server that sends only the masters leaves the maps alone', () {
      const held = UserPreferences(pushNotificationTypes: {'nc_raised': false});
      final merged = held.mergedWithEvent({'emailNotifications': false});
      expect(merged.emailNotifications, isFalse);
      expect(merged.pushNotificationTypes, {'nc_raised': false});
    });
  });

  group('NotificationPrefs mirror', () {
    test('needs the master AND the topic, unknown topics follow the master', () async {
      await NotificationPrefs.setPushEnabled(true);
      await NotificationPrefs.setPushTypes({'nc_rejected': false});
      expect(await NotificationPrefs.readPushAllowed('nc_rejected'), isFalse);
      expect(await NotificationPrefs.readPushAllowed('nc_raised'), isTrue);
      expect(await NotificationPrefs.readPushAllowed('something_new'), isTrue);
      expect(await NotificationPrefs.readPushAllowed(''), isTrue);

      await NotificationPrefs.setPushEnabled(false);
      expect(await NotificationPrefs.readPushAllowed('nc_raised'), isFalse);
      expect(await NotificationPrefs.readPushAllowed('something_new'), isFalse);
    });

    test('an empty or corrupt mirror reads as every topic on', () async {
      expect(await NotificationPrefs.readPushTypeEnabled('nc_raised'), isTrue);
      SharedPreferences.setMockInitialValues({'notif_push_types': '{not json'});
      expect(await NotificationPrefs.readPushTypeEnabled('nc_raised'), isTrue);
    });

    test('signing out wipes the topic mirror', () async {
      await NotificationPrefs.setPushTypes({'nc_raised': false});
      await NotificationPrefs.clearSession();
      expect(await NotificationPrefs.readPushTypeEnabled('nc_raised'), isTrue);
    });

    test('the catalog covers every type once, in the four groups', () {
      final keys = kNotificationTopics.map((t) => t.key).toList();
      expect(keys.toSet().length, keys.length);
      expect(keys.length, 18);
      expect(
        kNotificationTopics.where((t) => !t.emailApplies).map((t) => t.key),
        ['audit_reminder'],
      );
      expect(
        kNotificationTopics.map((t) => t.group).toSet(),
        kNotificationGroups.toSet(),
      );
    });
  });

  group('Settings screen', () {
    testWidgets('lists every topic under its group, audit reminders push only', (tester) async {
      await openSettings(tester);
      for (final group in kNotificationGroups) {
        expect(find.text(group), findsOneWidget);
      }
      for (final topic in kNotificationTopics) {
        expect(find.text(topic.label), findsOneWidget, reason: topic.label);
        expect(
          _rowSwitches(topic.label),
          findsNWidgets(topic.emailApplies ? 2 : 1),
          reason: topic.label,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a 320 wide phone without overflowing', (tester) async {
      await openSettings(tester, width: 320);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a phone with notifications allowed can send itself a test push', (tester) async {
      await openSettings(tester, width: 320);
      final button = find.text('Send a test notification');
      expect(button, findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      // Firebase isn't initialised in a unit test, so the check says so plainly
      // instead of failing silently or throwing.
      expect(find.text("Push isn't set up in this build"), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text("Push isn't set up in this build"), findsNothing);
      expect(find.text('Send a test notification'), findsOneWidget);
    });

    testWidgets('with the Push switch off there is no test button', (tester) async {
      server.pushMaster = false;
      await openSettings(tester);
      expect(find.text('Send a test notification'), findsNothing);
    });

    testWidgets('one switch sends BOTH channel values of its topic, then the mirror follows', (tester) async {
      server.email['audit_reassigned'] = false;
      await openSettings(tester);
      final row = _rowSwitches('Audit reassigned');
      expect(_isOn(tester, row, 0), isFalse);
      expect(_isOn(tester, row, 1), isTrue);

      await tester.tap(row.at(1));
      await tester.pumpAndSettle();

      expect(server.puts, hasLength(1));
      expect(server.puts.single, {
        'emailNotificationTypes': {'audit_reassigned': false},
        'pushNotificationTypes': {'audit_reassigned': false},
      });
      expect(_isOn(tester, row, 0), isFalse);
      expect(_isOn(tester, row, 1), isFalse);
      expect(auth.user!.preferences.pushTypeOn('audit_reassigned'), isFalse);
      expect(await NotificationPrefs.readPushAllowed('audit_reassigned'), isFalse);
      expect(await NotificationPrefs.readPushAllowed('audit_created'), isTrue);
    });

    testWidgets('moves at once, and snaps back with an error when the server refuses', (tester) async {
      await openSettings(tester);
      server
        ..hold = Completer<void>()
        ..refuse = true;
      final row = _rowSwitches('NC response rejected');

      await tester.tap(row.at(0));
      await tester.pump();
      expect(_isOn(tester, row, 0), isFalse, reason: 'optimistic while the request is out');

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(_isOn(tester, row, 0), isTrue, reason: 'rolled back');
      expect(find.text('Server says no'), findsOneWidget);
      expect(auth.user!.preferences.emailTypeOn('nc_rejected'), isTrue);
    });

    testWidgets('saves queue up: each response keeps the earlier changes on screen', (tester) async {
      await openSettings(tester);
      server.hold = Completer<void>();
      final first = _rowSwitches('NC raised');
      final second = _rowSwitches('NC overdue');

      await tester.tap(first.at(1));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(second.at(1));
      await tester.pump(const Duration(milliseconds: 20));
      expect(server.puts, hasLength(1), reason: 'the second waits for the first');

      server.hold!.complete();
      await tester.pumpAndSettle();
      expect(server.puts, hasLength(2));
      expect(_isOn(tester, first, 1), isFalse);
      expect(_isOn(tester, second, 1), isFalse);
      expect(server.push['nc_raised'], isFalse);
      expect(server.push['nc_overdue'], isFalse);
    });

    testWidgets('a group shortcut sets a whole column and still sends both channels', (tester) async {
      server.push['audit_skipped'] = false;
      await openSettings(tester);

      await tester.tap(find.text('Email').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('All off'));
      await tester.pumpAndSettle();

      final audits = kNotificationTopics.where((t) => t.group == kNotificationGroupAudits);
      expect(server.puts, hasLength(1));
      expect(
        server.puts.single['emailNotificationTypes'],
        {for (final t in audits) if (t.emailApplies) t.key: false},
      );
      // Push values ride along untouched, audit_reminder (no email) included.
      expect(
        server.puts.single['pushNotificationTypes'],
        {for (final t in audits) t.key: t.key != 'audit_skipped'},
      );
      expect(_isOn(tester, _rowSwitches('Audit completed'), 0), isFalse);
      expect(_isOn(tester, _rowSwitches('NC raised'), 0), isTrue, reason: 'other groups untouched');
    });

    testWidgets('a master that is off locks and greys its column but keeps the values', (tester) async {
      server
        ..pushMaster = false
        ..push['nc_raised'] = false;
      await openSettings(tester);

      final row = _rowSwitches('NC raised');
      expect(_isEnabled(tester, row, 0), isTrue, reason: 'email master is on');
      expect(_isEnabled(tester, row, 1), isFalse);
      expect(_isOn(tester, row, 1), isFalse, reason: 'stored value stays visible');
      expect(find.text('Turn on Push notifications above to choose.'), findsOneWidget);
      expect(find.text('Turn on Email notifications above to choose.'), findsNothing);

      await tester.tap(find.text('Push').first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('All on'), findsNothing, reason: 'shortcut menu stays shut');
      expect(server.puts, isEmpty);
    });
  });

  // The line under the Push switch: "Active" only when the OS permission, this
  // phone's registration and the server can all deliver — and each way it can
  // not, said as what it is.
  group('Push status line', () {
    const permissionsChannel = MethodChannel('flutter.baseflow.com/permissions/methods');
    // What the fake OS answers: permission_handler's status (0 denied, 1
    // granted, 4 permanently denied) and whether Android would still show its
    // dialog (the "rationale" answer).
    late int osStatus;
    late bool osCanAsk;
    late Object? osRationaleError;
    late List<String> osCalls;

    setUp(() {
      osStatus = 1;
      osCanAsk = false;
      osRationaleError = null;
      osCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(permissionsChannel, (call) async {
            osCalls.add(call.method);
            switch (call.method) {
              case 'checkPermissionStatus':
                return osStatus;
              case 'shouldShowRequestPermissionRationale':
                final error = osRationaleError;
                if (error != null) throw error;
                return osCanAsk;
              case 'requestPermissions':
                return {Permission.notification.value: osStatus};
              case 'openAppSettings':
                return true;
            }
            return null;
          });
      // A signed-in phone: the session mirror is what lets a registration run.
      SharedPreferences.setMockInitialValues({'bg_auth_token': 'jwt'});
      FcmService.debugReset();
      FcmService.postRetryPause = Duration.zero;
      FcmService.retryDelays = const [];
      FcmService.getFcmToken = () async => 'tok-1';
    });

    tearDown(FcmService.debugReset);

    // Firebase "configured" and this phone's registration attempted once, the
    // way the login does it (outside the widget's fake clock).
    Future<void> registerPhone(WidgetTester tester) async {
      FcmService.debugSetInitialized(true);
      await tester.runAsync(FcmService.registerToken);
    }

    testWidgets('a build without Firebase never claims to be active', (tester) async {
      await openSettings(tester);

      expect(find.text('Active on this phone'), findsNothing);
      expect(find.text("Phone push isn't available in this build"), findsOneWidget);
    });

    testWidgets('permission allowed, token registered, server able to send: active', (tester) async {
      await registerPhone(tester);
      await openSettings(tester);

      expect(find.text('Active on this phone'), findsOneWidget);
      expect(find.text('Send a test notification'), findsOneWidget);
    });

    testWidgets('registered but the server cannot send: says so, without the server\'s internals', (tester) async {
      server.registerBody = {
        'isOk': true,
        'pushReady': false,
        'problem': 'No credentials for Firebase project "internal-audit-c7c2b" (FIREBASE_SERVICE_ACCOUNT_PATH).',
      };
      await registerPhone(tester);
      await openSettings(tester);

      expect(find.text('Active on this phone'), findsNothing);
      expect(find.text("Registered, but the server can't send to this phone"), findsOneWidget);
      expect(find.textContaining('Send a test notification'), findsWidgets);
      expect(find.textContaining('internal-audit-c7c2b'), findsNothing);

      // The reason itself is one tap away, in the test's own dialog.
      await tester.tap(find.text('Send a test notification'));
      await tester.pumpAndSettle();
      expect(find.text("The server can't push to this phone"), findsOneWidget);
      expect(find.textContaining('internal-audit-c7c2b'), findsOneWidget);
      expect(server.tests, isEmpty, reason: 'nothing to send while the server cannot');
    });

    testWidgets('a registration that keeps failing: not registered, with a Try again that works', (tester) async {
      server.registerStatus = 503;
      await registerPhone(tester);
      await openSettings(tester);

      expect(find.text('Active on this phone'), findsNothing);
      expect(find.text("This phone isn't registered for push yet"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);

      server.registerStatus = 200; // the connection is back
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text('Active on this phone'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('opening Settings retries a registration that ran out of retries', (tester) async {
      server.registerStatus = 503;
      await registerPhone(tester); // the login-time attempt: gone, no retry left
      expect(FcmService.registrationState, PushRegistration.notRegistered);

      server.registerStatus = 200; // the connection is back, nobody tapped anything
      await openSettings(tester);

      expect(find.text('Active on this phone'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('Try again shows an attempt under way at once, then the result', (tester) async {
      server.registerStatus = 503;
      SharedPreferences.setMockInitialValues({}); // opening Settings starts no attempt of its own
      await registerPhone(tester);
      await openSettings(tester);
      expect(find.text('Try again'), findsOneWidget);

      SharedPreferences.setMockInitialValues({'bg_auth_token': 'jwt'});
      server
        ..registerStatus = 200
        ..registerHold = Completer<void>();
      await tester.tap(find.text('Try again'));
      await tester.pump();
      expect(find.text('Registering this phone for push…'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      server.registerHold!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Active on this phone'), findsOneWidget);
    });

    testWidgets('the two-line status lines fit a 320 wide phone', (tester) async {
      server.registerStatus = 503;
      await registerPhone(tester);
      await openSettings(tester, width: 320);
      expect(find.text('Try again'), findsOneWidget); // text + hint + a button
      expect(tester.takeException(), isNull);

      // Pumping a fresh tree (and a fresh look at the registration) with a
      // server that cannot send: text + hint, no button.
      await tester.pumpWidget(const SizedBox());
      FcmService.debugReset();
      FcmService.debugSetInitialized(true);
      FcmService.postRetryPause = Duration.zero;
      FcmService.retryDelays = const [];
      FcmService.getFcmToken = () async => 'tok-1';
      server
        ..registerStatus = 200
        ..registerBody = {'isOk': true, 'pushReady': false, 'problem': 'x'};
      await tester.runAsync(FcmService.registerToken);
      await openSettings(tester, width: 320);
      expect(find.text("Registered, but the server can't send to this phone"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a registration waiting for its retry reads as registering, not active', (tester) async {
      SharedPreferences.setMockInitialValues({}); // no session: opening Settings starts no attempt of its own
      server.registerStatus = 503;
      FcmService.retryDelays = const [Duration(minutes: 10)];
      await registerPhone(tester);
      expect(FcmService.debugRetryScheduled, isTrue);
      await openSettings(tester);

      expect(find.text('Registering this phone for push…'), findsOneWidget);
      expect(find.text('Active on this phone'), findsNothing);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('follows a registration that finishes while the screen is open', (tester) async {
      server.registerHold = Completer<void>();
      FcmService.debugSetInitialized(true);
      await tester.runAsync(() async {
        unawaited(FcmService.registerToken());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await openSettings(tester);
      expect(find.text('Registering this phone for push…'), findsOneWidget);

      server.registerHold!.complete();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(seconds: 3)); // the screen looks again every couple of seconds
      await tester.pumpAndSettle();

      expect(find.text('Registering this phone for push…'), findsNothing);
      expect(find.text('Active on this phone'), findsOneWidget);
    });

    testWidgets('a test push that cannot be delivered takes "Active" away, a good one gives it back', (tester) async {
      await registerPhone(tester);
      await openSettings(tester);
      expect(find.text('Active on this phone'), findsOneWidget);

      server.testBody = _testAnswer(ok: false, code: 'messaging/third-party-auth-error', hint: 'APNs key missing');
      await tester.tap(find.text('Send a test notification'));
      await tester.pumpAndSettle();
      expect(find.text("The server couldn't deliver the test"), findsOneWidget);
      expect(server.tests.single, {'token': 'tok-1'}, reason: 'the test is aimed at this phone alone');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Active on this phone'), findsNothing);
      expect(find.text("Registered, but the server can't send to this phone"), findsOneWidget);

      server.testBody = _testAnswer(ok: true);
      await tester.tap(find.text('Send a test notification'));
      await tester.pumpAndSettle();
      expect(find.text('Test notification sent'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Active on this phone'), findsOneWidget);
    });

    testWidgets('a permission the OS refuses outranks a working registration', (tester) async {
      osStatus = 4; // permanently denied
      await registerPhone(tester);
      await openSettings(tester);

      expect(find.text('Active on this phone'), findsNothing);
      expect(find.text('Blocked in system settings'), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Send a test notification'), findsNothing);
    });

    // permission_handler on Android below 13 reports "denied" for
    // notifications switched off in the system settings, and its request()
    // cannot show anything there — an "Allow" would do nothing.
    testWidgets('Android 12 and below, notifications blocked in system settings: Open settings, not Allow', (tester) async {
      osStatus = 0; // denied
      osCanAsk = false; // and no dialog to show
      await openSettings(tester);

      expect(find.text('Blocked in system settings'), findsOneWidget);
      expect(find.text('Allow'), findsNothing);
      expect(find.text('Not allowed on this phone yet'), findsNothing);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(osCalls, contains('openAppSettings'));
    });

    testWidgets('a permission the OS can still ask for keeps its Allow button', (tester) async {
      osStatus = 0; // denied once on Android 13+: the dialog can come up again
      osCanAsk = true;
      await openSettings(tester);

      expect(find.text('Not allowed on this phone yet'), findsOneWidget);
      expect(find.text('Allow'), findsOneWidget);
      expect(find.text('Open settings'), findsNothing);
    });

    testWidgets('when the OS cannot say whether it can ask, Allow stays', (tester) async {
      osStatus = 0;
      osRationaleError = PlatformException(code: 'no-activity');
      await openSettings(tester);

      expect(find.text('Allow'), findsOneWidget);
      expect(find.text('Blocked in system settings'), findsNothing);
    });

    testWidgets('Allow asks the OS and the line follows the answer', (tester) async {
      osStatus = 0;
      osCanAsk = true;
      await openSettings(tester);

      osStatus = 1; // the user taps "Allow" in the system dialog
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();

      expect(osCalls, contains('requestPermissions'));
      expect(find.text('Not allowed on this phone yet'), findsNothing);
      expect(find.text('Send a test notification'), findsOneWidget);
    });
  });

  group('Local banners obey the topic switches', () {
    final shown = <String>[];

    // The plugin only registers its Android side on an Android host.
    setUpAll(AndroidFlutterLocalNotificationsPlugin.registerWith);

    setUp(() {
      shown.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('dexterous.com/flutter/local_notifications'),
            (call) async {
              if (call.method == 'initialize') return true;
              if (call.method == 'show') shown.add(call.arguments['title'] as String);
              return null;
            },
          );
    });

    // Plays the server for one tick of both polls.
    Future<void> tick({
      required Map<String, dynamic> preferences,
      List<Map<String, dynamic>> audits = const [],
      List<Map<String, dynamic>> ncs = const [],
    }) => http.runWithClient(() async {
      await pollAndNotifyOverdueNcs();
      await pollAndNotifyEvents();
    }, () => http_testing.MockClient((request) async {
      final path = request.url.path;
      Object data;
      if (path.endsWith('/auth/me/preferences')) {
        data = preferences;
      } else if (path.endsWith('/audits/mine')) {
        data = audits;
      } else {
        data = ncs;
      }
      return http.Response(jsonEncode({'isOk': true, 'data': data}), 200);
    }));

    Map<String, dynamic> audit(String id) => {
      '_id': id,
      'title': 'Audit $id',
      'status': 'Scheduled',
      'scheduledDate': '2099-01-01T00:00:00.000Z',
    };

    Map<String, dynamic> nc(String id, String status, {int reopen = 0}) => {
      '_id': id,
      'title': 'NC $id',
      'status': status,
      'reopenCount': reopen,
    };

    Map<String, dynamic> prefs({bool push = true, Map<String, bool> types = const {}}) => {
      'pushNotifications': push,
      'pushNotificationTypes': types,
    };

    // The polls fetch only the signed-in person's own items, so they need
    // the mirrored user id along with the token.
    setUp(() => SharedPreferences.setMockInitialValues({'bg_auth_token': 'tok', 'bg_user_id': 'u1'}));

    test('new audit assigned needs both assignment topics, and the tick refreshes the mirror', () async {
      await tick(preferences: prefs(), audits: [audit('a1')]); // baseline
      await tick(
        preferences: prefs(types: {'audit_reassigned': false}),
        audits: [audit('a1'), audit('a2')],
      );
      expect(shown, isEmpty);
      expect(await NotificationPrefs.readPushTypeEnabled('audit_reassigned'), isFalse);

      await tick(preferences: prefs(), audits: [audit('a1'), audit('a2'), audit('a3')]);
      expect(shown, ['New audit assigned']);
    });

    test('NC raised, approved and rejected each follow their own topic', () async {
      await tick(preferences: prefs(), ncs: [nc('n1', 'Raised'), nc('n2', 'Raised')]); // baseline

      await tick(
        preferences: prefs(types: {'nc_raised': false, 'nc_approved': false}),
        ncs: [nc('n1', 'Closed'), nc('n2', 'Raised', reopen: 1), nc('n3', 'Raised')],
      );
      expect(shown, ['NC response rejected'], reason: 'raised and approved are off');

      shown.clear();
      await tick(
        preferences: prefs(types: {'nc_rejected': false}),
        ncs: [nc('n1', 'Closed'), nc('n2', 'Raised', reopen: 2), nc('n4', 'Raised')],
      );
      expect(shown, ['New NC raised against you'], reason: 'the rejection is off now');
    });

    test('a rejected-then-approved NC with approvals off never shows a rejection', () async {
      await tick(preferences: prefs(), ncs: [nc('n1', 'Raised')]);
      await tick(
        preferences: prefs(types: {'nc_approved': false}),
        ncs: [nc('n1', 'Closed', reopen: 1)],
      );
      expect(shown, isEmpty);
    });

    test('the master switch silences every topic', () async {
      await tick(preferences: prefs(), audits: [audit('a1')], ncs: [nc('n1', 'Raised')]);
      await tick(
        preferences: prefs(push: false),
        audits: [audit('a1'), audit('a2')],
        ncs: [nc('n1', 'Closed'), nc('n2', 'Raised')],
      );
      expect(shown, isEmpty);
    });

    test('start and due-date reminders follow audit_reminder', () async {
      Map<String, dynamic> due(String id) => {
        ...audit(id),
        'scheduledDate': '2000-01-01T00:00:00.000Z',
        'scheduledEndDate': '2000-02-01T00:00:00.000Z',
      };
      await tick(preferences: prefs(), audits: [due('a1')]); // baseline seeds the dedup state
      await tick(preferences: prefs(types: {'audit_reminder': false}), audits: [due('a1'), due('a2')]);
      expect(
        shown.where((t) => t == 'Audit starting' || t == 'Audit due'),
        isEmpty,
      );

      await tick(preferences: prefs(), audits: [due('a1'), due('a2'), due('a3')]);
      expect(shown, containsAll(['Audit starting', 'Audit due']));
    });

    test('overdue NCs follow nc_overdue and are recorded either way', () async {
      final overdue = {
        ...nc('n1', 'Raised'),
        'targetDate': '2000-01-01T00:00:00.000Z',
      };
      await tick(preferences: prefs(types: {'nc_overdue': false}), ncs: [overdue]);
      expect(shown, isNot(contains('NC n1 is overdue')));
      // Recorded as handled while off, so switching it back on later does not dump it.
      await tick(preferences: prefs(), ncs: [overdue]);
      expect(shown, isNot(contains('NC n1 is overdue')));

      final another = {...overdue, '_id': 'n2', 'title': 'NC n2'};
      await tick(preferences: prefs(), ncs: [overdue, another]);
      expect(shown, contains('NC n2 is overdue'));
    });
  });
}
