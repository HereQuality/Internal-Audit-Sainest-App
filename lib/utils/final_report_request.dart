import '../models/nc_report_model.dart' show NcBucket;
import '../providers/audit_filter_scope.dart';
import '../providers/audits_provider.dart';
import '../providers/filter_options_provider.dart';
import '../providers/nc_provider.dart';
import 'final_report_download.dart';
import 'final_report_excel.dart';
import 'report_filter_lines.dart';
import 'report_sheet_spec.dart';

/// utils/final_report_request.dart
/// ─────────────────────────────────
/// Snapshots the Final Report screen's CURRENT filter selection into a
/// [FinalReportRequest]: the exact queries the tab's own list and tiles send (the
/// providers build them — see AuditsProvider.reportListQuery,
/// NcProvider.ncReportListQuery and NcProvider.repeatParams), and the plain-words
/// "Filters applied" lines for the Summary sheet, with ids turned into names from
/// the same option lists the filter sheet uses (the web does this at click time too:
/// hooks/useFilterDescriber.js).

/// The audit tiles' names, in the order the tile row shows them.
const _auditTileLabels = <String, String>{
  'inProgress': 'In Progress',
  'overdue': 'Overdue',
  'notStarted': 'Not Started',
  'onTime': 'On-Time Completed',
  'delayed': 'Delayed Completed',
  'skipped': 'Skipped',
  'notAttempted': 'Not Attempted',
  'other': 'Other',
};

/// Team / people / place / audit-type lines every tab with a person filter shares.
class _Names {
  _Names(FilterOptionsProvider options)
    : teams = {for (final t in options.teams) t.id: t.name},
      people = {for (final e in options.employees) e.id: e.name},
      locations = {for (final l in options.locations) l.id: l.display},
      departments = {for (final d in options.departments) d.id: d.display};

  final Map<String, String> teams;
  final Map<String, String> people;
  final Map<String, String> locations;
  final Map<String, String> departments;
}

/// The request for [tab]. [audits] and [ncs] are the providers the tab is showing
/// (they hold identical filter state — widgets/filter_sheet.dart keeps them in step —
/// but each tab's own provider is the one whose query it sends, so that is the one read).
FinalReportRequest buildFinalReportRequest({
  required FinalReportTab tab,
  required AuditsProvider audits,
  required NcProvider ncs,
  required FilterOptionsProvider options,
  String generatedBy = '',
}) {
  final names = _Names(options);

  List<ReportFilterLine> lines(
    AuditFilterScope scope, {
    bool withPeople = true,
    List<String>? flags,
    List<String>? statuses,
    List<String>? tiles,
    String? dateText,
    String? search,
    List<ReportFilterLine> extra = const [],
  }) {
    return describeReportFilters(
      teams: withPeople ? labelsForIds(scope.teamFilter, names.teams, 'team') : null,
      people: withPeople
          ? describePeople(
              employeeIds: scope.filterParams?['employeeIds'] as String?,
              names: names.people,
              selfId: scope.selfEmployeeId,
            )
          : null,
      locations: labelsForIds(scope.locationFilter, names.locations, 'location'),
      departments: labelsForIds(scope.departmentFilter, names.departments, 'department'),
      auditTypes: scope.auditTypeFilter,
      flags: flags,
      statuses: statuses,
      tiles: tiles,
      dateText: dateText ?? describeDateRange(scope.dateFrom, scope.dateTo),
      search: search,
      extra: extra,
    );
  }

  switch (tab) {
    case FinalReportTab.audits:
      return FinalReportRequest(
        tab: tab,
        listQuery: audits.reportListQuery(),
        statsQuery: audits.reportStatsQuery(),
        generatedBy: generatedBy,
        filters: lines(
          audits,
          statuses: [if (audits.reportsStatus != null) audits.reportsStatus!],
          tiles: [
            for (final e in _auditTileLabels.entries)
              if (audits.reportsTileKeys.contains(e.key)) e.value,
          ],
          search: audits.reportsSearch,
        ),
      );
    case FinalReportTab.ncs:
      return FinalReportRequest(
        tab: tab,
        listQuery: ncs.ncReportListQuery(),
        statsQuery: ncs.ncReportStatsQuery(),
        generatedBy: generatedBy,
        filters: lines(
          ncs,
          flags: ncs.flagFilter,
          tiles: [
            for (final b in NcBucket.all)
              if (ncs.ncReportTileKeys.contains(b)) NcBucket.label(b),
          ],
          search: ncs.ncReportSearch,
        ),
      );
    case FinalReportTab.repeats:
      // Org-wide on the server: who raised or received an NC never enters a repeat group, so
      // the people half of the filters (Team / Members) is not sent and not listed — and with
      // no date picked the tab looks back six months, which the file says.
      final from = NcProvider.repeatDefaultFrom();
      return FinalReportRequest(
        tab: tab,
        listQuery: ncs.repeatParams,
        generatedBy: generatedBy,
        minCount: ncs.repeatsMinCount,
        filters: lines(
          ncs,
          withPeople: false,
          flags: ncs.flagFilter,
          dateText: ncs.repeatsUseDefaultWindow
              ? 'Last 6 months (from ${formatPickedDay(from)}) — the default'
              : describeDateRange(ncs.dateFrom, ncs.dateTo),
          search: ncs.repeatsSearch,
          extra: [('Minimum repeats', '${ncs.repeatsMinCount}+ times at the same place')],
        ),
      );
  }
}

/// "Download All": the three tabs' requests at once, each under the filters ITS OWN tab uses
/// right now — the Audits' chip, search and lit tiles, the NCs' flag, search and lit tile, the
/// Repeated NCs' six-month window, Min. times and search — snapshotted together at the tap, so
/// the combined file says exactly what the three separate downloads would.
FinalReportAllRequest buildFinalReportAllRequest({
  required AuditsProvider audits,
  required NcProvider ncs,
  required FilterOptionsProvider options,
  String generatedBy = '',
}) {
  FinalReportRequest of(FinalReportTab tab) => buildFinalReportRequest(
    tab: tab,
    audits: audits,
    ncs: ncs,
    options: options,
    generatedBy: generatedBy,
  );
  return FinalReportAllRequest(
    audits: of(FinalReportTab.audits),
    ncs: of(FinalReportTab.ncs),
    repeats: of(FinalReportTab.repeats),
    generatedBy: generatedBy,
  );
}
