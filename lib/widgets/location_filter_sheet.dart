import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/department_option.dart';
import '../models/location_option.dart';
import 'picker_sheet.dart' show kPickerSearchThreshold;

/// The picked "where": locations (Area / Zone / Sub Zone) and departments —
/// ONE facet, as on the web's LocationFilterSelect. Both empty = All.
typedef WhereSelection = ({List<String> locations, List<String> departments});

/// widgets/location_filter_sheet.dart
/// ────────────────────────────────────
/// The phone's version of the web LocationFilterSelect: a grouped
/// multi-select with Area / Zone / Sub Zone / Department sections (each
/// collapsible, with its count), a search box once the list is long, an
/// "All Locations" row that clears the pick, Sub Zones grouped under and
/// labelled with their parent Zone, and ticking a Zone ticking its Sub Zones
/// too (as explicit ids, so each can still be unticked on its own — the Zone
/// row then shows the dash). Once locations are picked the Department section
/// narrows to the departments present at them.
///
/// Returns null when dismissed; otherwise the new selection (Apply).
Future<WhereSelection?> showLocationFilterSheet(
  BuildContext context, {
  required List<LocationOption> locations,
  required List<DepartmentOption> departments,
  required Map<String, List<String>> departmentsByLocation,
  required List<String> selectedLocations,
  required List<String> selectedDepartments,
  bool loading = false,
  bool failed = false,
  bool fullAccess = false,
  bool showDepartments = true,
}) {
  return showModalBottomSheet<WhereSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LocationSheet(
      locations: locations,
      departments: showDepartments ? departments : const [],
      departmentsByLocation: departmentsByLocation,
      selectedLocations: selectedLocations,
      selectedDepartments: selectedDepartments,
      loading: loading,
      failed: failed,
      fullAccess: fullAccess,
    ),
  );
}

const _sectionTitles = {'Area': 'Area', 'Zone': 'Zone', 'SubZone': 'Sub Zone'};

class _Row {
  final String id;
  final String label;
  final String? sublabel;
  final bool isDepartment;

  const _Row(this.id, this.label, {this.sublabel, this.isDepartment = false});
}

class _Section {
  final String key;
  final String title;
  final List<_Row> rows;
  final String? hint;

  const _Section(this.key, this.title, this.rows, {this.hint});
}

class _LocationSheet extends StatefulWidget {
  final List<LocationOption> locations;
  final List<DepartmentOption> departments;
  final Map<String, List<String>> departmentsByLocation;
  final List<String> selectedLocations;
  final List<String> selectedDepartments;
  final bool loading;
  final bool failed;
  final bool fullAccess;

  const _LocationSheet({
    required this.locations,
    required this.departments,
    required this.departmentsByLocation,
    required this.selectedLocations,
    required this.selectedDepartments,
    required this.loading,
    required this.failed,
    required this.fullAccess,
  });

