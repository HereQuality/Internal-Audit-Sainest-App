import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/utils/final_report_all.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/report_sheet_spec.dart';
import 'package:internal_audit_app/utils/xlsx_report_writer.dart';

/// "Download All": the three tabs' workbooks in ONE file — a case-for-case port of the web
/// app's buildAllReport tests (client/src/utils/finalReportExcel.test.js), plus the written
/// .xlsx read back, so the phone's combined file says what the web's says.
void main() {
  Map<String, dynamic> emp(String name) => {'_id': name, 'employeeName': name};
  final generatedAt = DateTime(2026, 10, 5, 9, 0);
  const sameFilters = [('Location', 'All locations'), ('Audit Type', 'All audit types')];

  Map<String, ReportWorkbookSpec> make({bool withRows = false}) {
    final auditRows = withRows
        ? auditExportRows([
            {
              '_id': 'a1', 'title': 'Safety walk', 'status': 'Completed', 'displayStatus': 'Total Closed', 'timeliness': 'On-Time Completed',
              'auditorIds': [emp('Asha')], 'auditeeIds': [emp('Ravi')],
              'locationIds': [{'_id': 'l1', 'name': 'Plant 1'}],
              'scoreResult': {'achieved': 8, 'maxPossible': 10, 'percentage': 80},
            },
          ]).rows
        : <Map<String, Object?>>[];
    final ncRows = withRows
        ? ncExportRows([
            {'_id': 'n1', 'ncId': 'NC-1', 'title': 'Guard', 'severity': 'Major', 'status': 'Raised', 'bucket': 'overdue', 'placeLabel': 'Plant 1', 'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Ravi'), 'startDate': '2026-09-01'},
          ], now: DateTime(2026, 10, 5))
        : <Map<String, Object?>>[];
    final groups = withRows
        ? <Map>[
            {'key': 'k1', 'title': 'Guard', 'locationName': 'Plant 1', 'count': 2, 'openCount': 1, 'latestStatus': 'Raised', 'ncIds': ['n1', 'n2']},
          ]
        : <Map>[];
    final byId = withRows
        ? <String, Map>{
            'n1': {'_id': 'n1', 'ncId': 'NC-1', 'startDate': '2026-09-01', 'status': 'Raised', 'auditId': {'_id': 'a1', 'title': 'Safety walk'}, 'raisedByEmployeeId': emp('Asha'), 'auditeeEmployeeId': emp('Ravi')},
            'n2': {'_id': 'n2', 'ncId': 'NC-2', 'startDate': '2026-08-01', 'status': 'Closed', 'completionDate': '2026-08-09', 'auditId': {'_id': 'a0', 'title': 'Older walk'}, 'raisedByEmployeeId': emp('Bo'), 'auditeeEmployeeId': emp('Ravi')},
          }
        : <String, Map>{};
    return {
      'audits': buildAuditsReport(rows: auditRows, stats: {'totalAudits': 4}, filters: [...sameFilters, ('Status', 'All statuses')], generatedBy: 'Mann', generatedAt: generatedAt),
      'ncs': buildNcsReport(rows: ncRows, stats: {'total': 7}, filters: [...sameFilters, ('Flag', 'Major and Minor')], generatedBy: 'Mann', generatedAt: generatedAt),
      'repeats': buildRepeatsReport(groups: groups, ncsById: byId, minCount: 2, filters: [...sameFilters, ('Date range', 'Last 6 months')], generatedBy: 'Mann', generatedAt: generatedAt),
    };
  }

  ReportWorkbookSpec all(Map<String, ReportWorkbookSpec> parts, {String generatedBy = 'Mann'}) => buildAllReport(
    audits: parts['audits'],
    ncs: parts['ncs'],
    repeats: parts['repeats'],
    generatedBy: generatedBy,
    generatedAt: generatedAt,
  );

  ReportDataSheet data(ReportWorkbookSpec s, String name) => s.sheet(name)! as ReportDataSheet;

  test("has ONE Summary first, then every tab's own sheets; no two sheets share a name", () {
    final combined = all(make());
    final names = combined.sheets.map((s) => s.name).toList();
    expect(names.first, 'Summary');
    expect(names.where((n) => n == 'Summary'), hasLength(1));
    expect(names.toSet(), hasLength(names.length));
    for (final expected in [
      'Audits', 'NCs', 'Repeated Checkpoints', 'Repeat NC Details',
      'Audits By Location', 'Audits By Auditor', 'Audits By Auditee',
      'NCs By Location', 'NCs By Auditor', 'NCs By Auditee',
      'Repeats By Location', 'Repeats By Auditor', 'Repeats By Auditee',
    ]) {
      expect(names, contains(expected), reason: '$expected is in the file');
    }
    expect(names.every((n) => n.length <= 31), isTrue, reason: "Excel's sheet-name limit");
    // The order: the Audits sheets, then the NCs', then the Repeated NCs'.
    expect(names.indexOf('Audits'), lessThan(names.indexOf('NCs')));
    expect(names.indexOf('NCs'), lessThan(names.indexOf('Repeated Checkpoints')));
    expect(names, [
      'Summary',
      'Audits', 'Audits By Location', 'Audits By Auditor', 'Audits By Auditee',
      'NCs', 'NCs By Location', 'NCs By Auditor', 'NCs By Auditee',
      'Repeated Checkpoints', 'Repeat NC Details', 'Repeats By Location', 'Repeats By Auditor', 'Repeats By Auditee',
    ]);
  });

  test("the Summary carries every tab's tiles under its tab's name, and every tab's notes", () {
    final summary = all(make()).sheets.first as ReportSummarySheet;
    final titles = summary.tileGroups.map((g) => g.title).toList();
    expect(titles, contains('Audits — Audit overview'));
    expect(titles, contains('NCs — NC overview'));
    expect(titles, contains('Repeated NCs — Repeated NC overview'));
    // The "In this file" groups of each tab are there too, each under its own tab.
    expect(titles, containsAll(['Audits — In this file', 'NCs — In this file', 'NCs — Speed of action']));
    expect(summary.notes.any((n) => n.startsWith('Audits: ')), isTrue);
    expect(summary.notes.any((n) => n.startsWith('NCs: ')), isTrue);
    expect(summary.notes.any((n) => n.startsWith('Repeated NCs: ')), isTrue);
    // The tiles themselves are the tab's own, unchanged.
    final overview = summary.tileGroups.firstWhere((g) => g.title == 'NCs — NC overview');
    expect(overview.tiles.first.label, 'Total NC');
    expect(overview.tiles.first.value, 7);
  });

  test('says a filter every tab shares once, and leads the others by their tab', () {
    final filters = all(make()).filters;
    expect(filters.take(2).toList(), [('Location', 'All locations'), ('Audit Type', 'All audit types')]);
    expect(filters.any((l) => l.$1 == 'Audits · Status' && l.$2 == 'All statuses'), isTrue);
    expect(filters.any((l) => l.$1 == 'NCs · Flag'), isTrue);
    expect(filters.any((l) => l.$1 == 'Repeated NCs · Date range'), isTrue);
    expect(filters.where((l) => l.$1 == 'Location'), hasLength(1));
    expect(filters, hasLength(5));
  });

  test('the same value under the same label on only SOME tabs is not shared', () {
    final a = buildAuditsReport(rows: const [], stats: const {}, filters: const [('Search', '"guard"')], generatedAt: generatedAt);
    final n = buildNcsReport(rows: const [], stats: const {}, filters: const [], generatedAt: generatedAt);
    expect(buildAllReport(audits: a, ncs: n, generatedAt: generatedAt).filters, [('Audits · Search', '"guard"')]);
  });

  test('a search every tab carries identically is said once; a different one on each stays with its tab', () {
    ReportWorkbookSpec withSearch(String text, {bool repeats = false}) => repeats
        ? buildRepeatsReport(groups: const [], ncsById: const {}, filters: [('Search', '"$text"')], generatedAt: generatedAt)
        : buildNcsReport(rows: const [], stats: const {}, filters: [('Search', '"$text"')], generatedAt: generatedAt);
    final audits = buildAuditsReport(rows: const [], stats: const {}, filters: const [('Search', '"guard"')], generatedAt: generatedAt);
    final same = buildAllReport(audits: audits, ncs: withSearch('guard'), repeats: withSearch('guard', repeats: true), generatedAt: generatedAt);
    expect(same.filters, [('Search', '"guard"')]);
    final different = buildAllReport(audits: audits, ncs: withSearch('floor'), repeats: withSearch('guard', repeats: true), generatedAt: generatedAt);
    expect(different.filters, [
      ('Audits · Search', '"guard"'),
      ('NCs · Search', '"floor"'),
      ('Repeated NCs · Search', '"guard"'),
    ]);
  });

  test("every tab's own sheets come through unchanged", () {
    final parts = make(withRows: true);
    final combined = all(parts);
    final audits = data(parts['audits']!, 'Audits');
    final inAll = data(combined, 'Audits');
    expect(inAll.rows, audits.rows);
    expect(inAll.columns.map((c) => c.header), audits.columns.map((c) => c.header));
    expect(inAll.freezeColumns, audits.freezeColumns);
    expect(data(combined, 'NCs By Location').totals!.values, data(parts['ncs']!, 'By Location').totals!.values);
    expect(data(combined, 'NCs By Location').title, 'Final Report — NCs by location');
    expect(data(combined, 'Repeat NC Details').rows, data(parts['repeats']!, 'Repeat NC Details').rows);
    expect(data(combined, 'Audits By Location').columns.first.header, 'Location / Zone');
  });

  test('the file is "Final Report — All", named for the day it was made, by whoever made it', () {
    final combined = all(make(), generatedBy: 'Asha');
    expect(combined.title, 'Final Report — All');
    expect(combined.filename, 'Final-Report-All-2026-10-05');
    expect(combined.generatedBy, 'Asha');
    expect(combined.generatedAt, generatedAt);
    expect(finalReportAllFileName(DateTime(2026, 11, 3, 23, 59)), 'Final-Report-All-2026-11-03.xlsx');
    expect(finalReportAllFileBase(DateTime(2027, 1, 9)), 'Final-Report-All-2027-01-09');
  });

  test('works with fewer tabs (one part) and with none', () {
    final one = buildAllReport(ncs: make()['ncs'], generatedAt: generatedAt);
    expect(one.sheets.any((s) => s.name == 'NCs By Location'), isTrue);
    // Nothing is "shared" by one tab alone (as on the web): every line is led by its tab.
    expect(one.filters.first, ('NCs · Location', 'All locations'));
    expect(buildAllReport(generatedAt: generatedAt).sheets.map((s) => s.name), ['Summary']);
  });

  test('two sheets with the same name are refused, never silently renamed', () {
    final clash = ReportWorkbookSpec(
      filename: 'x',
      title: 'T',
      generatedAt: generatedAt,
      sheets: const [
        ReportSummarySheet(),
        ReportDataSheet(name: 'NCs', columns: [ReportColumn(header: 'A', key: 'a')], rows: []),
      ],
    );
    expect(
      () => buildAllReport(audits: clash, ncs: make()['ncs'], generatedAt: generatedAt),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('both called "NCs"'))),
    );
    final summaryClash = ReportWorkbookSpec(
      filename: 'x',
      title: 'T',
      generatedAt: generatedAt,
      sheets: const [ReportDataSheet(name: 'Summary', columns: [ReportColumn(header: 'A', key: 'a')], rows: [])],
    );
    expect(() => buildAllReport(audits: summaryClash, generatedAt: generatedAt), throwsA(isA<StateError>()));
  });

  group('the written .xlsx', () {
    final combined = all(make(withRows: true));
    final bytes = encodeReportWorkbook(combined);

    test('opens with the same sheets, in order', () {
      final book = xl.Excel.decodeBytes(bytes);
      expect(book.tables.keys.toList(), combined.sheets.map((s) => s.name).toList());
      expect(book.tables.keys.first, 'Summary');
    });

    test('has the combined Summary: one title, the shared filters once, the tab-led ones, the tiles of all three', () {
      final ws = xl.Excel.decodeBytes(bytes)['Summary'];
      final texts = [
        for (final row in ws.rows)
          for (final cell in row)
            if (cell?.value is xl.TextCellValue) (cell!.value as xl.TextCellValue).value.text!,
      ];
      expect(texts.first, 'Final Report — All');
      expect(texts, contains('FILTERS APPLIED'));
      expect(texts.where((t) => t == 'Location'), hasLength(1));
      expect(texts, containsAll(['Audits · Status', 'NCs · Flag', 'Repeated NCs · Date range']));
      expect(texts, containsAll(['AUDITS — AUDIT OVERVIEW', 'NCS — NC OVERVIEW', 'REPEATED NCS — REPEATED NC OVERVIEW']));
      expect(texts.any((t) => t.startsWith('Audits: ')), isTrue);
    });

    test('keeps every merged sheet\'s frozen header and auto-filter', () {
      final archive = ZipDecoder().decodeBytes(bytes);
      String xmlOf(String sheetName) {
        final workbook = utf8.decode(archive.files.firstWhere((f) => f.name == 'xl/workbook.xml').content as List<int>);
        final rels = utf8.decode(archive.files.firstWhere((f) => f.name == 'xl/_rels/workbook.xml.rels').content as List<int>);
        final tag = RegExp('<sheet\\b[^>]*name="$sheetName"[^>]*/>').firstMatch(workbook)!.group(0)!;
        final id = RegExp(r'r:id="([^"]*)"').firstMatch(tag)!.group(1)!;
        final rel = RegExp('<Relationship\\b[^>]*Id="$id"[^>]*/>').firstMatch(rels)!.group(0)!;
        final target = RegExp(r'Target="([^"]*)"').firstMatch(rel)!.group(1)!;
        return utf8.decode(archive.files.firstWhere((f) => f.name == 'xl/$target').content as List<int>);
      }

      // A frozen header (and as many frozen columns as the tab's own sheet has) on every data sheet...
      expect(xmlOf('Audits'), contains('<pane xSplit="3" ySplit="4"'));
      expect(xmlOf('NCs'), contains('<pane xSplit="3" ySplit="4"'));
      expect(xmlOf('Repeat NC Details'), contains('<pane xSplit="2" ySplit="4"'));
      for (final name in ['Audits By Location', 'NCs By Auditor', 'Repeats By Auditee']) {
        expect(xmlOf(name), contains('<pane ySplit="4"'), reason: name);
        expect(xmlOf(name), contains('state="frozen"'), reason: name);
      }
      // ...and its rows filterable.
      expect(xmlOf('Audits'), contains('<autoFilter ref="A4:S5"/>'));
      expect(xmlOf('NCs'), contains('<autoFilter ref="A4:Y5"/>'));
      expect(xmlOf('Repeat NC Details'), contains('<autoFilter ref="A4:M6"/>'));
      expect(xmlOf('Audits By Location'), contains('<autoFilter ref="A4:L5"/>'));
      // The Summary is neither.
      expect(xmlOf('Summary'), isNot(contains('<autoFilter')));
      expect(xmlOf('Summary'), isNot(contains('<pane')));
    });

    test('a data sheet\'s own band and filter line speak for the whole workbook', () {
      final ws = xl.Excel.decodeBytes(bytes)['NCs By Location'];
      String text(String ref) => (ws.cell(xl.CellIndex.indexByString(ref)).value as xl.TextCellValue).value.text!;
      expect(text('A1'), 'Final Report — NCs by location');
      expect(text('A2'), contains('Location: All locations'));
      expect(text('A2'), contains('NCs · Flag: Major and Minor'));
      expect(text('A2'), contains('Generated 05 Oct 2026, 09:00 by Mann'));
    });
  });
}
