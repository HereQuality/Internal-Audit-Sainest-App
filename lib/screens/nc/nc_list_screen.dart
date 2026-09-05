import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/nc_timeliness.dart';
import '../../models/nc_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart' show FilterButton;
import '../../widgets/scope_toggle.dart';
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
// value still runs through the SAME _matchesFilter below (same mutually-
// exclusive bucket rules as server's nc.controller.js#computeNcBuckets),
// only which values are OFFERED narrows per screen.
//
// Auditor ("Raised by me" / NC Monitoring) — Total NC / Awaiting Approval
// / Overdue / Closed, the 4 tiles on AuditorDashboard's own NC card.
// 'Pending Approval' is the underlying value (Response Submitted or
// Verification, not yet overdue — see _matchesFilter) that tile's own
// "Awaiting Approval" label describes; the raw Raised/Response Submitted/
// Verification split and the auditee-side In Progress/On Time/Delayed
// tracking THEIR OWN response speed aren't a distinction the raising
// auditor's own dashboard makes, so neither is this list.
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

// Same bucket rules as server/controllers/nc.controller.js#computeNcBuckets
// — kept in sync by hand since there's no shared-across-platforms source
// of truth for this logic (mirrors today_ncs_section.dart's own
// _dueToday/_overdue/_ongoing helpers, just as exact-match filter
// predicates instead of a "what's due soon" summary).
bool _matchesFilter(NcModel n, String filter) {
  if (filter == 'All') return true;
  // Not one of _auditorStatusFilters/_auditeeStatusFilters — this is the
  // value DashboardScreen's own "NC Pending" tile jumps here with
  // (stats.ncPending counts server-side `status != "Closed"`, i.e. every
  // OPEN status regardless of overdue-ness: Raised, Response Submitted AND
  // Verification). Neither side's picker offers a single chip for exactly
  // that ("Awaiting Approval"/'Pending Approval' excludes plain Raised,
  // same as the web app's own tile; 'Overdue' excludes a Raised-but-not-
  // yet-overdue NC) — deliberately outside the trimmed vocabulary rather
  // than adding a 7th/5th option nobody would tap on purpose, the same way
  // a tile-driven jump to a raw status ('Closed', say) needs no chip of
  // its own either.
  if (filter == 'Open') return n.status != 'Closed';
  if (![
    'In Progress',
    'Pending Approval',
    'Overdue',
    'On Time',
    'Delayed',
  ].contains(filter)) {
    return n.status == filter;
  }
  final target = n.targetDate;
  if (n.status == 'Closed') {
    final completed = n.completionDate;
    final isDelayed = target != null &&
        completed != null &&
        completed.isAfter(effectiveDeadline(target));
    if (filter == 'Delayed') return isDelayed;
    if (filter == 'On Time') return !isDelayed;
    return false;
  }
  final isOverdue = target != null && DateTime.now().isAfter(effectiveDeadline(target));
  if (filter == 'Overdue') return isOverdue;
  if (isOverdue) return false;
  if (filter == 'In Progress') return n.status == 'Raised';
  if (filter == 'Pending Approval')
    return n.status == 'Response Submitted' || n.status == 'Verification';
  return false;
}

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

  bool get _showRaised => widget.mode != NcListMode.auditeeOnly;
  bool get _showAgainst => widget.mode != NcListMode.auditorOnly;

  @override
  void initState() {
    super.initState();
    if (widget.mode == null) {
      _tabController = TabController(length: 2, vsync: this);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<NcProvider>();
      // Must be set before either fetch below — see DashboardProvider/
      // AuditsProvider's identical _scopeParams pattern: "Me" resolves to an
      // explicit employeeIds=<selfId>, which needs this known first. Used to
      // only run when _showRaised (auditor mode) — an auditee-only session
      // (widget.mode == auditeeOnly) never hit this at all, on this screen
      // or on AuditeeDashboardScreen, so fetchAgainstMe's own "Me" scope
      // below silently ran unscoped instead.
      final selfId = context.read<AuthProvider>().user?.id;
      if (selfId != null) provider.setSelfEmployeeId(selfId);
      if (_showRaised) provider.fetchRaisedByMe();
      if (_showAgainst) provider.fetchAgainstMe();
    });
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mode == NcListMode.auditorOnly) {
      return _RaisedByMeList(
        onRefresh: () => context.read<NcProvider>().fetchRaisedByMe(),
        initialStatusFilter: widget.initialStatusFilter,
      );
    }
    if (widget.mode == NcListMode.auditeeOnly) {
      return _AgainstMeList(
        onRefresh: () => context.read<NcProvider>().fetchAgainstMe(),
        initialStatusFilter: widget.initialStatusFilter,
      );
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
              _RaisedByMeList(
                onRefresh: () => context.read<NcProvider>().fetchRaisedByMe(),
                initialStatusFilter: widget.initialStatusFilter,
              ),
              _AgainstMeList(
                onRefresh: () => context.read<NcProvider>().fetchAgainstMe(),
                initialStatusFilter: widget.initialStatusFilter,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Shared by both lists below — Me/Team on the left, the status Filters
// button on the right, same spaceBetween header-row shape as
// DashboardFilterBar/MyAuditsScreen use for their own scope+filter rows.
//
// This used to be a permanently-visible horizontal row of ALL TEN status
// chips (StatusFilterChipRow, one per _ncStatusFilters entry) sitting
// under the ScopeToggle — on a phone that's a wall of pills wide enough
// that most of them scroll off-screen, and "In Progress"/"Pending
// Approval"/"Overdue"/"On Time"/"Delayed" (the derived buckets) sitting
// right next to "Raised"/"Response Submitted"/"Verification"/"Closed"
// (the raw statuses) reads as one undifferentiated cluster. A single
// "Filters" button opening a picker sheet (see showNcStatusFilterSheet)
// keeps the status choice one tap away without permanently spending
// screen space on nine options nobody has picked.
class _NcListFilterRow extends StatelessWidget {
  final bool isTeam;
  final ValueChanged<bool> onScopeChanged;
  final String statusFilter;
  final ValueChanged<String> onStatusChanged;

  /// Which values this side's sheet offers — _auditorStatusFilters or
  /// _auditeeStatusFilters — and their display labels.
  final List<String> filters;
  final Map<String, String> labels;

  const _NcListFilterRow({
    required this.isTeam,
    required this.onScopeChanged,
    required this.statusFilter,
    required this.onStatusChanged,
    required this.filters,
    required this.labels,
  });

  Future<void> _openStatusSheet(BuildContext context) async {
    final result = await showNcStatusFilterSheet(
      context,
      selected: statusFilter,
      filters: filters,
      labels: labels,
    );
    if (result != null) {
      onStatusChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ScopeToggle(isTeam: isTeam, onChanged: onScopeChanged),
            ),
          ),
        ),
        FilterButton(
          activeCount: statusFilter == 'All' ? 0 : 1,
          onTap: () => _openStatusSheet(context),
        ),
      ],
    );
  }
}

