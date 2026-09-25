import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:permission_handler/permission_handler.dart';

import 'background_entrypoints.dart';
import 'event_poll.dart';
import 'fcm_service.dart';
import 'notification_bootstrap.dart';
import 'notification_prefs.dart';
import 'overdue_poll.dart';

/// The one seam between AuthProvider (foreground, Provider-based) and the
/// plain-function background pipeline — called from AuthProvider on
/// login/bootstrap-while-authenticated and on logout. Everything it calls
/// into is a plain top-level function itself, so nothing here depends on
/// being inside a widget tree.
class NotificationScheduler {
  NotificationScheduler._();

  /// Mirrors the session into SharedPreferences (the only storage a
  /// background isolate can reach — see notification_prefs.dart) and arms
  /// both AlarmManager chains + the foreground service. Also fires one
  /// immediate poll so a fresh login doesn't wait kPollInterval before the
  /// user sees anything already-overdue.
  static Future<void> onLoggedIn({required String token, required String userId}) async {
    await NotificationPrefs.setSession(token: token, userId: userId);
    // Called unawaited from AuthProvider right after login/bootstrap — this
    // must never throw back into that call site (e.g. because
    // NotificationBootstrap.init() failed or was skipped on this device).
    // Reminders are a nice-to-have; login itself must not be affected.
    try {
      // Requested once here, shared by both paths below — same as the
      // Settings screen's own push-switch-on path, so a fresh login doesn't
      // start anything before the user has ever been asked. A denial just
      // means no alerts on this phone; the account's push switch stays
      // as it is so re-granting later (Settings, or the OS Settings screen
      // after a permanent denial) picks everything back up with no
      // rediscovery needed.
      final granted = await _requestPermissions();
      // The token is registered whenever OS permission is granted,
      // regardless of the account's push switch: the server is what
      // honours that switch (createNotification skips push entirely while
      // it's off), so a token that's already on file is exactly what lets
      // switching push ON from the web start reaching this phone
      // immediately. A real server push also needs no persistent
      // foreground service to arrive.
      if (granted) await FcmService.registerToken();
      // The local poll is the Android fallback net behind FCM and obeys the
      // same switches as everything else — AuthProvider mirrors the
      // account's master value (NotificationPrefs.readPushEnabled, on by
      // default) and its per-topic values just before calling this; the
      // polls themselves then check each topic before showing anything.
      if (granted && await NotificationPrefs.readPushEnabled()) {
        await startBackgroundPolling();
        await pollAndNotifyOverdueNcs();
        await pollAndNotifyEvents();
      }
    } catch (e, st) {
      debugPrint('NotificationScheduler.onLoggedIn failed: $e\n$st');
    }
  }

  /// The account's master push switch changed — from this phone's own Settings or
  /// from the web, via the 'preferences_updated' socket event or a resume
  /// refetch (AuthProvider forwards all three). Keeps the SharedPreferences
  /// mirror in step and starts/stops the Android polling fallback to match.
  /// Never prompts for OS permission: asking belongs to the Settings
  /// switch, inside the user's own tap. Also safe to call repeatedly — a
  /// service that's already running (or already stopped) is left alone.
  static Future<void> onPushPreferenceChanged(bool enabled) async {
    try {
      await NotificationPrefs.setPushEnabled(enabled);
      if (!enabled) {
        await stopBackgroundPolling();
      } else if (await Permission.notification.isGranted) {
        await startBackgroundPolling();
      }
    } catch (e, st) {
      debugPrint('NotificationScheduler.onPushPreferenceChanged failed: $e\n$st');
    }
  }

  /// The account's per-topic push values changed (or were re-read). Keeps
  /// the SharedPreferences copy the local banner paths read in step — see
  /// NotificationPrefs.setPushTypes. Nothing to start or stop: a topic
  /// switch never turns the polling fallback on or off, only what a tick is
  /// allowed to show.
  static Future<void> onPushTypesChanged(Map<String, bool> types) async {
    try {
      await NotificationPrefs.setPushTypes(types);
    } catch (e, st) {
      debugPrint('NotificationScheduler.onPushTypesChanged failed: $e\n$st');
    }
  }

  /// app_shell.dart fires its own, independent NotificationBootstrap
  /// .requestPermissions() call from initState on the very next frame after
  /// login, so this call and that one land within about a frame of each
  /// other on essentially every login. permission_handler's Android side
  /// rejects a second concurrent request outright with a PlatformException
  /// instead of queuing it, so whichever call loses that race must not be
  /// read as the user denying the permission. Back off and ask again —
  /// once the winning call's dialog has been answered, request() just
  /// returns the OS's decision without re-prompting — instead of giving up
  /// after a single lost race.
  static Future<bool> _requestPermissions() async {
    const maxAttempts = 10;
    const retryDelay = Duration(milliseconds: 500);
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        return await NotificationBootstrap.requestPermissions();
      } on PlatformException {
        if (attempt == maxAttempts) rethrow;
        await Future.delayed(retryDelay);
      }
    }
    return false; // unreachable
  }

  static Future<void> onLoggedOut() async {
    try {
      await stopBackgroundPolling();
    } catch (e, st) {
      debugPrint('NotificationScheduler.onLoggedOut failed to stop polling: $e\n$st');
    }
    try {
      await FcmService.unregisterToken();
    } catch (e, st) {
      debugPrint('NotificationScheduler.onLoggedOut failed to unregister FCM token: $e\n$st');
    }
    await NotificationPrefs.clearSession();
  }
}
