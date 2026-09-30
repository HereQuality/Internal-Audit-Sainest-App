import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../models/audit_model.dart';

/// The auditor dashboard's headline scorecard (same figures as the web app's
/// Components/Common/AuditorScorecard.jsx, read off the same GET
/// /audits/auditor-stats response). It replaces the ATS/OTC ScoreRow there —
/// ATS/OTC now belong to the auditee's NCs only.
///
/// Blocks stacked so it reads on a phone: Total Planned / Active, On-Time /
/// Delayed Completed (with their share of the finished audits), the two
/// plan-vs-actual bars, then the Cumulative Score.
class AuditorScorecard extends StatelessWidget {
  final AuditorStats stats;

  const AuditorScorecard({super.key, required this.stats});

  static double? _ratio(int part, int whole) =>
      whole > 0 ? (part / whole * 1000).round() / 10 : null;

  static String _pct(double? v) => v == null
      ? '—'
      : '${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(1)}%';

  // [good]: where green starts — 75 for an audit score (as on every other
  // screen and the web), 80 for the other percentages here.
  static Color _tier(double? v, {double good = 80}) => v == null
      ? Colors.grey
      : v >= good
      ? AppColors.green
      : v >= 50
      ? AppColors.amber
      : AppColors.red;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final planned = stats.totalAudits;
    final onTime = stats.onTimeCompleted;
    final delayed = stats.delayed;
    final completed = onTime + delayed;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
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
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.auto_awesome_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auditor Scorecard',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Plan vs actual and scoring across your audits',
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Box(
            title: 'Audits',
            children: [
              _Line(
                label: 'Total Planned Audits',
                value: '$planned',
                color: AppColors.primary,
                strong: true,
              ),
              _Line(
                label: 'On-Time Completed',
                value: '$onTime',
                color: AppColors.green,
              ),
              _Line(
                label: 'Delayed Completed',
                value: '$delayed',
                color: AppColors.red,
              ),
              _Line(label: 'Total Completed', value: '$completed'),
              _Line(
                label: 'On-Time %',
                value: _pct(_ratio(onTime, completed)),
                color: _tier(_ratio(onTime, completed)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Box(
            title: 'Plan vs Actual',
            children: [
              _Line(
                label: 'On-Time Plan vs Actual',
                value: '$onTime / $planned',
                color: AppColors.green,
                strong: true,
                bar: planned > 0 ? onTime / planned : 0,
                note: '${_pct(_ratio(onTime, planned))} of plan done on time',
              ),
              _Line(
                label: 'Overall Plan vs Actual',
                value: '$completed / $planned',
                color: AppColors.primary,
                strong: true,
                bar: planned > 0 ? completed / planned : 0,
                note: '${_pct(_ratio(completed, planned))} of plan completed',
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Box(
            title: 'Audit Score',
            children: [
              _Line(
                label: 'Cumulative Score',
                value: _pct(stats.overallScore),
                color: _tier(stats.overallScore, good: 75),
                strong: true,
                note: 'All audits you performed, combined',
              ),
              _Line(
                label: 'Active Audits',
                value: '${stats.activeAudits}',
                color: AppColors.blue,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Box extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Box({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.outline,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
          for (final c in children) ...[const SizedBox(height: 8), c],
        ],
      ),
    );
  }
}

/// One line inside a box: the label wraps on the left, the value sits on the right.
class _Line extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final bool strong;
  final double? bar;
  final String? note;

  const _Line({
    required this.label,
    required this.value,
    this.color,
    this.strong = false,
    this.bar,
    this.note,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              value,
              style: (strong ? theme.titleLarge : theme.titleSmall)?.copyWith(
                fontWeight: FontWeight.w800,
                color: color == null
                    ? null
                    : AppColors.readable(context, color!),
              ),
            ),
          ],
        ),
        if (bar != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: bar!.clamp(0.0, 1.0),
              minHeight: 6,
              color: color,
              backgroundColor: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
        ],
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note!,
              style: theme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ),
      ],
    );
  }
}
