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
///
/// The row can be longer than the screen (the audit lists now carry all
/// eight lifecycle statuses), so the SELECTED chip is scrolled into view
/// whenever it is picked from outside the row — a dashboard tile jumping
/// straight to "NC Verification Pending" must not land on a list whose
/// highlighted chip is off the right edge. That is why the chips are laid
/// out in a plain scrolling Row (one GlobalKey each, all built up front — a
/// filter row is a handful of chips) instead of a lazy ListView, whose
/// off-screen chips have no context to scroll to.
class StatusFilterChipRow extends StatefulWidget {
  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;

  /// 44 (the default) is a touch-friendly top-level filter bar; 36 suits a
  /// denser secondary picker like AuditDetailScreen's per-location chips.
  final double height;

  /// Optional colour per option — draws a small dot on the chip so a status
  /// chip carries the same colour as its badge everywhere else. Null (or a
  /// null return) leaves that chip plain. The dot gives way to the check
  /// mark while its chip is selected.
  final Color? Function(String option)? dotColorFor;

  /// Optional display text per option (the NC lists show "Total NC" for the
  /// underlying 'All'); defaults to the option itself.
  final String Function(String option)? labelFor;

  const StatusFilterChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.height = 44,
    this.dotColorFor,
    this.labelFor,
  });

  @override
  State<StatusFilterChipRow> createState() => _StatusFilterChipRowState();
}

class _StatusFilterChipRowState extends State<StatusFilterChipRow> {
  // One key per POSITION (not per label), so a caller that ever repeats a
  // label cannot end up with two widgets sharing a GlobalKey.
  final List<GlobalKey> _keys = [];

  GlobalKey _keyAt(int i) {
    while (_keys.length <= i) {
      _keys.add(GlobalKey(debugLabel: 'chip-${_keys.length}'));
    }
    return _keys[i];
  }

  @override
  void initState() {
    super.initState();
    _revealSelected();
  }

  @override
  void didUpdateWidget(StatusFilterChipRow old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _revealSelected();
  }

  // Post-frame: the chip has to be laid out before it can be scrolled to.
  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final i = widget.options.indexOf(widget.selected);
      final ctx = i < 0 || i >= _keys.length ? null : _keys[i].currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            for (int i = 0; i < widget.options.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _chip(i),
            ],
          ],
        ),
      ),
    );
  }

  Widget _chip(int index) {
    final label = widget.options[index];
    final dot = widget.dotColorFor?.call(label);
    return Center(
      key: _keyAt(index),
      child: ChoiceChip(
        label: Text(widget.labelFor?.call(label) ?? label),
        avatar: dot == null
            ? null
            : Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
        selected: widget.selected == label,
        onSelected: (_) => widget.onSelected(label),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
