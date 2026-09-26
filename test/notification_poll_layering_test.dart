import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/notifications/background_entrypoints.dart' show serviceShouldRun;
import 'package:internal_audit_app/core/notifications/event_poll.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/notifications/local_notifications.dart';
import 'package:internal_audit_app/core/notifications/notification_prefs.dart';
import 'package:internal_audit_app/core/notifications/overdue_poll.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The tests play "another isolate" by writing to the platform store behind
// the SharedPreferences instance this isolate has already cached.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/session_fakes.dart';

/// The local polls are the FALLBACK behind the server's own pushes: they must
/// not announce what the server already does, must only ever look at the
/// signed-in person's own items, and must not dump what happened while push
/// was switched off.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginChannel = MethodChannel('dexterous.com/flutter/local_notifications');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> shown;
  late _Server server;

  setUpAll(AndroidFlutterLocalNotificationsPlugin.registerWith);

  setUp(() {
    SharedPreferences.setMockInitialValues({'bg_auth_token': 'tok', 'bg_user_id': 'u1'});
    shown = [];
    server = _Server();
    messenger.setMockMethodCallHandler(pluginChannel, (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') shown.add(call.arguments['title'] as String);
      return null;
    });
    LocalNotifications.debugReset();
  });

  tearDown(() => messenger.setMockMethodCallHandler(pluginChannel, null));

  Future<void> tick() => server.tick();

  group('while the server can push to this phone the polls only keep the books', () {
    setUp(() async {
      await NotificationPrefs.setFcmPushReady(true);
    });

    test('a new audit, NC raised, approval, rejection and overdue NC are all left to the server', () async {
      server
        ..audits = [_audit('a1')]
        ..ncs = [_nc('n1', 'Raised'), _nc('n2', 'Raised'), _nc('n5', 'Raised')];
      await tick(); // baseline

      server
        ..audits = [_audit('a1'), _audit('a2')]
        ..ncs = [
          _nc('n1', 'Closed'),
          _nc('n2', 'Raised', reopen: 1),
          _nc('n3', 'Raised'),
          {..._nc('n5', 'Raised'), 'targetDate': '2000-01-01T00:00:00.000Z'},
        ];
      await tick();

      expect(shown, isEmpty);
    });

    test('what it held back is still recorded: the server path failing later does not dump it', () async {
      server.audits = [_audit('a1')];
      server.ncs = [_nc('n1', 'Raised')];
      await tick();
      server
        ..audits = [_audit('a1'), _audit('a2')]
        ..ncs = [_nc('n1', 'Closed'), _nc('n3', 'Raised')];
      await tick();
      expect(shown, isEmpty);

      // The registration is lost (a token pruned, the project changed): the poll is the fallback again...
      await NotificationPrefs.setFcmPushReady(false);
      await tick();
      expect(shown, isEmpty, reason: 'a2, n1 and n3 were already recorded');

      // ...and announces what is genuinely new from now on.
      server.audits = [_audit('a1'), _audit('a2'), _audit('a4')];
      await tick();
      expect(shown, ['New audit assigned']);
    });

    test('audit start and due reminders are still the poll\'s — no server job sends them', () async {
      server.audits = [_audit('a1')];
      await tick();
      server.audits = [_audit('a1'), _dueAudit('a2')];
      await tick();
      expect(shown, containsAll(['Audit starting', 'Audit due']));
      expect(shown, isNot(contains('New audit assigned')));
    });

    test('...and they still follow their own topic', () async {
      server.audits = [_audit('a1')];
      await tick();
      server
        ..types = {'audit_reminder': false}
        ..audits = [_audit('a1'), _dueAudit('a2')];
      await tick();
      expect(shown, isEmpty);
    });
  });

  group('on a phone the server cannot push to they are the fallback', () {
    test('every event still announces itself', () async {
      server
        ..audits = [_audit('a1')]
        ..ncs = [_nc('n1', 'Raised'), _nc('n2', 'Raised')];
      await tick();
      server
        ..audits = [_audit('a1'), _audit('a2')]
        ..ncs = [
          _nc('n1', 'Closed'),
          _nc('n2', 'Raised', reopen: 1),
          _nc('n3', 'Raised'),
          {..._nc('n4', 'Raised'), 'targetDate': '2000-01-01T00:00:00.000Z'},
        ];
      await tick();
      expect(
        shown,
        unorderedEquals([
          'New audit assigned',
          'NC response approved',
          'NC response rejected',
          'New NC raised against you',
          'New NC raised against you',
          'NC n4 is overdue',
        ]),
      );
    });

    test('registration in the token/pushReady sense is what counts: a server that said pushReady=false leaves them on', () async {
      await NotificationPrefs.setFcmPushReady(false);
      server.audits = [_audit('a1')];
      await tick();
      server.audits = [_audit('a1'), _audit('a2')];
      await tick();
      expect(shown, ['New audit assigned']);
    });
  });

  group('an event the server already announced on this phone is not announced twice', () {
    Future<void> serverBanner(String type, String ref) =>
        NotificationPrefs.claimBanner(notificationId: 'srv-$type-$ref', type: type, referenceId: ref);

    test('a new audit told by the socket / FCM is skipped, the untold one is not', () async {
      server.audits = [_audit('a1')];
      await tick();
      await serverBanner('audit_created', 'a2');
      server.audits = [_audit('a1'), _audit('a2'), _audit('a3')];
      await tick();
      expect(shown, ['New audit assigned']); // a3 only
    });

    test('an audit the server announced as a reassignment, or as a series, counts too', () async {
      server.audits = [_audit('a1')];
      await tick();
      await serverBanner('audit_reassigned', 'a2');
      await serverBanner('audit_series_created', 'a3');
      server.audits = [_audit('a1'), _audit('a2'), _audit('a3')];
      await tick();
      expect(shown, isEmpty);
    });

    test('NC raised and approved likewise', () async {
      server.ncs = [_nc('n1', 'Raised')];
      await tick();
      await serverBanner('nc_raised', 'n2');
      await serverBanner('nc_approved', 'n1');
      server.ncs = [_nc('n1', 'Closed'), _nc('n2', 'Raised')];
      await tick();
      expect(shown, isEmpty);
    });

    test('one server banner covers one rejection: the next rejection, whose push never came, is announced', () async {
      server.ncs = [_nc('n1', 'Raised')];
      await tick();

      await serverBanner('nc_rejected', 'n1');
      server.ncs = [_nc('n1', 'Raised', reopen: 1)];
      await tick();
      expect(shown, isEmpty);

      server.ncs = [_nc('n1', 'Raised', reopen: 2)];
      await tick();
      expect(shown, ['NC response rejected']);
    });

    test('an overdue NC the server announced is recorded, and left out of the group', () async {
      final overdue = {..._nc('n1', 'Raised'), 'targetDate': '2000-01-01T00:00:00.000Z'};
      final notYet = {..._nc('n2', 'Raised'), 'targetDate': '2099-01-01T00:00:00.000Z'};
      await serverBanner('nc_overdue', 'n1');
      server.ncs = [overdue, notYet];
      await tick();
      expect(shown, isEmpty);

      server.ncs = [overdue, {...notYet, 'targetDate': '2000-01-01T00:00:00.000Z'}];
      await tick();
      expect(shown, ['NC n2 is overdue']); // n1 is not "new" again
    });

    test('a topic that is off still uses the record up (nothing lingers to hide a later event)', () async {
      server.ncs = [_nc('n1', 'Raised')];
      await tick();
      await serverBanner('nc_rejected', 'n1');
      server
        ..types = {'nc_rejected': false}
        ..ncs = [_nc('n1', 'Raised', reopen: 1)];
      await tick();
      expect(await NotificationPrefs.consumeServerEvent(const ['nc_rejected'], 'n1'), isFalse);
    });
  });

  group('only the signed-in person\'s own items are fetched', () {
    test('both polls ask for employeeIds=<self> on the audit and NC lists, and only there', () async {
      await tick();
      final audits = server.requests.where((u) => u.path.endsWith('/audits/mine'));
      final ncs = server.requests.where((u) => u.path.endsWith('/ncs/mine'));
      expect(audits, hasLength(1));
      expect(ncs, hasLength(2), reason: 'the event poll and the overdue poll each read the NC list');
      for (final u in [...audits, ...ncs]) {
        expect(u.queryParameters, {'employeeIds': 'u1'});
      }
      final prefs = server.requests.where((u) => u.path.endsWith('/auth/me/preferences'));
      expect(prefs, isNotEmpty);
      expect(prefs.every((u) => u.queryParameters.isEmpty), isTrue);
    });

    test('with no known person nothing is fetched — never the unscoped (team / organisation) list', () async {
      SharedPreferences.setMockInitialValues({'bg_auth_token': 'tok'});
      await tick();
      expect(server.requests, isEmpty);
    });

    test('an account switch is followed: the next tick asks for the new person', () async {
      await tick();
      await NotificationPrefs.setSession(token: 'tok2', userId: 'u2');
      server.requests.clear();
      await tick();
      expect(
        server.requests.where((u) => u.path.endsWith('/audits/mine')).single.queryParameters,
        {'employeeIds': 'u2'},
      );
    });

    test('a user id another isolate wrote is read fresh, not the one cached at first read', () async {
      await tick();
      // The app signs in as somebody else while this (long-lived) isolate lives on.
      await SharedPreferencesStorePlatform.instance.setValue('String', 'flutter.bg_user_id', 'u3');
      expect(await NotificationPrefs.readUserId(), 'u3');
      server.requests.clear();
      await tick();
      expect(
        server.requests.where((u) => u.path.endsWith('/audits/mine')).single.queryParameters,
        {'employeeIds': 'u3'},
      );
    });
  });

  group('switching push back ON does not dump what happened while it was OFF', () {
    final overdueNc = {..._nc('n9', 'Raised'), 'targetDate': '2000-01-01T00:00:00.000Z'};

    test('the first tick after OFF -> ON records everything and shows nothing; the next one announces normally', () async {
      server
        ..audits = [_audit('a1')]
        ..ncs = [_nc('n1', 'Raised')];
      await tick(); // baseline while push is on

      // Push goes OFF on this phone (Settings, or the web): the polls stop
      // (the service stops itself, iOS never polled), so nothing is recorded...
      await NotificationPrefs.setPushEnabled(false);
      // ...while the world moves on.
      server
        ..audits = [_audit('a1'), _audit('a2'), _dueAudit('a3')]
        ..ncs = [_nc('n1', 'Closed'), _nc('n2', 'Raised'), overdueNc];

      await NotificationPrefs.setPushEnabled(true); // switched back on
      await tick();
      expect(shown, isEmpty, reason: 'a week the person had muted');

      server
        ..audits = [_audit('a1'), _audit('a2'), _dueAudit('a3'), _audit('a4')]
        ..ncs = [_nc('n1', 'Closed'), _nc('n2', 'Raised'), overdueNc, _nc('n6', 'Raised')];
      await tick();
      expect(shown, unorderedEquals(['New audit assigned', 'New NC raised against you']));
    });

    test('it takes ONE pass: both polls are back to normal afterwards', () async {
      await tick();
      await NotificationPrefs.setPushEnabled(false);
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollEvents), isTrue);
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollOverdue), isTrue);

      await NotificationPrefs.setPushEnabled(true);
      await tick();
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollEvents), isFalse);
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollOverdue), isFalse);
    });

    test('a tick that still finds push OFF changes nothing: the catch-up waits for it to come back', () async {
      server.audits = [_audit('a1')];
      await tick();
      await NotificationPrefs.setPushEnabled(false);
      server
        ..pushMaster = false
        ..audits = [_audit('a1'), _audit('a2')];
      await tick(); // records a2 silently, but this is not the pass that ends the suspension
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollEvents), isTrue);

      server
        ..pushMaster = true
        ..audits = [_audit('a1'), _audit('a2'), _audit('a3')]; // a3 happened just before ON
      await tick();
      expect(shown, isEmpty);
    });

    test('a tick that could not read the lists (offline) does not end the catch-up', () async {
      server.audits = [_audit('a1')];
      await tick();
      await NotificationPrefs.setPushEnabled(false);
      await NotificationPrefs.setPushEnabled(true);

      server
        ..auditsStatus = 503
        ..audits = [_audit('a1'), _audit('a2')];
      await tick();
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollEvents), isTrue);

      server.auditsStatus = 200;
      await tick();
      expect(shown, isEmpty, reason: 'the pass that finally read the list is the silent one');
      expect(await NotificationPrefs.readPollSuspended(NotificationPrefs.pollEvents), isFalse);
    });

    test('the master coming ON from the web while the phone was not listening is caught too', () async {
      server.audits = [_audit('a1')];
      await tick();
      // The phone last saw OFF (mirror written OFF) and the web switches it ON later.
      await NotificationPrefs.setPushEnabled(false);
      server.audits = [_audit('a1'), _audit('a2')];
      await tick(); // the service's next tick reads ON from the server and only records
      expect(shown, isEmpty);
    });

    test('a topic that was switched off and on again (master untouched) keeps working as before', () async {
      server.audits = [_audit('a1')];
      await tick();
      server
        ..types = {'audit_reassigned': false}
        ..audits = [_audit('a1'), _audit('a2')];
      await tick();
      server
        ..types = {}
        ..audits = [_audit('a1'), _audit('a2'), _audit('a3')];
      await tick();
      expect(shown, ['New audit assigned']);
    });
  });

  group('a session the server refused', () {
    test('a 401 is remembered, so the foreground service can stop instead of idling for hours', () async {
      await NotificationPrefs.setPushEnabled(true);
      expect(await serviceShouldRun(), isTrue);

      server.status = 401;
      await tick();

      expect(await NotificationPrefs.isSessionRejected(), isTrue);
      expect(await serviceShouldRun(), isFalse);
    });

    test('so is a blocked account (403)', () async {
      server.status = 403;
      await tick();
      expect(await serviceShouldRun(), isFalse);
    });

    test('a server error or being offline is not a verdict on the session', () async {
      server.status = 503;
      await tick();
      expect(await serviceShouldRun(), isTrue);
    });

    test('the next login (a new token) is not mistaken for the refused one', () async {
      server.status = 401;
      await tick();
      await NotificationPrefs.setSession(token: 'fresh', userId: 'u1');
      expect(await NotificationPrefs.isSessionRejected(), isFalse);
      expect(await serviceShouldRun(), isTrue);
    });

    test('signing out drops the note: it is a verbatim copy of a JWT, and a signed-out phone keeps none', () async {
      server.status = 401;
      await tick();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('bg_rejected_token'), 'tok');

      await NotificationPrefs.clearSession();

      await prefs.reload();
      expect(prefs.getKeys(), isNot(contains('bg_rejected_token')));
      expect(prefs.getKeys(), isNot(contains('bg_auth_token')));
      expect(await NotificationPrefs.isSessionRejected(), isFalse);
    });

    test('the app having the SAME session accepted again (a launch) clears the note too', () async {
      server.status = 403; // blocked... then unblocked
      await tick();
      await NotificationPrefs.setSession(token: 'tok', userId: 'u1');
      expect(await serviceShouldRun(), isTrue);
    });
  });

  group('PollPlan', () {
    const on = PushGate(enabled: true, types: {'nc_raised': false});

    test('the server pushing, or a catch-up tick, silences the fallback but not a phone-local topic', () {
      expect(const PollPlan(gate: on).showsFallback(topicOn: true), isTrue);
      expect(const PollPlan(gate: on, serverPushes: true).showsFallback(topicOn: true), isFalse);
      expect(const PollPlan(gate: on, catchUp: true).showsFallback(topicOn: true), isFalse);
      expect(const PollPlan(gate: on).showsFallback(topicOn: false), isFalse);

      expect(const PollPlan(gate: on, serverPushes: true).showsLocal('audit_reminder'), isTrue);
      expect(const PollPlan(gate: on, catchUp: true).showsLocal('audit_reminder'), isFalse);
      expect(const PollPlan(gate: on).showsLocal('nc_raised'), isFalse);
    });
  });

  group('the server-push flag follows the registration', () {
    late FakeAdapter adapter;
    late Completer<void>? holdPost;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({'bg_auth_token': 'mirror-jwt', 'bg_user_id': 'u1'});
      holdPost = null;
      adapter = FakeAdapter()
        ..handler = (o) async {
          if (o.method == 'POST') await holdPost?.future;
          return json(200, {'isOk': true, 'pushReady': true});
        };
      DioClient.instance.dio.httpClientAdapter = adapter;
      FcmService.debugReset();
      FcmService.debugSetInitialized(true);
      FcmService.postRetryPause = Duration.zero;
      FcmService.getFcmToken = () async => 'tok-1';
      FcmService.deleteFcmToken = () async {};
    });
    tearDown(FcmService.debugReset);

    test('the server accepting the token and saying it can send turns it on', () async {
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);
      await FcmService.registerToken();
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);
    });

    test('an older server that says nothing about pushReady counts as able', () async {
      adapter.handler = (_) async => json(200, {'isOk': true});
      await FcmService.registerToken();
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);
    });

    test('"registered, but the server cannot send to this project" keeps the fallback on', () async {
      adapter.handler = (_) async => json(200, {'isOk': true, 'pushReady': false, 'problem': 'wrong project'});
      await FcmService.registerToken();
      expect(FcmService.debugTokenRegistered, isTrue);
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);
    });

    test('a registration that did not get through never turns it on', () async {
      adapter.handler = (o) async => connectionError(o);
      await FcmService.registerToken();
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);
    });

    test('a token refresh turns it off until the new token is registered', () async {
      await FcmService.registerToken();
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);

      holdPost = Completer<void>();
      final refresh = FcmService.debugOnTokenRefresh('tok-2');
      await settle();
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);

      holdPost!.complete();
      await refresh;
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);
    });

    test('signing out turns it off, and so does clearing the session', () async {
      await FcmService.registerToken();
      await FcmService.unregisterToken(jwt: 'jwt');
      await settle();
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);

      await NotificationPrefs.setFcmPushReady(true);
      await NotificationPrefs.clearSession();
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);
    });

    group('a test push that could not be delivered', () {
      Map<String, dynamic> testAnswer(List<Map<String, dynamic>> results) => {
        'isOk': true,
        'data': {'sent': results.where((r) => r['ok'] == true).length, 'results': results, 'serverProjects': ['p']},
      };

      // The phone is registered and the server says it can send — but the APNs
      // key / credentials are broken, which only a real send reveals.
      Future<void> runTest(List<Map<String, dynamic>> results) async {
        adapter.handler = (o) async {
          if (o.method == 'POST' && o.path == ApiConstants.deviceTokenTest) return json(200, testAnswer(results));
          return json(200, {'isOk': true, 'pushReady': true});
        };
        await FcmService.runPushCheck();
      }

      test('turns the phone back into a fallback one: the polls and the socket may not stand down for it', () async {
        await FcmService.registerToken();
        expect(await NotificationPrefs.readFcmPushReady(), isTrue);

        await runTest([
          {'platform': 'android', 'ok': false, 'code': 'messaging/third-party-auth-error'},
        ]);
        expect(await NotificationPrefs.readFcmPushReady(), isFalse);

        // ...so the poll announces again.
        server.audits = [_audit('a1')];
        await tick();
        server.audits = [_audit('a1'), _audit('a2')];
        await tick();
        expect(shown, ['New audit assigned']);
      });

      test('a later test that gets through clears it', () async {
        await FcmService.registerToken();
        await runTest([
          {'platform': 'android', 'ok': false, 'code': 'x'},
        ]);
        await runTest([
          {'platform': 'android', 'ok': true},
        ]);
        expect(await NotificationPrefs.readFcmPushReady(), isTrue);
      });

      test('another phone\'s failure, or no result for this one, proves nothing about this phone', () async {
        await FcmService.registerToken();
        await runTest([
          {'platform': 'ios', 'ok': false, 'code': 'messaging/third-party-auth-error'},
        ]);
        expect(await NotificationPrefs.readFcmPushReady(), isTrue);
        await runTest(const []);
        expect(await NotificationPrefs.readFcmPushReady(), isTrue);
      });

      test('signing out forgets it', () async {
        await FcmService.registerToken();
        await runTest([
          {'platform': 'android', 'ok': false, 'code': 'x'},
        ]);
        await NotificationPrefs.clearSession();
        await FcmService.registerToken();
        expect(await NotificationPrefs.readFcmPushReady(), isTrue);
      });
    });

    test('it is read fresh: another isolate\'s registration is seen', () async {
      expect(await NotificationPrefs.readFcmPushReady(), isFalse);
      await SharedPreferencesStorePlatform.instance.setValue('Bool', 'flutter.bg_fcm_push_ready', true);
      expect(await NotificationPrefs.readFcmPushReady(), isTrue);
    });
  });
}

