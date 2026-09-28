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
//
// Follows the server's displayStatus, whose 'In Progress' EXCLUDES overdue
// audits (they are 'Overdue' there). The raw `status` used to be the test,
// and it says 'In Progress' for an overdue open audit too — so the same card
// appeared here and again under Overdue. Older server / cached data (no
// displayStatus): the raw status, as before.
List<AuditModel> _inProgressAudits(List<AuditModel> audits) => audits
    .where((a) => a.displayStatus != null
        ? a.displayStatus == 'In Progress'
        : a.status == 'In Progress')
    .toList();

// Past its own due date and still not wrapped up — the server's 'Overdue'
// displayStatus (auditLifecycleStatus.js: not completed, now past the end of
// the due day), so this list, the dashboard's Overdue tile and the Overdue
// chip all agree. Only when displayStatus is absent (older server / cached
// data) is it derived client-side, by the simple "not Completed/Skipped and
// the due date has passed" rule from the same scheduledDate/scheduledEndDate
// fields the Today section already reads.
List<AuditModel> _overdueAudits(List<AuditModel> audits) {
  final today = _dayOnly(DateTime.now());
  return audits.where((a) {
    final display = a.displayStatus;
    if (display != null) return display == 'Overdue';
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

  /// Accordion hooks (see [AuditAttentionPanel]): when [onToggle] is set the
  /// header is tappable, shows a chevron and hides the cards while
  /// [expanded] is false. Left null (the standalone use), the section is
  /// always open exactly as before.
  final bool expanded;
  final VoidCallback? onToggle;

  const _AuditListSection({
    required this.icon,
    required this.title,
    required this.audits,
    this.onSeeAll,
    this.expanded = true,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (audits.isEmpty) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final header = Row(
      children: [
        Icon(icon, size: 18, color: scheme.primary),
        const SizedBox(width: 6),
        // Expanded + a Flexible title (and no Spacer): at the larger Dynamic Type
        // sizes title + count + "See all" no longer fit one line and this Row
        // overflowed (yellow/black stripes, cut-off text).
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
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
              if (onToggle != null) ...[
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: scheme.outline),
                ),
              ],
            ],
          ),
        ),
        if (onSeeAll != null)
          TextButton(
            onPressed: onSeeAll,
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 44), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            child: const Text('See all', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (onToggle == null)
          header
        else
          Semantics(
            button: true,
            expanded: expanded,
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 44), child: header),
            ),
          ),
        if (expanded) ...[
          const SizedBox(height: 10),
          for (final audit in audits) ...[
            RepaintBoundary(child: _AuditListCard(audit: audit)),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

/// The dashboard's "What needs attention" body: Today's / In Progress /
/// Overdue audits as an ACCORDION — opening one folds the other two, so only
/// one list is ever expanded (tapping "Today's Audits" collapses In Progress
/// and Overdue; tapping the open one closes it). Today's is open first, or the
/// first non-empty list when nothing is scheduled today. The open list is held
/// in this State, which lives as long as the (kept-alive) Dashboard tab, so
/// coming Back from an audit finds the same list open.
class AuditAttentionPanel extends StatefulWidget {
  final List<AuditModel> audits;
  final VoidCallback? onSeeAll;

  const AuditAttentionPanel({super.key, required this.audits, this.onSeeAll});

  @override
  State<AuditAttentionPanel> createState() => _AuditAttentionPanelState();
}

class _AuditAttentionPanelState extends State<AuditAttentionPanel> {
  // Null = "not chosen yet" (falls back to the first non-empty list); the
  // empty string = the user closed everything.
  String? _open;

  void _toggle(String key) => setState(() => _open = _open == key ? '' : key);

  @override
  Widget build(BuildContext context) {
    final today = _todaysAudits(widget.audits);
    final inProgress = _inProgressAudits(widget.audits);
    final overdue = _overdueAudits(widget.audits);
    final open = _open ??
        (today.isNotEmpty ? 'today' : inProgress.isNotEmpty ? 'progress' : 'overdue');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AuditListSection(
          icon: Icons.today_rounded,
          title: "Today's Audits",
          audits: today,
          onSeeAll: widget.onSeeAll,
          expanded: open == 'today',
          onToggle: () => _toggle('today'),
        ),
        if (today.isNotEmpty) const SizedBox(height: 14),
        _AuditListSection(
          icon: Icons.autorenew_rounded,
          title: 'In Progress Audits',
          audits: inProgress,
          onSeeAll: widget.onSeeAll,
          expanded: open == 'progress',
          onToggle: () => _toggle('progress'),
        ),
        if (inProgress.isNotEmpty) const SizedBox(height: 14),
        _AuditListSection(
          icon: Icons.report_problem_outlined,
          title: 'Overdue Audits',
          audits: overdue,
          onSeeAll: widget.onSeeAll,
          expanded: open == 'overdue',
          onToggle: () => _toggle('overdue'),
        ),
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
    final statusColor = AppColors.forAuditStatus(audit.displayLabel);
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
                // readable(): the raw token is dark by design (badge text
                // on a light tint) and would sink into the dark theme's card.
                decoration: BoxDecoration(color: AppColors.readable(context, statusColor), borderRadius: BorderRadius.circular(2)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      audit.title,
                      // 2 lines: on one line "Cold Store Temperature Audit" was cut to
                      // "Cold Store Temperature A…" on a 390pt phone.
                      maxLines: 2,
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
              StatusBadge(label: audit.displayLabel, color: statusColor),
            ],
          ),
        ),
      ),
    );
  }
}
