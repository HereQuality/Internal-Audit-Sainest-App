import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/audit_detail_model.dart';
import 'report_pdf_fonts.dart';
import 'report_sections.dart';

/// utils/report_pdf_builder.dart
/// ────────────────────────────────
/// Builds a real, structured PDF (selectable text/tables, not a rasterized
/// screenshot) for the mobile Reports screen — same section/index-table
/// shape as the web's printable Full Report (AuditFullReport.jsx +
/// Components/AuditReport/ReportIndexTable.jsx): header info, then one
/// Sr/Checkpoint/Status/Score[/Weightage]/Achieved-Total/Total% table per
/// location, each ending in a bold FINAL SCORE row.
const _headerBlue = PdfColor.fromInt(0xFF005A8E);
const _bannerBlue = PdfColor.fromInt(0xFF0077B6);
const _lightBlue = PdfColor.fromInt(0xFFE8F3FA);
const _slate = PdfColor.fromInt(0xFF334155);
const _muted = PdfColor.fromInt(0xFF64748B);

final _findingColor = {
  'Strong Compliance': const PdfColor.fromInt(0xFF16A34A),
  'Compliance': const PdfColor.fromInt(0xFF0EA5E9),
  'OFI': const PdfColor.fromInt(0xFFD97706),
  'NC': const PdfColor.fromInt(0xFFEF4444),
};

String _fmtDate(DateTime? d) {
  if (d == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
}

Future<Uint8List> buildReportPdf(AuditDetailModel audit) async {
  final doc = pw.Document(theme: await loadReportPdfTheme());
  final sections = buildReportSections(audit);
  final isWeightage = audit.scoringSystem == 'weightage';
  final overall = audit.scoreResult.percentage;

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        _buildHeader(audit, overall),
        pw.SizedBox(height: 16),
        for (final section in sections) ...[
          _buildSectionTable(section, isWeightage, audit.maxScore),
          pw.SizedBox(height: 16),
        ],
        if ((audit.finalAuditorRemark ?? '').isNotEmpty) _buildRemark(audit.finalAuditorRemark!),
      ],
    ),
  );

  return doc.save();
}

/// buildCombinedReportPdf — one PDF spanning several completed zones of the
/// SAME multi-zone batch (see AuditModel.scheduleBatchId) that this
/// employee happens to be personally assigned to more than one of — the
/// mobile counterpart of a batch's "Show Report" on the web Final Report
/// page. Each zone gets its own section table (labeled by its own
/// location, not the shared title) ending in a "{location} SUBTOTAL" row,
/// then one true FINAL SCORE bar combines every zone's achieved/max — sum-
/// then-divide across the whole group, never an average of each zone's own
/// %, same rule every other multi-audit rollup in this app uses.
///
/// Deliberately built from zones already fetched one at a time via the
/// normal GET /audits/:id?report=true (AuditsProvider.fetchAuditReportDetail
/// — the same call the single-report PDF above uses) rather than the
/// server's own combined GET /audits/batch/:batchId/report: that endpoint
/// is gated to planner/admin menu access (see server/routes/audit.routes.js
/// LIST_MENU_URLS: requireMenuPermission(["/schedule-audit", "/final-report"])),
/// so a field auditor personally assigned to every zone here still
/// wouldn't be authorized to call it, even though they can already see
/// each zone's own full detail individually.
Future<Uint8List> buildCombinedReportPdf(List<AuditDetailModel> zones) async {
  final doc = pw.Document(theme: await loadReportPdfTheme());
  if (zones.isEmpty) return doc.save();
  final first = zones.first;
  final isWeightage = first.scoringSystem == 'weightage';

  final auditorNames = <String>{};
  DateTime? minStart;
  DateTime? maxEnd;
  var grandAchieved = 0.0;
  var grandMax = 0.0;
  final sectionWidgets = <pw.Widget>[];

  for (final zone in zones) {
    auditorNames.addAll(zone.auditorNames);
    final zoneStart = zone.scheduledDate;
    if (zoneStart != null && (minStart == null || zoneStart.isBefore(minStart))) {
      minStart = zoneStart;
    }
    final zoneEnd = zone.scheduledEndDate ?? zone.completedDate;
    if (zoneEnd != null && (maxEnd == null || zoneEnd.isAfter(maxEnd))) {
      maxEnd = zoneEnd;
    }
    final zoneLabel = zone.locationLabels.isNotEmpty ? zone.locationLabels.map((l) => l.display).join(', ') : zone.title;
    for (final section in buildReportSections(zone)) {
      final relabeled = ReportSection(label: zoneLabel, tree: section.tree);
      final leaves = <ParameterNode>[];
      for (final node in relabeled.tree) {
        leaves.addAll(collectScoredLeaves([node]));
      }
      final am = sumAchievedMax(leaves, isWeightage ? 'weightage' : 'normal', zone.maxScore);
      grandAchieved += am.achieved;
      grandMax += am.max;
      sectionWidgets.add(_buildSectionTable(relabeled, isWeightage, zone.maxScore, finalRowLabel: '${zoneLabel.toUpperCase()} SUBTOTAL'));
      sectionWidgets.add(pw.SizedBox(height: 16));
    }
  }

  final finalPct = grandMax > 0 ? (grandAchieved / grandMax * 100).round() : null;

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        _buildCombinedHeader(first, auditorNames.toList(), minStart, maxEnd, zones.length, finalPct),
        pw.SizedBox(height: 16),
        ...sectionWidgets,
        _buildGrandFinalRow(grandAchieved, grandMax, finalPct),
      ],
    ),
  );

  return doc.save();
}

