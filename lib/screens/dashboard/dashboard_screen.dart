import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_status.dart';
import '../../core/utils/responsive.dart';
import '../../models/audit_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/audits_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_section.dart';
import '../../widgets/audit_filter_bar.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/auditor_scorecard.dart';
import '../../widgets/max_width_scroll.dart';
import '../../widgets/stat_card.dart';
import '../../widgets/today_audits_section.dart';

/// screens/dashboard/dashboard_screen.dart
/// ───────────────────────────────────────
/// The auditor-mode Dashboard tab: ATS/OTC scorecard, the audit-status
/// tallies (one per lifecycle status), and the "what needs attention" audit panel — all of them read
/// through the SAME filter state (see providers/audit_filter_scope.dart),
/// so the header bar at the top of this screen is the one place that
/// decides what every number below it is counting.
class DashboardScreen extends StatefulWidget {
  /// Lets a stat tile jump straight to the tab it summarizes (e.g. "NC
  /// Pending" -> the NC Monitoring tab), optionally pre-applying that
  /// tab's own status filter (e.g. "Overdue" -> the Audits tab already
  /// showing just Overdue) instead of landing on an unfiltered list.
  /// Index is within AppShell's auditor tab set (0 Dashboard, 1 Audits,
  /// 2 NC Monitoring).
  final void Function(int tabIndex, {String? filter})? onNavigateToTab;

  const DashboardScreen({super.key, this.onNavigateToTab});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Must be set before the first fetch below — see DashboardProvider/
      // AuditsProvider's _scopeParams (Me defaults to explicit
      // employeeIds=<selfId>, which needs this to actually be known).
      final selfId = context.read<AuthProvider>().user?.id;
      if (selfId != null) {
        context.read<DashboardProvider>().setSelfEmployeeId(selfId);
        context.read<AuditsProvider>().setSelfEmployeeId(selfId);
      }
      context.read<DashboardProvider>().fetchStats();
      // Same list My Audits/Calendar already fetch (AuditsProvider.audits)
      // — reused here just to answer "what's on today" without a second,
      // dashboard-only endpoint.
      context.read<AuditsProvider>().fetchMyAudits();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardProvider>();
    final showFullLoader = dashboard.isLoading && !dashboard.hasLoadedStats && dashboard.errorMessage == null;
    final user = context.watch<AuthProvider>().user;
    final auditsProvider = context.watch<AuditsProvider>();

