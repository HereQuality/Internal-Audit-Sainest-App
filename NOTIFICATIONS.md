# Notifications: server push, one banner per event, local fallback

The server is where notifications come from
(`server/services/notification.service.js#createNotification` is the only
funnel: in-app row + socket event + email + web push + phone push). The phone
gets each one through up to four routes, and the code makes sure it is ONE
banner:

- **FCM push** (`core/notifications/fcm_service.dart`) — real push through
  Firebase Cloud Messaging, arriving in every app state (foreground,
  background, killed) on both platforms. Android is sent a data-only
  message that this app draws; iOS is sent an alert push that iOS draws. It
  needs a real Firebase project (and, for iOS, an Apple APNs key) — see
  **FCM push setup** and **The Firebase project must match on both sides**.
- **Socket** (`providers/notifications_provider.dart`) — the `new_notification`
  event over the app's socket.io connection: what draws a banner in real
  time while the app is open on a phone the server cannot push to, and the
  fast path on Android.
- **Local polls** (`event_poll.dart`, `overdue_poll.dart`) — the phone asks
  `GET /audits/mine` and `GET /ncs/mine` about the signed-in person and derives
  audit assigned / NC raised / approved / rejected / overdue itself. They are
  the FALLBACK for a phone the server cannot push to, and the only source of
  `audit_reminder`, which no server job sends. On Android they run every 15
  minutes in a foreground service and at every launch/login; on iOS only at
  launch/login (iOS gives an app no background clock).

