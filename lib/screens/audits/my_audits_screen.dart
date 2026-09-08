import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../models/audit_model.dart';
import '../../providers/audits_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/audit_agenda.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/status_filter_chip_row.dart';
import '../dashboard/dashboard_screen.dart' show DashboardFilterBar;

/// screens/audits/my_audits_screen.dart
/// ─────────────────────────────────────
/// The auditor's Audits tab (bottom nav #2, mounted by
/// screens/root/app_shell.dart), rebuilt as a TIME-ANCHORED AGENDA.
///
/// It used to be a flat list of collapsible date groups ordered
/// newest-scheduled-date-first, with the newest group auto-expanded. That
/// ordering answered "what was scheduled most recently", which is not the
/// question anyone opens this tab with, and it meant the further into the
/// future an audit was scheduled the closer to the top it sat — so
/// today's work drifted down the list as the schedule filled up.
///
/// Now the list is anchored on today: Today sits at the top of the
/// viewport on first paint, the next seven days follow it one day at a
/// time, everything beyond that is summarised a month at a time, and the
/// past sits ABOVE today, reached by scrolling UP. All of the bucketing
/// and every section widget lives in widgets/audit_agenda.dart; this file
/// is the screen shell around it — the filter bar, status chips,
/// loading/error/empty states, pull-to-refresh, and the sliver wiring
/// that makes the anchor work.
///
/// The filter bar reuses [DashboardFilterBar] wholesale rather than
/// growing a second copy of it — the naming is a dashboard-screen
/// artifact of where it was built first, but `AuditsProvider.audits` (the
/// very list this screen renders) is exactly what its Me/Team toggle,
/// people/location/audit-type chips and Filters sheet already narrow.
/// `_applyFilters` below pushes every result to BOTH AuditsProvider and
/// DashboardProvider, same reasoning as the Auditee Dashboard's own
/// _applyFilters: they are shared, root-scoped state, and a filter set
/// from this tab has to stay visible/consistent everywhere else that
/// state is read (the Dashboard's own tiles and "what needs attention"
/// panel, the Calendar) — not just here.
///
/// Unchanged on purpose: the status chips (still a
/// client-side filter over the one fetched list), the empty/error states,
/// RefreshIndicator -> fetchMyAudits(), and the `initialStatusFilter`
/// prop AppShell passes when a dashboard stat tile jumps here.

// "All" plus the statuses actually worth a dedicated chip. Skipped is
// already excluded server-side (audit.controller.js#notSkipped); Draft is
// deliberately left off too — this row is for triaging ACTIVE work
// ("what's not started, what's in progress, what's done"), and a Draft
// (not-yet-scheduled/incomplete-setup) audit doesn't fit that question.
// It still shows up under "All", just with no chip of its own to isolate
// it — the same "Complete Setup" row on the web Schedule Audit page is
// where a planner actually deals with drafts, not this triage list.
// Filtered client-side over the one fetched list rather than a re-fetch
// per tap, since a single auditor's own audit list is small enough that
// round-tripping the server for every filter change would just be
// perceptible lag for no benefit.
const _statusFilters = [
  'All',
  'Not Started',
  'In Progress',
  'Completed',
];

// Which way the "Today" pill would take you — also its visibility, since
// "you are already at Today" is exactly when it should not be on screen.
enum _JumpTarget { hidden, up, down }

// Far enough from the anchor that the pill can't flicker in and out while
// someone rests a thumb on a barely-moving list, close enough that it
// appears as soon as Today has genuinely left the viewport.
const double _jumpThreshold = 80;

class MyAuditsScreen extends StatefulWidget {
  // Pre-applies one of _statusFilters below — set by AppShell when a
  // dashboard stat tile is tapped (see DashboardScreen's _StatsGrid),
  // remounted under a fresh key each time so this always takes effect
  // even when the tile tapped is the same filter already showing.
  final String? initialStatusFilter;

  const MyAuditsScreen({super.key, this.initialStatusFilter});

  @override
  State<MyAuditsScreen> createState() => _MyAuditsScreenState();
}

