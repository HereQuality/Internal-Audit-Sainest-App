import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/nc_model.dart';
import '../../models/nc_report_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/list_view_memory.dart';
import '../../providers/nc_paged_list.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart' show AuditFilterSelection, applyAuditFilterSelection;
import '../../widgets/audit_filter_bar.dart';
import '../../widgets/max_width_scroll.dart';
import '../../widgets/nc_page_footer.dart';
import '../../widgets/report_tiles.dart';
import '../../widgets/status_badge.dart';
import 'nc_response_screen.dart';
import 'nc_review_screen.dart';

/// Same split as the web app: "Raised by me" (auditor — NCManagement.jsx)
/// and "Against me" (auditee — Auditee.jsx). One person can appear in
/// both; each list is independently scoped server-side.
///
/// `mode` restricts which side is shown — the Auditor tab set only wants
/// "raised by me" (NC Monitoring is the auditor's own), the Auditee tab
/// set only wants "against me" (the NCs given to them). Null (default)
/// shows both as tabs, same as before.
enum NcListMode { auditorOnly, auditeeOnly }

// Two different vocabularies, one per side — each mirroring exactly the
// stat tiles its OWN dashboard shows (AuditorDashboard's NC Monitoring
// card / AuditeeDashboardScreen's NC grid), not a shared ten-value list.
// That combined list used to offer every raw status (Raised/Response
// Submitted/Verification/Closed) right alongside the derived buckets
// (In Progress/Pending Approval/Overdue/On Time/Delayed) on BOTH sides,
// which is a lot of half-overlapping options to scan on a phone — "Pending
// Approval" and "Response Submitted" read as two different things until
// you realise one is a raw status and the other already includes it. Each
// value still means the SAME as before (same mutually-exclusive bucket rules
// as server's nc.controller.js#computeNcBuckets — but the SERVER now applies
// them: a stored status goes as `status=`, a derived bucket as the ids the
// stat tiles counted, see nc_paged_list.dart#ncChipQuery), only which values
// are OFFERED narrows per screen.
//
// Auditor ("Raised by me" / NC Monitoring) — Total NC / Awaiting Approval
// / Overdue / Closed, the 4 tiles on AuditorDashboard's own NC card.
// 'Pending Approval' is the underlying value (Response Submitted or
// Verification, not yet overdue) that tile's own "Awaiting Approval" label
// describes; the raw Raised/Response Submitted/Verification split and the
// auditee-side In Progress/On Time/Delayed tracking THEIR OWN response speed
// aren't a distinction the raising auditor's own dashboard makes, so neither
// is this list.
const _auditorStatusFilters = ['All', 'Pending Approval', 'Overdue', 'Closed'];
const _auditorStatusFilterLabels = {
  'All': 'Total NC',
  'Pending Approval': 'Awaiting Approval',
};

// Auditee ("Against me") — Total NC / In Progress / Overdue / Pending
// Approval / Delayed / On Time Completion, the 6 tiles on
// AuditeeDashboardScreen's own NC grid, in that same order. Drops the 4
// raw statuses (Raised/Response Submitted/Verification/Closed) — each is
// already folded into exactly one of these 6 buckets (a rejected-and-
// resent NC goes back to "Raised", i.e. 'In Progress', same as new).
const _auditeeStatusFilters = [
  'All',
  'In Progress',
  'Overdue',
  'Pending Approval',
  'Delayed',
  'On Time',
];
const _auditeeStatusFilterLabels = {
  'All': 'Total NC',
  'On Time': 'On Time Completion',
};

// The six tiles NC Monitoring shows (GET /ncs/raised/stats) speak in the
// server's bucket keys; the list's own filter speaks in the labels above. A
// tile tap sets the same chip a dashboard jump does, so the two are one
// mechanism — this map just translates.
const _bucketFilterLabels = {
  NcBucket.inProgress: 'In Progress',
  NcBucket.overdue: 'Overdue',
  NcBucket.pendingApproval: 'Pending Approval',
  NcBucket.delayed: 'Delayed',
  NcBucket.onTime: 'On Time',
};

