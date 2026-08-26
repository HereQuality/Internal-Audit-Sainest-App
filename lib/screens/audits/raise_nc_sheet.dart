import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../core/utils/snackbar.dart';
import '../../core/utils/validators.dart';
import '../../models/employee_option.dart';
import '../../providers/audits_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';

// Same set nc_details_sheet.dart's checkpoint-scoped flow offers — see its
// own doc comment for why "Observation" (server-accepted, NC_SEVERITIES)
// isn't included, and why this is labeled "Flag" below, not "Severity".
const _ncSeverities = ['Major', 'Minor'];

Future<void> showRaiseNcSheet(
  BuildContext context, {
  required String auditId,
  required String auditTitle,
  bool isSelfAudit = false,
  List<EmployeeOption> employees = const [],
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _RaiseNcSheet(auditId: auditId, auditTitle: auditTitle, isSelfAudit: isSelfAudit, employees: employees),
  );
}

class _RaiseNcSheet extends StatefulWidget {
  final String auditId;
  final String auditTitle;
  final bool isSelfAudit;
  final List<EmployeeOption> employees;

  const _RaiseNcSheet({required this.auditId, required this.auditTitle, required this.isSelfAudit, required this.employees});

  @override
  State<_RaiseNcSheet> createState() => _RaiseNcSheetState();
}

class _RaiseNcSheetState extends State<_RaiseNcSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  DateTime? _targetDate;
  String? _auditeeEmployeeId;
  // Defaults to "Minor" — matches models/NonConformance.js#severity's own
  // schema default — so it's never a second field to remember to touch.
  String _severity = 'Minor';
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _targetDate = picked);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_targetDate == null) {
      showErrorSnackBar(context, 'Please choose a target date.');
      return;
    }
    if (!widget.isSelfAudit && _auditeeEmployeeId == null) {
      showErrorSnackBar(context, 'Please pick who this NC is against.');
      return;
    }
    setState(() => _isSubmitting = true);
    final error = await context.read<AuditsProvider>().raiseNc(
          auditId: widget.auditId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          targetDate: _targetDate!,
          auditeeEmployeeId: widget.isSelfAudit ? null : _auditeeEmployeeId,
          severity: _severity,
        );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (error != null) {
      showErrorSnackBar(context, error);
      return;
    }
    // raiseNc lives on AuditsProvider (it's fired from the audit workspace)
    // but the NC itself belongs to NcProvider's own "Raised by me" list —
    // and the raiser gets no socket notification for their own action — so
    // without this, the NC Monitoring tab and the dashboard's NC Pending
    // tile would both still show the pre-raise counts until reloaded.
    await Future.wait([
      context.read<NcProvider>().fetchRaisedByMe(),
      context.read<DashboardProvider>().refreshAll(),
    ]);
    if (!mounted) return;
    Navigator.of(context).pop();
    showSuccessSnackBar(context, 'NC raised successfully.');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                    decoration: BoxDecoration(
                      color: scheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Raise Non-Conformance', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('For audit: ${widget.auditTitle}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _titleController,
                  decoration: const InputDecoration(labelText: 'NC Title'),
                  validator: (v) => Validators.required(v, field: 'Title'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descriptionController,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true),
                  validator: (v) => Validators.required(v, field: 'Description'),
                ),
                const SizedBox(height: 12),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(12),
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Target Date', prefixIcon: Icon(Icons.event_outlined)),
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
                if (!widget.isSelfAudit) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _auditeeEmployeeId,
                    decoration: const InputDecoration(labelText: 'Raise NC against', prefixIcon: Icon(Icons.person_outline)),
                    isExpanded: true,
                    items: widget.employees
                        .map((e) => DropdownMenuItem(value: e.id, child: Text(e.name, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (v) => setState(() => _auditeeEmployeeId = v),
                  ),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Raise NC'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
