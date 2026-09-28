import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show DioException;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../constants/api_constants.dart';
import '../network/dio_client.dart';
import '../storage/secure_storage.dart';
import 'local_notifications.dart';
import 'notification_navigation.dart';
import 'notification_prefs.dart';
import 'push_check.dart';

/// Top-level, not a method — the `firebase_messaging` plugin spawns a
/// SEPARATE background isolate to run this when a data-only message
/// arrives while the app is backgrounded/killed (foreground delivery goes
/// through FcmService._handleForegroundMessage instead, same process, no
/// isolate hop needed there). A background isolate has none of the
/// current process's state, so this can only do isolate-safe work — same
/// constraint notification_prefs.dart's own doc comment describes for the
/// foreground-service isolate. Registering it is also what makes a
/// data-only push (Android's message shape) get processed AT ALL while
/// backgrounded — without an onBackgroundMessage handler registered,
/// Android has nothing to hand a data-only message to and just drops it
/// silently.
///
/// Built for speed: this cold isolate exists to put one banner on screen.
/// It touches no Firebase API (so no `Firebase.initializeApp()` round trip —
/// the plugin has already handed us the message) and uses the light
/// notification init (plugin + channels, no timezone database).
@pragma('vm:entry-point')
Future<void> fcmBackgroundMessageHandler(RemoteMessage message) async {
  debugPrint('FcmService: background message received (${_describe(message)})');
  // A message carrying a `notification` block is drawn by the OS itself
  // (every iOS push) — rendering it again here would show it twice.
  if (message.notification != null) return;
  try {
    await renderDataPush(message);
  } catch (e, st) {
    debugPrint('FcmService: could not draw a background push: $e\n$st');
  }
}

/// The name this handler was registered under before [fcmBackgroundMessageHandler]
/// existed, kept on purpose. firebase_messaging does not store the function, it
/// stores a callback HANDLE in native preferences, and Flutter maps that handle
/// back to a function BY NAME (and library). A phone that has just been updated
/// still holds the old build's handle until this build has been launched once
/// and registered again — a push landing in that gap would look up a symbol
/// that no longer exists and be dropped. So the entry point that gets registered
/// keeps the original name, in this same file, and only delegates.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) =>
    fcmBackgroundMessageHandler(message);

// What a log line may say about a push: its type and id, never `data` — that
// carries the notification's title and body (audit and NC names, locations,
// ticket text), and debugPrint is not stripped from a release build (it
// reaches logcat and the iOS unified log).
String _describe(RemoteMessage message) => 'type: ${message.data['type']}, id: ${message.messageId}';

/// Draws one FCM data push (Android's message shape) as a local banner —
/// shared by the foreground listener and the background isolate.
///
/// Two gates, deliberately different:
/// - a SESSION check: with nobody signed in the push belongs to an account
///   that has left this phone (a sign-out that couldn't reach the server
///   leaves its token registered until the DELETE lands), and drawing it
///   would show that account's titles on a phone that now shows a login
///   screen. Nothing is signed in when the mirrored session token is gone.
/// - NO switch check: the server is the authority for FCM and only sends a
///   push while the account's Push switch AND this topic's push switch are
///   both on. The SharedPreferences mirror can be stale (a switch turned on
///   from the web while this app was killed), and dropping a push the
///   server already approved would lose it until the app is next opened.
///   The mirror still gates the paths the server can't see: the socket
///   banner and the local polls.
@visibleForTesting
Future<void> renderDataPush(RemoteMessage message) async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty) return;
  final data = message.data;
  final referenceId = data['referenceId'] as String?;
  final notificationId = data['notificationId'] as String?;
  await LocalNotifications.showServerBanner(
    // A server that predates notificationId still gets a stable tray id (from
    // the reference, else the message id) and is never deduped (there is
    // nothing exact to key on).
    notificationId: notificationId,
    fallbackKey: message.messageId,
    type: data['type'] as String? ?? 'general',
    referenceId: referenceId,
    // A console "test message" arrives with a notification block instead of
    // our data keys; read that too rather than drawing an empty banner.
    title: data['title'] as String? ?? message.notification?.title ?? 'Notification',
    body: data['body'] as String? ?? message.notification?.body ?? '',
  );
}

// How a POST /device-tokens/register (or DELETE) ended, as far as retrying
// goes: a 4xx (other than a timeout / rate limit) will not change by asking
// again, so only the rest is worth a later attempt.
enum _Post { registered, retry, rejected }

