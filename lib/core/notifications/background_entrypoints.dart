import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';

import 'event_poll.dart';
import 'notification_prefs.dart';
import 'overdue_poll.dart';

/// Whether the foreground service has any business existing right now:
/// someone is signed in (a session token is mirrored), that session is not
/// one the server has refused, AND their master push switch is on. All of it
/// matters. The master mirror deliberately survives a logout and defaults to
/// ON (see NotificationPrefs), so it alone would keep a service alive — and
/// its persistent notification on screen — on a phone nobody is signed in on;
/// the polls no-op without a token, so nothing else would ever end it. A
/// mirrored token that expired (1 day for a phone login) makes every poll
/// request a 401 nothing can fix until the next login, so the service stops
/// instead of "Watching for overdue NCs" while doing nothing; FCM is not
/// affected. Every start goes through this, and every tick asks it again, so
/// a stop message that never arrived (the service's Dart side is not
/// listening yet while its engine boots) is healed by state.
@visibleForTesting
Future<bool> serviceShouldRun() async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty) return false;
  if (await NotificationPrefs.isSessionRejected()) return false;
  return NotificationPrefs.readPushEnabled();
}

/// One full tick. Each poll refreshes the push-switch mirror (the master
/// switch and the per-topic values) from the server before showing anything
/// (see event_poll.dart#refreshPushGate) and gates every banner by its own
/// topic, so the answer read afterwards is as fresh as the network allows.
/// Returns false once [serviceShouldRun] says no — the MASTER push switch is
/// off or nobody is signed in — so the foreground service can shut itself
/// down instead of idling, and holding its persistent notification, for
/// something that is switched off. A single topic being off never stops it:
/// the other topics still need it.
Future<bool> _pollAll() async {
  await pollAndNotifyOverdueNcs();
  await pollAndNotifyEvents();
  return serviceShouldRun();
}

/// How often the foreground service polls for overdue NCs while it's alive.
const Duration kPollInterval = Duration(minutes: 15);

/// How long the foreground service may run after the app last came to the
/// foreground before it stops itself — on Android 15+ ([kDataSyncTimeoutSdk])
/// only. This app targets API 36, so there a dataSync foreground service gets
/// about 6 h of background runtime per 24 h; then the system calls
/// Service.onTimeout and kills the WHOLE app process if the service hasn't
/// stopped within seconds.
/// flutter_background_service (6.3.1) has no onTimeout to hook, so stopping
/// ourselves well ahead of the limit is the only lever from Dart. The check
/// rides the poll tick, so the worst case is this plus one [kPollInterval],
/// still inside the budget. The budget resets whenever the app comes to the
/// foreground (see [handleAppResumed]), which is also the only moment
/// Android lets a stopped dataSync service start again. FCM keeps delivering
/// while the service is stopped: this poll is only the fallback behind it.
/// Earlier releases have no such timeout, and stopping there would only end
/// the fallback for nothing; when the release isn't known the cap applies.
const Duration kServiceMaxRuntime = Duration(hours: 5);

/// The first Android API level (15) that ends a dataSync foreground service
/// after its runtime budget.
const int kDataSyncTimeoutSdk = 35;

// Only MainActivity.kt answers this, and only the UI isolate has that engine —
// the service isolate reads what [recordAndroidSdk] left behind.
const MethodChannel _deviceChannel = MethodChannel('com.hqepl.audit360/device');

/// Leaves the Android API level in the prefs for the service isolate (see
/// [runPollingService]). Best-effort: without it (a platform channel that
/// doesn't answer, an older MainActivity) the service keeps the cap.
@visibleForTesting
Future<void> recordAndroidSdk() async {
  try {
    final sdk = await _deviceChannel.invokeMethod<int>('sdkInt');
    if (sdk != null) await NotificationPrefs.setAndroidSdk(sdk);
  } catch (_) {
    // Not answered: the cap stays on, which is the safe side.
  }
}

