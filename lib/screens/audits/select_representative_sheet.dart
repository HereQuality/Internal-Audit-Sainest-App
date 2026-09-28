import 'package:flutter/material.dart';

import '../../models/employee_option.dart';
import '../../widgets/picker_sheet.dart';

/// The "select representative auditee" step — a hard gate before an
/// assigned auditor can start scoring (see
/// audit_detail_screen.dart's `_needsRepresentative`: the checklist stays
/// read-only and Submit/Final Submit stay hidden until this is set). Picks
/// one or more people from every member of the audit's location(s) — the
/// pool the "raise NC against" picker is built from (AuditsProvider.
/// auditeeCandidates, purely location-scoped, no manager-hierarchy or
/// audit-type narrowing; that picker additionally drops the acting auditor,
/// this one keeps the full list) — as a default for who findings get raised
/// against; it does not restrict the per-NC picker, which still offers
/// everyone else at those locations. Multi-select (was a single-choice
/// dropdown) — a location can genuinely have more than one accountable
/// representative, and there's no reason to force picking just one when
/// the underlying field (models/Audit.js#auditeeIds) already supports a
/// list.
///
/// Dismissible (back button, tap-outside, drag-to-close all work) — that
/// doesn't skip the requirement, it just leaves the checklist blocked
/// (audit_detail_screen.dart shows a "select a representative" banner
/// with a button back into this sheet). Also reused, with `initiallySelected`
/// pre-checked, as the "Change" action once a representative is already
/// set. Returns the picked employee ids (at least one, if Confirm was
/// tapped), or null if dismissed any way.
///
/// The body is the shared searchable multi picker (widgets/picker_sheet.dart):
/// a search box once the list is long, a pinned Confirm that stays above the
/// keyboard, rows that wrap at large text, and a clearly ticked state. (The
/// previous hand-rolled sheet had no search and a fixed 320dp list; the caller
/// (audit_detail_screen.dart) now also looks people up for department-scoped
/// audits, retries an empty lookup and tells the auditor when there really is
/// nobody to pick from, instead of silently skipping the step.)
Future<List<String>?> showSelectRepresentativeSheet(
  BuildContext context, {
  required List<EmployeeOption> employees,
  List<String> initiallySelected = const [],
}) {
  // Sorted by name and de-duplicated by id: /employees/by-location can list
  // a person once per matching location/department.
  final seen = <String>{};
  final sorted = [
    for (final e in employees)
      if (seen.add(e.id)) e,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final changing = initiallySelected.isNotEmpty;
  return showMultiPickerSheet<String>(
    context,
    title: changing
        ? 'Change Representative Auditee'
        : 'Select Representative Auditee',
    subtitle:
        'Pick who represents this location for this audit before you continue — you can pick more than one. '
        'You can still pick anyone at this location when raising an individual NC.',
    searchHint: 'Search people',
    minSelected: 1,
    items: [
      for (final e in sorted)
        PickerItem<String>(
          value: e.id,
          label: e.name,
          sublabel: e.teams.isEmpty
              ? null
              : e.teams.map((t) => t.name).join(', '),
        ),
    ],
    selected: initiallySelected,
  );
}
