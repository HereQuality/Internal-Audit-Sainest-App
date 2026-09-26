import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/constants/api_constants.dart';
import 'core/notifications/fcm_service.dart';
import 'core/notifications/local_notifications.dart';
import 'core/notifications/notification_bootstrap.dart';
import 'core/notifications/notification_navigation.dart';
import 'core/theme/app_theme.dart';
import 'providers/announcement_provider.dart';
import 'providers/app_mode_provider.dart';
import 'providers/app_update_provider.dart';
import 'providers/audits_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/dashboard_provider.dart';
import 'providers/filter_options_provider.dart';
import 'providers/maintenance_provider.dart';
import 'providers/nc_provider.dart';
import 'providers/notifications_provider.dart';
import 'providers/profile_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/tickets_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/root/app_shell.dart';
import 'screens/root/maintenance_block_screen.dart';
import 'screens/root/role_picker_screen.dart';
import 'screens/root/update_required_screen.dart';
import 'widgets/app_loading.dart';
import 'widgets/app_update/soft_update_overlay.dart';
import 'widgets/maintenance/maintenance_announcement_host.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Registers notification channels + the background_service isolate entry
  // point BEFORE runApp — a login that happens seconds after launch (auto-
  // login via a saved token, see AuthProvider.bootstrap) can otherwise race
  // NotificationScheduler.onLoggedIn against an uninitialized plugin.
  // Guarded: some devices (missing Play services, OEM battery managers
  // blocking foreground services, emulators) throw here — that must never
  // take the whole app down before a single frame has rendered. Worst case
  // without this try/catch was a silent crash at launch with no UI at all,
  // notifications being the only thing lost by skipping it.
  try {
    await NotificationBootstrap.init().timeout(const Duration(seconds: 5));
  } catch (e, st) {
    debugPrint(
      'NotificationBootstrap.init failed, continuing without it: $e\n$st',
    );
  }
  // Its own try/catch, NOT part of the block above: FCM has nothing to do
  // with the local-notification plugin, so a failed or timed-out local init
  // (a hung iOS platform-channel reply, an OEM blocking the foreground
  // service) must not also skip push setup for the whole launch. Firebase
  // not being set up yet still degrades to "no push", never a crash — see
  // FcmService's own doc comment. Giving up on the wait does not stop the
  // init: it keeps running, and the launch-tap read below waits for it, so a
  // slow Firebase start does not cost the tap that opened the app.
  try {
    await FcmService.init().timeout(const Duration(seconds: 5));
  } catch (e, st) {
    debugPrint('FcmService.init failed, continuing without push: $e\n$st');
  }
  // Set if the app process was NOT already running and got launched BY
  // tapping a notification (cold start) — see LocalNotifications
  // .consumeLaunchPayload's own doc comment for why this can't just navigate
  // immediately here. Held (not acted on) until _RootGate can: signed in and
  // past the update/maintenance gates. Each source is read on its own, with
  // its own timeout, so a hung platform-channel reply (seen on iOS with
  // flutter_local_notifications' getNotificationAppLaunchDetails under the
  // newer implicit-engine registration) neither blocks runApp() forever nor
  // costs the other source its read.
  holdNotificationTap(
    await resolveLaunchPayload(
      local: LocalNotifications.consumeLaunchPayload,
      fcm: FcmService.consumeLaunchPayload,
    ),
  );
  runApp(const InternalAuditApp());
}

class InternalAuditApp extends StatelessWidget {
  const InternalAuditApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()..bootstrap()),
        ChangeNotifierProvider(create: (_) => AppModeProvider()..bootstrap()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()..bootstrap()),
        ChangeNotifierProvider(create: (_) => AppUpdateProvider()..bootstrap()),
        ChangeNotifierProvider(create: (_) => MaintenanceProvider()..bootstrap()),
        ChangeNotifierProvider(create: (_) => AnnouncementProvider()..bootstrap()),
        ChangeNotifierProvider(create: (_) => DashboardProvider()),
        ChangeNotifierProvider(create: (_) => AuditsProvider()),
        ChangeNotifierProvider(create: (_) => NcProvider()),
        ChangeNotifierProvider(create: (_) => ProfileProvider()),
        ChangeNotifierProvider(create: (_) => NotificationsProvider()),
        ChangeNotifierProvider(create: (_) => TicketsProvider()),
        // Option lists for the Dashboard/Audits/Calendar filter sheet —
        // loaded lazily the first time a sheet opens, then cached.
        ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) => MaterialApp(
          title: 'Internal Audit',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeProvider.mode,
          // Lets a local-notification tap (see local_notifications.dart's
          // onDidReceiveNotificationResponse) navigate from outside any
          // screen's own BuildContext.
          navigatorKey: notificationNavigatorKey,
          home: const RootGate(),
          // Debug-only — every screen (login, Update Required, the app
          // itself) gets this same tiny strip showing which server the app
          // is actually talking to. Exists purely because "why isn't the
          // change I made on the web admin page showing up" turned out
          // repeatedly to be "this build is still pointed at the remote
          // dev server, not the local one" (see ApiConstants.baseUrl's own
          // doc comment on the --dart-define override) — this makes that
          // instantly visible instead of guessable. `kDebugMode` keeps it
          // out of release builds entirely, zero risk of a real user ever
          // seeing it.
          builder: kDebugMode
              ? (context, child) => Stack(
                    children: [
                      ?child,
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SafeArea(
                          top: false,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            color: Colors.black87,
                            child: Text(
                              'API: ${ApiConstants.baseUrl}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.amberAccent, fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
              : null,
        ),
      ),
    );
  }
}

