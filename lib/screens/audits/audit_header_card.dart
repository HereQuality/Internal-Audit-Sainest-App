import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/audit_detail_model.dart';
import '../../widgets/status_badge.dart';

/// The audit-detail screen's own identifying header — mirrors the web
/// app's AuditReportDetail.jsx header block (title, auditor(s), scoped
/// location(s), schedule) condensed for a phone screen. Previously this
/// screen showed almost nothing here besides the scope text and a status
/// badge (see audit_detail_screen.dart's _buildBody), leaving whoever
/// opened an audit with no quick answer to "which audit, who's auditing,
/// where, and when" without scrolling past the parameter tree entirely.
/// Pure UI over fields AuditDetailModel already carries — no new API call.
class AuditHeaderCard extends StatelessWidget {
  final AuditDetailModel audit;

  const AuditHeaderCard({super.key, required this.audit});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final auditors = audit.auditorNames.join(', ');
    final locations = audit.locationLabels.map((l) => l.display).join(', ');
    final hasSchedule = audit.scheduledDate != null || audit.scheduledEndDate != null || audit.completedDate != null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(audit.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 8),
              StatusBadge(label: audit.status, color: AppColors.forAuditStatus(audit.status)),
            ],
          ),
          if (auditors.isNotEmpty) ...[
            const SizedBox(height: 8),
            _InfoRow(
              icon: Icons.badge_outlined,
              label: audit.auditorNames.length > 1 ? 'Auditors' : 'Auditor',
              value: auditors,
            ),
          ],
          if (locations.isNotEmpty) ...[
            const SizedBox(height: 6),
            _InfoRow(
              icon: Icons.place_outlined,
              label: audit.locationLabels.length > 1 ? 'Locations' : 'Location',
              value: locations,
            ),
          ],
          if (hasSchedule) ...[
            const SizedBox(height: 6),
            _InfoRow(icon: Icons.event_outlined, label: 'Schedule', value: _scheduleValue()),
          ],
        ],
      ),
    );
  }

  String _scheduleValue() {
    final parts = <String>[];
    if (audit.scheduledDate != null) parts.add('Start ${Formatters.date(audit.scheduledDate)}');
    if (audit.scheduledEndDate != null) parts.add('End ${Formatters.date(audit.scheduledEndDate)}');
    if (audit.completedDate != null) parts.add('Completed ${Formatters.date(audit.completedDate)}');
    return parts.join('  •  ');
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: scheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$label: ', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: scheme.outline)),
                TextSpan(text: value, style: TextStyle(fontSize: 12.5, color: scheme.onSurface)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
