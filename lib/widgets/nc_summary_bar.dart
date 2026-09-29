import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../models/auditee_stats_model.dart';

/// widgets/nc_summary_bar.dart
/// ────────────────────────────
/// A short recap above the Auditee dashboard's 6 NC tiles (Total, In Progress,
/// Overdue, Pending Approval, Delayed, On Time) — mirrors the web's
/// Components/Common/NcSummaryBar.jsx. Reduces the same numbers to two sides:
///   Pending   = In Progress + Overdue + Pending Approval (not yet accepted —
///               server's computeNcBuckets: a response the auditor hasn't
///               accepted yet, or rejects, is NOT done)
///   Completed = On Time + Delayed (the auditor actually accepted it)
/// with the completion rate as its own thin strip underneath, not squeezed
/// onto the same row as the two sides — three things fighting for one phone-
/// width row is what overflowed before (the rate strip's text is a few px
/// wider on iOS than Android for the same numbers, which was enough to tip
/// it over). Two deterministic rows instead: never depends on how wide any
/// one piece of text happens to render.
class NcSummaryBar extends StatelessWidget {
  final AuditeeStats stats;

  const NcSummaryBar({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pending = stats.inProgress + stats.overdue + stats.pendingApproval;
    final completed = stats.onTime + stats.delayed;
    final rate = stats.total > 0
        ? (completed / stats.total * 100).round()
        : null;
    final rateColor = rate == null
        ? scheme.outline
        : rate >= 80
        ? AppColors.green
        : rate >= 50
        ? AppColors.amber
        : AppColors.red;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primary.withValues(alpha: 0.12), scheme.surface],
        ),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _Side(
                  icon: Icons.hourglass_bottom_rounded,
                  label: 'Pending',
                  value: pending,
                  color: AppColors.readable(context, const Color(0xFFDB2777)),
                  breakdown:
                      '${stats.inProgress} in progress · ${stats.overdue} overdue',
                ),
              ),
              const SizedBox(width: 8),
              Container(width: 1, height: 34, color: scheme.outlineVariant.withValues(alpha: 0.4)),
              const SizedBox(width: 8),
              Expanded(
                child: _Side(
                  icon: Icons.check_circle_outline,
                  label: 'Completed',
                  value: completed,
                  color: AppColors.readable(context, AppColors.green),
                  breakdown: '${stats.onTime} on time · ${stats.delayed} delayed',
                ),
              ),
            ],
          ),
          if (rate != null) ...[
            const SizedBox(height: 10),
            Container(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '$rate%',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: rateColor,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'of ${stats.total} closed',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Side extends StatelessWidget {
  final IconData icon;
  final String label;
  final int value;
  final Color color;
  final String breakdown;

  const _Side({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    required this.breakdown,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$value',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      label.toUpperCase(),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                breakdown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                  fontSize: 10.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
