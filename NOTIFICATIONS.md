# Overdue-NC local notifications

Non-FCM, poll-from-the-device pipeline for notifying an auditee that a
Non-Conformance raised against them has passed its `targetDate` without
being closed. Android gets a real, resilient background poll; iOS gets
best-effort only (see **iOS reality check** below) — that asymmetry is
inherent to the platforms, not a gap in this implementation.

## Files

| File | Runs where | Job |
|---|---|---|
| `core/notifications/notification_prefs.dart` | any isolate | SharedPreferences-backed session token + "already notified" NC ids — the only thing background isolates can reach (no Provider/DI) |
| `core/notifications/local_notifications.dart` | any isolate | `flutter_local_notifications` init, channel setup, `showOverdueNc` / `showFullScreenAlarm` |
| `core/notifications/overdue_poll.dart` | any isolate | `pollAndNotifyOverdueNcs()` — the one function that does the actual work: `GET /ncs/mine`, diff against already-notified, show |
| `core/notifications/background_entrypoints.dart` | background isolates | `alarmTick` (self-rescheduling `AndroidAlarmManager.oneShot`), `watchdogTick` (`AndroidAlarmManager.periodic` recovery check), `backgroundServiceOnStart` (`flutter_background_service` foreground service) |
| `core/notifications/notification_bootstrap.dart` | foreground | one-time plugin init (call from `main()`) + runtime permission requests (call from a real screen) |
| `core/notifications/notification_scheduler.dart` | foreground | the seam `AuthProvider` calls into on login/logout |

Wired in: `main.dart` (`NotificationBootstrap.init()` before `runApp`),
`providers/auth_provider.dart` (`NotificationScheduler.onLoggedIn` /
`onLoggedOut`), `screens/root/app_shell.dart` (`requestPermissions()` once
the user is actually inside the app).

## Why three overlapping timers instead of one

- **`alarmTick`** (`AndroidAlarmManager.oneShot`, `exact: true,
  allowWhileIdle: true`, every 15 min, re-arms itself from inside itself)
  — the actual clock. Not `Timer.periodic`: an in-process Dart timer only
  fires if the OS is still scheduling that isolate's event loop, and
  Vivo/Xiaomi/Oppo-style battery managers freeze a backgrounded process's
  event loop long before they kill it — the timer just silently stalls.
  Going through the real OS `AlarmManager` means Doze/App Standby still
  have to honor it (within their own throttling rules).
- **`backgroundServiceOnStart`** (`flutter_background_service`, foreground
  service) — not a timer at all, just *presence*. A visible foreground
  notification makes the process a foreground service in the OS's eyes,
  which most OEM battery managers treat very differently from a bare
  background process. It does one poll on (re)start and otherwise waits.
- **`watchdogTick`** (`AndroidAlarmManager.periodic`, every 30 min, not
  self-rescheduling since a recovery check doesn't need that discipline) —
  the "did the other two actually survive" check. If `alarmTick` hasn't
  recorded a run in the last 3 poll-intervals, re-arms it. If the
  foreground service isn't running, restarts it.

None of this makes the pipeline unkillable — no third-party app can
override an OEM that's determined to kill everything — it just gives the
pipeline three independent chances to notice and self-heal instead of one
silent single point of failure.

## Testing it for real

1. `flutter pub get` (already run — resolves clean against this repo).
2. Log in on a physical Android device (emulators fake Doze behavior
   unreliably). Grant the notification + exact-alarm prompts that appear.
3. On the backend, set an NC's `targetDate` to a few minutes in the past
   for the logged-in employee (`node -e` against the seeded data works —
   see `server/seed/seedFullTestData.js` for NC ids/usernames), or just
   wait for real data to go overdue.
4. Force-stop the app from Recents (swipe away, not just background it —
   this is the actual failure mode you're guarding against) and leave the
   screen off for 15+ minutes. The notification should still arrive.
5. `adb shell dumpsys alarm | grep -A3 internal_audit_app` to confirm the
   two alarms (`kTickAlarmId` / `kWatchdogAlarmId`) are actually registered
   with AlarmManager if a notification doesn't show up.

## Full-screen, lock-screen alarm-style notification (Android 14+)

`LocalNotifications.showFullScreenAlarm()` is already wired for this
(`fullScreenIntent: true`, `category: alarm`, `visibility: public`) but
**unused by the overdue poll on purpose** — reserve it for something that
genuinely warrants interrupting the lock screen (a hard compliance
deadline), not a routine overdue nudge, or Play Store review will flag it.

What's required beyond the notification call itself:
- `<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/>`
  — already added to `AndroidManifest.xml`.
- **Android 14 (API 34) changed this permission's grant model.** For apps
  *targeting* SDK 34+, it is no longer auto-granted at install time — the
  user must explicitly allow it via
  `Settings > Apps > Internal Audit > Alarms & reminders` (or the
  `NotificationManager.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT` intent,
  which deep-links straight there). Check
  `NotificationManagerCompat.from(context).canUseFullScreenIntent()`
  before relying on it; if false, fall back to `showOverdueNc` (a loud
  heads-up notification is still far better than nothing) and prompt the
  user toward that settings screen the same way this repo already prompts
  for exact-alarm.
- Google Play policy restricts full-screen intent to genuine alarm/call
  use cases — don't ship it for anything less, it risks a policy strike.

## iOS: AlarmKit (iOS 26+)

Apple's `AlarmKit` (introduced iOS 26) is the real iOS mechanism for a
lock-screen, Focus-bypassing alarm-style alert — normal
`UNNotificationRequest`/`flutter_local_notifications` cannot do this on
iOS at all, full-screen intent has no iOS equivalent.

**I did not wire this up.** `flutter_alarmkit` isn't something I could
verify actually exists as a maintained package from here (no network
access in this environment) — before depending on it: check pub.dev
directly for a real, maintained wrapper; if none exists, the fallback is
writing a thin `MethodChannel` yourself around Apple's native
`AlarmKit`/`AlarmManager.requestAuthorization()` APIs. Either way you'll
also need:
- `NSAlarmKitUsageDescription` in `Info.plist` (parallel to
  `NSCameraUsageDescription` already there).
- An explicit authorization request at runtime (`AlarmManager.authorizationState` /
  `requestAuthorization()`), separate from the `UNUserNotificationCenter`
  permission this repo already requests.
- Apple restricts AlarmKit to genuine alarm/timer semantics, same spirit
  as Android's full-screen-intent policy above — not a fit for a routine
  "an NC is overdue" nudge; reserve it for the same class of hard-deadline
  case `showFullScreenAlarm` is reserved for on Android.

Given this app has no reliable iOS background poll to trigger it from
anyway (see below), AlarmKit is only worth the investment once/if iOS
gets a real trigger — i.e. after adding FCM/APNs silent push for iOS
specifically.

## iOS reality check

`android_alarm_manager_plus` has no iOS implementation — there is no
Android-equivalent way to make iOS honor a "poll every 15 minutes" clock
while backgrounded or killed. `flutter_background_service`'s
`onIosBackground` only gets an *opportunistic* window iOS grants at its
own discretion (frequently none for hours if the user hasn't opened the
app recently) via `BGAppRefreshTask` under the hood. On iOS, this pipeline
in practice means: notifications fire correctly while the app is open or
was very recently backgrounded, and are NOT reliable once it's been
backgrounded a while or force-quit. If iOS reliability actually matters
for this feature, the only real fix is FCM or APNs silent push
(`content-available: 1`) specifically for iOS — nothing achievable
client-side changes that. See the trade-off note this doc's companion
conversation gave for the fuller FCM-vs-polling comparison.