    return RefreshIndicator(
      onRefresh: () => Future.wait([
        context.read<DashboardProvider>().fetchStats(),
        context.read<AuditsProvider>().fetchMyAudits(),
      ]),
      // Wraps the WHOLE CustomScrollView (not each sliver individually) —
      // see MaxWidthScroll's own doc for why that's the right level for a
      // sliver tree: the cap only ever touches width, so it can't disturb
      // this scroll view's (purely vertical) behavior.
      child: MaxWidthScroll(
        child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome back${user != null && user.name.isNotEmpty ? ',' : ''}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  if (user != null && user.name.isNotEmpty)
                    Text(
                      user.name,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                ],
              ),
            ),
          ),
          // Me (default) vs Team (self + downstream hierarchy), plus the
          // people/location/audit-type sheet behind the Filters button —
          // together they scope everything below: the ATS/OTC score, the
          // stat tallies and the audit sections. See DashboardProvider.
          // setTeamScope and AuditFilterScope.applyFilters.
          //
          // Deliberately OUTSIDE the loading/error branch below (the lone
          // toggle used to sit inside it): applying a filter is exactly
          // what puts this screen into isLoading, so leaving the bar in
          // there made the control the user just touched — and the chips
          // saying what they picked — vanish for the length of the
          // refetch. It also has to survive an error state, since a filter
          // that returns an error is precisely when you need to clear it.
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverToBoxAdapter(
              // The shared filter bar (widgets/audit_filter_bar.dart): Me /
              // All Members, the Filters sheet and the active-filter pills.
              // Status is left off — the tiles below always count every
              // status (the web dashboard only applies Status to its table).
              child: const AuditFilterBar(),
            ),
          ),
          // Full-page loader only until the first answer: later refreshes
          // (filters, socket events) keep the page — and its scroll — as is.
          if (showFullLoader)
            const SliverFillRemaining(child: AppLoading())
          else if (dashboard.errorMessage != null)
            SliverFillRemaining(
              child: ErrorState(
                message: dashboard.errorMessage!,
                onRetry: () => context.read<DashboardProvider>().fetchStats(),
              ),
            )
          else ...[
            // Headline ATS/OTC scorecard — the most visually dominant
            // thing on this dashboard (feeds straight into appraisal /
            // increment review). This auditor's own audit-based ATS/OTC
            // (Start/Due/Completed dates), same fields the web app's
            // AuditorDashboard.jsx Performance Scorecard reads off this
            // identical GET /audits/auditor-stats response — NOT the
            // NC-closure-based score (that one's AuditeeStats, the
            // auditee's own dashboard below).
            // ATS/OTC are the auditee's (for their NCs) — an auditor's own
            // scorecard is plan vs actual + scoring (AuditorScorecard).
            if (!showFullLoader && dashboard.errorMessage == null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: AuditorScorecard(stats: dashboard.stats),
                ),
              ),
            // Secondary operational tallies — deliberately smaller
            // (StatCard compact:true) than the scorecard above, right
            // under it per spec order (score first, other stats after).
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: AuditStatsGrid(
                  stats: dashboard.stats,
                  onNavigateToTab: widget.onNavigateToTab,
                ),
              ),
            ),
            // Today's / In Progress / Overdue audits — tucked into one
            // collapsible panel below the stats, instead of always taking
            // up the full scroll.
            //
            // Nothing in here assumes an unfiltered list: TodayAudits/
            // InProgress/OverdueAuditsSection and auditActivityCount all
            // derive their buckets purely from the AuditModel list handed
            // in (scheduledDate window / the server's displayStatus), never
            // from a total or a count the server sent alongside it. So the same widgets
            // simply describe the narrowed list once the filters reach
            // GET /audits/mine, with no "N of M" claim to go stale.
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              sliver: SliverToBoxAdapter(
                child: ExpandableSection(
                  title: "What needs attention",
                  icon: Icons.checklist_rounded,
                  count: auditActivityCount(auditsProvider.audits),
                  // Accordion: opening one of Today's / In Progress /
                  // Overdue folds the others (see AuditAttentionPanel).
                  child: AuditAttentionPanel(
                    audits: auditsProvider.audits,
                    onSeeAll: widget.onNavigateToTab == null
                        ? null
                        : () => widget.onNavigateToTab!(1),
                  ),
                ),
              ),
            ),
          ],
          if (!showFullLoader &&
              dashboard.errorMessage == null &&
              dashboard.stats.assignedAudits == 0)
            SliverFillRemaining(
              hasScrollBody: false,
              // "Nothing assigned to you" and "nothing matched what you
              // just picked" are completely different situations with the
              // same zero in them — telling a filtering user their audits
              // don't exist is how a filter turns into a support ticket.
              child: dashboard.hasActiveFilters
                  ? EmptyState(
                      icon: Icons.filter_alt_off_outlined,
                      title: 'No audits match these filters',
                      subtitle:
                          'Nothing is assigned under the people, locations '
                          'and audit types you picked.',
                      action: OutlinedButton.icon(
                        onPressed: () => applyAuditFilterSelection(
                          context,
                          AuditFilterSelection.cleared,
                        ),
                        icon: const Icon(Icons.filter_alt_off_outlined),
                        label: const Text('Clear filters'),
                      ),
                    )
                  : const EmptyState(
                      icon: Icons.fact_check_outlined,
                      title: 'No audits assigned yet',
                      subtitle: 'Audits assigned to you will show up here.',
                    ),
            ),
        ],
        ),
      ),
    );
  }
}

// One icon per lifecycle status, so a tile reads at a glance without its
// (two-line) label.
IconData _statusIcon(String status) => switch (status) {
  AuditStatus.notStarted => Icons.schedule_outlined,
  AuditStatus.inProgress => Icons.hourglass_bottom_rounded,
  AuditStatus.overdue => Icons.alarm_off_outlined,
  AuditStatus.delayedCompleted => Icons.history_toggle_off_rounded,
  AuditStatus.onTimeCompleted => Icons.check_circle_outline,
  AuditStatus.ncResponsePending => Icons.mark_email_unread_outlined,
  AuditStatus.ncVerificationPending => Icons.fact_check_outlined,
  AuditStatus.totalClosed => Icons.verified_outlined,
  _ => Icons.assignment_outlined,
};

