import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../constants/api_constants.dart';
import '../network/dio_client.dart';
import 'local_notifications.dart';
import 'notification_navigation.dart';
import 'notification_prefs.dart';
import 'push_check.dart';

/// Real phone push delivery via Firebase Cloud Messaging
/// (server/services/fcmPush.service.js) — arrives even with the app fully
/// closed/killed, unlike event_poll.dart/overdue_poll.dart's local
/// polling (which only runs while the process/background service is
/// alive). The two deliberately overlap rather than one replacing the
/// other outright: a push can still be missed (device offline, a battery
/// optimizer killing things before FCM re-delivers), so the local poll
/// stays as the fallback net — a duplicate firing for the same event
/// costs nothing worse than two tray entries the first time this ships,
/// never a MISSED one.
///
/// The two platforms are sent different message shapes:
/// - Android: DATA-ONLY (title/body/type/referenceId/notificationId in
///   `data`, no `notification` block). Nothing draws it for us, so this
///   file renders a local notification from it (foreground handler +
///   [_firebaseMessagingBackgroundHandler]).
/// - iOS: an ALERT push (a `notification` block + apns headers). iOS draws
///   it itself — banner, sound, even with the app force-quit — so this file
///   must NOT render it a second time. `data` only carries type/
///   referenceId/notificationId, for tap routing.
///
/// EVERY call in this file is guarded so a not-yet-configured Firebase
/// project (no android/app/google-services.json / iOS
/// GoogleService-Info.plist yet — see NOTIFICATIONS.md) degrades to "no
/// push notifications" rather than a crash, same philosophy main.dart's
/// own NotificationBootstrap.init() guard already follows.
// Top-level, not a method — the `firebase_messaging` plugin spawns a
// SEPARATE background isolate to run this when a data-only message
// arrives while the app is backgrounded/killed (foreground delivery goes
// through FcmService._handleForegroundMessage instead, same process, no
// isolate hop needed there). A background isolate has none of the
// current process's state, so this can only do isolate-safe work — same
// constraint notification_prefs.dart's own doc comment describes for the
// AndroidAlarmManager/background_service isolates. Registering it is
// also what makes a data-only push (Android's message shape) get
// processed AT ALL while backgrounded — without an onBackgroundMessage
// handler registered, Android has nothing to hand a data-only message to
// and just drops it silently.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('FcmService: background message received: ${message.data}');
  // A message carrying a `notification` block is drawn by the OS itself
  // (every iOS push) — rendering it again here would show it twice.
  if (message.notification != null) return;
  final data = message.data;
  // No switch check here on purpose: the server is the authority for FCM and
  // only sends a push while the account's Push switch AND this topic's push
  // switch are both on. The SharedPreferences mirror can be stale (a topic
  // switched on from the web while this app was killed), and dropping a push
  // the server already approved would lose it until the app is next opened.
  // The mirror still gates the paths the server can't see: the socket banner
  // and the local polls.
  await Firebase.initializeApp();
  await LocalNotifications.init();
  final referenceId = data['referenceId'] as String?;
  await LocalNotifications.showLive(
    id: FcmService.localNotificationId(
      notificationId: data['notificationId'] as String?,
      fallback: referenceId ?? message.messageId,
    ),
    title: data['title'] as String? ?? 'Notification',
    body: data['body'] as String? ?? '',
    payload: encodeNotificationPayload(
      type: data['type'] as String? ?? 'general',
      referenceId: (referenceId == null || referenceId.isEmpty) ? null : referenceId,
    ),
  );
}

class FcmService {
  FcmService._();

  static bool _initialized = false;
  // Set once at init and never re-attached: a token can rotate at any time,
  // and one listener for the whole process is what keeps a rotation from
  // being POSTed once per login (this used to be attached inside
  // registerToken, so every login added another subscription).
  static StreamSubscription<String>? _tokenRefreshSubscription;
  // True once the current token has been accepted by the server for the
  // signed-in account; cleared on unregister. See [pushShownNatively].
  static bool _tokenRegistered = false;
  // Whether the server said it can actually SEND to this device. False when
  // the app's Firebase project isn't one the server holds credentials for
  // (the answer to POST /device-tokens/register says so, with a reason).
  static bool _serverCanSend = true;
  static String? _serverProblem;
  static bool _registering = false;