/// ── flutter_background_service's foreground-service entrypoint ───────
/// Posts the persistent notification that makes this a real foreground
/// service (OEM battery managers treat a visible foreground service very
/// differently from a bare background process), does one immediate poll on
/// (re)start so a freshly-started service doesn't wait a full kPollInterval
/// before the user sees anything, then polls again every kPollInterval for
/// as long as the service stays alive — which ends on its own the first
/// tick that finds nobody signed in or the account's master push switch off
/// (see [_pollAll]), or — on Android 15+ only — once [kServiceMaxRuntime] has
/// passed.
@pragma('vm:entry-point')
void backgroundServiceOnStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  await runPollingService(service);
}

/// The body of [backgroundServiceOnStart], with its collaborators injectable
/// so a test can drive it without a platform: [poll] is one tick (true =
/// keep running), [readForegroundedAt] when the app last came to the
/// foreground, [readAndroidSdk] the API level the UI isolate recorded, [now]
/// the clock.
@visibleForTesting
Future<void> runPollingService(
  ServiceInstance service, {
  Future<bool> Function() poll = _pollAll,
  Future<DateTime?> Function() readForegroundedAt = NotificationPrefs.readAppForegroundedAt,
  Future<int?> Function() readAndroidSdk = NotificationPrefs.readAndroidSdk,
  DateTime Function() now = DateTime.now,
  Duration interval = kPollInterval,
  Duration maxRuntime = kServiceMaxRuntime,
}) async {
  final startedAt = now();
  var stopped = false;
  Timer? timer;

  void stop() {
    if (stopped) return;
    stopped = true;
    timer?.cancel();
    service.stopSelf();
  }

  // First thing, before any await: the plugin's event stream is a
  // broadcast one that drops whatever arrives while nobody listens, and the
  // awaits below (the foreground promotion, then a poll of several HTTP
  // calls) leave a window of seconds — minutes on a bad connection — in
  // which a logout or push-off would otherwise vanish and leave the service
  // running with its notification.
  service.on('stopService').listen((_) => stop());

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
    await service.setForegroundNotificationInfo(
      title: 'Internal Audit',
      content: 'Watching for overdue NCs',
    );
  }

  // A tick that throws is a failed poll, not a reason to stop, and must not
  // abort this entrypoint before the timer below exists — that would leave
  // an idle foreground service with no poll and no way to end itself.
  Future<bool> pollSafely() async {
    try {
      return await poll();
    } catch (e, st) {
      debugPrint('Foreground-service poll failed, will retry next tick: $e\n$st');
      return true;
    }
  }

  // Whether the Android 15+ dataSync budget (see [kServiceMaxRuntime]) is
  // spent. It counts from the app's last time in the foreground, not from
  // when this service started: the OS clock restarts on every foreground.
  // Without a stamp, or with one that can't be trusted (unreadable, or "from
  // the future" because the clock went back — which would otherwise keep
  // the service alive far past the limit), it falls back to the service's
  // own start. Never spent on a release known to be older than Android 15:
  // it has no such timeout, and stopping there only ends the fallback early.
  Future<bool> runtimeSpent() async {
    try {
      final sdk = await readAndroidSdk();
      if (sdk != null && sdk < kDataSyncTimeoutSdk) return false;
    } catch (_) {
      // Unreadable prefs: not knowing the release keeps the cap.
    }
    final current = now();
    var since = startedAt;
    try {
      final stamp = await readForegroundedAt();
      if (stamp != null && !stamp.isAfter(current)) since = stamp;
    } catch (_) {
      // Unreadable prefs: the service's own start is the safe bound.
    }
    return current.difference(since) >= maxRuntime;
  }

  if (stopped) return;
  if (!await pollSafely()) {
    stop();
    return;
  }
  // A stop that arrived while that first poll ran already ended the
  // service — never start ticking after it.
  if (stopped) return;

  timer = Timer.periodic(interval, (_) async {
    if (stopped) return;
    if (await runtimeSpent() || !await pollSafely()) stop();
  });
}

@pragma('vm:entry-point')
bool backgroundServiceOnIosBackground(ServiceInstance service) {
  DartPluginRegistrant.ensureInitialized();
  _pollAll();
  return true;
}

