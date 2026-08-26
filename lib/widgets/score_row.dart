import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

/// ATS/OTC — the headline scorecard at the very top of a dashboard, above
/// the (now visually secondary) tally-tile grid. Same GET /ncs/ats-summary
/// data source (server/controllers/nc.controller.js#getAtsSummary) drives
/// both the Auditee dashboard (scored against the auditee themself) and
/// the Auditor dashboard (scored against the auditor's team, same default
/// scope resolveScopedEmployeeIds already applies with no employeeIds
/// param) — only the values passed in differ, not the shape.
///
/// Deliberately the most visually dominant thing on either dashboard —
/// mirrors the web app's PerformanceScoreHero — since these two numbers
/// feed straight into appraisal/increment review, not just another pair
/// of tally tiles to skim past.
class ScoreRow extends StatelessWidget {
  final double? atsScore;
  final double? otcScore;

  const ScoreRow({super.key, this.atsScore, this.otcScore});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: 0.12),
            scheme.surface,
          ],
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
                child: const Icon(Icons.auto_awesome_rounded, size: 16, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Performance Scorecard',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      'Counts toward your appraisal & increment',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _ScoreGaugeBlock(label: 'OTC Score', value: otcScore, color: AppColors.green)),
              const SizedBox(width: 10),
              Expanded(child: _ScoreGaugeBlock(label: 'ATS Score', value: atsScore, color: AppColors.blue)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScoreGaugeBlock extends StatelessWidget {
  final String label;
  final double? value;
  final Color color;

  const _ScoreGaugeBlock({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tierColor = _tierColorFor(value);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          SizedBox(
            width: 74,
            height: 74,
            child: CustomPaint(
              painter: _GaugePainter(
                value: value,
                color: tierColor,
                trackColor: scheme.outlineVariant.withValues(alpha: 0.35),
              ),
              child: Center(
                child: Text(
                  value != null ? value!.toStringAsFixed(0) : '—',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800, color: tierColor),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.3),
          ),
        ],
      ),
    );
  }
}

Color _tierColorFor(double? score) {
  if (score == null) return AppColors.slate;
  if (score >= 80) return AppColors.green;
  if (score >= 50) return AppColors.amber;
  return AppColors.red;
}

class _GaugePainter extends CustomPainter {
  final double? value;
  final Color color;
  final Color trackColor;

  const _GaugePainter({required this.value, required this.color, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 7.0;
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, track);

    final pct = ((value ?? 0).clamp(0, 100)) / 100.0;
    if (pct <= 0) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * pct, false, arc);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) =>
      oldDelegate.value != value || oldDelegate.color != color || oldDelegate.trackColor != trackColor;
}
