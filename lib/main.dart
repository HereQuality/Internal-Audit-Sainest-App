import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/notifications/fcm_service.dart';
import 'core/notifications/local_notifications.dart';
import 'core/notifications/notification_bootstrap.dart';
import 'core/notifications/notification_navigation.dart';
import 'core/theme/app_theme.dart';
import 'providers/announcement_provider.dart';
import 'providers/app_mode_provider.dart';
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
import 'widgets/app_loading.dart';
import 'widgets/maintenance/maintenance_announcement_host.dart';

// Set once, before runApp, if the app process was NOT already running and
// got launched BY tapping a notification (cold start) — see
// LocalNotifications.consumeLaunchPayload's own doc comment for why this
// can't just navigate immediately here. Null on an ordinary launch, or
// once _RootGate has already consumed it (see below) so it doesn't
// re-fire on some later unrelated rebuild.
String? _pendingLaunchPayload;

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
    // Own try/catch internally (Firebase project not set up yet degrades
    // to "no push", never a crash — see FcmService's own doc comment) —
    // called here regardless so [consumeLaunchPayload] below has a chance
    // to actually resolve once it IS set up.
    await FcmService.init().timeout(const Duration(seconds: 5));
    // Timeouts guard against a hung platform-channel reply (seen on iOS
    // with flutter_local_notifications' getNotificationAppLaunchDetails
    // under the newer implicit-engine registration) — without them, an
    // unresolved await here blocks runApp() forever: no crash, no error,
    // just the native launch screen staying up indefinitely.
    _pendingLaunchPayload =
        await LocalNotifications.consumeLaunchPayload().timeout(const Duration(seconds: 3)) ??
        await FcmService.consumeLaunchPayload().timeout(const Duration(seconds: 3));
  } catch (e, st) {
    debugPrint(
      'NotificationBootstrap.init failed, continuing without it: $e\n$st',
    );
  }
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
          home: const _RootGate(),
        ),
      ),
    );
  }
}

class _RootGate extends StatefulWidget {
  const _RootGate();

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> {
  // Consuming _pendingLaunchPayload is one-shot — a rebuild triggered by
  // anything else (theme change, a later logout/login) must not re-fire
  // the same cold-start navigation a second time.
  bool _consumedLaunchPayload = false;
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final appMode = context.watch<AppModeProvider>();

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
            context.read<AuditsProvider>().resetForLogout();
            context.read<DashboardProvider>().resetForLogout();
            context.read<NcProvider>().resetForLogout();
            context.read<FilterOptionsProvider>().resetForLogout();
          });
        }
        return const LoginScreen();
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
        if (!_consumedLaunchPayload && _pendingLaunchPayload != null) {
          _consumedLaunchPayload = true;
          final payload = _pendingLaunchPayload;
          _pendingLaunchPayload = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            handleLocalNotificationTap(payload);
          });
        }

        final content = appMode.mode == null ? const RolePickerScreen() : const AppShell();
        // The once-a-day scheduled-maintenance popup only makes sense for
        // people who'd actually be blocked by it later — skip it for
        // SuperAdmin, who set the schedule themselves.
        return isSuperAdmin ? content : MaintenanceAnnouncementHost(child: content);
    }
  }
}
