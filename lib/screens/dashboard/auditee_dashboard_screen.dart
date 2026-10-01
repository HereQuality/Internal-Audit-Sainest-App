import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/responsive.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_section.dart';
import '../../widgets/audit_filter_bar.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/max_width_scroll.dart';
import '../../widgets/nc_summary_bar.dart';
import '../../widgets/score_row.dart';
import '../../widgets/stat_card.dart';
import '../../widgets/today_ncs_section.dart';

/// The Auditee-mode dashboard — NC tallies + ATS/OTC score (GET /ncs/
/// ats-summary), NOT the auditor-mode DashboardScreen's assigned/
/// in-progress AUDIT stats, which are meaningless to someone who isn't
/// performing audits right now. Same data source/tiles as the web app's
/// Auditee.jsx dashboard cards.
class AuditeeDashboardScreen extends StatefulWidget {
  /// Lets a stat tile jump straight to the NCs tab, optionally with that
  /// tab's own status filter pre-applied. Index is within AppShell's
  /// auditee tab set (0 Dashboard, 1 NCs).
  final void Function(int tabIndex, {String? filter})? onNavigateToTab;

  const AuditeeDashboardScreen({super.key, this.onNavigateToTab});

  @override
  State<AuditeeDashboardScreen> createState() => _AuditeeDashboardScreenState();
}

class _AuditeeDashboardScreenState extends State<AuditeeDashboardScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Must be set before the first fetch below — see DashboardProvider/
      // NcProvider's own _scopeParams (Me defaults to explicit
      // employeeIds=<selfId>, which needs this to actually be known).
      // Mirrors the auditor DashboardScreen's identical initState.
      final selfId = context.read<AuthProvider>().user?.id;
      if (selfId != null) {
        context.read<DashboardProvider>().setSelfEmployeeId(selfId);
        context.read<NcProvider>().setSelfEmployeeId(selfId);
      }
      context.read<DashboardProvider>().fetchAuditeeStats();
      // The same NCs the NCs tab's "Against me" view lists, but ALL of them
      // (NcProvider.againstMeAll — that screen pages its list, 20 at a time):
      // reused here just to answer "what do I need to do" without a second,
      // dashboard-only endpoint, same reasoning as the auditor
      // DashboardScreen reusing AuditsProvider.audits.
      context.read<NcProvider>().fetchAgainstMeAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardProvider>();
    final user = context.watch<AuthProvider>().user;
    final stats = dashboard.auditeeStats;
    final ncProvider = context.watch<NcProvider>();

    return RefreshIndicator(
      onRefresh: () => Future.wait([
        context.read<DashboardProvider>().fetchAuditeeStats(),
        context.read<NcProvider>().fetchAgainstMeAll(),
      ]),
      // Wraps the WHOLE CustomScrollView, not each sliver — see
      // MaxWidthScroll's own doc for why that's safe for a sliver tree
      // (the cap only ever touches width, never this scroll view's
      // vertical behavior).
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
          // Me (default) vs Team (self + downstream hierarchy) — scopes the
          // ATS/OTC score and the tally grid below, same toggle/scoping the
          // auditor DashboardScreen already offers and the web app's
          // Auditee.jsx TeamFilterPanel. A manager reviewing this as an
          // auditee still wants their own reports' NCs counted in, not just
          // their personal ones. The Filters button beside it opens the
          // same sheet the auditor dashboard uses — the selection is one
          // shared piece of state on DashboardProvider, so switching
          // AppMode does not quietly change what is being counted; the
          // footnote below the chips is what keeps that honest about the
          // dimensions THIS screen's endpoint ignores.
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverToBoxAdapter(
              // Same shared bar as everywhere else: the filters are one state
              // for Audits, Dashboard and NC providers, and every dimension —
              // team, members, location, department, audit type, date, flag —
              // now reaches GET /ncs/ats-summary and /ncs/mine, so there is
              // no "this doesn't narrow" caveat to print any more.
              child: const AuditFilterBar(showFlag: true),
            ),
          ),
          if (dashboard.isLoadingAuditee &&
              dashboard.auditeeErrorMessage == null)
            const SliverFillRemaining(child: AppLoading())
          else if (dashboard.auditeeErrorMessage != null)
            SliverFillRemaining(
              child: ErrorState(
                message: dashboard.auditeeErrorMessage!,
                onRetry: () =>
                    context.read<DashboardProvider>().fetchAuditeeStats(),
              ),
            )
          else ...[
            if (stats.total > 0) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: ScoreRow(
                    atsScore: stats.atsScore,
                    otcScore: stats.otcScore,
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(child: NcSummaryBar(stats: stats)),
              ),
            ],
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _AuditeeStatsGrid(
                  stats: stats,
                  onNavigateToTab: widget.onNavigateToTab,
                ),
              ),
            ),
            // Like the auditor dashboard's twin panel, every section here
            // derives its bucket from the NcModel list itself (Today*/
            // Ongoing*/Overdue*NcsSection, ncActivityCount) rather than
            // from any server-sent total, so a narrowed list simply
            // describes itself — there is no "N of M" to go stale. What it
            // is narrowed by the same shared filters (NcProvider.ncFilterParams).
            // "See all"/"See more" opens the NC tab on the list's own chip: Overdue → Overdue.
            // Today's and Ongoing mix several chips (a due-today or upcoming NC may be waiting
            // on the auditee or on approval), so they open it on "All".
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              sliver: SliverToBoxAdapter(
                child: ExpandableSection(
                  title: "What needs attention",
                  icon: Icons.checklist_rounded,
                  count: ncActivityCount(ncProvider.againstMeAll),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TodayNcsSection(
                        ncs: ncProvider.againstMeAll,
                        onSeeAll: widget.onNavigateToTab == null
                            ? null
                            : () => widget.onNavigateToTab!(1, filter: 'All'),
                      ),
                      const SizedBox(height: 14),
                      OngoingNcsSection(
                        ncs: ncProvider.againstMeAll,
                        onSeeAll: widget.onNavigateToTab == null
                            ? null
                            : () => widget.onNavigateToTab!(1, filter: 'All'),
                      ),
                      const SizedBox(height: 14),
                      OverdueNcsSection(
                        ncs: ncProvider.againstMeAll,
                        onSeeAll: widget.onNavigateToTab == null
                            ? null
                            : () => widget.onNavigateToTab!(1, filter: 'Overdue'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (!dashboard.isLoadingAuditee &&
              dashboard.auditeeErrorMessage == null &&
              stats.total == 0)
            SliverFillRemaining(
              hasScrollBody: false,
              // "None against you" and "none matched what you picked" are
              // very different zeros — congratulating someone on a clean
              // record they only have because a filter is on would be the
              // most misleading thing on this screen.
              child: dashboard.hasActiveFilters
                  ? EmptyState(
                      icon: Icons.filter_alt_off_outlined,
                      title: 'No NCs match these filters',
                      subtitle:
                          'Nothing is recorded under the people, places, '
                          'dates and types you picked.',
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
                      icon: Icons.thumb_up_outlined,
                      title: 'No NCs against you',
                      subtitle: 'NCs raised against you will show up here.',
                    ),
            ),
        ],
        ),
      ),
    );
  }
}

