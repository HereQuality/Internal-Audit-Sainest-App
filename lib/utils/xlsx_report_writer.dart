import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart'
    show
        Border,
        BorderStyle,
        CellIndex,
        CellStyle,
        CellValue,
        DateCellValue,
        DoubleCellValue,
        Excel,
        ExcelColor,
        FontFamily,
        HorizontalAlign,
        IntCellValue,
        NumFormat,
        Sheet,
        TextCellValue,
        TextWrapping,
        VerticalAlign,
        getFontFamily;

import 'report_sheet_spec.dart';

/// utils/xlsx_report_writer.dart
/// ───────────────────────────────
/// Writes a [ReportWorkbookSpec] as an .xlsx — the Dart twin of the web app's
/// client/src/utils/excelReport.js, so the phone's file looks like the web's:
///
///  * a SUMMARY sheet: a title band, when it was made and by whom, the FILTERS
///    APPLIED (a file opened next month still says which people / places / dates
///    it covers) and the stat tiles the tab shows, tinted in the tile's own colour;
///  * DATA sheets: a title band, a one-line filter summary, a frozen header over a
///    filterable table with real numbers / percentages / dates (sortable, not
///    text), zebra rows, status / flag / score cells coloured like the app's
///    badges, and an optional bold totals row.
///
/// The cells, styles, merges and widths go through the `excel` package. That
/// package cannot freeze panes, switch an auto-filter on, colour a sheet tab or
/// set the print layout, so [_patchPackage] adds those to the finished file's
/// sheet XML — a small, tested edit of the zip (see its own comment) rather than
/// a hand-written workbook.
///
/// Pure Dart (no Flutter), so [encodeReportWorkbook] runs the same in a unit test
/// and in the background isolate [encodeReportWorkbookInBackground] uses to keep a
/// few thousand rows off the UI thread.

// ── Theme (the web's XLSX_THEME) ────────────────────────────────────────────

const _band = 'FF312E81';
const _bandText = 'FFFFFFFF';
const _head = 'FF1F2937';
const _headText = 'FFFFFFFF';
const _borderColor = 'FFE2E8F0';
const _zebra = 'FFF8FAFC';
const _muted = 'FF64748B';
const _ink = 'FF0F172A';
const _labelFill = 'FFF1F5F9';

const _summaryColumns = 6;
const _summaryColumnWidth = 24.0;
// Row of the data sheets' header (1-based): 1 title, 2 filter line, 3 blank, 4 header.
const _dataHeaderRow = 4;

/// Excel allows 32,767 characters in a cell.
const _maxCellText = 32000;

/// "#16a34a" / "16a34a" -> "FF16A34A" (what the writer wants); null for anything else.
String? argb(String? hex) {
  final h = (hex ?? '').replaceAll('#', '');
  final six = h.length >= 6 ? h.substring(0, 6) : h;
  return RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(six) ? 'FF${six.toUpperCase()}' : null;
}

/// A colour mixed with white ([amount] = the share of the colour kept) — the light fill behind a coloured value.
String? tint(String? hex, [double amount = 0.14]) {
  final h = (hex ?? '').replaceAll('#', '');
  final six = h.length >= 6 ? h.substring(0, 6) : h;
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(six)) return null;
  String mix(int i) {
    final c = int.parse(six.substring(i, i + 2), radix: 16);
    return (255 - (255 - c) * amount).round().toRadixString(16).padLeft(2, '0');
  }

  return 'FF${mix(0)}${mix(2)}${mix(4)}'.toUpperCase();
}

/// "05 Oct 2026, 14:32" — the stamp on every sheet.
String stampText(DateTime when) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)} ${months[d.month - 1]} ${d.year}, ${two(d.hour)}:${two(d.minute)}';
}

