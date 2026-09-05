import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/audits_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/filter_options_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/expandable_section.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/score_row.dart';
import '../../widgets/scope_toggle.dart';
import '../../widgets/stat_card.dart';
import '../../widgets/today_audits_section.dart';

/// screens/dashboard/dashboard_screen.dart
/// ───────────────────────────────────────
/// The auditor-mode Dashboard tab: ATS/OTC scorecard, the four operational
/// tallies, and the "what needs attention" audit panel — all of them read
/// through the SAME filter state (see providers/audit_filter_scope.dart),
/// so the header bar at the top of this screen is the one place that
/// decides what every number below it is counting.
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

  /// Pushes one filter selection — whether it came from the sheet, from a
  /// chip's X, or from "Clear all" — into BOTH providers.
  ///
  /// Both, always: DashboardProvider owns the stat tiles and the ATS/OTC
  /// score while AuditsProvider owns the "what needs attention" lists, and
  /// a dashboard whose tallies say "Zone A only" above three sections
  /// still listing every zone is worse than no filter at all. Same reason
  /// the plain ScopeToggle has always called setTeamScope on both.
  ///
  /// The two providers are read BEFORE the first await and the refetches
  /// run together rather than one after the other: reading them up front
  /// means there is no post-await `context` use to guard at all (the
  /// use_build_context_synchronously trap this codebase keeps hitting),
  /// and the two GETs are independent, so serialising them would just
  /// double how long the spinner is up.
  Future<void> _applyFilters(AuditFilterSelection selection) {
    final dashboard = context.read<DashboardProvider>();
    final audits = context.read<AuditsProvider>();
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
    ]);
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
              child: DashboardFilterBar(
                isTeam: dashboard.isTeamScope,
                employees: dashboard.employeeFilter,
                locations: dashboard.locationFilter,
                auditTypes: dashboard.auditTypeFilter,
                activeCount: dashboard.activeFilterCount,
                onScopeChanged: (isTeam) {
                  // The coarse toggle keeps its own cheap path (one flag,
                  // no sheet round-trip) but still has to move every
                  // provider this filter concept is shared with — NOT just
                  // the two THIS screen reads from. NcProvider is a single
                  // root-scoped instance shared with the NC Monitoring tab
                  // (NcListMode.auditorOnly); skipping it here would leave
                  // that tab's own Me/Team stuck on whatever it was last
                  // set to elsewhere, disagreeing with the dashboard/
                  // audits scope this same toggle just changed.
                  context.read<DashboardProvider>().setTeamScope(isTeam);
                  context.read<AuditsProvider>().setTeamScope(isTeam);
                  context.read<NcProvider>().setTeamScope(isTeam);
                },
                onApply: _applyFilters,
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
            //
            // Nothing in here assumes an unfiltered list: TodayAudits/
            // InProgress/OverdueAuditsSection and auditActivityCount all
            // derive their buckets purely from the AuditModel list handed
            // in (scheduledDate window / status), never from a total or a
            // count the server sent alongside it. So the same widgets
            // simply describe the narrowed list once the filters reach
            // GET /audits/mine, with no "N of M" claim to go stale.
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
                        onPressed: () => _applyFilters(_clearedSelection),
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
    );
  }
}

/// The resting state as a [AuditFilterSelection] — just me, everywhere,
/// every type. Mirrors AuditFilterScope.clearFilters' own arguments; kept
/// here so "Clear all" and the filtered empty state can't drift apart on
/// what "cleared" means.
const _clearedSelection = AuditFilterSelection(
  isTeam: false,
  employees: [],
  locations: [],
  auditTypes: [],
);

/// The filter control both dashboards share: the Me/Team [ScopeToggle] on
/// the left (or, once specific people are picked, a chip naming them), the
/// [FilterButton] that opens the sheet on the right, and — whenever
/// anything is actually narrowing the numbers — a wrap of removable chips
/// underneath spelling out what.
///
/// It lives in this file rather than lib/widgets/ only because the two
/// dashboards are its only callers today (AuditeeDashboardScreen imports
/// it from here); the moment a third screen wants it, move it out —
/// widgets/status_filter_chip_row.dart exists precisely because the
/// copy-of-a-copy version of this idea got out of hand once already.
///
/// Deliberately stateless and provider-free apart from the id→name lookup:
/// the two screens push a selection into DIFFERENT pairs of providers
/// (Dashboard+Audits vs Dashboard+Nc) and only they know which dimensions
/// their own endpoints honour. Everything leaves through [onApply] as one
/// whole [AuditFilterSelection] — the same shape the sheet returns — so a
/// chip's X and a sheet apply travel the identical code path.
class DashboardFilterBar extends StatelessWidget {
  final bool isTeam;

  /// Employee ids, location ids and audit type NAMES — straight off
  /// AuditFilterScope's fields, same units the sheet and the server use
  /// (audit types travel by name; see AuditTypeOption's own doc).
  final List<String> employees;
  final List<String> locations;
  final List<String> auditTypes;

