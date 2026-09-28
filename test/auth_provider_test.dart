import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/notifications/notification_prefs.dart';
import 'package:internal_audit_app/core/notifications/notification_scheduler.dart';
import 'package:internal_audit_app/core/storage/secure_storage.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

const _register = ApiConstants.deviceTokenRegister;

Map<String, dynamic> _user(String id) => {
      '_id': id,
      'roleType': 'Employee',
      'employeeName': 'Person $id',
    };

/// Session lifecycle: what a saved session survives (no signal), what ends
/// one (401/403, the button), and what has to happen on the way out — the
/// phone must stop receiving the account's pushes, and the next account on
/// the same phone must start clean.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late FakeSockets sockets;
  late AuthProvider auth;
  late int trayClears;
  late int fcmDeletes;
  // What GET /auth/me answers; tests swap it.
  late Future<ResponseBody> Function(RequestOptions) me;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    trayClears = 0;
    fcmDeletes = 0;
    NotificationScheduler.clearTray = () async => trayClears++;
    FcmService.debugReset();
    FcmService.debugSetInitialized(true);
    FcmService.getFcmToken = () async => 'tok-1';
    FcmService.deleteFcmToken = () async => fcmDeletes++;
    FcmService.postRetryPause = Duration.zero;

    me = (_) async => json(200, {'data': _user('u1')});
    adapter = FakeAdapter()
      ..handler = (o) async {
        switch ('${o.method} ${o.path}') {
          case 'GET ${ApiConstants.me}':
            return me(o);
          case 'POST ${ApiConstants.login}':
            return json(200, {
              'token': 'jwt-${o.data['username']}',
              'data': {'user': _user(o.data['username'] as String)},
            });
          default:
            return json(200, {'isOk': true, 'pushReady': true, 'data': {}});
        }
      };
    DioClient.instance.dio.httpClientAdapter = adapter;

    sockets = FakeSockets(readToken: SecureStorage.instance.readToken);
    SocketService.debugInstance = sockets.service;
    AuthProvider.sessionRetryDelays = const [Duration(milliseconds: 20)];
    auth = AuthProvider();
  });

  tearDown(() async {
    // The notification setup a login starts runs on its own; let it finish
    // before the next test replaces the mocks under it.
    await settle(30);
    auth.dispose();
    DioClient.instance.onUnauthorized = null;
    FcmService.debugReset();
    AuthProvider.sessionRetryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ];
  });

  Future<void> saveSession(String jwt) => SecureStorage.instance.saveToken(jwt);

  group('bootstrap', () {
    test('no saved token: signed out, the server is not asked', () async {
      await auth.bootstrap();
      expect(auth.status, AuthStatus.unauthenticated);
      expect(adapter.where('GET', ApiConstants.me), isEmpty);
    });

    test('a saved token the server accepts: signed in, socket connected', () async {
      await saveSession('jwt-saved');
      await auth.bootstrap();
      expect(auth.status, AuthStatus.authenticated);
      expect(auth.user?.id, 'u1');
      expect(sockets.sockets, hasLength(1));
      expect(sockets.sockets.single.connectCalled, isTrue);
    });

    test('a 401 ends the session: unregisters with the OLD token, clears storage, tray and socket', () async {
      await saveSession('jwt-old');
      me = (_) async => json(401, {'message': 'expired'});
      await auth.bootstrap();

      expect(auth.status, AuthStatus.unauthenticated);
      expect(await SecureStorage.instance.readToken(), isNull);
      final deletes = adapter.where('DELETE', _register).toList();
      expect(deletes, hasLength(1), reason: 'the interceptor and bootstrap must run ONE teardown');
      expect(deletes.single.headers['Authorization'], 'Bearer jwt-old');
      expect(deletes.single.data, {'token': 'tok-1'});
      expect(trayClears, 1);
    });

    test('a 403 (blocked account) ends the session the same way', () async {
      await saveSession('jwt-old');
      me = (_) async => json(403, {'message': 'Your account has been blocked.'});
      await auth.bootstrap();

      expect(auth.status, AuthStatus.unauthenticated);
      expect(await SecureStorage.instance.readToken(), isNull);
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer jwt-old');
      expect(trayClears, 1);
    });

    test('no signal: the session is KEPT and nothing is torn down', () async {
      await saveSession('jwt-saved');
      me = (o) async => connectionError(o);
      await auth.bootstrap();

      expect(auth.status, AuthStatus.offline);
      expect(auth.user, isNull);
      expect(await SecureStorage.instance.readToken(), 'jwt-saved');
      expect(adapter.where('DELETE', _register), isEmpty);
      expect(trayClears, 0);
      expect(sockets.sockets, isEmpty);
    });

    test('a timeout keeps the session too', () async {
      await saveSession('jwt-saved');
      me = (o) async => throw DioException(requestOptions: o, type: DioExceptionType.connectionTimeout);
      await auth.bootstrap();
      expect(auth.status, AuthStatus.offline);
      expect(await SecureStorage.instance.readToken(), 'jwt-saved');
    });

    for (final status in [500, 502, 503, 504]) {
      test('a $status from the server (a deploy) keeps the session', () async {
        await saveSession('jwt-saved');
        me = (_) async => json(status, {});
        await auth.bootstrap();
        expect(auth.status, AuthStatus.offline);
        expect(await SecureStorage.instance.readToken(), 'jwt-saved');
        expect(adapter.where('DELETE', _register), isEmpty);
      });
    }

    test('an unreadable /auth/me body keeps the session (the server\'s problem, not proof it is bad)', () async {
      await saveSession('jwt-saved');
      me = (_) async => json(200, {'isOk': true}); // no data
      await auth.bootstrap();
      expect(auth.status, AuthStatus.offline);
      expect(await SecureStorage.instance.readToken(), 'jwt-saved');
    });

    test('Try again signs in once the server answers', () async {
      await saveSession('jwt-saved');
      AuthProvider.sessionRetryDelays = const [Duration(hours: 1)];
      me = (o) async => connectionError(o);
      await auth.bootstrap();
      expect(auth.status, AuthStatus.offline);

      me = (_) async => json(200, {'data': _user('u1')});
      await auth.retrySession();
      expect(auth.status, AuthStatus.authenticated);
      expect(auth.user?.id, 'u1');
      expect(sockets.sockets, hasLength(1));
      expect(auth.isBusy, isFalse);
    });

    test('asks again by itself while offline', () async {
      await saveSession('jwt-saved');
      me = (o) async => connectionError(o);
      await auth.bootstrap();
      expect(auth.status, AuthStatus.offline);

      me = (_) async => json(200, {'data': _user('u1')});
      await waitFor(() => auth.status == AuthStatus.authenticated);
    });

    test('coming back to the foreground asks again', () async {
      await saveSession('jwt-saved');
      AuthProvider.sessionRetryDelays = const [Duration(hours: 1)];
      me = (o) async => connectionError(o);
      await auth.bootstrap();

      me = (_) async => json(200, {'data': _user('u1')});
      auth.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await waitFor(() => auth.status == AuthStatus.authenticated);
    });

    test('a retry that finally gets a 401 signs out properly', () async {
      await saveSession('jwt-saved');
      AuthProvider.sessionRetryDelays = const [Duration(hours: 1)];
      me = (o) async => connectionError(o);
      await auth.bootstrap();

      me = (_) async => json(401, {});
      await auth.retrySession();
      expect(auth.status, AuthStatus.unauthenticated);
      expect(await SecureStorage.instance.readToken(), isNull);
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer jwt-saved');
    });

    test('a launch with no session sends the sign-out that could not be sent earlier', () async {
      await SecureStorage.instance.savePendingUnregister(
        '{"token":"tok-old","jwt":"jwt-old","at":${DateTime.now().millisecondsSinceEpoch}}',
      );
      await auth.bootstrap();
      await waitFor(() => adapter.where('DELETE', _register).isNotEmpty);
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer jwt-old');
    });
  });

  group('sign-out', () {
    test('the button unregisters with the token BEFORE it is cleared, then clears everything', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      final tokenAtDelete = <String?>[];
      final inner = adapter.handler!;
      adapter.handler = (o) async {
        if (o.method == 'DELETE' && o.path == _register) {
          tokenAtDelete.add(await SecureStorage.instance.readToken());
        }
        return inner(o);
      };

      await auth.logout();

      expect(tokenAtDelete, ['jwt-A'], reason: 'the stored token was already wiped when the unregister ran');
      final delete = adapter.where('DELETE', _register).single;
      expect(delete.headers['Authorization'], 'Bearer jwt-A');
      expect(auth.status, AuthStatus.unauthenticated);
      expect(auth.user, isNull);
      expect(await SecureStorage.instance.readToken(), isNull);
      expect(sockets.sockets.single.disposed, isTrue);
      expect(trayClears, 1);

      await settle();
      expect(adapter.where('POST', ApiConstants.logout).single.headers['Authorization'], 'Bearer jwt-A');
    });

    test('a 401 from an ordinary request ends it too — once, however many requests fail together', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      final inner = adapter.handler!;
      adapter.handler = (o) async => o.path.startsWith('/audits') ? json(401, {}) : inner(o);

      await Future.wait([
        for (var i = 0; i < 3; i++) DioClient.instance.dio.get('/audits/$i').then((_) {}, onError: (_) {}),
      ]);
      await waitFor(() => auth.status == AuthStatus.unauthenticated);
      await settle(30); // the screen leaves first; the teardown finishes behind it

      expect(adapter.where('DELETE', _register), hasLength(1));
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer jwt-A');
      expect(await SecureStorage.instance.readToken(), isNull);
      expect(trayClears, 1);
    });

    test('a blocked account\'s 403 from an ordinary request ends the session mid-use, and unregisters the phone', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      final inner = adapter.handler!;
      adapter.handler = (o) async => o.path.startsWith('/audits')
          ? json(403, {'success': false, 'status': 'fail', 'message': 'Your account has been blocked.'})
          : inner(o);

      await DioClient.instance.dio.get('/audits/mine').then((_) {}, onError: (_) {});
      await waitFor(() => auth.status == AuthStatus.unauthenticated);
      await settle(30);

      expect(await SecureStorage.instance.readToken(), isNull);
      expect(adapter.where('DELETE', _register).single.headers['Authorization'], 'Bearer jwt-A');
      expect(trayClears, 1);
    });

    test('any other 403 leaves the session alone', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      final inner = adapter.handler!;
      adapter.handler = (o) async => o.path.startsWith('/ncs')
          ? json(403, {'isOk': false, 'message': 'Only the auditor who raised this NC can verify it.'})
          : inner(o);

      await DioClient.instance.dio.get('/ncs/x').then((_) {}, onError: (_) {});
      await settle(30);

      expect(auth.status, AuthStatus.authenticated);
      expect(await SecureStorage.instance.readToken(), 'jwt-A');
    });

    test('offline: signs out locally anyway, and keeps the unregister to retry', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      final inner = adapter.handler!;
      adapter.handler = (o) async => o.path == _register ? connectionError(o) : inner(o);

      await auth.logout();

      expect(auth.status, AuthStatus.unauthenticated);
      expect(await SecureStorage.instance.readToken(), isNull);
      // Written before the sign-out's storage wipe and still there after it.
      final note = await SecureStorage.instance.readPendingUnregister();
      expect(note, allOf(contains('tok-1'), contains('jwt-A')));
      expect(fcmDeletes, 1);
    });

    test('the tray is cleared even when the FCM cleanup fails', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      FcmService.getFcmToken = () async => throw StateError('no FCM');
      await auth.logout();
      expect(trayClears, 1);
      expect(auth.status, AuthStatus.unauthenticated);
    });

    test('a failing tray clear never keeps the UI signed in', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      NotificationScheduler.clearTray = () async => throw StateError('plugin gone');
      await auth.logout();
      expect(auth.status, AuthStatus.unauthenticated);
      expect(await SecureStorage.instance.readToken(), isNull);
    });

    test('a login that starts during a sign-out waits for it', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      final order = <String>[];
      final inner = adapter.handler!;
      adapter.handler = (o) async {
        order.add('${o.method} ${o.path}');
        if (o.method == 'DELETE') await Future<void>.delayed(const Duration(milliseconds: 30));
        return inner(o);
      };

      final leaving = auth.logout();
      await settle();
      final entering = auth.login(username: 'B', password: 'x');
      await Future.wait([leaving, entering]);

      expect(order.indexOf('POST ${ApiConstants.login}'), greaterThan(order.indexOf('DELETE $_register')));
      expect(auth.status, AuthStatus.authenticated);
      expect(auth.user?.id, 'B');
      expect(await SecureStorage.instance.readToken(), 'jwt-B',
          reason: 'the old session\'s teardown wiped the new one\'s token');
    });
  });

  group('sign-out from the "Can\'t reach the server" screen', () {
    // The screen keeps status == offline for the whole teardown, so a retry
    // (the timer, a resume) can start — and be answered — in the middle of it.
    late Completer<void> meGate;
    late Completer<void> deleteGate;

    setUp(() {
      meGate = Completer<void>();
      deleteGate = Completer<void>();
    });

    Future<void> goOffline() async {
      await saveSession('jwt-saved');
      AuthProvider.sessionRetryDelays = const [Duration(hours: 1)];
      me = (o) async => connectionError(o);
      await auth.bootstrap();
      expect(auth.status, AuthStatus.offline);
    }

    // The next GET /auth/me is parked until [meGate] opens, then answers [answer].
    void parkNextMe(Future<ResponseBody> Function(RequestOptions) answer) {
      me = (o) async {
        await meGate.future;
        return answer(o);
      };
    }

    // The sign-out's FCM DELETE is parked until [deleteGate] opens, which keeps
    // the teardown running.
    void parkTeardown() {
      final inner = adapter.handler!;
      adapter.handler = (o) async {
        if (o.method == 'DELETE' && o.path == _register) await deleteGate.future;
        return inner(o);
      };
    }

    test('a restore answered in the middle of the teardown does not set the account up again', () async {
      await goOffline();
      parkNextMe((_) async => json(200, {'data': _user('u1')}));
      auth.didChangeAppLifecycleState(AppLifecycleState.resumed); // starts a restore
      await settle();
      expect(adapter.where('GET', ApiConstants.me), hasLength(2));

      parkTeardown();
      final leaving = auth.logout();
      await settle();
      // The screen has already left (Log out must not look frozen while the
      // unregister is parked); the teardown itself is still running.
      expect(auth.status, AuthStatus.unauthenticated);
      expect(await SecureStorage.instance.readToken(), isNotNull, reason: 'the teardown must still be running');

      meGate.complete(); // GET /auth/me answers 200, mid-teardown
      await settle();
      deleteGate.complete();
      await leaving;
      await settle(30);

      expect(auth.status, AuthStatus.unauthenticated);
      expect(auth.user, isNull);
      expect(sockets.sockets, isEmpty, reason: 'a socket was opened for the account that signed out');
      expect(adapter.where('POST', _register), isEmpty, reason: 'push registration was lifted for it');
      expect(await SecureStorage.instance.readToken(), isNull);
    });

    test('a resume or a retry during the teardown does not start a restore', () async {
      await goOffline();
      parkTeardown();
      final leaving = auth.logout();
      await settle();
      final asked = adapter.where('GET', ApiConstants.me).length;

      auth.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await auth.retrySession();
      await settle();
      expect(adapter.where('GET', ApiConstants.me), hasLength(asked));
      expect(auth.isBusy, isFalse);

      deleteGate.complete();
      await leaving;
      expect(auth.status, AuthStatus.unauthenticated);
    });

    test('a restore that finds the server unreachable does not put the offline screen back over the login screen', () async {
      await goOffline();
      parkNextMe((o) async => connectionError(o));
      auth.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();

      await auth.logout();
      meGate.complete();
      await settle(30);

      expect(auth.status, AuthStatus.unauthenticated);
      expect(sockets.sockets, isEmpty);
    });

    test('a 401 that outlived its session does not sign the next account out', () async {
      await goOffline();
      parkNextMe((_) async => json(401, {'message': 'expired'}));
      auth.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();

      await auth.logout();
      expect(await auth.login(username: 'B', password: 'x'), isNull);
      meGate.complete(); // the old session's request is refused only now
      await settle(30);

      expect(auth.status, AuthStatus.authenticated);
      expect(auth.user?.id, 'B');
      expect(await SecureStorage.instance.readToken(), 'jwt-B');
    });
  });

  group('preferences refresh', () {
    test('an answer for the account that signed out is not applied to the next one', () async {
      var asked = 0;
      final gate = Completer<void>();
      final inner = adapter.handler!;
      adapter.handler = (o) async {
        if (o.method == 'GET' && o.path == ApiConstants.mePreferences) {
          final n = ++asked;
          if (n == 1) await gate.future; // A's request stays on the wire
          return json(200, {
            'data': {'pushNotifications': n != 1}, // A: push off; anyone after: on
          });
        }
        return inner(o);
      };

      expect(await auth.login(username: 'A', password: 'x'), isNull);
      await waitFor(() => asked == 1);

      await auth.logout();
      expect(await auth.login(username: 'B', password: 'x'), isNull);
      // A's request still pending must not make B's own refresh a no-op.
      await waitFor(() => asked == 2);
      await settle(30);

      gate.complete(); // A's answer lands now
      await settle(30);

      expect(auth.user?.id, 'B');
      expect(auth.user?.preferences.pushNotifications, isTrue, reason: "A's switches were applied to B");
      expect(await NotificationPrefs.readPushEnabled(), isTrue, reason: "A's switch reached the mirror B's polls read");
    });

    test('is not issued while a sign-out is running', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      await settle(30);
      final deleteGate = Completer<void>();
      final inner = adapter.handler!;
      adapter.handler = (o) async {
        if (o.method == 'DELETE' && o.path == _register) await deleteGate.future;
        return inner(o);
      };
      final leaving = auth.logout();
      await settle();
      final asked = adapter.where('GET', ApiConstants.mePreferences).length;

      await auth.refreshPreferences();
      auth.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await settle();
      expect(adapter.where('GET', ApiConstants.mePreferences), hasLength(asked));

      deleteGate.complete();
      await leaving;
    });
  });

  group('re-login in the same process', () {
    test('a new socket per session, with the handlers registered on the old one', () async {
      var events = 0;
      void onNotification(dynamic _) => events++;

      expect(await auth.login(username: 'A', password: 'x'), isNull);
      SocketService.instance.on('new_notification', onNotification); // what AppShell's providers do
      sockets.sockets[0].receive('new_notification');
      await auth.logout();

      expect(await auth.login(username: 'B', password: 'x'), isNull);
      expect(sockets.sockets, hasLength(2));
      sockets.sockets[1].receive('new_notification');
      expect(events, 2);

      // Its own reconnect handler survived too, and the join carries B's token.
      sockets.sockets[1].receive('connect');
      await settle();
      expect(sockets.sockets[1].emitted, [('join', 'jwt-B')]);
    });

    test('push registration is allowed again for the next account', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      await auth.logout();
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isFalse, reason: 'registered while signed out');

      expect(await auth.login(username: 'B', password: 'x'), isNull);
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isTrue);
    });

    test('a socket reconnect nudges a push registration that failed while offline', () async {
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      await settle(30);
      SharedPreferences.setMockInitialValues({'bg_auth_token': 'jwt-A'});
      expect(FcmService.debugTokenRegistered, isFalse);

      sockets.sockets.single.receive('connect');
      await waitFor(() => FcmService.debugTokenRegistered);
    });
  });
}
