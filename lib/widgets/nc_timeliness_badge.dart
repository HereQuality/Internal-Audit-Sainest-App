import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/nc_timeliness.dart';
import 'status_badge.dart';

String? _labelFor(NcTimelinessVerdict v) {
  switch (v) {
    case NcTimelinessVerdict.onTime:
      return 'On Time';
    case NcTimelinessVerdict.delayed:
      return 'Delayed';
    case NcTimelinessVerdict.overdue:
      return 'Overdue';
    case NcTimelinessVerdict.inProgress:
      return 'In Progress';
    case NcTimelinessVerdict.unscored:
      return null; // no startDate/targetDate to judge against — nothing to show
  }
}

Color _colorFor(NcTimelinessVerdict v) {
  switch (v) {
    case NcTimelinessVerdict.onTime:
      return AppColors.green;
    case NcTimelinessVerdict.delayed:
      return AppColors.amber;
    case NcTimelinessVerdict.overdue:
      return AppColors.red;
    case NcTimelinessVerdict.inProgress:
    case NcTimelinessVerdict.unscored:
      return AppColors.slate;
  }
}

/// A StatusBadge-styled pill showing an NC's live On Time / Delayed /
/// Overdue / In Progress verdict — computed client-side via
/// core/utils/nc_timeliness.dart (mirrors server/utils/ncScoring.js
/// #computeAtsScore) rather than trusting the persisted nc.atsScore, which
/// (like the server's own computeActionTakenSpeed) is only ever written at
/// close time and so can't reflect an NC that's still open. Renders
/// nothing when there's no targetDate/startDate to judge against yet.
class NcTimelinessBadge extends StatelessWidget {
  final DateTime? startDate;
  final DateTime? targetDate;
  final DateTime? completionDate;
  // Overridable for tests — defaults to the real clock.
  final DateTime? now;

  const NcTimelinessBadge({
    super.key,
    required this.startDate,
    required this.targetDate,
    required this.completionDate,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final result = computeNcTimeliness(startDate: startDate, targetDate: targetDate, completionDate: completionDate, now: now);
    final label = _labelFor(result.verdict);
    if (label == null) return const SizedBox.shrink();
    return StatusBadge(label: label, color: _colorFor(result.verdict));
  }
}
