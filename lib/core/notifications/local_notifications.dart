import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'notification_navigation.dart';

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

  /// Safe to call from the foreground app AND from a background isolate
  /// (AndroidAlarmManager callback / background_service isolate) — each
  /// isolate has its own plugin registration, so this must run once per
  /// isolate, not once per process.
  static Future<void> init() async {
    if (_initialized) return;

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

    if (Platform.isAndroid) {
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

    _initialized = true;
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
  /// below (see event_poll.dart) — all routine "App Updates" channel
  /// heads-ups, only the id/title/body/payload differ per call site.
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
  }) async {
    await init();
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
  /// — title/body come straight from the server's own notification doc, so
  /// this covers every notification type (NC lifecycle, audit
  /// reassignment, future ones) without a type-keyed switch here.
  static Future<void> showLive({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) => _showAppEvent(id: id, title: title, body: body, payload: payload ?? '');

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