/// The dashboard's audit-status tiles — one per lifecycle status plus the NC
/// Pending shortcut. Public (not file-private like the widgets around it) only
/// so a widget test can drive it without standing up the whole dashboard's
/// provider tree; nothing else builds it.
class AuditStatsGrid extends StatelessWidget {
  final AuditorStats stats;
  final void Function(int tabIndex, {String? filter})? onNavigateToTab;

  const AuditStatsGrid({super.key, required this.stats, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    // tab: index within AppShell's auditor tab set (1 Audits, 2 NC
    // Monitoring). filter: the exact status chip that tab should land on
    // pre-applied (see MyAuditsScreen's status chips / NcListScreen's
    // synthetic buckets), so a tile tap shows precisely what it counted
    // instead of dumping the whole unfiltered list.
    //
    // One tile per lifecycle status, in the order the owner listed them
    // (AuditStatus.pipeline), counted by the server (AuditorStats.countFor)
    // and routed to the Audits tab under the chip of the SAME label — the
    // tile and the list it opens filter by the same rule, so the number on
    // the tile is the number of cards you land on. Delayed / On-Time
    // Completed count by timeliness and the NC tiles by NC stage, so one
    // audit can sit in two tiles (a late audit still waiting on an NC
    // response) — intended, per the status contract. Both sides are the same
    // set (every audit its auditor has completed), so On-Time + Delayed always
    // equals NC Response + NC Verification + Total Closed: every number here
    // is the SERVER's own tally from GET /audits/stats/auditor, never counted
    // from the (paginated / filtered) audit list, which is what keeps the two
    // sides from drifting apart.
    //
    // NC Pending stays as the ninth tile: it counts NCs (a different unit
    // from the audit tiles) and is this dashboard's only way straight into
    // the NC Monitoring tab.
    final cards = [
      // Total first: every planned audit; opens the unfiltered Audits tab.
      (
        label: 'Total',
        value: stats.totalAudits,
        icon: Icons.assignment_outlined,
        color: AppColors.primary,
        tab: 1,
        // 'All', not null: a null filter leaves the Audits tab on whatever
        // status was picked there last.
        filter: 'All' as String?,
      ),
      for (final status in AuditStatus.pipeline)
        // An older server sends no NC-stage tallies: hide those tiles rather
        // than print zeros that contradict the timeliness tiles (see
        // AuditorStats.hasNcStageCounts).
        if (stats.hasNcStageCounts || !AuditStatus.isNcStage(status))
        (
          label: status,
          value: stats.countFor(status),
          icon: _statusIcon(status),
          color: AppColors.forAuditStatus(status),
          tab: 1,
          filter: status,
        ),
      (
        label: 'NC Pending',
        value: stats.ncPending,
        icon: Icons.report_gmailerrorred_outlined,
        color: AppColors.red,
        tab: 2,
        // 'Pending' matched nothing at all — nc_list_screen.dart's
        // _matchesFilter has no status called that (real NC statuses are
        // Raised/Response Submitted/Verification/Closed), so this tile
        // silently landed on an always-empty NC Monitoring list. 'Open'
        // is what actually mirrors stats.ncPending's own server-side
        // definition (status != "Closed") — see _matchesFilter's own doc
        // on why neither status picker offers a chip for it directly.
        filter: 'Open',
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: cards.length,
      // Smaller than before (compact:true StatCard + tighter extent) — this
      // grid is now secondary detail under the headline ScoreRow above it,
      // not the dashboard's main event. Two label lines: "NC Verification
      // Pending" and "On-Time Completed" do not fit one line in a half-width
      // tile, and an ellipsized status name is no name at all.
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // responsiveColumnCount: 2 on a phone (unchanged), more on a
        // tablet-width screen instead of the same 2 tiles just stretching
        // wider and wider — see core/utils/responsive.dart.
        crossAxisCount: responsiveColumnCount(context),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: StatCard.compactTileExtent(context, labelLines: 2),
      ),
      itemBuilder: (context, index) {
        final c = cards[index];
        return StatCard(
          label: c.label,
          value: c.value,
          icon: c.icon,
          // readable(): the 500/600-level tokens are tuned for light
          // surfaces and go dim on the dark theme's tinted icon chip.
          color: AppColors.readable(context, c.color),
          compact: true,
          labelMaxLines: 2,
          onTap: onNavigateToTab == null
              ? null
              : () => onNavigateToTab!(c.tab, filter: c.filter),
        );
      },
    );
  }
}
