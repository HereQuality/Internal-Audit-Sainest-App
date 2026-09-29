import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';
import '../../models/employee_option.dart';
import '../../models/nc_model.dart';

// The Flag picker offers nc_model.dart#kNcFlags (Major / Minor) only.
// "Observation" is no longer a Flag — the server merely tolerates it on
// legacy NCs — so it is never offered, and an existing NC that still
// carries it is seeded as Minor (see initState). Labeled "Flag" in the UI
// below, not "Severity" — same underlying `severity` field server-side
// either way.

/// screens/audits/nc_details_sheet.dart
/// ───────────────────────────────────────
/// The popup a checkpoint's "Raise NC" pick opens to collect what the
/// server needs before it'll create the linked NC (audit.controller.js#
/// scoreParameter): who it's against (always an explicit pick from the
/// audited location's people — the caller excludes the acting auditor, an
/// NC is never raised against the raiser), a due date, a flag, plus the
/// remark that's shared with the checkpoint's own text field. Same shape
/// as the old standalone freeform Raise NC sheet did (removed — an NC is
/// only ever raised on the specific checkpoint it's about).
///
/// It doubles as the EDIT sheet for an already-raised NC (see
/// [NcSheetMode.edit] and checkpoint_card.dart's `_openNcEditSheet`).
/// That used to be a separate inline form grown inside the checkpoint
/// card itself — two dropdowns and a date row that pushed everything
/// below them down the scroll, on the one control auditors complained
/// they couldn't hit. It collected the exact same three fields this
/// sheet already collects, so it's the same sheet now; only the wording,
/// the primary button, whether the Remark field appears at all, and how
/// far back the date picker will go actually differ between the modes.
enum NcSheetMode {
  /// Raising a brand-new NC off a checkpoint's "NC" finding — collects
  /// the remark too, since scoreParameter saves it onto both the
  /// checkpoint and the NC it creates.
  raise,

  /// Fixing a mistake on an NC that already exists (nc.controller.js#
  /// updateNC). That endpoint only ever accepts auditeeEmployeeId /
  /// severity (the flag) / targetDate — the checkpoint's remark is NOT part of the
  /// update, so showing the field here would imply an edit that silently
  /// went nowhere.
  edit,
}

class NcDetailsResult {
  // Always set: the sheet's picker is required, so a result only ever comes
  // back with a real person chosen.
  final String auditeeEmployeeId;
  final DateTime targetDate;
  final String remark;
  final String severity;

  const NcDetailsResult({required this.auditeeEmployeeId, required this.targetDate, required this.remark, required this.severity});
}

Future<NcDetailsResult?> showNcDetailsSheet(
  BuildContext context, {
  required List<EmployeeOption> employees,
  String? initialAuditeeId,
  // The current auditee's display name — ONLY meaningful (and only ever
  // passed) alongside `initialAuditeeId` in edit mode. See its use below:
  // this is what lets the dropdown show/keep the NC's real auditee even
  // when that person has fallen out of `employees` (a per-location audit
  // whose active zone has changed since the NC was raised — see
  // audit_detail_screen.dart#_employeesForNc — narrows `employees` to
  // whoever is at the CURRENTLY active location, which is not necessarily
  // the location this NC's auditee belongs to).
  String? initialAuditeeName,
  DateTime? initialTargetDate,
  required String initialRemark,
  String initialSeverity = 'Minor',
  // Defaulted, not required, so the original raise call site
  // (checkpoint_card.dart#_openNcDetailsPopup) keeps working verbatim.
  NcSheetMode mode = NcSheetMode.raise,
}) {
  return showModalBottomSheet<NcDetailsResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NcDetailsSheet(
      employees: employees,
      initialAuditeeId: initialAuditeeId,
      initialAuditeeName: initialAuditeeName,
      initialTargetDate: initialTargetDate,
      initialRemark: initialRemark,
      initialSeverity: initialSeverity,
      mode: mode,
    ),
  );
}

class _NcDetailsSheet extends StatefulWidget {
  final List<EmployeeOption> employees;
  final String? initialAuditeeId;
  final String? initialAuditeeName;
  final DateTime? initialTargetDate;
  final String initialRemark;
  final String initialSeverity;
  final NcSheetMode mode;

  const _NcDetailsSheet({
    required this.employees,
    this.initialAuditeeId,
    this.initialAuditeeName,
    this.initialTargetDate,
    required this.initialRemark,
    required this.initialSeverity,
    required this.mode,
  });

  @override
  State<_NcDetailsSheet> createState() => _NcDetailsSheetState();
}

