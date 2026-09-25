# Notifications: local poll + FCM push

Two layers, deliberately overlapping rather than one replacing the other:

- **Local poll** (this doc's original content, below) — a
  poll-from-the-device pipeline, resilient on Android via AlarmManager +
  a foreground service, best-effort on iOS (see **iOS reality check**).
  Works with ZERO server/Firebase setup.
- **FCM push** (`core/notifications/fcm_service.dart`) — real push via
  Firebase Cloud Messaging, arriving even with the app fully closed/
  killed on both platforms, sourced from the server's own Notification
  system (`server/services/notification.service.js` ->
  `fcmPush.service.js`, the exact same funnel the web app's browser push
  already goes through). See **FCM push setup** below — it needs a real
  Firebase project (and, for iOS, an Apple APNs key) to do anything; until
  then it's a total no-op and the local poll (this whole rest of the doc)
  is the only thing running.

Neither layer's dedup state (SharedPreferences `notifiedDates`/`seenIds`
locally, the server's own `Notification.isRead` for pushes) knows about
the other, so the FIRST event after FCM goes live can show two tray
entries for the same thing — a one-time overlap, not a bug to chase; see
`event_poll.dart`'s own header comment.

## Settings: two master switches, then a switch per topic and channel

Settings (phone AND web) has two account-level master switches and, under
them, "Choose what you get": every topic with its own **Email** and **Push**
switch. All of it is stored on the account (`preferences.pushNotifications`
/ `preferences.emailNotifications`, plus the per-topic maps
`preferences.emailNotificationTypes.<type>` and
`preferences.pushNotificationTypes.<type>`; `GET`/`PUT
/auth/me/preferences`), identical on both portals and kept in step live
(`preferences_updated` socket event, which carries the full payload, plus a
refetch on app resume, on socket reconnect and when Settings opens).

- **Push notifications** (master) — browser push AND phone push, every
  notification type including support tickets. Off silences the whole Push
  column; the stored per-topic values stay visible but locked, with a hint.
  The server stops sending FCM/web push (`createNotification` is the only
  funnel).
- **Email notifications** (master) — same for the Email column.
- **Per topic** — the catalog is `kNotificationTopics` in
  `core/notifications/notification_prefs.dart` (the `key`s are the contract
  and match `server/utils/notificationTypes.js`, the canonical catalog):
  Audits (new audit assigned, recurring series created, reassigned,
  skipped, completed, due/overdue, and the push-only `audit_reminder`),
  Non-conformances (raised, response submitted/approved/rejected, overdue),
  Daily summaries (morning, evening) and Support tickets (new, reply,
  status/confirmation, escalated). Each group header's Email / Push menus
  are "all on / all off" for that column.
- A change saves optimistically (the switch moves at once) and rolls back
  with an error snackbar if the server refuses. Both of a topic's channel
  values are always sent together — the server falls back to the old shared
  setting for a channel that was never set explicitly, and that fallback
  ends the first time both are sent. Saves on the screen go through one
  queue so an older response can never undo a newer tap.

The phone must obey the same switches for everything IT draws, not only for
what the server sends, so the Push values are mirrored into SharedPreferences
(the code that decides whether to SHOW something — the two poll isolates, the
FCM background handler, the socket banner — can't reach AuthProvider):

| Mirror | Key | Read with |
|---|---|---|
| master Push switch | `notif_push_enabled` | `NotificationPrefs.readPushEnabled()` (default ON) |
| per-topic Push values (JSON object, effective values) | `notif_push_types` | `readPushTypes()` / `readPushTypeEnabled(type)` (a missing topic is ON) |

`NotificationPrefs.readPushAllowed(type)` = master AND topic, and is what the
socket banner and both FCM renderers ask; a type that is not in the catalog
answers to the master alone. The polls read one `PushGate` per tick
(`refreshPushGate` in `event_poll.dart` re-fetches `GET /auth/me/preferences`
first, so a change made on the web reaches the killed-app service too).
Mapping of what a poll may show:

| Local banner | Topic(s) that must be on |
|---|---|
| "New audit assigned" | `audit_created` AND `audit_reassigned` — a newly listed audit can be either, and the list can't say which |
| "Audit starting" / "Audit due" | `audit_reminder` |
| "New NC raised against you" | `nc_raised` |
| "NC response approved" / "rejected" | `nc_approved` / `nc_rejected` |
| overdue NC | `nc_overdue` |

With a topic off nothing is shown but the dedup bookkeeping still runs, so
turning it back on never dumps what happened meanwhile. `AuthProvider` writes
both mirrors before `NotificationScheduler.onLoggedIn` (after one
`GET /auth/me/preferences` at login, so the mirror holds the server's
effective values) and again whenever the master or the per-topic values
change; the topic mirror is wiped on logout, the master one is not (see
`notification_prefs.dart`).

OS permission is NOT a third option: Settings shows it as a status line
under the master push switch. The retired phone-local switches — the
"Notifications" master switch (`notif_bg_polling_enabled`) and the six
per-type reminder toggles — are gone.

## What each platform receives

`fcmPush.service.js` builds a different message per token `platform`:

| | Android | iOS |
|---|---|---|
| Shape | **data-only** (`title`/`body`/`type`/`referenceId`/`notificationId` in `data`, no `notification` block), `android.priority: high` | **alert push**: `notification` block + `apns` headers (`apns-push-type: alert`, `apns-priority: 10`, a collapse id) + `aps.sound`; `data` carries `type`/`referenceId`/`notificationId` for tap routing |
| Drawn by | this app: `fcm_service.dart` renders a local notification (foreground handler + `_firebaseMessagingBackgroundHandler`) | iOS itself — banner + sound, even with the app force-quit. No Dart runs for the banner |
| `content-available` | n/a | deliberately NOT set — it would also wake the Dart background handler and double the banner |

Why iOS can't use data-only: a data-only message shows nothing on iOS; it
only arrives as a throttled silent push that isn't delivered at all once
the user force-quits the app. So on iOS the app must NOT render FCM
messages a second time:

- foreground: `setForegroundNotificationPresentationOptions(alert, badge,
  sound)` (in `FcmService.init`) makes iOS show the alert push while the
  app is open, and `_handleForegroundMessage` skips any iOS message that
  has a `notification` block;
- `_firebaseMessagingBackgroundHandler` returns early for any message with
  a `notification` block;
- the socket-driven live banner (`NotificationsProvider`) stays quiet on
  iOS once the token is registered (`FcmService.pushShownNatively`) —
  otherwise the same event would show twice, once from the socket and
  once from the push. Before registration succeeds it still acts as the
  fallback.

Local notification ids derive from the server's Notification `_id`
(`FcmService.localNotificationId`; the FCM `notificationId` and the
socket `new_notification` `_id` are the same value), so if a socket banner
and an FCM banner for one event DO both show (Android), they replace each
other instead of stacking. Every local banner — socket, FCM foreground/
background — is skipped while the mirrored master Push switch is off or that
notification's own topic is off (`readPushAllowed`).

## FCM push setup

Everything on the SERVER and DART sides is already wired
(`server/models/DeviceToken.js`, `server/config/firebase.js`,
`server/services/fcmPush.service.js`, `server/controllers/
deviceToken.controller.js` + its route, `fcm_service.dart`, and
`main.dart`/`notification_scheduler.dart` calling into it) — every one of
those already fails soft to "no push" with nothing configured, so none of
it risks the app or server today. What's still missing, because it needs
an actual Firebase project (a Google account, not something committable
to this repo):

1. **Create a Firebase project** at console.firebase.google.com (free —
   Cloud Messaging has no usage cap or paid tier).
2. **Add an Android app** to it, package name **`com.hqepl.audit360`**
   (the real Android `applicationId` — `android/app/build.gradle.kts`) —
   download the generated `google-services.json` and place it at
   `android/app/google-services.json` (gitignored — never commit it).
3. **Add the Google Services Gradle plugin** — DONE (`android/settings
   .gradle.kts` + `android/app/build.gradle.kts`, plugin `4.5.0`, this
   project's Kotlin DSL `.gradle.kts`, not `.gradle`). `google-services
   .json` is in place at `android/app/google-services.json` (gitignored).
4. **iOS** — the iOS bundle id is **`com.hqepl.internalaudit`** (Xcode's
   `PRODUCT_BUNDLE_IDENTIFIER`, and `BUNDLE_ID` inside
   `GoogleService-Info.plist`). It is NOT the Android id: the same Firebase
   project holds two apps, one per platform. `GoogleService-Info.plist` is
   in place at `ios/Runner/GoogleService-Info.plist` (gitignored) and
   registered on the `Runner` target's Copy Bundle Resources phase. Real
   iPhone delivery needs ALL of these; the code can only do the first
   four:
   - **Push Notifications entitlement** — `ios/Runner/Runner.entitlements`
     (`aps-environment`), referenced by `CODE_SIGN_ENTITLEMENTS` in the
     Debug, Profile AND Release configurations of the `Runner` target, plus
     the Push Notifications / Background Modes capabilities in the project.
     Without it iOS never issues an APNs token and Firebase can't mint an
     iOS FCM token. (`flutter build ios --no-codesign` can't catch a
     missing entitlement — it never signs anything.)
   - **`firebase_messaging` 16.7+ / `firebase_core` 4.14+** — this app uses
     the UIScene + implicit-engine iOS template, where plugins are created
     AFTER launch. 15.x did all its iOS push setup (swizzling, APNs
     registration, notification-center delegate) in a launch-time observer
     that had already fired, so it never registered for remote
     notifications at all.
   - **`AppDelegate.swift`** sets itself as the
     `UNUserNotificationCenter` delegate so `FlutterAppDelegate` fans
     foreground presentation and taps out to BOTH `firebase_messaging` and
     `flutter_local_notifications`.
   - **`ios/Podfile`** defines `PERMISSION_NOTIFICATIONS=1` for
     `permission_handler_apple` (re-run `pod install` after changing it).
     Belt and braces: the iOS permission prompt itself goes through
     `FirebaseMessaging.requestPermission` (`FcmService.requestIosPermission`),
     not permission_handler, so iOS doesn't depend on that native flag.
   - **Apple Developer**: Push Notifications enabled on the App ID
     `com.hqepl.internalaudit`.
   - **APNs Authentication Key** (`.p8`, Apple Developer -> Certificates,
     Identifiers & Profiles -> Keys -> + -> "Apple Push Notifications
     service (APNs)") uploaded to Firebase Console -> Project Settings ->
     Cloud Messaging -> Apple app configuration, with its Key ID and the
     Team ID. Without it FCM answers `messaging/third-party-auth-error`
     for every iOS token.
5. **Server**: Firebase Console -> Project Settings -> Service Accounts ->
   "Generate new private key" — downloads a JSON file. Save it as
   `server/firebase-service-account.json` (gitignored) and confirm
   `server/.env`'s `FIREBASE_SERVICE_ACCOUNT_PATH` points at it (already
   set to that same default path). It must belong to the SAME Firebase
   project as `google-services.json` and `GoogleService-Info.plist`.
6. Restart the server, run `flutter pub get` (+ `cd ios && pod install
   --repo-update` for iOS) + rebuild the app. Log in on a device —
   `fcm_service.dart#registerToken` fires automatically and posts this
   device's token to `POST /device-tokens/register`. Trigger any existing
   notification (assign an audit, raise an NC, reply to a ticket) and
   confirm it now also arrives as a real push, including with the app
   closed.

## The Firebase project must match on both sides

An FCM token can only be sent to with the service account of the Firebase
project whose app minted it. The project is `project_id` in
`android/app/google-services.json` (Android) and `PROJECT_ID` in
`ios/Runner/GoogleService-Info.plist` (iOS); the server's is `project_id` in
`server/firebase-service-account.json`. When they differ Firebase answers
`messaging/mismatched-credential` for that platform and NOTHING arrives — this
is what "iOS push is silent while Android works" usually is. Check with:

    grep PROJECT_ID -A1 ios/Runner/GoogleService-Info.plist
    grep project_id android/app/google-services.json server/firebase-service-account.json

Either put the iOS app in the same project as the server (Firebase Console ->
Add app -> iOS, bundle id `com.hqepl.internalaudit`, download the new
`GoogleService-Info.plist`, upload the APNs `.p8` key under Project settings ->
Cloud Messaging -> Apple app configuration) or give the server the iOS
project's service account too (`FIREBASE_EXTRA_SERVICE_ACCOUNT_PATHS` in
`server/.env`). The app reports its project when it registers
(`firebaseProjectId`), so the server logs `[FCM] device registered but the
server cannot send to it` naming both, and Settings -> "Send a test
notification" says the same on the phone.

**Settings -> Send a test notification** (under the Push switch, once
notifications are allowed): re-registers the phone, pushes a real test to it and
shows the outcome — permission, whether iOS handed over the Apple push token,
the app's Firebase project, and the server's verdict/hint. It is the quickest
way to tell "not registered", "wrong Firebase project", "APNs key missing" and
"delivered" apart.

The registration is retried when the app returns to the foreground
(`FcmService.ensureRegistered`) if the login-time attempt failed or the
permission was granted later, instead of waiting for the next login.

## Testing iOS push (real iPhone only)

Simulators don't reliably issue APNs tokens, so nothing below works on
one.

1. Install a **Debug** build on the device (`flutter run`, signed in
   Xcode). Log in. iOS shows the "Allow notifications" prompt — tap Allow.
2. In the debug console `FcmService` prints the FCM token
   (`FCM token (paste it into Firebase console ...)`). If it instead
   prints `no APNs token after 10s`, the entitlement/capability isn't in
   the signed build, or this isn't a real device. Xcode's console saying
   `no valid 'aps-environment' entitlement string found` means the same.
3. Firebase Console -> Messaging -> New campaign -> Firebase Notification
   messages -> **Send test message**, paste the token. Expect a banner
   with the app in the background AND after force-quitting it.
4. Trigger a real event (raise a ticket, assign an audit). If nothing
   arrives, call **`POST /api/v1/device-tokens/test`** (authenticated) — it
   sends a test push to the caller's OWN tokens only and returns
   `{ isOk, data: { sent, failed, pruned, results: [{ tokenId, platform,
   ok, code }] } }`:
   - `ok: true` on the iOS token — APNs accepted it; if nothing shows, look
     at Focus/notification settings on the phone;
   - `messaging/third-party-auth-error` — APNs key missing, or wrong Key
     ID / Team ID, in Firebase;
   - `messaging/mismatched-credential` / `messaging/sender-id-mismatch` —
     `firebase-service-account.json` is from a different Firebase project
     than the app's plist;
   - `messaging/registration-token-not-registered` — stale token (it's
     pruned automatically);
   - no results at all — this account has no registered token: the app
     never registered (permission, entitlement, or the login didn't reach
     `registerToken`).
5. Tap a push: with the app running/backgrounded it routes via
   `onMessageOpenedApp`; force-quit it and tap — it routes via
   `getInitialMessage` once the app shell is up. Confirm both.

### Sandbox vs. production APNs

`aps-environment` in `Runner.entitlements` is `development`, Xcode's
default. A Debug run installed from Xcode gets a **sandbox** APNs token, and
`firebase_messaging` tags the token as sandbox only when compiled with the
DEBUG flag. TestFlight and App Store builds use **production** APNs (the
same `.p8` key covers both; with automatic signing Xcode normally rewrites
the entitlement to `production` when archiving/exporting — verify it, see
below). Consequences:

- Test with a `flutter run` **Debug** build, or with TestFlight/App Store.
  Do NOT test a `--release`/`--profile` build installed straight onto a
  device: it has a sandbox token but is tagged production, so pushes fail.
- Verify what actually shipped: `codesign -d --entitlements - Runner.app`
  on the exported app must show `aps-environment` = `production`. If you
  sign manually (or with fastlane) instead of automatic signing, give the
  Release configuration its own entitlements file with `production`.

### After releasing this build

Phones on an old build never registered an iOS token, so each iPhone has to
update, open the app once, allow notifications and sign in again. Check the
`devicetokens` collection for a document with `platform: 'ios'` for that
user. Roll the update out through Administration -> Company -> App Update
(Latest Version for the soft banner, later Minimum Version to force it) so
old builds don't linger; the server stays backward compatible with them.

## iOS gotcha: Swift Package Manager vs. `firebase_core`

When this was diagnosed (`firebase_core` 3.15.2), that plugin's
`Package.swift` computed its own version by
reading `pubspec.yaml` via a path built from `#file` two directories up.
Flutter's Swift Package Manager integration resolves local plugin
packages through a SYMLINK
(`ios/Flutter/ephemeral/Packages/.packages/firebase_core-<version>` ->
`~/.pub-cache/.../firebase_core-<version>/ios/firebase_core`), and `#file`
reports the SYMLINK's own path, not its real target — so "two directories
up" lands on `ios/Flutter/ephemeral/Packages/pubspec.yaml`, which doesn't
exist, and `xcodebuild`/`flutter build ios`/`flutter run` all fail with
`Failed to load configuration: fileNotFound(...pubspec.yaml...)` before
any of this app's own code is even touched.

**Fix applied**: `flutter config --no-enable-swift-package-manager`
(global to this machine — there's no other Flutter project on it), then
the iOS project was regenerated from scratch
(`flutter create --platforms=ios --org com.hqepl .` on a moved-aside
`ios/`) so Flutter wires plugins through CocoaPods (`ios/Podfile`,
already present) instead — CocoaPods vendors real files, no symlink, no
`#file` mismatch. `pod install` now resolves Firebase in
`ios/Podfile.lock` correctly. If `ios/` is ever regenerated again for any
reason, **re-verify no `FlutterGeneratedPluginSwiftPackage` reference
exists** in `ios/Runner.xcodeproj/project.pbxproj`
(`grep -c FlutterGeneratedPluginSwiftPackage`) — a nonzero count means
SPM crept back in and this same build failure will return.

**Side effect to watch for**: regenerating `ios/` from scratch (moving
the whole folder aside first, not just re-running `flutter create` on an
existing one — which does NOT retrofit an already-SPM-integrated project)
resets `ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png` back to the
stock Flutter template icons and drops `ios/Runner/Info.plist`'s custom
keys (camera/photo permissions, `BGTaskSchedulerPermittedIdentifiers`,
`UIBackgroundModes`) back to bare defaults — both are tracked in git, so
`git checkout HEAD -- ios/Runner/Assets.xcassets/AppIcon.appiconset/`
recovers the icons, but Info.plist's custom keys need re-adding by hand.
Also re-set `PRODUCT_BUNDLE_IDENTIFIER` to `com.hqepl.internalaudit` in
the fresh `project.pbxproj` (`flutter create`'s own default is
`com.hqepl.internalAuditApp`), and revert `pubspec.lock`/`.metadata`
afterward — `flutter create` bumps transitive dependency versions and
strips other-platform entries out of `.metadata` as a side effect
unrelated to iOS itself. A regeneration ALSO silently drops every push
change: `ios/Runner/Runner.entitlements` + `CODE_SIGN_ENTITLEMENTS` in
all three Runner build configurations, the `UNUserNotificationCenter`
delegate in `AppDelegate.swift`, and the `PERMISSION_NOTIFICATIONS=1`
block in `ios/Podfile`'s `post_install` — re-apply and re-verify all of
them.

## Files

| File | Runs where | Job |
|---|---|---|
| `core/notifications/notification_prefs.dart` | any isolate | SharedPreferences-backed session token, "already notified" NC ids, the `notif_push_enabled` and `notif_push_types` mirrors of the account's push switches, and the topic catalog (`kNotificationTopics`) — the only thing background isolates can reach (no Provider/DI) |
| `core/notifications/local_notifications.dart` | any isolate | `flutter_local_notifications` init, channel setup, `showOverdueNc` / `showFullScreenAlarm` |
| `core/notifications/overdue_poll.dart` | any isolate | `pollAndNotifyOverdueNcs()` — the one function that does the actual work: `GET /ncs/mine`, diff against already-notified, show |
| `core/notifications/background_entrypoints.dart` | background isolates | `alarmTick` (self-rescheduling `AndroidAlarmManager.oneShot`), `watchdogTick` (`AndroidAlarmManager.periodic` recovery check), `backgroundServiceOnStart` (`flutter_background_service` foreground service) |
| `core/notifications/notification_bootstrap.dart` | foreground | one-time plugin init (call from `main()`) + runtime permission requests (call from a real screen) |
| `core/notifications/notification_scheduler.dart` | foreground | the seam `AuthProvider` calls into on login/logout |
| `core/notifications/fcm_service.dart` | foreground (+ FCM background isolate) | Firebase init, foreground/opened-app/background handlers, iOS permission (`requestIosPermission`), token registration (waits for the APNs token on iOS, one POST retry, single token-refresh listener) and un-registration |

Wired in: `main.dart` (`NotificationBootstrap.init()` and, in its OWN
try/catch so one failing can't skip the other, `FcmService.init()` before
`runApp`), `providers/auth_provider.dart` (`NotificationScheduler.onLoggedIn`
/ `onLoggedOut`; `FcmService.unregisterToken()` runs BEFORE the auth token
is cleared on logout — afterwards the DELETE would just 401 and the phone
would keep receiving the signed-out account's pushes),
`providers/notifications_provider.dart` (socket-driven live banner),
`screens/root/app_shell.dart` (`requestPermissions()` once the user is
actually inside the app). `NotificationBootstrap.requestPermissions()`
asks through `FcmService.requestIosPermission()` on iOS and through
permission_handler on Android.

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
gets a real app-side trigger. iOS now gets ALERT pushes through APNs, but
those are drawn by iOS itself and never run app code; an AlarmKit alarm
would additionally need a silent (`content-available`) push, which is
deliberately not enabled.

## iOS reality check

`android_alarm_manager_plus` has no iOS implementation — there is no
Android-equivalent way to make iOS honor a "poll every 15 minutes" clock
while backgrounded or killed. `flutter_background_service`'s
`onIosBackground` only gets an *opportunistic* window iOS grants at its
own discretion (frequently none for hours if the user hasn't opened the
app recently) via `BGAppRefreshTask` under the hood. On iOS, this pipeline
in practice means: notifications fire correctly while the app is open or
was very recently backgrounded, and are NOT reliable once it's been
backgrounded a while or force-quit. That is why iOS reliability rests on
the FCM **alert** push (see **What each platform receives**), not on this
poll — a silent (`content-available`) push is not a substitute either: iOS
throttles it and doesn't deliver it at all after a force-quit. The poll
stays on iOS only as a best-effort extra.
