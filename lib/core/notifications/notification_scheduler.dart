import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

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
      // Settings screen's own toggle-on path, so a fresh login doesn't
      // start anything before the user has ever been asked. A denial just
      // means no reminders; the underlying prefs stay on so re-granting
      // later (Settings, or the OS Settings screen after a permanent
      // denial) picks everything back up next login with no rediscovery
      // needed.
      final granted = await _requestPermissions();
      // FCM push doesn't depend on the (Android-only) local-poll
      // foreground-service toggle below — a real server push needs no
      // persistent foreground service to arrive, so this registers
      // whenever notification permission is granted, on by default same
      // as background polling is.
      if (granted) await FcmService.registerToken();
      // On by default — see NotificationPrefs.readBackgroundPollingEnabled.
      if (granted && await NotificationPrefs.readBackgroundPollingEnabled()) {
        await startBackgroundPolling();
        await pollAndNotifyOverdueNcs();
        await pollAndNotifyEvents();
      }
    } catch (e, st) {
      debugPrint('NotificationScheduler.onLoggedIn failed: $e\n$st');
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
