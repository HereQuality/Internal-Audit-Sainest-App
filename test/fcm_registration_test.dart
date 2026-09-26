import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart' show RemoteMessage;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/storage/secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

const _register = ApiConstants.deviceTokenRegister;

/// Token registration and sign-out unregistration: what stands between a
/// phone and every push, and between a signed-out phone and the previous
/// account's pushes. Firebase's own calls are swapped for fakes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late int logoutSignals;
  late int fcmDeletes;
  late String? fcmToken;
  late Object? fcmTokenError;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({'bg_auth_token': 'mirror-jwt'});
    adapter = FakeAdapter()..handler = (_) async => json(200, {'isOk': true, 'pushReady': true});
    DioClient.instance.dio.httpClientAdapter = adapter;
    logoutSignals = 0;
    DioClient.instance.onUnauthorized = () => logoutSignals++;
    fcmDeletes = 0;
    fcmToken = 'tok-1';
    fcmTokenError = null;

    FcmService.debugReset();
    FcmService.debugSetInitialized(true);
    FcmService.postRetryPause = Duration.zero;
    FcmService.retryDelays = const [Duration(milliseconds: 20), Duration(milliseconds: 20)];
    FcmService.getFcmToken = () async {
      final error = fcmTokenError;
      if (error != null) throw error;
      return fcmToken;
    };
    FcmService.deleteFcmToken = () async => fcmDeletes++;
  });

  tearDown(() {
    FcmService.debugReset();
    DioClient.instance.onUnauthorized = null;
  });

  Iterable<dynamic> bodies(String method) => adapter.where(method, _register).map((r) => r.data);

  // The note holds a live JWT, so it lives in secure storage.
  Future<String?> pending() => SecureStorage.instance.readPendingUnregister();

  group('registration retry', () {
    test('a registration that fails is retried on its own and lands', () async {
      var failures = 3; // both in-call attempts of the first try, plus the first of the retry
      adapter.handler = (o) async {
        if (o.method == 'POST' && failures-- > 0) connectionError(o);
        return json(200, {'isOk': true, 'pushReady': true});
      };

      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isFalse);
      expect(FcmService.debugRetryScheduled, isTrue);

      await waitFor(() => FcmService.debugTokenRegistered);
      expect(bodies('POST'), hasLength(4));
    });

    test('a getToken() that throws is retried', () async {
      fcmTokenError = StateError('offline');
      await FcmService.registerToken();
      expect(adapter.requests, isEmpty);
      expect(FcmService.debugRetryScheduled, isTrue);

      fcmTokenError = null; // FCM reachable again
      await waitFor(() => FcmService.debugTokenRegistered);
    });

    test('a getToken() that returns nothing is retried', () async {
      fcmToken = null;
      await FcmService.registerToken();
      expect(FcmService.debugRetryScheduled, isTrue);
      fcmToken = 'tok-1';
      await waitFor(() => FcmService.debugTokenRegistered);
    });

    test('the backoff is bounded; a resume (ensureRegistered) starts it over', () async {
      adapter.handler = (o) async => connectionError(o);
      await FcmService.registerToken();
      // Two delays configured: registration 1 + two timed retries, then quiet.
      await waitFor(() => bodies('POST').length == 6 && !FcmService.debugRetryScheduled);
      await settle();
      expect(bodies('POST'), hasLength(6));

      adapter.handler = (_) async => json(200, {'isOk': true});
      await FcmService.ensureRegistered();
      expect(FcmService.debugTokenRegistered, isTrue);
    });

    test('a 4xx answer is final: no second attempt, no retry', () async {
      adapter.handler = (_) async => json(400, {'isOk': false});
      await FcmService.registerToken();
      expect(bodies('POST'), hasLength(1));
      expect(FcmService.debugRetryScheduled, isFalse);
      expect(FcmService.debugTokenRegistered, isFalse);
    });

    test('a 5xx answer is retried', () async {
      adapter.handler = (_) async => json(503, {'isOk': false});
      await FcmService.registerToken();
      expect(FcmService.debugRetryScheduled, isTrue);
    });

    test('a failed token refresh is not "registered" and is retried', () async {
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isTrue);

      adapter.handler = (o) async => connectionError(o);
      fcmToken = 'tok-2';
      await FcmService.debugOnTokenRefresh('tok-2');
      expect(FcmService.debugTokenRegistered, isFalse,
          reason: 'the server still holds the OLD token; "registered" must not stay true');
      expect(FcmService.debugRetryScheduled, isTrue);

      adapter.handler = (_) async => json(200, {'isOk': true});
      await waitFor(() => FcmService.debugTokenRegistered);
      expect(bodies('POST').last, containsPair('token', 'tok-2'));
    });

    test('a token refresh without a session is ignored', () async {
      SharedPreferences.setMockInitialValues({});
      await FcmService.debugOnTokenRefresh('tok-2');
      expect(adapter.requests, isEmpty);
    });
  });

  group('unregister on sign-out', () {
    Future<void> registered() async {
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isTrue);
      adapter.requests.clear();
    }

    test('sends the DELETE with the token the CALLER holds, and its 401 is not a logout signal', () async {
      await registered();
      // Stored token already gone (forced logout), server says the JWT expired.
      adapter.handler = (_) async => json(401, {'message': 'expired'});

      await FcmService.unregisterToken(jwt: 'expired-jwt');

      final delete = adapter.where('DELETE', _register).single;
      expect(delete.headers['Authorization'], 'Bearer expired-jwt');
      expect(delete.data, {'token': 'tok-1'});
      expect(logoutSignals, 0);
    });

    test('a confirmed delete is the whole job: the FCM token is left alone', () async {
      await registered();
      await FcmService.unregisterToken(jwt: 'jwt');
      expect(fcmDeletes, 0);
      expect(await pending(), isNull);
      expect(FcmService.debugTokenRegistered, isFalse);
    });

    test('a refused delete (401/403) falls back to invalidating the token at FCM, without a retry note', () async {
      await registered();
      adapter.handler = (_) async => json(403, {});
      await FcmService.unregisterToken(jwt: 'jwt');
      expect(fcmDeletes, 1);
      expect(await pending(), isNull);
    });

    test('offline: keeps a note to retry, and still asks FCM to drop the token', () async {
      await registered();
      adapter.handler = (o) async => connectionError(o);
      await FcmService.unregisterToken(jwt: 'jwt-A');

      final note = jsonDecode((await pending())!) as Map;
      expect(note['token'], 'tok-1');
      expect(note['jwt'], 'jwt-A');
      expect(fcmDeletes, 1);
    });

    test('that note carries a live JWT: it is in secure storage, in no SharedPreferences value', () async {
      await registered();
      adapter.handler = (o) async => connectionError(o);
      await FcmService.unregisterToken(jwt: 'jwt-A');

      expect(await pending(), contains('jwt-A'));
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect('${prefs.get(key)}', isNot(contains('jwt-A')), reason: 'the JWT is readable in SharedPreferences key "$key"');
      }
    });

    test('deletes the token the server holds even when FCM cannot be asked for it', () async {
      await registered();
      fcmTokenError = StateError('offline');
      await FcmService.unregisterToken(jwt: 'jwt');
      expect(adapter.where('DELETE', _register).single.data, {'token': 'tok-1'});
    });

    test('without a caller token it uses the session mirror\'s', () async {
      await registered();
      await FcmService.unregisterToken();
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer mirror-jwt');
    });

    test('with no token anywhere there is nothing to send, but FCM is still asked to drop the token', () async {
      await registered();
      SharedPreferences.setMockInitialValues({});
      await FcmService.unregisterToken();
      expect(adapter.requests, isEmpty);
      expect(fcmDeletes, 1);
    });

    test('runs once per sign-out (a second call would mint and delete a throwaway token)', () async {
      await registered();
      await FcmService.unregisterToken(jwt: 'jwt');
      await FcmService.unregisterToken(jwt: 'jwt');
      expect(adapter.where('DELETE', _register), hasLength(1));
    });

    test('never registers the phone again until the next sign-in', () async {
      await registered();
      await FcmService.unregisterToken(jwt: 'jwt');
      adapter.requests.clear();

      await FcmService.registerToken();
      await FcmService.ensureRegistered();
      await FcmService.debugOnTokenRefresh('tok-2');
      expect(adapter.requests, isEmpty);
      expect(FcmService.debugTokenRegistered, isFalse);

      FcmService.onSessionStarted();
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isTrue);
    });

    test('cancels a registration retry that was waiting', () async {
      adapter.handler = (o) async => connectionError(o);
      await FcmService.registerToken();
      expect(FcmService.debugRetryScheduled, isTrue);

      await FcmService.unregisterToken(jwt: 'jwt');
      expect(FcmService.debugRetryScheduled, isFalse);
      adapter.requests.clear();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(adapter.requests, isEmpty, reason: 'a retry registered the signed-out phone');
    });

    test('a registration already on the wire lands first, so its row is the one deleted', () async {
      final gate = Completer<void>();
      adapter.handler = (o) async {
        if (o.method == 'POST') await gate.future;
        return json(200, {'isOk': true});
      };
      final registering = FcmService.registerToken();
      await settle();
      expect(adapter.where('POST', _register), hasLength(1));

      final unregistering = FcmService.unregisterToken(jwt: 'jwt');
      await settle();
      expect(adapter.where('DELETE', _register), isEmpty, reason: 'the DELETE overtook the POST');

      gate.complete();
      await Future.wait([registering, unregistering]);
      expect(adapter.requests.map((r) => r.method), ['POST', 'DELETE']);
      expect(adapter.where('DELETE', _register).single.data, {'token': 'tok-1'});
      expect(FcmService.debugTokenRegistered, isFalse);
    });

    test('a new sign-in that begins meanwhile keeps the token it registered', () async {
      await registered();
      adapter.handler = (o) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return connectionError(o);
      };
      final unregistering = FcmService.unregisterToken(jwt: 'jwt-A');
      await settle();
      FcmService.onSessionStarted(); // the next account signs in while the DELETE is failing
      await unregistering;
      expect(fcmDeletes, 0, reason: 'FCM token deleted from under the new sign-in');
    });
  });

  group('sign-out that could not reach the server', () {
    Future<void> leaveNote({required String token, String jwt = 'old-jwt', DateTime? at}) async {
      await SecureStorage.instance.savePendingUnregister(
        jsonEncode({'token': token, 'jwt': jwt, 'at': (at ?? DateTime.now()).millisecondsSinceEpoch}),
      );
    }

    test('is retried later with the saved token, and cleared once it lands', () async {
      await leaveNote(token: 'tok-1');
      await FcmService.retryPendingUnregister();

      final delete = adapter.where('DELETE', _register).single;
      expect(delete.headers['Authorization'], 'Bearer old-jwt');
      expect(delete.data, {'token': 'tok-1'});
      expect(await pending(), isNull);
    });

    test('stays while the server is unreachable', () async {
      await leaveNote(token: 'tok-1');
      adapter.handler = (o) async => connectionError(o);
      await FcmService.retryPendingUnregister();
      expect(await pending(), isNotNull);
    });

    test('is dropped when the server refuses it (asking again will not change that)', () async {
      await leaveNote(token: 'tok-1');
      adapter.handler = (_) async => json(401, {});
      await FcmService.retryPendingUnregister();
      expect(await pending(), isNull);
      expect(logoutSignals, 0);
    });

    test('is dropped, unsent, after a week', () async {
      await leaveNote(token: 'tok-1', at: DateTime.now().subtract(const Duration(days: 8)));
      await FcmService.retryPendingUnregister();
      expect(adapter.requests, isEmpty);
      expect(await pending(), isNull);
    });

    test('a note nobody can read is dropped', () async {
      await SecureStorage.instance.savePendingUnregister('not json');
      await FcmService.retryPendingUnregister();
      expect(adapter.requests, isEmpty);
      expect(await pending(), isNull);
    });

    test('survives the wipe every sign-out ends with, which takes the session token', () async {
      await leaveNote(token: 'tok-1');
      await SecureStorage.instance.saveToken('jwt-A');

      await SecureStorage.instance.clear();

      expect(await SecureStorage.instance.readToken(), isNull);
      expect(await pending(), isNotNull);
      await FcmService.retryPendingUnregister();
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer old-jwt');
    });

    test('registering the SAME token supersedes it — it must not delete the new sign-in\'s token later', () async {
      await leaveNote(token: 'tok-1');
      await FcmService.registerToken();
      await waitFor(() => FcmService.debugTokenRegistered);
      await settle();
      expect(await pending(), isNull);
    });

    test('registering a different token leaves it alone', () async {
      await leaveNote(token: 'some-other-token');
      await FcmService.registerToken();
      await settle();
      expect(await pending(), isNotNull);
    });

    test('a sign-in that re-registered the token while the retry was in flight registers it again', () async {
      await leaveNote(token: 'tok-1');
      final gate = Completer<void>();
      adapter.handler = (o) async {
        if (o.method == 'DELETE') await gate.future;
        return json(200, {'isOk': true});
      };
      final retrying = FcmService.retryPendingUnregister();
      await settle();

      FcmService.onSessionStarted();
      await FcmService.registerToken(); // same account, same token: its row is what the DELETE removes
      expect(FcmService.debugTokenRegistered, isTrue);

      gate.complete();
      await retrying;
      await waitFor(() => bodies('POST').length >= 2);
      await waitFor(() => FcmService.debugTokenRegistered);
    });
  });

  group('the tap that launched the app', () {
    RemoteMessage tap() => RemoteMessage(data: {'type': 'nc_raised', 'referenceId': 'nc1'});

    setUp(() {
      FcmService.debugReset(); // not initialized yet, like a cold start
      FcmService.getInitialMessage = () async => tap();
    });

    test('survives an init that outlives main.dart\'s wait', () async {
      final release = Completer<void>();
      FcmService.initCore = () async {
        await release.future;
        FcmService.debugSetInitialized(true);
      };

      final init = FcmService.init();
      // main.dart: await FcmService.init().timeout(...), then moves on.
      await expectLater(init.timeout(const Duration(milliseconds: 20)), throwsA(isA<TimeoutException>()));
      final launch = FcmService.consumeLaunchPayload();
      expect(FcmService.isReady, isFalse);

      release.complete();
      expect(await launch, 'nc_raised|nc1');
    });

    test('a second init joins the one running instead of setting everything up twice', () async {
      var runs = 0;
      final release = Completer<void>();
      FcmService.initCore = () async {
        runs++;
        await release.future;
        FcmService.debugSetInitialized(true);
      };
      final first = FcmService.init();
      final second = FcmService.init();
      release.complete();
      await Future.wait([first, second]);
      expect(runs, 1);
    });

    test('no Firebase setup: there is nothing to read, and nothing is asked of FCM', () async {
      var asked = false;
      FcmService.initCore = () async {}; // Firebase not configured: stays uninitialized
      FcmService.getInitialMessage = () async {
        asked = true;
        return tap();
      };
      final init = FcmService.init();
      expect(await FcmService.consumeLaunchPayload(), isNull);
      await init;
      expect(asked, isFalse);
    });

    test('an init that already finished is read straight away', () async {
      FcmService.debugSetInitialized(true);
      expect(await FcmService.consumeLaunchPayload(), 'nc_raised|nc1');
    });
  });

  test('the Settings push check aims the test at THIS phone\'s token', () async {
    adapter.handler = (o) async => o.path == ApiConstants.deviceTokenTest
        ? json(200, {
            'isOk': true,
            'data': {'sent': 1, 'failed': 0, 'results': [], 'serverProjects': []},
          })
        : json(200, {'isOk': true, 'pushReady': true});
    await FcmService.runPushCheck();
    expect(adapter.where('POST', ApiConstants.deviceTokenTest).single.data, {'token': 'tok-1'});
  });
}
