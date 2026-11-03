import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/utils/report_filter_lines.dart';

/// The "Filters applied" lines on the Excel Summary — a port of the web app's
/// client/src/utils/reportFilters.test.js.
void main() {
  group('dates', () {
    test('writes a day as "05 Oct 2026"', () {
      expect(formatPickedDay(DateTime(2026, 10, 5)), '05 Oct 2026');
      expect(formatPickedDay(DateTime(2026, 1, 31)), '31 Jan 2026');
    });

    test('describes open and closed ranges', () {
      expect(describeDateRange(DateTime(2026, 10, 1), DateTime(2026, 10, 31)), '01 Oct 2026 to 31 Oct 2026');
      expect(describeDateRange(DateTime(2026, 10, 1), DateTime(2026, 10, 1)), '01 Oct 2026');
      expect(describeDateRange(DateTime(2026, 10, 1), null), 'From 01 Oct 2026');
      expect(describeDateRange(null, DateTime(2026, 10, 31)), 'Up to 31 Oct 2026');
      expect(describeDateRange(null, null), 'All dates');
      expect(describeDateRange(null, null, allText: 'Last 6 months'), 'Last 6 months');
    });
  });

  group('lists', () {
    test('shortens a long list of names', () {
      expect(namesText(['A', 'B']), 'A, B');
      expect(namesText(['A', 'B', 'C', 'D'], max: 2), 'A, B and 2 more');
    });

    test('follows the [] = all / none-selected = nothing convention', () {
      expect(pickedText([], 'All teams'), 'All teams');
      expect(pickedText(null, 'All teams'), 'All teams');
      expect(pickedText([noneSelected], 'All teams'), 'None selected');
      expect(pickedText(['QA', 'Stores'], 'All teams'), 'QA, Stores');
    });
  });

  group('labelsForIds', () {
    const lookup = {'1': 'Plant 1', '2': 'Plant 2'};

    test('names every picked id', () {
      expect(labelsForIds(['1', '2'], lookup, 'location'), ['Plant 1', 'Plant 2']);
      expect(labelsForIds([], lookup, 'location'), isEmpty);
      expect(labelsForIds([noneSelected], lookup, 'location'), [noneSelected]);
    });

    test('counts the pick instead of printing a half list when a name is unknown', () {
      expect(labelsForIds(['1', '9'], lookup, 'location'), ['2 locations selected']);
      expect(labelsForIds(['9'], lookup, 'team'), ['1 team selected']);
      expect(labelsForIds(['1'], const {}, 'location'), ['1 location selected']);
    });
  });

  group('describeReportFilters', () {
    test('does not call a departments-only pick "All locations"', () {
      final lines = describeReportFilters(locations: [], departments: ['QA']);
      expect(lines.firstWhere((l) => l.$1 == 'Location').$2, 'None — departments only');
    });

    test('lists only what the tab has, in the filter bar\'s order, with "All" wording for untouched filters', () {
      final lines = describeReportFilters(
        teams: [],
        people: 'All members',
        locations: ['Plant 1 (P1)'],
        auditTypes: [],
        flags: ['Major'],
        dateText: describeDateRange(DateTime(2026, 10, 1), null),
        search: 'guard',
      );
      expect(lines, [
        ('Team', 'All teams'),
        ('Members', 'All members'),
        ('Location', 'Plant 1 (P1)'),
        ('Audit Type', 'All audit types'),
        ('Flag', 'Major'),
        ('Date range', 'From 01 Oct 2026'),
        ('Search', '"guard"'),
      ]);
    });

    test('leaves out the people lines on a tab without them (Repeated NCs) and shows departments only when picked', () {
      final lines = describeReportFilters(
        locations: [],
        departments: ['QA'],
        auditTypes: [],
        dateText: 'Last 6 months (default)',
        extra: [('Minimum repeats', '2+ times')],
      );
      expect(lines.map((l) => l.$1), ['Location', 'Department', 'Audit Type', 'Date range', 'Minimum repeats']);
      expect(lines.firstWhere((l) => l.$1 == 'Date range').$2, 'Last 6 months (default)');
    });

    test('names the status pick and lit stat tiles, and says none when no tile is lit', () {
      expect(describeReportFilters(statuses: ['Overdue']), [('Status', 'Overdue')]);
      expect(describeReportFilters(statuses: []), [('Status', 'All statuses')]);
      expect(describeReportFilters(tiles: ['Overdue', 'In Progress']), [('Stat tile', 'Overdue, In Progress')]);
      expect(describeReportFilters(tiles: []), [('Stat tile', 'None (everything)')]);
    });

    test('a blank search is not a line', () {
      expect(describeReportFilters(search: '   '), isEmpty);
    });
  });

  group('describePeople', () {
    const names = {'1': 'Asha', '2': 'Ravi', '3': 'Mia'};

    test('says All members when no people were sent (the server then reads the whole reporting line and places)', () {
      expect(describePeople(employeeIds: null, names: names), 'All members');
    });

    test('says "Only me" with the name when the scope is just the person', () {
      expect(describePeople(employeeIds: '1', names: names, selfId: '1'), 'Only me (Asha)');
      expect(describePeople(employeeIds: '1', names: const {}, selfId: '1'), 'Only me');
    });

    test('lists the picked people, or counts them when a name is not known', () {
      expect(describePeople(employeeIds: '2,3', names: names, selfId: '1'), 'Ravi, Mia');
      expect(describePeople(employeeIds: '2,9', names: names, selfId: '1'), '2 people');
      expect(describePeople(employeeIds: '9', names: names, selfId: '1'), '1 person');
    });

    test('says No one for a Team with nobody in it', () {
      expect(describePeople(employeeIds: noneSelected, names: names), 'No one');
    });
  });
}
