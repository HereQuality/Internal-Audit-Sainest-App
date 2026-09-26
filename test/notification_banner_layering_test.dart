import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/notifications/local_notifications.dart';
import 'package:internal_audit_app/core/notifications/notification_prefs.dart';
import 'package:internal_audit_app/providers/notifications_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The tests play "another isolate" by writing to the platform store behind
// the SharedPreferences instance this isolate has already cached.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/session_fakes.dart';

/// One server notification must be ONE banner on the phone, whichever of the
/// routes that can carry it (the socket, an FCM foreground callback, the FCM
/// background isolate) sees it first — and none of them may make the phone
/// silent when another route is broken.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pluginChannel = MethodChannel('dexterous.com/flutter/local_notifications');
  const timezoneChannel = MethodChannel('flutter_timezone');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Object? showError;
  late FakeSockets sockets;

  Iterable<MethodCall> shows() => calls.where((c) => c.method == 'show');
  Iterable<String> shownTitles() => shows().map((c) => c.arguments['title'] as String);

  Map<String, dynamic> serverNotification(
    String id, {
    String type = 'audit_created',
    String? referenceId = 'a1',
  }) => {
    '_id': id,
    'type': type,
    'title': 'Title $id',
    'message': 'Body $id',
    'referenceId': referenceId,
  };

  // Android's data-only shape.
  RemoteMessage dataPush(
    String id, {
    String type = 'audit_created',
    String? referenceId = 'a1',
    String? title,
  }) => RemoteMessage(
    messageId: 'm-$id',
    data: {
      'notificationId': id,
      'type': type,
      'referenceId': ?referenceId,
      'title': title ?? 'Title $id',
      'body': 'Body $id',
    },
  );

  // iOS's alert shape: the OS draws it, `data` is only there for routing.
  RemoteMessage alertPush(String id, {String type = 'audit_created', String? referenceId = 'a1'}) => RemoteMessage(
    messageId: 'm-$id',
    notification: const RemoteNotification(title: 'Title', body: 'Body'),
    data: {'notificationId': id, 'type': type, 'referenceId': ?referenceId},
  );

  setUpAll(AndroidFlutterLocalNotificationsPlugin.registerWith);

  setUp(() {
    SharedPreferences.setMockInitialValues({'bg_auth_token': 'tok', 'bg_user_id': 'u1'});
    calls = [];
    showError = null;
    messenger.setMockMethodCallHandler(pluginChannel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return true;
      final error = showError;
      if (call.method == 'show' && error != null) throw error;
      return null;
    });
    messenger.setMockMethodCallHandler(timezoneChannel, (call) async {
      calls.add(call);
      return 'Asia/Kolkata';
    });
    LocalNotifications.debugReset();
    FcmService.debugReset();
    FcmService.nativeAlertGrace = const Duration(milliseconds: 300);
    FcmService.nativeAlertPoll = const Duration(milliseconds: 20);
    sockets = FakeSockets();
    SocketService.debugInstance = sockets.service;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(pluginChannel, null);
    messenger.setMockMethodCallHandler(timezoneChannel, null);
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    FcmService.debugReset();
  });

  group('the banner ledger', () {
    test('the first route to claim a notification draws it, every later one stays quiet', () async {
      expect(await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'audit_created'), isTrue);
      expect(await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'audit_created'), isFalse);
      expect(await NotificationPrefs.claimBanner(notificationId: 'n2', type: 'audit_created'), isTrue);
    });

    test('two claims in the same instant cannot both win', () async {
      final results = await Future.wait([
        NotificationPrefs.claimBanner(notificationId: 'n1', type: 'nc_raised'),
        NotificationPrefs.claimBanner(notificationId: 'n1', type: 'nc_raised'),
      ]);
      expect(results.where((won) => won), hasLength(1));
    });

    test('a claim made by another isolate is seen (the store is re-read first)', () async {
      // This isolate has already used (and cached) its copy of the store.
      expect(await NotificationPrefs.claimBanner(notificationId: 'warm', type: 'audit_created'), isTrue);
      final now = DateTime.now().millisecondsSinceEpoch;
      await SharedPreferencesStorePlatform.instance.setValue(
        'StringList',
        'flutter.bg_banner_ledger',
        ['$now|n:from-fcm-isolate'],
      );
      expect(await NotificationPrefs.claimBanner(notificationId: 'from-fcm-isolate', type: 'audit_created'), isFalse);
    });

    test('a claim given back (drawing failed) can be made again', () async {
      await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'nc_raised', referenceId: 'nc1');
      await NotificationPrefs.releaseBanner(notificationId: 'n1', type: 'nc_raised', referenceId: 'nc1');
      expect(await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'nc_raised', referenceId: 'nc1'), isTrue);
      // ...and the release took the event record with it, so a poll is not told it was announced.
      await NotificationPrefs.releaseBanner(notificationId: 'n1', type: 'nc_raised', referenceId: 'nc1');
      expect(await NotificationPrefs.consumeServerEvent(const ['nc_raised'], 'nc1'), isFalse);
    });

    test('a notification without an id cannot be deduped, so it is always drawn', () async {
      expect(await NotificationPrefs.claimBanner(type: 'audit_created', referenceId: 'a1'), isTrue);
      expect(await NotificationPrefs.claimBanner(type: 'audit_created', referenceId: 'a1'), isTrue);
    });

    test('an event record is used up by the one poll observation it covers', () async {
      await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'nc_rejected', referenceId: 'nc1');
      expect(await NotificationPrefs.consumeServerEvent(const ['nc_rejected'], 'nc1'), isTrue);
      // A second rejection whose push never arrived has no record left.
      expect(await NotificationPrefs.consumeServerEvent(const ['nc_rejected'], 'nc1'), isFalse);
    });

    test('only the events a poll can derive are recorded as events', () async {
      await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'ticket_reply', referenceId: 't1');
      expect(await NotificationPrefs.consumeServerEvent(const ['ticket_reply'], 't1'), isFalse);
    });

    test('it stays bounded in size', () async {
      for (var i = 0; i < 350; i++) {
        await NotificationPrefs.claimBanner(notificationId: 'n$i', type: 'nc_raised', referenceId: 'nc$i');
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('bg_banner_ledger'), hasLength(300));
      // The newest survive, the oldest are the ones forgotten.
      expect(await NotificationPrefs.bannerClaimed('n349'), isTrue);
      expect(await NotificationPrefs.bannerClaimed('n0'), isFalse);
    });

    test('and in age: a claim from days ago no longer matters', () async {
      final longAgo = DateTime.now().subtract(const Duration(days: 4));
      await NotificationPrefs.claimBanner(notificationId: 'old', type: 'nc_raised', referenceId: 'nc1', now: longAgo);
      expect(await NotificationPrefs.bannerClaimed('old'), isFalse);
      expect(await NotificationPrefs.consumeServerEvent(const ['nc_raised'], 'nc1'), isFalse);
    });

    test('a different account signing in starts with an empty ledger', () async {
      await NotificationPrefs.claimBanner(notificationId: 'n1', type: 'nc_raised', referenceId: 'nc1');
      await NotificationPrefs.setSession(token: 't2', userId: 'someone-else');
      expect(await NotificationPrefs.bannerClaimed('n1'), isFalse);
    });
  });

  group('the entry point registered for background pushes', () {
    // firebase_messaging persists a callback HANDLE natively and Flutter maps it
    // back to a function by NAME. After an app update the phone still holds the
    // old build's handle until the new build has launched once, so the registered
    // symbol must keep the name the previous build registered.
    test('keeps the name an already-installed build has persisted', () {
      // A private top-level function prints as Function '<name>@<library key>'.
      expect('${FcmService.backgroundHandler}', contains("Function '_firebaseMessagingBackgroundHandler@"));
    });

    test('and does the same work as the public handler', () async {
      await FcmService.backgroundHandler(dataPush('n1', referenceId: 'a9'));
      expect(shownTitles(), ['Title n1']);
      expect(shows().single.arguments['payload'], 'audit_created|a9');
    });
  });

  group('what a push leaves in the logs', () {
    // debugPrint is not stripped from release builds: it reaches logcat and the
    // iOS unified log, so a push's title/body (audit and NC names, locations,
    // ticket text) must never be in it.
    test('the type and id of a push, never its content', () async {
      final lines = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => lines.add(message ?? '');
      addTearDown(() => debugPrint = original);

      await fcmBackgroundMessageHandler(dataPush('n1', title: 'Fire drill at Plant 7'));
      await FcmService.debugHandleForegroundMessage(dataPush('n2', title: 'Fire drill at Plant 7'));

      final log = lines.join('\n');
      expect(log, allOf(contains('audit_created'), contains('m-n1'), contains('m-n2')));
      expect(log, isNot(anyOf(contains('Fire drill'), contains('Body n1'), contains('Body n2'))));
    });
  });

  group('FCM data push (Android): one banner, drawn fast', () {
    test('the background handler draws it on the app-events channel, alerting once', () async {
      await fcmBackgroundMessageHandler(dataPush('n1', referenceId: 'a9'));

      expect(shownTitles(), ['Title n1']);
      final show = shows().single;
      expect(show.arguments['id'], LocalNotifications.serverNotificationId(notificationId: 'n1'));
      expect(show.arguments['payload'], 'audit_created|a9');
      final android = show.arguments['platformSpecifics'] as Map;
      expect(android['channelId'], LocalNotifications.appEventsChannelId);
      // The socket may draw the same id a moment later: that must update, not re-alert.
      expect(android['onlyAlertOnce'], isTrue);
    });

    test('a cold isolate gets the light init: plugin + both channels, no timezone database', () async {
      await fcmBackgroundMessageHandler(dataPush('n1'));

      expect(calls.where((c) => c.method == 'initialize'), hasLength(1));
      final channels = calls
          .where((c) => c.method == 'createNotificationChannel')
          .map((c) => c.arguments['id'])
          .toSet();
      expect(channels, {LocalNotifications.overdueChannelId, LocalNotifications.appEventsChannelId});
      expect(calls.where((c) => c.method == 'getLocalTimezone'), isEmpty, reason: 'timezone lookup is not on the push path');
      expect(calls.indexWhere((c) => c.method == 'createNotificationChannel'), lessThan(calls.indexWhere((c) => c.method == 'show')));
    });

    test('two pushes arriving together initialise the plugin once', () async {
      await Future.wait([
        fcmBackgroundMessageHandler(dataPush('n1')),
        fcmBackgroundMessageHandler(dataPush('n2')),
      ]);
      expect(calls.where((c) => c.method == 'initialize'), hasLength(1));
      expect(shows(), hasLength(2));
    });

    test('the same push delivered twice is drawn once', () async {
      await fcmBackgroundMessageHandler(dataPush('n1'));
      await fcmBackgroundMessageHandler(dataPush('n1'));
      expect(shows(), hasLength(1));
    });

    test('a message the OS draws itself (it has a notification block) is not drawn again', () async {
      await fcmBackgroundMessageHandler(alertPush('n1'));
      expect(shows(), isEmpty);
    });

    test('nothing is drawn for a phone nobody is signed in on', () async {
      SharedPreferences.setMockInitialValues({});
      await fcmBackgroundMessageHandler(dataPush('n1'));
      expect(shows(), isEmpty);
    });

    test('a session that ended in another isolate is seen (the token is re-read)', () async {
      await fcmBackgroundMessageHandler(dataPush('n1'));
      expect(shows(), hasLength(1));
      await SharedPreferencesStorePlatform.instance.remove('flutter.bg_auth_token');
      await fcmBackgroundMessageHandler(dataPush('n2'));
      expect(shows(), hasLength(1));
    });

    test('the server decides what to send: a stale switch mirror does not drop a push', () async {
      // Switched on from the web while this app was killed — the mirror still says off.
      await NotificationPrefs.setPushEnabled(false);
      await NotificationPrefs.setPushTypes({'audit_created': false});
      await fcmBackgroundMessageHandler(dataPush('n1'));
      expect(shows(), hasLength(1));
    });

    test('the server sends empty strings for what it has none of: still one banner per message, never one shared id', () async {
      RemoteMessage bare(String messageId) => RemoteMessage(
        messageId: messageId,
        data: const {'title': 'T', 'body': 'B', 'type': 'general', 'referenceId': '', 'notificationId': ''},
      );
      await fcmBackgroundMessageHandler(bare('m1'));
      await fcmBackgroundMessageHandler(bare('m2'));
      final ids = shows().map((c) => c.arguments['id']).toSet();
      expect(ids, hasLength(2), reason: 'two different messages must not replace each other in the tray');
      expect(shows().first.arguments['payload'], 'general|');
    });

    test('a message that only has a notification block still reads as a banner on Android', () async {
      await renderDataPush(RemoteMessage(
        messageId: 'console',
        notification: const RemoteNotification(title: 'From console', body: 'Hello'),
      ));
      expect(shows().single.arguments['title'], 'From console');
      expect(shows().single.arguments['body'], 'Hello');
    });

    test('a failed draw gives the claim back so another route can still show it', () async {
      showError = PlatformException(code: 'boom');
      await fcmBackgroundMessageHandler(dataPush('n1')); // logs, never throws
      expect(await NotificationPrefs.bannerClaimed('n1'), isFalse, reason: 'nothing is on screen, so nothing is claimed');
      showError = null;
      await fcmBackgroundMessageHandler(dataPush('n1'));
      expect(shows().where((c) => c.arguments['title'] == 'Title n1'), hasLength(2)); // the failed try + the retry
      expect(await NotificationPrefs.bannerClaimed('n1'), isTrue);
    });
  });

  group('socket + FCM on Android: whoever is first draws it, the other stays quiet', () {
    late NotificationsProvider provider;

    setUp(() {
      provider = NotificationsProvider()..startListening();
      SocketService.instance.connect('jwt');
    });
    tearDown(() => provider.resetForLogout());

    void socketReceives(Map<String, dynamic> n) => sockets.sockets.single.receive('new_notification', n);

    test('the socket first, then the FCM data push: one banner', () async {
      socketReceives(serverNotification('n1'));
      await waitFor(() => shows().isNotEmpty);
      await fcmBackgroundMessageHandler(dataPush('n1'));
      await settle();
      expect(shows(), hasLength(1));
    });

    test('FCM first, then the socket: one banner', () async {
      await FcmService.debugHandleForegroundMessage(dataPush('n1'));
      socketReceives(serverNotification('n1'));
      await settle(20);
      expect(shows(), hasLength(1));
    });

    test('two different notifications are two banners', () async {
      socketReceives(serverNotification('n1'));
      socketReceives(serverNotification('n2'));
      await waitFor(() => shows().length == 2);
    });

    test('with the master switch off the socket draws nothing', () async {
      await NotificationPrefs.setPushEnabled(false);
      socketReceives(serverNotification('n1'));
      await settle(20);
      expect(shows(), isEmpty);
    });

    test('with the topic off the socket draws nothing, the others still do', () async {
      await NotificationPrefs.setPushTypes({'nc_rejected': false});
      socketReceives(serverNotification('n1', type: 'nc_rejected', referenceId: 'nc1'));
      socketReceives(serverNotification('n2'));
      await waitFor(() => shows().isNotEmpty);
      await settle(20);
      expect(shownTitles(), ['Title n2']);
    });
  });

  group('iOS: never silent, never twice', () {
    late NotificationsProvider provider;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      provider = NotificationsProvider()..startListening();
      SocketService.instance.connect('jwt');
    });
    tearDown(() {
      provider.resetForLogout();
      AndroidFlutterLocalNotificationsPlugin.registerWith();
    });

    void socketReceives(Map<String, dynamic> n) => sockets.sockets.single.receive('new_notification', n);

    test('an alert push the OS drew in the foreground is only recorded, never drawn again', () async {
      await FcmService.debugHandleForegroundMessage(alertPush('n1', referenceId: 'a7'));
      expect(shows(), isEmpty);
      expect(await NotificationPrefs.bannerClaimed('n1'), isTrue);
    });

    test('the socket stays quiet when FCM reports the OS drew it within the grace period', () async {
      await NotificationPrefs.setFcmPushReady(true);
      socketReceives(serverNotification('n1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await FcmService.debugHandleForegroundMessage(alertPush('n1')); // the push lands after the socket event
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(shows(), isEmpty);
    });

    test('a push that never arrives (broken APNs setup) still gets a banner from the socket', () async {
      // The registration worked, so the app expects the OS to draw it — but nothing does.
      await NotificationPrefs.setFcmPushReady(true);
      socketReceives(serverNotification('n1'));
      await waitFor(() => shows().isNotEmpty);
      expect(shownTitles(), ['Title n1']);
    });

    test('a phone the server cannot push to gets the socket banner at once', () async {
      await NotificationPrefs.setFcmPushReady(false);
      final started = DateTime.now();
      socketReceives(serverNotification('n1'));
      await waitFor(() => shows().isNotEmpty);
      expect(DateTime.now().difference(started), lessThan(FcmService.nativeAlertGrace));
    });

    test('with the app in the background the OS banner is the only one', () async {
      await NotificationPrefs.setFcmPushReady(true);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      socketReceives(serverNotification('n1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(shows(), isEmpty);
    });

    test('an app that goes to the background while waiting draws nothing afterwards', () async {
      await NotificationPrefs.setFcmPushReady(true);
      socketReceives(serverNotification('n1'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(shows(), isEmpty);
    });

    test('the master switch off silences the socket path here too', () async {
      await NotificationPrefs.setFcmPushReady(false);
      await NotificationPrefs.setPushEnabled(false);
      socketReceives(serverNotification('n1'));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(shows(), isEmpty);
    });
  });

  group('the light init is only for banners: the full init still sets up time zones', () {
    test('init() reads the device time zone, initLight() does not', () async {
      await LocalNotifications.initLight();
      expect(calls.where((c) => c.method == 'getLocalTimezone'), isEmpty);
      await LocalNotifications.init();
      expect(calls.where((c) => c.method == 'getLocalTimezone'), hasLength(1));
      expect(calls.where((c) => c.method == 'initialize'), hasLength(1), reason: 'the plugin is not initialised twice');
    });

    test('a failed plugin init is retried on the next call', () async {
      var fail = true;
      messenger.setMockMethodCallHandler(pluginChannel, (call) async {
        if (call.method == 'initialize' && fail) throw PlatformException(code: 'not-ready');
        return call.method == 'initialize' ? true : null;
      });
      await expectLater(LocalNotifications.initLight(), throwsA(isA<PlatformException>()));
      fail = false;
      await LocalNotifications.initLight();
    });
  });
}
