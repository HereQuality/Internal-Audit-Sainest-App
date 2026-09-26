import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/storage/secure_storage.dart';

import 'support/session_fakes.dart';

/// The 401 handling decides when a session ends, and the sign-out cleanup
/// (FCM unregister) needs the token that ended it — so the order and the
/// conditions matter.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late Dio dio;
  late List<String?> tokenSeenByLogout;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    adapter = FakeAdapter();
    dio = DioClient.instance.dio..httpClientAdapter = adapter;
    tokenSeenByLogout = [];
    DioClient.instance.onUnauthorized = () async {
      // What the real handler can still read at the moment it is called.
      tokenSeenByLogout.add(await SecureStorage.instance.readToken());
    };
  });

  tearDown(() => DioClient.instance.onUnauthorized = null);

  test('attaches the stored token', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async => json(200, {'ok': true});
    await dio.get('/x');
    expect(adapter.requests.single.headers['Authorization'], 'Bearer jwt-A');
  });

  test('a 401 for the stored token ends the session WITHOUT clearing it first', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async => json(401, {'message': 'expired'});

    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    await settle();

    // The handler runs the teardown, which needs the token to prove who is
    // signing out — the interceptor used to wipe it before calling.
    expect(tokenSeenByLogout, ['jwt-A']);
    expect(await SecureStorage.instance.readToken(), 'jwt-A');
  });

  test('a 401 with no handler installed still clears the stored token', () async {
    DioClient.instance.onUnauthorized = null;
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async => json(401, {});
    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    expect(await SecureStorage.instance.readToken(), isNull);
  });

  test('a 401 on a request that carried no token is not a logout signal', () async {
    adapter.handler = (_) async => json(401, {});
    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    await settle();
    expect(tokenSeenByLogout, isEmpty);
  });

  test('a 401 for a token that has since been replaced does not sign the new session out', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async {
      // While this request was in flight, someone else signed in.
      await SecureStorage.instance.saveToken('jwt-B');
      return json(401, {});
    };
    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    await settle();
    expect(tokenSeenByLogout, isEmpty);
    expect(await SecureStorage.instance.readToken(), 'jwt-B');
  });

  test('a 401 after the token was already cleared (sign-out under way) is ignored', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async {
      await SecureStorage.instance.clear();
      return json(401, {});
    };
    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    await settle();
    expect(tokenSeenByLogout, isEmpty);
  });

  // The server's `protect` answers every request of a blocked account with
  // this 403 (auth.middleware.js), in errorHandler.js's body shape.
  Map<String, dynamic> blocked() => {'success': false, 'status': 'fail', 'message': 'Your account has been blocked.'};

  test('a blocked account\'s 403 for the stored token ends the session, like a 401', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async => json(403, blocked());

    await expectLater(dio.get('/audits/mine'), throwsA(isA<DioException>()));
    await settle();

    expect(tokenSeenByLogout, ['jwt-A']);
  });

  test('a 403 that is only one endpoint saying no leaves the session alone', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    for (final refusal in [
      {'isOk': false, 'message': 'Only the auditor who raised this NC can verify it.'},
      {'isOk': false, 'message': 'Access denied'},
      {'success': false, 'status': 'fail', 'message': "Role 'Employee' is not authorized to access this route."},
      {'success': false, 'status': 'fail', 'message': 'You do not have "edit" permission for this page.'},
      {'isOk': false, 'message': 'Account blocked by admin', 'isBlocked': true}, // a login answer, not a session's
    ]) {
      adapter.handler = (_) async => json(403, refusal);
      await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    }
    await settle();
    expect(tokenSeenByLogout, isEmpty);
    expect(await SecureStorage.instance.readToken(), 'jwt-A');
  });

  test('a blocked-account 403 for a token that has since been replaced does not sign the new session out', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async {
      await SecureStorage.instance.saveToken('jwt-B');
      return json(403, blocked());
    };
    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    await settle();
    expect(tokenSeenByLogout, isEmpty);
  });

  test('a blocked-account 403 on the sign-out\'s own request (explicit token) is not a logout signal either', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    adapter.handler = (_) async => json(403, blocked());
    await expectLater(
      dio.delete('/x', options: DioClient.explicitBearer('jwt-A')),
      throwsA(isA<DioException>()),
    );
    await settle();
    expect(tokenSeenByLogout, isEmpty);
  });

  test('errors other than 401 (and the blocked account\'s 403) never end the session', () async {
    await SecureStorage.instance.saveToken('jwt-A');
    for (final status in [403, 500, 503]) {
      adapter.handler = (_) async => json(status, {});
      await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    }
    adapter.handler = (o) async => connectionError(o);
    await expectLater(dio.get('/x'), throwsA(isA<DioException>()));
    await settle();
    expect(tokenSeenByLogout, isEmpty);
    expect(await SecureStorage.instance.readToken(), 'jwt-A');
  });

  group('explicitBearer', () {
    test('sends the caller\'s token even with nothing stored', () async {
      adapter.handler = (_) async => json(200, {});
      await dio.delete('/x', options: DioClient.explicitBearer('old-jwt'));
      expect(adapter.requests.single.headers['Authorization'], 'Bearer old-jwt');
    });

    test('is not replaced by whatever is stored', () async {
      await SecureStorage.instance.saveToken('someone-else');
      adapter.handler = (_) async => json(200, {});
      await dio.delete('/x', options: DioClient.explicitBearer('old-jwt'));
      expect(adapter.requests.single.headers['Authorization'], 'Bearer old-jwt');
    });

    test('a 401 for it is not a logout signal (it would re-enter the teardown it belongs to)', () async {
      await SecureStorage.instance.saveToken('old-jwt');
      adapter.handler = (_) async => json(401, {});
      await expectLater(
        dio.delete('/x', options: DioClient.explicitBearer('old-jwt')),
        throwsA(isA<DioException>()),
      );
      await settle();
      expect(tokenSeenByLogout, isEmpty);
    });
  });
}
