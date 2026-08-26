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

// "All", the derived dashboard buckets (On Time/Delayed/Overdue/In
// Progress/Pending Approval — same mutually-exclusive rules as server's
// nc.controller.js#computeNcBuckets, mirrored in _matchesFilter below so a
// dashboard stat tile tap lands on a chip that filters to EXACTLY what it
// counted), then the raw statuses. Filtered client-side over the one
// already-fetched list, same reasoning as MyAuditsScreen's own status
// filter (one person's NC list is small enough that a server round-trip
// per filter tap would just be lag).
const _ncStatusFilters = [
  'All',
  'In Progress',
  'Pending Approval',
  'Overdue',
  'On Time',
  'Delayed',
  'Raised',
  'Response Submitted',
  'Verification',
  'Closed',
];

// Same bucket rules as server/controllers/nc.controller.js#computeNcBuckets
// — kept in sync by hand since there's no shared-across-platforms source
// of truth for this logic (mirrors today_ncs_section.dart's own
// _dueToday/_overdue/_ongoing helpers, just as exact-match filter
// predicates instead of a "what's due soon" summary).
bool _matchesFilter(NcModel n, String filter) {
  if (filter == 'All') return true;
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
  // Pre-applies one of _ncStatusFilters above — set by AppShell when a
  // dashboard stat tile is tapped (AuditorDashboard's NC Pending tile, or
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
      if (_showRaised) {
        final selfId = context.read<AuthProvider>().user?.id;
        if (selfId != null) provider.setSelfEmployeeId(selfId);
        provider.fetchRaisedByMe();
      }
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

// Shared by both lists below — a horizontal row of status chips above the
// list itself, same visual pattern as MyAuditsScreen's own filter row.
class _StatusFilterRow extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelect;

  const _StatusFilterRow({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        itemCount: _ncStatusFilters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final label = _ncStatusFilters[i];
          // See MyAuditsScreen's identical fix — a horizontal ListView
          // top-aligns each child instead of centering it in the row.
          return Center(
            child: ChoiceChip(
              label: Text(label),
              selected: selected == label,
              onSelected: (_) => onSelect(label),
            ),
          );
        },
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
          child: Align(
            alignment: Alignment.centerLeft,
            child: ScopeToggle(
              isTeam: provider.isTeamScope,
              onChanged: (isTeam) =>
                  context.read<NcProvider>().setTeamScope(isTeam),
            ),
          ),
        ),
        if (!showLoading && !showError && !showEmpty)
          _StatusFilterRow(
            selected: _statusFilter,
            onSelect: (v) => setState(() => _statusFilter = v),
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
    if (provider.isLoadingMine && provider.raisedAgainstMe.isEmpty) {
      return const AppLoading();
    }
    if (provider.mineError != null && provider.raisedAgainstMe.isEmpty) {
      return ErrorState(
        message: provider.mineError!,
        onRetry: widget.onRefresh,
      );
    }
    if (provider.raisedAgainstMe.isEmpty) {
      return const EmptyState(
        icon: Icons.thumb_up_outlined,
        title: 'No NCs against you — great work!',
      );
    }
    final filtered = provider.raisedAgainstMe
        .where((n) => _matchesFilter(n, _statusFilter))
        .toList();
    return Column(
      children: [
        _StatusFilterRow(
          selected: _statusFilter,
          onSelect: (v) => setState(() => _statusFilter = v),
        ),
        Expanded(
          child: RefreshIndicator(
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
