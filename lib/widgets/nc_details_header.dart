import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/formatters.dart';
import '../models/nc_model.dart';
import 'status_badge.dart';

/// widgets/nc_details_header.dart
/// ─────────────────────────────────
/// "What audit is this, where, and who's involved" — the block every NC
/// screen (Respond, Review) opens with, mirroring the web app's
/// Components/Common/NCDetailsPanel.jsx: status + flag, the audit it belongs
/// to and its dates, the parameter (this NC's own title), the place, who
/// raised it and who it's against, the raised/due dates, and the finding
/// itself. Before this, the phone screens showed only the bare title +
/// description — everything else (audit name, type, location, dates) was on
/// the record but never drawn.
class NcDetailsHeader extends StatelessWidget {
  final NcModel nc;

  const NcDetailsHeader({super.key, required this.nc});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final period = nc.auditScheduledDate == null
        ? null
        : nc.auditScheduledEndDate != null &&
                Formatters.date(nc.auditScheduledEndDate) != Formatters.date(nc.auditScheduledDate)
            ? '${Formatters.date(nc.auditScheduledDate)} – ${Formatters.date(nc.auditScheduledEndDate)}'
            : Formatters.date(nc.auditScheduledDate);
    final place = [nc.locationName, nc.departmentName].where((s) => (s ?? '').isNotEmpty).join(' · ');

    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
              StatusBadge(
                label: nc.severity,
                color: nc.severity == 'Major' ? AppColors.red : AppColors.amber,
              ),
              if (nc.auditType != null && nc.auditType!.isNotEmpty)
                StatusBadge(label: nc.auditType!, color: AppColors.readable(context, const Color(0xFF0891B2))),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              if (nc.auditTitle.isNotEmpty) _Item(label: 'Audit', value: nc.auditTitle),
              if (period != null) _Item(label: 'Audit date', value: period),
              _Item(label: 'Parameter', value: nc.title.isEmpty ? '—' : nc.title),
              if (place.isNotEmpty) _Item(label: 'Location', value: place),
              _Item(label: 'Raised by (auditor)', value: nc.raisedBy.name),
              _Item(label: 'Auditee', value: nc.auditee.name),
              _Item(label: 'Raised on', value: Formatters.date(nc.startDate)),
              _Item(label: 'Due date', value: Formatters.date(nc.targetDate)),
              if (nc.completionDate != null) _Item(label: 'Closed on', value: Formatters.date(nc.completionDate)),
            ],
          ),
          if (nc.description.isNotEmpty) ...[
            const SizedBox(height: 10),
            Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 10),
            Text(
              'FINDING / REMARK',
              style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: scheme.outline),
            ),
            const SizedBox(height: 2),
            Text(nc.description, style: const TextStyle(fontSize: 13.5)),
          ],
        ],
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final String label;
  final String value;

  const _Item({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 110, maxWidth: 220),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: scheme.outline),
          ),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