/// Sheet names: at most 31 characters, none of [ ] : * ? / \, and unique inside the workbook.
String safeSheetName(String? name, Set<String> used) {
  var base = (name ?? 'Sheet').replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (base.length > 31) base = base.substring(0, 31).trim();
  if (base.isEmpty) base = 'Sheet';
  var candidate = base;
  var n = 2;
  while (used.contains(candidate.toLowerCase())) {
    final suffix = ' ($n)';
    candidate = '${base.substring(0, math.min(base.length, 31 - suffix.length))}$suffix';
    n++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}

/// One line naming the filters, for the top of a data sheet ("Location: Plant 1 · Dates: ...").
String filterLine(List<ReportFilterLine> filters) {
  final parts = [
    for (final f in filters)
      if (f.$2.isNotEmpty) '${f.$1}: ${f.$2}',
  ];
  return parts.isEmpty ? 'No filters — everything you may see' : parts.join('  ·  ');
}

// The narrowest a column may be so its HEADER reads in full. The filter button
// Excel draws on the right of every header cell covers about five characters'
// width, so the width is the text plus that — a long header may wrap onto two
// lines (half its length, or its longest word if that is longer, plus the
// button). Bold text runs ~15% wider than the width unit.
const _filterButtonWidth = 5;

int headerWidth(String header) {
  final text = header.trim();
  if (text.isEmpty) return 0;
  final longestWord = text.split(RegExp(r'\s+')).map((w) => w.length).reduce(math.max);
  final lineChars = text.length <= 12 ? text.length : math.max(longestWord, (text.length / 2).ceil());
  return (lineChars * 1.15).ceil() + _filterButtonWidth;
}

double _columnWidth(ReportColumn c) => math.max(c.width, headerWidth(c.header).toDouble());

// Whether the header needs a second line at that width (the header row is made taller then).
bool _headerWraps(ReportColumn c) => (c.header.length * 1.15).ceil() + _filterButtonWidth > _columnWidth(c);

String _percentFormat(int decimals) => decimals > 0 ? '0.${'0' * decimals}%' : '0%';

HorizontalAlign _alignOf(ReportColumn c) => switch (c.format) {
  ReportFormat.integer || ReportFormat.number || ReportFormat.percent => HorizontalAlign.Right,
  ReportFormat.date => HorizontalAlign.Center,
  ReportFormat.text => HorizontalAlign.Left,
};

// Characters XML 1.0 cannot carry (an old record with a stray control character)
// would make the whole file unreadable.
final _xmlIllegal = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]');

String _cleanText(String s) {
  final clean = s.replaceAll(_xmlIllegal, '');
  return clean.length > _maxCellText ? clean.substring(0, _maxCellText) : clean;
}

// ── Styles ──────────────────────────────────────────────────────────────────

ExcelColor _color(String argbHex) => ExcelColor.fromHexString(argbHex);

Border _thin() => Border(borderStyle: BorderStyle.Thin, borderColorHex: _color(_borderColor));

class _Styles {
  final _cache = <String, CellStyle>{};

  CellStyle get({
    String font = _ink,
    String? fill,
    bool bold = false,
    bool italic = false,
    int size = 10,
    HorizontalAlign h = HorizontalAlign.Left,
    VerticalAlign v = VerticalAlign.Top,
    bool wrap = false,
    NumFormat numFmt = NumFormat.standard_0,
    bool box = false,
    String? topBorder,
    String? topStyle,
    bool sides = false,
    bool bottom = false,
  }) {
    final key = [font, fill, bold, italic, size, h.index, v.index, wrap, numFmt.formatCode, box, topBorder, topStyle, sides, bottom].join('|');
    return _cache.putIfAbsent(
      key,
      () => CellStyle(
        fontFamily: getFontFamily(FontFamily.Calibri),
        fontSize: size,
        bold: bold,
        italic: italic,
        fontColorHex: _color(font),
        backgroundColorHex: fill == null ? ExcelColor.none : _color(fill),
        horizontalAlign: h,
        verticalAlign: v,
        textWrapping: wrap ? TextWrapping.WrapText : null,
        numberFormat: numFmt,
        leftBorder: box || sides ? _thin() : null,
        rightBorder: box || sides ? _thin() : null,
        bottomBorder: box || bottom ? _thin() : null,
        topBorder: box
            ? _thin()
            : topBorder != null
                ? Border(borderStyle: topStyle == 'thick' ? BorderStyle.Thick : BorderStyle.Medium, borderColorHex: _color(topBorder))
                : null,
      ),
    );
  }
}

