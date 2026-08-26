import 'package:flutter/material.dart';

import '../../models/employee_option.dart';

/// The "select representative auditee" step — a hard gate before an
/// assigned auditor can start scoring a non-Self audit (see
/// audit_detail_screen.dart's `_needsRepresentative`: the checklist stays
/// read-only and Submit/Final Submit stay hidden until this is set). Picks
/// one or more people from every member of the audit's location(s) — the
/// same pool the "raise NC against" picker uses (AuditsProvider.
/// auditeeCandidates, purely location-scoped, no manager-hierarchy or
/// audit-type narrowing) — as a default for who findings get raised
/// against; it does not restrict the per-NC picker, which still offers
/// everyone at those locations. Multi-select (was a single-choice
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
Future<List<String>?> showSelectRepresentativeSheet(
  BuildContext context, {
  required List<EmployeeOption> employees,
  List<String> initiallySelected = const [],
}) {
  return showModalBottomSheet<List<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SelectRepresentativeSheet(
      employees: employees,
      initiallySelected: initiallySelected,
    ),
  );
}

class _SelectRepresentativeSheet extends StatefulWidget {
  final List<EmployeeOption> employees;
  final List<String> initiallySelected;

  const _SelectRepresentativeSheet({
    required this.employees,
    this.initiallySelected = const [],
  });

  @override
  State<_SelectRepresentativeSheet> createState() =>
      _SelectRepresentativeSheetState();
}

class _SelectRepresentativeSheetState
    extends State<_SelectRepresentativeSheet> {
  late final Set<String> _selected = {...widget.initiallySelected};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.initiallySelected.isEmpty
                  ? 'Select Representative Auditee${_selected.length > 1 ? 's' : ''}'
                  : 'Change Representative Auditee${_selected.length > 1 ? 's' : ''}',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Pick who represents this location for this audit before you continue — you can pick more than one. '
              'You can still pick anyone at this location when raising an individual NC.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
            const SizedBox(height: 8),
            // Same capped-height, scrollable list convention as every
            // other multi-select in this app (e.g. the web's
            // TeamFilterPanel/LocationFilterSelect) — a long employee list
            // shouldn't push the Confirm button off-screen.
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: widget.employees.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final e = widget.employees[i];
                  final checked = _selected.contains(e.id);
                  return CheckboxListTile(
                    value: checked,
                    onChanged: (v) => setState(() {
                      if (v ?? false) {
                        _selected.add(e.id);
                      } else {
                        _selected.remove(e.id);
                      }
                    }),
                    title: Text(e.name, overflow: TextOverflow.ellipsis),
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.of(context).pop(_selected.toList()),
              child: Text(
                _selected.isEmpty
                    ? 'Select at least one'
                    : 'Confirm (${_selected.length})',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
