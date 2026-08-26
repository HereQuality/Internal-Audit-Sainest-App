import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../models/nc_model.dart';
import '../screens/nc/nc_response_screen.dart';
import '../screens/nc/nc_review_screen.dart';
import 'status_badge.dart';

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

// Three non-overlapping buckets over the auditee's own open NCs (Closed
// ones drop out of all three — nothing left to do on them) — same
// "due today / already overdue / still ahead of schedule" split the
// auditor's Today/In Progress/Overdue audit sections use, just keyed off
// each NC's own targetDate instead of an audit's scheduledDate.
List<NcModel> _dueToday(List<NcModel> ncs) {
  final today = _dayOnly(DateTime.now());
  return ncs.where((n) => n.status != 'Closed' && n.targetDate != null && _dayOnly(n.targetDate!) == today).toList();
}

List<NcModel> _overdue(List<NcModel> ncs) {
  final today = _dayOnly(DateTime.now());
  return ncs.where((n) => n.status != 'Closed' && n.targetDate != null && _dayOnly(n.targetDate!).isBefore(today)).toList();
}

List<NcModel> _ongoing(List<NcModel> ncs) {
  final today = _dayOnly(DateTime.now());
  return ncs.where((n) {
    if (n.status == 'Closed') return false;
    if (n.targetDate == null) return true;
    return _dayOnly(n.targetDate!).isAfter(today);
  }).toList();
}

/// Count of distinct NCs appearing in any of the three buckets below —
/// used as the badge on the ExpandableSection wrapping all three on
/// AuditeeDashboardScreen, mirroring auditActivityCount above.
int ncActivityCount(List<NcModel> ncs) {
  final ids = <String>{};
  ids.addAll(_dueToday(ncs).map((n) => n.id));
  ids.addAll(_ongoing(ncs).map((n) => n.id));
  ids.addAll(_overdue(ncs).map((n) => n.id));
  return ids.length;
}

/// widgets/today_ncs_section.dart
/// ─────────────────────────────────
/// The Auditee dashboard's own "what do I need to do" answer, mirroring
/// widgets/today_audits_section.dart's three-bucket layout (Today →
/// Ongoing → Overdue) for NCs raised against this employee instead of
/// audits assigned to them. Each section renders nothing at all when its
/// own bucket is empty.
class TodayNcsSection extends StatelessWidget {
  final List<NcModel> ncs;
  final VoidCallback? onSeeAll;

  const TodayNcsSection({super.key, required this.ncs, this.onSeeAll});

  @override
  Widget build(BuildContext context) => _NcListSection(
        icon: Icons.today_rounded,
        title: "Today's NC",
        ncs: _dueToday(ncs),
        onSeeAll: onSeeAll,
      );
}

class OngoingNcsSection extends StatelessWidget {
  final List<NcModel> ncs;
  final VoidCallback? onSeeAll;

  const OngoingNcsSection({super.key, required this.ncs, this.onSeeAll});

  @override
  Widget build(BuildContext context) => _NcListSection(
        icon: Icons.autorenew_rounded,
        title: 'Ongoing NCs',
        ncs: _ongoing(ncs),
        onSeeAll: onSeeAll,
      );
}

class OverdueNcsSection extends StatelessWidget {
  final List<NcModel> ncs;
  final VoidCallback? onSeeAll;

  const OverdueNcsSection({super.key, required this.ncs, this.onSeeAll});

  @override
  Widget build(BuildContext context) => _NcListSection(
        icon: Icons.report_problem_outlined,
        title: 'Overdue NCs',
        ncs: _overdue(ncs),
        onSeeAll: onSeeAll,
      );
}

class _NcListSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<NcModel> ncs;
  final VoidCallback? onSeeAll;

  const _NcListSection({required this.icon, required this.title, required this.ncs, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    if (ncs.isEmpty) return const SizedBox.shrink();

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
                '${ncs.length}',
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
        for (final nc in ncs) ...[
          RepaintBoundary(child: _NcListCard(nc: nc)),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _NcListCard extends StatelessWidget {
  final NcModel nc;

  const _NcListCard({required this.nc});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = AppColors.forNcStatus(nc.status);
    return Card(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Same tap rule as nc_list_screen.dart's "against me" list — still
        // Raised (or reopened after a rejection, which goes right back to
        // Raised) needs a response; anything past that is view/track only.
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => nc.status == 'Raised' ? NcResponseScreen(nc: nc) : NcReviewScreen(nc: nc),
          ),
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
                      nc.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.person_outline, size: 13, color: scheme.outline),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            'By ${nc.raisedBy.name}',
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
              StatusBadge(label: nc.status, color: statusColor),
            ],
          ),
        ),
      ),
    );
  }
}
