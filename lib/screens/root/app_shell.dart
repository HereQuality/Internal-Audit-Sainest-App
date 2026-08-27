import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/notifications/notification_bootstrap.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/app_mode_provider.dart';
import '../../providers/audits_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';
import '../../providers/notifications_provider.dart';
import '../audits/my_audits_screen.dart';
import '../calendar/calendar_screen.dart';
import '../dashboard/auditee_dashboard_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../nc/nc_list_screen.dart';
import '../notifications/notifications_screen.dart';
import '../profile/profile_screen.dart';

/// Restricted tab set per AppMode — Profile is deliberately NOT one of
/// these tabs (it's shared/identical for both modes), it's reached via
/// the app-bar avatar instead. See AppModeProvider for why the mode
/// itself is a local UI choice, not a real permission.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  // Drives the swipe-between-tabs body below (PageView) — the
  // NavigationBar's own tap-to-switch still works too, it just animates
  // this same controller to the tapped page instead of a bare setState,
  // same as WhatsApp's tab bar being tap- AND swipe-driven off one
  // underlying controller.
  final PageController _pageController = PageController();

  // Pending status filter for a dashboard-stat-tile jump into the Audits
  // tab (auditor mode only) or the NC tab (both modes) — see _goToTab.
  // Each token bumps on every explicit filter request, even a repeat of
  // the same filter string, so MyAuditsScreen/NcListScreen below always
  // remount under a fresh ValueKey and re-apply it (a plain widget-field
  // change wouldn't retrigger anything once that filter's already showing
  // and the user has since picked a different chip by hand).
  String? _auditsFilter;
  int _auditsFilterToken = 0;
  String? _ncFilter;
  int _ncFilterToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final notifications = context.read<NotificationsProvider>();
      notifications.startListening();
      notifications.fetchUnreadCount();
      context.read<NcProvider>().startListening();
      context.read<AuditsProvider>().startListening();
      context.read<DashboardProvider>().startListening();
      // Best-effort — a denial here just means overdue-NC reminders may be
      // late/absent; the rest of the app works identically either way.
      NotificationBootstrap.requestPermissions();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // Shared by the bottom bar's tap handler and each dashboard's
  // onNavigateToTab (stat tiles jumping straight to another tab, optionally
  // pre-applying that tab's own status filter) — animates the PageView to
  // the target page; onPageChanged (below) is what actually updates
  // `_index` once the animation/swipe settles, same single source of truth
  // either way it got triggered. `filter` is only ever non-null for an
  // explicit stat-tile tap (the bottom bar itself never passes one), so a
  // plain tab switch never disturbs whatever filter chip a screen already
  // has selected.
  void _goToTab(int i, {String? filter}) {
    if (filter != null) {
      final mode = context.read<AppModeProvider>().mode ?? AppMode.auditor;
      final isAuditor = mode == AppMode.auditor;
      setState(() {
        if (isAuditor && i == 1) {
          _auditsFilter = filter;
          _auditsFilterToken++;
        } else if ((isAuditor && i == 2) || (!isAuditor && i == 1)) {
          _ncFilter = filter;
          _ncFilterToken++;
        }
      });
    }
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        i,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      setState(() => _index = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unreadCount = context.watch<NotificationsProvider>().unreadCount;
    final mode = context.watch<AppModeProvider>().mode ?? AppMode.auditor;
    final isAuditor = mode == AppMode.auditor;

    final titles = isAuditor
        ? const ['Auditor Dashboard', 'Audits', 'NC Monitoring']
        : const ['Dashboard', 'NCs'];
    final tabs = isAuditor
        ? [
            // Passed to each dashboard so its stat tiles can jump straight
            // to the relevant tab (optionally with that tab's own status
            // filter pre-applied) instead of just displaying a number to
            // look at. The two list screens below remount under a fresh
            // key on every explicit filter request (_auditsFilterToken/
            // _ncFilterToken) so the jump always takes effect.
            DashboardScreen(onNavigateToTab: _goToTab),
            MyAuditsScreen(key: ValueKey('audits-$_auditsFilterToken'), initialStatusFilter: _auditsFilter),
            NcListScreen(key: ValueKey('nc-$_ncFilterToken'), mode: NcListMode.auditorOnly, initialStatusFilter: _ncFilter),
          ]
        // Auditee mode gets its own NC-tallies dashboard, not the auditor
        // one's assigned/in-progress AUDIT stats — those mean nothing to
        // someone who isn't performing audits right now.
        : [
            AuditeeDashboardScreen(onNavigateToTab: _goToTab),
            NcListScreen(key: ValueKey('nc-$_ncFilterToken'), mode: NcListMode.auditeeOnly, initialStatusFilter: _ncFilter),
          ];
    // Each tab wrapped to stay alive off-screen (scroll position, filter
    // chips, etc. survive a swipe away and back) — PageView, unlike the
    // IndexedStack this replaces, disposes an offscreen page's state by
    // default.
    final keepAliveTabs = tabs.map((t) => _KeepAlivePage(child: t)).toList();
    final destinations = isAuditor
        ? const [
            NavigationDestination(
              icon: Icon(Icons.space_dashboard_outlined),
              selectedIcon: Icon(Icons.space_dashboard),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.assignment_outlined),
              selectedIcon: Icon(Icons.assignment),
              label: 'Audits',
            ),
            NavigationDestination(
              icon: Icon(Icons.fact_check_outlined),
              selectedIcon: Icon(Icons.fact_check),
              label: 'NC Monitoring',
            ),
          ]
        : const [
            NavigationDestination(
              icon: Icon(Icons.space_dashboard_outlined),
              selectedIcon: Icon(Icons.space_dashboard),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.report_gmailerrorred_outlined),
              selectedIcon: Icon(Icons.report_gmailerrorred),
              label: 'NCs',
            ),
          ];

    final safeIndex = _index < tabs.length ? _index : 0;

    return PopScope(
      // AppShell is always the (only) route in the stack while it's on
      // screen — see main.dart's _RootGate, which swaps it in/out of
      // `home` rather than pushing/popping it. So a bare pop here would
      // just close the app. Instead, back should behave like the nav
      // hierarchy the bottom bar implies: off Dashboard, it steps back to
      // Dashboard; on Dashboard, it steps back out to the role picker
      // (same flow as Profile → Switch Role). Screens pushed on top of a
      // tab (NC/audit detail, Profile, etc.) are separate routes and keep
      // their own default pop behavior untouched by this.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (safeIndex != 0) {
          _goToTab(0);
        } else {
          switchRole(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(titles[safeIndex]),
          actions: [
            IconButton(
              tooltip: 'Calendar',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CalendarScreen()),
              ),
              icon: const Icon(Icons.calendar_month_outlined),
            ),
            IconButton(
              tooltip: 'Notifications',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NotificationsScreen()),
              ),
              icon: Badge(
                label: Text(unreadCount > 99 ? '99+' : '$unreadCount'),
                isLabelVisible: unreadCount > 0,
                backgroundColor: AppColors.red,
                textColor: Colors.white,
                child: const Icon(Icons.notifications_outlined),
              ),
            ),
            IconButton(
              tooltip: 'Profile',
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
              icon: const Icon(Icons.person_outline),
            ),
            const SizedBox(width: 4),
          ],
        ),
        // Swipeable, like WhatsApp's tab bar — the NavigationBar below
        // still works by tap too (_goToTab animates this same controller
        // either way), this just also lets a left/right drag switch tabs.
        body: PageView(
          controller: _pageController,
          onPageChanged: (i) => setState(() => _index = i),
          children: keepAliveTabs,
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: safeIndex,
          onDestinationSelected: _goToTab,
          destinations: destinations,
        ),
      ),
    );
  }
}

/// Keeps one PageView page's whole widget subtree alive while another tab
/// is showing — without this, PageView disposes an offscreen page's state
/// (scroll position, MyAuditsScreen's/NcListScreen's own selected status
/// filter chip, in-flight list data, etc.) the moment it scrolls far enough
/// away, unlike the IndexedStack this replaced, which always kept every
/// tab's state resident.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({required this.child});

  final Widget child;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
