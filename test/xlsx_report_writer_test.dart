import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/report_sheet_spec.dart';
import 'package:internal_audit_app/utils/xlsx_report_writer.dart';

/// The .xlsx the Final Report downloads become. The sheet descriptions are tested in
/// final_report_excel_test.dart; here a real file is written and read back (cells, widths,
/// merges) and its XML is checked for what the `excel` package cannot do by itself and the
/// writer patches in: the frozen header, the auto-filter, the tab colours, the print layout.
void main() {
  Map<String, dynamic> emp(String name) => {'_id': name, 'employeeName': name};
  final generatedAt = DateTime(2026, 10, 5, 9, 7);

  Map<String, dynamic> audit(String id, {Map<String, dynamic> over = const {}}) => {
    '_id': id,
    'title': 'Safety walk $id',
    'auditNumber': 'AUD-$id',
    'auditType': 'Safety',
    'status': 'Completed',
    'displayStatus': 'Total Closed',
    'timeliness': 'On-Time Completed',
    'scheduledDate': '2026-09-01T00:00:00.000',
    'scheduledEndDate': '2026-09-05T00:00:00.000',
    'completedDate': '2026-09-04T00:00:00.000',
    'auditorIds': [emp('Asha')],
    'auditeeIds': [emp('Ravi')],
    'locationIds': [
      {'_id': 'l1', 'name': 'Plant 1', 'code': 'P1'},
    ],
    'scoreResult': {'achieved': 40, 'maxPossible': 50, 'percentage': 80},
    'ncSummary': {'total': 3, 'closed': 1},
    ...over,
  };

  ReportWorkbookSpec auditsSpec({List<Map<String, dynamic>>? audits}) {
    final export = auditExportRows(audits ?? [
      audit('1'),
      audit('2', over: {
        'status': 'In Progress',
        'displayStatus': 'In Progress',
        'timeliness': null,
        'locationIds': [
          {'name': 'Plant 2'},
        ],
      }),
      audit('3', over: {
        'scoreResult': {'achieved': 0, 'maxPossible': 0, 'percentage': null},
      }),
    ]);
    return buildAuditsReport(
      rows: export.rows,
      bundles: export.bundles,
      stats: {'percentage': 80, 'totalAudits': 3, 'inProgress': 1, 'onTimeCompleted': 2},
      filters: const [('Location', 'Plant 1 (P1)'), ('Date range', 'All dates'), ('Search', '')],
      generatedBy: 'Asha Rao',
      generatedAt: generatedAt,
    );
  }

  /// name -> xml text of every part, and the sheet name -> its part's path.
  ({Map<String, String> parts, Map<String, String> sheetPath}) unpack(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final parts = <String, String>{
      for (final f in archive.files)
        if (f.isFile && (f.name.endsWith('.xml') || f.name.endsWith('.rels'))) f.name: utf8.decode(f.content as List<int>),
    };
    final targets = <String, String>{
      for (final m in RegExp(r'<Relationship\b[^>]*/?>').allMatches(parts['xl/_rels/workbook.xml.rels']!))
        RegExp('Id="([^"]*)"').firstMatch(m.group(0)!)!.group(1)!: RegExp('Target="([^"]*)"').firstMatch(m.group(0)!)!.group(1)!,
    };
    final paths = <String, String>{
      for (final m in RegExp(r'<sheet\b[^>]*/?>').allMatches(parts['xl/workbook.xml']!))
        RegExp(r'name="([^"]*)"').firstMatch(m.group(0)!)!.group(1)!: 'xl/${targets[RegExp(r'r:id="([^"]*)"').firstMatch(m.group(0)!)!.group(1)!]!}',
    };
    return (parts: parts, sheetPath: paths);
  }

  group('the file', () {
    final bytes = encodeReportWorkbook(auditsSpec());
    final unpacked = unpack(bytes);
    final book = xl.Excel.decodeBytes(bytes);

    test('is a real .xlsx whose sheets come in the order of the description', () {
      expect(bytes.sublist(0, 2), [0x50, 0x4B]); // "PK": a zip
      expect(book.tables.keys.toList(), ['Summary', 'Audits', 'By Location', 'By Auditor', 'By Auditee']);
      expect(unpacked.sheetPath.keys.toList(), ['Summary', 'Audits', 'By Location', 'By Auditor', 'By Auditee']);
    });

    test('a data sheet has its title band, filter line, a blank row, the header row and then the rows', () {
      final ws = book['Audits'];
      String text(String ref) => (ws.cell(xl.CellIndex.indexByString(ref)).value as xl.TextCellValue).value.text!;
      expect(text('A1'), 'Final Report — Audits');
      expect(text('A2'), contains('Location: Plant 1 (P1)'));
      expect(text('A2'), contains('Generated 05 Oct 2026, 09:07 by Asha Rao'));
      // Empty filter values are not printed.
      expect(text('A2'), isNot(contains('Search:')));
      expect(text('A4'), '#');
      expect(text('B4'), 'Audit No.');
      expect(text('S4'), 'NCs Open');
      expect(text('B5'), 'AUD-1');
      expect(text('E5'), 'Plant 1 (P1)');
      expect(text('E6'), 'Plant 2');
      expect(ws.maxRows, 7); // header on row 4, three audits
    });

    test('numbers stay numbers, percents are fractions, dates are real dates', () {
      final ws = book['Audits'];
      xl.CellValue? at(String ref) => ws.cell(xl.CellIndex.indexByString(ref)).value;
      expect((at('A5') as xl.IntCellValue).value, 1);
      // Score % (column O): 80 -> 0.8
      expect((at('O5') as xl.DoubleCellValue).value, closeTo(0.8, 1e-9));
      // Marks achieved (P): 40
      expect((at('P5') as xl.IntCellValue).value, 40);
      // Start (J) is a date cell on the day the person sees.
      final start = at('J5') as xl.DateCellValue;
      expect([start.year, start.month, start.day], [2026, 9, 1]);
      expect(unpacked.parts['xl/styles.xml'], contains('dd-mmm-yyyy'));
      expect(unpacked.parts['xl/styles.xml'], contains('formatCode="0%"'));
    });

    test('a score that is not calculated (unfinished, or all Not Applicable) is an EMPTY cell — never 0%', () {
      final ws = book['Audits'];
      // Row 6: in progress. Row 7: finished but every checkpoint Not Applicable.
      expect(ws.cell(xl.CellIndex.indexByString('O6')).value, isNull);
      expect(ws.cell(xl.CellIndex.indexByString('O7')).value, isNull);
      // Marks of an unfinished audit are empty too; a finished one with nothing assessed shows 0 / 0 like the web.
      expect(ws.cell(xl.CellIndex.indexByString('P6')).value, isNull);
    });

    test('colours the score by the 75 / 50 thresholds (text and tinted fill)', () {
      final styles = unpacked.parts['xl/styles.xml']!;
      // 80% -> #15803d: the bold green font and its light fill are in the styles.
      expect(styles, contains('FF15803D'));
      expect(styles, contains(tint('#15803d', 0.14)!));
      final low = encodeReportWorkbook(auditsSpec(audits: [
        audit('1', over: {
          'scoreResult': {'achieved': 10, 'maxPossible': 50, 'percentage': 20},
        }),
      ]));
      expect(unpack(low).parts['xl/styles.xml'], contains('FFB91C1C'));
      final mid = encodeReportWorkbook(auditsSpec(audits: [
        audit('1', over: {
          'scoreResult': {'achieved': 30, 'maxPossible': 50, 'percentage': 60},
        }),
      ]));
      expect(unpack(mid).parts['xl/styles.xml'], contains('FFB45309'));
    });

    test('freezes the header row and the first three columns, and filters the table', () {
      final xml = unpacked.parts[unpacked.sheetPath['Audits']!]!;
      expect(xml, contains('<pane xSplit="3" ySplit="4" topLeftCell="D5" activePane="bottomRight" state="frozen"/>'));
      expect(xml, contains('showGridLines="0"'));
      // The filter covers the header and every row, and sits after the rows and before the merges.
      expect(xml, contains('<autoFilter ref="A4:S7"/>'));
      expect(xml.indexOf('</sheetData>'), lessThan(xml.indexOf('<autoFilter')));
      expect(xml.indexOf('<autoFilter'), lessThan(xml.indexOf('<mergeCells')));
      expect(xml, contains('<pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>'));
      expect(xml, contains('<tabColor rgb="FF64748B"/>'));
    });

    test('the Summary sheet is not filtered or frozen, and has its own tab colour', () {
      final xml = unpacked.parts[unpacked.sheetPath['Summary']!]!;
      expect(xml, isNot(contains('<autoFilter')));
      expect(xml, isNot(contains('<pane')));
      expect(xml, contains('<tabColor rgb="FF312E81"/>'));
    });

    test('sets sensible column widths (never narrower than the header needs)', () {
      final xml = unpacked.parts[unpacked.sheetPath['Audits']!]!;
      double widthOf(int col) => double.parse(RegExp('<col min="$col" max="$col" width="([0-9.]+)"').firstMatch(xml)!.group(1)!);
      expect(widthOf(1), greaterThanOrEqualTo(6)); // "#"
      expect(widthOf(3), 34); // Audit
      expect(widthOf(15), greaterThanOrEqualTo(headerWidth('Score %')));
      expect(headerWidth('Marks Achieved'), greaterThan('Marks Achieved'.length ~/ 2));
    });

    test('merges the title band across the table and styles the header row', () {
      final ws = book['Audits'];
      expect(ws.spannedItems, contains('A1:S1'));
      expect(ws.spannedItems, contains('A2:S2'));
      final header = ws.cell(xl.CellIndex.indexByString('A4')).cellStyle!;
      expect(header.isBold, isTrue);
      expect(header.fontColor.colorHex, 'FFFFFFFF');
      expect(header.backgroundColor.colorHex, 'FF1F2937');
    });

    test('the Summary sheet carries the title, who made it and when, the filters applied and the tiles', () {
      final ws = book['Summary'];
      String text(String ref) => (ws.cell(xl.CellIndex.indexByString(ref)).value as xl.TextCellValue).value.text!;
      expect(text('A1'), 'Final Report — Audits');
      expect(text('A2'), 'Generated 05 Oct 2026, 09:07 by Asha Rao');
      expect(text('A4'), 'FILTERS APPLIED');
      expect(text('A5'), 'Location');
      expect(text('B5'), 'Plant 1 (P1)');
      expect(text('A6'), 'Date range');
      // A filter with no value reads "All".
      expect(text('A7'), 'Search');
      expect(text('B7'), 'All');
      // The first tiles: label above value.
      expect(text('A9'), 'AUDIT OVERVIEW');
      expect(text('A10'), 'TOTAL SCORE');
      expect((ws.cell(xl.CellIndex.indexByString('A11')).value as xl.DoubleCellValue).value, closeTo(0.8, 1e-9));
      expect(text('B10'), 'TOTAL AUDITS');
      expect((ws.cell(xl.CellIndex.indexByString('B11')).value as xl.IntCellValue).value, 3);
    });

    test('the totals row is bold and not part of the filter range', () {
      final bytes2 = encodeReportWorkbook(auditsSpec());
      final xml = unpack(bytes2).parts[unpack(bytes2).sheetPath['By Location']!]!;
      // Two places -> rows 5-6, totals row 7, filter A4:L6.
      expect(xml, contains('<autoFilter ref="A4:L6"/>'));
      final book2 = xl.Excel.decodeBytes(bytes2);
      final ws = book2['By Location'];
      expect((ws.cell(xl.CellIndex.indexByString('A7')).value as xl.TextCellValue).value.text, 'Total');
      expect(ws.cell(xl.CellIndex.indexByString('A7')).cellStyle!.isBold, isTrue);
    });
  });

  group('an empty result', () {
    final spec = buildNcsReport(rows: const [], stats: {'total': 0}, filters: const [('Flag', 'Major')], generatedAt: generatedAt);
    final bytes = encodeReportWorkbook(spec);
    final unpacked = unpack(bytes);

    test('still opens, with every sheet and a plain "no records" line instead of rows', () {
      final book = xl.Excel.decodeBytes(bytes);
      expect(book.tables.keys.toList(), ['Summary', 'NCs', 'By Location', 'By Auditor', 'By Auditee']);
      final ws = book['NCs'];
      expect((ws.cell(xl.CellIndex.indexByString('A5')).value as xl.TextCellValue).value.text, 'No records match these filters.');
      expect(ws.spannedItems, contains('A5:Y5'));
    });

    test('has no auto-filter (nothing to filter) but keeps the frozen header', () {
      final xml = unpacked.parts[unpacked.sheetPath['NCs']!]!;
      expect(xml, isNot(contains('<autoFilter')));
      expect(xml, contains('state="frozen"'));
    });
  });

  group('values', () {
    test('XML-illegal control characters are dropped and a huge text is cut to what a cell can hold', () {
      final spec = ReportWorkbookSpec(
        filename: 'x',
        title: 'T',
        generatedAt: generatedAt,
        sheets: [
          ReportDataSheet(
            name: 'Data',
            columns: const [ReportColumn(header: 'Text', key: 't')],
            rows: [
              {'t': 'bad\u0001char\u0008s'},
              {'t': 'a' * 40000},
            ],
          ),
        ],
      );
      final book = xl.Excel.decodeBytes(encodeReportWorkbook(spec));
      String at(String ref) => (book['Data'].cell(xl.CellIndex.indexByString(ref)).value as xl.TextCellValue).value.text!;
      expect(at('A5'), 'badchars');
      expect(at('A6').length, lessThan(32768));
      expect(at('A6').length, greaterThan(30000));
    });

    test('a percent column with decimals (ATS 71.4%) keeps them', () {
      final spec = buildNcsReport(rows: const [], stats: {'total': 1, 'atsScore': 71.4, 'otcScore': 66.7}, generatedAt: generatedAt);
      final bytes = encodeReportWorkbook(spec);
      expect(unpack(bytes).parts['xl/styles.xml'], contains('formatCode="0.0%"'));
      final ws = xl.Excel.decodeBytes(bytes)['Summary'];
      // NC overview: 6 tiles in one row (A..F), then the "Speed of action" group.
      var found = false;
      for (final row in ws.rows) {
        for (final cell in row) {
          final v = cell?.value;
          if (v is xl.DoubleCellValue && (v.value - 0.714).abs() < 1e-9) found = true;
        }
      }
      expect(found, isTrue);
    });

    test('a tile with no number (no score yet) reads "—"', () {
      final spec = buildAuditsReport(rows: const [], stats: {'percentage': null, 'totalAudits': 0}, generatedAt: generatedAt);
      final ws = xl.Excel.decodeBytes(encodeReportWorkbook(spec))['Summary'];
      final texts = [
        for (final row in ws.rows)
          for (final cell in row)
            if (cell?.value is xl.TextCellValue) (cell!.value as xl.TextCellValue).value.text,
      ];
      expect(texts, contains('—'));
    });

    test('a long filter value (a list of names) gets a taller row', () {
      final spec = ReportWorkbookSpec(
        filename: 'x',
        title: 'T',
        generatedAt: generatedAt,
        filters: [('Members', List.generate(60, (i) => 'Person number $i').join(', '))],
        sheets: const [ReportSummarySheet()],
      );
      final xml = unpack(encodeReportWorkbook(spec)).parts['xl/worksheets/sheet1.xml']!;
      expect(RegExp(r'<row r="5" ht="(\d+)').firstMatch(xml)!.group(1), isNotNull);
      expect(int.parse(RegExp(r'<row r="5" ht="(\d+)').firstMatch(xml)!.group(1)!), greaterThan(30));
    });
  });

  group('helpers', () {
    test('sheet names are cleaned, cut to 31 characters and kept unique', () {
      final used = <String>{};
      expect(safeSheetName('By Location', used), 'By Location');
      expect(safeSheetName('by location', used), 'by location (2)');
      expect(safeSheetName('A/B:C*D?E[F]G\\H', used), 'A B C D E F G H');
      expect(safeSheetName('x' * 40, used), 'x' * 31);
      expect(safeSheetName('', used), 'Sheet');
      expect(safeSheetName(null, used), 'Sheet (2)');
    });

    test('colours: hex to ARGB, and a tint toward white', () {
      expect(argb('#16a34a'), 'FF16A34A');
      expect(argb('16a34a'), 'FF16A34A');
      expect(argb('nope'), isNull);
      expect(tint('#000000', 0.5), 'FF808080');
      expect(tint('#ffffff', 0.14), 'FFFFFFFF');
      expect(tint(null), isNull);
    });

    test('the stamp is "dd Mon yyyy, HH:mm"', () {
      expect(stampText(DateTime(2026, 1, 9, 7, 5)), '09 Jan 2026, 07:05');
    });

    test('the filter line joins the filters and says so when there are none', () {
      expect(filterLine(const [('Location', 'Plant 1'), ('Flag', 'Major'), ('Search', '')]), 'Location: Plant 1  ·  Flag: Major');
      expect(filterLine(const []), 'No filters — everything you may see');
    });

    test('a header is never narrower than its text plus the filter button', () {
      expect(headerWidth('#'), greaterThanOrEqualTo(6));
      expect(headerWidth('Marks Achieved'), greaterThanOrEqualTo(12));
      expect(headerWidth(''), 0);
    });
  });

  group('off the UI thread', () {
    test('the background writer makes the same workbook', () async {
      final spec = auditsSpec();
      final inline = xl.Excel.decodeBytes(encodeReportWorkbook(spec));
      final background = xl.Excel.decodeBytes(await encodeReportWorkbookInBackground(spec));
      expect(background.tables.keys.toList(), inline.tables.keys.toList());
      for (final name in inline.tables.keys) {
        expect(background[name].maxRows, inline[name].maxRows, reason: name);
        expect(background[name].maxColumns, inline[name].maxColumns, reason: name);
      }
    });
  });

  group('size', () {
    test('three thousand NCs (25 columns) are written in a sensible time and open again', () async {
      final ncs = [
        for (var i = 0; i < 3000; i++)
          {
            '_id': 'n$i',
            'ncId': 'NC-$i',
            'title': 'Guard missing on press $i',
            'description': 'The guard of press $i was found removed during the walk. ' * 3,
            'severity': i % 4 == 0 ? 'Major' : 'Minor',
            'status': i % 3 == 0 ? 'Closed' : 'Raised',
            'bucket': ['inProgress', 'overdue', 'pendingApproval', 'delayed', 'onTime'][i % 5],
            'placeLabel': 'Plant ${i % 12}',
            'auditId': {'_id': 'a${i % 80}', 'title': 'Audit ${i % 80}', 'auditType': 'Safety'},
            'raisedByEmployeeId': emp('Auditor ${i % 15}'),
            'auditeeEmployeeId': emp('Auditee ${i % 40}'),
            'startDate': '2026-08-${(i % 28 + 1).toString().padLeft(2, '0')}T00:00:00',
            'targetDate': '2026-09-${(i % 28 + 1).toString().padLeft(2, '0')}T00:00:00',
            'completionDate': i % 3 == 0 ? '2026-09-02T00:00:00' : null,
            'repeatCount': i % 3,
            'rootCause': 'Worn interlock',
            'correctiveAction': 'Replace the interlock',
          },
      ];
      final spec = buildNcsReport(rows: ncExportRows(ncs, now: DateTime(2026, 10, 5)), stats: {'total': 3000}, generatedAt: generatedAt);
      final watch = Stopwatch()..start();
      final Uint8List bytes = await encodeReportWorkbookInBackground(spec);
      watch.stop();
      // ignore: avoid_print
      print('3000 NCs -> ${(bytes.length / 1024).round()} KB in ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
      final book = xl.Excel.decodeBytes(bytes);
      expect(book['NCs'].maxRows, 3004);
      final xml = unpack(bytes).parts[unpack(bytes).sheetPath['NCs']!]!;
      expect(xml, contains('<autoFilter ref="A4:Y3004"/>'));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