class NcListScreen extends StatefulWidget {
  final NcListMode? mode;
  // Pre-applies one of _auditorStatusFilters/_auditeeStatusFilters above
  // (whichever side is showing) — set by AppShell when a dashboard stat
  // tile is tapped (AuditorDashboard's NC Pending tile, or
  // AuditeeDashboardScreen's _AuditeeStatsGrid), remounted under a fresh
  // key each time so this always takes effect even when the tile tapped
  // is the same filter already showing.
  final String? initialStatusFilter;

  const NcListScreen({super.key, this.mode, this.initialStatusFilter});

  @override
  State<NcListScreen> createState() => _NcListScreenState();
}

class _NcListScreenState extends State<NcListScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    if (widget.mode == null) {
      _tabController = TabController(length: 2, vsync: this);
    }
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  // Each list loads itself (one page at a time) when it is first built — see
  // _NcListBodyState — so a side that is never opened never asks the server.
  @override
  Widget build(BuildContext context) {
    if (widget.mode == NcListMode.auditorOnly) {
      return _NcListBody(raised: true, initialStatusFilter: widget.initialStatusFilter);
    }
    if (widget.mode == NcListMode.auditeeOnly) {
      return _NcListBody(raised: false, initialStatusFilter: widget.initialStatusFilter);
    }
    return Column(
      children: [
        TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Raised by me'),
            Tab(text: 'Against me'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _NcListBody(raised: true, initialStatusFilter: widget.initialStatusFilter),
              _NcListBody(raised: false, initialStatusFilter: widget.initialStatusFilter),
            ],
          ),
        ),
      ],
    );
  }
}