/// The status picker sheet _NcListFilterRow's Filters button opens.
/// Single-select: tapping a row both picks it AND closes the sheet (one
/// tap, no separate Apply step needed for a single value) and returns the
/// chosen filter string; dismissing without picking (tap outside, drag
/// down) returns null and the caller leaves the current filter alone.
Future<String?> showNcStatusFilterSheet(
  BuildContext context, {
  required String selected,
  required List<String> filters,
  required Map<String, String> labels,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NcStatusFilterSheet(
      selected: selected,
      filters: filters,
      labels: labels,
    ),
  );
}

class _NcStatusFilterSheet extends StatelessWidget {
  final String selected;
  final List<String> filters;
  final Map<String, String> labels;

  const _NcStatusFilterSheet({
    required this.selected,
    required this.filters,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // Status is a single tap-to-pick list, never a text field — no
      // keyboard can appear over it — but the same viewInsets padding
      // every other sheet in this app applies costs nothing and keeps
      // this one consistent if a future revision ever adds a search box.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Status',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            const SizedBox(height: 8),
            // Same capped-height, scrollable list convention as every
            // other multi-select sheet in this app (see
            // select_representative_sheet.dart's own identical
            // ConstrainedBox+shrinkWrap pair) — a fixed cap outside any
            // Flexible/Expanded needs no ambiguous parent height to work
            // against, unlike sizing this off a percentage of the sheet's
            // own (itself content-sized) height would.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 400),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final option in filters)
                    _StatusOptionTile(
                      label: labels[option] ?? option,
                      checked: option == selected,
                      onTap: () => Navigator.of(context).pop(option),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusOptionTile extends StatelessWidget {
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _StatusOptionTile({
    required this.label,
    required this.checked,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: checked ? FontWeight.w700 : FontWeight.w500,
                  color: checked ? scheme.primary : scheme.onSurface,
                ),
              ),
            ),
            if (checked)
              Icon(Icons.check_rounded, size: 20, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}

class _RaisedByMeList extends StatefulWidget {
  final Future<void> Function() onRefresh;
  final String? initialStatusFilter;

  const _RaisedByMeList({required this.onRefresh, this.initialStatusFilter});

  @override
  State<_RaisedByMeList> createState() => _RaisedByMeListState();
}

class _RaisedByMeListState extends State<_RaisedByMeList> {
  late String _statusFilter = widget.initialStatusFilter ?? 'All';

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NcProvider>();
    final showLoading = provider.isLoadingRaised && provider.raisedByMe.isEmpty;
    final showError =
        provider.raisedError != null && provider.raisedByMe.isEmpty;
    final showEmpty = !showLoading && !showError && provider.raisedByMe.isEmpty;
    final filtered = provider.raisedByMe
        .where((n) => _matchesFilter(n, _statusFilter))
        .toList();
    return Column(
      children: [
        // Kept visible through loading/error/empty too — an empty "Me"
        // list (nobody raised against your own scope) is exactly when
        // switching to "Team" to check your reports' NCs matters most.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _NcListFilterRow(
            isTeam: provider.isTeamScope,
            onScopeChanged: (isTeam) =>
                context.read<NcProvider>().setTeamScope(isTeam),
            statusFilter: _statusFilter,
            onStatusChanged: (v) => setState(() => _statusFilter = v),
            filters: _auditorStatusFilters,
            labels: _auditorStatusFilterLabels,
          ),
        ),
        Expanded(
          child: showLoading
              ? const AppLoading()
              : showError
              ? ErrorState(
                  message: provider.raisedError!,
                  onRetry: widget.onRefresh,
                )
              : showEmpty
              ? const EmptyState(
                  icon: Icons.fact_check_outlined,
                  title: 'No NCs raised yet',
                )
              : RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(
                              height: MediaQuery.of(context).size.height * 0.5,
                              child: EmptyState(
                                icon: Icons.filter_alt_off_outlined,
                                title: 'No $_statusFilter NCs',
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final nc = filtered[i];
                            return _NcCard(
                              nc: nc,
                              subtitle: 'Against ${nc.auditee.name}',
                              actionLabel:
                                  (nc.status == 'Response Submitted' ||
                                      nc.status == 'Verification')
                                  ? 'Review'
                                  : (nc.status == 'Closed' ? 'View' : null),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => NcReviewScreen(nc: nc),
                                ),
                              ),
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }
}

class _AgainstMeList extends StatefulWidget {
  final Future<void> Function() onRefresh;
  final String? initialStatusFilter;

  const _AgainstMeList({required this.onRefresh, this.initialStatusFilter});

  @override
  State<_AgainstMeList> createState() => _AgainstMeListState();
}

class _AgainstMeListState extends State<_AgainstMeList> {
  late String _statusFilter = widget.initialStatusFilter ?? 'All';

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<NcProvider>();
    final showLoading = provider.isLoadingMine && provider.raisedAgainstMe.isEmpty;
    final showError = provider.mineError != null && provider.raisedAgainstMe.isEmpty;
    final showEmpty = !showLoading && !showError && provider.raisedAgainstMe.isEmpty;
    final filtered = provider.raisedAgainstMe
        .where((n) => _matchesFilter(n, _statusFilter))
        .toList();
    return Column(
      children: [
        // Kept visible through loading/error/empty too — same reasoning as
        // _RaisedByMeList's identical row: an empty "Me" list (nobody's
        // raised anything against your own scope) is exactly when switching
        // to "Team" to check your downstream reports' NCs matters most. Same
        // Me/Team scope as the web app's Auditee.jsx TeamFilterPanel.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: _NcListFilterRow(
            isTeam: provider.isTeamScope,
            onScopeChanged: (isTeam) =>
                context.read<NcProvider>().setTeamScope(isTeam),
            statusFilter: _statusFilter,
            onStatusChanged: (v) => setState(() => _statusFilter = v),
            filters: _auditeeStatusFilters,
            labels: _auditeeStatusFilterLabels,
          ),
        ),
        Expanded(
          child: showLoading
              ? const AppLoading()
              : showError
              ? ErrorState(
                  message: provider.mineError!,
                  onRetry: widget.onRefresh,
                )
              : showEmpty
              ? const EmptyState(
                  icon: Icons.thumb_up_outlined,
                  title: 'No NCs against you — great work!',
                )
              : RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: filtered.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [
                            SizedBox(
                              height: MediaQuery.of(context).size.height * 0.5,
                              child: EmptyState(
                                icon: Icons.filter_alt_off_outlined,
                                title: 'No $_statusFilter NCs',
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: filtered.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (_, i) {
                            final nc = filtered[i];
                            return _NcCard(
                              nc: nc,
                              subtitle: 'Raised by ${nc.raisedBy.name}',
                              actionLabel: nc.status == 'Raised' ? 'Respond' : null,
                              onTap: () {
                                if (nc.status == 'Raised') {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => NcResponseScreen(nc: nc),
                                    ),
                                  );
                                } else {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => NcReviewScreen(nc: nc),
                                    ),
                                  );
                                }
                              },
                            );
                          },
                        ),
                ),
        ),
      ],
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
                      const Icon(
                        Icons.replay_outlined,
                        size: 13,
                        color: AppColors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Rejected: ${nc.verificationNote}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.red,
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