NumFormat _numFmtOf(ReportColumn c) => switch (c.format) {
  ReportFormat.text => NumFormat.standard_0,
  ReportFormat.integer => NumFormat.standard_3, // #,##0
  ReportFormat.number => NumFormat.standard_0, // General: "#,##0.##" would print a whole number with a dangling dot
  ReportFormat.percent => NumFormat.custom(formatCode: _percentFormat(c.decimals)),
  ReportFormat.date => NumFormat.custom(formatCode: 'dd-mmm-yyyy'),
};

// What goes into a cell for a column's format. Percent columns hold WHOLE
// percents everywhere in the app (82 = 82%), Excel wants the fraction.
CellValue? _cellValue(Object? value, ReportFormat format) {
  switch (format) {
    case ReportFormat.date:
      final d = value is DateTime ? value : null;
      return d == null ? null : DateCellValue.fromDateTime(d.toLocal());
    case ReportFormat.integer:
    case ReportFormat.number:
    case ReportFormat.percent:
      final n = value is num ? value : (value is String ? num.tryParse(value) : null);
      if (n == null || !n.isFinite) return null;
      final v = format == ReportFormat.percent ? n / 100 : n;
      return v == v.truncateToDouble() && format != ReportFormat.percent ? IntCellValue(v.toInt()) : DoubleCellValue(v.toDouble());
    case ReportFormat.text:
      if (value == null) return null;
      return TextCellValue(_cleanText(value is DateTime ? value.toLocal().toIso8601String() : value.toString()));
  }
}

CellIndex _at(int col, int row) => CellIndex.indexByColumnRow(columnIndex: col, rowIndex: row);

void _put(Sheet ws, int col, int row, CellValue? value, CellStyle style) => ws.updateCell(_at(col, row), value, cellStyle: style);

/// Merges [col1]..[col2] of one row; the start cell's value and style stay.
void _mergeRow(Sheet ws, int row, int col1, int col2) {
  if (col2 > col1) ws.merge(_at(col1, row), _at(col2, row));
}

// ── Sheet bookkeeping for the zip patch ─────────────────────────────────────

class _SheetPatch {
  final String tabColor;

  /// Rows above the first scrolling row and columns left of the first scrolling column (0 = none).
  final int freezeRows;
  final int freezeColumns;

  /// The auto-filter range ("A4:S120"), or null.
  final String? autoFilter;

  const _SheetPatch({
    required this.tabColor,
    this.freezeRows = 0,
    this.freezeColumns = 0,
    this.autoFilter,
  });
}

String _columnName(int index) {
  var n = index;
  var s = '';
  do {
    s = String.fromCharCode(65 + n % 26) + s;
    n = n ~/ 26 - 1;
  } while (n >= 0);
  return s;
}

String _stampLine(ReportWorkbookSpec spec) =>
    'Generated ${stampText(spec.generatedAt)}${spec.generatedBy.isNotEmpty ? ' by ${spec.generatedBy}' : ''}';

void _writeBand(Sheet ws, _Styles styles, int row, String text, int lastColumn, {int size = 14, double height = 28}) {
  _put(
    ws,
    0,
    row,
    TextCellValue(_cleanText(text)),
    styles.get(font: _bandText, fill: _band, bold: true, size: size, v: VerticalAlign.Center),
  );
  _mergeRow(ws, row, 0, math.max(lastColumn, 1) - 1);
  ws.setRowHeight(row, height);
}

