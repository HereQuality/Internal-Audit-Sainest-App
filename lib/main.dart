import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/notifications/local_notifications.dart';
import 'core/notifications/notification_bootstrap.dart';
import 'core/notifications/notification_navigation.dart';
import 'core/theme/app_theme.dart';
import 'providers/announcement_provider.dart';
import 'providers/app_mode_provider.dart';
import 'providers/audits_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/dashboard_provider.dart';
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
    await NotificationBootstrap.init();
    _pendingLaunchPayload = await LocalNotifications.consumeLaunchPayload();
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final appMode = context.watch<AppModeProvider>();

    switch (auth.status) {
      case AuthStatus.unknown:
        return const Scaffold(body: AppLoading());
      case AuthStatus.unauthenticated:
        _wasBlocked = false;
        return const LoginScreen();
      case AuthStatus.authenticated:
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