  /// Badge on the Filters button — DashboardProvider.activeFilterCount.
  final int activeCount;

  /// The cheap Me/Team path, which each screen wires to its own pair of
  /// providers' setTeamScope.
  final ValueChanged<bool> onScopeChanged;

  /// Every other change — sheet result, one chip removed, "Clear all".
  final Future<void> Function(AuditFilterSelection selection) onApply;

  /// A caveat rendered under the chips, e.g. the auditee dashboard's note
  /// that location does not narrow its NC numbers. Null on a screen where
  /// every chip on show really is filtering what is on screen.
  final String? footnote;

  const DashboardFilterBar({
    super.key,
    required this.isTeam,
    required this.employees,
    required this.locations,
    required this.auditTypes,
    required this.activeCount,
    required this.onScopeChanged,
    required this.onApply,
    this.footnote,
  });

  Future<void> _openSheet(BuildContext context) async {
    final result = await showAuditFilterSheet(
      context,
      isTeam: isTeam,
      employees: employees,
      locations: locations,
      auditTypes: auditTypes,
      // month deliberately omitted: passing it non-null is what makes the
      // sheet show its Month section, and neither dashboard has a month
      // dimension to show one for (that section is the Calendar's).
    );
    if (result == null) return;
    // The sheet can outlive this widget — a socket-driven rebuild, an
    // AppMode switch or a logout can all tear the dashboard down while it
    // is open, and applying then would touch providers on behalf of a
    // screen that is gone.
    if (!context.mounted) return;
    await onApply(result);
  }

  /// Re-emits the whole selection with one dimension replaced — the chips
  /// each change exactly one thing, and [onApply] only ever deals in
  /// complete selections.
  Future<void> _applyChange({
    bool? isTeam,
    List<String>? employees,
    List<String>? locations,
    List<String>? auditTypes,
  }) {
    return onApply(
      AuditFilterSelection(
        isTeam: isTeam ?? this.isTeam,
        employees: employees ?? this.employees,
        locations: locations ?? this.locations,
        auditTypes: auditTypes ?? this.auditTypes,
      ),
    );
  }

  /// Names the person when exactly one is picked — "Asha Menon" beats
  /// "1 person" and the name is already in the cache the sheet filled —
  /// and counts them otherwise.
  String _peopleLabel(FilterOptionsProvider options) {
    if (employees.length == 1) {
      for (final e in options.employees) {
        if (e.id == employees.first) return e.name;
      }
      return '1 person';
    }
    return '${employees.length} people';
  }

