import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/audits_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_section.dart';
import '../../widgets/score_row.dart';
import '../../widgets/scope_toggle.dart';
import '../../widgets/stat_card.dart';
import '../../widgets/today_audits_section.dart';

class DashboardScreen extends StatefulWidget {
  /// Lets a stat tile jump straight to the tab it summarizes (e.g. "NC
  /// Pending" -> the NC Monitoring tab), optionally pre-applying that
  /// tab's own status filter (e.g. "Completed" -> the Audits tab already
  /// showing just Completed) instead of landing on an unfiltered list.
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
    final user = context.watch<AuthProvider>().user;
    final auditsProvider = context.watch<AuditsProvider>();

    return RefreshIndicator(
      onRefresh: () => Future.wait([
        context.read<DashboardProvider>().fetchStats(),
        context.read<AuditsProvider>().fetchMyAudits(),
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
          if (dashboard.isLoading && dashboard.errorMessage == null)
            const SliverFillRemaining(child: AppLoading())
          else if (dashboard.errorMessage != null)
            SliverFillRemaining(
              child: ErrorState(
                message: dashboard.errorMessage!,
                onRetry: () => context.read<DashboardProvider>().fetchStats(),
              ),
            )
          else ...[
            // Me (default) vs Team (self + downstream hierarchy) — scopes
            // everything below: the ATS/OTC score, the stat tallies, and
            // the audit sections. See AuditsProvider/DashboardProvider's
            // setTeamScope.
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ScopeToggle(
                    isTeam: dashboard.isTeamScope,
                    onChanged: (isTeam) {
                      context.read<DashboardProvider>().setTeamScope(isTeam);
                      context.read<AuditsProvider>().setTeamScope(isTeam);
                    },
                  ),
                ),
              ),
            ),
            // Headline ATS/OTC scorecard — the most visually dominant
            // thing on this dashboard (feeds straight into appraisal /
            // increment review). This auditor's own audit-based ATS/OTC
            // (Start/Due/Completed dates), same fields the web app's
            // AuditorDashboard.jsx Performance Scorecard reads off this
            // identical GET /audits/auditor-stats response — NOT the
            // NC-closure-based score (that one's AuditeeStats, the
            // auditee's own dashboard below).
            if (!dashboard.isLoading &&
                dashboard.errorMessage == null &&
                (dashboard.stats.auditAtsScore != null ||
                    dashboard.stats.auditOtcScore != null))
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                sliver: SliverToBoxAdapter(
                  child: ScoreRow(
                    atsScore: dashboard.stats.auditAtsScore,
                    otcScore: dashboard.stats.auditOtcScore,
                  ),
                ),
              ),
            // Secondary operational tallies — deliberately smaller
            // (StatCard compact:true) than the scorecard above, right
            // under it per spec order (score first, other stats after).
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              sliver: SliverToBoxAdapter(
                child: _StatsGrid(
                  stats: dashboard.stats,
                  onNavigateToTab: widget.onNavigateToTab,
                ),
              ),
            ),
            // Today's / In Progress / Overdue audits — tucked into one
            // collapsible panel below the stats, instead of always taking
            // up the full scroll.
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              sliver: SliverToBoxAdapter(
                child: ExpandableSection(
                  title: "What needs attention",
                  icon: Icons.checklist_rounded,
                  count: auditActivityCount(auditsProvider.audits),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TodayAuditsSection(
                        audits: auditsProvider.audits,
                        onSeeAll: widget.onNavigateToTab == null
                            ? null
                            : () => widget.onNavigateToTab!(1),
                      ),
                      const SizedBox(height: 14),
                      InProgressAuditsSection(
                        audits: auditsProvider.audits,
                        onSeeAll: widget.onNavigateToTab == null
                            ? null
                            : () => widget.onNavigateToTab!(1),
                      ),
                      const SizedBox(height: 14),
                      OverdueAuditsSection(
                        audits: auditsProvider.audits,
                        onSeeAll: widget.onNavigateToTab == null
                            ? null
                            : () => widget.onNavigateToTab!(1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (!dashboard.isLoading &&
              dashboard.errorMessage == null &&
              dashboard.stats.assignedAudits == 0)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.fact_check_outlined,
                title: 'No audits assigned yet',
                subtitle: 'Audits assigned to you will show up here.',
              ),
            ),
        ],
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final dynamic stats;
  final void Function(int tabIndex, {String? filter})? onNavigateToTab;

  const _StatsGrid({required this.stats, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    // tab: index within AppShell's auditor tab set (1 Audits, 2 NC
    // Monitoring). filter: the exact status chip that tab should land on
    // pre-applied (see MyAuditsScreen's _statusFilters / NcListScreen's
    // synthetic buckets), so a tile tap shows precisely what it counted
    // instead of dumping the whole unfiltered list.
    final cards = [
      (
        label: 'Assigned Audits',
        value: stats.assignedAudits as int,
        icon: Icons.assignment_outlined,
        color: AppColors.primary,
        tab: 1,
        filter: 'All',
      ),
      (
        label: 'In Progress',
        value: stats.inProgress as int,
        icon: Icons.hourglass_bottom_rounded,
        color: AppColors.amber,
        tab: 1,
        filter: 'In Progress',
      ),
      (
        label: 'NC Pending',
        value: stats.ncPending as int,
        icon: Icons.report_gmailerrorred_outlined,
        color: AppColors.red,
        tab: 2,
        filter: 'Pending',
      ),
      (
        label: 'Completed',
        value: stats.completed as int,
        icon: Icons.check_circle_outline,
        color: AppColors.green,
        tab: 1,
        filter: 'Completed',
      ),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: cards.length,
      // Smaller than before (compact:true StatCard + tighter extent) — this
      // grid is now secondary detail under the headline ScoreRow above it,
      // not the dashboard's main event.
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
          onTap: onNavigateToTab == null
              ? null
              : () => onNavigateToTab!(c.tab, filter: c.filter),
        );
      },
    );
  }
}
