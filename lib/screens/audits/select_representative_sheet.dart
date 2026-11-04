import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/employee_option.dart';
import '../../models/self_audit.dart';
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
/// **Or Self.** Sometimes nobody from the auditee side responds or is
/// available (or the location has nobody to pick). The "Self" button under
/// Confirm answers the step without naming anyone: the auditor says why (a
/// reason + a required remark, [showSelfAuditSheet]) and the report's Auditee
/// then reads "Self" (models/self_audit.dart). It works with an empty list
/// too. NCs are unaffected — each still names the person it is raised against.
///
/// Dismissible (back button, tap-outside, drag-to-close all work) — that
/// doesn't skip the requirement, it just leaves the checklist blocked
/// (audit_detail_screen.dart shows a "select a representative" banner
/// with a button back into this sheet). Also reused, with `initiallySelected`
/// (or `initialSelf`) pre-set, as the "Change" action once a representative is
/// already set. Returns the answer — the picked employee ids (at least one) or
/// Self — or null if dismissed any way. Dismissing the Self form goes back to
/// the people list rather than closing everything.
///
/// The body is the shared searchable multi picker (widgets/picker_sheet.dart):
/// a search box once the list is long, a pinned Confirm that stays above the
/// keyboard, rows that wrap at large text, and a clearly ticked state. (The
/// previous hand-rolled sheet had no search and a fixed 320dp list; the caller
/// (audit_detail_screen.dart) now also looks people up for department-scoped
/// audits, retries an empty lookup and tells the auditor when there really is
/// nobody to pick from, instead of silently skipping the step.)
Future<RepresentativeChoice?> showSelectRepresentativeSheet(
  BuildContext context, {
  required List<EmployeeOption> employees,
  List<String> initiallySelected = const [],
  SelfAuditChoice? initialSelf,
}) async {
  // Sorted by name and de-duplicated by id: /employees/by-location can list
  // a person once per matching location/department.
  final seen = <String>{};
  final sorted = [
    for (final e in employees)
      if (seen.add(e.id)) e,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  final changing = initiallySelected.isNotEmpty || initialSelf != null;
  final nobody = sorted.isEmpty;

  while (true) {
    final outcome = await showMultiPickerWithAlt<String>(
      context,
      title: changing
          ? 'Change Representative Auditee'
          : 'Select Representative Auditee',
      subtitle: nobody
          ? 'No members were found for this audit\'s location. Pull the audit to refresh and try again, or choose Self below if nobody from the auditee side is available.'
          : 'Pick who represents this location for this audit before you continue — you can pick more than one. '
                'You can still pick anyone at this location when raising an individual NC. '
                'If nobody from the auditee side responds or is available, choose Self.',
      searchHint: 'Search people',
      minSelected: 1,
      altLabel: initialSelf != null
          ? 'Self — edit the reason or remark'
          : 'Self — the auditee is not responding or not available',
      altSublabel: 'No one to name: say why and add a remark',
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
    if (outcome == null) return null;
    if (!outcome.alt) {
      return outcome.picked.isEmpty
          ? null
          : RepresentativeChoice.people(outcome.picked);
    }
    if (!context.mounted) return null;
    final self = await showSelfAuditSheet(context, initial: initialSelf);
    if (self != null) return RepresentativeChoice.self(self);
    if (!context.mounted) return null;
    // The Self form was dismissed: back to the people list.
  }
}

/// The Self form: why (one of [SelfAuditReason]) and a remark, both required.
/// Returns them, or null if dismissed.
Future<SelfAuditChoice?> showSelfAuditSheet(
  BuildContext context, {
  SelfAuditChoice? initial,
}) {
  return showModalBottomSheet<SelfAuditChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _SelfAuditSheet(initial: initial),
  );
}

class _SelfAuditSheet extends StatefulWidget {
  final SelfAuditChoice? initial;

  const _SelfAuditSheet({this.initial});

  @override
  State<_SelfAuditSheet> createState() => _SelfAuditSheetState();
}

class _SelfAuditSheetState extends State<_SelfAuditSheet> {
  late SelfAuditReason? _reason = widget.initial?.reason;
  late final TextEditingController _remark = TextEditingController(
    text: widget.initial?.remark ?? '',
  );

  @override
  void dispose() {
    _remark.dispose();
    super.dispose();
  }

  bool get _valid => _reason != null && _remark.text.trim().isNotEmpty;

  void _confirm() {
    if (!_valid) return;
    Navigator.of(context).pop(
      SelfAuditChoice(reason: _reason!, remark: _remark.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
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
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Text(
                  'Self audit',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nobody from the auditee side could take part, so you are conducting this audit yourself. '
                        'The report will show the Auditee as Self, with the reason and remark below. '
                        'Any NC you raise is still assigned to someone at this location — you pick who, per NC.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Why?',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final r in SelfAuditReason.values)
                            ChoiceChip(
                              label: Text(r.label),
                              selected: _reason == r,
                              onSelected: (_) => setState(() => _reason = r),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _remark,
                        minLines: 3,
                        maxLines: 6,
                        maxLength: kSelfAuditRemarkMax,
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Remark (required)',
                          hintText:
                              'What you tried and what happened — e.g. called twice, no answer.',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
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
                      onPressed: _valid ? _confirm : null,
                      child: Text(
                        _valid
                            ? 'Confirm Self audit'
                            : _reason == null
                            ? 'Choose why'
                            : 'Add a remark',
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
}
