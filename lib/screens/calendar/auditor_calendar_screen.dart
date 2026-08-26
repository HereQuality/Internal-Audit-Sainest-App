import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_date_range.dart';
import '../../providers/audits_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/month_calendar.dart';
import '../audits/audit_detail_screen.dart';

/// Auditor's calendar — one dot per day with an audit scheduled
/// (AuditModel#scheduledDate through scheduledEndDate), tap a day to see
/// which audits, tap an audit to open its scoring workspace. Reuses
/// AuditsProvider.audits — the same list My Audits already fetches, just
/// visualized by date instead of grouped-by-day list rows.
class AuditorCalendarScreen extends StatefulWidget {
  const AuditorCalendarScreen({super.key});

  @override
  State<AuditorCalendarScreen> createState() => _AuditorCalendarScreenState();
}

class _AuditorCalendarScreenState extends State<AuditorCalendarScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuditsProvider>().fetchMyAudits();
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AuditsProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Calendar')),
      body: provider.isLoading && provider.audits.isEmpty
          ? const AppLoading()
          : MonthCalendar(
              // A multi-day audit (scheduledEndDate set) used to only show
              // a dot on its scheduledDate — every other day it's actually
              // open for scoring looked empty on this calendar even though
              // My Audits' own date grouping treats the whole range as
              // live. Expanded here (not inside MonthCalendar, which stays
              // a plain single-date-per-event grid shared with the
              // Auditee/NC calendar) into one CalendarEvent per day in
              // [scheduledDate, scheduledEndDate].
              events: provider.audits
                  .where((a) => a.scheduledDate != null)
                  .expand((a) => daysInAuditRange(a).map(
                        (day) => CalendarEvent(
                          date: day,
                          title: a.title,
                          subtitle: a.status,
                          color: AppColors.forAuditStatus(a.status),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AuditDetailScreen(auditId: a.id),
                            ),
                          ),
                        ),
                      ))
                  .toList(),
              emptyDayBuilder: (context, _) => Center(
                child: Text(
                  'No audits scheduled this day.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ),
            ),
    );
  }
}
