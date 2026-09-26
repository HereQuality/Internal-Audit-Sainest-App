import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const StatusBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        // readable(): the raw token is only 2.5-3.6:1 on the tinted pill in dark mode.
        style: TextStyle(color: AppColors.readable(context, color), fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The small secondary pill beside a finished audit's status badge —
/// "On-Time" / "Delayed", from the server's `timeliness` (or a batch's
/// `batchTimeliness`).
///
/// Separate from the badge because the two answer different questions: the
/// badge says where the audit is in its NC lifecycle (NC Response Pending,
/// Total Closed, ...), the pill says whether the auditor finished it before
/// its due date. Outlined rather than filled so it never competes with the
/// badge, and it draws nothing for null (an audit not finished yet, an older
/// server) or a label it does not know — never a wrong pill.
class TimelinessPill extends StatelessWidget {
  final String? timeliness;

  const TimelinessPill({super.key, required this.timeliness});

  /// "On-Time" / "Delayed" for the two labels the server sends, else null.
  static String? shortLabel(String? timeliness) => switch (timeliness) {
    'On-Time Completed' => 'On-Time',
    'Delayed Completed' => 'Delayed',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final label = shortLabel(timeliness);
    if (label == null) return const SizedBox.shrink();
    final color = AppColors.forAuditStatus(timeliness!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.readable(context, color),
        ),
      ),
    );
  }
}
