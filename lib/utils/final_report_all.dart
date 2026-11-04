import 'report_sheet_spec.dart';

/// utils/final_report_all.dart
/// ─────────────────────────────
/// "Download All": the Audits, NCs and Repeated NCs workbooks folded into ONE file —
/// the Dart twin of the web app's client/src/utils/finalReportExcel.js#buildAllReport,
/// so the phone's combined file says what the web's does.
///
/// Each part is the spec its own tab's "Download Excel" builds (buildAuditsReport /
/// buildNcsReport / buildRepeatsReport), under the filters that tab uses right now. They
/// are merged into:
///   - ONE Summary, first: the tiles of all three, each group headed by its tab
///     ("Audits — Audit overview", "NCs — NC overview", "Repeated NCs — Repeated NC
///     overview"); the filters applied (a line every tab carries identically is said once,
///     the others are led by their tab — the tabs filter differently: status and tiles are
///     the Audits', flag the NCs' and Repeats', the Repeated NCs window defaults to six
///     months, and each tab has its own search); and every tab's notes, prefixed by it;
///   - then every tab's own sheets, unchanged, in the order Audits · NCs · Repeated NCs.
///     The "By Location / By Auditor / By Auditee" tallies carry their tab's name in front
///     ("NCs By Location", "Repeats By Auditor") so no two sheets are called the same.
///
/// Pure: specs in, one spec out. The writer (xlsx_report_writer.dart) treats it like any
/// other, so the frozen headers and auto-filters of every merged sheet come with it.

/// The tallies every tab has; in the one file each gets its tab's name in front.
const _sharedSheetNames = {'By Location', 'By Auditor', 'By Auditee'};

/// Excel's limit on a sheet name.
const sheetNameMax = 31;

String _sheetLabel(String prefix, String name) {
  final full = '$prefix $name';
  return full.length > sheetNameMax ? full.substring(0, sheetNameMax) : full;
}

/// `Final-Report-All-<yyyy-MM-dd>` — the file name WITHOUT ".xlsx", the day it was made.
String finalReportAllFileBase(DateTime when) {
  final d = when.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return 'Final-Report-All-${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// [finalReportAllFileBase] with its extension.
String finalReportAllFileName(DateTime when) => '${finalReportAllFileBase(when)}.xlsx';

class _Part {
  const _Part(this.label, this.prefix, this.spec);

  /// The tab's name, in the Summary ("Repeated NCs").
  final String label;

  /// What its tallies' sheet names start with ("Repeats").
  final String prefix;
  final ReportWorkbookSpec spec;
}

String _lineKey(ReportFilterLine line) => '${line.$1}\u0000${line.$2}';

/// Folds the three tabs' workbooks into one. Any part may be null (the file then holds
/// the others). Throws a [StateError] if two sheets of the combined file would share a name.
ReportWorkbookSpec buildAllReport({
  ReportWorkbookSpec? audits,
  ReportWorkbookSpec? ncs,
  ReportWorkbookSpec? repeats,
  String generatedBy = '',
  required DateTime generatedAt,
}) {
  final parts = <_Part>[
    if (audits != null) _Part('Audits', 'Audits', audits),
    if (ncs != null) _Part('NCs', 'NCs', ncs),
    if (repeats != null) _Part('Repeated NCs', 'Repeats', repeats),
  ];

  // Filters: a [label, value] line that every tab carries identically is said once; the rest are
  // led by their tab.
  final everywhere = <String>{};
  if (parts.length > 1) {
    for (final line in parts.first.spec.filters) {
      final key = _lineKey(line);
      if (parts.every((p) => p.spec.filters.any((l) => _lineKey(l) == key))) everywhere.add(key);
    }
  }
  final filters = <ReportFilterLine>[
    if (parts.isNotEmpty)
      for (final line in parts.first.spec.filters)
        if (everywhere.contains(_lineKey(line))) line,
    for (final p in parts)
      for (final line in p.spec.filters)
        if (!everywhere.contains(_lineKey(line))) ('${p.label} · ${line.$1}', line.$2),
  ];

  final tileGroups = <ReportTileGroup>[];
  final notes = <String>[];
  final sheets = <ReportSheet>[];
  final taken = <String>{'Summary'};
  for (final p in parts) {
    for (final sheet in p.spec.sheets) {
      switch (sheet) {
        case ReportSummarySheet():
          for (final group in sheet.tileGroups) {
            tileGroups.add(ReportTileGroup(title: '${p.label} — ${group.title ?? 'Overview'}', tiles: group.tiles));
          }
          for (final note in sheet.notes) {
            notes.add('${p.label}: $note');
          }
        case ReportDataSheet():
          final name = _sharedSheetNames.contains(sheet.name) ? _sheetLabel(p.prefix, sheet.name) : sheet.name;
          if (!taken.add(name)) {
            throw StateError('Two sheets of the combined Final Report are both called "$name".');
          }
          sheets.add(ReportDataSheet(
            name: name,
            title: sheet.title,
            columns: sheet.columns,
            rows: sheet.rows,
            totals: sheet.totals,
            freezeColumns: sheet.freezeColumns,
          ));
      }
    }
  }

  return ReportWorkbookSpec(
    filename: finalReportAllFileBase(generatedAt),
    title: 'Final Report — All',
    filters: filters,
    generatedBy: generatedBy,
    generatedAt: generatedAt,
    sheets: [ReportSummarySheet(tileGroups: tileGroups, notes: notes), ...sheets],
  );
}
