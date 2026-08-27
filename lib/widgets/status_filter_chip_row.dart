import 'package:flutter/material.dart';

/// A horizontally-scrolling row of single-select pill chips — the
/// "All / Not Started / In Progress / ..." status filter bar that used to
/// be copy-pasted (each copy's own comment pointing at "the same pattern"
/// in the others) across MyAuditsScreen, NcListScreen and ReportsScreen,
/// plus AuditDetailScreen's near-identical per-location picker.
///
/// A plain horizontal ListView top-aligns each child within the row's
/// fixed height instead of centering it — every prior copy patched that
/// with its own `Center` wrapper per item, which fixed the vertical
/// alignment but left each ChoiceChip using Material's default
/// MaterialTapTargetSize.padded (a hidden minimum-48px tap area around the
/// visible pill) and the stock Material 3 chip look, which between the
/// invisible padding and the plain grey chrome is what actually read as
/// "off-center" and "not great looking" on a phone. AppTheme's own
/// `chipTheme` (see core/theme/app_theme.dart) sets the brand shape/color
/// half of the fix; `shrinkWrap`/`compact` below (widget-level, not
/// ChipThemeData fields) remove the hidden tap-target padding so there's
/// nothing left to be off-center.
class StatusFilterChipRow extends StatelessWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;

  /// 44 (the default) is a touch-friendly top-level filter bar; 36 suits a
  /// denser secondary picker like AuditDetailScreen's per-location chips.
  final double height;

  const StatusFilterChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final label = options[i];
          return Center(
            child: ChoiceChip(
              label: Text(label),
              selected: selected == label,
              onSelected: (_) => onSelected(label),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          );
        },
      ),
    );
  }
}
