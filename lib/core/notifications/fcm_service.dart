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
class FcmService {
  FcmService._();

  static bool _initialized = false;

  /// Called once from main.dart, right alongside NotificationBootstrap
  /// .init() and BEFORE [consumeLaunchPayload] — registers the
  /// foreground/opened-app listeners. Token REGISTRATION with the server
  /// happens separately, per-login (see [registerToken]), not here.
  static Future<void> init() async {
    if (_initialized) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_handleOpenedAppMessage);
      _initialized = true;
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
