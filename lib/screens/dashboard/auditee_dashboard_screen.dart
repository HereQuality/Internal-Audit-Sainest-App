import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_section.dart';
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
      context.read<DashboardProvider>().fetchAuditeeStats();
      // Same list the NCs tab's "Against me" view fetches (NcProvider.
      // raisedAgainstMe) — reused here just to answer "what do I need to
      // do" without a second, dashboard-only endpoint, same reasoning as
      // the auditor DashboardScreen reusing AuditsProvider.audits.
      context.read<NcProvider>().fetchAgainstMe();
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
        context.read<NcProvider>().fetchAgainstMe(),
      ]),
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
            if (stats.total > 0)
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
              sliver: SliverToBoxAdapter(
                child: _AuditeeStatsGrid(
                  stats: stats,
                  onNavigateToTab: widget.onNavigateToTab,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              sliver: SliverToBoxAdapter(
                child: ExpandableSection(
                  title: "What needs attention",
                  icon: Icons.checklist_rounded,
                  count: ncActivityCount(ncProvider.raisedAgainstMe),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TodayNcsSection(
                        ncs: ncProvider.raisedAgainstMe,
                        onSeeAll: widget.onNavigateToTab == null ? null : () => widget.onNavigateToTab!(1),
                      ),
                      const SizedBox(height: 14),
                      OngoingNcsSection(
                        ncs: ncProvider.raisedAgainstMe,
                        onSeeAll: widget.onNavigateToTab == null ? null : () => widget.onNavigateToTab!(1),
                      ),
                      const SizedBox(height: 14),
                      OverdueNcsSection(
                        ncs: ncProvider.raisedAgainstMe,
                        onSeeAll: widget.onNavigateToTab == null ? null : () => widget.onNavigateToTab!(1),
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
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.thumb_up_outlined,
                title: 'No NCs against you',
                subtitle: 'NCs raised against you will show up here.',
              ),
            ),
        ],
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
    final cards = [
      (
        label: 'Total NC',
        value: stats.total as int,
        icon: Icons.assignment_outlined,
        color: AppColors.primary,
        filter: 'All',
      ),
      (
        label: 'On Time',
        value: stats.onTime as int,
        icon: Icons.check_circle_outline,
        color: AppColors.green,
        filter: 'On Time',
      ),
      (
        label: 'In Progress',
        value: stats.inProgress as int,
        icon: Icons.hourglass_bottom_rounded,
        color: AppColors.blue,
        filter: 'In Progress',
      ),
      (
        label: 'Pending Approval',
        value: stats.pendingApproval as int,
        icon: Icons.pending_actions_outlined,
        color: AppColors.slate,
        filter: 'Pending Approval',
      ),
      (
        label: 'Overdue',
        value: stats.overdue as int,
        icon: Icons.report_gmailerrorred_outlined,
        color: AppColors.red,
        filter: 'Overdue',
      ),
      (
        label: 'Delayed',
        value: stats.delayed as int,
        icon: Icons.warning_amber_outlined,
        color: AppColors.amber,
        filter: 'Delayed',
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: cards.length,
      // Smaller than before (compact:true StatCard + tighter extent) — this
      // grid is now secondary detail under the headline ScoreRow above it,
      // matching the auditor dashboard's own _StatsGrid.
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 100,
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
          onTap: onNavigateToTab == null ? null : () => onNavigateToTab!(1, filter: c.filter),
        );
      },
    );
  }
}
