import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/audit_detail_model.dart';
import '../models/nc_model.dart';
import 'report_pdf_fonts.dart';
import 'report_sections.dart';

/// utils/report_pdf_builder.dart
/// ────────────────────────────────
/// Builds a real, structured PDF (selectable text/tables, not a rasterized
/// screenshot) for the mobile Reports screen — same section/index-table
/// shape as the web's printable Full Report (AuditFullReport.jsx +
/// Components/AuditReport/ReportIndexTable.jsx): header info, an Index &
/// Score Summary table per location, then a Detailed Audit Findings
/// section (client/src/utils/exportAuditReportToPdf.js#drawFindingNode) —
/// every checkpoint's own remark, evidence photos, and (for an NC finding)
/// its full response thread, same content the web PDF already carries.
/// This used to be summary-table-only on mobile, which is what read as
/// "the phone PDF isn't the same as the web one" — the numbers agreed but
/// none of the underlying evidence did.
const _headerBlue = PdfColor.fromInt(0xFF005A8E);
const _bannerBlue = PdfColor.fromInt(0xFF0077B6);
const _lightBlue = PdfColor.fromInt(0xFFE8F3FA);
const _slate = PdfColor.fromInt(0xFF334155);
const _muted = PdfColor.fromInt(0xFF64748B);
const _green = PdfColor.fromInt(0xFF16A34A);
const _red = PdfColor.fromInt(0xFFDC2626);

final _findingColor = {
  'Strong Compliance': const PdfColor.fromInt(0xFF16A34A),
  'Compliance': const PdfColor.fromInt(0xFF0EA5E9),
  'OFI': const PdfColor.fromInt(0xFFD97706),
  'NC': const PdfColor.fromInt(0xFFEF4444),
};

// Same short labels as the web's own FINDING_META_PDF
// (exportAuditReportToPdf.js) — "Raise NC" (not just "NC") matches what
// the web PDF's stat tile/pill actually says.
const _findingLabel = {
  'Strong Compliance': 'Strong',
  'Compliance': 'Compliant',
  'OFI': 'OFI',
  'NC': 'Raise NC',
};
const _findingSummaryOrder = ['Strong Compliance', 'Compliance', 'OFI', 'NC'];

String _fmtDate(DateTime? d) {
  if (d == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
}

String _fmtDateTime(DateTime? d) {
  if (d == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final ampm = d.hour >= 12 ? 'PM' : 'AM';
  return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}, $hour12:${d.minute.toString().padLeft(2, '0')} $ampm';
}

// ── Evidence photos — fetched once per report, keyed by URL, so a photo
// reused across a checkpoint AND its NC's response history (or across
// several zones of a combined report) isn't fetched twice. Best-effort:
// a failed fetch (bad URL, network blip, unrecognized image format) maps
// to null and renders as a placeholder box in _photoRow — never fails the
// whole PDF, same contract as the web's own fetchImageForPdf
// (exportAuditReportToPdf.js). ──────────────────────────────────────────
Set<String> _collectPhotoUrls(List<ReportSection> sections, Map<String, NcModel> ncsById) {
  final urls = <String>{};
  void walk(ParameterNode node) {
    urls.addAll(node.photoUrls);
    if (node.findingType == 'NC' && node.ncId != null) {
      final nc = ncsById[node.ncId];
      if (nc != null) {
        for (final entry in nc.responseHistory) {
          urls.addAll(entry.photos);
        }
      }
    }
    for (final child in node.children) {
      walk(child);
    }
  }

  for (final section in sections) {
    for (final node in section.tree) {
      walk(node);
    }
  }
  return urls;
}

Future<Map<String, pw.MemoryImage?>> _fetchImages(Set<String> urls) async {
  final entries = await Future.wait(
    urls.map((url) async {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return MapEntry<String, pw.MemoryImage?>(url, null);
        return MapEntry<String, pw.MemoryImage?>(url, pw.MemoryImage(res.bodyBytes));
      } catch (_) {
        // Bad URL, network blip, or an image format the pdf package can't
        // decode — degrade to a placeholder box rather than failing the
        // whole report.
        return MapEntry<String, pw.MemoryImage?>(url, null);
      }
    }),
  );
  return Map.fromEntries(entries);
}

