import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/audit_status.dart';
import '../core/utils/calendar_entries.dart';

/// How a layer looks: the SAME icon marks it on its switch, on its day-cell
/// markers, on its agenda cards and in the card's "whose is this" chip — so
/// "whose is this?" is never a guess (the web Calendar's LAYERS do the same
/// with clipboard-check / pin / warning triangle).
extension CalendarLayerStyle on CalendarLayer {
  IconData get icon => switch (this) {
        CalendarLayer.mine => Icons.assignment_turned_in_outlined,
        CalendarLayer.location => Icons.place_outlined,
        CalendarLayer.nc => Icons.warning_amber_rounded,
      };

  /// The layer's own colour (the web's #6366f1 / #2563eb / #ef4444), lightened
  /// on the dark theme so it stays readable as text and as a thin icon.
  Color color(BuildContext context) => AppColors.readable(
        context,
        switch (this) {
          CalendarLayer.mine => AppColors.primary,
          CalendarLayer.location => AppColors.blue,
          CalendarLayer.nc => AppColors.red,
        },
      );
}

/// The colour an audit of [status] is drawn in on the Calendar — the same
/// palette as every status badge, lightened for the dark theme.
Color calendarStatusColor(BuildContext context, String status) =>
    AppColors.readable(context, AppColors.forAuditStatus(status));

/// "Show: [My audits 4] [Audit at My Location 2] [My NCs 3]" — one switch per
/// layer, each with its icon and the number it holds in the month on screen.
/// Switching one off only hides it: every layer is still loaded.
///
/// Each switch is at least 44 px tall and wraps onto a second line (and its label
/// onto a second line of its own) rather than overflowing at 320 px or a large
/// text size.
class CalendarLayerChips extends StatelessWidget {
  final Set<CalendarLayer> on;
  final CalendarMonthCounts counts;
  final ValueChanged<CalendarLayer> onToggle;

  const CalendarLayerChips({super.key, required this.on, required this.counts, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final layer in CalendarLayer.values)
          _LayerChip(
            layer: layer,
            on: on.contains(layer),
            count: counts.of(layer),
            detail: layer == CalendarLayer.nc ? '${counts.ncRaised} raised, ${counts.ncDue} due' : null,
            onTap: () => onToggle(layer),
          ),
      ],
    );
  }
}

class _LayerChip extends StatelessWidget {
  final CalendarLayer layer;
  final bool on;
  final int count;
  final String? detail;
  final VoidCallback onTap;

  const _LayerChip({required this.layer, required this.on, required this.count, required this.onTap, this.detail});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = layer.color(context);
    final fg = on ? color : scheme.outline;
    return Semantics(
      button: true,
      toggled: on,
      label: '${layer.label}, $count${detail == null ? '' : ' ($detail)'}',
      hint: '${layer.hint}. Double tap to ${on ? 'hide' : 'show'}',
      excludeSemantics: true,
      child: Material(
        color: on ? color.withValues(alpha: 0.12) : scheme.surface,
        shape: StadiumBorder(side: BorderSide(color: on ? color : scheme.outlineVariant)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(layer.icon, size: 18, color: fg),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      layer.label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: fg,
                        decoration: on ? null : TextDecoration.lineThrough,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The colour key under the switches: the six statuses an audit can be drawn in,
/// in pipeline order. Delayed / On-Time Completed are a completed audit's
/// timeliness, never its status, so nothing is ever drawn in them. Not Attempted
/// and Skipped are listed only when the month holds one (as on the web).
///
/// View only — nothing here is tappable.
class CalendarStatusLegend extends StatelessWidget {
  final bool showNotAttempted;
  final bool showSkipped;

  const CalendarStatusLegend({super.key, this.showNotAttempted = false, this.showSkipped = false});

  static const statuses = [
    AuditStatus.notStarted,
    AuditStatus.inProgress,
    AuditStatus.overdue,
    AuditStatus.ncResponsePending,
    AuditStatus.ncVerificationPending,
    AuditStatus.totalClosed,
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final labels = [
      ...statuses,
      if (showNotAttempted) AuditStatus.notAttempted,
      if (showSkipped) AuditStatus.skipped,
    ];
    return Semantics(
      container: true,
      label: 'What the colour of an audit means',
      child: Wrap(
        spacing: 12,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Status colours',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
          ),
          for (final label in labels)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: calendarStatusColor(context, label)),
                ),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: scheme.outline),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
