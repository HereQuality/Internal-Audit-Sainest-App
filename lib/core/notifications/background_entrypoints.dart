import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'event_poll.dart';
import 'overdue_poll.dart';

Future<void> _pollAll() async {
  await pollAndNotifyOverdueNcs();
  await pollAndNotifyEvents();
}

/// How often the foreground service polls for overdue NCs while it's alive.
const Duration kPollInterval = Duration(minutes: 15);

/// ── flutter_background_service's foreground-service entrypoint ───────
/// Posts the persistent notification that makes this a real foreground
/// service (OEM battery managers treat a visible foreground service very
/// differently from a bare background process), does one immediate poll on
/// (re)start so a freshly-started service doesn't wait a full kPollInterval
/// before the user sees anything, then polls again every kPollInterval for
/// as long as the service stays alive.
@pragma('vm:entry-point')
void backgroundServiceOnStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    await service.setForegroundNotificationInfo(
      title: 'Internal Audit',
      content: 'Watching for overdue NCs',
    );
  }

  await _pollAll();
  Timer.periodic(kPollInterval, (_) => _pollAll());

  service.on('stopService').listen((_) => service.stopSelf());
}

@pragma('vm:entry-point')
bool backgroundServiceOnIosBackground(ServiceInstance service) {
  DartPluginRegistrant.ensureInitialized();
  _pollAll();
  return true;
}

/// Wires up flutter_background_service's configuration. iOS gets a
/// registered background handler too, but per NOTIFICATIONS.md, iOS never
/// actually backgrounds this the way Android does — `onIosBackground`
/// above only gets a brief opportunistic window from the OS, it is not a
/// standing service the way the Android half is.
Future<void> configureBackgroundService() async {
  final service = FlutterBackgroundService();
  // flutter_background_service ties its native singleton to the isolate
  // that first configured it. A Flutter *hot restart* (dev only — reruns
  // main() in the same still-alive Android process instead of a real cold
  // start) reconfigures on top of that stale native state and throws "This
  // class should only be used in the main isolate" — harmless on a real
  // launch, but must not be allowed to propagate: NotificationBootstrap.init
  // already wraps this whole call, but guarding here too means a caller
  // that starts calling this directly later doesn't quietly lose that.
  try {
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundServiceOnStart,
        autoStart: false, // started explicitly once someone's actually logged in — see notification_scheduler.dart
        isForegroundMode: true,
        // No custom notificationChannelId — leaving it null makes the plugin
        // create+use its own "FOREGROUND_DEFAULT" channel automatically. A
        // custom id here would need that channel created ourselves, via
        // flutter_local_notifications, BEFORE this configure() call.
        initialNotificationTitle: 'Internal Audit',
        initialNotificationContent: 'Watching for overdue NCs',
        // Must match the android:foregroundServiceType="dataSync" override
        // in AndroidManifest.xml (added via tools:node="merge" on the
        // plugin's BackgroundService) — Android now requires every FGS to
        // declare a type, and the runtime call's type must be a subset of
        // what's declared in the manifest.
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundServiceOnStart,
        onBackground: backgroundServiceOnIosBackground,
      ),
    );
  } catch (e, st) {
    debugPrint('configureBackgroundService failed (likely a hot-restart artifact — safe to ignore unless it also happens on a fresh launch): $e\n$st');
  }
}

/// Starts the service — called once after login (and once at app start if
/// already logged in). Idempotent: starting an already-running service is
/// a no-op.
Future<void> startBackgroundPolling() async {
  if (!Platform.isAndroid) return; // see NOTIFICATIONS.md — no real background equivalent on iOS
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    await service.startService();
  }
}

/// Stops the service on logout — otherwise it would keep polling with a
/// token NotificationPrefs.clearSession() just erased, which
/// pollAndNotifyOverdueNcs already no-ops on, but there's no reason to
/// keep it running for nothing.
Future<void> stopBackgroundPolling() async {
  if (!Platform.isAndroid) return;
  final service = FlutterBackgroundService();
  if (await service.isRunning()) service.invoke('stopService');
}