Future<Uint8List> buildReportPdf(AuditDetailModel audit) async {
  final doc = pw.Document(theme: await loadReportPdfTheme());
  final sections = buildReportSections(audit);
  final isWeightage = audit.scoringSystem == 'weightage';
  final overall = audit.scoreResult.percentage;
  final allScoredLeaves = sections.expand((s) => collectScoredLeaves(s.tree)).toList();
  final images = await _fetchImages(_collectPhotoUrls(sections, audit.ncsById));

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        _buildHeader(audit, overall),
        pw.SizedBox(height: 12),
        _buildStatTiles(overall?.round(), allScoredLeaves),
        pw.SizedBox(height: 16),
        for (final section in sections) ...[
          _buildSectionTable(section, isWeightage, audit.maxScore),
          pw.SizedBox(height: 16),
        ],
        if ((audit.finalAuditorRemark ?? '').isNotEmpty) ...[
          _buildRemark(audit.finalAuditorRemark!),
          pw.SizedBox(height: 16),
        ],
        _sectionHeading('DETAILED AUDIT FINDINGS'),
        pw.SizedBox(height: 8),
        for (final section in sections)
          ..._buildDetailedFindingsSection(section, audit.ncsById, images, isWeightage, audit.maxScore),
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
/// %, same rule every other multi-audit rollup in this app uses. Each
/// zone's own Detailed Audit Findings follow the same way, one after
/// another, labeled the same as that zone's own section table.
///
/// Takes whatever zones the caller hands it — reports_screen.dart's own
/// _downloadCombined prefers AuditsProvider.fetchBatchReport (the server's
/// combined GET /audits/batch/:batchId/report, every zone in the batch —
/// not just this employee's own) and only falls back to fetching one zone
/// at a time via fetchAuditReportDetail (this employee's own zones only)
/// if that request fails — a per-role "Final Report"/"Schedule Audit" menu
/// grant that varies by company setup (see audit.routes.js's
/// LIST_MENU_URLS), or a slow connection on the single heaviest request
/// this screen makes.
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
  final allScoredLeaves = <ParameterNode>[];
  // (owning zone, relabeled section) pairs, gathered in this first pass —
  // the Detailed Findings widgets for each are built in a second pass
  // below, once `images` has been fetched for every zone at once (a single
  // network round-trip covering the whole combined report, not one per
  // zone).
  final zoneSections = <(AuditDetailModel, ReportSection)>[];

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

      allScoredLeaves.addAll(leaves);
      zoneSections.add((zone, relabeled));
    }
  }

  final allPhotoUrls = <String>{};
  for (final pair in zoneSections) {
    allPhotoUrls.addAll(_collectPhotoUrls([pair.$2], pair.$1.ncsById));
  }
  final images = await _fetchImages(allPhotoUrls);
  final findingsWidgets = <pw.Widget>[
    for (final pair in zoneSections) ..._buildDetailedFindingsSection(pair.$2, pair.$1.ncsById, images, isWeightage, pair.$1.maxScore),
  ];

  final finalPct = grandMax > 0 ? (grandAchieved / grandMax * 100).round() : null;

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        _buildCombinedHeader(first, auditorNames.toList(), minStart, maxEnd, zones.length, finalPct),
        pw.SizedBox(height: 12),
        _buildStatTiles(finalPct, allScoredLeaves),
        pw.SizedBox(height: 16),
        ...sectionWidgets,
        _buildGrandFinalRow(grandAchieved, grandMax, finalPct),
        pw.SizedBox(height: 16),
        _sectionHeading('DETAILED AUDIT FINDINGS'),
        pw.SizedBox(height: 8),
        ...findingsWidgets,
      ],
    ),
  );

  return doc.save();
}

pw.Widget _sectionHeading(String text) => pw.Text(
      text,
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _headerBlue, letterSpacing: 0.5),
    );

// Score + Strong/Compliant/OFI/Raise-NC counts + Total Checks — same six
// values the web's stat tiles under the header show (exportAuditReportToPdf
// .js's `tiles` array), just laid out as a wrapping row of small boxes
// instead of jsPDF's fixed-width tile grid.
pw.Widget _buildStatTiles(int? overallPct, List<ParameterNode> scoredLeaves) {
  final counts = {for (final ft in _findingSummaryOrder) ft: 0};
  for (final leaf in scoredLeaves) {
    final ft = leaf.findingType;
    if (ft != null && counts.containsKey(ft)) counts[ft] = counts[ft]! + 1;
  }
  final scoreColor = overallPct == null
      ? _muted
      : overallPct >= 75
          ? _green
          : overallPct >= 50
              ? const PdfColor.fromInt(0xFFD97706)
              : _red;

  final tiles = <MapEntry<String, PdfColor>>[
    MapEntry(overallPct != null ? 'Score: $overallPct%' : 'Score: —', scoreColor),
    for (final ft in _findingSummaryOrder) MapEntry('${_findingLabel[ft]}: ${counts[ft]}', _findingColor[ft] ?? _muted),
    MapEntry('Total Checks: ${scoredLeaves.length}', _slate),
  ];

  return pw.Wrap(
    spacing: 8,
    runSpacing: 8,
    children: tiles
        .map(
          (t) => pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: pw.BoxDecoration(
              color: PdfColor(t.value.red, t.value.green, t.value.blue, 0.10),
              border: pw.Border.all(color: t.value, width: 0.6),
              borderRadius: pw.BorderRadius.circular(6),
            ),
            child: pw.Text(t.key, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: t.value)),
          ),
        )
        .toList(),
  );
}

