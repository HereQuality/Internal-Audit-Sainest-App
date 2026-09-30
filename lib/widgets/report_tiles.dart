import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../models/nc_report_model.dart';
import 'status_badge.dart';

/// One stat tile of the Final Report / NC Monitoring: a number, its label and —
/// when [onTap] is set — a tap that narrows the list below to exactly what the
/// number counted ([selected] draws that state).
class ReportTileData {
  /// What a tap reports back (a bucket key, a tile key) — also the widget key
  /// suffix, so a test can find one tile.
  final String id;
  final String label;
  final String value;
  final String? sub;
  final IconData icon;
  final Color color;
  final bool selected;

  /// A tile that is not part of the total it sits under (Not Attempted): drawn
  /// in the muted outline colour instead of its own.
  final bool muted;
  final VoidCallback? onTap;

  const ReportTileData({
    required this.id,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.sub,
    this.selected = false,
    this.muted = false,
    this.onTap,
  });
}

/// The six NC tiles — Total NC, In Progress, Overdue, Pending Approval,
/// Delayed, On Time Completion — from the server's [NcTileStats], in the order
/// (and on the colours) of the Auditee dashboard's own grid. Tapping a bucket
/// tile toggles it in [selected] (several can be on at once, they OR together);
/// Total NC is not a bucket: its tap clears the picks ([onClear]).
List<ReportTileData> ncBucketTiles(
  NcTileStats stats, {
  required Set<String> selected,
  required ValueChanged<String> onToggle,
  required VoidCallback onClear,
}) {
  ({IconData icon, Color color}) look(String bucket) => switch (bucket) {
    NcBucket.inProgress => (icon: Icons.hourglass_bottom_rounded, color: AppColors.blue),
    NcBucket.overdue => (icon: Icons.report_gmailerrorred_outlined, color: AppColors.red),
    NcBucket.pendingApproval => (icon: Icons.pending_actions_outlined, color: AppColors.slate),
    NcBucket.delayed => (icon: Icons.warning_amber_outlined, color: AppColors.amber),
    _ => (icon: Icons.check_circle_outline, color: AppColors.green),
  };
  return [
    ReportTileData(
      id: 'total',
      label: 'Total NC',
      value: '${stats.total}',
      icon: Icons.assignment_outlined,
      color: AppColors.primary,
      onTap: onClear,
    ),
    for (final bucket in NcBucket.all)
      ReportTileData(
        id: bucket,
        label: NcBucket.label(bucket),
        value: '${stats.countFor(bucket)}',
        icon: look(bucket).icon,
        color: look(bucket).color,
        selected: selected.contains(bucket),
        onTap: () => onToggle(bucket),
      ),
  ];
}

/// The NC bucket's colour — one palette for a tile and for the pill on a row.
Color ncBucketColor(String? bucket) => switch (bucket) {
  NcBucket.inProgress => AppColors.blue,
  NcBucket.overdue => AppColors.red,
  NcBucket.pendingApproval => AppColors.slate,
  NcBucket.delayed => AppColors.amber,
  NcBucket.onTime => AppColors.green,
  _ => AppColors.slate,
};

/// A compact grid of [ReportTileData]: three to a row on a phone (every label
/// may take two lines, so nothing clips at a large text size), six on a wide
/// tablet. Rows are as tall as their tallest tile.
class ReportTileGrid extends StatelessWidget {
  final List<ReportTileData> tiles;

  const ReportTileGrid({super.key, required this.tiles});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth >= 640 ? 6 : 3;
        final rows = <List<ReportTileData>>[];
        for (var i = 0; i < tiles.length; i += columns) {
          rows.add(tiles.sublist(i, i + columns < tiles.length ? i + columns : tiles.length));
        }
        return Column(
          children: [
            for (final (r, row) in rows.indexed) ...[
              if (r > 0) const SizedBox(height: 8),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var c = 0; c < columns; c++) ...[
                      if (c > 0) const SizedBox(width: 8),
                      // A short last row keeps the same tile width instead of
                      // stretching its few tiles across the whole line.
                      Expanded(
                        child: c < row.length
                            ? _ReportTile(data: row[c])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ReportTile extends StatelessWidget {
  final ReportTileData data;

  const _ReportTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // readable(): the palette colours are tuned for a light card and sink into
    // the dark theme's surface.
    final color = data.muted ? scheme.outline : AppColors.readable(context, data.color);
    final radius = BorderRadius.circular(14);
    return Semantics(
      button: data.onTap != null,
      selected: data.selected,
      child: Material(
        color: data.selected ? color.withValues(alpha: 0.10) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: data.selected ? color : scheme.outlineVariant.withValues(alpha: 0.5),
            width: data.selected ? 1.6 : 1,
          ),
        ),
        child: InkWell(
          key: ValueKey('report-tile-${data.id}'),
          borderRadius: radius,
          onTap: data.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(data.icon, size: 15, color: color),
                    const SizedBox(width: 5),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          data.value,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  data.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                    fontWeight: FontWeight.w600,
                    fontSize: 11.5,
                  ),
                ),
                if (data.sub != null)
                  Text(
                    data.sub!,
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
        ),
      ),
    );
  }
}

/// An NC's Flag as the small pill every NC surface shows — Major red, Minor amber.
class NcFlagBadge extends StatelessWidget {
  final String flag;

  const NcFlagBadge({super.key, required this.flag});

  @override
  Widget build(BuildContext context) => StatusBadge(
    label: flag,
    color: flag == 'Major' ? AppColors.red : AppColors.amber,
  );
}

/// The pill naming the bucket the SERVER counted an NC under (In Progress,
/// Overdue, Pending Approval, Delayed, On Time) — the word on the row and the
/// tile that row was counted in are always the same.
class NcBucketBadge extends StatelessWidget {
  final String bucket;

  const NcBucketBadge({super.key, required this.bucket});

  @override
  Widget build(BuildContext context) =>
      StatusBadge(label: NcBucket.pill(bucket), color: ncBucketColor(bucket));
}
