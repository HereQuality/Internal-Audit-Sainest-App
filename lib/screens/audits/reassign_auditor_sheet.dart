import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/audit_model.dart';
import '../../models/employee_option.dart';
import '../../providers/audits_provider.dart';
import '../../widgets/picker_sheet.dart';

/// screens/audits/reassign_auditor_sheet.dart
/// ───────────────────────────────────────────
/// A place leader's "this auditor is not coming" sheet: swap ONE auditor of an
/// audit for someone else, from the phone (the counterpart of the web's
/// ReassignAuditorModal; server: audit.controller.js#reassignAuditor — who may
/// and when is decided there, and the list only offers the button when the
/// server says `canReassign`).
///
/// The new auditor is picked from the audited place's own members, not already
/// on the audit and qualified for its type (AuditsProvider.
/// fetchReassignCandidates) — the same pool the web dialog shows. Whatever was
/// already scored stays, and the audit's open NCs move to the new auditor; the
/// note under the form says so when something has been scored.
///
/// Returns the server's confirmation message once the auditor was changed (the
/// caller shows it on the screen underneath), null when dismissed.
Future<String?> showReassignAuditorSheet(BuildContext context, AuditModel audit) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _ReassignBody(audit: audit),
  );
}

class _ReassignBody extends StatefulWidget {
  final AuditModel audit;
  const _ReassignBody({required this.audit});

  @override
  State<_ReassignBody> createState() => _ReassignBodyState();
}

class _ReassignBodyState extends State<_ReassignBody> {
  final TextEditingController _reason = TextEditingController();
  List<EmployeeOption>? _candidates;
  bool _loadFailed = false;
  String? _fromId;
  String? _toId;
  bool _alsoUpcoming = false;
  bool _busy = false;
  String? _error;

  AuditModel get audit => widget.audit;

  @override
  void initState() {
    super.initState();
    // With one auditor, that is who is being replaced.
    if (audit.auditors.length == 1) _fromId = audit.auditors.first.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPeople());
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadPeople() async {
    setState(() {
      _candidates = null;
      _loadFailed = false;
    });
    final people = await context.read<AuditsProvider>().fetchReassignCandidates(audit);
    if (!mounted) return;
    setState(() {
      _candidates = people;
      _loadFailed = people == null;
      // A pick that dropped out of a reloaded pool is no pick.
      if (people != null && !people.any((p) => p.id == _toId)) _toId = null;
    });
  }

  Future<void> _confirm() async {
    final from = _fromId;
    final to = _toId;
    if (from == null || to == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await context.read<AuditsProvider>().reassignAuditor(
      audit.id,
      toAuditorId: to,
      fromAuditorId: from,
      reason: _reason.text,
      alsoUpcoming: _alsoUpcoming,
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result.message);
      return;
    }
    setState(() {
      _busy = false;
      _error = result.message;
    });
  }

  String get _period {
    final start = audit.scheduledDate;
    final end = audit.scheduledEndDate;
    if (start == null) return '';
    if (end == null || Formatters.date(end) == Formatters.date(start)) {
      return Formatters.date(start);
    }
    return '${Formatters.date(start)} – ${Formatters.date(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final people = _candidates;
    final items = [
      for (final p in people ?? const <EmployeeOption>[])
        PickerItem<String>(
          value: p.id,
          label: p.name,
          sublabel: p.teams.isEmpty ? null : p.teams.map((t) => t.name).join(', '),
        ),
    ];
    final canSave = !_busy && _fromId != null && _toId != null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Reassign auditor', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(audit.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              [
                if (audit.location.isNotEmpty) audit.location,
                if (_period.isNotEmpty) _period,
                if (audit.isRecurring) '${audit.frequency ?? 'Recurring'} series',
              ].join(' · '),
              style: muted,
            ),
            const SizedBox(height: 16),
            Text(
              audit.auditors.length > 1 ? 'Who is not coming?' : 'Current auditor',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            for (final a in audit.auditors)
              _AuditorRow(
                name: a.name + (a.inactive ? ' (inactive)' : ''),
                selectable: audit.auditors.length > 1,
                selected: _fromId == a.id,
                onTap: _busy ? null : () => setState(() => _fromId = a.id),
              ),
            const SizedBox(height: 14),
            if (people == null && !_loadFailed)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_loadFailed)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "Couldn't load the list of people.",
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                  TextButton(onPressed: _loadPeople, child: const Text('Retry')),
                ],
              )
            else if (items.isEmpty)
              Text(
                audit.isCFT
                    ? "This is a Cross Functional Team audit — only its planner or scheduler can change its auditor."
                    : 'Nobody else at this place is available and qualified for this audit type.',
                style: muted,
              )
            else
              PickerFormField<String>(
                label: 'New auditor',
                hint: 'Pick new auditor',
                sheetTitle: 'New auditor',
                items: items,
                value: _toId,
                enabled: !_busy,
                onChanged: (v) => setState(() => _toId = v),
              ),
            if (people != null && items.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text("Showing only the members of this audit's place.", style: muted),
            ],
            const SizedBox(height: 14),
            TextField(
              controller: _reason,
              enabled: !_busy,
              maxLength: 300,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'e.g. On leave today',
              ),
            ),
            if (audit.isRecurring)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _alsoUpcoming,
                onChanged: _busy ? null : (v) => setState(() => _alsoUpcoming = v ?? false),
                title: const Text('Also change the upcoming occurrences of this series'),
                subtitle: const Text(
                  "Later occurrences that still have this auditor move too — finished or overdue ones stay as they are.",
                ),
              ),
            if (audit.scoredCount > 0) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.amber.withValues(alpha: 0.45)),
                ),
                child: Text(
                  '${audit.scoredCount} checkpoint${audit.scoredCount == 1 ? ' is' : 's are'} already scored — '
                  'those scores stay, the new auditor continues from here, and any open NCs on this audit move to them.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: canSave ? _confirm : null,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Reassign'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditorRow extends StatelessWidget {
  final String name;
  final bool selectable;
  final bool selected;
  final VoidCallback? onTap;

  const _AuditorRow({
    required this.name,
    required this.selectable,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: selectable ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            if (selectable)
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            else
              Icon(Icons.person_outline, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(name)),
          ],
        ),
      ),
    );
  }
}