// ── Detailed Audit Findings — one label heading per section (zone/
// location), then every checkpoint: group banners with an avg score +
// finding-count summary, and each leaf's own finding pill, score, remark,
// photos, and (for an NC) its full response thread. Mirrors
// exportAuditReportToPdf.js's drawFindingNode — ported to the `pdf`
// package's pw.Widget composition (auto-paginating via pw.MultiPage/
// pw.Wrap's own SpanningWidget support) rather than jsPDF's manual
// y-position/page-break bookkeeping, since that's a different drawing
// model entirely. ──────────────────────────────────────────────────────
List<pw.Widget> _buildDetailedFindingsSection(
  ReportSection section,
  Map<String, NcModel> ncsById,
  Map<String, pw.MemoryImage?> images,
  bool isWeightage,
  double? auditMaxScore,
) {
  final widgets = <pw.Widget>[
    pw.Text(section.label.toUpperCase(), style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _headerBlue)),
    pw.SizedBox(height: 4),
  ];
  var i = 1;
  for (final node in section.tree) {
    widgets.addAll(_buildFindingNode(node, '$i', 0, ncsById, images, isWeightage, auditMaxScore));
    i++;
  }
  widgets.add(pw.SizedBox(height: 14));
  return widgets;
}

List<pw.Widget> _buildFindingNode(
  ParameterNode node,
  String serial,
  int depth,
  Map<String, NcModel> ncsById,
  Map<String, pw.MemoryImage?> images,
  bool isWeightage,
  double? auditMaxScore,
) {
  if (!node.isLeaf) {
    final leaves = collectScoredLeaves([node]);
    final am = sumAchievedMax(leaves, isWeightage ? 'weightage' : 'normal', auditMaxScore);
    final pct = percentageOf(am);
    final counts = {for (final ft in _findingSummaryOrder) ft: leaves.where((l) => l.findingType == ft).length};

    final widgets = <pw.Widget>[
      pw.Container(
        margin: const pw.EdgeInsets.only(top: 6, bottom: 2),
        padding: pw.EdgeInsets.symmetric(horizontal: 10, vertical: depth == 0 ? 8 : 6),
        decoration: pw.BoxDecoration(
          color: depth == 0 ? _headerBlue : _lightBlue,
          borderRadius: pw.BorderRadius.circular(depth == 0 ? 6 : 4),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(
              child: pw.Text(
                '$serial  ${node.name}',
                style: pw.TextStyle(
                  fontSize: depth == 0 ? 10.5 : 9,
                  fontWeight: pw.FontWeight.bold,
                  color: depth == 0 ? PdfColors.white : _headerBlue,
                ),
              ),
            ),
            if (pct != null)
              pw.Text(
                '$pct%  (${am.achieved.round()}/${am.max.round()})',
                style: pw.TextStyle(fontSize: 8, color: depth == 0 ? PdfColors.white : _headerBlue),
              ),
          ],
        ),
      ),
    ];
    if (depth == 0 && leaves.isNotEmpty) {
      widgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(left: 10, top: 3, bottom: 3),
          child: pw.Text(
            _findingSummaryOrder.map((ft) => '${_findingLabel[ft]} ${counts[ft]}').join('   ·   '),
            style: pw.TextStyle(fontSize: 7.5, color: _muted),
          ),
        ),
      );
    }
    var i = 1;
    for (final child in node.children) {
      widgets.addAll(_buildFindingNode(child, '$serial.$i', depth + 1, ncsById, images, isWeightage, auditMaxScore));
      i++;
    }
    return widgets;
  }

  // Leaf checkpoint
  final indent = 10.0 + depth * 12;
  final widgets = <pw.Widget>[
    pw.Padding(
      padding: pw.EdgeInsets.only(left: indent, top: 5),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Expanded(
            child: pw.Text('$serial  ${node.name}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _slate)),
          ),
          if (node.findingType != null) ...[
            _findingPill(node.findingType!),
            if (node.score != null) ...[
              pw.SizedBox(width: 6),
              pw.Text('Score: ${node.score!.round()}', style: pw.TextStyle(fontSize: 7.5, color: _muted)),
            ],
          ] else
            pw.Text('Not scored yet', style: pw.TextStyle(fontSize: 7.5, fontStyle: pw.FontStyle.italic, color: PdfColors.grey400)),
        ],
      ),
    ),
  ];

  if ((node.remark ?? '').isNotEmpty) {
    widgets.add(
      pw.Padding(
        padding: pw.EdgeInsets.only(left: indent, top: 2),
        child: pw.Text(node.remark!, style: pw.TextStyle(fontSize: 8.5, fontStyle: pw.FontStyle.italic, color: _slate)),
      ),
    );
  }
  if (node.photoUrls.isNotEmpty) {
    widgets.add(
      pw.Padding(
        padding: pw.EdgeInsets.only(left: indent, top: 4),
        child: _photoRow(node.photoUrls, images),
      ),
    );
  }

  final nc = node.findingType == 'NC' && node.ncId != null ? ncsById[node.ncId] : null;
  if (nc != null) {
    widgets.add(
      pw.Padding(
        padding: pw.EdgeInsets.only(left: indent, top: 6),
        child: _buildNcThread(nc, images),
      ),
    );
  }

  widgets.add(pw.SizedBox(height: 4));
  return widgets;
}