enum _Unregistered { removed, rejected, unreachable, skipped }

bool _isPermanentRejection(int? status) =>
    status != null && status >= 400 && status < 500 && status != 408 && status != 429;

/// Real phone push delivery via Firebase Cloud Messaging
/// (server/services/fcmPush.service.js) — arrives even with the app fully
/// closed/killed, unlike event_poll.dart/overdue_poll.dart's local
/// polling (which only runs while the process/background service is
/// alive).
///
/// The layers do not announce the same thing twice. The server owns every
/// event it pushes (audit assigned, NC raised/approved/rejected/overdue,
/// tickets, summaries): FCM, and the socket while the app is open, draw it,
/// and both go through [LocalNotifications.showServerBanner], whose shared
/// ledger (NotificationPrefs.claimBanner) makes the second route stay quiet.
/// The local polls are the FALLBACK for a phone the server cannot push to
/// (no token registered, `pushReady: false`, Firebase unavailable) and the
/// source of the one topic no server job sends (audit_reminder); while
/// [NotificationPrefs.readFcmPushReady] is true they only keep their
/// bookkeeping. See NOTIFICATIONS.md, "One banner per event".
///
/// The two platforms are sent different message shapes:
/// - Android: DATA-ONLY (title/body/type/referenceId/notificationId in
///   `data`, no `notification` block). Nothing draws it for us, so this
///   file renders a local notification from it (foreground handler +
///   [fcmBackgroundMessageHandler]).
/// - iOS: an ALERT push (a `notification` block + apns headers). iOS draws
///   it itself — banner, sound, even with the app force-quit — so this file
///   must NOT render it a second time. `data` only carries type/
///   referenceId/notificationId, for tap routing. With the app open the
///   plugin still tells Dart about it (onMessage): that is recorded in the
///   ledger, which is how the socket path learns the OS already drew it.
///
/// EVERY call in this file is guarded so a not-yet-configured Firebase
/// project (no android/app/google-services.json / iOS
/// GoogleService-Info.plist yet — see NOTIFICATIONS.md) degrades to "no
/// push notifications" rather than a crash, same philosophy main.dart's
/// own NotificationBootstrap.init() guard already follows.
class FcmService {
  FcmService._();

  static bool _initialized = false;
  // The core of [init] while it is running, so that a caller that gave up
  // waiting for it (main.dart's timeout) doesn't leave the launch-tap read to
  // conclude that nothing is set up.
  static Future<void>? _initRun;
  // Set once at init and never re-attached: a token can rotate at any time,
  // and one listener for the whole process is what keeps a rotation from
  // being POSTed once per login (this used to be attached inside
  // registerToken, so every login added another subscription).
  static StreamSubscription<String>? _tokenRefreshSubscription;
  // The other two listeners, kept so a second run of the core (a hot restart
  // re-runs main() in the same process; an init that half-failed and is tried
  // again) replaces them instead of stacking — every foreground push would
  // otherwise be handled, and its banner claimed, once per subscription.
  static StreamSubscription<RemoteMessage>? _onMessageSubscription;
  static StreamSubscription<RemoteMessage>? _onOpenedSubscription;
  // True once the current token has been accepted by the server for the
  // signed-in account; cleared on unregister. Its persisted, cross-isolate
  // counterpart (which the polls and the iOS socket path actually read) is
  // NotificationPrefs.readFcmPushReady.
  static bool _tokenRegistered = false;
  // Whether the server said it can actually SEND to this device. False when
  // the app's Firebase project isn't one the server holds credentials for
  // (the answer to POST /device-tokens/register says so, with a reason).
  static bool _serverCanSend = true;
  static String? _serverProblem;
  // The registration attempt in flight, if any. Shared, so a second caller
  // (a resume, the Settings check) waits for the same result instead of
  // racing it, and a sign-out can let it finish before deleting its row.
  static Future<void>? _registration;
  // The token the server holds for the signed-in account — what sign-out
  // deletes, known even when FCM itself can't be asked for it (offline).
  static String? _registeredToken;
  // True from sign-out until the next sign-in ([onSessionStarted]). Nothing
  // registers this phone while it is set: not a retry, not a token refresh,
  // not a resume — the account it would bind the phone to just left.
  static bool _signedOut = false;
  // Bumped by sign-out; every registration remembers the value it started
  // under and gives up (and never marks itself registered) if it changed.
  static int _session = 0;
  static Timer? _retryTimer;
  static int _retryAttempt = 0;
  static Future<void>? _pendingRetry;