// Shared by both lists below — the shared filter bar (Me / All Members, the
// Filters sheet with Team, Members, Location + Department, Audit Type, Date
// range and Flag, and the removable pills), then a search box and the NC
// status chips (single-select — the same six/four buckets as this side's own
// dashboard tiles, see _auditorStatusFilters / _auditeeStatusFilters).
//
// The filters themselves are the shared app-wide state (NcProvider holds them
// like AuditsProvider/DashboardProvider; see applyAuditFilterSelection) and go
// to GET /ncs/raised / /ncs/mine as query params, so they filter server-side
// exactly as on the web. The chip, the search text and the scroll offset are
// remembered in ListViewMemory, so opening an NC and pressing Back finds the
// list as it was.
class _NcListHeader extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final String statusFilter;
  final ValueChanged<String> onStatusChanged;

  /// Which values this side offers — _auditorStatusFilters or
  /// _auditeeStatusFilters — and their display labels.
  final List<String> filters;
  final Map<String, String> labels;

  const _NcListHeader({
    required this.searchController,
    required this.onSearchChanged,
    required this.statusFilter,
    required this.onStatusChanged,
    required this.filters,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Kept visible through loading/error/empty too — an empty "Me"
        // list is exactly when widening to All Members matters most.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: const AuditFilterBar(showFlag: true),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search NCs, audit, person...',
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'Clear search',
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                    ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Nothing came back under the filters" — distinct from "you have none", so
/// a filter can never read as a clean record. Offers the way out.
Widget _filteredEmpty(BuildContext context) => EmptyState(
  icon: Icons.filter_alt_off_outlined,
  title: 'No NCs match your filters',
  subtitle: 'Try widening the people, place, date or flag.',
  action: OutlinedButton.icon(
    onPressed: () =>
        applyAuditFilterSelection(context, AuditFilterSelection.cleared),
    icon: const Icon(Icons.filter_alt_off_outlined),
    label: const Text('Clear filters'),
  ),
);

/// One side's NC list — "Raised by me" (auditor, [raised]) or "Against me"
/// (auditee) — one page at a time.
///
/// The first page loads when the screen opens, on a filter / chip / search change
/// and on pull-to-refresh; the next pages follow by themselves as the user scrolls
/// within [ncLoadMoreExtent] of the end (a small spinner at the foot; "Try again"
/// when a page failed) until the server's total is on screen. The status chip and
/// the search text are the SERVER's (NcPagedList sends them), so the list is a
/// list of what is being looked at, however long.
class _NcListBody extends StatefulWidget {
  final bool raised;
  final String? initialStatusFilter;

  const _NcListBody({required this.raised, this.initialStatusFilter});

  @override
  State<_NcListBody> createState() => _NcListBodyState();
}

class _NcListBodyState extends State<_NcListBody> {
  /// Search text goes to the server this long after the last keystroke.
  static const _searchDelay = Duration(milliseconds: 400);

  late final NcProvider _provider;
  late final String _memoryId;
  late final ListScreenMemory _saved;
  late String _statusFilter;
  late final TextEditingController _search;
  late final ScrollController _scroll;
  Timer? _debounce;
  bool _afterBuildQueued = false;
  // How many first pages had landed when this screen last looked: one more means
  // the list was replaced (a filter moved) and the scroll goes back to the top.
  late int _seenFirstPages;
  String _query = '';

  NcPagedList get _list => widget.raised ? _provider.raisedList : _provider.mineList;

  @override
  void initState() {
    super.initState();
    _provider = context.read<NcProvider>();
    _memoryId = widget.raised ? 'nc-raised' : 'nc-against';
    final memory = context.read<ListViewMemory>();
    // A dashboard tile jump re-keys this screen with the tile's own filter:
    // start fresh for it. A plain remount keeps what was remembered.
    if (widget.initialStatusFilter != null) memory.forget(_memoryId);
    _saved = memory.screen(_memoryId);
    if (widget.initialStatusFilter != null) {
      _saved.chip = widget.initialStatusFilter!;
    }
    _statusFilter = _saved.chip;
    _query = _saved.search;
    _search = TextEditingController(text: _saved.search);
    _scroll = ScrollController(initialScrollOffset: _saved.scroll)..addListener(_onScroll);
    // What the list holds must be the chip and search this screen shows, from its
    // first build (a list left narrowed otherwise is dropped here, and read again
    // below).
    _list.setNarrowing(chip: _statusFilter, search: _query);
    _seenFirstPages = _list.firstPageCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _open() {
    // Must be set before the fetch below — see DashboardProvider/
    // AuditsProvider's identical _scopeParams pattern: "Me" resolves to an
    // explicit employeeIds=<selfId>, which needs this known first. The auditee
    // side needs it just the same (it too is "Me" by default).
    final selfId = context.read<AuthProvider>().user?.id;
    if (selfId != null) _provider.setSelfEmployeeId(selfId);
    if (widget.raised) {
      // A list that still holds what this screen was left showing is refreshed
      // in place (its scroll position is still good), else page 1 is read.
      _provider.openRaised();
      _provider.fetchRaisedStats();
    } else {
      _provider.openAgainstMe();
    }
  }

  /// Page 1 again (and, for NC Monitoring, its tiles) — pull-to-refresh and the
  /// error state's Retry.
  Future<void> _refresh() => widget.raised
      ? Future.wait([_provider.fetchRaisedByMe(), _provider.fetchRaisedStats()])
      : _provider.fetchAgainstMe();

  // A chip, tile or search change: the server answers it, so page 1 is read again
  // (the tile ids it needs are already held — only a filter change asks for them
  // afresh).
  void _reload() => widget.raised
      ? _provider.fetchRaisedByMe(fresh: false)
      : _provider.fetchAgainstMe(fresh: false);

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _saved.scroll = _scroll.offset;
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    final list = _list;
    if (list.pagerMode) return; // Prev/Next, not scrolling, moves between pages
    if (!list.hasMore || list.isLoading || list.isLoadingMore) return;
    if (nearListEnd(_scroll)) list.loadMore();
  }

  // After each build: scroll back to the top when the list was replaced, and keep
  // loading while the end is still near (a tall screen — or a short page — would
  // otherwise never scroll, so never ask for more).
  void _afterBuild(NcPagedList list) {
    if (_afterBuildQueued) return;
    final replaced = list.firstPageCount != _seenFirstPages;
    final canLoad = !list.pagerMode && list.hasMore && !list.isLoading && !list.isLoadingMore && list.moreError == null;
    if (!replaced && !canLoad) return;
    _afterBuildQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _afterBuildQueued = false;
      if (!mounted) return;
      if (_list.firstPageCount != _seenFirstPages) {
        _seenFirstPages = _list.firstPageCount;
        _saved.scroll = 0;
        if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
      }
      _maybeLoadMore();
    });
  }

  void _onSearch(String v) {
    _saved.search = v;
    setState(() => _query = v);
    _debounce?.cancel();
    void apply() {
      if (mounted && _list.setNarrowing(search: v)) _reload();
    }

    if (v.trim().isEmpty) {
      apply();
    } else {
      _debounce = Timer(_searchDelay, apply);
    }
  }

  void _onStatus(String v) {
    _saved.chip = v;
    setState(() => _statusFilter = v);
    if (_list.setNarrowing(chip: v)) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NcProvider>();
    final list = _list;
    final items = list.items;
    final showError = list.error != null && items.isEmpty;
    final showLoading = !showError && items.isEmpty && (list.isLoading || !list.hasLoaded);
    final showEmpty = !showLoading && !showError && items.isEmpty;
    // Narrowed by the chip or the search (the server answered with none), as
    // against nothing at all under the shared filters.
    final narrowed = list.chip != 'All' || list.search.isNotEmpty;
    // A tile's own filter narrows by the NC ids the server counted under it, so
    // the list under a tile always has exactly the tile's number of rows.
    final stats = widget.raised ? provider.raisedStats : null;
    final bucket = ncBucketOfChip(_statusFilter);
    _afterBuild(list);
    return Column(
      children: [
        // Kept visible through loading/error/empty too — an empty "Me"
        // list (nobody raised against your own scope) is exactly when
        // switching to "Team" to check your reports' NCs matters most. The
        // auditee side has the same Me/Team scope as the web app's
        // Auditee.jsx TeamFilterPanel.
        _NcListHeader(
          searchController: _search,
          onSearchChanged: _onSearch,
          statusFilter: _statusFilter,
          onStatusChanged: _onStatus,
          filters: widget.raised ? _auditorStatusFilters : _auditeeStatusFilters,
          labels: widget.raised ? _auditorStatusFilterLabels : _auditeeStatusFilterLabels,
        ),
        // The same six tiles as the Final Report's NCs tab and the Auditee
        // dashboard — Total NC, In Progress, Overdue, Pending Approval,
        // Delayed, On Time Completion — under the same filters as the list.
        // Each is a tap-filter; Total NC clears it.
        if (stats != null && stats.hasBuckets)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: ReportTileGrid(
              tiles: ncBucketTiles(
                stats,
                selected: {?bucket},
                onToggle: (b) => _onStatus(
                  bucket == b ? 'All' : _bucketFilterLabels[b]!,
                ),
                onClear: () => _onStatus('All'),
              ),
            ),
          ),
        // The server's own count of what the list holds, however many pages
        // are on screen so far.
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
            child: Row(
              children: [
                Expanded(
                  child: NcCountLine(
                    loaded: items.length,
                    total: list.total,
                    hasMore: list.hasMore,
                    offset: list.pagerMode ? ((list.windowPage ?? 1) - 1) * NcPagedList.pageSize : 0,
                  ),
                ),
                // The same Prev/Next as the foot of the list, small, so a long page needs no scroll to turn.
                if (list.pagerMode)
                  NcPagerCompact(
                    page: list.windowPage ?? 1,
                    totalPages: list.totalPages,
                    busy: list.isLoading,
                    onPage: list.goToPage,
                  ),
              ],
            ),
          ),
        Expanded(
          // MaxWidthScroll wraps this whole branch (loading/error/empty
          // states included, not just the ListView) — a thin wrap around
          // "whatever this Expanded shows", the same one-line-per-screen
          // approach as every other call site, rather than threading it
          // into just the ListView/ListView.separated branch.
          child: MaxWidthScroll(
            child: showLoading
                ? const AppLoading()
                : showError
                ? ErrorState(message: list.error!, onRetry: _refresh)
                : showEmpty && !narrowed
                ? (provider.hasActiveFilters
                      ? _filteredEmpty(context)
                      : EmptyState(
                          icon: widget.raised
                              ? Icons.fact_check_outlined
                              : Icons.thumb_up_outlined,
                          title: widget.raised
                              ? 'No NCs raised yet'
                              : 'No NCs against you — great work!',
                        ))
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: showEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              SizedBox(
                                height: MediaQuery.of(context).size.height * 0.5,
                                child: EmptyState(
                                  icon: Icons.filter_alt_off_outlined,
                                  title: list.search.isNotEmpty
                                      ? 'No NCs match "${list.search}"'
                                      : 'No ${_statusFilter == 'All' ? '' : '$_statusFilter '}NCs',
                                ),
                              ),
                            ],
                          )
                        : ListView.separated(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            itemCount: items.length + 1,
                            separatorBuilder: (_, _) => const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              if (i == items.length) {
                                if (list.pagerMode) {
                                  return Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (list.moreError != null)
                                        Padding(
                                          padding: const EdgeInsets.only(top: 4),
                                          child: Text(
                                            list.moreError!,
                                            textAlign: TextAlign.center,
                                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: Theme.of(context).colorScheme.error,
                                            ),
                                          ),
                                        ),
                                      NcPagerBar(
                                        page: list.windowPage ?? 1,
                                        totalPages: list.totalPages,
                                        busy: list.isLoading,
                                        onPage: list.goToPage,
                                      ),
                                    ],
                                  );
                                }
                                return NcPageFooter(
                                  hasMore: list.hasMore,
                                  isLoadingMore: list.isLoadingMore,
                                  error: list.moreError,
                                  onRetry: () => list.loadMore(retry: true),
                                );
                              }
                              return _card(context, items[i]);
                            },
                          ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _card(BuildContext context, NcModel nc) {
    if (widget.raised) {
      return _NcCard(
        nc: nc,
        subtitle: 'Against ${nc.auditee.name}',
        actionLabel: (nc.status == 'Response Submitted' || nc.status == 'Verification')
            ? 'Review'
            : (nc.status == 'Closed' ? 'View' : null),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => NcReviewScreen(nc: nc)),
        ),
      );
    }
    return _NcCard(
      nc: nc,
      subtitle: 'Raised by ${nc.raisedBy.name}',
      actionLabel: nc.status == 'Raised' ? 'Respond' : null,
      onTap: () {
        if (nc.status == 'Raised') {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => NcResponseScreen(nc: nc)),
          );
        } else {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => NcReviewScreen(nc: nc)),
          );
        }
      },
    );
  }
}

