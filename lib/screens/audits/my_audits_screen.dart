import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/audit_model.dart';
import '../../providers/audits_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/scope_toggle.dart';
import '../../widgets/status_badge.dart';
import 'audit_detail_screen.dart';

// "All" plus every status getMyAudits can actually return (Skipped is
// already excluded server-side — see audit.controller.js#notSkipped) —
// filtered client-side over the one fetched list rather than a re-fetch
// per tap, since a single auditor's own audit list is small enough that
// round-tripping the server for every filter change would just be
// perceptible lag for no benefit.
const _statusFilters = [
  'All',
  'Not Started',
  'In Progress',
  'Completed',
  'Draft',
];

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

// One calendar day's worth of audits — scheduledDate stripped to just
// its date, so multiple audits on the same day land in the same group
// regardless of their time-of-day component.
DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

String _dayLabel(DateTime day) {
  final today = _dayOnly(DateTime.now());
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  return Formatters.date(day);
}

class _MyAuditsScreenState extends State<MyAuditsScreen> {
  late String _statusFilter = widget.initialStatusFilter ?? 'All';
  // Which date group is expanded — only ever one at a time, so tapping a
  // date reveals just that date's audits below it instead of the whole
  // list turning into an unreadable wall of cards. Starts null and gets
  // defaulted to the latest date once audits are in (see build below),
  // so the newest date is open automatically without extra taps.
  DateTime? _expandedDay;
  bool _expandedDaySet = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selfId = context.read<AuthProvider>().user?.id;
      if (selfId != null)
        context.read<AuditsProvider>().setSelfEmployeeId(selfId);
      context.read<AuditsProvider>().fetchMyAudits();
    });
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
    final filtered = _statusFilter == 'All'
        ? provider.audits
        : provider.audits.where((a) => a.status == _statusFilter).toList();

    // Latest scheduled date first — undated audits (scheduledDate null,
    // e.g. a still-unassigned Draft) sink to their own group at the end.
    final sorted = [...filtered]
      ..sort((a, b) {
        if (a.scheduledDate == null && b.scheduledDate == null) return 0;
        if (a.scheduledDate == null) return 1;
        if (b.scheduledDate == null) return -1;
        return b.scheduledDate!.compareTo(a.scheduledDate!);
      });
    final Map<DateTime?, List<AuditModel>> grouped = {};
    for (final a in sorted) {
      final key = a.scheduledDate == null ? null : _dayOnly(a.scheduledDate!);
      grouped.putIfAbsent(key, () => []).add(a);
    }
    final dayKeys = grouped.keys.toList();

    // Default the open group to the newest date exactly once per audit
    // list — after that, whatever the user tapped stays in charge
    // (including collapsing everything by setting it back to null).
    if (!_expandedDaySet && dayKeys.isNotEmpty) {
      _expandedDaySet = true;
      _expandedDay = dayKeys.first;
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: ScopeToggle(
              isTeam: provider.isTeamScope,
              onChanged: (isTeam) =>
                  context.read<AuditsProvider>().setTeamScope(isTeam),
            ),
          ),
        ),
        if (!showLoading && !showError && !showEmptyState)
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              itemCount: _statusFilters.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final label = _statusFilters[i];
                final selected = _statusFilter == label;
                // A horizontal ListView top-aligns each child within the
                // row's fixed height rather than centering it — the chip
                // (shorter than the 44px row) sat flush against the top,
                // leaving its label looking vertically off-center.
                return Center(
                  child: ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) => setState(() => _statusFilter = label),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => context.read<AuditsProvider>().fetchMyAudits(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: showLoading || showEmptyState || showError
                  ? EdgeInsets.zero
                  : const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                if (showLoading)
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: const AppLoading(),
                  )
                else if (showError)
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: ErrorState(
                      message: provider.errorMessage!,
                      onRetry: () =>
                          context.read<AuditsProvider>().fetchMyAudits(),
                    ),
                  )
                else if (showEmptyState)
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: const EmptyState(
                      icon: Icons.assignment_outlined,
                      title: 'No audits assigned',
                      subtitle: 'Audits assigned to you will appear here.',
                    ),
                  )
                else if (filtered.isEmpty)
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.5,
                    child: EmptyState(
                      icon: Icons.filter_alt_off_outlined,
                      title: 'No $_statusFilter audits',
                    ),
                  )
                else
                  for (final day in dayKeys) ...[
                    _DateSectionHeader(
                      label: day == null ? 'No date set' : _dayLabel(day),
                      count: grouped[day]!.length,
                      expanded: _expandedDay == day,
                      onTap: () => setState(
                        () => _expandedDay = _expandedDay == day ? null : day,
                      ),
                    ),
                    if (_expandedDay == day) ...[
                      const SizedBox(height: 8),
                      for (final audit in grouped[day]!) ...[
                        RepaintBoundary(child: _AuditCard(audit: audit)),
                        const SizedBox(height: 12),
                      ],
                    ],
                    const SizedBox(height: 4),
                  ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// A tappable date header — collapsed by default (except the newest date,
// opened automatically), expanding to reveal just that date's audits
// instead of every date's cards stacked in one long, hard-to-scan list.
class _DateSectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  const _DateSectionHeader({
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: expanded
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.event_outlined, size: 16, color: scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditCard extends StatelessWidget {
  final AuditModel audit;

  const _AuditCard({required this.audit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AuditDetailScreen(auditId: audit.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      audit.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusBadge(
                    label: audit.status,
                    color: AppColors.forAuditStatus(audit.status),
                  ),
                ],
              ),
              if (audit.scope.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  audit.scope,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.place_outlined, size: 15, color: scheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      audit.location.isNotEmpty
                          ? audit.location
                          : 'No location set',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: audit.location.isNotEmpty
                            ? null
                            : scheme.outline,
                        fontWeight: audit.location.isNotEmpty
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.event_outlined, size: 14, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    Formatters.date(audit.scheduledDate),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