void _writeSubtitle(Sheet ws, _Styles styles, int row, String text, int lastColumn, {double? height}) {
  _put(
    ws,
    0,
    row,
    TextCellValue(_cleanText(text)),
    styles.get(font: _muted, italic: true, size: 9, v: VerticalAlign.Center, wrap: true),
  );
  _mergeRow(ws, row, 0, math.max(lastColumn, 1) - 1);
  if (height != null) ws.setRowHeight(row, height);
}

// ── Summary sheet ───────────────────────────────────────────────────────────

_SheetPatch _writeSummarySheet(Sheet ws, ReportSummarySheet sheet, ReportWorkbookSpec spec, _Styles styles) {
  for (var c = 0; c < _summaryColumns; c++) {
    ws.setColumnWidth(c, _summaryColumnWidth);
  }
  _writeBand(ws, styles, 0, spec.title, _summaryColumns, size: 18, height: 36);
  _writeSubtitle(ws, styles, 1, _stampLine(spec), _summaryColumns);
  var row = 3;

  void heading(String text) {
    _put(
      ws,
      0,
      row,
      TextCellValue(_cleanText(text.toUpperCase())),
      styles.get(font: _muted, bold: true, v: VerticalAlign.Center, topBorder: null, bottom: false),
    );
    _mergeRow(ws, row, 0, _summaryColumns - 1);
    ws.setRowHeight(row, 20);
    row++;
  }

  // Filters applied: label | value (merged to the right edge).
  if (spec.filters.isNotEmpty) {
    heading('Filters applied');
    for (final f in spec.filters) {
      _put(ws, 0, row, TextCellValue(_cleanText(f.$1)), styles.get(bold: true, fill: _labelFill, wrap: true, box: true));
      final value = f.$2.isEmpty ? 'All' : f.$2;
      _put(ws, 1, row, TextCellValue(_cleanText(value)), styles.get(wrap: true, box: true));
      _mergeRow(ws, row, 1, _summaryColumns - 1);
      // Merged cells do not auto-fit: give a long value (a list of names) the room its length needs.
      final lines = math.max(1, (value.length / 90).ceil());
      if (lines > 1) ws.setRowHeight(row, 15.0 * lines);
      row++;
    }
    row++;
  }

  // Stat tiles: _summaryColumns per row, label above value, tinted in the tile's own colour.
  for (final group in sheet.tileGroups) {
    if (group.title != null) heading(group.title!);
    final tiles = group.tiles;
    for (var start = 0; start < tiles.length; start += _summaryColumns) {
      final slice = tiles.sublist(start, math.min(start + _summaryColumns, tiles.length));
      final hasNote = slice.any((t) => (t.note ?? '').isNotEmpty);
      for (var i = 0; i < slice.length; i++) {
        final tile = slice[i];
        final color = argb(tile.color) ?? _ink;
        final fill = tint(tile.color, 0.12) ?? _labelFill;
        _put(
          ws,
          i,
          row,
          TextCellValue(_cleanText(tile.label.toUpperCase())),
          styles.get(font: _muted, bold: true, size: 8, fill: fill, v: VerticalAlign.Center, wrap: true, topBorder: color, topStyle: 'thick', sides: true),
        );
        final v = tile.value;
        final isNumber = v is num && v.isFinite;
        CellValue? cell;
        NumFormat fmt = NumFormat.standard_0;
        if (tile.format == ReportFormat.percent && isNumber) {
          cell = DoubleCellValue(v / 100);
          fmt = NumFormat.custom(formatCode: _percentFormat(tile.decimals));
        } else if (isNumber) {
          cell = v == v.truncateToDouble() ? IntCellValue(v.toInt()) : DoubleCellValue(v.toDouble());
          fmt = tile.decimals > 0 ? NumFormat.custom(formatCode: '#,##0.${'0' * tile.decimals}') : NumFormat.standard_3;
        } else {
          cell = TextCellValue(v == null || v.toString().isEmpty ? '—' : _cleanText(v.toString()));
        }
        _put(
          ws,
          i,
          row + 1,
          cell,
          styles.get(font: color, bold: true, size: 22, fill: fill, v: VerticalAlign.Center, numFmt: fmt, sides: true, bottom: !hasNote),
        );
        if (hasNote) {
          _put(
            ws,
            i,
            row + 2,
            TextCellValue(_cleanText(tile.note ?? '')),
            styles.get(font: _muted, italic: true, size: 8, fill: fill, wrap: true, sides: true, bottom: true),
          );
        }
      }
      ws.setRowHeight(row, 22);
      ws.setRowHeight(row + 1, 34);
      if (hasNote) ws.setRowHeight(row + 2, 24);
      row += hasNote ? 4 : 3;
    }
  }

  for (final note in sheet.notes) {
    _put(ws, 0, row, TextCellValue(_cleanText(note)), styles.get(font: _muted, italic: true, size: 9, wrap: true));
    _mergeRow(ws, row, 0, _summaryColumns - 1);
    // Merged cells do not auto-fit: a note is up to a few lines long.
    ws.setRowHeight(row, 13.0 * math.max(1, (note.length / 130).ceil()) + 2);
    row++;
  }
  return const _SheetPatch(tabColor: _band);
}