  @override
  State<_LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends State<_LocationSheet> {
  late final Set<String> _locs = {...widget.selectedLocations};
  late final Set<String> _depts = {...widget.selectedDepartments};
  final Set<String> _collapsed = {};
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isAll => _locs.isEmpty && _depts.isEmpty;

  // Sub Zones offered under each Zone — what ticking that Zone ticks.
  Map<String, List<String>> get _childrenOfZone {
    final map = <String, List<String>>{};
    for (final l in widget.locations) {
      if (l.locationType == 'SubZone' && l.parentZoneId != null) {
        map.putIfAbsent(l.parentZoneId!, () => []).add(l.id);
      }
    }
    return map;
  }

  List<_Section> _buildSections() {
    final children = _childrenOfZone;
    final zoneName = {
      for (final l in widget.locations)
        if (l.locationType == 'Zone') l.id: l.name,
    };
    int byLabel(_Row a, _Row b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase());

    _Row row(LocationOption l, {String? sub}) =>
        _Row(l.id, l.display, sublabel: sub);

    final areas = [
      for (final l in widget.locations)
        if (l.locationType == 'Area') row(l),
    ]..sort(byLabel);
    final zones = [
      for (final l in widget.locations)
        if (l.locationType == 'Zone')
          row(
            l,
            sub: (children[l.id]?.length ?? 0) == 0
                ? null
                : '${children[l.id]!.length} sub zone${children[l.id]!.length == 1 ? '' : 's'}',
          ),
    ]..sort(byLabel);
    // Grouped under the parent Zone's name; one whose Zone isn't offered
    // still shows the name the server sent.
    final subs = [
      for (final l in widget.locations)
        if (l.locationType == 'SubZone')
          (
            zone: zoneName[l.parentZoneId] ?? l.parentZoneName ?? '',
            row: row(
              l,
              sub: (zoneName[l.parentZoneId] ?? l.parentZoneName) == null
                  ? null
                  : 'in ${zoneName[l.parentZoneId] ?? l.parentZoneName}',
            ),
          ),
    ]..sort((a, b) {
        final az = a.zone.isEmpty ? 1 : 0;
        final bz = b.zone.isEmpty ? 1 : 0;
        if (az != bz) return az - bz;
        final z = a.zone.toLowerCase().compareTo(b.zone.toLowerCase());
        return z != 0 ? z : byLabel(a.row, b.row);
      });
    final other = [
      for (final l in widget.locations)
        if (!_sectionTitles.containsKey(l.locationType)) row(l),
    ]..sort(byLabel);

    // Departments at the chosen locations. Never hides one already ticked —
    // a tick must stay visible so it can be unticked.
    final picked = _locs;
    final atPicked = {
      for (final id in picked) ...(widget.departmentsByLocation[id] ?? const []),
    };
    final narrow = picked.isNotEmpty;
    final offered = [
      for (final d in widget.departments)
        if (!narrow || atPicked.contains(d.id) || _depts.contains(d.id))
          _Row(d.id, d.display, isDepartment: true),
    ]..sort(byLabel);

    return [
      _Section('Area', 'Area', areas),
      _Section('Zone', 'Zone', zones),
      _Section('SubZone', 'Sub Zone', [for (final s in subs) s.row]),
      if (other.isNotEmpty) _Section('other', 'Location', other),
      if (widget.departments.isNotEmpty)
        _Section(
          'department',
          'Department',
          offered,
          hint: narrow && offered.isEmpty
              ? 'No departments at the selected locations.'
              : null,
        ),
    ];
  }

  bool _ticked(_Row r) =>
      r.isDepartment ? _depts.contains(r.id) : _locs.contains(r.id);

  void _toggle(_Row r) {
    setState(() {
      final set = r.isDepartment ? _depts : _locs;
      if (!set.remove(r.id)) set.add(r.id);
    });
  }

  // Zone + its Sub Zones together: all ticked → untick all, else tick all.
  void _toggleZone(_Row zone) {
    final kids = _childrenOfZone[zone.id] ?? const <String>[];
    final all = [zone.id, ...kids];
    setState(() {
      if (all.every(_locs.contains)) {
        _locs.removeAll(all);
      } else {
        _locs.addAll(all);
      }
    });
  }

  bool? _zoneState(_Row zone) {
    final kids = _childrenOfZone[zone.id] ?? const <String>[];
    final self = _locs.contains(zone.id);
    if (kids.isEmpty) return self;
    final n = kids.where(_locs.contains).length;
    if (self && n == kids.length) return true;
    if (self || n > 0) return null; // the dash
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final q = _query.trim().toLowerCase();
    final total = widget.locations.length + widget.departments.length;
    final sections = _buildSections();
    final maxHeight = math.min(
      media.size.height * 0.9,
      media.size.height - media.viewInsets.bottom - media.padding.top - 8,
    );
    bool matches(_Row r) =>
        q.isEmpty ||
        r.label.toLowerCase().contains(q) ||
        (r.sublabel ?? '').toLowerCase().contains(q);

    final visible = [
      for (final s in sections)
        (
          section: s,
          rows: s.rows.where(matches).toList(),
        ),
    ].where((e) => q.isEmpty || e.rows.isNotEmpty).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Material(
        color: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: math.max(maxHeight, 240)),
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
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.departments.isEmpty
                            ? 'Location'
                            : 'Location & Department',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (!_isAll)
                      TextButton(
                        onPressed: () => setState(() {
                          _locs.clear();
                          _depts.clear();
                        }),
                        child: const Text('Clear'),
                      ),
                  ],
                ),
              ),
              if (total >= kPickerSearchThreshold)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: widget.departments.isEmpty
                          ? 'Search locations'
                          : 'Search locations & departments',
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
                child: widget.loading && total == 0
                    ? const Padding(
                        padding: EdgeInsets.all(32),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : widget.failed && total == 0
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          "Couldn't load locations. Close this and try again.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.outline),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.only(bottom: 8),
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        children: [
                          if (q.isEmpty)
                            _CheckRow(
                              label: 'All Locations',
                              sublabel: widget.fullAccess
                                  ? 'Showing everything (Full Access)'
                                  : null,
                              value: _isAll,
                              bold: true,
                              onTap: () => setState(() {
                                _locs.clear();
                                _depts.clear();
                              }),
                            ),
                          if (total == 0)
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                widget.fullAccess
                                    ? 'No locations or departments have been set up yet.'
                                    : 'No places are linked to your account yet — All Locations still shows all of your data.',
                                style: TextStyle(color: scheme.outline),
                              ),
                            ),
                          for (final e in visible)
                            ..._sectionWidgets(context, e.section, e.rows, q),
                          if (q.isNotEmpty && visible.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(
                                'No matches found.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: scheme.outline),
                              ),
                            ),
                        ],
                      ),
              ),
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
                      onPressed: () => Navigator.of(context).pop((
                        locations: _locs.toList(),
                        departments: _depts.toList(),
                      )),
                      child: Text(
                        _isAll
                            ? 'Done — all locations'
                            : 'Done (${_locs.length + _depts.length})',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sectionWidgets(
    BuildContext context,
    _Section s,
    List<_Row> rows,
    String q,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // A search opens every section that has a match, so a hit is never hidden.
    final open = q.isNotEmpty || !_collapsed.contains(s.key);
    return [
      InkWell(
        onTap: () => setState(() {
          if (!_collapsed.remove(s.key)) _collapsed.add(s.key);
        }),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Row(
            children: [
              Icon(
                open
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: 18,
                color: scheme.outline,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  s.title.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: scheme.outline,
                  ),
                ),
              ),
              Text(
                '${s.rows.length}',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
      if (open) ...[
        for (final r in rows)
          s.key == 'Zone'
              ? _CheckRow(
                  label: r.label,
                  sublabel: r.sublabel,
                  tristate: true,
                  value: _zoneState(r),
                  onTap: () => _toggleZone(r),
                )
              : _CheckRow(
                  label: r.label,
                  sublabel: r.sublabel,
                  value: _ticked(r),
                  onTap: () => _toggle(r),
                ),
        if (s.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
            child: Text(
              s.hint ??
                  (widget.fullAccess ? 'None set up yet.' : 'None linked to you.'),
              style: TextStyle(fontSize: 12.5, color: scheme.outline),
            ),
          ),
      ],
    ];
  }
}

class _CheckRow extends StatelessWidget {
  final String label;
  final String? sublabel;
  final bool? value;
  final bool tristate;
  final bool bold;
  final VoidCallback onTap;

  const _CheckRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.sublabel,
    this.tristate = false,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = value != false;
    return Semantics(
      checked: value == true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          color: value == true
              ? scheme.primaryContainer.withValues(alpha: 0.3)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Row(
            children: [
              IgnorePointer(
                child: Checkbox(
                  value: value,
                  tristate: tristate,
                  onChanged: (_) {},
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: bold || on
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (sublabel != null)
                      Text(
                        sublabel!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