Map<String, dynamic> _audit(String id) => {
  '_id': id,
  'title': 'Audit $id',
  'status': 'Scheduled',
  'scheduledDate': '2099-01-01T00:00:00.000Z',
};

// Already past its start and due dates.
Map<String, dynamic> _dueAudit(String id) => {
  ..._audit(id),
  'scheduledDate': '2000-01-01T00:00:00.000Z',
  'scheduledEndDate': '2000-02-01T00:00:00.000Z',
};

Map<String, dynamic> _nc(String id, String status, {int reopen = 0}) => {
  '_id': id,
  'title': 'NC $id',
  'status': status,
  'reopenCount': reopen,
};

/// Plays the server for the phone's own polls (package:http, not Dio).
class _Server {
  Map<String, bool> types = {};
  bool pushMaster = true;
  List<Map<String, dynamic>> audits = [];
  List<Map<String, dynamic>> ncs = [];

  /// Status of every answer, and of the audit list alone.
  int status = 200;
  int auditsStatus = 200;

  final requests = <Uri>[];

  Future<void> tick() => http.runWithClient(
    () async {
      await pollAndNotifyOverdueNcs();
      await pollAndNotifyEvents();
    },
    () => http_testing.MockClient((request) async {
      requests.add(request.url);
      final path = request.url.path;
      var code = status;
      Object data;
      if (path.endsWith('/auth/me/preferences')) {
        data = {'pushNotifications': pushMaster, 'pushNotificationTypes': types};
      } else if (path.endsWith('/audits/mine')) {
        data = audits;
        if (auditsStatus != 200) code = auditsStatus;
      } else {
        data = ncs;
      }
      return http.Response(jsonEncode({'isOk': true, 'data': data}), code);
    }),
  );
}