  // ~10 s in total. On a real device the APNs token normally lands within a
  // second or two of launch; on an iOS Simulator (or a build without the
  // Push entitlement) it never does, and that has to end in a clear message
  // rather than an endless wait.
  static const _apnsPollAttempts = 20;
  static const _apnsPollInterval = Duration(milliseconds: 500);

  /// Whether Firebase was configured successfully at launch — lets callers
  /// tell "no Firebase project here" apart from "permission denied".
  static bool get isReady => _initialized;

  /// iOS only: true once this device's token is registered for the
  /// signed-in account. From then on the server's ALERT pushes are drawn by
  /// iOS itself, also while the app is open (see the presentation options in
  /// [init]) — so the socket-driven local banner for the same event
  /// (NotificationsProvider) has to stay quiet, or every notification would
  /// show twice. Before registration succeeds it is false, so that banner
  /// still acts as the fallback.
  static bool get pushShownNatively =>
      defaultTargetPlatform == TargetPlatform.iOS &&
      _tokenRegistered &&
      _serverCanSend;

  /// Why the server can't push to this phone, when it has said so at
  /// registration (null = fine, or not registered yet). Shown by the
  /// Settings "Send a test notification" check.
  static String? get serverProblem => _serverProblem;

  /// Local-notification id for one server notification. FCM's data
  /// `notificationId` and the socket `new_notification` payload's `_id` are
  /// the same Mongo id, and both display paths (NotificationsProvider for
  /// the socket, the handlers in this file for FCM) derive their id from it
  /// HERE — so a socket banner and an FCM banner for the same event land on
  /// the same id and replace each other instead of stacking. [fallback] is
  /// only for a server that doesn't send `notificationId` yet.
  static int localNotificationId({String? notificationId, String? fallback}) {
    final key = (notificationId != null && notificationId.isNotEmpty)
        ? notificationId
        : (fallback ?? '');
    return key.hashCode & 0x7fffffff;
  }