They are NOT independent any more: see **One banner per event** below. (An
earlier version of this document called the overlap of push and poll "a
one-time overlap, not a bug to chase". It was not one-time: the poll's dedup
state never learned about pushes, so every server-pushed event was announced
a second time, on Android at the next tick and on iOS at the next launch.)

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
socket banner asks; a type that is not in the catalog answers to the master
alone. The FCM renderers deliberately do NOT ask it (the server already
applied both switches, and a stale mirror would drop a push it approved) — they
only require a signed-in session. The polls read one `PushGate` per tick
(`refreshPushGate` in `event_poll.dart` re-fetches `GET /auth/me/preferences`
first, so a change made on the web reaches the killed-app service too).
Mapping of what a poll may show (as the fallback — see **One banner per
event**; the reminders are the poll's own):

| Local banner | Topic(s) that must be on |
|---|---|
| "New audit assigned" | `audit_created` AND `audit_reassigned` — a newly listed audit can be either, and the list can't say which |
| "Audit starting" / "Audit due" | `audit_reminder` — raised on the day the audit starts / is due, only while the app or the Android service runs; no server job sends them, and iOS never polls in the background. The row's copy says so, and that the Morning summary covers a closed app |
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

## A push that belongs to another account, and rows left behind

A token row the server still holds for an account that has left this phone keeps
delivering that account's pushes (iOS draws them itself, no Dart runs). Three
guards, all needed:

- **Rows are cleaned up.** `POST /device-tokens/register` takes an optional
  `replaces` (the token FCM just rotated away from; `FcmService._onTokenRefresh`
  sends it) and deletes that row for the same account, and keeps at most 5 rows
  per account and platform (oldest dropped) — a reinstall or a rotation that
  never said goodbye no longer leaves a row that outlives the logout.
- **Every FCM push names its owner.** `fcmPush.service.js#buildFcmMessage` adds
  `recipientId` to `data`. `renderDataPush` drops (draws nothing) a push whose
  `recipientId` is not the signed-in person, and a tap on a push addressed to
  someone else (`handleLocalNotificationTap`, carried as a third part of the
  tap payload, see `notificationPayloadRecipient`) opens nothing and says so —
  never "someone else's audit" under the current login.
- **The auditee is told as the auditee.** `audit_created` to the auditee no
  longer says "you've been assigned to audit" (it read as an auditor task and
  opened an audit that, in the auditor view, is not theirs).

## What each platform receives

`fcmPush.service.js` builds a different message per token `platform`:

| | Android | iOS |
|---|---|---|
| Shape | **data-only** (`title`/`body`/`type`/`referenceId`/`notificationId` in `data`, no `notification` block), `android.priority: high`, 24 h `ttl` | **alert push**: `notification` block + `apns` headers (`apns-push-type: alert`, `apns-priority: 10`, 24 h `apns-expiration`, a collapse id) + `aps.sound`; `data` carries `type`/`referenceId`/`notificationId` for tap routing |
| Drawn by | this app: `fcm_service.dart` renders a local notification (foreground listener + `fcmBackgroundMessageHandler`, a separate isolate when the app is not in the foreground) | iOS itself — banner + sound, even with the app force-quit. No Dart runs for the banner |
| `content-available` | n/a | deliberately NOT set — it would also wake the Dart background handler and double the banner |

Why iOS can't use data-only: a data-only message shows nothing on iOS; it
only arrives as a throttled silent push that isn't delivered at all once
the user force-quits the app. So on iOS the app must NOT render FCM
messages a second time:

- foreground: `setForegroundNotificationPresentationOptions(alert, badge,
  sound)` (in `FcmService.init`) makes iOS show the alert push while the
  app is open. `_handleForegroundMessage` does not draw it again — it only
  RECORDS it in the banner ledger, which is how the socket path learns iOS
  drew it (see below);
- `fcmBackgroundMessageHandler` returns early for any message with a
  `notification` block.

The handler registered with `FirebaseMessaging.onBackgroundMessage` is NOT
`fcmBackgroundMessageHandler` itself but the private
`_firebaseMessagingBackgroundHandler` in the same file, which only delegates to
it. The plugin persists a callback handle natively and Flutter maps it back to
a function by name and library, so after an app update the phone still holds the
old build's handle until the new build has launched once: the registered symbol
must keep the name earlier builds registered, or a push in that gap is dropped.
Never rename it. Log lines about a push carry its type and id only, never
`data` (`debugPrint` reaches logcat and the iOS unified log in release builds).

## One banner per event

**Who owns what.** Everything the server pushes — audit assigned / series /
reassigned / skipped / completed / overdue, NC raised / responded / approved
/ rejected / overdue, both daily summaries, tickets — is owned by the
server: FCM and the socket draw it. Only `audit_reminder` (start / due
reminders) is owned by the phone. The polls announce a server-owned event only
as a fallback (below).

**The banner ledger.** Every route that draws a server notification goes
through `LocalNotifications.showServerBanner`, which first *claims* it in a
shared ledger (`NotificationPrefs.claimBanner`, SharedPreferences with a
`reload()` before every read, so it is shared across the app's isolates):

| Ledger key | Meaning | Used by |
|---|---|---|
| `n:<notificationId>` | the server's own id (the Mongo `_id`; FCM's `notificationId` and the socket `_id` are the same value) | socket vs FCM, exact |
| `e:<type>\|<referenceId>` | the EVENT (only for the types a poll can derive: audit created / series / reassigned, NC raised / approved / rejected / overdue) | a poll, which only knows "this audit / NC changed" |

Whoever claims first draws it; the others stay quiet. Entries are bounded
(300, 3 days). If drawing fails the claim is given back so another route can
still show it. Every route also uses the same tray id
(`LocalNotifications.serverNotificationId`, a hash of the notification id) and
posts `onlyAlertOnce`, so the residual race (two isolates interleaving their
read-modify-write and both drawing) updates one tray entry silently instead
of stacking or buzzing twice.

**Route by route:**

| App state | Android | iOS |
|---|---|---|
| Foreground | socket + FCM foreground callback both call `showServerBanner`; the first draws, the second is dropped | iOS draws the alert push; the FCM foreground callback records it in the ledger. The socket path waits up to `FcmService.nativeAlertGrace` (4 s) for that record and draws its OWN banner only if none arrived (broken APNs setup, dropped push) and the app is still in the foreground |
| Background (process alive) | FCM background isolate + the socket (if still connected) → ledger | iOS draws it natively and nothing runs in Dart. While the phone is registered for push the socket path stays quiet (there is nothing to add, and a banner from a socket that outlived the foreground would repeat the OS's); on a phone the server can't push to it still draws |
| Killed | FCM background isolate | iOS draws it natively |

The socket-driven banner is also gated by the switches mirror
(`readPushAllowed`: master AND topic). The FCM renderers deliberately are not
(the server already applied both switches, and a mirror that is stale after a
switch turned ON from the web while the app was killed would drop a push the
server approved) — they check only that somebody is signed in.

**Why iOS still lets the OS draw the foreground push.** The cleaner-looking
design is to switch the foreground presentation options off and draw one local
banner from whichever of socket / FCM `onMessage` arrives first. It was
checked against `firebase_messaging` 16.7.0's iOS source and is NOT safe
without a native change: the plugin answers iOS's `willPresent` for EVERY
notification with those (global) options — including the local ones
`flutter_local_notifications` posts (whose own `willPresent` answers only for
notifications it created) — and it is registered before it (see
`GeneratedPluginRegistrant.m`), so in the AppDelegate's first-reply-wins
handler its answer most likely comes first (the Flutter engine's fan-out order
is not something that could be read from source here). With the options off,
every foreground banner (the socket fallback, the polls) would then be
swallowed. It needs
`AppDelegate.swift`'s `willPresent` to tell a remote push (`gcm.message_id` in
`userInfo`) from a local one and answer differently; that is a Swift change
that has to be tried on a real iPhone. Until then the app relies on evidence
rather than a static assumption: it does not suppress its own banner just
because a token is registered (which turned a misconfigured APNs key into a
totally silent foreground iPhone), it waits to see whether iOS actually drew
the push.

**The polls are a fallback, not a second announcer.** A poll shows a banner for
a server-owned event only when ALL hold:

1. the account's master switch and that event's topic are on;
2. the server cannot be counted on to have told the person — while
   `NotificationPrefs.readFcmPushReady()` is true it is the server's job, and the
   poll only keeps its bookkeeping (seen ids, last statuses, notified NCs), so
   flipping the flag off later never dumps a backlog;
3. no server banner for that event was already drawn on this phone
   (`consumeServerEvent` — one recorded banner covers one observed change, so
   an NC rejected twice is two events).

`bg_fcm_push_ready` is written by `FcmService`: set when the server accepts this
phone's token and doesn't say `pushReady: false`; cleared by sign-out, by a token
refresh until the new token is registered, by the server saying it cannot
send, and by a Settings "Send a test notification" that the server reports as
undeliverable to this phone (a phone with a missing APNs key registers fine and
then every send fails — only a real send reveals it; a later successful test
clears the mark, and so does signing out). "Audit starting" / "Audit due" are
the poll's own and follow only their topic.

Limitation, fallback mode only: a recurring series is ONE server push
(`audit_series_created`, referenceId = its first occurrence) but the audit
list shows every occurrence, and the list cannot tell "a series was created"
from "I was reassigned to it" — so on a phone the server cannot push to, the
first occurrence is matched to the push and the rest each announce as "New
audit assigned". While the server can push, none of it announces.

**The polls fetch only the signed-in person's own items** (`employeeIds=<self>`,
like the app's own screens). Without the parameter the server answers with the
whole reporting hierarchy (a manager's team) or, for SuperAdmin / full-access
accounts, the organisation, and each of those would have read as "assigned to
you". With no known user id a poll does not run at all (never the unscoped
fallback). A SuperAdmin's id is a users-collection id that matches no audit or
NC, so their scoped lists are simply empty.

**Master switch back ON does not dump what happened while it was OFF.** While
the master is off the Android service stops itself and iOS never polled in the
background, so the polls' "already seen" state stops advancing. Writing the
master OFF (`NotificationPrefs.setPushEnabled(false)`) therefore marks both
polls suspended (`bg_polls_suspended`); the first tick after the switch is back
ON is a catch-up (`PollPlan.catchUp`): it records everything and announces
nothing, and only a tick that read the lists successfully ends it. This is
persisted, not in memory, because the pass runs in whichever isolate polls first.
(A per-topic OFF needs none of this: the polls keep running and record.)

**A session the server refused.** The polls authenticate with the mirrored
token, a 1-day JWT on phones. Once it expires every poll request is a 401 that
no later tick can fix; that is remembered (`markSessionRejected`) and the
foreground service stops itself instead of "Watching for overdue NCs" while doing
nothing. FCM is not affected (it doesn't use the JWT). The next login brings a
new token and starts the service again. The consequence for `audit_reminder`
on Android is that it can only appear while the mirrored token is valid — up to a
day after the last login; making that longer is a server decision (a longer
phone session, or a refresh route).

**Switches, layer by layer** (OFF means nothing from ANY layer):

| Switch | Server | Socket banner | FCM renderers | Polls |
|---|---|---|---|---|
| Master Push OFF | no FCM / web push | silent (mirror) | nothing arrives; a message already in flight is drawn | silent, and the service stops; catch-up on ON |
| Topic Push OFF | none for that type | silent (mirror) | nothing arrives | silent for it; bookkeeping continues |
| Master / topic ON | sends at once | mirror refreshed by `preferences_updated` / resume | works at once, no re-login | announces only what is new after the catch-up |
| OS permission denied | still sends | nothing can be drawn | nothing can be drawn | not started |
| Signed out | token unregistered | socket disconnected | dropped (no session) | stopped |

The switch mirrors are `notif_push_enabled` / `notif_push_types` (see the
table above).

## Real-time: what the code guarantees and what it can't

Guaranteed by the design (and covered by tests): one banner per notification
whichever routes deliver it; nothing suppressed on the strength of a
registration alone; the Android FCM path is as short as it can be — a cold
isolate that touches no Firebase API and does the light notification init
(plugin + the two high-importance channels, no timezone database) before
drawing.

Not something app code can guarantee, and never measured on a device here (this
was all verified by reading code and by tests; only a real Android and a real
iPhone can prove "within seconds"):

- **Android killed state** needs the data push to reach a cold Dart isolate.
  "Force stop" in system settings stops the app receiving FCM at all until it
  is opened again. Xiaomi/Oppo/Vivo/Huawei/Samsung-style battery managers may
  block background start unless the app is allowed to auto-start / run
  unrestricted. Nothing in the app asks for battery-optimisation exemption or
  explains OEM settings yet.
- **Blocked channel or notification permission.** A banner posted while the
  OS-level `App Updates` / `Overdue NCs` channel is switched off, or
  POST_NOTIFICATIONS is denied, is dropped silently by Android while
  Settings still reads "Active". Settings reads only the app-level permission.
- **FCM delivery itself** is best effort (Doze, pending-message limits).
  Android's `ttl` and iOS's `apns-expiration` are 24 h.
- **iOS** works only once the Firebase project matches on both sides and the
  APNs key is uploaded (below); until then the server drops every iOS push
  and the app falls back to the socket banner (foreground) and the launch-time
  poll.

To measure it: on a real Android, `adb shell am force-stop` is NOT a valid
"killed" test (it also blocks FCM); swipe the app away from Recents, lock
the phone, trigger an event on the server and time it. Repeat with the app
open, backgrounded, and with Push switched off then on (nothing while off; the
next event after ON, without logging in again). Check
`adb shell dumpsys notification | grep -A3 app_events` for the channel's
importance.

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

The registration is retried in the foreground with backoff (5 s, 30 s, 2 min),
and again when the app returns to the foreground or the socket reconnects
(`FcmService.ensureRegistered`) if the login-time attempt failed or the
permission was granted later, instead of waiting for the next login. A test that
the server reports as undeliverable to this phone also puts the fallback layers
back on (see **One banner per event**).

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
   sends a test push to the caller's OWN tokens only (the app's Settings check
   sends `{"token": <this phone's FCM token>}` so only this phone is tested) and returns
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
| `core/notifications/notification_prefs.dart` | any isolate | SharedPreferences-backed state, the only thing background isolates can reach (no Provider/DI): the session token + user id, the poll dedup sets, the `notif_push_enabled` / `notif_push_types` mirrors of the account's push switches, the topic catalog (`kNotificationTopics`), the banner ledger (`claimBanner` / `consumeServerEvent`), `bg_fcm_push_ready`, `bg_polls_suspended`, and the rejected-session marker |
| `core/notifications/local_notifications.dart` | any isolate | `flutter_local_notifications` init (`init()` = plugin + channels + timezone data for the app; `initLight()` = plugin + channels only, what the FCM background isolate uses), `showServerBanner` (claim, then draw), the per-type poll banners, `showOverdueNc` / `showFullScreenAlarm` |
| `core/notifications/event_poll.dart` | any isolate | `pollAndNotifyEvents()` — new audit / audit start & due / NC raised / approved / rejected, plus `PollPlan`, `refreshPushGate`, and the shared authenticated GET (`pollGetJson`) |
| `core/notifications/overdue_poll.dart` | any isolate | `pollAndNotifyOverdueNcs()` — `GET /ncs/mine`, diff against already-notified, show as one consolidated banner |
| `core/notifications/background_entrypoints.dart` | service isolate | the Android foreground service (`flutter_background_service`): one poll at start, then `Timer.periodic(15 min)`; `serviceShouldRun` decides whether it exists at all |
| `core/notifications/notification_bootstrap.dart` | foreground | one-time plugin init (call from `main()`) + runtime permission requests (call from a real screen) |
| `core/notifications/notification_scheduler.dart` | foreground | the seam `AuthProvider` calls into on login/logout and on a push-switch change |
| `core/notifications/fcm_service.dart` | foreground (+ FCM background isolate) | Firebase init, the foreground listener and `fcmBackgroundMessageHandler`, iOS permission (`requestIosPermission`), token registration (waits for the APNs token on iOS, in-place retry plus foreground backoff, one token-refresh listener), sign-out unregistration (explicit-JWT DELETE, retry note, `deleteToken` fallback) and the persisted "the server can push to this phone" flag |

Wired in: `main.dart` (`NotificationBootstrap.init()` and, in its OWN
try/catch so one failing can't skip the other, `FcmService.init()` before
`runApp`), `providers/auth_provider.dart` (`NotificationScheduler.onLoggedIn`
/ `onLoggedOut`; one teardown for every way a session ends: it reads the JWT it
still holds first, disconnects the socket, and unregisters the FCM token with
that JWT sent explicitly — the server accepts an expired, validly signed
one for exactly that DELETE — then stops the poll, clears the session mirror
and the notification tray. A DELETE that can't reach the server is kept and
retried at the next launch; if the server refuses or can't be reached,
`FirebaseMessaging.deleteToken()` is the fallback), `providers/
notifications_provider.dart` (the socket-driven banner and the badge),
`screens/root/app_shell.dart` (`requestPermissions()` once the user is
actually inside the app). `NotificationBootstrap.requestPermissions()`
asks through `FcmService.requestIosPermission()` on iOS and through
permission_handler on Android. A notification TAP is held while signed out,
offline, or on the update / maintenance screen, and applied by `main.dart`'s
root gate once it clears.

## What keeps the Android fallback alive

There is no AlarmManager chain in this app (an earlier version of this document
described `alarmTick` / `watchdogTick` / `kTickAlarmId`; none of that was ever
implemented, there is no `android_alarm_manager_plus` in `pubspec.yaml`, and
nothing here calls `zonedSchedule`, so there are also no scheduled
notifications to cancel when push is switched off). The only local mechanism
is ONE foreground service:

- `flutter_background_service` runs `backgroundServiceOnStart` as a foreground
  service (type `dataSync`, with a persistent "Watching for overdue NCs"
  notification — a visible foreground service is treated very differently from
  a bare background process by OEM battery managers). It polls once when it
  starts, then every 15 minutes from a `Timer.periodic` in the service isolate.
- It exists only while it has a job: someone is signed in, the master push
  switch is on, and the session was not refused (`serviceShouldRun`). It is
  started at login, when push is switched on, and every time the app comes to
  the foreground; it stops itself on logout, on push OFF, on a 401 (see **A
  session the server refused**), and — on Android 15+ only — after
  `kServiceMaxRuntime` (5 h) without the app being in the foreground.
  Android 15+ gives a `dataSync` service about 6 h in the background and kills
  the WHOLE app process if it doesn't stop when time is up, and the plugin has
  no `onTimeout` hook to stop it gracefully. Earlier releases have no such
  timeout, so the service runs on there. The service's isolate cannot ask the
  OS which release it is on: `MainActivity` answers `sdkInt` on the
  `com.hqepl.audit360/device` channel, the UI isolate leaves it in the prefs
  each time it starts the service (`recordAndroidSdk`), and until it is known
  the cap applies. It restarts on the next foreground. FCM keeps delivering
  while it is stopped; only the local fallback pauses.
- No start at boot: `BootReceiver` is removed from the merged manifest and
  `autoStartOnBoot` is false, so a reboot or app update does not bring up a
  service (and its notification) for a phone nobody is signed in on. It comes back
  when the app is opened.
- `flutter_background_service` also keeps its own native watchdog alarm that
  respawns the service if the process dies while it should be running (from
  reading its 6.3.1 source; it is not configured here). What nothing detects is
  a live-but-frozen Dart timer under an aggressive OEM battery manager — the
  15-minute poll just stops until the app is opened. That is the honest limit of
  the fallback; FCM is the real-time path.

## Testing it for real

1. Log in on a physical Android device (emulators fake Doze behaviour
   unreliably) and grant the notification permission. Check the Firebase side
   first: **Settings → Send a test notification** (it targets this phone's own
   token) must say "Test notification sent".
2. **FCM, app killed.** Swipe the app away from Recents (NOT
   `adb shell am force-stop`, which also blocks FCM until the app is opened),
   lock the phone, and trigger an event on the server (assign an audit, raise
   an NC). One banner should arrive within seconds. Repeat with the app open
   (one banner, not two) and just backgrounded.
3. **Switches.** Turn Push OFF in Settings: trigger events — nothing. Turn it ON
   again without logging in: the next event arrives at once, and the events
   from the OFF period do NOT appear as banners (they are in the bell list).
   Turn one topic OFF: only that topic goes quiet.
4. **Logout.** Log out, trigger an event for that account: nothing on the
   phone. Log in as someone else: only their events.
5. **Local fallback (Android).** With the app signed in and the server
   unable to push (or FCM not registered), set an NC's `targetDate` to a few
   minutes in the past for the logged-in employee (see
   `server/seed/seedFullTestData.js` for ids/usernames) and wait up to 15
   minutes; the overdue banner should come from the poll. `adb shell dumpsys
   activity services | grep BackgroundService` shows whether the service is
   running.

Do not read a banner that shows up ~15 minutes after an event as proof that push
works: that is the poll. While the phone is registered for push
(`bg_fcm_push_ready`) the polls do not announce audit assigned / NC raised /
approved / rejected / overdue at all, precisely so a tester can no longer
mistake the fallback for the server path (before this, on Android the poll
masked any event the server forgot to push, while iOS, which polls only at
launch, simply missed it).

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
  user toward that settings screen.
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

iOS has no equivalent of the Android foreground service: there is no way to
make it honour a "poll every 15 minutes" clock while the app is backgrounded
or killed. The `onIosBackground` handler in `background_entrypoints.dart` is
never registered (`configureBackgroundService` runs on Android only), so the
polls run on iOS at launch and login only. On iOS, this fallback in practice
means: while the app is open, and at each launch, on a phone the server cannot
push to. That is why iOS reliability rests on the FCM **alert** push (see
**What each platform receives**), not on the poll — a silent
(`content-available`) push is not a substitute either: iOS throttles it and
doesn't deliver it at all after a force-quit.

Consequences worth knowing:

- **Nothing reaches a closed iPhone until the Firebase project matches and the
  APNs key is uploaded** (the known blocker: `GoogleService-Info.plist` names a
  different project than the server's service account, so the server drops every
  iOS push). Until then an open iPhone still gets the socket banner, and a
  launch runs the poll fallback.
- `audit_reminder` ("Audit starting" / "Audit due") has no server path, so on
  iOS it appears only at launch/login — with the app closed, the **Morning
  summary** (09:00 IST, lists what starts and is due today; skipped on holidays
  and weekly-off days) is the push that tells you. Scheduling local notifications
  from the audits list was considered and not built: iOS would fire them with no
  Dart running, so a Push/topic switch turned OFF on the web while the app is
  killed would not stop them, which breaks "OFF means nothing from any layer".
  The reliable option is a push-only server sender for `audit_reminder`
  (`resolveChannels` already treats it as push-only, so it would never be
  emailed), retiring the poll's reminder banners in the same change so Android
  does not double up.
- Follow-up to make the foreground banner iOS-native and single without waiting
  for the socket: `AppDelegate.swift`'s `willPresent` answering "no alert" for
  remote pushes (`gcm.message_id` in `userInfo`) and banner+sound for local
  ones, then `setForegroundNotificationPresentationOptions(alert: false, ...)`.
  See **Why iOS still lets the OS draw the foreground push**.