// Public only so a test can mount it under its own providers.
@visibleForTesting
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> with WidgetsBindingObserver {
  // Tracks whether the LAST build was in the maintenance-blocked state, so
  // the forced pop-to-root below (see isBlocked handling) only fires on
  // the actual on-transition edge, not every rebuild while already blocked.
  bool _wasBlocked = false;
  // Same edge-only shape, for the filter-state reset below — every
  // provider in this app lives for the whole process (main.dart's root
  // MultiProvider never recreates them), so without an explicit reset on
  // logout a shared device's NEXT login would inherit the PREVIOUS
  // account's Team Filter selection, locations and cached people/location/
  // audit-type option lists. Edge-tracked so it fires once per actual
  // logout, not on every rebuild while already on the login screen (a
  // maintenance-status poll, a theme change).
  bool _wasAuthenticated = false;
  // Same edge-only pop-to-root shape as the maintenance gate below, for
  // the force-update gate.
  bool _wasUpdateBlocked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Same pattern as settings_screen.dart's own permission-status refresh —
  // whoever is sitting on the pre-login/Update-Required screen has no
  // socket yet (SocketService only connects post-login), so an admin
  // toggling Force Update off/on elsewhere never reaches them live. Without
  // this they'd only find out on the next 30s background poll (see
  // AppUpdateProvider's own `_pollInterval`) or a full app restart. Coming
  // back from the home-screen/app-switcher (locking the phone and
  // unlocking it, or switching apps and back) is the moment a real person
  // actually re-opens their attention to this screen, so re-checking right
  // then is what makes "the admin already fixed it" resolve itself instead
  // of needing an explicit "Check again" tap.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<AppUpdateProvider>().refreshNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final appMode = context.watch<AppModeProvider>();

    // Force-update gate — checked before EVERYTHING else, including
    // login: an old build may not even be able to talk to a changed API
    // contract, so unlike the maintenance gate below (which only applies
    // once authenticated) this can't wait for a session to resolve first.
    // No role bypass either — see AppUpdateProvider's own doc comment.
    final appUpdate = context.watch<AppUpdateProvider>();
    final updateBlocked = appUpdate.isForceUpdateRequired;
    if (updateBlocked && !_wasUpdateBlocked) {
      // Same reasoning as the maintenance gate's own pop-to-root: a no-op
      // if there's no pushed route yet (e.g. still on the login screen),
      // but pops back to root if this fires while several screens deep.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
      });
    }
    _wasUpdateBlocked = updateBlocked;
    if (updateBlocked) return const UpdateRequiredScreen();

    switch (auth.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: AppLoading());
      case AuthStatus.unauthenticated:
        _wasBlocked = false;
        if (_wasAuthenticated) {
          _wasAuthenticated = false;
          // Deferred exactly like the maintenance pop-to-root above/below
          // this switch: each resetForLogout() calls notifyListeners(),
          // and firing that synchronously from inside THIS widget's own
          // build would ask another still-building widget to rebuild
          // mid-build — a "setState()/markNeedsBuild() called during
          // build" framework error. A frame later is soon enough; nothing
          // reads these providers until AppShell mounts again on the next
          // login, long after this frame finishes.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Screens pushed over the shell (an audit, an NC, the profile)
            // would otherwise stay on top of the login screen after a
            // session that ended on its own (expiry, blocked account) —
            // showing the previous account's data to whoever is next.
            Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
            context.read<AuditsProvider>().resetForLogout();
            context.read<DashboardProvider>().resetForLogout();
            context.read<NcProvider>().resetForLogout();
            context.read<NotificationsProvider>().resetForLogout();
            context.read<FilterOptionsProvider>().resetForLogout();
            context.read<TicketsProvider>().resetForLogout();
            // A tap still waiting for its turn was that account's.
            clearHeldNotificationTap();
          });
        }
        return const SoftUpdateOverlay(child: LoginScreen());
      case AuthStatus.offline:
        _wasBlocked = false;
        return const _ServerUnreachableScreen();
      case AuthStatus.authenticated:
        _wasAuthenticated = true;
        if (!appMode.loaded) return const Scaffold(body: AppLoading());

        // Maintenance gate — checked before anything else past this point,
        // same spirit as the web app's App.jsx. SuperAdmin always bypasses
        // (server-side enforcement mirrors this — see
        // server/middlewares/maintenance.middleware.js).
        final maintenance = context.watch<MaintenanceProvider>();
        final isSuperAdmin = auth.user?.roleType == 'SuperAdmin';
        final isBlocked = maintenance.status.isActive && !isSuperAdmin;

        if (isBlocked && !_wasBlocked) {
          // Maintenance just kicked in while the user may be several
          // screens deep (Navigator.push — an audit detail, an NC
          // response — not just this root widget). Rebuilding _RootGate
          // alone only changes what's under those pushed routes; it does
          // NOT pop them away, so without this a blocked user could stay
          // fully interactive on whatever screen they already had open.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
          });
        }
        _wasBlocked = isBlocked;

        if (isBlocked) return const MaintenanceBlockScreen();

        // Every scoped list/stat endpoint sends `employeeIds=<self>` while
        // the Me scope is selected (the default — see AuditsProvider's own
        // isTeamScope), and each provider needs to be told which id that
        // is. Doing it here, once, on the authenticated build, rather than
        // in each screen's initState is what makes the default actually
        // hold everywhere: CalendarScreen and the notification-tap deep
        // links fetch without ever having gone through a dashboard, and a
        // provider that hasn't been told its own id silently falls back to
        // the full hierarchy instead. Plain field writes, no
        // notifyListeners, so this is safe to repeat on every rebuild.
        //
        // EXCEPT for a genuine SuperAdmin: auth.middleware.js resolves a
        // token against the `User` collection first and only falls back to
        // `Employee`, so a SuperAdmin's own `auth.user.id` is a `users`
        // document id that exists in NO `employees` document — sending it
        // as employeeIds=<id> isn't "just me", it's a filter that can
        // never match anything (resolveScopedEmployeeIds's `isUnfiltered`
        // branch returns whatever id was asked for VERBATIM, with no
        // intersection against real employees), so every list/stat would
        // silently read empty. Deliberately leaving `_selfEmployeeId`
        // unset for that one roleType is what makes the fallback further
        // down each provider's own `filterParams` do the right thing here:
        // no employeeIds param at all resolves server-side to "no filter"
        // (org-wide) — the same "all" a SuperAdmin's Me now falls back to
        // on web, see client/src/hooks/useSelfScope.js. A custom Role with
        // full access is NOT this case — it's still a real Employee
        // document with a real, matchable id, so it keeps going through
        // the branch below like any other employee.
        // isSuperAdmin is already computed above, for the maintenance
        // gate — same account field, reused rather than redeclared.
        final selfId = auth.user?.id;
        if (!isSuperAdmin && selfId != null && selfId.isNotEmpty) {
          context.read<AuditsProvider>().setSelfEmployeeId(selfId);
          context.read<DashboardProvider>().setSelfEmployeeId(selfId);
          context.read<NcProvider>().setSelfEmployeeId(selfId);
        }

        // Only now — logged in, not blocked, app shell about to actually
        // mount — is it safe to act on a cold-start-from-notification-tap:
        // the target screens (AuditDetailScreen, NcResponseScreen/
        // NcReviewScreen) assume an authenticated provider tree above
        // them, which doesn't exist a moment earlier. Pushed on TOP of
        // AppShell (not replacing it) so the back button still lands
        // somewhere real, same as tapping the equivalent in-app
        // notification row would.
        //
        // Also where a WARM tap that landed on a login / update / maintenance
        // screen is applied once those clear (see handleLocalNotificationTap).
        final heldTap = takeHeldNotificationTap();
        if (heldTap != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            handleLocalNotificationTap(heldTap);
          });
        }

        final content = appMode.mode == null ? const RolePickerScreen() : const AppShell();
        // The once-a-day scheduled-maintenance popup only makes sense for
        // people who'd actually be blocked by it later — skip it for
        // SuperAdmin, who set the schedule themselves. SoftUpdateOverlay
        // wraps this UNCONDITIONALLY (outside the isSuperAdmin ternary) —
        // it has no role bypass, same reasoning as the force-update gate
        // above: a SuperAdmin's device can be on an old build too.
        return SoftUpdateOverlay(
          child: isSuperAdmin ? content : MaintenanceAnnouncementHost(child: content),
        );
    }
  }
}

/// Shown while a saved session can't be confirmed because the server can't
/// be reached (no signal, a timeout, a deploy) — see AuthStatus.offline. Not
/// the login screen: the session is still good, asking for the password
/// again would need the very connection that is missing, and dropping it
/// would sign the person out of push as well. AuthProvider asks again by
/// itself (backoff, and every time the app comes to the foreground); the
/// buttons are for the impatient and for anyone who would rather leave.
class _ServerUnreachableScreen extends StatelessWidget {
  const _ServerUnreachableScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auth = context.watch<AuthProvider>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.cloud_off_outlined, size: 48, color: scheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    "Can't reach the server",
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "You're still signed in. We'll reconnect as soon as the connection is back.",
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.outline),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: auth.isBusy ? null : auth.retrySession,
                    icon: auth.isBusy
                        ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 18),
                    label: const Text('Try again'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: auth.isBusy ? null : () => auth.logout(),
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