// ── Data sheet ──────────────────────────────────────────────────────────────

_SheetPatch _writeDataSheet(Sheet ws, ReportDataSheet sheet, ReportWorkbookSpec spec, _Styles styles) {
  final columns = sheet.columns;
  final width = columns.length;
  for (var i = 0; i < width; i++) {
    ws.setColumnWidth(i, _columnWidth(columns[i]));
  }
  _writeBand(ws, styles, 0, sheet.title ?? '${spec.title} — ${sheet.name}', width);
  _writeSubtitle(ws, styles, 1, '${filterLine(spec.filters)}   |   ${_stampLine(spec)}', width, height: 28);

  const headerRow = _dataHeaderRow - 1; // 0-based
  ws.setRowHeight(headerRow, columns.any(_headerWraps) ? 40 : 28);
  for (var i = 0; i < width; i++) {
    final c = columns[i];
    // Never right-aligned: Excel's filter button sits at the right edge and would cover the text.
    final h = _alignOf(c) == HorizontalAlign.Left ? HorizontalAlign.Left : HorizontalAlign.Center;
    _put(ws, i, headerRow, TextCellValue(_cleanText(c.header)), styles.get(font: _headText, fill: _head, bold: true, h: h, v: VerticalAlign.Center, wrap: true, box: true));
  }

  final rows = sheet.rows;
  if (rows.isEmpty) {
    _put(
      ws,
      0,
      headerRow + 1,
      TextCellValue('No records match these filters.'),
      styles.get(font: _muted, italic: true, h: HorizontalAlign.Center, v: VerticalAlign.Center),
    );
    _mergeRow(ws, headerRow + 1, 0, math.max(width, 1) - 1);
    ws.setRowHeight(headerRow + 1, 24);
  }

  for (var index = 0; index < rows.length; index++) {
    final record = rows[index];
    final excelRow = headerRow + 1 + index;
    for (var i = 0; i < width; i++) {
      final c = columns[i];
      final raw = record[c.key];
      final tone = c.tone?.call(raw, record);
      final fg = tone == null ? null : argb(tone.fg);
      final fill = tone != null
          ? (tone.bg != null ? argb(tone.bg) : (tone.fg != null ? tint(tone.fg, 0.14) : null))
          : null;
      final zebraFill = index.isOdd ? _zebra : null;
      _put(
        ws,
        i,
        excelRow,
        _cellValue(raw, c.format),
        styles.get(
          font: fg ?? _ink,
          bold: fg != null,
          fill: fill ?? zebraFill,
          h: _alignOf(c),
          wrap: c.wrap,
          numFmt: _numFmtOf(c),
          box: true,
        ),
      );
    }
  }

  final int lastDataRow = headerRow + math.max<int>(rows.length, 1);
  final totals = sheet.totals;
  if (totals != null) {
    final totalsRow = lastDataRow + 1;
    for (var i = 0; i < width; i++) {
      final c = columns[i];
      final given = totals.values[c.key];
      final CellValue? value = (i == 0 && given == null)
          ? TextCellValue(_cleanText(totals.label))
          : (i == 0 && given is String ? TextCellValue(_cleanText(given)) : _cellValue(given, c.format));
      _put(
        ws,
        i,
        totalsRow,
        value,
        styles.get(
          bold: true,
          fill: _labelFill,
          v: VerticalAlign.Center,
          h: _alignOf(c),
          numFmt: i == 0 ? NumFormat.standard_0 : _numFmtOf(c),
          topBorder: _band,
          sides: true,
          bottom: true,
        ),
      );
    }
    ws.setRowHeight(totalsRow, 22);
  }

  return _SheetPatch(
    tabColor: 'FF64748B',
    freezeRows: _dataHeaderRow,
    freezeColumns: sheet.freezeColumns,
    autoFilter: rows.isEmpty ? null : 'A$_dataHeaderRow:${_columnName(math.max(width, 1) - 1)}${_dataHeaderRow + rows.length}',
  );
}

