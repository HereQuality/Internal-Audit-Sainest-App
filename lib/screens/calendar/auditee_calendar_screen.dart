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

/// Auditee's calendar — two things layered on the same grid:
///   - one dot per day an NC is due (NcModel#targetDate), tap a day to see
///     which, tap one to respond (still "Raised") or check its review
///     status. Reuses NcProvider.raisedAgainstMe — the same list the NCs
///     tab's "Against me" side already fetches.
///   - a fixed-blue dot per day someone (not necessarily this employee) is
///     scheduled to audit one of THIS employee's own locations
///     (AuditsProvider.auditsAtMyLocation) — so a location's rank-and-file
///     staff can see "an auditor is coming" ahead of time even when they're
///     not personally the assigned auditor/auditee on that audit. Always
///     AppColors.blue regardless of the audit's own status, deliberately
///     distinct from AppColors.forAuditStatus (used on the Auditor
///     Calendar) — this is a "heads up, someone's visiting" marker, not a
///     status readout.
class AuditeeCalendarScreen extends StatefulWidget {
  const AuditeeCalendarScreen({super.key});

  @override
  State<AuditeeCalendarScreen> createState() => _AuditeeCalendarScreenState();
}

class _AuditeeCalendarScreenState extends State<AuditeeCalendarScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NcProvider>().fetchAgainstMe();
      context.read<AuditsProvider>().fetchAuditsAtMyLocation();
    });
  }

  @override
  Widget build(BuildContext context) {
    final ncProvider = context.watch<NcProvider>();
    final auditsProvider = context.watch<AuditsProvider>();
    final isLoading = ncProvider.isLoadingMine &&
        ncProvider.raisedAgainstMe.isEmpty &&
        auditsProvider.isLoadingAtMyLocation &&
        auditsProvider.auditsAtMyLocation.isEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: isLoading
          ? const AppLoading()
          : MonthCalendar(
              events: [
                ...ncProvider.raisedAgainstMe
                    .where((nc) => nc.targetDate != null)
                    .map(
                      (nc) => CalendarEvent(
                        date: nc.targetDate!,
                        title: nc.title,
                        subtitle: nc.status,
                        color: AppColors.forNcStatus(nc.status),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => nc.status == 'Raised'
                                ? NcResponseScreen(nc: nc)
                                : NcReviewScreen(nc: nc),
                          ),
                        ),
                      ),
                    ),
                ...auditsProvider.auditsAtMyLocation
                    .where((a) => a.scheduledDate != null)
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
