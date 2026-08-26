import 'package:flutter/material.dart';

import '../../core/utils/formatters.dart';
import '../../models/employee_option.dart';

// The server's NC_SEVERITIES also allows "Observation" (audit.controller.
// js#scoreParameter) — deliberately not offered here, mobile only ever
// picks between these two. Labeled "Flag" in the UI below, not
// "Severity" — same underlying `severity` field server-side either way.
const _ncSeverities = ['Major', 'Minor'];

/// screens/audits/nc_details_sheet.dart
/// ───────────────────────────────────────
/// The popup a checkpoint's "Raise NC" pick opens to collect what the
/// server needs before it'll create the linked NC (audit.controller.js#
/// scoreParameter): who it's against (skipped for Self Audit — always
/// resolves to the auditor themselves), a due date, a severity, plus the
/// remark that's shared with the checkpoint's own text field. Same shape
/// as the standalone raise_nc_sheet.dart's freeform flow, just scoped to
/// one specific checkpoint instead of a blank NC.
class NcDetailsResult {
  final String? auditeeEmployeeId;
  final DateTime targetDate;
  final String remark;
  final String severity;

  const NcDetailsResult({this.auditeeEmployeeId, required this.targetDate, required this.remark, required this.severity});
}

Future<NcDetailsResult?> showNcDetailsSheet(
  BuildContext context, {
  required List<EmployeeOption> employees,
  required bool isSelfAudit,
  String? initialAuditeeId,
  DateTime? initialTargetDate,
  required String initialRemark,
  String initialSeverity = 'Minor',
}) {
  return showModalBottomSheet<NcDetailsResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NcDetailsSheet(
      employees: employees,
      isSelfAudit: isSelfAudit,
      initialAuditeeId: initialAuditeeId,
      initialTargetDate: initialTargetDate,
      initialRemark: initialRemark,
      initialSeverity: initialSeverity,
    ),
  );
}

class _NcDetailsSheet extends StatefulWidget {
  final List<EmployeeOption> employees;
  final bool isSelfAudit;
  final String? initialAuditeeId;
  final DateTime? initialTargetDate;
  final String initialRemark;
  final String initialSeverity;

  const _NcDetailsSheet({
    required this.employees,
    required this.isSelfAudit,
    this.initialAuditeeId,
    this.initialTargetDate,
    required this.initialRemark,
    required this.initialSeverity,
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

  @override
  void initState() {
    super.initState();
    _remarkController = TextEditingController(text: widget.initialRemark);
    _auditeeEmployeeId = widget.initialAuditeeId;
    _targetDate = widget.initialTargetDate;
    _severity = widget.initialSeverity;
  }

  @override
  void dispose() {
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _targetDate ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _targetDate = picked);
  }

  void _submit() {
    setState(() => _dateTouched = true);
    final formOk = _formKey.currentState?.validate() ?? false;
    if (!formOk || _targetDate == null) return;
    Navigator.of(context).pop(NcDetailsResult(
      auditeeEmployeeId: widget.isSelfAudit ? null : _auditeeEmployeeId,
      targetDate: _targetDate!,
      remark: _remarkController.text.trim(),
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
    final pickable = widget.employees;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
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
                Text('Raise NC — Details', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  widget.isSelfAudit
                      ? 'Self Audit — this NC will be raised against you.'
                      : 'Pick who this is against and by when it should be closed.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
                const SizedBox(height: 16),
                if (!widget.isSelfAudit) ...[
                  DropdownButtonFormField<String>(
                    initialValue: pickable.any((e) => e.id == _auditeeEmployeeId) ? _auditeeEmployeeId : null,
                    decoration: const InputDecoration(labelText: 'Raise NC against', prefixIcon: Icon(Icons.person_outline)),
                    isExpanded: true,
                    items: pickable
                        .map((e) => DropdownMenuItem(value: e.id, child: Text(e.name, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (v) => setState(() => _auditeeEmployeeId = v),
                    validator: (v) => v == null ? 'Pick who this NC is against' : null,
                  ),
                  if (pickable.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'No one available to pick from your hierarchy.',
                        style: TextStyle(color: scheme.outline, fontSize: 11.5),
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
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
                  items: _ncSeverities.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
                  onChanged: (v) => setState(() => _severity = v ?? _severity),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _remarkController,
                  maxLines: 3,
                  decoration: const InputDecoration(labelText: 'Remark', alignLabelWithHint: true, prefixIcon: Icon(Icons.chat_bubble_outline)),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Add a remark' : null,
                ),
                const SizedBox(height: 20),
                ElevatedButton(onPressed: _submit, child: const Text('Save & Raise NC')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