pw.Widget _buildCombinedHeader(
  AuditDetailModel first,
  List<String> auditorNames,
  DateTime? minStart,
  DateTime? maxEnd,
  int zoneCount,
  int? overall,
) {
  final infoRows = <List<String>>[
    ['Auditor(s)', auditorNames.isNotEmpty ? auditorNames.join(', ') : '—'],
    ['Locations', '$zoneCount'],
    ['Start Date', _fmtDate(minStart)],
    ['End Date', _fmtDate(maxEnd)],
    ['Status', first.status],
    ['Scoring', first.scoringSystem == 'weightage' ? 'Weightage Average' : 'Normal Average'],
  ];

  return pw.Container(
    padding: const pw.EdgeInsets.all(14),
    decoration: pw.BoxDecoration(
      color: _lightBlue,
      borderRadius: pw.BorderRadius.circular(10),
      border: pw.Border.all(color: PdfColors.blue100),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('INTERNAL AUDIT REPORT — COMBINED', style: pw.TextStyle(fontSize: 8, color: _headerBlue, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6)),
              pw.SizedBox(height: 3),
              pw.Text(first.title, style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Wrap(
                spacing: 22,
                runSpacing: 8,
                children: infoRows
                    .map(
                      (r) => pw.SizedBox(
                        width: 130,
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(r[0].toUpperCase(), style: pw.TextStyle(fontSize: 7, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.4)),
                            pw.SizedBox(height: 2),
                            pw.Text(r[1], style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
        pw.Container(
          width: 62,
          height: 62,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            shape: pw.BoxShape.circle,
            border: pw.Border.all(color: overall == null ? PdfColors.grey400 : overall >= 75 ? const PdfColor.fromInt(0xFF16A34A) : overall >= 50 ? const PdfColor.fromInt(0xFFD97706) : const PdfColor.fromInt(0xFFDC2626), width: 3),
          ),
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text(overall != null ? '$overall%' : '—', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.Text('SCORE', style: pw.TextStyle(fontSize: 5.5, color: _muted, fontWeight: pw.FontWeight.bold)),
            ],
          ),
        ),
      ],
    ),
  );
}

pw.Widget _buildGrandFinalRow(double achieved, double max, int? pct) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: pw.BoxDecoration(color: _headerBlue, borderRadius: pw.BorderRadius.circular(6)),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('FINAL SCORE (ALL LOCATIONS COMBINED)', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
          pw.Text(
            '${max > 0 ? '${achieved.round()}/${max.round()}' : '—'}   ${pct != null ? '$pct%' : '—'}',
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
          ),
        ],
      ),
    );