class _NcCard extends StatelessWidget {
  final NcModel nc;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback onTap;

  const _NcCard({
    required this.nc,
    required this.subtitle,
    required this.actionLabel,
    required this.onTap,
  });

  // A rejected-and-sent-back NC (server: nc.controller.js#verifyNC's
  // "Reject" branch — status goes right back to "Raised", same as a fresh
  // NC, only reopenCount/verificationNote distinguish it) looked
  // identical to a brand-new one on this list — the auditee had no way to
  // tell "this needs a re-response, here's what was wrong" without
  // opening it. nc_response_screen.dart already shows the rejection note
  // once opened; this just surfaces the same signal on the card itself.
  bool get _isReopened => nc.status == 'Raised' && nc.reopenCount > 0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nc.title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          nc.ncId,
                          style: TextStyle(
                            color: scheme.outline,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Without this a long NC title ran straight into the status
                  // badge with no gap at all.
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusBadge(
                        label: nc.status,
                        color: AppColors.forNcStatus(nc.status),
                      ),
                      if (_isReopened) ...[
                        const SizedBox(height: 4),
                        const StatusBadge(
                          label: 'Reopened',
                          color: AppColors.red,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              if (_isReopened && (nc.verificationNote ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(color: AppColors.red, width: 3),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.replay_outlined,
                        size: 13,
                        color: AppColors.readable(context, AppColors.red),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Rejected: ${nc.verificationNote}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.readable(context, AppColors.red),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Icon(Icons.event_outlined, size: 13, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    Formatters.date(nc.targetDate),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    onPressed: onTap,
                    child: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