// ── Public ──────────────────────────────────────────────────────────────────

/// The finished .xlsx. Synchronous and CPU-heavy for a big table — on the phone
/// call [encodeReportWorkbookInBackground].
Uint8List encodeReportWorkbook(ReportWorkbookSpec spec) {
  final excel = Excel.createExcel();
  final starter = excel.getDefaultSheet() ?? 'Sheet1';
  final styles = _Styles();
  final used = <String>{};
  final patches = <String, _SheetPatch>{};

  var first = true;
  for (final sheet in spec.sheets) {
    final name = safeSheetName(sheet.name, used);
    // The workbook starts with one empty sheet: the first of ours takes its place.
    if (first) {
      if (starter != name) excel.rename(starter, name);
      first = false;
    }
    final ws = excel[name];
    patches[name] = switch (sheet) {
      ReportSummarySheet() => _writeSummarySheet(ws, sheet, spec, styles),
      ReportDataSheet() => _writeDataSheet(ws, sheet, spec, styles),
    };
  }
  if (spec.sheets.isEmpty) excel.rename(starter, 'Summary');
  final bytes = excel.encode();
  if (bytes == null) throw StateError('The workbook could not be written.');
  return Uint8List.fromList(_patchPackage(bytes, patches));
}

/// [encodeReportWorkbook] off the UI thread (a few thousand rows take a second or
/// two of pure Dart). Falls back to the calling isolate if one cannot be started.
Future<Uint8List> encodeReportWorkbookInBackground(ReportWorkbookSpec spec) async {
  try {
    return await Isolate.run(() => encodeReportWorkbook(spec));
  } on StateError {
    rethrow;
  } catch (_) {
    return encodeReportWorkbook(spec);
  }
}

// ── The zip patch: freeze panes, auto-filter, tab colour, print layout ──────
//
// The `excel` package writes each sheet as
//   <worksheet …> <dimension …/> <sheetViews>…</sheetViews> <cols>…</cols>
//   <sheetData>…</sheetData> [<mergeCells…/>] <pageMargins …/> </worksheet>
// and has no API for the four things below, so they are added to that XML:
//   <sheetPr> (tab colour, fit-to-page) goes first, <sheetViews> gets the frozen
//   pane and hides the gridlines, <autoFilter> goes right after <sheetData> (before
//   <mergeCells>, as the schema orders it), <pageSetup> right after <pageMargins>.
// A pattern that is not there is left alone, and the writer's tests assert each
// edit landed, so a change in the package's output shows up as a failing test
// instead of a file that quietly lost its frozen header.

String? _attr(String tag, String name) {
  final m = RegExp('$name="([^"]*)"').firstMatch(tag);
  return m?.group(1);
}

