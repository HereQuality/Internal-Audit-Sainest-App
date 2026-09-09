import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../constants/api_constants.dart';
import '../network/dio_client.dart';
import 'local_notifications.dart';
import 'notification_navigation.dart';

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
// also what makes a data-only push (fcmPush.service.js sends no
// `notification` block) get processed AT ALL while backgrounded —
// without an onBackgroundMessage handler registered, Android has nothing
// to hand a data-only message to and just drops it silently.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('FcmService: background message received: ${message.data}');
  await Firebase.initializeApp();
  await LocalNotifications.init();
  final data = message.data;
  final referenceId = data['referenceId'] as String?;
  await LocalNotifications.showLive(
    id: (referenceId ?? message.messageId ?? '').hashCode & 0x7fffffff,
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
  static Future<String?> consumeLaunchPayload() async {
    if (!_initialized) return null;
    try {
      return _payloadFor(await FirebaseMessaging.instance.getInitialMessage());
    } catch (_) {
      return null;
    }
  }

  // data-only message (fcmPush.service.js sends no `notification` block,
  // only `data`) — arriving while the app is in the foreground, where the
  // OS would otherwise show nothing at all for a pure data message.
  // Rendered through the exact same display layer + payload scheme as a
  // live socket notification (notifications_provider.dart's own
  // showLive), so a push and the in-app socket event for the same thing
  // read identically and route identically on tap.
  static void _handleForegroundMessage(RemoteMessage message) {
    debugPrint('FcmService: foreground message received: ${message.data}');
    final data = message.data;
    final payload = _payloadFor(message);
    LocalNotifications.showLive(
      id: (data['referenceId'] as String? ?? message.messageId ?? '').hashCode & 0x7fffffff,
      title: data['title'] as String? ?? 'Notification',
      body: data['body'] as String? ?? '',
      payload: payload,
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
  /// own session gets armed. Also listens for FCM's own token-refresh
  /// event (a token can rotate at any time, not just on login) and
  /// re-registers automatically for as long as the app process is alive.
  static Future<void> registerToken() async {
    if (!_initialized) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _postToken(token);
      FirebaseMessaging.instance.onTokenRefresh.listen(_postToken);
    } catch (e, st) {
      debugPrint('FcmService.registerToken failed: $e\n$st');
    }
  }

  static Future<void> _postToken(String token) async {
    try {
      await DioClient.instance.dio.post(
        ApiConstants.deviceTokenRegister,
        data: {
          'token': token,
          'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        },
      );
    } catch (e, st) {
      debugPrint('FcmService._postToken failed: $e\n$st');
    }
  }

  /// Un-registers this device's current token — called from
  /// NotificationScheduler.onLoggedOut so a signed-out device stops
  /// receiving pushes meant for the account that was just signed out of
  /// (mirrors the web app's own unsubscribe-on-logout for browser push).
  static Future<void> unregisterToken() async {
    if (!_initialized) return;
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
}
