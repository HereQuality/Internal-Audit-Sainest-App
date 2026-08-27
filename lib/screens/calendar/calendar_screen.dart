import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_date_range.dart';
import '../../providers/audits_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/month_calendar.dart';
import '../audits/audit_detail_screen.dart';
import '../nc/nc_response_screen.dart';
import '../nc/nc_review_screen.dart';

/// The single calendar both Auditor and Auditee mode push from
/// app_shell.dart's app-bar calendar icon — mirrors the web app's own
/// Calendar.jsx, which fetches and shows the exact same four categories
/// for EVERY role rather than splitting them across role-specific views:
/// this used to be two separate screens (auditor_calendar_screen.dart /
/// auditee_calendar_screen.dart) each showing a different partial subset
/// (auditor: only its own audits, all one status color; auditee: only NCs
/// raised against it + others' audits at its own location, never its own
/// audits) — which is exactly why the two stopped matching each other and
/// drifted from the web page they were both meant to mirror. One shared
/// implementation, fetching all three sources unconditionally regardless
/// of AppMode, is what keeps that from happening again.
///
///   - Non-Conformance (red) — NcProvider.raisedAgainstMe, one dot per
///     NcModel#targetDate, tap to respond (still "Raised") or review.
///   - Audit (amber) / Completed (green) — AuditsProvider.audits (this
///     employee's own, as auditor), split by AuditModel#status, expanded
///     across every day in AuditModel#scheduledDate..scheduledEndDate via
///     daysInAuditRange.
///   - Audit at Your Location (blue) — AuditsProvider.auditsAtMyLocation,
///     someone ELSE scheduled to audit one of this employee's own
///     locations. Deduped against `audits` above (same id showing as both
///     "mine" and "at my location" — this employee audits their own
///     location plenty) so nothing plots twice, once amber/green and once
///     blue — mirrors Calendar.jsx's own myAuditIds/isOthers filter.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NcProvider>().fetchAgainstMe();
      context.read<AuditsProvider>().fetchMyAudits();
      context.read<AuditsProvider>().fetchAuditsAtMyLocation();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ncProvider = context.watch<NcProvider>();
    final auditsProvider = context.watch<AuditsProvider>();
    final isLoading = ncProvider.isLoadingMine &&
        ncProvider.raisedAgainstMe.isEmpty &&
        auditsProvider.isLoading &&
        auditsProvider.audits.isEmpty &&
        auditsProvider.isLoadingAtMyLocation &&
        auditsProvider.auditsAtMyLocation.isEmpty;

    final myAuditIds = auditsProvider.audits.map((a) => a.id).toSet();

    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: isLoading
          ? const AppLoading()
          : MonthCalendar(
              legend: const _CalendarLegend(),
              events: [
                ...ncProvider.raisedAgainstMe
                    .where((nc) => nc.targetDate != null)
                    .map(
                      (nc) => CalendarEvent(
                        date: nc.targetDate!,
                        title: nc.title,
                        subtitle: nc.status,
                        color: AppColors.red,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => nc.status == 'Raised'
                                ? NcResponseScreen(nc: nc)
                                : NcReviewScreen(nc: nc),
                          ),
                        ),
                      ),
                    ),
                ...auditsProvider.audits
                    .where((a) => a.scheduledDate != null)
                    .expand((a) => daysInAuditRange(a).map(
                          (day) => CalendarEvent(
                            date: day,
                            title: a.title,
                            subtitle: a.status,
                            color: a.status == 'Completed' ? AppColors.green : AppColors.amber,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AuditDetailScreen(auditId: a.id),
                              ),
                            ),
                          ),
                        )),
                ...auditsProvider.auditsAtMyLocation
                    .where((a) => a.scheduledDate != null && !myAuditIds.contains(a.id))
                    .expand((a) => daysInAuditRange(a).map(
                          (day) => CalendarEvent(
                            date: day,
                            title: a.title,
                            subtitle: a.auditorNames.isNotEmpty
                                ? 'Audit visit — ${a.auditorNames.join(', ')}'
                                : 'Audit visit at your location',
                            color: AppColors.blue,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => AuditDetailScreen(auditId: a.id),
                              ),
                            ),
                          ),
                        )),
              ],
              emptyDayBuilder: (context, _) => Center(
                child: Text(
                  'Nothing due this day.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
    );
  }
}

class _CalendarLegendEntry {
  final String label;
  final Color color;
  const _CalendarLegendEntry(this.label, this.color);
}

const _legendEntries = [
  _CalendarLegendEntry('Non-Conformance', AppColors.red),
  _CalendarLegendEntry('Audit', AppColors.amber),
  _CalendarLegendEntry('Completed', AppColors.green),
  _CalendarLegendEntry('Audit at Your Location', AppColors.blue),
];

/// Same dot+label row as the web calendar's own legend (Calendar.jsx) —
/// wraps onto a second line on a narrow phone rather than the single
/// `d-flex flex-wrap` row web can afford at full width.
class _CalendarLegend extends StatelessWidget {
  const _CalendarLegend();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          for (final e in _legendEntries)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(shape: BoxShape.circle, color: e.color),
                ),
                Text(
                  e.label,
                  style: TextStyle(fontSize: 11.5, color: scheme.outline, fontWeight: FontWeight.w600),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