  // Foreground backoff for a registration that failed (flaky connection at
  // login, FCM not reachable yet). Only a nudge: timers don't run while the
  // OS has the app suspended, so the resume / socket-reconnect / token
  // refresh triggers stay the ones that actually cover a locked phone.
  @visibleForTesting
  static List<Duration> retryDelays = const [
    Duration(seconds: 5),
    Duration(seconds: 30),
    Duration(minutes: 2),
  ];
  @visibleForTesting
  static Duration postRetryPause = const Duration(seconds: 2);

  /// iOS, app open, FCM expected to work: how long the socket path waits for
  /// FCM's own foreground callback to report that iOS drew the alert push
  /// before drawing a banner of its own. The socket event lands within a
  /// fraction of a second of the server's send and the push a second or two
  /// after it; a push that hasn't shown by then is not going to (a broken
  /// APNs key, a dropped push), and silence is the worse failure than the
  /// rare late duplicate.
  @visibleForTesting
  static Duration nativeAlertGrace = const Duration(seconds: 4);
  @visibleForTesting
  static Duration nativeAlertPoll = const Duration(milliseconds: 250);

  // Sign-out must never hang the screen on a dead network.
  static const _settleTimeout = Duration(seconds: 3);
  static const _unregisterTimeout = Duration(seconds: 6);
  static const _deleteTokenTimeout = Duration(seconds: 4);

  // Firebase's own calls, swappable so the registration logic can run in a
  // unit test — the plugin only works on a device.
  @visibleForTesting
  static Future<String?> Function() getFcmToken = () => FirebaseMessaging.instance.getToken();
  @visibleForTesting
  static Future<void> Function() deleteFcmToken = () => FirebaseMessaging.instance.deleteToken();
  @visibleForTesting
  static Future<void> Function() initCore = _initCore;
  @visibleForTesting
  static Future<RemoteMessage?> Function() getInitialMessage = () => FirebaseMessaging.instance.getInitialMessage();

