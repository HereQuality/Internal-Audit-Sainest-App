import 'dart:math' as math;

import 'package:flutter/material.dart';

/// widgets/picker_sheet.dart
/// ──────────────────────────
/// The one reliable "pick from a list" bottom sheet for the whole app — the
/// replacement for cramped inline dropdowns (DropdownButtonFormField menus
/// clip on long names, can't be searched, hide behind the keyboard and read
/// badly at large text sizes). Single-select ([showSinglePickerSheet]) and
/// multi-select ([showMultiPickerSheet]) share one body:
///
///  * a pinned header + footer with the list scrolling between them, capped
///    to what is left after the status bar and the keyboard, so the Confirm
///    button can never end up below the fold or under the keyboard;
///  * a search box whenever the list is long enough to need one (matches the
///    label and the muted second line), with a clear button and a "No
///    matches" state that keeps the selection intact;
///  * a clearly marked selected row (check / filled checkbox + tinted
///    background), min 48dp tall rows, labels that wrap instead of
///    truncating so large text stays readable;
///  * theme colours only, so dark mode follows the app theme.
///
/// Also see [PickerFormField], the form-field look that opens the single
/// picker.
class PickerItem<T> {
  final T value;
  final String label;

  /// Muted second line (e.g. a person's team, a Sub Zone's parent Zone).
  final String? sublabel;

  const PickerItem({required this.value, required this.label, this.sublabel});
}

/// Below this many rows a search box is just noise.
const int kPickerSearchThreshold = 7;

/// Single choice: tapping a row returns it and closes the sheet. Returns
/// null when dismissed (back, tap outside, drag down), so a dismissal never
/// clears the current value. When [clearLabel] is set an extra top row with
/// that label returns [clearValue] (for "None"/"Any").
Future<T?> showSinglePickerSheet<T>(
  BuildContext context, {
  required String title,
  required List<PickerItem<T>> items,
  T? selected,
  String? subtitle,
  String searchHint = 'Search',
  String? clearLabel,
  T? clearValue,
}) async {
  final choice = await showSinglePickerChoice<T>(
    context,
    title: title,
    items: items,
    selected: selected,
    subtitle: subtitle,
    searchHint: searchHint,
    clearLabel: clearLabel,
  );
  if (choice == null) return null;
  return choice.cleared ? clearValue : choice.value;
}

/// Like [showSinglePickerSheet] but tells "dismissed" (null) apart from
/// "picked the clear row" (`cleared: true`) — for callers where clearing is
/// a real change, such as [PickerFormField].
Future<PickerChoice<T>?> showSinglePickerChoice<T>(
  BuildContext context, {
  required String title,
  required List<PickerItem<T>> items,
  T? selected,
  String? subtitle,
  String searchHint = 'Search',
  String? clearLabel,
}) {
  return showModalBottomSheet<PickerChoice<T>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    // Capped on a tablet-width screen — see filter_sheet.dart's identical
    // constraints for why no extra centering is needed on top of it.
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _PickerBody<T>(
      title: title,
      subtitle: subtitle,
      items: items,
      multi: false,
      initiallySelected: selected == null ? const [] : [selected],
      searchHint: searchHint,
      clearLabel: clearLabel,
    ),
  );
}

/// Multi choice with a Confirm button. Returns the picked values in the
/// order of [items] (so a result is stable), or null when dismissed.
/// [minSelected] = 1 keeps Confirm disabled ("Select at least one") until
/// something is ticked — used for a required pick such as the representative.
Future<List<T>?> showMultiPickerSheet<T>(
  BuildContext context, {
  required String title,
  required List<PickerItem<T>> items,
  List<T> selected = const [],
  String? subtitle,
  String searchHint = 'Search',
  int minSelected = 0,
  String confirmLabel = 'Confirm',
}) {
  return showModalBottomSheet<List<T>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    // Capped on a tablet-width screen — see filter_sheet.dart's identical
    // constraints for why no extra centering is needed on top of it.
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _PickerBody<T>(
      title: title,
      subtitle: subtitle,
      items: items,
      multi: true,
      initiallySelected: selected,
      searchHint: searchHint,
      minSelected: minSelected,
      confirmLabel: confirmLabel,
    ),
  );
}

/// What a single-choice sheet returns: the picked [value], or [cleared]
/// when the "clear" row was tapped.
class PickerChoice<T> {
  final T? value;
  final bool cleared;

  const PickerChoice(this.value, {this.cleared = false});
}

class _PickerBody<T> extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<PickerItem<T>> items;
  final bool multi;
  final List<T> initiallySelected;
  final String searchHint;
  final int minSelected;
  final String confirmLabel;
  final String? clearLabel;

  const _PickerBody({
    required this.title,
    required this.items,
    required this.multi,
    required this.initiallySelected,
    required this.searchHint,
    this.subtitle,
    this.minSelected = 0,
    this.confirmLabel = 'Confirm',
    this.clearLabel,
  });

  @override
  State<_PickerBody<T>> createState() => _PickerBodyState<T>();
}

class _PickerBodyState<T> extends State<_PickerBody<T>> {
  late final Set<T> _selected = {...widget.initiallySelected};
  final TextEditingController _search = TextEditingController();
  String _query = '';