  /// Resolves a location id through the sheet's cached option list.
  /// Falls back to a generic word rather than showing the raw ObjectId:
  /// the cache is loaded before anything can be picked, so an unresolved
  /// id means the cache was dropped, and a hex string on a chip reads as
  /// a bug to the user.
  String _locationLabel(FilterOptionsProvider options, String id) {
    for (final l in options.locations) {
      if (l.id == id) return l.name;
    }
    return 'Location';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // watch, not read: this cache fills in asynchronously the first time
    // the sheet is opened, and these chips are what turn its ids back into
    // names.
    final options = context.watch<FilterOptionsProvider>();
    // Same rule as AuditFilterScope.hasActiveFilters — plain "Me" is the
    // resting state and shows no chips; Team is a deliberate widening and
    // does. Recomputed rather than passed in so the two screens have one
    // less field to keep in sync with the provider they already read the
    // four selections from.
    final hasActive =
        isTeam ||
        employees.isNotEmpty ||
        locations.isNotEmpty ||
        auditTypes.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          // Scope control hard left, Filters hard right, leftover width
          // absorbed as the gap between them. The left child is Flexible
          // and scrolls horizontally, so on a 360px phone — where a
          // SegmentedButton plus the Filters button come within a few
          // pixels of the whole 328px content width — the toggle gives way
          // instead of the row overflowing.
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Padding(
                // Guarantees a gap even at the width where spaceBetween
                // has none left to hand out.
                padding: const EdgeInsets.only(right: 12),
                child: employees.isEmpty
                    ? SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ScopeToggle(
                          isTeam: isTeam,
                          onChanged: onScopeChanged,
                        ),
                      )
                    // Picking specific people WINS over Me/Team server-side
                    // (AuditFilterScope.filterParams sends employeeIds and
                    // ignores the flag entirely), so a segmented button
                    // still sitting on "Me" would be asserting a scope that
                    // is not in force. Hidden rather than disabled: a
                    // greyed-out toggle still reads as a statement about
                    // the current scope, and the honest statement is the
                    // list of people. This chip is also where the people
                    // dimension is REMOVED, which is why the wrap below
                    // skips its own people chip in this state — one
                    // dimension, one control.
                    // The people PILL, not a full Material InputChip — see
                    // _FilterPill's own doc for why every active-filter
                    // affordance on this bar moved off InputChip/ActionChip:
                    // their built-in padding/avatar slot made even one
                    // active filter read as heavier than it needed to, and
                    // several of them wrapping onto a second/third line
                    // (the old `Wrap` below) is exactly what made this bar
                    // feel oversized on a phone.
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: _FilterPill(
                          label: _peopleLabel(options),
                          onTap: () => _openSheet(context),
                          onRemove: () => _applyChange(employees: const []),
                        ),
                      ),
              ),
            ),
            FilterButton(
              activeCount: activeCount,
              onTap: () => _openSheet(context),
            ),
          ],
        ),
        // What is narrowing the numbers, spelled out. A surprising tally
        // has to be explainable without reopening the sheet to go looking
        // for why — and each pill removes just its own dimension, so
        // widening back out is one tap rather than a round trip.
        //
        // Fixed-HEIGHT, horizontally-scrolling single row — deliberately
        // NOT a `Wrap` (which is what this used to be): a Wrap grows
        // downward, one more line per overflowed pill, so three or four
        // active filters could push this row to two or three lines tall
        // and shove the actual page content down with it. A single
        // scrollable row caps the vertical cost at exactly one row no
        // matter how many filters are active — reach the ones that don't
        // fit by scrolling sideways, same as Calendar's own active-filter
        // strip (screens/calendar/calendar_screen.dart#_ActiveFilterBar),
        // which this now matches instead of diverging from.
        //
        // "Clear" sits OUTSIDE that scrollable ListView, not as its last
        // item — with enough active filters (team + a few audit types +
        // a few locations easily runs to 6-8 pills), the row scrolls well
        // past one screen's width and Clear used to be all the way at the
        // far end of it, behind however many pills happened to be picked.
        // Pinned to the left instead: always exactly one tap away
        // regardless of how many pills are active or how far the pill row
        // itself has been scrolled.
        if (hasActive) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: Row(
              children: [
                TextButton(
                  onPressed: () => onApply(_clearedSelection),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Clear', style: TextStyle(fontSize: 12.5)),
                ),
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final type in auditTypes)
                        _FilterPill(
                          label: type,
                          onRemove: () => _applyChange(
                            auditTypes: [...auditTypes]..remove(type),
                          ),
                        ),
                      for (final id in locations)
                        _FilterPill(
                          label: _locationLabel(options, id),
                          // Employee selections are left alone when a
                          // location goes: the two are independent params
                          // server-side (employeeIds ∩ locationIds), and
                          // silently dropping people because their
                          // location was removed would be a second,
                          // invisible edit to a filter the user did not
                          // ask to change.
                          onRemove: () => _applyChange(
                            locations: [...locations]..remove(id),
                          ),
                        ),
                      // Only in the Team case — the specific-people state
                      // is already represented by the pill that replaced
                      // the toggle above, and showing the same "3 people"
                      // twice in one bar would just raise the question of
                      // what the difference is.
                      if (employees.isEmpty && isTeam)
                        _FilterPill(
                          label: 'Team',
                          onRemove: () => _applyChange(isTeam: false),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (footnote != null) ...[
            const SizedBox(height: 6),
            Text(
              footnote!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ],
      ],
    );
  }
}

/// One active filter as a small, self-themed pill — a plain Container/
/// InkWell, not a Material InputChip/ActionChip. A Chip widget carries
/// real fixed overhead (an avatar slot, delete-icon spacing, the theme's
/// own chipTheme padding — 14/8 horizontal/vertical, see AppTheme) that
/// stays roughly the same size REGARDLESS of density overrides, which is
/// what made even a single active filter read as a big, heavy pill; a few
/// of them stacked (the old `Wrap`) made the whole bar feel oversized.
/// This is deliberately tiny: no icon, 11.5px text, a hairline border
/// instead of a filled Material shape, matching Calendar's own compact
/// filter strip so every screen's "what's currently narrowing this" UI
/// looks and costs the same.
///
/// [onTap] is optional — the people pill (the one spot in the header row
/// this also replaces) reopens the sheet on tap; the ones in the strip
/// below are remove-only, same split as before this rewrite.
class _FilterPill extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  final VoidCallback? onTap;

  const _FilterPill({required this.label, required this.onRemove, this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A long audit type or location name must not push this
                // pill (and the whole scrollable row) arbitrarily wide —
                // capped rather than left to size to its content.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(999),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
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
        // 'Pending' matched nothing at all — nc_list_screen.dart's
        // _matchesFilter has no status called that (real NC statuses are
        // Raised/Response Submitted/Verification/Closed), so this tile
        // silently landed on an always-empty NC Monitoring list. 'Open'
        // is what actually mirrors stats.ncPending's own server-side
        // definition (status != "Closed") — see _matchesFilter's own doc
        // on why neither status picker offers a chip for it directly.
        filter: 'Open',
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