String _unescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _patchSheetXml(String xml, _SheetPatch p) {
  var out = xml;

  // <sheetPr> first among the worksheet's children.
  final open = RegExp(r'<worksheet\b[^>]*>').firstMatch(out);
  if (open != null && !out.contains('<sheetPr')) {
    final sheetPr = '<sheetPr><tabColor rgb="${p.tabColor}"/><pageSetUpPr fitToPage="1"/></sheetPr>';
    out = out.replaceRange(open.end, open.end, sheetPr);
  }

  // The view: gridlines off (the tables carry their own borders) and the frozen pane.
  final rows = p.freezeRows;
  final cols = p.freezeColumns;
  final topLeft = '${_columnName(cols)}${rows + 1}';
  final pane = rows == 0 && cols == 0
      ? ''
      : cols == 0
          ? '<pane ySplit="$rows" topLeftCell="$topLeft" activePane="bottomLeft" state="frozen"/>'
              '<selection pane="bottomLeft" activeCell="$topLeft" sqref="$topLeft"/>'
          : '<pane xSplit="$cols" ySplit="$rows" topLeftCell="$topLeft" activePane="bottomRight" state="frozen"/>'
              '<selection pane="topRight" activeCell="${_columnName(cols)}1" sqref="${_columnName(cols)}1"/>'
              '<selection pane="bottomLeft" activeCell="A${rows + 1}" sqref="A${rows + 1}"/>'
              '<selection pane="bottomRight" activeCell="$topLeft" sqref="$topLeft"/>';
  out = out.replaceFirst(
    RegExp(r'<sheetViews>.*?</sheetViews>', dotAll: true),
    '<sheetViews><sheetView showGridLines="0" workbookViewId="0">$pane</sheetView></sheetViews>',
  );

  if (p.autoFilter != null) {
    out = out.replaceFirst('</sheetData>', '</sheetData><autoFilter ref="${p.autoFilter}"/>');
  }
  out = out.replaceFirstMapped(
    RegExp(r'<pageMargins\b[^>]*/>'),
    (m) => '${m.group(0)}<pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>',
  );
  return out;
}

List<int> _patchPackage(List<int> bytes, Map<String, _SheetPatch> patches) {
  final archive = ZipDecoder().decodeBytes(bytes);
  ArchiveFile? file(String name) {
    for (final f in archive.files) {
      if (f.name == name) return f;
    }
    return null;
  }

  String text(ArchiveFile f) => utf8.decode(f.content as List<int>);

  final workbook = file('xl/workbook.xml');
  final rels = file('xl/_rels/workbook.xml.rels');
  if (workbook == null || rels == null) return bytes;

  final targetById = <String, String>{
    for (final m in RegExp(r'<Relationship\b[^>]*/?>').allMatches(text(rels)))
      if (_attr(m.group(0)!, 'Id') != null && _attr(m.group(0)!, 'Target') != null)
        _attr(m.group(0)!, 'Id')!: _attr(m.group(0)!, 'Target')!,
  };
  final pathByName = <String, String>{};
  for (final m in RegExp(r'<sheet\b[^>]*/?>').allMatches(text(workbook))) {
    final tag = m.group(0)!;
    final name = _attr(tag, 'name');
    final id = _attr(tag, 'r:id');
    final target = id == null ? null : targetById[id];
    if (name != null && target != null) {
      pathByName[_unescape(name)] = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    }
  }

  final patched = Archive();
  final byPath = {for (final e in patches.entries) if (pathByName[e.key] != null) pathByName[e.key]!: e.value};
  for (final f in archive.files) {
    final p = byPath[f.name];
    if (p == null) {
      patched.addFile(f);
      continue;
    }
    final data = utf8.encode(_patchSheetXml(text(f), p));
    patched.addFile(ArchiveFile(f.name, data.length, data));
  }
  return ZipEncoder().encode(patched) ?? bytes;
}