class _MyAuditsScreenState extends State<MyAuditsScreen> {
  late String _statusFilter = widget.initialStatusFilter ?? 'All';

  /// Which groups the user opened/closed. Held here, in the State object,
  /// rather than inside each section widget: AppShell wraps every tab in
  /// a _KeepAlivePage, so this survives a swipe to another tab and back —
  /// returning to the Audits tab to find every group you had opened
  /// slammed shut would make the tab feel like it reloads on every swipe.
  ///
  /// The old screen's "default the open group to the newest date, once
  /// per list load" behaviour is deliberately NOT carried over: the Today
  /// anchor is what decides where the user lands now, and an auto-opened
  /// group somewhere down the list would just fight it.
  final AgendaExpansion _expansion = AgendaExpansion();

  /// Marks the Today sliver as the CustomScrollView's `center` — see
  /// _buildAgenda for what that actually does.
  final GlobalKey _todayKey = GlobalKey(debugLabel: 'agenda-today-sliver');

  final ScrollController _scroll = ScrollController();

  /// Free-text narrowing, applied on top of the status chip. Local to
  /// this screen and deliberately NOT pushed into AuditsProvider like the
  /// location/type/people filters are: those are server-side query params
  /// (fetchMyAudits re-requests on change), and round-tripping the
  /// network on every keystroke would make typing lag on exactly the
  /// mid-range phones this app targets. Everything the agenda shows is
  /// already in memory, so this filters the loaded list instead.
  final TextEditingController _searchController = TextEditingController();
  String _search = '';

  /// Title, scope and location are all drawn on the agenda card itself
  /// (audit_agenda.dart renders `audit.scope` under the title), so a hit
  /// on any of them is visible on the card the user lands on. `scope` in
  /// particular is the longest free text on the card and the most likely
  /// thing someone retypes after reading it.
  ///
  /// `auditee.name` is the deliberate exception: no agenda widget renders
  /// it, so a match there looks unexplained on the card. It stays
  /// searchable anyway because "which audits is this person the
  /// representative for" is a question auditors actually ask, and the
  /// name IS shown once the audit is opened.
  static bool _matchesSearch(AuditModel audit, String query) {
    bool has(String? value) =>
        value != null && value.toLowerCase().contains(query);
    return has(audit.title) ||
        has(audit.scope) ||
        has(audit.location) ||
        has(audit.auditType) ||
        has(audit.auditee.name) ||
        audit.auditorNames.any((n) => n.toLowerCase().contains(query));
  }

  /// Drives the floating "Today" pill. A ValueNotifier + ValueListenable
  /// Builder instead of setState: this changes on every scroll frame, and
  /// rebuilding the whole agenda (hundreds of cards) 60 times a second to
  /// fade one pill in would drop frames on exactly the mid-range phones
  /// this app runs on. ValueNotifier also skips notifying when the value
  /// is unchanged, so a long scroll in one direction notifies once.
  final ValueNotifier<_JumpTarget> _jump =
      ValueNotifier<_JumpTarget>(_JumpTarget.hidden);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selfId = context.read<AuthProvider>().user?.id;
      if (selfId != null) {
        context.read<AuditsProvider>().setSelfEmployeeId(selfId);
      }
      context.read<AuditsProvider>().fetchMyAudits();
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _jump.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // With a centre sliver, scroll offset 0 IS Today: everything in the
  // past region lives at negative offsets and everything after Today at
  // positive ones, so the sign of the offset is also the direction the
  // pill has to point to get back.
  void _onScroll() {
    if (!_scroll.hasClients) {
      return;
    }
    final offset = _scroll.offset;
    if (offset > _jumpThreshold) {
      _jump.value = _JumpTarget.up;
    } else if (offset < -_jumpThreshold) {
      _jump.value = _JumpTarget.down;
    } else {
      _jump.value = _JumpTarget.hidden;
    }
  }