pw.Widget _findingPill(String findingType) {
  final color = _findingColor[findingType] ?? _muted;
  final label = _findingLabel[findingType] ?? findingType;
  return pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: pw.BoxDecoration(
      color: PdfColor(color.red, color.green, color.blue, 0.14),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Text(label, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: color)),
  );
}

// Thumbnails in a wrapping row, page-break-aware via pw.Wrap's own
// SpanningWidget support (never splits mid-photo) — same idea as the
// web's own drawPhotoRow, just letting pw.MultiPage handle pagination
// instead of manually tracking a page cursor.
pw.Widget _photoRow(List<String> urls, Map<String, pw.MemoryImage?> images) {
  const size = 56.0;
  return pw.Wrap(
    spacing: 6,
    runSpacing: 6,
    children: urls.map((url) {
      final img = images[url];
      return pw.Container(
        width: size,
        height: size,
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey300),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: img != null
            ? pw.ClipRRect(
                horizontalRadius: 4,
                verticalRadius: 4,
                child: pw.Image(img, fit: pw.BoxFit.cover, width: size, height: size),
              )
            : pw.Text('photo', style: pw.TextStyle(fontSize: 6.5, color: _muted)),
      );
    }).toList(),
  );
}

List<MapEntry<String, String>> _ncResponseFields(NcResponseEntry entry) {
  final fields = <MapEntry<String, String>>[];
  void add(String label, String? value) {
    if (value != null && value.trim().isNotEmpty) fields.add(MapEntry(label, value));
  }

  add('Correction', entry.correctionAction);
  add('Root Cause', entry.rootCause);
  add('Corrective Action', entry.correctiveAction);
  add('Preventive Action', entry.preventiveAction);
  return fields;
}

// Full NC thread — id/status/severity/auditee/due date, then every
// response cycle's own correction/root-cause/corrective/preventive text,
// photos, and verification outcome. Mirrors drawFindingNode's own NC
// branch + RESPONSE_FIELD_LABELS in exportAuditReportToPdf.js field-for-
// field, so a checkpoint raised as an NC carries the same evidence trail
// on mobile as it already does on the web PDF.
pw.Widget _buildNcThread(NcModel nc, Map<String, pw.MemoryImage?> images) {
  final children = <pw.Widget>[
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text('NC ${nc.ncId}', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _findingColor['NC'] ?? _red)),
        pw.SizedBox(width: 6),
        pw.Expanded(
          child: pw.Text(
            '${nc.status}  ·  ${nc.severity}  ·  Against ${nc.auditee.name}  ·  Due ${_fmtDate(nc.targetDate)}',
            style: pw.TextStyle(fontSize: 7.5, color: _muted),
          ),
        ),
      ],
    ),
  ];

  for (final entry in nc.responseHistory) {
    final fields = _ncResponseFields(entry);
    children.add(
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 6, left: 12),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'NC${entry.cycle} Response — ${nc.auditee.name}   (${_fmtDateTime(entry.submittedAt)})',
              style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _slate),
            ),
            pw.SizedBox(height: 3),
            for (final field in fields)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 10, bottom: 2),
                child: pw.RichText(
                  text: pw.TextSpan(
                    children: [
                      pw.TextSpan(text: '${field.key}: ', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _slate)),
                      pw.TextSpan(text: field.value, style: pw.TextStyle(fontSize: 8, color: _slate)),
                    ],
                  ),
                ),
              ),
            if (entry.photos.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 10, top: 2),
                child: _photoRow(entry.photos, images),
              ),
            if (entry.verificationAction != null)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 10, top: 4),
                child: pw.Text(
                  entry.verificationNote != null && entry.verificationNote!.trim().isNotEmpty
                      ? 'Verified: ${entry.verificationAction}  — ${entry.verificationNote}'
                      : 'Verified: ${entry.verificationAction}',
                  style: pw.TextStyle(
                    fontSize: 7.5,
                    fontWeight: pw.FontWeight.bold,
                    color: entry.verificationAction == 'Accept' ? _green : _red,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  return pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(
      color: PdfColors.grey50,
      border: pw.Border.all(color: PdfColors.grey300),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: children),
  );
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
