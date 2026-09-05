import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/audits_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_section.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/score_row.dart';
import '../../widgets/stat_card.dart';
import '../../widgets/today_ncs_section.dart';
// DashboardFilterBar (scope toggle + Filters button + active-filter chips)
// lives next to the auditor dashboard that also uses it — see its own doc
// comment for why it isn't in lib/widgets/ yet.
import 'dashboard_screen.dart';

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
      // Same list the NCs tab's "Against me" view fetches (NcProvider.
      // raisedAgainstMe) — reused here just to answer "what do I need to
      // do" without a second, dashboard-only endpoint, same reasoning as
      // the auditor DashboardScreen reusing AuditsProvider.audits.
      context.read<NcProvider>().fetchAgainstMe();
    });
  }

  /// Pushes one filter selection into every provider this filter state is
  /// shared with — not just the two this screen itself reads from.
  ///
  /// DashboardProvider and AuditsProvider both get the whole selection;
  /// NcProvider — which has no AuditFilterScope of its own — gets only the
  /// Me/Team half, because GET /ncs/mine understands nothing but
  /// `employeeIds` (see its _scopeParams). The raw toggle value is passed
  /// on even when specific people are picked: the list below is "NCs
  /// raised against me", so widening it to the whole team on the strength
  /// of a people filter that this endpoint cannot even apply would show
  /// MORE than the tiles above it, which is the wrong way round for a
  /// filter to fail.
  ///
  /// AuditsProvider is NOT read by anything on THIS screen — but it is a
  /// single root-scoped instance (main.dart's MultiProvider), shared with
  /// the Auditor Dashboard's own "what needs attention" panel, the Audits
  /// tab and the Calendar. AppMode is a plain local toggle the user is
  /// free to flip via Profile > Switch Role at any moment (app_shell.dart
  /// #switchRole) — so skipping it here would leave a filter applied in
  /// AUDITEE mode invisible to AuditsProvider, and the very next time this
  /// same person opens the Auditor Dashboard its stat tiles (driven by
  /// DashboardProvider, correctly filtered) and its audit list underneath
  /// (driven by AuditsProvider, NOT filtered) would silently disagree
  /// about what population they're both describing. Same reasoning the
  /// auditor dashboard's own _applyFilters already follows in the other
  /// direction — mirror it here rather than assume "this screen doesn't
  /// show audits" means "this screen doesn't need to touch AuditsProvider".
  ///
  /// Providers are read before the first await (nothing to guard with
  /// context.mounted afterwards) and every refetch runs together.
  Future<void> _applyFilters(AuditFilterSelection selection) {
    final dashboard = context.read<DashboardProvider>();
    final audits = context.read<AuditsProvider>();
    final ncs = context.read<NcProvider>();
    return Future.wait([
      dashboard.applyFilters(
        isTeam: selection.isTeam,
        employees: selection.employees,
        locations: selection.locations,
        auditTypes: selection.auditTypes,
      ),
      audits.applyFilters(
        isTeam: selection.isTeam,
        employees: selection.employees,
        locations: selection.locations,
        auditTypes: selection.auditTypes,
      ),
      ncs.setTeamScope(selection.isTeam),
    ]);
  }

  /// The honesty line under the chips.
  ///
  /// The sheet is shared with the auditor dashboard and offers all three
  /// dimensions, but GET /ncs/ats-summary does not honour all three:
  ///  • people  — honoured (employeeIds).
  ///  • audit type — honoured (nc.controller.js#auditTypeFilter resolves
  ///    the type to audit ids and ANDs it into the query).
  ///  • location — NOT honoured, and dropped on purpose before the request
  ///    goes out (DashboardProvider._ncSummaryParams): that endpoint takes
  ///    `locationId` singular and, worse, lets it REPLACE the employee
  ///    scoping, so sending it would turn "my NCs" into "everyone's NCs in
  ///    that zone" under a personal score.
  /// The location chip is still shown rather than hidden — it is real,
  /// shared filter state that the auditor dashboard is applying, and a
  /// chip the user cannot see is a chip they cannot clear — but it must
  /// not be allowed to imply it is narrowing these numbers, hence this
  /// note. Same for the panel below, which follows Me/Team alone.
  String? _filterFootnote(DashboardProvider dashboard) {
    final notes = <String>[];
    if (dashboard.locationFilter.isNotEmpty) {
      notes.add("Location doesn't narrow NC numbers.");
    }
    // Audit type DOES narrow the tiles above (GET /ncs/ats-summary honours
    // it — see DashboardProvider._ncSummaryParams, which strips location
    // but keeps type) but the panel below never receives it at all:
    // _applyFilters only ever forwards the Me/Team half to NcProvider
    // (GET /ncs/mine has no auditType param wired through it here), so a
    // type-only filter would otherwise narrow the tiles with nothing
    // below explaining why the list underneath still shows every type.
    // Folded into the SAME note as employeeFilter's — both describe the
    // identical fact ("the list below only follows Me/Team"), and showing
    // it twice for two filters that are both true would just be noise.
    if (dashboard.employeeFilter.isNotEmpty || dashboard.auditTypeFilter.isNotEmpty) {
      notes.add('The list below follows Me/Team only.');
    }
    return notes.isEmpty ? null : notes.join(' ');
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
              child: DashboardFilterBar(
                isTeam: dashboard.isTeamScope,
                employees: dashboard.employeeFilter,
                locations: dashboard.locationFilter,
                auditTypes: dashboard.auditTypeFilter,
                // The raw count, location included even though it does not
                // narrow this screen: the badge has to match what the user
                // finds selected when the sheet opens, and a badge that
                // disagrees with the sheet is a worse lie than one that
                // counts a filter the footnote already qualifies.
                activeCount: dashboard.activeFilterCount,
                onScopeChanged: (isTeam) {
                  context.read<DashboardProvider>().setTeamScope(isTeam);
                  context.read<NcProvider>().setTeamScope(isTeam);
                  // Same reasoning as _applyFilters above — AuditsProvider
                  // is shared root-scoped state, not something private to
                  // the auditor screens, so the coarse toggle has to move
                  // it too or the Auditor Dashboard/Audits tab/Calendar go
                  // stale the next time this person switches role.
                  context.read<AuditsProvider>().setTeamScope(isTeam);
                },
                onApply: _applyFilters,
                footnote: _filterFootnote(dashboard),
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
            // Like the auditor dashboard's twin panel, every section here
            // derives its bucket from the NcModel list itself (Today*/
            // Ongoing*/Overdue*NcsSection, ncActivityCount) rather than
            // from any server-sent total, so a narrowed list simply
            // describes itself — there is no "N of M" to go stale. What it
            // is narrowed BY is only Me/Team, see _applyFilters.
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
                          'Nothing is recorded for the people and audit '
                          'types you picked.',
                      action: OutlinedButton.icon(
                        onPressed: () => _applyFilters(
                          const AuditFilterSelection(
                            isTeam: false,
                            employees: [],
                            locations: [],
                            auditTypes: [],
                          ),
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