  void _jumpToToday() {
    if (!_scroll.hasClients) {
      return;
    }
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  // True when every audit currently on screen is sitting above the fold
  // in the collapsed past region — see AgendaTodaySection.hasHiddenPastContent
  // for why this matters: without it, a filtered list that happens to be
  // entirely past-dated (e.g. the dashboard's "Completed" tile, or any
  // status chip once the current schedule is clear) renders as a screen
  // that looks empty even though it isn't.
  bool _onlyPastHasContent(AuditAgenda agenda) =>
      agenda.todayAudits.isEmpty &&
      agenda.nextSevenDays.isEmpty &&
      agenda.restOfThisMonth.isEmpty &&
      agenda.laterMonths.isEmpty &&
      agenda.undated.isEmpty &&
      agenda.pastMonths.isNotEmpty;

  // Scrolls up to the (already expanded, by the time this runs) top of the
  // past region — shared by _viewPast and _togglePast below. Always posted
  // a frame out: the sliver has to have actually grown from the setState
  // that preceded this call before minScrollExtent reflects the new,
  // further-negative offset — reading it in the same frame would still see
  // the pre-expansion (~50px collapsed) extent and stop short.
  void _scrollToPastTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) {
        return;
      }
      _scroll.animateTo(
        _scroll.position.minScrollExtent,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // Opens the past region and scrolls up to it — the tap target behind
  // AgendaTodaySection's "past audits above" hint. Always expands (never
  // toggles closed): the hint only ever shows when Today has nothing on
  // it, so there's no "already open, tapping again should close it" case
  // here the way there is for _togglePast below.
  void _viewPast(AuditAgenda agenda) {
    setState(() => _expansion.pastExpanded = true);
    _scrollToPastTop();
  }

  // AgendaPastRegion's own "Past audits · N" row. A reverse-growth sliver
  // is anchored by its BOTTOM edge (see that class's own header doc), so
  // expanding it grows UPWARD into more negative scroll offsets while the
  // viewport itself doesn't move — the newly revealed months render
  // entirely off-screen above the fold, which is what reads as "I tapped
  // expand and nothing happened" (or worse, "it expanded upward and I have
  // to scroll up to find what I just opened"). Only follow the expansion
  // when actually EXPANDING — collapsing already shrinks back down to sit
  // right above Today, which is already on screen, so animating there too
  // would just be a pointless extra motion (and could yank the user away
  // from wherever in the past they'd scrolled to on their own).
  void _togglePast() {
    final expanding = !_expansion.pastExpanded;
    setState(() => _expansion.pastExpanded = expanding);
    if (expanding) {
      _scrollToPastTop();
    }
  }

  // The onChanged AgendaPastRegion is built with below (NOT the plain
  // _onExpansionChanged every forward section uses) — every toggle that
  // happens ONCE ALREADY INSIDE the (now-open) past region: a past
  // month's own header, or a recurring series inside one of those months.
  // Same reverse-growth problem as _togglePast fixes for the region's own
  // "Past audits" row, one level deeper: AgendaMonthSection/
  // AgendaSeriesGroup mutate `_expansion` for whichever key was tapped
  // and then just call whatever `onChanged` they were handed — they have
  // no way to tell this screen "I just grew upward, follow me" beyond
  // that one call, and no reason to (every OTHER place they're used, in
  // the forward-growing part of the agenda, genuinely doesn't need
  // following). Re-scrolling to the top of the past region on every one
  // of these — not just the ones that expanded — is what actually covers
  // it without threading an expand/collapse signal through two more
  // widgets that have no other reason to carry one: collapsing a past
  // month settles the scroll position at the top of a now-shorter past
  // region instead of wherever the user happened to be, which is a small
  // harmless move next to leaving a just-expanded month sitting off-
  // screen above the fold every time.
  void _onPastRegionChanged() {
    setState(() {});
    _scrollToPastTop();
  }

  Future<void> _refresh() => context.read<AuditsProvider>().fetchMyAudits();

  // Pushes a sheet result to every provider this filter state is shared
  // with — see this file's own header doc for why DashboardProvider is
  // included even though this screen never reads from it.
  Future<void> _applyFilters(AuditFilterSelection selection) {
    final audits = context.read<AuditsProvider>();
    final dashboard = context.read<DashboardProvider>();
    return Future.wait([
      audits.applyFilters(
        isTeam: selection.isTeam,
        employees: selection.employees,
        locations: selection.locations,
        auditTypes: selection.auditTypes,
      ),
      dashboard.applyFilters(
        isTeam: selection.isTeam,
        employees: selection.employees,
        locations: selection.locations,
        auditTypes: selection.auditTypes,
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AuditsProvider>();

    final bool showEmptyState =
        !provider.isLoading &&
        provider.errorMessage == null &&
        provider.audits.isEmpty;
    final bool showError =
        provider.errorMessage != null && provider.audits.isEmpty;
    final bool showLoading =
        provider.isLoading && provider.audits.isEmpty && !showError;
    // Search narrows alongside the status chip and, like it, runs BEFORE
    // bucketing (see the note below) so headers, counts and the Today
    // anchor all describe what is actually on screen.
    final String query = _search.trim().toLowerCase();
    final List<AuditModel> filtered =
        (_statusFilter == 'All' && query.isEmpty)
        ? provider.audits
        : provider.audits.where((a) {
            if (_statusFilter != 'All' && a.status != _statusFilter) {
              return false;
            }
            return query.isEmpty || _matchesSearch(a, query);
          }).toList();

    // The status chips filter BEFORE bucketing, so every section header's
    // count and the Today anchor itself describe what is actually on
    // screen — filtering afterwards would leave empty day groups and a
    // "Past audits · 12" row standing over three visible cards.
    final bool showAgenda =
        !showLoading && !showError && !showEmptyState && filtered.isNotEmpty;
    // Computed here, not inside _buildAgenda, so AgendaPastBar (pinned
    // above the scroll view, see its own doc) can read agenda.pastMonths/
    // pastCount too — the same DateTime.now() read feeds both it and the
    // scrollable agenda below, so the two can't disagree about what counts
    // as "past" if a build happens to straddle midnight.
    final agenda = showAgenda ? buildAuditAgenda(filtered, DateTime.now()) : null;

    // Resync the floating Today pill to whatever this build actually
    // produced. Without this, narrowing the list to nothing (via the
    // search box or a status chip) destroys the CustomScrollView while
    // `_jump` keeps its last value, so the pill stays on screen at full
    // opacity over the empty state — and tapping it does nothing, because
    // `_jumpToToday` no-ops once `_scroll` has detached. Done here rather
    // than in each of the handlers so the search, the chips and a
    // provider refresh are all covered by one rule.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        _onScroll();
      } else {
        _jump.value = _JumpTarget.hidden;
      }
    });

    return Column(
      children: [
        // Hidden while loading/erroring/empty for the same reason the
        // status chips are: there is nothing to narrow, and a dead search
        // box over an error message reads as a broken screen.
        if (!showLoading && !showError && !showEmptyState)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Search audits, location, auditor...',
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: 'Clear search',
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _search = '');
                        },
                      ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: DashboardFilterBar(
            isTeam: provider.isTeamScope,
            employees: provider.employeeFilter,
            locations: provider.locationFilter,
            auditTypes: provider.auditTypeFilter,
            activeCount: provider.activeFilterCount,
            onScopeChanged: (isTeam) {
              context.read<AuditsProvider>().setTeamScope(isTeam);
              context.read<DashboardProvider>().setTeamScope(isTeam);
            },
            onApply: _applyFilters,
          ),
        ),
        if (!showLoading && !showError && !showEmptyState)
          StatusFilterChipRow(
            options: _statusFilters,
            selected: _statusFilter,
            onSelected: (v) => setState(() => _statusFilter = v),
          ),
        if (agenda != null)
          AgendaPastBar(
            agenda: agenda,
            expanded: _expansion.pastExpanded,
            onTap: _togglePast,
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _refresh,
            // RefreshIndicator's default onEdge mode only arms on a drag
            // that starts with metrics.extentBefore == 0.0. With `center:
            // _todayKey` (see _buildAgenda), the collapsed past region
            // sits at negative scroll offsets, so minScrollExtent is
            // already negative at rest — extentBefore is that region's
            // own collapsed height, never 0, even though the list visibly
            // isn't scrolled anywhere. onEdge would need a first pull just
            // to reach true offset 0 before a second pull actually arms
            // it. `anywhere` accepts a drag starting from any position.
            triggerMode: RefreshIndicatorTriggerMode.anywhere,
            child: showAgenda
                ? _buildAgenda(agenda!)
                : _buildPlaceholder(
                    showLoading: showLoading,
                    showError: showError,
                    showEmptyState: showEmptyState,
                    errorMessage: provider.errorMessage,
                  ),
          ),
        ),
      ],
    );
  }

  // Loading / error / "nothing at all" / "nothing matching this chip".
  // Still a scrollable (AlwaysScrollableScrollPhysics over a
  // viewport-height box) rather than a bare centred widget, so
  // pull-to-refresh works on a screen with no content to pull — which is
  // the screen most likely to need a retry.
  Widget _buildPlaceholder({
    required bool showLoading,
    required bool showError,
    required bool showEmptyState,
    required String? errorMessage,
  }) {
    final height = MediaQuery.of(context).size.height;
    final Widget child;
    if (showLoading) {
      child = SizedBox(height: height * 0.6, child: const AppLoading());
    } else if (showError) {
      child = SizedBox(
        height: height * 0.6,
        child: ErrorState(message: errorMessage ?? '', onRetry: _refresh),
      );
    } else if (showEmptyState) {
      // provider.audits is already the FILTERED list (fetchMyAudits sends
      // AuditFilterScope's own params), so an empty result here can mean
      // either "genuinely nothing assigned" or "a location/audit-type/
      // people filter — possibly set from the Dashboard or Calendar, not
      // touched on this screen at all — narrowed it to nothing". Showing
      // the plain "no audits assigned" message in the second case reads
      // as this auditor having no work at all, when the truth is a filter
      // is hiding it; the Filters button above stays the way in either
      // way, but only the filtered case gets a direct Clear here too.
      final provider = context.read<AuditsProvider>();
      child = SizedBox(
        height: height * 0.6,
        child: provider.hasActiveFilters
            ? EmptyState(
                icon: Icons.filter_alt_off_outlined,
                title: 'No audits match your filters',
                subtitle: 'Try widening the team, location or audit type.',
                action: OutlinedButton.icon(
                  onPressed: () => provider.clearFilters(),
                  icon: const Icon(Icons.filter_alt_off_outlined),
                  label: const Text('Clear filters'),
                ),
              )
            : const EmptyState(
                icon: Icons.assignment_outlined,
                title: 'No audits assigned',
                subtitle: 'Audits assigned to you will appear here.',
              ),
      );
    } else {
      // There IS data — the on-screen narrowing (status chip and/or the
      // search box) is what emptied the list. Distinct from
      // showEmptyState above, which means the provider's own server-side
      // filters returned nothing, so the way out is different: offer the
      // search reset here, not clearFilters().
      final searchTerm = _search.trim();
      final searching = searchTerm.isNotEmpty;
      child = SizedBox(
        height: height * 0.5,
        child: EmptyState(
          icon: searching ? Icons.search_off : Icons.filter_alt_off_outlined,
          title: searching
              ? 'No audits match "$searchTerm"'
              : 'No $_statusFilter audits',
          // Both narrowings active at once is the case most likely to
          // read as "the search is broken" — name the other one so the
          // user knows there is a second thing hiding results.
          subtitle: searching && _statusFilter != 'All'
              ? 'Also filtered to $_statusFilter audits.'
              : null,
          action: searching
              ? OutlinedButton.icon(
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _search = '');
                  },
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear search'),
                )
              : null,
        ),
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [child],
    );
  }

  /// THE ANCHOR, and the whole reason this is a CustomScrollView rather
  /// than a ListView.
  ///
  /// `center: _todayKey` splits the sliver list in two. Slivers listed
  /// BEFORE the centre key lay out in the REVERSE growth direction —
  /// upward from scroll offset 0 — so the past region hangs above the
  /// viewport with its BOTTOM edge on the centre boundary; the centre
  /// sliver and everything after it grow downward as usual. First paint
  /// therefore starts at offset 0, which is the top of the Today section,
  /// with the past already sitting above it and reachable by scrolling
  /// up. A sliver in the reverse region still lays its own contents out
  /// top-to-bottom, so AgendaPastRegion needs no reversing of its own.
  ///
  /// Deliberately NOT done by measuring section heights and jumping a
  /// ScrollController in a post-frame callback: that flashes the past
  /// content for a frame on every single build (including every refresh
  /// and every status-chip tap), and it fights the user — any jump that
  /// lands after the user has started scrolling yanks the list out from
  /// under their thumb. The centre sliver has no first-frame position to
  /// correct, because it never starts anywhere else.
  ///
  /// It also makes expanding the past region free: because that sliver is
  /// anchored by its bottom edge, growing it pushes content up into more
  /// negative offsets and Today does not move at all.
  Widget _buildAgenda(AuditAgenda agenda) {
    const horizontal = EdgeInsets.symmetric(horizontal: 16);

    return Stack(
      children: [
        CustomScrollView(
          controller: _scroll,
          center: _todayKey,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            // 1. Past — the reverse region, above the anchor. Its own
            // toggle row is AgendaPastBar, pinned above this whole scroll
            // view in build() — this sliver only ever holds the actual
            // past month sections, once expanded.
            //
            // onChanged: _onPastRegionChanged, NOT the plain
            // _onExpansionChanged every forward section below uses — see
            // that method's own doc. AgendaPastRegion forwards whichever
            // onChanged it's given straight down to every nested
            // AgendaMonthSection/AgendaSeriesGroup it renders, so this one
            // swap is what makes a month or series toggled ONCE ALREADY
            // inside the past region also re-scroll to keep up with it,
            // without AgendaPastRegion itself needing to know why.
            SliverToBoxAdapter(
              child: Padding(
                padding: horizontal,
                child: AgendaPastRegion(
                  agenda: agenda,
                  expansion: _expansion,
                  onChanged: _onPastRegionChanged,
                ),
              ),
            ),
            // 2. Today — the centre. Always present, even when empty:
            // the anchor cannot be data-dependent or the screen would
            // open somewhere different depending on the schedule.
            SliverToBoxAdapter(
              key: _todayKey,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: AgendaTodaySection(
                  today: agenda.today,
                  audits: agenda.todayAudits,
                  hasHiddenPastContent: _onlyPastHasContent(agenda),
                  onViewPast: () => _viewPast(agenda),
                ),
              ),
            ),
            // 3. Tomorrow and the rest of the seven-day window, one
            // sliver per day so a busy day expanding/collapsing only
            // rebuilds its own box.
            for (final group in agenda.nextSevenDays)
              SliverToBoxAdapter(
                child: Padding(
                  padding: horizontal,
                  child: AgendaDaySection(
                    group: group,
                    today: agenda.today,
                    expanded:
                        _expansion.isDayExpanded(agendaDayKey(group.day)),
                    onToggle: () {
                      _expansion.toggleDay(agendaDayKey(group.day));
                      _onExpansionChanged();
                    },
                  ),
                ),
              ),
            // 4. What is left of this month after the seven-day window.
            // Absent (not empty-with-a-header) when the window has
            // already spilled into next month — see buildAuditAgenda's
            // note on the `day > horizon` rule.
            if (agenda.restOfThisMonth.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: horizontal,
                  child: AgendaMonthSection(
                    label: 'Rest of ${DateFormat('MMMM').format(agenda.today)}',
                    groupKey: 'rest-of-month',
                    audits: agenda.restOfThisMonth,
                    today: agenda.today,
                    expansion: _expansion,
                    onChanged: _onExpansionChanged,
                  ),
                ),
              ),
            // 5. The nearest 3 months after this one, by name, then
            // (only once there is anything further out than that)
            // increasingly wide range buckets — "Next 6 Months", "Next
            // Year", "Later" — each drilling month-wise then day-wise
            // instead of the agenda growing one flat row per future
            // month forever. See AuditAgenda.recentLaterMonths/
            // futureBuckets' own docs.
            for (final month in agenda.recentLaterMonths)
              SliverToBoxAdapter(
                child: Padding(
                  padding: horizontal,
                  child: AgendaMonthSection(
                    label: agendaMonthLabel(month.month),
                    groupKey: agendaMonthKey(month.month),
                    audits: month.audits,
                    today: agenda.today,
                    expansion: _expansion,
                    onChanged: _onExpansionChanged,
                  ),
                ),
              ),
            for (final bucket in agenda.futureBuckets)
              SliverToBoxAdapter(
                child: Padding(
                  padding: horizontal,
                  child: AgendaRangeBucketSection(
                    bucket: bucket,
                    today: agenda.today,
                    expansion: _expansion,
                    onChanged: _onExpansionChanged,
                  ),
                ),
              ),
            // 6. Audits with no scheduled date at all — nowhere to put
            // them on a timeline, so they get the very bottom rather than
            // being dropped from a list that claims to be everything
            // assigned to you.
            if (agenda.undated.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: horizontal,
                  child: _UndatedSection(
                    audits: agenda.undated,
                    today: agenda.today,
                    expanded: _expansion.isMonthExpanded('undated'),
                    onToggle: () {
                      _expansion.toggleMonth('undated');
                      _onExpansionChanged();
                    },
                  ),
                ),
              ),
            // 7. Room for the floating Today pill to sit over dead space
            // instead of over the last card.
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
        _TodayJumpButton(target: _jump, onTap: _jumpToToday),
      ],
    );
  }

  // The agenda sections mutate _expansion directly (it is plain state,
  // not a Listenable) and then call this so the one setState that has to
  // happen happens in exactly one place.
  void _onExpansionChanged() => setState(() {});
}

