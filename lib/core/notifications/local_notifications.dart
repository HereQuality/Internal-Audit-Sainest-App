import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notification_navigation.dart';
import 'notification_prefs.dart';

/// One shared plugin instance, plain top-level accessible (no DI) — both
/// the foreground app and any background isolate that calls
/// `LocalNotifications.init()` first can show/cancel notifications through
/// this the same way.
final FlutterLocalNotificationsPlugin _plugin =
    FlutterLocalNotificationsPlugin();

class LocalNotifications {
  LocalNotifications._();

  static const overdueChannelId = 'nc_overdue';
  static const overdueChannelName = 'Overdue NCs';
  static const overdueChannelDescription =
      'Alerts when a Non-Conformance raised against you passes its target date without being closed.';

  // One shared channel for every other event-poll notification type (see
  // event_poll.dart) — audit assignment/date reminders and NC
  // raised/approved/rejected. These are routine status updates, not
  // urgent-overdue alerts, so they get their own (still "high" importance
  // so they still heads-up, but a separate Android channel) rather than
  // reusing overdueChannelId — keeps the per-channel Settings toggle
  // Android exposes meaningful (a user who mutes "App Updates" still gets
  // Overdue NC alerts, and vice versa).
  static const appEventsChannelId = 'app_events';
  static const appEventsChannelName = 'App Updates';
  static const appEventsChannelDescription =
      'Audit assignments, audit date reminders, and NC status changes.';

  static bool _initialized = false;
  static Future<void>? _pluginReady;

  @visibleForTesting
  static void debugReset() {
    _initialized = false;
    _pluginReady = null;
  }