pw.Widget _buildHeader(AuditDetailModel audit, double? overall) {
  final infoRows = <List<String>>[
    ['Auditor', audit.auditorNames.isNotEmpty ? audit.auditorNames.join(', ') : '—'],
    if (!audit.isSelfAudit) ['Representative', (audit.auditeeName ?? '').isNotEmpty ? audit.auditeeName! : '—'],
    ['Start Date', _fmtDate(audit.scheduledDate)],
    ['End Date', _fmtDate(audit.scheduledEndDate ?? audit.completedDate)],
    ['Status', audit.status],
    ['Scoring', audit.scoringSystem == 'weightage' ? 'Weightage Average' : 'Normal Average'],
  ];

  return pw.Container(
    padding: const pw.EdgeInsets.all(14),
    decoration: pw.BoxDecoration(
      color: _lightBlue,
      borderRadius: pw.BorderRadius.circular(10),
      border: pw.Border.all(color: PdfColors.blue100),
    ),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('INTERNAL AUDIT REPORT', style: pw.TextStyle(fontSize: 8, color: _headerBlue, fontWeight: pw.FontWeight.bold, letterSpacing: 0.6)),
              pw.SizedBox(height: 3),
              pw.Text(audit.title, style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 10),
              pw.Wrap(
                spacing: 22,
                runSpacing: 8,
                children: infoRows
                    .map(
                      (r) => pw.SizedBox(
                        width: 130,
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.start,
                          children: [
                            pw.Text(r[0].toUpperCase(), style: pw.TextStyle(fontSize: 7, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.4)),
                            pw.SizedBox(height: 2),
                            pw.Text(r[1], style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
        pw.Container(
          width: 62,
          height: 62,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            shape: pw.BoxShape.circle,
            border: pw.Border.all(color: overall == null ? PdfColors.grey400 : overall >= 75 ? const PdfColor.fromInt(0xFF16A34A) : overall >= 50 ? const PdfColor.fromInt(0xFFD97706) : const PdfColor.fromInt(0xFFDC2626), width: 3),
          ),
          child: pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [
              pw.Text(overall != null ? '${overall.round()}%' : '—', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
              pw.Text('SCORE', style: pw.TextStyle(fontSize: 5.5, color: _muted, fontWeight: pw.FontWeight.bold)),
            ],
          ),
        ),
      ],
    ),
  );
}

pw.Widget _buildRemark(String remark) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 4),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300), borderRadius: pw.BorderRadius.circular(8)),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('FINAL AUDITOR REMARK', style: pw.TextStyle(fontSize: 7, color: _muted, fontWeight: pw.FontWeight.bold, letterSpacing: 0.4)),
          pw.SizedBox(height: 3),
          pw.Text(remark, style: const pw.TextStyle(fontSize: 9.5)),
        ],
      ),
    );

pw.Widget _cell(String text, {bool bold = false, PdfColor? color, pw.TextAlign align = pw.TextAlign.left, double size = 8.5}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: pw.Text(text, textAlign: align, style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color)),
    );