  /// Called once from main.dart, right alongside NotificationBootstrap
  /// .init() and BEFORE [consumeLaunchPayload] — registers the
  /// foreground/opened-app/background listeners. Token REGISTRATION with
  /// the server happens separately, per-login (see [registerToken]), not
  /// here.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedAppMessage);
      // Must be a top-level function reference, not a closure/method —
      // the plugin passes it to a background isolate by reference, which
      // can't capture instance/closure state. See its own doc comment.
      FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh.listen(_onTokenRefresh);
      _initialized = true;
      debugPrint('FcmService.init succeeded — Firebase configured, listeners registered.');
    } catch (e, st) {
      debugPrint('FcmService.init failed (Firebase not set up yet?), continuing without push: $e\n$st');
      return;
    }
    // Separate from the try above so a failure here can't take the whole
    // push setup down with it. iOS shows nothing for a push that arrives
    // while the app is open unless told to (persisted natively, no-op on
    // Android); without it an FCM alert push would only ever appear with
    // the app backgrounded.
    try {
      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (e, st) {
      debugPrint('FcmService: could not enable foreground presentation: $e\n$st');
    }
  }

  /// Set once, before runApp, if the app process was NOT already running
  /// and got launched by tapping an FCM push (cold start) — same
  /// "consume later, once the app shell can actually navigate" contract
  /// as LocalNotifications.consumeLaunchPayload, and folded into the SAME
  /// `_pendingLaunchPayload` variable in main.dart (only one of the two
  /// cold-start sources can be true for a given launch), so _RootGate's
  /// existing one-shot consumption logic needs no changes for this.
  static Future<String?> consumeLaunchPayload() async {
    if (!_initialized) return null;
    try {
      return _payloadFor(await FirebaseMessaging.instance.getInitialMessage());
    } catch (_) {
      return null;
    }
  }

  /// iOS notification permission, asked through Firebase Messaging — the
  /// call that shows the OS prompt AND makes the plugin register with APNs
  /// once it's granted. Deliberately not permission_handler: on iOS its
  /// notification support only exists when a native build define is set
  /// (see ios/Podfile), and without it request() silently answers
  /// "permanently denied" without ever prompting. An answered prompt
  /// doesn't re-prompt — this just returns the standing decision. Returns
  /// whether alerts are allowed (authorized, or provisional).
  static Future<bool> requestIosPermission() async {
    if (!_initialized) return false;
    try {
      final settings = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (e, st) {
      debugPrint('FcmService.requestIosPermission failed: $e\n$st');
      return false;
    }
  }

  // Android's data-only message (see the class doc comment) arriving while
  // the app is in the foreground, where the OS would otherwise show
  // nothing at all for a pure data message. Rendered through the exact
  // same display layer + payload scheme as a live socket notification
  // (notifications_provider.dart's own banner), so a push and the in-app
  // socket event for the same thing read identically and route identically
  // on tap.
  static Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint('FcmService: foreground message received: ${message.data}');
    // iOS presents an alert push itself while the app is open (the
    // presentation options set in [init]) — drawing it here as well would
    // show two banners for one push.
    if (defaultTargetPlatform == TargetPlatform.iOS && message.notification != null) return;
    // No switch check here either — see the background handler above: the
    // server only sends what the account's switches allow.
    final data = message.data;
    await LocalNotifications.showLive(
      id: localNotificationId(
        notificationId: data['notificationId'] as String?,
        fallback: (data['referenceId'] as String?) ?? message.messageId,
      ),
      title: data['title'] as String? ?? 'Notification',
      body: data['body'] as String? ?? '',
      payload: _payloadFor(message),
    );
  }

  // The app was backgrounded (not killed) when the tap landed — same
  // routing destination as a local-notification tap, just reached through
  // FCM's own callback instead of flutter_local_notifications'.
  static void _handleOpenedAppMessage(RemoteMessage message) {
    final payload = _payloadFor(message);
    if (payload == null) return;
    handleLocalNotificationTap(payload);
  }

  static String? _payloadFor(RemoteMessage? message) {
    if (message == null) return null;
    final data = message.data;
    final referenceId = data['referenceId'] as String?;
    return encodeNotificationPayload(
      type: data['type'] as String? ?? 'general',
      referenceId: (referenceId == null || referenceId.isEmpty) ? null : referenceId,
    );
  }

  /// Fetches this device's FCM token and registers it with the server
  /// (POST /device-tokens/register) — called from
  /// NotificationScheduler.onLoggedIn, the same place the local poll's
  /// own session gets armed. FCM's own token-refresh event (a token can
  /// rotate at any time, not just on login) is handled by the single
  /// listener [init] attaches.
  static Future<void> registerToken() async {
    if (!_initialized || _registering) return;
    _registering = true;
    try {
      // On iOS getToken() throws `apns-token-not-set` until APNs has
      // handed the device its own token, and that arrives asynchronously
      // after launch/permission — so wait for it instead of failing on the
      // first login.
      if (defaultTargetPlatform == TargetPlatform.iOS && !await _waitForApnsToken()) {
        debugPrint(
          'FcmService.registerToken: no APNs token after '
          '${_apnsPollAttempts * _apnsPollInterval.inMilliseconds ~/ 1000}s — iOS push cannot work yet. '
          'Check: (1) the Push Notifications capability / ios/Runner/Runner.entitlements is in the '
          'signed build, (2) this is a real iPhone (simulators get no APNs token), (3) notification '
          'permission was allowed. The token is registered automatically if it arrives later '
          '(token refresh), otherwise on the next login.',
        );
        return;
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        debugPrint('FcmService.registerToken: Firebase returned no FCM token.');
        return;
      }
      if (kDebugMode) {
        debugPrint('FcmService: FCM token (paste it into Firebase console > Messaging > Send test message): $token');
      }
      await _postToken(token);
    } catch (e, st) {
      debugPrint('FcmService.registerToken failed: $e\n$st');
    } finally {
      _registering = false;
    }
  }

  /// Registers this phone if it isn't yet — for the moments the login-time
  /// attempt can't cover: it failed (a flaky connection right at launch), or
  /// notifications were allowed in the system settings afterwards. Called
  /// when the app comes back to the foreground. Never prompts: on iOS it
  /// only reads the standing permission.
  static Future<void> ensureRegistered() async {
    if (!_initialized || _tokenRegistered || _registering) return;
    if (await NotificationPrefs.readToken() == null) return;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final settings = await FirebaseMessaging.instance.getNotificationSettings();
        final allowed = settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
        if (!allowed) return;
      }
      await registerToken();
    } catch (e, st) {
      debugPrint('FcmService.ensureRegistered failed: $e\n$st');
    }
  }

  // The Firebase project this build's config file belongs to. The server
  // needs it: a token only works with that project's credentials.
  static String? _firebaseProjectId() {
    try {
      return Firebase.app().options.projectId;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _waitForApnsToken() async {
    for (var attempt = 1; attempt <= _apnsPollAttempts; attempt++) {
      if (await FirebaseMessaging.instance.getAPNSToken() != null) return true;
      if (attempt < _apnsPollAttempts) await Future<void>.delayed(_apnsPollInterval);
    }
    return false;
  }

  // FCM rotated this device's token. Only meaningful with a session: when
  // signed out the POST could only 401, and the next login's
  // [registerToken] picks the current token up anyway.
  static Future<void> _onTokenRefresh(String token) async {
    if (await NotificationPrefs.readToken() == null) return;
    await _postToken(token);
  }

  // One retry — the registration is the only thing standing between this
  // device and every push, and it usually fires right at login/launch
  // when the connection can still be waking up.
  static Future<void> _postToken(String token) async {
    const attempts = 2;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        final res = await DioClient.instance.dio.post(
          ApiConstants.deviceTokenRegister,
          data: {
            'token': token,
            'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
            'firebaseProjectId': _firebaseProjectId(),
          },
        );
        _tokenRegistered = true;
        // An older server doesn't say; only an explicit `false` is a problem.
        final body = res.data;
        _serverCanSend = !(body is Map && body['pushReady'] == false);
        _serverProblem = _serverCanSend ? null : (body as Map)['problem']?.toString();
        if (!_serverCanSend) debugPrint('FcmService: server cannot push to this phone: $_serverProblem');
        return;
      } catch (e, st) {
        debugPrint('FcmService._postToken failed (attempt $attempt/$attempts): $e\n$st');
        if (attempt < attempts) await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  /// Un-registers this device's current token — called from
  /// NotificationScheduler.onLoggedOut so a signed-out device stops
  /// receiving pushes meant for the account that was just signed out of
  /// (mirrors the web app's own unsubscribe-on-logout for browser push).
  /// Only works while the bearer token is still valid, i.e. it has to run
  /// BEFORE the session is cleared — after that the DELETE just 401s.
  static Future<void> unregisterToken() async {
    if (!_initialized) return;
    _tokenRegistered = false;
    _serverCanSend = true;
    _serverProblem = null;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await DioClient.instance.dio.delete(
        ApiConstants.deviceTokenRegister,
        data: {'token': token},
      );
    } catch (e, st) {
      debugPrint('FcmService.unregisterToken failed: $e\n$st');
    }
  }
  /// Settings > "Send a test notification". Re-registers this phone, then asks
  /// the server to push a real test to this account's phones and explains the
  /// outcome (see [describePushTestResponse]). Also reports what the phone
  /// itself knows — permission, Apple push token, Firebase project — because
  /// "nothing arrived" has a different fix for each.
  static Future<PushCheck> runPushCheck() async {
    final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
    if (!_initialized) {
      return const PushCheck(
        ok: false,
        title: "Push isn't set up in this build",
        lines: [
          'This build has no working Firebase configuration '
              '(GoogleService-Info.plist / google-services.json), so it cannot '
              'receive push notifications.',
        ],
      );
    }

    final local = <String>[];
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      local.add('Permission on this phone: ${settings.authorizationStatus.name}');
      if (platform == 'ios') {
        final apns = await FirebaseMessaging.instance.getAPNSToken();
        local.add(
          apns != null
              ? 'Apple push token: received'
              : 'Apple push token: NOT received (real iPhone, Push Notifications capability and permission are all required)',
        );
      }
    } catch (e) {
      debugPrint('FcmService.runPushCheck: could not read phone state: $e');
    }
    local.add('This app\'s Firebase project: ${_firebaseProjectId() ?? 'unknown'}');

    // Refresh the server's copy of this phone's token first, so the test goes
    // to what the phone holds NOW (and the server can report a project it
    // has no credentials for).
    await registerToken();
    if (_serverProblem != null) {
      return PushCheck(
        ok: false,
        title: "The server can't push to this phone",
        lines: [_serverProblem!, ...local],
      );
    }

    try {
      final res = await DioClient.instance.dio.post(ApiConstants.deviceTokenTest);
      final body = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};
      return describePushTestResponse(body, platform: platform, localLines: local);
    } on DioException catch (e) {
      final data = e.response?.data;
      final message = data is Map && data['message'] != null
          ? '${data['message']}'
          : 'Could not reach the server (${e.type.name}).';
      return PushCheck(ok: false, title: "Couldn't run the test", lines: [message, ...local]);
    } catch (e) {
      return PushCheck(ok: false, title: "Couldn't run the test", lines: ['$e', ...local]);
    }
  }
}
