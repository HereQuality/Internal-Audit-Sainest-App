import 'package:flutter/material.dart';

class StatCard extends StatelessWidget {
  /// Row height for the 2-column grid of compact tiles (both dashboards). It
  /// used to be a flat 100, which is exactly what a compact tile needs at
  /// the default text size and nothing more — so at any larger Dynamic Type
  /// size (even iOS "Extra Extra Large") the tile's column overflowed and
  /// the label got clipped. 40 is the fixed part (icon row + padding), 60 the
  /// text part, which scales.
  ///
  /// [labelLines] > 1 is for a grid whose labels wrap (the audit-status
  /// tiles: "NC Verification Pending" does not fit one line in a half-width
  /// tile) — each extra line adds one bodySmall line (16 at scale 1), which
  /// scales with the text size like the rest of the text part.
  static double compactTileExtent(BuildContext context, {int labelLines = 1}) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final double s = scale < 1 ? 1 : scale;
    return 40 + 60 * s + 16 * (labelLines - 1) * s;
  }

  final String label;
  final int value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  // Shrinks padding/icon/number so this tile reads as supporting detail —
  // used for the secondary operational tallies grid on both dashboards,
  // now that ScoreRow (ATS/OTC) is the visually dominant headline element
  // above it instead of competing for attention at the same size.
  final bool compact;
  // How many lines the label may take: 1 for a compact tile (ellipsized), 2
  // otherwise — unless a grid that sized its rows for more says so via
  // compactTileExtent(labelLines:).
  final int? labelMaxLines;

  const StatCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.onTap,
    this.compact = false,
    this.labelMaxLines,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(compact ? 10 : 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: EdgeInsets.all(compact ? 6 : 8),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(compact ? 8 : 10),
                    ),
                    child: Icon(icon, color: color, size: compact ? 16 : 20),
                  ),
                  if (onTap != null)
                    Icon(
                      Icons.chevron_right,
                      size: compact ? 15 : 18,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                ],
              ),
              SizedBox(height: compact ? 6 : 10),
              Text(
                '$value',
                style:
                    (compact
                            ? Theme.of(context).textTheme.titleLarge
                            : Theme.of(context).textTheme.headlineSmall)
                        ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: labelMaxLines ?? (compact ? 1 : 2),
                overflow: compact ? TextOverflow.ellipsis : TextOverflow.clip,
                style: (compact
                        ? Theme.of(context).textTheme.bodySmall
                        : Theme.of(context).textTheme.bodyMedium)
                    ?.copyWith(color: Theme.of(context).colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