  bool get _searchable => widget.items.length >= kPickerSearchThreshold;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<PickerItem<T>> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items
        .where(
          (i) =>
              i.label.toLowerCase().contains(q) ||
              (i.sublabel ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  void _toggle(T value) {
    if (!widget.multi) {
      Navigator.of(context).pop(PickerChoice<T>(value));
      return;
    }
    setState(() {
      if (!_selected.remove(value)) _selected.add(value);
    });
  }

  void _confirm() {
    // Items order, not tap order — a stable result for the caller.
    final picked = [
      for (final i in widget.items)
        if (_selected.contains(i.value)) i.value,
    ];
    Navigator.of(context).pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final visible = _visible;
    // Bounded by what is actually left once the keyboard has taken its share
    // (useSafeArea already removed the status bar), so the search field never
    // pushes the sheet off-screen and the footer stays reachable.
    final maxHeight = math.min(
      media.size.height * 0.88,
      media.size.height - media.viewInsets.bottom - media.padding.top - 8,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Material(
        color: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: math.max(maxHeight, 200)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (widget.multi && _selected.isNotEmpty)
                      TextButton(
                        onPressed: () => setState(_selected.clear),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ),
              if (_searchable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: widget.searchHint,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              Flexible(
                child: visible.isEmpty && widget.clearLabel == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 32,
                          horizontal: 20,
                        ),
                        child: Text(
                          widget.items.isEmpty
                              ? 'Nothing to pick from.'
                              : 'No matches for "${_query.trim()}".',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.outline),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        children: [
                          // Scrolls with the rows (not pinned): at a large
                          // text size a long explanation would otherwise eat
                          // the room the list and Confirm need above the
                          // keyboard.
                          if (widget.subtitle != null && _query.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                              child: Text(
                                widget.subtitle!,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: scheme.outline),
                              ),
                            ),
                          if (widget.clearLabel != null && _query.isEmpty)
                            _PickerRow(
                              label: widget.clearLabel!,
                              selected: _selected.isEmpty,
                              multi: false,
                              onTap: () => Navigator.of(
                                context,
                              ).pop(PickerChoice<T>(null, cleared: true)),
                            ),
                          for (final item in visible)
                            _PickerRow(
                              label: item.label,
                              sublabel: item.sublabel,
                              selected: _selected.contains(item.value),
                              multi: widget.multi,
                              onTap: () => _toggle(item.value),
                            ),
                        ],
                      ),
              ),
              if (widget.multi)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: scheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: FilledButton(
                        onPressed: _selected.length < widget.minSelected
                            ? null
                            : _confirm,
                        child: Text(
                          _selected.length < widget.minSelected
                              ? 'Select at least ${widget.minSelected}'
                              : _selected.isEmpty
                              ? widget.confirmLabel
                              : '${widget.confirmLabel} (${_selected.length})',
                        ),
                      ),
                    ),
                  ),
                )
              else
                SizedBox(height: media.padding.bottom + 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerRow extends StatelessWidget {
  final String label;
  final String? sublabel;
  final bool selected;
  final bool multi;
  final VoidCallback onTap;

  const _PickerRow({
    required this.label,
    required this.selected,
    required this.multi,
    required this.onTap,
    this.sublabel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: !multi,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              if (multi) ...[
                // IgnorePointer: the whole row is the tap target (one
                // handler), the box is just the state indicator.
                IgnorePointer(
                  child: Checkbox(value: selected, onChanged: (_) {}),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (sublabel != null && sublabel!.isNotEmpty)
                      Text(
                        sublabel!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
              if (!multi && selected)
                Icon(Icons.check_rounded, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A form-field-looking control that opens [showSinglePickerSheet] — the
/// drop-in replacement for DropdownButtonFormField: same label/hint/error
/// look, but the choices open in the searchable, keyboard-safe sheet.
class PickerFormField<T> extends StatelessWidget {
  final String label;
  final String? hint;
  final String? errorText;
  final T? value;
  final List<PickerItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? sheetTitle;
  final String? clearLabel;
  final bool enabled;

  const PickerFormField({
    super.key,
    required this.label,
    required this.items,
    required this.onChanged,
    this.value,
    this.hint,
    this.errorText,
    this.sheetTitle,
    this.clearLabel,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // A value no item matches (list reloaded underneath it) reads as empty
    // instead of throwing the way DropdownButtonFormField does.
    PickerItem<T>? current;
    for (final i in items) {
      if (i.value == value) current = i;
    }
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: !enabled
          ? null
          : () async {
              final scope = FocusScope.of(context);
              scope.unfocus();
              final choice = await showSinglePickerChoice<T>(
                context,
                title: sheetTitle ?? label,
                items: items,
                selected: current?.value,
                clearLabel: clearLabel,
              );
              // Dismissed without a choice → leave the value alone.
              if (choice != null) onChanged(choice.cleared ? null : choice.value);
            },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: errorText,
          enabled: enabled,
          suffixIcon: const Icon(Icons.arrow_drop_down_rounded),
        ),
        isEmpty: current == null,
        child: Text(
          current?.label ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}