/// The Android half of the service configuration, split out so a test can
/// pin it. The values that matter beyond the plugin's defaults:
/// - autoStart false: started explicitly once someone's actually logged in
///   (see notification_scheduler.dart), never just because the app launched.
/// - autoStartOnBoot false: the plugin's default (true) makes its BootReceiver
///   restart the service after every reboot and app update whether or not
///   anyone is signed in or push is on. On Android 15+ a BOOT_COMPLETED
///   receiver may not even start a dataSync foreground service. The receiver
///   itself is removed in AndroidManifest.xml too, because this flag is only
///   rewritten when the app next launches — after the update's own
///   broadcast has already fired. The service is started from the app
///   instead: at login, when push is switched on, and on every foreground
///   ([handleAppResumed]).
@visibleForTesting
AndroidConfiguration buildAndroidServiceConfiguration() => AndroidConfiguration(
  onStart: backgroundServiceOnStart,
  autoStart: false,
  autoStartOnBoot: false,
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
  // what's declared in the manifest. dataSync is the honest type for a
  // periodic poll; the only timeout-free alternative, specialUse, needs a
  // Play Console declaration a poll cannot really justify, so the timeout
  // is handled by [kServiceMaxRuntime] instead.
  foregroundServiceTypes: [AndroidForegroundType.dataSync],
);

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
      androidConfiguration: buildAndroidServiceConfiguration(),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundServiceOnStart,
        onBackground: backgroundServiceOnIosBackground,
      ),
    );
    if (_lifecycleHook == null) {
      _lifecycleHook = _ServiceLifecycleHook();
      WidgetsBinding.instance.addObserver(_lifecycleHook!);
    }
  } catch (e, st) {
    debugPrint('configureBackgroundService failed (likely a hot-restart artifact — safe to ignore unless it also happens on a fresh launch): $e\n$st');
  }
}

_ServiceLifecycleHook? _lifecycleHook;

/// Ties the service to the app coming to the foreground: the one moment
/// Android lets a stopped dataSync service start again and restarts its
/// runtime budget (see [kServiceMaxRuntime]).
class _ServiceLifecycleHook with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Platform.isAndroid && state == AppLifecycleState.resumed) {
      unawaited(handleAppResumed(FlutterBackgroundService()));
    }
  }
}

/// The app came to the foreground. Records it — the service's runtime budget
/// counts from here — and, when the service isn't running though it should
/// be (it stopped itself at the budget, the OS killed it, or the
/// notification permission was granted only later), starts it. Never throws.
@visibleForTesting
Future<void> handleAppResumed(FlutterBackgroundService service) async {
  try {
    await NotificationPrefs.markAppForegrounded();
    if (await service.isRunning()) return;
    // Same gate as the login and push-on paths in notification_scheduler.dart:
    // without the OS permission nothing the service polls could be shown.
    if (!await Permission.notification.isGranted) return;
    await startServiceIfEligible(service);
  } catch (e, st) {
    debugPrint('handleAppResumed failed: $e\n$st');
  }
}

/// Starts the service — called once after login (and once at app start if
/// already logged in), when the account's push switch is switched on, and on
/// every return to the foreground. Idempotent: starting an already-running
/// service is a no-op. Does nothing unless someone is signed in with the
/// master push switch on (see [serviceShouldRun]), so a caller that raced a
/// logout — the permission dialog is awaited before the login path gets
/// here — cannot resurrect a service on a signed-out phone.
Future<void> startBackgroundPolling() async {
  if (!Platform.isAndroid) return; // see NOTIFICATIONS.md — no real background equivalent on iOS
  await startServiceIfEligible(FlutterBackgroundService());
}

/// [startBackgroundPolling] minus the platform check, for tests. True when
/// the service is (now) running or was left running.
@visibleForTesting
Future<bool> startServiceIfEligible(FlutterBackgroundService service) async {
  if (!await serviceShouldRun()) return false;
  // Every start comes from the app being in use, which is what the runtime
  // budget counts from — including when the service was already running. It
  // is also the moment the service's isolate learns which Android it is on.
  await NotificationPrefs.markAppForegrounded();
  await recordAndroidSdk();
  if (!await service.isRunning()) {
    await service.startService();
  }
  return true;
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
