import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/models/employee_option.dart';
import 'package:internal_audit_app/models/location_option.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/final_report_request.dart';

/// "Exactly what the filters match": the Excel download sends the very queries the
/// Final Report's own lists send (the providers build them), and its Summary names
/// the filters in force.
void main() {
  late AuditsProvider audits;
  late NcProvider ncs;
  late FilterOptionsProvider options;

  setUp(() {
    audits = AuditsProvider()..setSelfEmployeeId('me');
    ncs = NcProvider()..setSelfEmployeeId('me');
    options = FilterOptionsProvider()
      ..employees = [
        const EmployeeOption(id: 'me', name: 'Asha Rao'),
        const EmployeeOption(id: 'e2', name: 'Ravi Shah', teams: [TeamRef(id: 't1', name: 'QA')]),
        const EmployeeOption(id: 'e3', name: 'Mia Das', teams: [TeamRef(id: 't1', name: 'QA')]),
      ]
      ..locations = [const LocationOption(id: 'l1', name: 'Plant 1', code: 'P1', locationType: 'Zone')];
  });

  Map<String, String> lines(List<(String, String)> filters) => {for (final f in filters) f.$1: f.$2};

  group('Audits', () {
    test('sends the list\'s own query and the tiles\' own query — the filters, the chip, the search and the lit tiles', () {
      audits
        ..setFilterState(isTeam: true, employees: ['e2'], locations: ['l1'], auditTypes: ['Safety'], dateRange: (DateTime(2026, 10, 1), null))
        ..reportsStatus = 'Overdue'
        ..reportsSearch = '  press '
        ..reportsTileKeys = {'onTime'};
      final r = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options, generatedBy: 'Asha Rao');

      expect(r.listQuery, audits.reportListQuery());
      expect(r.listQuery['employeeIds'], 'e2');
      expect(r.listQuery['locationIds'], 'l1');
      expect(r.listQuery['auditType'], 'Safety');
      expect(r.listQuery['fromDate'], '2026-10-01');
      expect(r.listQuery['search'], 'press');
      // The chip and the tile are one status pick, OR-ed by the server.
      expect(r.listQuery['status'], 'Overdue,On-Time Completed');
      // The tiles describe the whole set: the chip and the search, never the lit tile.
      expect(r.statsQuery, audits.reportStatsQuery());
      expect(r.statsQuery!['status'], 'Overdue');
      expect(r.statsQuery!.containsKey('ids'), isFalse);
      expect(r.generatedBy, 'Asha Rao');
      expect(r.tab, FinalReportTab.audits);
    });

    test('names the filters in force in the Summary', () {
      audits
        ..setFilterState(isTeam: true, employees: ['e2'], locations: ['l1'], auditTypes: ['Safety'], dateRange: (DateTime(2026, 10, 1), DateTime(2026, 10, 31)))
        ..reportsStatus = 'Overdue'
        ..reportsSearch = 'press'
        ..reportsTileKeys = {'onTime', 'inProgress'};
      final l = lines(buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Team'], 'All teams');
      expect(l['Members'], 'Ravi Shah');
      expect(l['Location'], 'Plant 1 (P1)');
      expect(l['Audit Type'], 'Safety');
      expect(l['Status'], 'Overdue');
      // In the tile row's order, not the order they were tapped.
      expect(l['Stat tile'], 'In Progress, On-Time Completed');
      expect(l['Date range'], '01 Oct 2026 to 31 Oct 2026');
      expect(l['Search'], '"press"');
    });

    test('the default Me scope says "Only me" with the name; All Members says so; no chip says All statuses', () {
      var l = lines(buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Members'], 'Only me (Asha Rao)');
      expect(l['Status'], 'All statuses');
      expect(l['Stat tile'], 'None (everything)');
      expect(l['Date range'], 'All dates');
      expect(l.containsKey('Search'), isFalse);

      audits.setFilterState(isTeam: true);
      l = lines(buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Members'], 'All members');
    });

    test('a Team pick is listed by name, with the people it resolved to', () {
      audits.setFilterState(teams: ['t1'], teamMembers: ['e2', 'e3']);
      final r = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options);
      final l = lines(r.filters);
      expect(l['Team'], 'QA');
      expect(l['Members'], 'Ravi Shah, Mia Das');
      expect(r.listQuery['employeeIds'], 'e2,e3');
    });

    test('a Team with nobody in it matches nobody, and says so', () {
      audits.setFilterState(teams: ['t1'], teamMembers: const []);
      final r = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options);
      expect(r.listQuery['employeeIds'], '__none__');
      expect(lines(r.filters)['Members'], 'No one');
    });

    test('an option list that did not load is counted, not guessed', () {
      options.locations = [];
      audits.setFilterState(isTeam: true, locations: ['l1', 'l9']);
      final l = lines(buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Location'], '2 locations selected');
    });

    test('departments only is not "All locations"', () {
      audits.setFilterState(isTeam: true, departments: ['d1']);
      final l = lines(buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Location'], 'None — departments only');
      expect(l['Department'], '1 department selected');
    });

    test('the request is a snapshot: later filter changes do not reach it', () {
      audits.setFilterState(isTeam: true, locations: ['l1']);
      final r = buildFinalReportRequest(tab: FinalReportTab.audits, audits: audits, ncs: ncs, options: options);
      audits.setFilterState(locations: ['l9']);
      audits.reportsStatus = 'Overdue';
      expect(r.listQuery['locationIds'], 'l1');
      expect(r.listQuery.containsKey('status'), isFalse);
    });
  });

  group('NCs', () {
    test('sends the list\'s own query, a lit tile by NAME in the tile order, and the tiles without it', () {
      ncs
        ..setFilterState(isTeam: true, locations: ['l1'], auditTypes: ['Safety'], flags: ['Major'])
        ..ncReportSearch = 'guard'
        ..ncReportTileKeys = {'overdue', 'inProgress'};
      final r = buildFinalReportRequest(tab: FinalReportTab.ncs, audits: audits, ncs: ncs, options: options);

      expect(r.listQuery, ncs.ncReportListQuery());
      expect(r.listQuery['bucket'], 'inProgress,overdue');
      expect(r.listQuery['severity'], 'Major');
      expect(r.listQuery['search'], 'guard');
      expect(r.listQuery['locationIds'], 'l1');
      expect(r.listQuery.containsKey('groupBy'), isFalse);
      expect(r.statsQuery, ncs.ncReportStatsQuery());
      expect(r.statsQuery!.containsKey('bucket'), isFalse);
      expect(r.statsQuery!['omitIds'], '1');
      expect(r.statsQuery!['severity'], 'Major');
      expect(r.statsQuery!['search'], 'guard');
    });

    test('no tile lit: no bucket param, everything the filters match', () {
      expect(ncs.ncReportListQuery().containsKey('bucket'), isFalse);
    });

    test('names the flag and the lit tiles in the Summary', () {
      ncs
        ..setFilterState(isTeam: true, flags: ['Major'])
        ..ncReportTileKeys = {'pendingApproval', 'onTime'};
      final l = lines(buildFinalReportRequest(tab: FinalReportTab.ncs, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Flag'], 'Major');
      expect(l['Stat tile'], 'Pending Approval, On Time Completion');
      expect(l['Members'], 'All members');
      expect(l.containsKey('Status'), isFalse);
    });

    test('both Excel queries read the Me default as the person themselves', () {
      final r = buildFinalReportRequest(tab: FinalReportTab.ncs, audits: audits, ncs: ncs, options: options);
      expect(r.listQuery['employeeIds'], 'me');
    });
  });

  group('Repeated NCs', () {
    test('sends the repeats list\'s own query — org-wide, so no people — with the Min. times pick', () {
      ncs
        ..setFilterState(locations: ['l1'], auditTypes: ['Safety'], flags: ['Major'], employees: ['e2'], dateRange: (DateTime(2026, 5, 3), null))
        ..repeatsMinCount = 3;
      final r = buildFinalReportRequest(tab: FinalReportTab.repeats, audits: audits, ncs: ncs, options: options);
      expect(r.listQuery, ncs.repeatParams);
      expect(r.listQuery['minCount'], 3);
      expect(r.listQuery['locationIds'], 'l1');
      expect(r.listQuery['severity'], 'Major');
      expect(r.listQuery['fromDate'], '2026-05-03');
      expect(r.listQuery.containsKey('employeeIds'), isFalse);
      expect(r.statsQuery, isNull);
      expect(r.minCount, 3);
    });

    test('lists no people and says the window and the minimum', () {
      ncs.repeatsMinCount = 4;
      final r = buildFinalReportRequest(tab: FinalReportTab.repeats, audits: audits, ncs: ncs, options: options);
      final l = lines(r.filters);
      expect(l.containsKey('Team'), isFalse);
      expect(l.containsKey('Members'), isFalse);
      expect(l['Date range'], startsWith('Last 6 months (from '));
      expect(l['Date range'], endsWith(') — the default'));
      expect(l['Minimum repeats'], '4+ times at the same place');
      // With no date picked the list itself looks back six months.
      expect(r.listQuery['fromDate'], isNotNull);
    });

    test('a picked date range replaces the default window', () {
      ncs.setFilterState(dateRange: (DateTime(2026, 1, 1), DateTime(2026, 6, 30)));
      final l = lines(buildFinalReportRequest(tab: FinalReportTab.repeats, audits: audits, ncs: ncs, options: options).filters);
      expect(l['Date range'], '01 Jan 2026 to 30 Jun 2026');
    });
  });
}
