import 'dart:async';

import 'package:dio/dio.dart' show RequestOptions;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/notifications/notification_prefs.dart';
import 'package:internal_audit_app/core/notifications/push_check.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

const _register = ApiConstants.deviceTokenRegister;
const _test = ApiConstants.deviceTokenTest;

/// Settings > "Send a test notification": the test must be about THIS phone's
/// token, and must say so honestly when this phone has no token, could not
/// register it, or the server cannot push to it. Firebase's own calls are
/// swapped for fakes; the server's answers come from [FakeAdapter].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late String? fcmToken;
  late Object? fcmTokenError;
  // What the server does with POST /device-tokens/register and /test.
  late Future<(int, Map<String, dynamic>)> Function(dynamic body) onRegister;
  late Map<String, dynamic> Function(dynamic body) onTest;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'bg_auth_token': 'jwt'});
    fcmToken = 'tok-1';
    fcmTokenError = null;
    onRegister = (_) async => (200, {'isOk': true, 'pushReady': true});
    // A server that honours { token }: it answers for that one row.
    onTest = (body) => _answer([
      _result(platform: 'android', ok: true),
    ]);
    adapter = FakeAdapter()
      ..handler = (o) async {
        if (o.method == 'POST' && o.path == _register) {
          final (status, body) = await onRegister(o.data);
          return json(status, body);
        }
        if (o.method == 'POST' && o.path == _test) return json(200, onTest(o.data));
        return json(404, {'isOk': false});
      };
    DioClient.instance.dio.httpClientAdapter = adapter;
    DioClient.instance.onUnauthorized = () {};

    FcmService.debugReset();
    FcmService.debugSetInitialized(true);
    FcmService.postRetryPause = Duration.zero;
    FcmService.retryDelays = const []; // no timers: every attempt is explicit here
    FcmService.getFcmToken = () async {
      final error = fcmTokenError;
      if (error != null) throw error;
      return fcmToken;
    };
  });

  tearDown(() {
    FcmService.debugReset();
    DioClient.instance.onUnauthorized = null;
  });

  Iterable<RequestOptions> tests() => adapter.where('POST', _test);

  group('the test is about this phone', () {
    test("sends this phone's own token, and only that", () async {
      final check = await FcmService.runPushCheck();

      expect(check.ok, isTrue);
      expect(check.title, 'Test notification sent');
      expect(tests(), hasLength(1));
      expect(tests().single.data, {'token': 'tok-1'});
    });

    test('the token it sends is the one the server accepted at registration', () async {
      await FcmService.runPushCheck();

      final registered = adapter.where('POST', _register).map((r) => (r.data as Map)['token']);
      expect(registered, contains('tok-1'));
      expect((tests().single.data as Map)['token'], 'tok-1');
    });

    test('the server has no such registration: says this phone is not registered', () async {
      onTest = (_) => _answer(const []); // { token } narrowed the send to nothing

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.title, contains("isn't registered"));
    });

    test('a failed send to this token is a failure, however many phones the account has', () async {
      onTest = (_) => _answer([
        _result(platform: 'android', ok: false, code: 'messaging/third-party-auth-error'),
      ]);

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.title, "The server couldn't deliver the test");
      expect(check.lines.first, 'messaging/third-party-auth-error');
    });

    test("an older server that ignores the token cannot let another phone vouch for this one", () async {
      // Same account, two Android phones: this one's send failed, the other
      // one's went through. Which is which is not in the answer.
      onTest = (_) => _answer([
        _result(platform: 'android', ok: false, code: 'messaging/invalid-argument'),
        _result(platform: 'android', ok: true),
      ]);

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.lines.join('\n'), contains('cannot say which one is this phone'));
    });
  });

  group('says so when this phone cannot be tested', () {
    test('no push token: nothing is sent', () async {
      fcmToken = null;

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.title, 'This phone has no push token');
      expect(check.lines.last, contains('not available'));
      expect(tests(), isEmpty);
    });

    test('a token that cannot be read: nothing is sent, and the reason is shown', () async {
      fcmTokenError = StateError('apns-token-not-set');

      final check = await FcmService.runPushCheck();

      expect(check.title, 'This phone has no push token');
      expect(check.lines.last, contains('apns-token-not-set'));
      expect(tests(), isEmpty);
    });

    test('registration failed: nothing is sent, however the account looks on the server', () async {
      // Another phone of the account may well accept a test — that says
      // nothing about this one.
      onRegister = (_) async => (503, {'isOk': false});

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.title, "This phone couldn't register for push");
      expect(tests(), isEmpty);
    });

    test('a token that rotated without its registration landing is not tested through the old one', () async {
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isTrue, reason: 'tok-1 is on the server');

      fcmToken = 'tok-2'; // FCM rotated it...
      onRegister = (_) async => (503, {'isOk': false}); // ...and the POST cannot land

      final check = await FcmService.runPushCheck();

      expect(check.title, "This phone couldn't register for push");
      expect(tests(), isEmpty);
    });

    test('the server cannot push to this phone: its own problem text is shown', () async {
      onRegister = (_) async => (
        200,
        {
          'isOk': true,
          'pushReady': false,
          'problem': 'No credentials for Firebase project "internal-audit-c7c2b".',
        },
      );

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.title, "The server can't push to this phone");
      expect(check.lines.first, contains('internal-audit-c7c2b'));
      expect(tests(), isEmpty);
    });

    test('pushReady false without a problem text still says so', () async {
      onRegister = (_) async => (200, {'isOk': true, 'pushReady': false});

      final check = await FcmService.runPushCheck();

      expect(check.title, "The server can't push to this phone");
      expect(check.lines.first, isNotEmpty);
      expect(tests(), isEmpty);
    });

    test('a registration still on the wire from login is waited for, not mistaken for a failure', () async {
      final hold = Completer<void>();
      onRegister = (_) async {
        await hold.future;
        return (200, {'isOk': true, 'pushReady': true});
      };
      final loginRegistration = FcmService.registerToken();
      await settle();
      expect(FcmService.registrationState, PushRegistration.registering);

      final checking = FcmService.runPushCheck();
      await settle();
      expect(tests(), isEmpty, reason: 'the check waits for the registration');
      hold.complete();
      await loginRegistration;
      final check = await checking;

      expect(check.ok, isTrue);
      expect(adapter.where('POST', _register), hasLength(1), reason: 'joined, not raced');
      expect(tests().single.data, {'token': 'tok-1'});
    });

    test('nothing to test in a build without Firebase', () async {
      FcmService.debugSetInitialized(false);

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(check.title, "Push isn't set up in this build");
      expect(adapter.requests, isEmpty);
    });
  });

  group('the outcome is remembered for the status line', () {
    test('a failed test marks the phone as not ready; a good one clears it', () async {
      await FcmService.registerToken();
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);

      onTest = (_) => _answer([_result(platform: 'android', ok: false, code: 'messaging/third-party-auth-error')]);
      await FcmService.runPushCheck();
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);

      onTest = (_) => _answer([_result(platform: 'android', ok: true)]);
      await FcmService.runPushCheck();
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);
    });

    test('an answer that cannot tell the phones apart is remembered the way the dialog reports it', () async {
      await FcmService.registerToken();
      // An older server that ignored { token }: two Android phones, one failed.
      onTest = (_) => _answer([
        _result(platform: 'android', ok: false, code: 'messaging/invalid-argument'),
        _result(platform: 'android', ok: true),
      ]);

      final check = await FcmService.runPushCheck();

      expect(check.ok, isFalse);
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);
    });

    test('a test that says nothing about this phone changes nothing', () async {
      await FcmService.registerToken();
      onTest = (_) => _answer(const []);
      await FcmService.runPushCheck();

      expect(await NotificationPrefs.readFcmPushReady(), isTrue);
    });
  });

  group('registrationState', () {
    test('follows the registration: registering, registered, cannot deliver, not registered', () async {
      expect(FcmService.registrationState, PushRegistration.notRegistered);

      await FcmService.registerToken();
      expect(FcmService.registrationState, PushRegistration.registered);

      FcmService.debugReset();
      FcmService.debugSetInitialized(true);
      FcmService.postRetryPause = Duration.zero;
      FcmService.retryDelays = const [];
      FcmService.getFcmToken = () async => 'tok-1';
      onRegister = (_) async => (200, {'isOk': true, 'pushReady': false, 'problem': 'x'});
      await FcmService.registerToken();
      expect(FcmService.registrationState, PushRegistration.cannotDeliver);
    });

    test('a registration waiting for its backoff retry reads as registering', () async {
      FcmService.retryDelays = const [Duration(minutes: 10)];
      onRegister = (_) async => (503, {'isOk': false});

      await FcmService.registerToken();

      expect(FcmService.debugRetryScheduled, isTrue);
      expect(FcmService.registrationState, PushRegistration.registering);
    });

    test('a build without Firebase is not set up', () {
      FcmService.debugSetInitialized(false);
      expect(FcmService.registrationState, PushRegistration.notSetUp);
    });
  });
}

var _rows = 0;

Map<String, dynamic> _result({required String platform, required bool ok, String? code}) => {
  'tokenId': 'row-${_rows++}',
  'platform': platform,
  'ok': ok,
  'code': ok ? null : (code ?? 'unknown'),
};

Map<String, dynamic> _answer(List<Map<String, dynamic>> results) => {
  'isOk': true,
  'data': {
    'sent': results.where((r) => r['ok'] == true).length,
    'failed': results.where((r) => r['ok'] != true).length,
    'results': results,
    'serverProjects': ['proj-server'],
  },
};