class _NcDetailsSheetState extends State<_NcDetailsSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _remarkController;
  String? _auditeeEmployeeId;
  DateTime? _targetDate;
  late String _severity;
  bool _dateTouched = false;

  bool get _isEdit => widget.mode == NcSheetMode.edit;

  @override
  void initState() {
    super.initState();
    _remarkController = TextEditingController(text: widget.initialRemark);
    _auditeeEmployeeId = widget.initialAuditeeId;
    // Pre-filled to one week out (still fully editable via _pickDate below)
    // so raising an NC doesn't stall on picking a date most auditors would
    // leave at a sensible default anyway — matches web's ParameterScoreCard
    // .jsx and the server's own +7-days-from-now fallback
    // (audit.controller.js#scoreParameter) for a caller that omits it.
    // In edit mode the NC always already carries one, so the fallback only
    // ever applies to a legacy record that somehow has none.
    //
    // Stripped to a bare date (year/month/day only), NOT
    // DateTime.now().add(...) directly: that carries the current
    // hour/minute/second, and _pickDate's own showDatePicker always
    // returns a midnight-local value (DateUtils.dateOnly) — so an
    // auditor who leaves this pre-filled value untouched and taps Save
    // would submit a targetDate with a time-of-day on it, unlike every
    // other path that reaches this field (a touched date picker here, the
    // server's own fallback, the web app). That distinction is not
    // cosmetic: effectiveDeadline (core/utils/nc_timeliness.dart, mirrored
    // server-side by utils/dueDate.js) treats a bare date as "due by the
    // END of that day" but a date carrying a time component as due at
    // that EXACT instant — so a raise made at, say, 14:32 would silently
    // tighten its own due date's grading by most of a day.
    final fallback = DateTime.now().add(const Duration(days: 7));
    _targetDate = widget.initialTargetDate ??
        DateTime(fallback.year, fallback.month, fallback.day);
    // Through flagOf so a legacy "Observation" (or missing) severity seeds
    // as Minor: the dropdown below only has Major/Minor items, and a
    // DropdownButtonFormField whose value matches none of them throws.
    _severity = flagOf(widget.initialSeverity);
  }

  @override
  void dispose() {
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _targetDate ?? now.add(const Duration(days: 7));
    // Raising: never backdate a brand-new NC, so `now` is the floor.
    // Editing: an NC that's been open a while legitimately carries a due
    // date that's already passed, and showDatePicker asserts
    // initialDate >= firstDate — with a hard `now` floor the sheet would
    // simply crash open on exactly the overdue NCs most likely to need
    // their date pushed out. The floor drops to the existing value's own
    // day in that case (date-only, so the assert can't trip on a
    // time-of-day difference) rather than opening the whole past up.
    final firstDate = _isEdit && initial.isBefore(now) ? DateTime(initial.year, initial.month, initial.day) : now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: firstDate,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _targetDate = picked);
    }
  }

  void _submit() {
    setState(() => _dateTouched = true);
    final formOk = _formKey.currentState?.validate() ?? false;
    // The picker's own validator already rejects an empty pick (and an empty
    // list, which leaves nothing to pick) — the null check here is what lets
    // the result carry a non-null auditee.
    final auditeeId = _auditeeEmployeeId;
    if (!formOk || _targetDate == null || auditeeId == null) {
      return;
    }
    Navigator.of(context).pop(NcDetailsResult(
      auditeeEmployeeId: auditeeId,
      targetDate: _targetDate!,
      // Edit mode never renders the Remark field (updateNC wouldn't accept
      // it — see NcSheetMode.edit), so this hands back exactly what came
      // in rather than an empty string a caller might mistake for "the
      // auditor cleared the remark" and write over the real one with.
      remark: _isEdit ? widget.initialRemark : _remarkController.text.trim(),
      severity: _severity,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Members of just the audit's current location, where the parent
    // screen has already narrowed the list down (audit_detail_screen.dart)
    // — an empty result there just means no one's been assigned to this
    // location yet, so it falls back to showing everyone rather than
    // leaving the picker with nothing selectable at all.
    //
    // In EDIT mode specifically, that narrowing can also drop the NC's
    // OWN current auditee — they were assigned while a different location
    // tab was active, and this one's active location has since changed
    // (see _NcDetailsSheet's own doc on initialAuditeeName above). Without
    // the synthetic item below, the dropdown would silently show blank
    // (no indication of who the NC is even against right now) AND — far
    // worse — DropdownButtonFormField's underlying FormFieldState seeds
    // its value ONCE from `initialValue` at construction and never resyncs
    // it (Flutter's own FormField.didUpdateWidget only ever reacts to
    // forceErrorText), so a null initial value here would fail this
    // field's `validator` and permanently block Save — even if the user
    // only meant to change the due date and never touched this dropdown
    // at all. Prepending a synthetic item for the current auditee (when
    // they're missing from `employees`) keeps them both visible and
    // selected by default, so an edit that doesn't touch this field
    // submits the auditee unchanged instead of being unsavable.
    final currentAuditeeMissing = widget.initialAuditeeId != null
        && widget.initialAuditeeId!.isNotEmpty
        && !widget.employees.any((e) => e.id == widget.initialAuditeeId);
    final pickable = currentAuditeeMissing
        ? [
            EmployeeOption(
              id: widget.initialAuditeeId!,
              name: widget.initialAuditeeName?.isNotEmpty == true
                  ? widget.initialAuditeeName!
                  : 'Currently assigned',
            ),
            ...widget.employees,
          ]
        : widget.employees;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      // Ink, not Container: the sheet's own Material is transparent, so a
      // decorated Container would sit on top of the due-date row's InkWell ink.
      child: Ink(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        // + the home-indicator inset: without it the Save button sat inside the
        // bottom safe area, under the iPhone's home indicator.
        padding: EdgeInsets.fromLTRB(16, 12, 16, 20 + MediaQuery.paddingOf(context).bottom),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(color: scheme.outlineVariant, borderRadius: BorderRadius.circular(999)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _isEdit ? 'Edit NC Details' : 'Raise NC — Details',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  _introLine(),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: pickable.any((e) => e.id == _auditeeEmployeeId) ? _auditeeEmployeeId : null,
                  decoration: InputDecoration(
                    labelText: _isEdit ? 'NC is against' : 'Raise NC against',
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  isExpanded: true,
                  items: pickable
                      .map((e) => DropdownMenuItem(
                            value: e.id,
                            // Flags the synthetic current-auditee entry
                            // (see `currentAuditeeMissing` above) so it
                            // doesn't read as just another ordinary
                            // pickable name — this person isn't offered
                            // by the normal location-scoped list, they're
                            // shown because they're who it's against
                            // right now.
                            child: Text(
                              currentAuditeeMissing && e.id == widget.initialAuditeeId
                                  ? '${e.name} (not at this location)'
                                  : e.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _auditeeEmployeeId = v),
                  // Re-validates once the user has touched the picker, so the
                  // "Pick who this NC is against" error clears the moment they do
                  // (it used to stay under a correctly filled-in name).
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => v == null ? 'Pick who this NC is against' : null,
                ),
                // The list is the audited location's people minus the acting
                // auditor — say so when that leaves nobody, or the required
                // picker just looks broken. Saving is blocked meanwhile (the
                // button below is disabled): an NC always needs an
                // "against" person.
                if (pickable.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      "No one else is tagged to this audit's location.",
                      style: TextStyle(color: scheme.outline, fontSize: 11.5),
                    ),
                  ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Due Date',
                      prefixIcon: const Icon(Icons.event_outlined),
                      errorText: _dateTouched && _targetDate == null ? 'Please choose a due date' : null,
                    ),
                    child: Text(_targetDate == null ? 'Select a date' : Formatters.date(_targetDate)),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _severity,
                  decoration: const InputDecoration(labelText: 'Flag', prefixIcon: Icon(Icons.priority_high_outlined)),
                  items: kNcFlags.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (v) => setState(() => _severity = v ?? _severity),
                ),
                // Raise only — the checkpoint remark isn't one of the three
                // fields updateNC accepts (see NcSheetMode.edit), and the
                // checkpoint's own remark field on the card behind this
                // sheet stays the place to change it afterwards.
                if (!_isEdit) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _remarkController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Remark',
                      // Carried over from the checkpoint's own remark box behind this
                      // sheet (same field, see this file's own header doc) — said here
                      // so it doesn't read as an unexplained prefill.
                      helperText: 'This is the checkpoint\'s remark — edit it here if needed',
                      alignLabelWithHint: true,
                      prefixIcon: Icon(Icons.chat_bubble_outline),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Add a remark' : null,
                  ),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: pickable.isEmpty ? null : _submit,
                  child: Text(_isEdit ? 'Save Changes' : 'Save & Raise NC'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Two distinct one-liners rather than one generic sentence: in edit mode
  // the auditee CAN still be reassigned — nc.controller.js#updateNC
  // notifies whoever it moves to — which is worth saying out loud before
  // someone changes it by accident.
  String _introLine() {
    return _isEdit
        ? 'Change who this is against, when it\'s due, or how it\'s flagged.'
        : 'Pick who this is against and by when it should be closed.';
  }
}
