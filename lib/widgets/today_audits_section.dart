import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../models/audit_model.dart';
import '../screens/audits/audit_detail_screen.dart';
import 'status_badge.dart';

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Which of `audits` are actually live today — scheduledDate/
/// scheduledEndDate treated as an inclusive [start, end] window (a
/// single-day audit has scheduledEndDate == null, which falls back to
/// its own scheduledDate as both ends), so a multi-day audit still shows
/// up on every day it spans, not just its first day.
List<AuditModel> _todaysAudits(List<AuditModel> audits) {
  final today = _dayOnly(DateTime.now());
  final result = audits.where((a) {
    if (a.scheduledDate == null) return false;
    final start = _dayOnly(a.scheduledDate!);
    final end = a.scheduledEndDate != null ? _dayOnly(a.scheduledEndDate!) : start;
    return !today.isBefore(start) && !today.isAfter(end);
  }).toList();
  // Actionable ones (Not Started / In Progress) first — Completed/Skipped
  // sink to the bottom since there's nothing left to do on them today.
  result.sort((a, b) {
    final aDone = a.status == 'Completed' || a.status == 'Skipped';
    final bDone = b.status == 'Completed' || b.status == 'Skipped';
    if (aDone != bDone) return aDone ? 1 : -1;
    return 0;
  });
  return result;
}

// Audits currently In Progress — regardless of when they're scheduled.
// Distinct from "today's" above: an audit spanning several days stays in
// this list every day it's actively being worked, not just the day it
// started.
List<AuditModel> _inProgressAudits(List<AuditModel> audits) =>
    audits.where((a) => a.status == 'In Progress').toList();

// Past its own scheduled window and still not wrapped up — mirrors the
// simple "not Completed/Skipped and the due date has passed" rule (no
// server-side plan-bucket endpoint backs this list yet, unlike the web
// app's derivePlanBucket, so it's derived client-side from the same
// scheduledDate/scheduledEndDate fields the Today section already reads).
List<AuditModel> _overdueAudits(List<AuditModel> audits) {
  final today = _dayOnly(DateTime.now());
  return audits.where((a) {
    if (a.status == 'Completed' || a.status == 'Skipped') return false;
    final due = a.scheduledEndDate ?? a.scheduledDate;
    if (due == null) return false;
    return _dayOnly(due).isBefore(today);
  }).toList();
}

/// Count of distinct audits appearing in any of the three buckets below —
/// used as the badge on the ExpandableSection wrapping all three on
/// DashboardScreen, so the collapsed header still shows "there's N things
/// here" without needing its own separate query.
int auditActivityCount(List<AuditModel> audits) {
  final ids = <String>{};
  ids.addAll(_todaysAudits(audits).map((a) => a.id));
  ids.addAll(_inProgressAudits(audits).map((a) => a.id));
  ids.addAll(_overdueAudits(audits).map((a) => a.id));
  return ids.length;
}

/// widgets/today_audits_section.dart
/// ──────────────────────────────────
/// The auditor Dashboard tab's own "what do I need to do" answer, as three
/// grouped mini-lists (Today → In Progress → Overdue) instead of just
/// count tiles — previously the only way to see the actual audits was
/// switching to the Audits tab and expanding a date group there
/// (my_audits_screen.dart). Each section renders nothing at all (not even
/// an empty state) when its own bucket is empty, so an otherwise-quiet day
/// never fills the dashboard with empty placeholders.
class TodayAuditsSection extends StatelessWidget {
  final List<AuditModel> audits;
  final VoidCallback? onSeeAll;

  const TodayAuditsSection({super.key, required this.audits, this.onSeeAll});

  @override
  Widget build(BuildContext context) => _AuditListSection(
        icon: Icons.today_rounded,
        title: "Today's Audits",
        audits: _todaysAudits(audits),
        onSeeAll: onSeeAll,
      );
}

class InProgressAuditsSection extends StatelessWidget {
  final List<AuditModel> audits;
  final VoidCallback? onSeeAll;

  const InProgressAuditsSection({super.key, required this.audits, this.onSeeAll});

  @override
  Widget build(BuildContext context) => _AuditListSection(
        icon: Icons.autorenew_rounded,
        title: 'In Progress Audits',
        audits: _inProgressAudits(audits),
        onSeeAll: onSeeAll,
      );
}

class OverdueAuditsSection extends StatelessWidget {
  final List<AuditModel> audits;
  final VoidCallback? onSeeAll;

  const OverdueAuditsSection({super.key, required this.audits, this.onSeeAll});

  @override
  Widget build(BuildContext context) => _AuditListSection(
        icon: Icons.report_problem_outlined,
        title: 'Overdue Audits',
        audits: _overdueAudits(audits),
        onSeeAll: onSeeAll,
      );
}

class _AuditListSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<AuditModel> audits;
  final VoidCallback? onSeeAll;

  const _AuditListSection({required this.icon, required this.title, required this.audits, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    if (audits.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: scheme.primary),
            const SizedBox(width: 6),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${audits.length}',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: scheme.onPrimaryContainer),
              ),
            ),
            const Spacer(),
            if (onSeeAll != null)
              TextButton(
                onPressed: onSeeAll,
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('See all', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        for (final audit in audits) ...[
          RepaintBoundary(child: _AuditListCard(audit: audit)),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _AuditListCard extends StatelessWidget {
  final AuditModel audit;

  const _AuditListCard({required this.audit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = AppColors.forAuditStatus(audit.status);
    return Card(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => AuditDetailScreen(auditId: audit.id)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 40,
                margin: const EdgeInsets.only(top: 2, right: 12),
                decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(2)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      audit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.place_outlined, size: 13, color: scheme.outline),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            audit.location.isNotEmpty ? audit.location : 'No location set',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(label: audit.status, color: statusColor),
            ],
          ),
        ),
      ),
    );
  }
}