/// The "No date set" group. Its own small widget rather than another
/// AgendaMonthSection because a month section collapses recurring series
/// by date span, and a series with no dates at all would render its span
/// as "-" — honest, but it reads as a rendering failure.
class _UndatedSection extends StatelessWidget {
  final List<AuditModel> audits;
  final DateTime today;
  final bool expanded;
  final VoidCallback onToggle;

  const _UndatedSection({
    required this.audits,
    required this.today,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AgendaSectionHeader(
          label: 'No date set',
          count: audits.length,
          expanded: expanded,
          onTap: onToggle,
          icon: Icons.event_busy_outlined,
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          for (final audit in audits) ...[
            RepaintBoundary(
              // showDate: false — Formatters.date(null) is "-", and a
              // date slot reading "-" on every card in a group already
              // headed "No date set" is pure noise.
              child: AgendaAuditCard(
                audit: audit,
                today: today,
                showDate: false,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }
}

/// The jump-back-to-Today pill.
///
/// AppShell owns the Scaffold and this screen is one page of its
/// PageView, so there is no floatingActionButton slot to put this in — it
/// is a Positioned child of a Stack wrapping the scroll view instead,
/// sitting above where the NavigationBar ends (the Scaffold body excludes
/// the nav bar, so `bottom` is measured from the top of it).
///
/// Hidden by opacity AND by IgnorePointer, not by being absent: a widget
/// that is rebuilt into and out of existence can't cross-fade, and an
/// invisible-but-present button would still swallow taps meant for the
/// card underneath it.
class _TodayJumpButton extends StatelessWidget {
  final ValueListenable<_JumpTarget> target;
  final VoidCallback onTap;

  const _TodayJumpButton({required this.target, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: Center(
        child: ValueListenableBuilder<_JumpTarget>(
          valueListenable: target,
          builder: (context, value, child) {
            final hidden = value == _JumpTarget.hidden;
            return IgnorePointer(
              ignoring: hidden,
              child: AnimatedOpacity(
                opacity: hidden ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                child: Material(
                  color: scheme.inverseSurface,
                  borderRadius: BorderRadius.circular(999),
                  elevation: 3,
                  shadowColor: scheme.shadow,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            // Points the way the list will travel: up
                            // when Today is above you, down when you have
                            // scrolled up into the past.
                            value == _JumpTarget.down
                                ? Icons.keyboard_arrow_down_rounded
                                : Icons.keyboard_arrow_up_rounded,
                            size: 18,
                            color: scheme.onInverseSurface,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Today',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: scheme.onInverseSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