pw.Widget _buildSectionTable(
  ReportSection section,
  bool isWeightage,
  double? auditMaxScore, {
  String finalRowLabel = 'FINAL SCORE',
}) {
  final headers = ['Sr.', 'Parameter / Checkpoint', 'Status', 'Score', if (isWeightage) 'Weightage', if (isWeightage) 'Achvd/Total', 'Total (%)'];
  final rows = <pw.TableRow>[
    pw.TableRow(
      decoration: const pw.BoxDecoration(color: _headerBlue),
      children: headers.map((h) => _cell(h, bold: true, color: PdfColors.white, size: 7.5)).toList(),
    ),
  ];

  var grandAchieved = 0.0, grandMax = 0.0;

  void walk(ParameterNode node, String serial, int depth) {
    final leaves = collectScoredLeaves([node]);
    final am = sumAchievedMax(leaves, isWeightage ? 'weightage' : 'normal', auditMaxScore);
    if (depth == 0) {
      grandAchieved += am.achieved;
      grandMax += am.max;
    }
    final pct = percentageOf(am);

    if (!node.isLeaf) {
      final scoreLabel = am.max > 0 ? '${am.achieved.round()}/${am.max.round()}' : '—';
      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(color: depth == 0 ? _bannerBlue : PdfColors.blue50),
        children: [
          _cell(serial, bold: true, color: depth == 0 ? PdfColors.white : _muted),
          _cell(node.name, bold: true, color: depth == 0 ? PdfColors.white : _slate),
          _cell('—', align: pw.TextAlign.center, color: depth == 0 ? PdfColors.white : null),
          _cell(isWeightage ? '—' : scoreLabel, align: pw.TextAlign.center, bold: true, color: depth == 0 ? PdfColors.white : _bannerBlue),
          if (isWeightage) _cell(am.max > 0 ? am.max.round().toString() : '—', align: pw.TextAlign.center, bold: true, color: depth == 0 ? PdfColors.white : const PdfColor.fromInt(0xFF0F766E)),
          if (isWeightage) _cell(scoreLabel, align: pw.TextAlign.center, bold: true, color: depth == 0 ? PdfColors.white : _bannerBlue),
          _cell(pct != null ? '$pct%' : '—', align: pw.TextAlign.center, bold: true, color: depth == 0 ? PdfColors.white : _bannerBlue),
        ],
      ));
      var i = 1;
      for (final child in node.children) {
        walk(child, '$serial.$i', depth + 1);
        i++;
      }
      return;
    }

    // Still rendered when not yet scored (findingType/score fall back to
    // "—") — same fix as the web app's ReportIndexTable.jsx/exportExcel.js,
    // so a checkpoint that predates full scoring (e.g. one Skipped in an
    // otherwise-Completed batch) doesn't just vanish from the PDF.
    rows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: _lightBlue),
      children: [
        _cell(serial, color: _muted),
        _cell(node.name, color: _slate),
        _cell(node.findingType ?? '—', align: pw.TextAlign.center, color: _findingColor[node.findingType] ?? _muted, bold: true, size: 7.5),
        _cell(node.score != null ? node.score!.round().toString() : '—', align: pw.TextAlign.center, bold: true, color: _bannerBlue),
        if (isWeightage) _cell(leafWeightage(node, auditMaxScore).round().toString(), align: pw.TextAlign.center, bold: true, color: const PdfColor.fromInt(0xFF0F766E)),
        if (isWeightage) _cell(am.max > 0 ? '${am.achieved.round()}/${am.max.round()}' : '—', align: pw.TextAlign.center, bold: true, color: _bannerBlue),
        _cell('—', align: pw.TextAlign.center, color: PdfColors.grey400),
      ],
    ));
  }

  var i = 1;
  for (final node in section.tree) {
    walk(node, '$i', 0);
    i++;
  }

  final finalPct = grandMax > 0 ? (grandAchieved / grandMax * 100).round() : null;
  rows.add(pw.TableRow(
    decoration: const pw.BoxDecoration(color: _headerBlue),
    children: [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 6),
        child: pw.Container(
          alignment: pw.Alignment.center,
          child: pw.Text(finalRowLabel, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
        ),
      ),
      ...List.generate(headers.length - 3, (_) => pw.SizedBox()),
      _cell(grandMax > 0 ? '${grandAchieved.round()}/${grandMax.round()}' : '—', align: pw.TextAlign.center, bold: true, color: PdfColors.white),
      _cell(finalPct != null ? '$finalPct%' : '—', align: pw.TextAlign.center, bold: true, color: PdfColors.white),
    ],
  ));

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(section.label, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _headerBlue)),
      pw.SizedBox(height: 4),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        columnWidths: {
          0: const pw.FixedColumnWidth(24),
          1: const pw.FlexColumnWidth(3),
        },
        children: rows,
      ),
    ],
  );
}
