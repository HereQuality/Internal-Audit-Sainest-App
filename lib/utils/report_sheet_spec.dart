/// utils/report_sheet_spec.dart
/// ──────────────────────────────
/// What an Excel report IS, before any file exists: a plain description of its
/// sheets (rows in, colours decided), the Dart twin of the `spec` object the web
/// app hands to client/src/utils/excelReport.js. Keeping the description apart
/// from the .xlsx writer (xlsx_report_writer.dart) is what lets the rules —
/// which row says what, which cell is green — be unit-tested without a file, and
/// the writer be swapped without touching them.
///
/// Every value in a row is a plain Dart value: String, int, double, DateTime
/// (a date column), or null (an empty cell). A percent column holds a WHOLE
/// percent (82 = 82%), exactly as the rest of the app does; the writer divides
/// by 100 because Excel wants the fraction.
library;

/// How a column's values are written.
enum ReportFormat { text, integer, number, percent, date }

/// A cell colour: [fg] the text, [bg] the fill (a light tint of [fg] when only
/// [fg] is given). Hex strings, "#rrggbb".
class ReportTone {
  final String? fg;
  final String? bg;

  const ReportTone({this.fg, this.bg});
}

/// Picks the tone of one cell from its value (and its whole row), or null for
/// none.
typedef ReportToneFn = ReportTone? Function(Object? value, Map<String, Object?> row);

class ReportColumn {
  final String header;
  final String key;
  final double width;
  final ReportFormat format;

  /// Decimals of a percent column (0 = "82%", 1 = "82.5%").
  final int decimals;
  final bool wrap;
  final ReportToneFn? tone;

  const ReportColumn({
    required this.header,
    required this.key,
    this.width = 18,
    this.format = ReportFormat.text,
    this.decimals = 0,
    this.wrap = false,
    this.tone,
  });
}

/// One stat tile of a Summary sheet — the same tiles the tab shows on screen.
class ReportTile {
  final String label;

  /// A number (written as one), a String (written as text), or null ("—").
  final Object? value;
  final String color;

  /// [ReportFormat.percent] (value is a whole percent) or null for the default.
  final ReportFormat? format;
  final int decimals;
  final String? note;

  const ReportTile({
    required this.label,
    required this.value,
    required this.color,
    this.format,
    this.decimals = 0,
    this.note,
  });
}

class ReportTileGroup {
  final String? title;
  final List<ReportTile> tiles;

  const ReportTileGroup({this.title, required this.tiles});
}

sealed class ReportSheet {
  final String name;

  const ReportSheet(this.name);
}

/// The first sheet: the filters applied, the stat tiles, a few notes.
class ReportSummarySheet extends ReportSheet {
  final List<ReportTileGroup> tileGroups;
  final List<String> notes;

  const ReportSummarySheet({
    String name = 'Summary',
    this.tileGroups = const [],
    this.notes = const [],
  }) : super(name);
}

/// A bold last row that is not part of the filterable table.
class ReportTotals {
  final String label;
  final Map<String, Object?> values;

  const ReportTotals({this.label = 'Total', required this.values});
}

/// A table: a title band, a filter line, a frozen filterable header and rows.
class ReportDataSheet extends ReportSheet {
  final String? title;
  final List<ReportColumn> columns;
  final List<Map<String, Object?>> rows;
  final ReportTotals? totals;

  /// How many leading columns stay put when scrolling sideways.
  final int freezeColumns;

  const ReportDataSheet({
    required String name,
    this.title,
    required this.columns,
    required this.rows,
    this.totals,
    this.freezeColumns = 0,
  }) : super(name);
}

/// "Label: value" — one line of the Summary's "Filters applied" block.
typedef ReportFilterLine = (String label, String value);

class ReportWorkbookSpec {
  /// The file name WITHOUT ".xlsx".
  final String filename;
  final String title;
  final List<ReportFilterLine> filters;
  final String generatedBy;
  final DateTime generatedAt;
  final List<ReportSheet> sheets;

  const ReportWorkbookSpec({
    required this.filename,
    required this.title,
    this.filters = const [],
    this.generatedBy = '',
    required this.generatedAt,
    required this.sheets,
  });

  /// A sheet by its name, or null.
  ReportSheet? sheet(String name) {
    for (final s in sheets) {
      if (s.name == name) return s;
    }
    return null;
  }
}