class _AuditeeStatsGrid extends StatelessWidget {
  final dynamic stats;
  final void Function(int tabIndex, {String? filter})? onNavigateToTab;

  const _AuditeeStatsGrid({required this.stats, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    // filter: one of nc_list_screen.dart's _ncStatusFilters synthetic
    // buckets — exact same mutually-exclusive rules as server's
    // computeNcBuckets (see _matchesFilter there), so a tile tap lands on
    // the NCs tab already filtered to precisely what it counted.
    // Total NC / In Progress / Overdue / Pending Approval / Delayed / On
    // Time Completion — this exact order, matching the web app's
    // Auditee.jsx tile row (and nc_list_screen.dart's own
    // _auditeeStatusFilters, so the grid and its Status picker read the
    // same list top to bottom instead of two different orderings of the
    // same six buckets).
    final cards = [
      (
        label: 'Total NC',
        value: stats.total as int,
        icon: Icons.assignment_outlined,
        color: AppColors.primary,
        filter: 'All',
      ),
      (
        label: 'In Progress',
        value: stats.inProgress as int,
        icon: Icons.hourglass_bottom_rounded,
        color: AppColors.blue,
        filter: 'In Progress',
      ),
      (
        label: 'Overdue',
        value: stats.overdue as int,
        icon: Icons.report_gmailerrorred_outlined,
        color: AppColors.red,
        filter: 'Overdue',
      ),
      (
        label: 'Pending Approval',
        value: stats.pendingApproval as int,
        icon: Icons.pending_actions_outlined,
        color: AppColors.slate,
        filter: 'Pending Approval',
      ),
      (
        label: 'Delayed',
        value: stats.delayed as int,
        icon: Icons.warning_amber_outlined,
        color: AppColors.amber,
        filter: 'Delayed',
      ),
      (
        label: 'On Time Completion',
        value: stats.onTime as int,
        icon: Icons.check_circle_outline,
        color: AppColors.green,
        filter: 'On Time',
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: cards.length,
      // Smaller than before (compact:true StatCard + tighter extent) — this
      // grid is now secondary detail under the headline ScoreRow above it,
      // matching the auditor dashboard's own _StatsGrid.
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        // responsiveColumnCount: 2 on a phone (unchanged), more on a
        // tablet-width screen — see core/utils/responsive.dart and the
        // auditor dashboard's identical AuditStatsGrid.
        crossAxisCount: responsiveColumnCount(context),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: StatCard.compactTileExtent(context),
      ),
      itemBuilder: (context, index) {
        final c = cards[index];
        return StatCard(
          label: c.label,
          value: c.value,
          icon: c.icon,
          color: c.color,
          compact: true,
          // Every tile summarizes the same one NCs tab (auditee mode is
          // only Dashboard + NCs — no separate per-status screen to send
          // each tile to individually), now with that tab's own filter
          // chip pre-applied instead of just landing there unfiltered.
          onTap: onNavigateToTab == null
              ? null
              : () => onNavigateToTab!(1, filter: c.filter),
        );
      },
    );
  }
}