  /// Checked once at cold start (main.dart, right after init() above) —
  /// if the app process was NOT already running and got launched BY
  /// tapping a notification (as opposed to tapping the app icon
  /// normally), this is that notification's own payload, to route to
  /// once the app's actually ready (there's no authenticated app shell —
  /// or navigator content worth pushing on top of — mounted yet at this
  /// exact point in startup; main.dart defers the actual navigation until
  /// then). Returns null on an ordinary (non-notification) launch.
  static Future<String?> consumeLaunchPayload() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return details?.notificationResponse?.payload;
  }

  /// Everything [init] does, plus the timezone database. Safe to call from
  /// the foreground app AND from a background isolate (the foreground-service
  /// isolate) — each isolate has its own plugin registration, so this must
  /// run once per isolate, not once per process.
  static Future<void> init() async {
    if (_initialized) return;
    await initLight();

    tz_data.initializeTimeZones();
    // Device-local zone, read from the OS (not guessed from DateTime, which
    // only gives an abbreviation) — every scheduled/targetDate comparison
    // downstream (overdue_poll.dart) works in UTC instants regardless, but
    // this matters the moment anything calls zonedSchedule for a specific
    // wall-clock reminder time instead of "show now".
    try {
      final localTz = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(localTz.identifier));
    } catch (_) {
      // Unknown/unmapped tz id on this device — fall back to UTC rather than crash.
    }

    _initialized = true;
  }

  /// The plugin and the Android channels, nothing else — what drawing a
  /// banner actually needs. Parsing the whole timezone database and asking
  /// the OS for the local zone (the rest of [init]) is time the FCM
  /// background isolate cannot spare: it is a cold isolate that exists to
  /// put one banner on screen, and every millisecond here is latency on a
  /// push. The two high-importance channels are (re)created here as well —
  /// the app's own start-up [init] already made them before anyone could be
  /// signed in to receive a push, and the plugin would also create one on
  /// first post, so this only pins down that a heads-up channel exists
  /// before the first banner rather than depending on either. Idempotent
  /// (an existing channel keeps what the user set on it); concurrent callers
  /// share one run.
  static Future<void> initLight() async {
    final pending = _pluginReady ??= _initPlugin();
    try {
      await pending;
    } catch (_) {
      _pluginReady = null; // let the next call try again
      rethrow;
    }
  }

  static Future<void> _initPlugin() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission:
          false, // requested explicitly via permission_handler instead — see notification_bootstrap.dart
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      // Fires when the app process is already alive (foreground, or
      // backgrounded-but-not-killed) and the user taps a notification —
      // see notification_navigation.dart for what "payload" actually
      // decodes to and where each type routes. The cold-start case (app
      // was NOT running) can't go through here — there's nothing to
      // navigate into yet — see consumeLaunchPayload below instead.
      onDidReceiveNotificationResponse: (response) =>
          handleLocalNotificationTap(response.payload),
    );

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          overdueChannelId,
          overdueChannelName,
          description: overdueChannelDescription,
          importance: Importance.high,
        ),
      );
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          appEventsChannelId,
          appEventsChannelName,
          description: appEventsChannelDescription,
          importance: Importance.high,
        ),
      );
    }
  }

  /// A normal heads-up notification for one overdue NC. `payload` is an
  /// encodeNotificationPayload(type: ..., referenceId: ...) string (see
  /// notification_navigation.dart), read back by
  /// onDidReceiveNotificationResponse above to deep-link straight to that
  /// NC on tap.
  static Future<void> showOverdueNc({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    await init();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          overdueChannelId,
          overdueChannelName,
          channelDescription: overdueChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload,
    );
  }

  /// Shared implementation behind the five event-poll notification types
  /// below (see event_poll.dart) and the live/server banners — all routine
  /// "App Updates" channel heads-ups, only the id/title/body/payload differ
  /// per call site. Only the light init: this is also the FCM background
  /// isolate's path, where time to the banner is the whole point.
  ///
  /// [alertOnce]: posting again under an id that is still in the tray UPDATES
  /// that entry, but Android treats the update as a fresh alert (sound,
  /// vibration, heads-up) unless it is marked only-alert-once. Set for the
  /// banners that can legitimately be posted twice under one id — the socket
  /// and FCM both announcing one server notification — and left off for the
  /// poll banners, whose ids are reused on purpose (an NC rejected a second
  /// time) and must alert again.
  ///
  /// BigTextStyleInformation (Android only — iOS's presentAlert already
  /// shows the full body with no style needed): without it, Android
  /// collapses a multi-line body — e.g. showLive() forwarding the server's
  /// morning/evening summary, which is several "- " bullet lines — down to
  /// one truncated line in the notification shade, so most of the digest
  /// was invisible until the user opened the app itself. BigTextStyle is
  /// what lets it expand to show every line, same as any other
  /// multi-line Android notification (Gmail, etc).
  static Future<void> _showAppEvent({
    required int id,
    required String title,
    required String body,
    required String payload,
    bool alertOnce = false,
  }) async {
    await initLight();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          appEventsChannelId,
          appEventsChannelName,
          channelDescription: appEventsChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.status,
          onlyAlertOnce: alertOnce,
          styleInformation: BigTextStyleInformation(body, contentTitle: title),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload,
    );
  }

  /// A new audit was scheduled with the current user as an auditor.
  static Future<void> showAuditAssigned({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload);

  /// An assigned audit's scheduledDate or scheduledEndDate has arrived.
  static Future<void> showAuditDateReminder({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload);

  /// A new NC was raised against the current user (auditee side).
  static Future<void> showNewNc({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload);

  /// The current user's NC response was accepted (NC closed).
  static Future<void> showNcApproved({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload);

  /// The current user's NC response was rejected (reopened, back to Raised).
  static Future<void> showNcRejected({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload);

  /// Any live event delivered over the socket's `new_notification` channel
  /// or an FCM data push — title/body come straight from the server's own
  /// notification doc, so this covers every notification type (NC
  /// lifecycle, audit reassignment, future ones) without a type-keyed switch
  /// here. Both routes derive [id] from the same Mongo id, so a repeat lands
  /// on the same tray entry — silently ([_showAppEvent]'s `alertOnce`).
  /// Callers that can race each other go through [showServerBanner].
  static Future<void> showLive({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload ?? '', alertOnce: true);

  /// Local-notification id for one server notification. FCM's data
  /// `notificationId` and the socket `new_notification` payload's `_id` are
  /// the same Mongo id, and every display route derives its id from it HERE,
  /// so two banners for one event land on the same tray entry. [fallback] is
  /// only for a server that doesn't send `notificationId`.
  static int serverNotificationId({String? notificationId, String? fallback}) {
    final key = (notificationId != null && notificationId.isNotEmpty)
        ? notificationId
        : (fallback ?? '');
    return key.hashCode & 0x7fffffff;
  }

  /// The one way a notification that came FROM THE SERVER (a socket event, an
  /// FCM data push in either isolate) becomes a banner: claimed in the
  /// shared ledger first (NotificationPrefs.claimBanner), so whichever route
  /// sees it first draws it and every other stays quiet — and a poll that
  /// later derives the same event from a list knows it was already
  /// announced. Returns whether THIS call drew it. If drawing fails the claim
  /// is given back, so another route can still try, and the error rethrown.
  static Future<bool> showServerBanner({
    required String? notificationId,
    required String type,
    required String? referenceId,
    required String title,
    required String body,
    String? fallbackKey,
  }) async {
    final kind = type.isEmpty ? 'general' : type;
    final claimed = await NotificationPrefs.claimBanner(
      notificationId: notificationId,
      type: kind,
      referenceId: referenceId,
    );
    if (!claimed) return false;
    try {
      await showLive(
        // Without a notification id (a server that predates it) the tray id
        // comes from the reference, then from [fallbackKey] (FCM's message id).
        id: serverNotificationId(
          notificationId: notificationId,
          fallback: (referenceId != null && referenceId.isNotEmpty) ? referenceId : fallbackKey,
        ),
        title: title,
        body: body,
        payload: encodeNotificationPayload(
          type: kind,
          referenceId: (referenceId == null || referenceId.isEmpty) ? null : referenceId,
        ),
      );
      return true;
    } catch (_) {
      await NotificationPrefs.releaseBanner(
        notificationId: notificationId,
        type: kind,
        referenceId: referenceId,
      );
      rethrow;
    }
  }

  /// Lock-screen, alarm-style presentation — bypasses Do Not Disturb-ish
  /// heads-up and actually launches your Activity over the lock screen.
  /// See NOTIFICATIONS.md for the Android 14+ permission story before
  /// wiring this up to a real call site; left here, unused by the overdue
  /// poll, as the documented "how" for when you need it (e.g. a hard
  /// deadline reminder rather than a routine overdue nudge).
  static Future<void> showFullScreenAlarm({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    await init();
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          overdueChannelId,
          overdueChannelName,
          channelDescription: overdueChannelDescription,
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.alarm,
          visibility: NotificationVisibility.public,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
          interruptionLevel: InterruptionLevel.timeSensitive,
        ),
      ),
      payload: payload,
    );
  }

  static Future<void> cancelAll() => _plugin.cancelAll();
}