  /// What [_initCore] registers with the plugin for background messages — see
  /// [_firebaseMessagingBackgroundHandler] for why it is that symbol.
  @visibleForTesting
  static const BackgroundMessageHandler backgroundHandler = _firebaseMessagingBackgroundHandler;
  @visibleForTesting
  static void debugSetInitialized(bool value) => _initialized = value;
  @visibleForTesting
  static void debugReset() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _initialized = false;
    _initRun = null;
    initCore = _initCore;
    getInitialMessage = () => FirebaseMessaging.instance.getInitialMessage();
    _onMessageSubscription?.cancel();
    _onMessageSubscription = null;
    _onOpenedSubscription?.cancel();
    _onOpenedSubscription = null;
    _tokenRegistered = false;
    _serverCanSend = true;
    _serverProblem = null;
    _registration = null;
    _registeredToken = null;
    _signedOut = false;
    _session = 0;
    _retryAttempt = 0;
    _pendingRetry = null;
    retryDelays = const [Duration(seconds: 5), Duration(seconds: 30), Duration(minutes: 2)];
    postRetryPause = const Duration(seconds: 2);
    nativeAlertGrace = const Duration(seconds: 4);
    nativeAlertPoll = const Duration(milliseconds: 250);
    getFcmToken = () => FirebaseMessaging.instance.getToken();
    deleteFcmToken = () => FirebaseMessaging.instance.deleteToken();
  }

  @visibleForTesting
  static Future<void> debugOnTokenRefresh(String token) => _onTokenRefresh(token);
  @visibleForTesting
  static bool get debugTokenRegistered => _tokenRegistered;
  @visibleForTesting
  static bool get debugRetryScheduled => _retryTimer != null;

  // ~10 s in total. On a real device the APNs token normally lands within a
  // second or two of launch; on an iOS Simulator (or a build without the
  // Push entitlement) it never does, and that has to end in a clear message
  // rather than an endless wait.
  static const _apnsPollAttempts = 20;
  static const _apnsPollInterval = Duration(milliseconds: 500);

  /// Whether Firebase was configured successfully at launch — lets callers
  /// tell "no Firebase project here" apart from "permission denied".
  static bool get isReady => _initialized;

  /// Why the server can't push to this phone, when it has said so at
  /// registration (null = fine, or not registered yet). Shown by the
  /// Settings "Send a test notification" check.
  static String? get serverProblem => _serverProblem;

  /// Where this phone's push registration stands right now — what the Settings
  /// status line shows under the Push switch, so "Active" is not claimed for a
  /// phone whose token never reached the server or that the server cannot send
  /// to. Read-only, computed from the registration state above; it cannot see
  /// silent failures on the server's side (a token FCM has since dropped, an
  /// APNs key problem) — only "Send a test notification" round-trips those.
  static PushRegistration get registrationState {
    if (!_initialized) return PushRegistration.notSetUp;
    if (_tokenRegistered) {
      return _serverCanSend ? PushRegistration.registered : PushRegistration.cannotDeliver;
    }
    if (_registration != null || _retryTimer != null) return PushRegistration.registering;
    return PushRegistration.notRegistered;
  }

  /// iOS, app open: whether iOS drew the alert push for [notificationId] by
  /// itself. The plugin tells Dart about a push that arrives while the app is
  /// open ([_handleForegroundMessage] records it in the ledger); the socket
  /// path calls this before drawing a banner of its own and waits up to
  /// [nativeAlertGrace] for that record. This replaces "iOS has a token, so
  /// assume the OS will draw it": a phone whose APNs setup is broken still
  /// registers a token, and assuming would leave it with no banner at all.
  /// Only call it when a native alert is expected
  /// (NotificationPrefs.readFcmPushReady) — otherwise there is nothing to
  /// wait for.
  static Future<bool> awaitNativeAlert(String? notificationId) async {
    if (notificationId == null || notificationId.isEmpty) return false;
    final deadline = DateTime.now().add(nativeAlertGrace);
    while (true) {
      if (await NotificationPrefs.bannerClaimed(notificationId)) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(nativeAlertPoll);
    }
  }

  /// Called once from main.dart, right alongside NotificationBootstrap
  /// .init() and BEFORE [consumeLaunchPayload] — registers the
  /// foreground/opened-app/background listeners. Token REGISTRATION with
  /// the server happens separately, per-login (see [registerToken]), not
  /// here.
  ///
  /// main.dart only waits a few seconds for this; the run itself carries on
  /// and is shared, so a second call joins it instead of registering every
  /// listener twice, and [consumeLaunchPayload] can wait for it.
  static Future<void> init() async {
    if (_initialized) return;
    await (_initRun ??= initCore().whenComplete(() => _initRun = null));
    if (!_initialized) return;
    // Separate from the core above so a failure here can't take the whole
    // push setup down with it. iOS shows nothing for a push that arrives
    // while the app is open unless told to (persisted natively, no-op on
    // Android); without it an FCM alert push would only ever appear with
    // the app backgrounded.
    //
    // Deliberately NOT turned off to let the app draw the foreground banner
    // itself: firebase_messaging answers iOS's willPresent for EVERY
    // notification with these options, its own and flutter_local_notifications'
    // alike, and it is registered first, so the AppDelegate's first-reply-wins
    // handler would most likely take "no alert" for the local banners too and
    // every foreground banner (socket fallback, polls) would vanish. Telling a
    // remote push from a local one needs a change in AppDelegate.swift (to be
    // tried on a real iPhone); until then the OS draws the push and the socket
    // path only fills in when it demonstrably didn't ([awaitNativeAlert]).
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

  // Never throws: a Firebase project that isn't set up leaves [_initialized]
  // false and the app without push.
  static Future<void> _initCore() async {
    try {
      await Firebase.initializeApp();
      await _onMessageSubscription?.cancel();
      await _onOpenedSubscription?.cancel();
      _onMessageSubscription = FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      _onOpenedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedAppMessage);
      // Must be a top-level function reference, not a closure/method —
      // the plugin passes it to a background isolate by reference, which
      // can't capture instance/closure state. See its own doc comment, and
      // why it is THIS one and not [fcmBackgroundMessageHandler].
      FirebaseMessaging.onBackgroundMessage(backgroundHandler);
      _tokenRefreshSubscription ??= FirebaseMessaging.instance.onTokenRefresh.listen(_onTokenRefresh);
      _initialized = true;
      debugPrint('FcmService.init succeeded — Firebase configured, listeners registered.');
    } catch (e, st) {
      debugPrint('FcmService.init failed (Firebase not set up yet?), continuing without push: $e\n$st');
    }
  }

  /// Set once, before runApp, if the app process was NOT already running
  /// and got launched by tapping an FCM push (cold start) — same
  /// "consume later, once the app shell can actually navigate" contract
  /// as LocalNotifications.consumeLaunchPayload, and folded into the SAME
  /// `_pendingLaunchPayload` variable in main.dart (only one of the two
  /// cold-start sources can be true for a given launch), so _RootGate's
  /// existing one-shot consumption logic needs no changes for this.
  ///
  /// Waits for an [init] that main.dart stopped waiting for but that is still
  /// running: the tap that launched the app is recorded only in FCM's
  /// getInitialMessage (an iOS push is drawn by the OS and leaves no other
  /// trace), so "not initialized yet" must not be read as "no tap".
  static Future<String?> consumeLaunchPayload() async {
    final running = _initRun;
    if (!_initialized && running != null) await running;
    if (!_initialized) return null;
    try {
      return _payloadFor(await getInitialMessage());
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

  // A push arriving while the app is in the foreground.
  // - Android: the data-only message (see the class doc comment), where the
  //   OS would otherwise show nothing at all. Rendered through the same
  //   display layer + payload scheme as a live socket notification, so a push
  //   and the in-app socket event for the same thing draw ONE banner (the
  //   ledger) and route identically on tap.
  // - iOS: an alert push. iOS presents it itself while the app is open (the
  //   presentation options set in [init]) — drawing it here as well would
  //   show two banners for one push. It is only RECORDED, so the socket path
  //   can tell the OS drew it ([awaitNativeAlert]).
  static Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint('FcmService: foreground message received (${_describe(message)})');
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS && message.notification != null) {
        final data = message.data;
        await NotificationPrefs.claimBanner(
          notificationId: data['notificationId'] as String?,
          type: data['type'] as String? ?? 'general',
          referenceId: data['referenceId'] as String?,
        );
        return;
      }
      await renderDataPush(message);
    } catch (e, st) {
      debugPrint('FcmService: could not handle a foreground push: $e\n$st');
    }
  }

  @visibleForTesting
  static Future<void> debugHandleForegroundMessage(RemoteMessage message) => _handleForegroundMessage(message);

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

  /// A new sign-in begins (NotificationScheduler.onLoggedIn): registering
  /// this phone is allowed again after the sign-out that stopped it.
  static void onSessionStarted() {
    _signedOut = false;
    _retryAttempt = 0;
  }

  /// Fetches this device's FCM token and registers it with the server
  /// (POST /device-tokens/register) — called from
  /// NotificationScheduler.onLoggedIn, the same place the local poll's
  /// own session gets armed. FCM's own token-refresh event (a token can
  /// rotate at any time, not just on login) is handled by the single
  /// listener [init] attaches. A failure (no token yet, the POST not
  /// getting through) schedules a foreground retry with backoff; the
  /// resume / socket-reconnect nudges ([ensureRegistered]) cover the rest.
  static Future<void> registerToken() {
    if (!_initialized || _signedOut) return Future.value();
    return _registration ??= _register().whenComplete(() => _registration = null);
  }

  static Future<void> _register() async {
    final session = _session;
    var retry = false;
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
          '(token refresh), otherwise on the next retry, resume or login.',
        );
        retry = true;
        return;
      }
      final token = await getFcmToken();
      // Signed out while FCM was being asked: nothing may register now.
      if (session != _session) return;
      if (token == null) {
        debugPrint('FcmService.registerToken: Firebase returned no FCM token.');
        retry = true;
        return;
      }
      if (kDebugMode) {
        debugPrint('FcmService: FCM token (paste it into Firebase console > Messaging > Send test message): $token');
      }
      retry = await _postToken(token, session) == _Post.retry;
    } catch (e, st) {
      debugPrint('FcmService.registerToken failed: $e\n$st');
      retry = true;
    } finally {
      if (retry && session == _session && !_signedOut) _scheduleRetry();
    }
  }

  // Foreground-only backoff: 5 s, 30 s, 2 min. Every outside nudge
  // ([ensureRegistered]) restarts the count.
  static void _scheduleRetry() {
    if (_retryAttempt >= retryDelays.length) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelays[_retryAttempt++], () {
      _retryTimer = null;
      unawaited(_ensureRegistered());
    });
  }

  /// Registers this phone if it isn't yet — for the moments the login-time
  /// attempt can't cover: it failed (a flaky connection right at launch), or
  /// notifications were allowed in the system settings afterwards. Called
  /// when the app comes back to the foreground and when the socket
  /// reconnects (the network is back). Never prompts: on iOS it only reads
  /// the standing permission.
  static Future<void> ensureRegistered() {
    _retryAttempt = 0;
    return _ensureRegistered();
  }

  static Future<void> _ensureRegistered() async {
    if (!_initialized || _signedOut || _tokenRegistered || _registration != null) return;
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
    if (_signedOut || await NotificationPrefs.readToken() == null) return;
    final session = _session;
    // The server holds the OLD token until this POST lands — not "registered",
    // and not something the polls may count on either.
    _tokenRegistered = false;
    await _setPushReady(false);
    if (await _postToken(token, session) == _Post.retry && session == _session && !_signedOut) {
      _scheduleRetry();
    }
  }

  // The persisted "the server can push to this phone" mirror. A storage
  // failure must never turn a registration that WORKED into a retry loop.
  static Future<void> _setPushReady(bool value) async {
    try {
      await NotificationPrefs.setFcmPushReady(value);
    } catch (e) {
      debugPrint('FcmService: could not persist the push-ready state: $e');
    }
  }

  // One retry in place — the registration is the only thing standing between
  // this device and every push, and it usually fires right at login/launch
  // when the connection can still be waking up. Anything longer is the
  // caller's backoff ([_scheduleRetry]), so login isn't held up by it.
  static Future<_Post> _postToken(String token, int session) async {
    const attempts = 2;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      // Signed out since this started: registering now would bind the phone
      // to the account that just left.
      if (session != _session) return _Post.rejected;
      try {
        final res = await DioClient.instance.dio.post(
          ApiConstants.deviceTokenRegister,
          data: {
            'token': token,
            'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
            'firebaseProjectId': _firebaseProjectId(),
          },
        );
        // The server holds it now, whichever session asked — remembered so a
        // sign-out that overtook this request still knows what to delete.
        _registeredToken = token;
        if (session != _session) return _Post.rejected;
        _tokenRegistered = true;
        _retryAttempt = 0;
        _retryTimer?.cancel();
        _retryTimer = null;
        // An older server doesn't say; only an explicit `false` is a problem.
        final body = res.data;
        _serverCanSend = !(body is Map && body['pushReady'] == false);
        _serverProblem = _serverCanSend ? null : (body as Map)['problem']?.toString();
        if (!_serverCanSend) debugPrint('FcmService: server cannot push to this phone: $_serverProblem');
        // Persisted for the polls (which run in another isolate) and the iOS
        // socket path: they stand down for what the server now pushes — or
        // stay the fallback when it says it can't.
        await _setPushReady(_serverCanSend);
        // A logout done offline left a "delete this token" note; this token
        // now belongs to the account that just signed in, so it must not fire.
        unawaited(_forgetPendingUnregister(token));
        return _Post.registered;
      } catch (e, st) {
        debugPrint('FcmService._postToken failed (attempt $attempt/$attempts): $e\n$st');
        if (e is DioException && _isPermanentRejection(e.response?.statusCode)) return _Post.rejected;
        if (attempt < attempts) await Future<void>.delayed(postRetryPause);
      }
    }
    return _Post.retry;
  }

  /// Un-registers this device's current token — called from
  /// NotificationScheduler.onLoggedOut so a signed-out device stops
  /// receiving pushes meant for the account that was just signed out of
  /// (mirrors the web app's own unsubscribe-on-logout for browser push).
  ///
  /// [jwt] is the session token the caller still HOLDS: on every path that
  /// ends signed out (button, expired session, blocked account) the stored
  /// one is already gone or no longer valid, and the DELETE has to carry
  /// something — the server accepts an expired, validly signed token for
  /// exactly this route. When the server can't be reached the request is
  /// kept and retried ([retryPendingUnregister]); when it can't be
  /// confirmed at all, FCM itself is asked to drop the token so the
  /// server's next send prunes it. Never throws; runs once per sign-out.
  static Future<void> unregisterToken({String? jwt}) async {
    if (!_initialized || _signedOut) return;
    // Synchronously, before any await: from here on nothing may register
    // this phone again while the sign-out is still working.
    _signedOut = true;
    _session++;
    _retryTimer?.cancel();
    _retryTimer = null;
    _tokenRegistered = false;
    _serverCanSend = true;
    _serverProblem = null;
    unawaited(_setPushReady(false));

    // A registration already on the wire finishes first, so its row exists
    // to be deleted instead of appearing after the DELETE.
    final inFlight = _registration;
    if (inFlight != null) {
      try {
        await inFlight.timeout(_settleTimeout);
      } catch (_) {}
    }
    var token = _registeredToken;
    _registeredToken = null;
    try {
      token ??= await getFcmToken().timeout(_settleTimeout);
    } catch (e) {
      debugPrint('FcmService.unregisterToken: could not read the FCM token: $e');
    }
    var auth = jwt;
    if (auth == null || auth.isEmpty) {
      try {
        auth = await NotificationPrefs.readToken();
      } catch (_) {}
    }

    var outcome = _Unregistered.skipped;
    if (token != null && auth != null && auth.isNotEmpty) {
      outcome = await _deleteOnServer(token, auth);
      if (outcome == _Unregistered.unreachable) await _rememberPendingUnregister(token, auth);
    }
    // Only when the server row could not be confirmed gone: the row is what
    // pushes go to, and a token FCM no longer knows is pruned by the server
    // on its next send. (After a confirmed delete nothing is sent to this
    // phone, and the next sign-in keeps its existing token.) Skipped if a
    // new sign-in already began — it must keep the token it just registered.
    if (outcome != _Unregistered.removed && _signedOut) {
      try {
        await deleteFcmToken().timeout(_deleteTokenTimeout);
      } catch (e) {
        debugPrint('FcmService.unregisterToken: could not delete the FCM token: $e');
      }
    }
  }

  static Future<_Unregistered> _deleteOnServer(String token, String jwt) async {
    try {
      await DioClient.instance.dio
          .delete(
            ApiConstants.deviceTokenRegister,
            data: {'token': token},
            options: DioClient.explicitBearer(jwt),
          )
          .timeout(_unregisterTimeout);
      return _Unregistered.removed;
    } catch (e) {
      debugPrint('FcmService: could not unregister the token from the server: $e');
      if (e is DioException && _isPermanentRejection(e.response?.statusCode)) {
        return _Unregistered.rejected;
      }
      return _Unregistered.unreachable;
    }
  }

  // ── Sign-out that couldn't reach the server ─────────────────────────────
  // {token, jwt, at} of a DELETE that never got through. The JWT rides along
  // because it is the only proof the server accepts (see [unregisterToken]).
  // It is a live credential for up to a week, so it is kept in secure storage
  // — not in SharedPreferences, which is plain text on disk — until the DELETE
  // lands, the token is registered again, or the week passes. Only the
  // foreground app ever reads it (the launch and the login screen's resume).
  static const _pendingUnregisterMaxAge = Duration(days: 7);

  static Future<void> _rememberPendingUnregister(String token, String jwt) async {
    try {
      await SecureStorage.instance.savePendingUnregister(
        jsonEncode({'token': token, 'jwt': jwt, 'at': DateTime.now().millisecondsSinceEpoch}),
      );
    } catch (e) {
      debugPrint('FcmService: could not remember the pending unregister: $e');
    }
  }

  static Future<void> _forgetPendingUnregister([String? onlyToken]) async {
    try {
      final raw = await SecureStorage.instance.readPendingUnregister();
      if (raw == null) return;
      if (onlyToken != null && _decodePending(raw)?.token != onlyToken) return;
      await SecureStorage.instance.clearPendingUnregister();
    } catch (_) {}
  }

  static ({String token, String jwt, int at})? _decodePending(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is Map && m['token'] is String && m['jwt'] is String && m['at'] is int) {
        return (token: m['token'] as String, jwt: m['jwt'] as String, at: m['at'] as int);
      }
    } catch (_) {}
    return null;
  }

  /// Sends the DELETE a sign-out couldn't (offline at the time). Called while
  /// no one is signed in — at launch and on resume of the login screen. A
  /// rejected request is dropped, not retried: asking again won't change it.
  static Future<void> retryPendingUnregister() =>
      _pendingRetry ??= _retryPending().whenComplete(() => _pendingRetry = null);

  static Future<void> _retryPending() async {
    try {
      final raw = await SecureStorage.instance.readPendingUnregister();
      if (raw == null) return;
      final pending = _decodePending(raw);
      final age = pending == null
          ? null
          : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(pending.at));
      if (pending == null || age! > _pendingUnregisterMaxAge) {
        await _forgetPendingUnregister();
        return;
      }
      final outcome = await _deleteOnServer(pending.token, pending.jwt);
      if (outcome == _Unregistered.unreachable) return;
      await _forgetPendingUnregister(pending.token);
      // A sign-in that began while the request was on the wire may have just
      // registered this very token for the same account, which that DELETE
      // then removed — register it again.
      if (outcome == _Unregistered.removed && !_signedOut && _registeredToken == pending.token) {
        _tokenRegistered = false;
        _registeredToken = null;
        unawaited(ensureRegistered());
      }
    } catch (e) {
      debugPrint('FcmService.retryPendingUnregister failed: $e');
    }
  }

  // What the test push proved about THIS phone: a send Firebase accepted clears
  // any earlier failure, a send that failed is remembered (see
  // NotificationPrefs.setFcmDeliveryFailed) so the fallback layers stay on for
  // a phone the server registered but cannot reach — and the Settings status
  // line stops saying "Active". No result for this phone says nothing about
  // delivery ([pushTestDelivered] has the rules).
  static Future<void> _rememberTestDelivery(Map<String, dynamic> body, String platform) async {
    try {
      final delivered = pushTestDelivered(body, platform: platform, thisPhoneOnly: true);
      if (delivered == null) return;
      await NotificationPrefs.setFcmDeliveryFailed(!delivered);
    } catch (e) {
      debugPrint('FcmService: could not remember the test push outcome: $e');
    }
  }

  /// Settings > "Send a test notification". Re-registers this phone, then asks
  /// the server to push a real test to THIS phone and explains the outcome (see
  /// [describePushTestResponse]). The request carries the phone's own FCM
  /// token, so the account's other phones (a second Android device, a stale
  /// token of an earlier install) cannot answer for it. When this phone has no
  /// push token, could not register it, or the server said it cannot push to
  /// it, that is what the person is told and nothing is sent. Also reports what
  /// the phone itself knows — permission, Apple push token, Firebase project —
  /// because "nothing arrived" has a different fix for each.
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

    // Refresh the server's copy of this phone's token first, so the test goes
    // to what the phone holds NOW (and the server can report a project it
    // has no credentials for). A registration already in flight (the login-time
    // attempt) is joined rather than raced, so it is not mistaken for a failure
    // below.
    await registerToken();

    // Read after registering: on iOS the Apple push token may only have
    // arrived while that waited.
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

    if (!_serverCanSend) {
      return PushCheck(
        ok: false,
        title: "The server can't push to this phone",
        lines: [
          _serverProblem ?? "The server said it can't send push notifications to this phone.",
          ...local,
        ],
      );
    }

    // Aimed at the token the phone holds NOW, and only if the server has
    // accepted exactly that one — a registration that failed, or a token that
    // rotated without its POST landing, would otherwise let a test "pass"
    // through some other row while nothing can reach this phone.
    String? token;
    Object? tokenError;
    try {
      token = await getFcmToken().timeout(_settleTimeout);
    } catch (e) {
      tokenError = e;
    }
    if (token == null || token.isEmpty) {
      return PushCheck(
        ok: false,
        title: 'This phone has no push token',
        lines: [
          'Firebase has not given this phone a push token, so there is nothing '
              'the server could send to. Check the connection and that '
              'notifications are allowed for this app, then try again in a minute.',
          ...local,
          'Push token: not available${tokenError == null ? '' : ' (${_briefError(tokenError)})'}',
        ],
      );
    }
    if (!(_tokenRegistered && _registeredToken == token)) {
      return PushCheck(
        ok: false,
        title: "This phone couldn't register for push",
        lines: [
          "The app couldn't tell the server about this phone (no connection, or "
              'the server refused), so there is no registration to send a test to. '
              'It keeps retrying by itself: try again in a minute, and if it keeps '
              'failing, sign out and back in.',
          ...local,
        ],
      );
    }

    try {
      final res = await DioClient.instance.dio.post(
        ApiConstants.deviceTokenTest,
        data: {'token': token},
      );
      final body = res.data is Map
          ? Map<String, dynamic>.from(res.data as Map)
          : <String, dynamic>{};
      await _rememberTestDelivery(body, platform);
      return describePushTestResponse(body, platform: platform, thisPhoneOnly: true, localLines: local);
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

  // A short reason for the check's own lines: a Firebase error code, not a
  // stack of platform-exception text.
  static String _briefError(Object e) {
    if (e is FirebaseException) return e.code;
    if (e is TimeoutException) return 'timed out';
    final text = '$e';
    return text.length > 120 ? '${text.substring(0, 120)}...' : text;
  }
}
