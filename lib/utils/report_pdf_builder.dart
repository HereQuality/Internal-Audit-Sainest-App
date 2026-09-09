import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../models/audit_detail_model.dart';
import '../models/nc_model.dart';
import 'report_pdf_fonts.dart';
import 'report_sections.dart';

/// utils/report_pdf_builder.dart
/// ────────────────────────────────
/// Builds a real, structured PDF (selectable text/shapes, not a rasterized
/// screenshot) for the mobile Reports screen — a Dart port of the web
/// portal's own download, client/src/utils/exportAuditReportToPdf.js, laid
/// out block-for-block against it so the phone's PDF and the web's are the
/// same document:
///
///   header card (+ score ring) → stat tiles / "audit in progress" banner
///   → final auditor remark(s) → Parameter Score / Location-wise Score
///   charts → "Audit Index & Score Summary" table → "Detailed Audit
///   Findings" (group banners + per-checkpoint cards)
///
/// Colors, type sizes and labels come straight from the web's shared
/// drawing layer (client/src/utils/pdfWriter.js's `C` palette and
/// exportAuditReportToPdf.js's FINDING_META_PDF), mirrored in [_C] and
/// [_findingMeta] below — that pairing is what keeps the two exports from
/// silently drifting apart the way the previous mobile-only layout had.
///
/// Two deliberate differences from the web, both structural rather than
/// cosmetic (see [_barChart] and [_indexTableRows] for the full rationale
/// of each):
///
///  • The two report charts are always the bar layout, never the
///    radar/spider one the web shows for a handful of audit TYPES that
///    opt into it — this report spec doesn't carry audit.auditType, and
///    every number the spider draws is the same one the bar layout shows.
///    Drawn as real vector bars (a pw.Stack of positioned Containers/Text),
///    not a captured bitmap — this screen has no on-screen chart DOM node
///    to screenshot the way the web's html2canvas capture does.
///  • The index table's column header can reappear at the top of every
///    location's own row block, not just after a genuine page break —
///    the `pdf` package's Table has no colspan, so the full-width
///    location/SUBTOTAL/FINAL SCORE bands force one small repeat-header
///    Table per location rather than one Table for the whole thing.
///
/// The NC response thread this used to render is intentionally GONE — the
/// web dropped it on purpose (see exportAuditReportToPdf.js's own note: a
/// downloaded report records that an NC exists and who owns it, not the
/// back-and-forth of resolving it) and replaced it with the flat "NC
/// ASSIGNED" alert reproduced in [_leafCardWidgets].

// ── Palette — exact port of client/src/utils/pdfWriter.js's `C` ──────────
class _C {
  static const blue = PdfColor.fromInt(0xFF0077B6);
  static const blueDark = PdfColor.fromInt(0xFF005A8E);
  static const blueBg = PdfColor.fromInt(0xFFE8F3FA);
  static const blueBgLight = PdfColor.fromInt(0xFFF8FBFE);
  static const cardBg = PdfColor.fromInt(0xFFEFF9FF);
  static const cardBorder = PdfColor.fromInt(0xFFBAE6FD);
  static const ink = PdfColor.fromInt(0xFF0F172A);
  static const slate = PdfColor.fromInt(0xFF64748B);
  static const slateLight = PdfColor.fromInt(0xFF94A3B8);
  static const border = PdfColor.fromInt(0xFFEEF0F4);
  static const white = PdfColor.fromInt(0xFFFFFFFF);
  static const green = PdfColor.fromInt(0xFF16A34A);
  static const amber = PdfColor.fromInt(0xFFD97706);
  static const amberBg = PdfColor.fromInt(0xFFFEFBEB);
  static const amberBorder = PdfColor.fromInt(0xFFFDE68A);
  static const amberText = PdfColor.fromInt(0xFF92400E);
  static const red = PdfColor.fromInt(0xFFEF4444);
  static const teal = PdfColor.fromInt(0xFF0F766E);

  /// The depth-0 group banner's translucent-white-over-blueDark chip and
  /// score box, pre-blended flat (jsPDF has no alpha compositing, and a
  /// pw.BoxDecoration fill doesn't composite one either — same reason).
  static const bannerAccent = PdfColor.fromInt(0xFF2E78A2);

  /// Header card's no-logo badge fallback — the web's own
  /// gradient(135deg,#0077B6,#005A8E) tile (AuditFullReport.jsx),
  /// pre-blended flat the same way bannerAccent above is, and the exact
  /// value exportAuditReportToPdf.js's C.logoBadgeBg uses.
  static const logoBadgeBg = PdfColor.fromInt(0xFF0069A2);

  static const dotGreen = PdfColor.fromInt(0xFF86EFAC);
  static const dotBlue = PdfColor.fromInt(0xFFBFDBFE);
  static const dotAmber = PdfColor.fromInt(0xFFFDE68A);
  static const dotRed = PdfColor.fromInt(0xFFFCA5A5);

  /// Index-table "{location} SUBTOTAL" band (the web's literal [186,230,253]).
  static const subtotalBg = PdfColor.fromInt(0xFFBAE6FD);

  /// Leaf card header band when the checkpoint isn't scored yet.
  static const neutralBand = PdfColor.fromInt(0xFFF4F7FA);
}

/// One finding type's 4-tier soft palette + its two labels — the web's
/// FINDING_META_PDF (short `label`) and FINDING_LONG_LABEL (`longLabel`)
/// merged, since nothing here ever needs one without the other.
class _Tone {
  final PdfColor fg;
  final PdfColor bg;
  final PdfColor border;
  final PdfColor dot;
  final String label;
  final String longLabel;
  const _Tone({
    required this.fg,
    required this.bg,
    required this.border,
    required this.dot,
    required this.label,
    required this.longLabel,
  });
}

const _findingMeta = <String, _Tone>{
  'Strong Compliance': _Tone(
    fg: PdfColor.fromInt(0xFF059669),
    bg: PdfColor.fromInt(0xFFF0FDF4),
    border: PdfColor.fromInt(0xFFBBF7D0),
    dot: PdfColor.fromInt(0xFF059669),
    label: 'Strong',
    longLabel: 'STRONG COMPLIANCE',
  ),
  'Compliance': _Tone(
    fg: PdfColor.fromInt(0xFF005A8E),
    bg: PdfColor.fromInt(0xFFE8F3FA),
    border: PdfColor.fromInt(0xFFBAE6FD),
    dot: PdfColor.fromInt(0xFF0077B6),
    label: 'Compliant',
    longLabel: 'COMPLIANCE',
  ),
  'OFI': _Tone(
    fg: PdfColor.fromInt(0xFFD97706),
    bg: PdfColor.fromInt(0xFFFFFBEB),
    border: PdfColor.fromInt(0xFFFDE68A),
    dot: PdfColor.fromInt(0xFFD97706),
    label: 'OFI',
    longLabel: 'OFI',
  ),
  'NC': _Tone(
    fg: PdfColor.fromInt(0xFFDC2626),
    bg: PdfColor.fromInt(0xFFFFF8F8),
    border: PdfColor.fromInt(0xFFFECACA),
    dot: PdfColor.fromInt(0xFFDC2626),
    label: 'Raise NC',
    longLabel: 'NON-CONFORMANCE',
  ),
};

const _findingSummaryOrder = ['Strong Compliance', 'Compliance', 'OFI', 'NC'];
const _dotColors = [_C.dotGreen, _C.dotBlue, _C.dotAmber, _C.dotRed];

// A4 portrait at the web's own 42pt margin (pdfWriter.js's Writer#margin),
// so a block that fills the content width lands at the same measure here
// as it does there.
const _pageMargin = 42.0;
const _contentWidth = 595.276 - _pageMargin * 2;
const _usablePageHeight = 841.89 - _pageMargin * 2;

String _fmtDate(DateTime? d) {
  if (d == null) return '—';
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]} ${d.year}';
}

/// Whole number when it is one — a checkpoint scored 7 should read "7",
/// not "7.0", and one scored 7.5 shouldn't be rounded away to "8".
String _num(num? v) {
  if (v == null) return '—';
  final d = v.toDouble();
  return d == d.roundToDouble() ? d.round().toString() : d.toStringAsFixed(1);
}

PdfColor _scoreColor(int? pct) {
  if (pct == null) return _C.slate;
  if (pct >= 75) return _C.green;
  if (pct >= 50) return _C.amber;
  return _C.red;
}

// ── The report as the renderer needs it — the Dart equivalent of the
// options object AuditFullReport.jsx hands exportAuditReportToPdf. Both
// public entry points below build one of these and hand it to [_render],
// so a single-audit and a combined-batch download can't drift apart in
// layout the way two separate builders did. ─────────────────────────────
class _SectionSpec {
  final String label;
  final List<ParameterNode> tree;

  /// Per-section rather than per-report: a combined batch's zones are
  /// separate audit documents that can each carry their own maxScore, and
  /// scoring one zone's leaves against another's would quietly change its
  /// numbers. A single-audit report just repeats the same value.
  final double? maxScore;

  const _SectionSpec({required this.label, required this.tree, this.maxScore});
}

class _ReportSpec {
  final String reportTitle;
  final List<(String, String)> headerFields;
  final List<_SectionSpec> sections;
  final Map<String, NcModel> ncsById;
  final String scoringSystem;
  final bool isFinalReport;
  final String? finalAuditorRemark;
  final List<(String, String)>? zoneRemarks;

  const _ReportSpec({
    required this.reportTitle,
    required this.headerFields,
    required this.sections,
    required this.ncsById,
    required this.scoringSystem,
    required this.isFinalReport,
    this.finalAuditorRemark,
    this.zoneRemarks,
  });

  bool get isWeightage => scoringSystem == 'weightage';

  /// The 0-N scale a group banner's "Avg Score" is normalized onto —
  /// AuditFullReport.jsx#scoreScale, per section since maxScore is.
  double scaleFor(_SectionSpec s) => isWeightage ? (s.maxScore ?? 10) : 10;
}

// ── Evidence photos — fetched once per report, keyed by URL, so a photo
// reused across zones of a combined report isn't fetched twice.
// Best-effort: a failed fetch maps to null and renders as a placeholder
// box, never failing the whole PDF (same contract as the web's own
// fetchImageForPdf). Only leaf evidence is collected — the NC response
// thread, whose photos this used to gather too, is no longer drawn. ─────
Set<String> _collectPhotoUrls(List<_SectionSpec> sections) {
  final urls = <String>{};
  void walk(ParameterNode node) {
    urls.addAll(node.photoUrls);
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

// ── Company name + logo for the header card — the web report reads both
// from its own useCompany() hook (company.name / company.logo); there's
// no company model on mobile, so this is a direct best-effort read of the
// same public endpoint (both fields come back in one response, so one
// fetch resolves both). Cached for the app session, but ONLY on success:
// a network blip during one download shouldn't leave every later report
// in the session missing the line (same reasoning as report_pdf_fonts.
// dart's own cache). A failure, an unexpected payload, or a blank
// name/logo all fall through to null and the header falls back
// accordingly (name: the line is omitted; logo: the initials badge). ────
String? _cachedCompanyName;
String? _cachedCompanyLogoUrl;
bool _companyResolved = false;

Future<(String?, String?)> _fetchCompanyInfo() async {
  if (_companyResolved) return (_cachedCompanyName, _cachedCompanyLogoUrl);
  try {
    final res = await DioClient.instance.dio.get(ApiConstants.companyDetails);
    final body = res.data;
    if (body is Map && body['data'] is Map) {
      final data = body['data'] as Map;
      final name = data['name'];
      if (name is String && name.trim().isNotEmpty) {
        _cachedCompanyName = name.trim();
      }
      final logo = data['logo'];
      if (logo is String && logo.trim().isNotEmpty) {
        _cachedCompanyLogoUrl = logo.trim();
      }
    }
    _companyResolved = true;
  } catch (_) {
    // Leave _companyResolved false so the next report retries.
  }
  return (_cachedCompanyName, _cachedCompanyLogoUrl);
}

// pw.MemoryImage does NOT decode eagerly — it just wraps the raw bytes,
// and only actually decodes them the first time the document is PAINTED
// (pw.Image -> ImageProvider.resolve -> PdfImage.file -> package:image's
// own decodeImage), which happens deep inside doc.save(), nowhere near
// either fetch function's own try/catch below. So a byte stream this
// package's decoder can't handle — confirmed in practice against a real
// company logo: a lossless-VP8L WebP the `image` package's WebP decoder
// (pinned at 4.3.0, per pubspec.yaml) throws a RangeError on — used to
// sail straight past "fetched OK, wrapped in a MemoryImage" and then blow
// up doc.save() itself, which reports_screen.dart's caller can only see
// as the whole report failing to generate, with no indication an image
// was the cause. Every logo hits this same decoder: uploadToCloudinary
// (server/controllers/company.controller.js) always stores a logo as
// `format: "webp"`, and Cloudinary's own "auto:good" encoder picks
// lossless VP8L for a logo's typical flat colors + transparency.
//
// Rather than pre-decode-and-swallow the exception (which only turns a
// crash into a MISSING logo — decodeImage() still failed, there's nothing
// to hand pw.MemoryImage), every webp is routed around package:image's
// WebP decoder entirely and decoded via Flutter's own Skia-backed one
// (dart:ui) instead — the same one Image.network/the OS image picker
// already rely on elsewhere in the app, with full WebP coverage — then
// re-encoded to PNG bytes so both the immediate fetch-time check below
// and doc.save()'s later paint-time decode (still package:image, just now
// handed a PNG it has no trouble with) succeed. Every other format
// (JPEG/PNG evidence photos, effectively never webp) keeps using
// package:image directly and unmodified, both because it already works
// for them and to avoid inflating a many-photo report's file size by
// re-encoding every JPEG as lossless PNG.
bool _looksLikeWebp(Uint8List bytes) =>
    bytes.length >= 12 &&
    // "RIFF" container magic (bytes 0-3; bytes 4-7 are a file-size field)…
    bytes[0] == 0x52 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x46 &&
    // …holding a "WEBP" payload (bytes 8-11).
    bytes[8] == 0x57 &&
    bytes[9] == 0x45 &&
    bytes[10] == 0x42 &&
    bytes[11] == 0x50;

Future<pw.MemoryImage?> _decodeIfSupported(Uint8List bytes) async {
  if (!_looksLikeWebp(bytes)) {
    try {
      if (img.decodeImage(bytes) != null) return pw.MemoryImage(bytes);
    } catch (_) {
      // fall through to the Skia decode below
    }
  }
  // pw.MemoryImage does NOT decode eagerly — it just wraps the raw bytes,
  // and only actually decodes them the first time the document is
  // PAINTED (pw.Image -> ImageProvider.resolve -> PdfImage.file ->
  // package:image's own decodeImage), deep inside doc.save(). Re-encoding
  // to PNG here, up front, is what keeps that later decode — which still
  // goes through the same unreliable package:image WebP path this
  // function exists to route around — from ever seeing the original webp
  // bytes at all.
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return png == null ? null : pw.MemoryImage(png.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

// Best-effort fetch of the logo image itself, same null-on-failure
// contract as _fetchImages below (a bad URL, a network blip, or a format
// the pdf package can't decode all degrade to the initials-badge
// fallback rather than failing the whole report).
Future<pw.MemoryImage?> _fetchCompanyLogoImage(String? url) async {
  if (url == null) return null;
  try {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    return await _decodeIfSupported(res.bodyBytes);
  } catch (_) {
    return null;
  }
}

Future<Map<String, pw.MemoryImage?>> _fetchImages(Set<String> urls) async {
  final entries = await Future.wait(
    urls.map((url) async {
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) return MapEntry<String, pw.MemoryImage?>(url, null);
        return MapEntry<String, pw.MemoryImage?>(url, await _decodeIfSupported(res.bodyBytes));
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

/// One completed audit — the mobile counterpart of the web Final Report
/// page's own "Download PDF".
Future<Uint8List> buildReportPdf(AuditDetailModel audit) async {
  final sections = buildReportSections(
    audit,
  ).map((s) => _SectionSpec(label: s.label, tree: s.tree, maxScore: audit.maxScore)).toList();

  return _render(
    _ReportSpec(
      reportTitle: audit.title,
      headerFields: [
        ('Auditor', audit.auditorNames.isNotEmpty ? audit.auditorNames.join(', ') : '—'),
        // Skipped entirely for a self-audit, same as the web's own
        // headerFields (there's no separate auditee to name).
        if (!audit.isSelfAudit)
          (
            'Auditee',
            audit.auditeeNames.isNotEmpty
                ? audit.auditeeNames.join(', ')
                : ((audit.auditeeName ?? '').isNotEmpty ? audit.auditeeName! : '—'),
          ),
        ('Start Date', _fmtDate(audit.scheduledDate)),
        ('End Date', _fmtDate(audit.scheduledEndDate ?? audit.completedDate)),
        ('Status', audit.status),
        ('Scoring', audit.scoringSystem == 'weightage' ? 'Weightage Average' : 'Normal Average'),
      ],
      sections: sections,
      ncsById: audit.ncsById,
      scoringSystem: audit.scoringSystem,
      isFinalReport: audit.status == 'Completed',
      finalAuditorRemark: (audit.finalAuditorRemark ?? '').isNotEmpty ? audit.finalAuditorRemark : null,
    ),
  );
}

/// buildCombinedReportPdf — one PDF spanning several completed zones of the
/// SAME multi-zone batch (see AuditModel.scheduleBatchId), the mobile
/// counterpart of a batch's combined "Show Report" on the web. Each zone
/// becomes its own labeled section: its own block of index-table rows
/// ending in a "{zone} SUBTOTAL" band, and its own Detailed Audit Findings
/// run — then one true FINAL SCORE row combines every zone by summing
/// achieved/max across the whole group (never averaging each zone's own %,
/// same rule every other multi-audit rollup in this app uses).
///
/// Takes whatever zones the caller hands it — reports_screen.dart's own
/// _downloadCombined prefers AuditsProvider.fetchBatchReport (the server's
/// combined GET /audits/batch/:batchId/report, every zone in the batch —
/// not just this employee's own) and only falls back to fetching one zone
/// at a time via fetchAuditReportDetail (this employee's own zones only)
/// if that request fails.
Future<Uint8List> buildCombinedReportPdf(List<AuditDetailModel> zones) async {
  if (zones.isEmpty) {
    return pw.Document(theme: await loadReportPdfTheme()).save();
  }
  final first = zones.first;

  final auditorNames = <String>{};
  final auditeeNames = <String>{};
  final ncsById = <String, NcModel>{};
  final sections = <_SectionSpec>[];
  final zoneRemarks = <(String, String)>[];
  DateTime? minStart;
  DateTime? maxEnd;

  for (final zone in zones) {
    auditorNames.addAll(zone.auditorNames);
    if (!zone.isSelfAudit) {
      auditeeNames.addAll(zone.auditeeNames);
      if (zone.auditeeNames.isEmpty && (zone.auditeeName ?? '').isNotEmpty) {
        auditeeNames.add(zone.auditeeName!);
      }
    }
    ncsById.addAll(zone.ncsById);

    final zoneStart = zone.scheduledDate;
    if (zoneStart != null && (minStart == null || zoneStart.isBefore(minStart))) {
      minStart = zoneStart;
    }
    final zoneEnd = zone.scheduledEndDate ?? zone.completedDate;
    if (zoneEnd != null && (maxEnd == null || zoneEnd.isAfter(maxEnd))) {
      maxEnd = zoneEnd;
    }

    // Every section of a zone is relabeled to that ZONE (not to the
    // shared batch title, and not to a per-location sub-label) so the
    // index table's subtotal bands and the findings headings both read as
    // one block per zone, the way the web's combined view does.
    final zoneLabel = zone.locationLabels.isNotEmpty
        ? zone.locationLabels.map((l) => l.display).join(', ')
        : zone.title;
    for (final section in buildReportSections(zone)) {
      sections.add(_SectionSpec(label: zoneLabel, tree: section.tree, maxScore: zone.maxScore));
    }
    if ((zone.finalAuditorRemark ?? '').isNotEmpty) {
      zoneRemarks.add((zoneLabel, zone.finalAuditorRemark!));
    }
  }

  return _render(
    _ReportSpec(
      reportTitle: first.title,
      headerFields: [
        ('Auditor', auditorNames.isNotEmpty ? auditorNames.join(', ') : '—'),
        if (auditeeNames.isNotEmpty) ('Auditee', auditeeNames.join(', ')),
        ('Start Date', _fmtDate(minStart)),
        ('End Date', _fmtDate(maxEnd)),
        ('Status', first.status),
        ('Scoring', first.scoringSystem == 'weightage' ? 'Weightage Average' : 'Normal Average'),
      ],
      sections: sections,
      ncsById: ncsById,
      scoringSystem: first.scoringSystem,
      isFinalReport: zones.every((z) => z.status == 'Completed'),
      zoneRemarks: zoneRemarks.isNotEmpty ? zoneRemarks : null,
    ),
  );
}

// ── Renderer — the block order below is exportAuditReportToPdf.js's own
// top-level body, one for one. ─────────────────────────────────────────
Future<Uint8List> _render(_ReportSpec spec) async {
  final doc = pw.Document(theme: await loadReportPdfTheme());
  final images = await _fetchImages(_collectPhotoUrls(spec.sections));
  final (companyName, companyLogoUrl) = await _fetchCompanyInfo();
  final companyLogo = await _fetchCompanyLogoImage(companyLogoUrl);

  // RAW (unrounded) per-leaf contributions summed across every section
  // FIRST, rounded exactly once at the very end — mirrors the web's own
  // header-ring/stat-tile computation (exportAuditReportToPdf.js: one
  // flatMap of every leaf from every section, fed into ONE sumAchievedMax
  // call). Summing already-rounded per-section sub-totals instead (as
  // this used to) can disagree with that: rounding isn't distributive
  // over addition, so "round each section then sum" and "sum raw then
  // round once" can land on different numbers (and, right at a 50%/75%
  // threshold, a different color) for the exact same underlying scores.
  // See [rawAchievedMax]'s own doc comment. Deliberately NOT the same
  // grand total the index table's own FINAL SCORE row below uses — that
  // one rounds per TOP-LEVEL NODE then sums (to agree with its own
  // SUBTOTAL rows), matching the web's own two genuinely different
  // aggregation granularities for these two displayed numbers.
  var rawAchieved = 0.0;
  var rawMax = 0.0;
  var scoredCount = 0;
  final counts = {for (final ft in _findingSummaryOrder) ft: 0};
  for (final section in spec.sections) {
    final leaves = collectScoredLeaves(section.tree);
    final am = rawAchievedMax(leaves, spec.scoringSystem, section.maxScore);
    rawAchieved += am.achieved;
    rawMax += am.max;
    scoredCount += leaves.length;
    for (final leaf in leaves) {
      final ft = leaf.findingType;
      if (ft != null && counts.containsKey(ft)) counts[ft] = counts[ft]! + 1;
    }
  }
  final achieved = rawAchieved.round();
  final max = rawMax.round();
  final overallPct = max > 0 ? (achieved / max * 100).round() : null;
  final scoreColor = _scoreColor(overallPct);

  final hasRemark = spec.finalAuditorRemark != null || (spec.zoneRemarks?.isNotEmpty ?? false);
  final paramChartData = _parameterChartData(spec.sections);
  final locationChartData = _locationChartData(spec.sections, spec.scoringSystem);

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(_pageMargin),
      build: (context) => [
        _headerCard(spec, companyName, companyLogo, overallPct, scoreColor),
        pw.SizedBox(height: 14),
        if (spec.isFinalReport && scoredCount > 0)
          _statTiles(overallPct, scoreColor, counts, scoredCount)
        else
          _partialBanner(),
        pw.SizedBox(height: 14),
        if (hasRemark) ...[_finalRemark(spec), pw.SizedBox(height: 14)],
        if (paramChartData.isNotEmpty) ...[
          _chartCard('Parameter Score', _barChart(paramChartData)),
          pw.SizedBox(height: 14),
        ],
        if (locationChartData.isNotEmpty) ...[
          _chartCard(
            'Location-wise Score',
            _barChart(locationChartData, referenceValue: overallPct?.toDouble(), referenceColor: scoreColor),
          ),
          pw.SizedBox(height: 14),
        ],
        ..._headingGluedToFirst(_sectionHeading('Audit Index & Score Summary'), 10, _indexTableRows(spec)),
        pw.SizedBox(height: 14),
        ..._headingGluedToFirst(_sectionHeading('Detailed Audit Findings'), 10, [
          for (final section in spec.sections) ..._findingsForSection(section, spec, images),
        ]),
      ],
    ),
  );

  return doc.save();
}

// Glues `heading` to the very first widget of `body` into one Inseparable
// block — a bare pw.Text heading is otherwise just another line
// pw.MultiPage can break straight after, landing it alone at the bottom
// of a page with whatever it introduces only starting once the reader
// turns to the next one. `body.first` is already independently atomic in
// every caller here (a table's own header row, a finding group's own
// banner, a leaf's own card — each already wrapped in its own
// Inseparable), so nesting it inside this one is safe, the same
// established pattern the leaf/finding-node code already documents
// elsewhere in this file. Everything after `body.first` stays flat and
// individually breakable, same as before — only the heading itself was
// ever at risk of separating from its content.
List<pw.Widget> _headingGluedToFirst(pw.Widget heading, double gap, List<pw.Widget> body) {
  if (body.isEmpty) return [heading];
  return [
    pw.Inseparable(
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          heading,
          pw.SizedBox(height: gap),
          body.first,
        ],
      ),
    ),
    ...body.skip(1),
  ];
}

pw.Widget _sectionHeading(String text) => pw.Text(
  text,
  style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _C.blueDark),
);

// ── Header card — "INTERNAL AUDIT REPORT" eyebrow, title, optional company
// name, then every header field as ONE wrapped run of "LABEL: value"
// (the web joins them with 5 spaces and lets the line wrap, rather than a
// fixed 2-line cap that used to silently drop trailing fields), with the
// score ring pinned right. ─────────────────────────────────────────────
// Company initials for the badge's no-logo fallback — same rule the web's
// on-screen badge uses (AuditFullReport.jsx): first letter of each of the
// first 2 words of the company name, or "AU" with no company name.
String _companyInitials(String? companyName) {
  final trimmed = (companyName ?? '').trim();
  final source = trimmed.isNotEmpty ? trimmed : 'AU';
  return source.split(RegExp(r'\s+')).take(2).map((w) => w.isNotEmpty ? w[0] : '').join().toUpperCase();
}

const _logoBadgeSize = 40.0;

// The on-screen header's rounded badge (AuditFullReport.jsx) — the
// company's uploaded logo on a white tile, or (no logo, or it failed to
// fetch) a solid tile with the company's initials, mirrored in
// exportAuditReportToPdf.js's own drawLogoBadge.
pw.Widget _logoBadge(pw.MemoryImage? logo, String? companyName) {
  if (logo != null) {
    // Explicit width/height on the Image itself, not just its Container —
    // an unsized pw.Image inside a centered, alignment-only parent gets
    // unbounded/NaN constraints in this package's layout model (unlike
    // real Flutter), which throws mid-render instead of mid-build, so it
    // surfaces on the phone as a plain "Could not generate this report"
    // with no further detail. _photoGrid below already gets this right —
    // same fix, applied here too.
    const inner = _logoBadgeSize - 8; // 4pt padding each side
    return pw.Container(
      width: _logoBadgeSize,
      height: _logoBadgeSize,
      alignment: pw.Alignment.center,
      decoration: pw.BoxDecoration(color: _C.white, borderRadius: pw.BorderRadius.circular(10)),
      child: pw.Image(logo, fit: pw.BoxFit.contain, width: inner, height: inner),
    );
  }
  return pw.Container(
    width: _logoBadgeSize,
    height: _logoBadgeSize,
    alignment: pw.Alignment.center,
    decoration: pw.BoxDecoration(color: _C.logoBadgeBg, borderRadius: pw.BorderRadius.circular(10)),
    child: pw.Text(
      _companyInitials(companyName),
      style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: _C.white),
    ),
  );
}

pw.Widget _headerCard(
  _ReportSpec spec,
  String? companyName,
  pw.MemoryImage? companyLogo,
  int? overallPct,
  PdfColor scoreColor,
) {
  // A non-breaking space (String.fromCharCode(160), never a plain " ")
  // glues every label's own words together, and glues the label to the
  // colon right after it -- the pdf package wraps a pw.Text on ANY plain
  // space, so a two-word label like "End Date" could otherwise break
  // mid-label ("...END" / "DATE: 03 Sep 2026") whenever the line-width
  // limit happened to fall between the two words. A value's OWN spaces
  // (e.g. a long Auditor list of several names) are left as normal,
  // breakable spaces on purpose -- that list still needs to wrap freely
  // between names, just never mid-label. Mirrors the same fix in the
  // web export, client/src/utils/exportAuditReportToPdf.js's own
  // drawHeaderCard.
  final nbsp = String.fromCharCode(160);
  String fieldChunk((String, String) f) => '${f.$1.toUpperCase().replaceAll(RegExp(r'\s+'), nbsp)}:$nbsp${f.$2}';

  // Start Date and End Date read as a pair — same rule the web's own
  // drawHeaderCard applies (glue them into one chunk so they don't land
  // on two separate wrapped lines with nothing to visually connect them).
  // The web has to hand-measure whether the glued pair fits before
  // committing to it (jsPDF has no flex/wrap layout of its own); pw.Wrap
  // does that same "does this chunk fit the current line, else start a
  // new one" natively, so an oversized pair just reflows onto its own
  // line automatically, no measurement needed.
  final fieldChunks = <String>[];
  final fields = spec.headerFields;
  for (var i = 0; i < fields.length; i++) {
    if (fields[i].$1 == 'Start Date' && i + 1 < fields.length && fields[i + 1].$1 == 'End Date') {
      fieldChunks.add('${fieldChunk(fields[i])}$nbsp$nbsp$nbsp${fieldChunk(fields[i + 1])}');
      i++;
    } else {
      fieldChunks.add(fieldChunk(fields[i]));
    }
  }

  return pw.Inseparable(
    child: pw.Container(
      decoration: pw.BoxDecoration(
        color: _C.cardBg,
        border: pw.Border.all(color: _C.cardBorder, width: 1),
        borderRadius: pw.BorderRadius.circular(12),
      ),
      padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          _logoBadge(companyLogo, companyName),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'INTERNAL AUDIT REPORT',
                  style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _C.blue),
                ),
                pw.SizedBox(height: 7),
                pw.Text(
                  spec.reportTitle.isNotEmpty ? spec.reportTitle : 'Audit Report',
                  style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold, color: _C.ink),
                ),
                if ((companyName ?? '').isNotEmpty) ...[
                  pw.SizedBox(height: 6),
                  pw.Text(
                    companyName!,
                    style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _C.blue),
                  ),
                ],
                pw.SizedBox(height: 11),
                pw.Wrap(
                  spacing: 14,
                  runSpacing: 4,
                  children: [
                    for (final c in fieldChunks) pw.Text(c, style: const pw.TextStyle(fontSize: 8, color: _C.ink)),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 16),
          pw.Container(
            width: 68,
            height: 68,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              shape: pw.BoxShape.circle,
              color: _C.white,
              border: pw.Border.all(color: scoreColor, width: 3),
            ),
            child: pw.Column(
              mainAxisAlignment: pw.MainAxisAlignment.center,
              children: [
                pw.Text(
                  overallPct != null ? '$overallPct%' : '—',
                  style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: scoreColor),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  'SCORE',
                  style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: _C.slate),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// Score + one tile per finding type + Total Checks, each a bordered box
// with a colored top rule, a big centered value and a small caption —
// pdfWriter.js#drawStatTiles.
pw.Widget _statTiles(int? overallPct, PdfColor scoreColor, Map<String, int> counts, int scoredCount) {
  final tiles = <(String, String, PdfColor)>[
    (overallPct != null ? '$overallPct%' : '—', 'Score', scoreColor),
    for (final ft in _findingSummaryOrder) ('${counts[ft] ?? 0}', _findingMeta[ft]!.label, _findingMeta[ft]!.fg),
    ('$scoredCount', 'Total Checks', _C.slate),
  ];

  return pw.Inseparable(
    child: pw.Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) pw.SizedBox(width: 8),
          pw.Expanded(
            child: pw.Container(
              height: 56,
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: _C.border, width: 1),
                borderRadius: pw.BorderRadius.circular(8),
              ),
              child: pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Container(
                    height: 3,
                    decoration: pw.BoxDecoration(
                      color: tiles[i].$3,
                      borderRadius: const pw.BorderRadius.only(
                        topLeft: pw.Radius.circular(8),
                        topRight: pw.Radius.circular(8),
                      ),
                    ),
                  ),
                  pw.SizedBox(height: 13),
                  pw.Text(
                    tiles[i].$1,
                    style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: tiles[i].$3),
                  ),
                  pw.SizedBox(height: 5),
                  pw.Text(
                    tiles[i].$2.toUpperCase(),
                    maxLines: 1,
                    overflow: pw.TextOverflow.clip,
                    style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _C.slate),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Shown instead of the stat tiles while an audit is still in progress —
/// the same amber left-ruled note the web draws, so a partial download is
/// never mistaken for a final score.
pw.Widget _partialBanner() => pw.Inseparable(
  child: pw.Container(
    width: double.infinity,
    decoration: const pw.BoxDecoration(
      color: _C.amberBg,
      border: pw.Border(left: pw.BorderSide(color: _C.amberBorder, width: 3)),
    ),
    padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: pw.Text(
      'Audit in progress — this is a partial view. The score and finding breakdown are only final once every checkpoint is scored.',
      style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: _C.amberText, lineSpacing: 2.7),
    ),
  ),
);

// Single-audit / one-zone view shows one remark; a combined batch shows
// one per zone that has its own — the same split the web's on-screen
// remark card(s) and its PDF both use.
pw.Widget _finalRemark(_ReportSpec spec) {
  final zoneRemarks = spec.zoneRemarks;
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        zoneRemarks != null && zoneRemarks.isNotEmpty ? 'FINAL AUDITOR REMARKS' : 'FINAL AUDITOR REMARK',
        style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _C.slate),
      ),
      pw.SizedBox(height: 6),
      if (spec.finalAuditorRemark != null)
        pw.Text(spec.finalAuditorRemark!, style: const pw.TextStyle(fontSize: 9, color: _C.ink, lineSpacing: 2.7))
      else
        for (var i = 0; i < zoneRemarks!.length; i++) ...[
          if (i > 0) pw.SizedBox(height: 6),
          pw.Text(
            zoneRemarks[i].$1,
            style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: _C.blueDark),
          ),
          pw.SizedBox(height: 3),
          pw.Text(zoneRemarks[i].$2, style: const pw.TextStyle(fontSize: 9, color: _C.ink, lineSpacing: 2.7)),
        ],
    ],
  );
}

// ── Report charts — Parameter Score / Location-wise Score ───────────────
// Dart port of AuditFullReport.jsx's buildParameterAverageData /
// buildLocationScoreData (same "average per LOCATION, then average those
// per-location numbers" / "sum-then-divide per section" rules the
// on-screen report and the web's own PDF/Word downloads already use) —
// drawn as real vector bars rather than a captured bitmap, since this
// screen has no on-screen chart DOM node to screenshot the way the web's
// html2canvas capture does.
//
// Always the bar layout, never the radar/spider one the web shows for a
// handful of audit TYPES that opt into it (AuditTypeMaster.jsx's
// parameterChartType) — this report spec doesn't carry audit.auditType,
// and every number a spider draws is the exact same one the bar layout
// below shows, so this still covers every audit's data, just always as
// bars.
const _chartBarColor = PdfColor.fromInt(0xFF2A78D6); // web's CHART_COLOR
const _horizontalBarThreshold = 10;

double? _leafRatio(ParameterNode leaf, double? auditMaxScore) {
  if (leaf.findingType == null) return null;
  if (leaf.findingType == 'Strong Compliance' || leaf.findingType == 'Compliance') return 1;
  final max = leafMax(leaf, auditMaxScore);
  return ((leaf.score ?? 0) / max).clamp(0.0, 1.0);
}

List<(String, int)> _parameterChartData(List<_SectionSpec> sections) {
  final axisNames = <String>[];
  final seen = <String>{};
  for (final section in sections) {
    for (final top in section.tree) {
      if (seen.add(top.name)) axisNames.add(top.name);
    }
  }
  final out = <(String, int)>[];
  for (final axisName in axisNames) {
    final perLocationAverages = <double>[];
    for (final section in sections) {
      ParameterNode? top;
      for (final n in section.tree) {
        if (n.name == axisName) {
          top = n;
          break;
        }
      }
      if (top == null) continue;
      final ratios = collectScoredLeaves([
        top,
      ]).map((l) => _leafRatio(l, section.maxScore)).whereType<double>().toList();
      if (ratios.isNotEmpty) perLocationAverages.add(ratios.reduce((a, b) => a + b) / ratios.length);
    }
    if (perLocationAverages.isEmpty) continue;
    final avg = perLocationAverages.reduce((a, b) => a + b) / perLocationAverages.length;
    out.add((axisName, (avg * 100).round()));
  }
  return out;
}

List<(String, int)> _locationChartData(List<_SectionSpec> sections, String scoringSystem) {
  final out = <(String, int)>[];
  for (var i = 0; i < sections.length; i++) {
    final section = sections[i];
    final leaves = collectScoredLeaves(section.tree);
    if (leaves.isEmpty) continue;
    final pct = percentageOf(sumAchievedMax(leaves, scoringSystem, section.maxScore));
    if (pct != null) out.add((section.label.isNotEmpty ? section.label : 'Location ${i + 1}', pct));
  }
  return out;
}

pw.Widget _chartCard(String title, pw.Widget chart) => pw.Inseparable(
  child: pw.Container(
    width: double.infinity,
    padding: const pw.EdgeInsets.fromLTRB(12, 10, 12, 14),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: _C.border, width: 1),
      borderRadius: pw.BorderRadius.circular(10),
    ),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title.toUpperCase(),
          style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _C.slate),
        ),
        pw.SizedBox(height: 10),
        chart,
      ],
    ),
  ),
);

pw.Widget _chartLabel(String text, {bool bold = false, double size = 7.5, PdfColor color = _C.slate}) => pw.Text(
  text,
  maxLines: 2,
  textAlign: pw.TextAlign.center,
  overflow: pw.TextOverflow.clip,
  style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color),
);

// Single-series 0-100% bar chart — one bar per category, an optional
// dashed reference line, and (past _horizontalBarThreshold categories, or
// long names past 5) a horizontal/list layout instead of vertical
// columns — same "too many/too long labels" switch ScoreBarChart makes
// on the web, just without the diagonal-rotated-label middle ground a
// canvas-free widget tree can't easily draw.
pw.Widget _barChart(
  List<(String label, int value)> data, {
  double? referenceValue,
  PdfColor referenceColor = _chartBarColor,
}) {
  final width = _contentWidth - 24;
  final longest = data.fold<int>(0, (m, d) => math.max(m, d.$1.length));
  final horizontal = data.length > _horizontalBarThreshold || (data.length > 5 && longest > 16);
  final refPct = referenceValue == null ? null : referenceValue.clamp(0, 100) / 100;

  if (horizontal) {
    const rowH = 22.0;
    final height = data.length * rowH;
    final labelW = math.min(150.0, math.max(60.0, longest * 4.3 + 10));
    const valueW = 32.0;
    final plotW = width - labelW - valueW - 8;
    return pw.SizedBox(
      width: width,
      height: height,
      child: pw.Stack(
        children: [
          for (var i = 0; i < data.length; i++) ...[
            pw.Positioned(
              left: 0,
              top: i * rowH,
              child: pw.SizedBox(
                width: labelW,
                height: rowH,
                child: pw.Container(alignment: pw.Alignment.centerLeft, child: _chartLabel(data[i].$1)),
              ),
            ),
            pw.Positioned(
              left: labelW,
              top: i * rowH + rowH / 2 - 5,
              child: pw.Container(
                width: math.max(2.0, plotW * data[i].$2.clamp(0, 100) / 100),
                height: 10,
                decoration: const pw.BoxDecoration(
                  color: _chartBarColor,
                  borderRadius: pw.BorderRadius.all(pw.Radius.circular(2)),
                ),
              ),
            ),
            pw.Positioned(
              left: labelW + plotW * data[i].$2.clamp(0, 100) / 100 + 4,
              top: i * rowH,
              child: pw.SizedBox(
                width: valueW,
                height: rowH,
                child: pw.Container(
                  alignment: pw.Alignment.centerLeft,
                  child: _chartLabel('${data[i].$2}%', bold: true, color: _C.ink),
                ),
              ),
            ),
          ],
          if (refPct != null)
            pw.Positioned(
              left: labelW + plotW * refPct,
              top: 0,
              child: pw.Container(
                width: 0,
                height: height,
                decoration: pw.BoxDecoration(
                  border: pw.Border(
                    left: pw.BorderSide(color: referenceColor, width: 1.4, style: pw.BorderStyle.dashed),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  const maxBarH = 88.0;
  const valueH = 12.0;
  const labelH = 20.0;
  const gap1 = 3.0, gap2 = 4.0, colGap = 6.0;
  final baselineY = valueH + gap1 + maxBarH;
  final totalH = baselineY + gap2 + labelH;
  final colW = (width - (data.length - 1) * colGap) / data.length;

  return pw.SizedBox(
    width: width,
    height: totalH,
    child: pw.Stack(
      children: [
        if (refPct != null)
          pw.Positioned(
            left: 0,
            top: baselineY - maxBarH * refPct,
            child: pw.Container(
              width: width,
              height: 0,
              decoration: pw.BoxDecoration(
                border: pw.Border(
                  top: pw.BorderSide(color: referenceColor, width: 1.4, style: pw.BorderStyle.dashed),
                ),
              ),
            ),
          ),
        for (var i = 0; i < data.length; i++)
          ...(() {
            final x = i * (colW + colGap);
            final barH = math.max(2.0, maxBarH * data[i].$2.clamp(0, 100) / 100);
            return [
              pw.Positioned(
                left: x,
                top: baselineY - barH - gap1 - valueH,
                child: pw.SizedBox(
                  width: colW,
                  height: valueH,
                  child: pw.Container(
                    alignment: pw.Alignment.center,
                    child: _chartLabel('${data[i].$2}%', bold: true, color: _C.ink),
                  ),
                ),
              ),
              pw.Positioned(
                left: x,
                top: baselineY - barH,
                child: pw.Container(
                  width: colW,
                  height: barH,
                  decoration: const pw.BoxDecoration(
                    color: _chartBarColor,
                    borderRadius: pw.BorderRadius.vertical(top: pw.Radius.circular(3)),
                  ),
                ),
              ),
              pw.Positioned(
                left: x,
                top: baselineY + gap2,
                child: pw.SizedBox(
                  width: colW,
                  height: labelH,
                  child: pw.Container(alignment: pw.Alignment.center, child: _chartLabel(data[i].$1)),
                ),
              ),
            ];
          })(),
      ],
    ),
  );
}

// ── Audit Index & Score Summary ─────────────────────────────────────────
// Header row repeats on every page a location's own row block spans
// (pw.Table's `repeat` row + this file's own [_indexTableRows] splitting
// the rows into one Table PER location) — the `pdf` package's Table has
// no colspan, so the full-width location banner / SUBTOTAL / FINAL SCORE
// bands (see [_spanRow]) can't live inside the same Table as the columned
// rows; they stay flat widgets between one small Table per location
// instead. The one visible difference from the web (which redraws a
// single header only after a genuine page break, wherever in the whole
// table it lands): here the header also reappears at the top of every
// new location's block even when no page break happens there — a location
// boundary always starts a fresh Table, and a fresh Table always shows
// its own header row. Column widths mirror the web's own two layouts.

class _Col {
  final String label;

  /// null = flex, taking whatever the fixed columns leave.
  final double? width;
  final bool center;
  const _Col(this.label, this.width, {this.center = true});
}

const _weightageCols = [
  _Col('Sr.', 30),
  _Col('Parameter / Checkpoint', null, center: false),
  _Col('Status', 60),
  _Col('Score', 45),
  _Col('Weightage', 55),
  _Col('Achieved / Total', 70),
  _Col('Total (%)', 55),
];

const _normalCols = [
  _Col('Sr.', 34),
  _Col('Parameter / Checkpoint', null, center: false),
  _Col('Status', 80),
  _Col('Score', 60),
  _Col('Total Achieved (%)', 96),
];

// Cell content only — no Expanded/SizedBox width wrapper, since a
// pw.TableRow's cells get their width from the owning pw.Table's own
// columnWidths (see [_indexTableRows]), not from a Row-style flex parent.
pw.Widget _cellContent(_Col col, String? value, PdfColor fg, bool bold, double size) => pw.Container(
  height: 20,
  alignment: col.center ? pw.Alignment.center : pw.Alignment.centerLeft,
  // Centered cells only need enough padding to keep neighbours apart; the
  // web's flat 8pt each side leaves too little room for "Weightage" and a
  // deep "1.1.1" serial once Noto Sans replaces Helvetica's narrower
  // metrics, and they clipped mid-word.
  padding: pw.EdgeInsets.symmetric(horizontal: col.center ? 4 : 8),
  child: value == null
      ? pw.SizedBox()
      : pw.Text(
          value,
          maxLines: 1,
          overflow: pw.TextOverflow.clip,
          style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: fg),
        ),
);

pw.TableRow _tableRow(
  List<_Col> cols,
  List<String?> values, {
  PdfColor? bg,
  PdfColor fg = _C.ink,
  bool bold = false,
  double size = 8,
  // Overrides `fg` for just one column index -- the Status column
  // carries its own finding-type color (see the leaf branch below)
  // without every other cell in the row following along.
  Map<int, PdfColor>? cellColors,
  // Set on the header row only — re-shown at the top of every page THIS
  // row's own pw.Table spans (see [_indexTableRows]).
  bool repeat = false,
}) => pw.TableRow(
  repeat: repeat,
  decoration: bg == null ? null : pw.BoxDecoration(color: bg),
  children: [for (var i = 0; i < cols.length; i++) _cellContent(cols[i], values[i], cellColors?[i] ?? fg, bold, size)],
);

pw.Widget _spanRow(
  String text, {
  required PdfColor bg,
  PdfColor fg = _C.blueDark,
  double size = 8.5,
  bool center = false,
}) => pw.Inseparable(
  child: pw.Container(
    height: 20,
    color: bg,
    alignment: center ? pw.Alignment.center : pw.Alignment.centerLeft,
    padding: const pw.EdgeInsets.symmetric(horizontal: 8),
    child: pw.Text(
      text,
      maxLines: 1,
      overflow: pw.TextOverflow.clip,
      style: pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold, color: fg),
    ),
  ),
);

List<pw.Widget> _indexTableRows(_ReportSpec spec) {
  final cols = spec.isWeightage ? _weightageCols : _normalCols;
  final columnWidths = <int, pw.TableColumnWidth>{
    for (var i = 0; i < cols.length; i++)
      i: cols[i].width == null ? const pw.FlexColumnWidth() : pw.FixedColumnWidth(cols[i].width!),
  };
  pw.TableRow headerRow() => _tableRow(
    cols,
    cols.map((c) => c.label).toList(),
    bg: _C.blueDark,
    fg: _C.white,
    bold: true,
    size: 7.5,
    repeat: true,
  );

  final rows = <pw.Widget>[];

  // FINAL SCORE below is built from THIS accumulator, not a total handed
  // in from outside — same reason the web's own drawIndexTable computes
  // its `grand` from the identical per-top-level-node walk that builds
  // each section's SUBTOTAL row (see exportAuditReportToPdf.js), rather
  // than from a separately-computed report-wide total: that guarantees
  // FINAL SCORE always equals the sum of the SUBTOTAL rows above it.
  // Deliberately a DIFFERENT rounding granularity than the header
  // ring/stat tile above (which rounds once over every raw leaf
  // contribution) — this one rounds per top-level node, matching what
  // each SUBTOTAL row itself sums, mirroring the web's own two distinct
  // aggregations for these two displayed numbers.
  var grandAchieved = 0.0;
  var grandMax = 0.0;

  for (final section in spec.sections) {
    rows.add(_spanRow(section.label.isNotEmpty ? section.label : 'All Locations', bg: _C.blueBg));

    var sectionAchieved = 0.0;
    var sectionMax = 0.0;
    final sectionRows = <pw.TableRow>[headerRow()];

    void walk(ParameterNode node, String serial, int depth) {
      final leaves = collectScoredLeaves([node]);
      final am = sumAchievedMax(leaves, spec.scoringSystem, section.maxScore);
      if (depth == 0) {
        sectionAchieved += am.achieved;
        sectionMax += am.max;
        grandAchieved += am.achieved;
        grandMax += am.max;
      }
      // Four spaces per level, matching the web's own name indent — the
      // hierarchy has to read from the name column alone once a row is
      // printed, with no tree lines to fall back on.
      final name = '${'    ' * depth}${node.name}';

      if (!node.isLeaf) {
        final pct = percentageOf(am);
        final scoreLabel = am.max > 0 ? '${am.achieved.round()}/${am.max.round()}' : '—';
        final weightageTotal = spec.isWeightage
            ? leaves.fold<double>(0, (sum, l) => sum + leafWeightage(l, section.maxScore)).round()
            : 0;
        final isTop = depth == 0;
        sectionRows.add(
          _tableRow(
            cols,
            spec.isWeightage
                ? [
                    serial,
                    name,
                    '—',
                    '—',
                    weightageTotal > 0 ? '$weightageTotal' : '—',
                    scoreLabel,
                    pct != null ? '$pct%' : '—',
                  ]
                : [serial, name, '—', scoreLabel, pct != null ? '$pct%' : '—'],
            bg: isTop ? _C.blue : _C.blueBgLight,
            fg: isTop ? _C.white : _C.ink,
            bold: true,
          ),
        );
        var i = 1;
        for (final child in node.children) {
          walk(child, '$serial.$i', depth + 1);
          i++;
        }
        return;
      }

      // Still rendered when not yet scored (findingType/score fall back to
      // "—") — same as the web's ReportIndexTable.jsx, so a checkpoint that
      // predates full scoring doesn't just vanish from the PDF.
      //
      // Same finding-type palette (and same short label) the Detailed
      // Findings section below already colors its own status pills with —
      // this column used to print plain black text, the one place on the
      // page a finding's color went missing. Mirrors the identical fix in
      // the web export's own drawIndexTable.
      final tone = node.findingType != null ? _findingMeta[node.findingType!] : null;
      final statusLabel = tone?.label ?? '—';
      sectionRows.add(
        _tableRow(
          cols,
          spec.isWeightage
              ? [
                  serial,
                  name,
                  statusLabel,
                  node.score != null ? '${node.score!.round()}' : '—',
                  '${leafWeightage(node, section.maxScore).round()}',
                  am.max > 0 ? '${am.achieved.round()}/${am.max.round()}' : '—',
                  '—',
                ]
              : [serial, name, statusLabel, node.score != null ? '${node.score!.round()}' : '—', '—'],
          bg: _C.blueBg,
          cellColors: tone != null ? {2: tone.fg} : null,
        ),
      );
    }

    var i = 1;
    for (final node in section.tree) {
      walk(node, '$i', 0);
      i++;
    }

    rows.add(pw.Table(columnWidths: columnWidths, children: sectionRows));

    if (spec.sections.length > 1) {
      final subPct = sectionMax > 0 ? (sectionAchieved / sectionMax * 100).round() : null;
      final subTotals = sectionMax > 0 ? '${sectionAchieved.round()}/${sectionMax.round()}' : '—';
      rows.add(
        _spanRow(
          '${section.label.isNotEmpty ? section.label : 'Location'} SUBTOTAL   —   $subTotals   —   ${subPct != null ? '$subPct%' : '—'}',
          bg: _C.subtotalBg,
          center: true,
        ),
      );
    }
  }

  final finalPct = grandMax > 0 ? (grandAchieved / grandMax * 100).round() : null;
  final finalTotals = grandMax > 0 ? '${grandAchieved.round()}/${grandMax.round()}' : '—';
  rows.add(
    _spanRow(
      'FINAL SCORE   —   $finalTotals   —   ${finalPct != null ? '$finalPct%' : '—'}',
      bg: _C.blueDark,
      fg: _C.white,
      size: 9.5,
      center: true,
    ),
  );

  return rows;
}

// ── Detailed Audit Findings ─────────────────────────────────────────────

List<pw.Widget> _findingsForSection(_SectionSpec section, _ReportSpec spec, Map<String, pw.MemoryImage?> images) {
  final heading = pw.Text(
    section.label.toUpperCase(),
    style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: _C.blueDark),
  );
  final nodeWidgets = <pw.Widget>[];
  var i = 1;
  for (final node in section.tree) {
    nodeWidgets.addAll(_findingNode(node, '$i', 0, section, spec, images));
    i++;
  }
  return [..._headingGluedToFirst(heading, 8, nodeWidgets), pw.SizedBox(height: 6)];
}

/// A serial chip — the web's Writer#pill (padX 7, height = size + 6, fully
/// rounded).
pw.Widget _serialPill(String text, {required PdfColor fg, required PdfColor bg, double size = 8}) => pw.Container(
  padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 3),
  decoration: pw.BoxDecoration(color: bg, borderRadius: pw.BorderRadius.circular((size + 6) / 2)),
  child: pw.Text(
    text,
    style: pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold, color: fg),
  ),
);

/// The leaf card's status badge — a white, tone-bordered pill with a small
/// leading dot (the web's drawDotPill, kept distinct from [_serialPill]
/// because that one reserves no room for a dot).
pw.Widget _dotPill(String label, _Tone tone, {double size = 6.5}) => pw.Container(
  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
  decoration: pw.BoxDecoration(
    color: _C.white,
    border: pw.Border.all(color: tone.border, width: 0.75),
    borderRadius: pw.BorderRadius.circular((size + 8) / 2),
  ),
  child: pw.Row(
    mainAxisSize: pw.MainAxisSize.min,
    children: [
      pw.Container(
        width: 4,
        height: 4,
        decoration: pw.BoxDecoration(color: tone.dot, shape: pw.BoxShape.circle),
      ),
      pw.SizedBox(width: 4),
      pw.Text(
        label,
        maxLines: 1,
        overflow: pw.TextOverflow.clip,
        style: pw.TextStyle(fontSize: size, fontWeight: pw.FontWeight.bold, color: tone.fg),
      ),
    ],
  ),
);

List<pw.Widget> _findingNode(
  ParameterNode node,
  String serial,
  int depth,
  _SectionSpec section,
  _ReportSpec spec,
  Map<String, pw.MemoryImage?> images,
) {
  final indent = depth * 14.0;

  if (!node.isLeaf) {
    final leaves = collectScoredLeaves([node]);
    final am = sumAchievedMax(leaves, spec.scoringSystem, section.maxScore);
    final scale = spec.scaleFor(section);
    final avg = leaves.isNotEmpty && am.max > 0 ? (am.achieved / am.max * scale).round() : null;
    final counts = [for (final ft in _findingSummaryOrder) leaves.where((l) => l.findingType == ft).length];
    final hasCounts = depth == 0 && leaves.isNotEmpty;
    final isTop = depth == 0;

    final nameRow = pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        _serialPill(serial, fg: _C.white, bg: isTop ? _C.bannerAccent : _C.blue, size: isTop ? 9 : 8),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: pw.Text(
            node.name,
            style: pw.TextStyle(
              fontSize: isTop ? 10.5 : 9,
              fontWeight: pw.FontWeight.bold,
              color: isTop ? _C.white : _C.blueDark,
            ),
          ),
        ),
      ],
    );

    final banner = pw.Inseparable(
      child: pw.Container(
        margin: pw.EdgeInsets.only(left: indent, bottom: 8),
        padding: pw.EdgeInsets.symmetric(horizontal: 10, vertical: isTop ? 6 : 5),
        decoration: pw.BoxDecoration(
          color: isTop ? _C.blueDark : _C.blueBg,
          borderRadius: pw.BorderRadius.circular(isTop ? 10 : 6),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  nameRow,
                  if (hasCounts) ...[
                    pw.SizedBox(height: 7),
                    pw.Row(
                      children: [
                        for (var i = 0; i < _findingSummaryOrder.length; i++)
                          if (counts[i] > 0) ...[
                            pw.Container(
                              width: 6,
                              height: 6,
                              decoration: pw.BoxDecoration(color: _dotColors[i], shape: pw.BoxShape.circle),
                            ),
                            pw.SizedBox(width: 4),
                            pw.Text(
                              '${counts[i]} ${_findingMeta[_findingSummaryOrder[i]]!.label}',
                              style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _C.white),
                            ),
                            pw.SizedBox(width: 16),
                          ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            if (avg != null) ...[
              pw.SizedBox(width: 8),
              if (isTop)
                // AVG SCORE box — the banner's own right-hand block, a
                // flat stand-in for the on-screen translucent-white panel.
                pw.Container(
                  width: 82,
                  padding: const pw.EdgeInsets.symmetric(vertical: 5),
                  decoration: pw.BoxDecoration(color: _C.bannerAccent, borderRadius: pw.BorderRadius.circular(8)),
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      pw.Text(
                        'AVG SCORE',
                        style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold, color: _C.white),
                      ),
                      pw.SizedBox(height: 2),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.center,
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          pw.Text(
                            '$avg',
                            style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: _C.white),
                          ),
                          pw.Text('/${_num(scale)}', style: const pw.TextStyle(fontSize: 7, color: _C.blueBg)),
                        ],
                      ),
                      pw.SizedBox(height: 2),
                      pw.Text(
                        'Total: ${am.achieved.round()}/${am.max.round()}',
                        style: const pw.TextStyle(fontSize: 6, color: _C.blueBg),
                      ),
                    ],
                  ),
                )
              else
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      'Avg: $avg/${_num(scale)}',
                      style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: _C.blue),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Total: ${am.achieved.round()}/${am.max.round()}',
                      style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: _C.teal),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
    final childWidgets = <pw.Widget>[
      for (var i = 0; i < node.children.length; i++)
        ..._findingNode(node.children[i], '$serial.${i + 1}', depth + 1, section, spec, images),
    ];
    // Glue the banner to only its first child's own first widget (e.g. a
    // "2 Shine" banner to "2.1 Shine check 1"'s card) — the same
    // [_headingGluedToFirst] pattern used for the section/page heading
    // above it, for the same reason: a bare Inseparable banner with
    // nothing glued after it is still just another block pw.MultiPage can
    // legally break straight after, landing it alone at the bottom of a
    // page with its first checkpoint only starting on the next one. gap:
    // 0 since the banner's own Container margin (bottom: 8) already
    // provides that spacing; everything after the first child stays flat
    // and individually breakable, same as before.
    return _headingGluedToFirst(banner, 0, childWidgets);
  }

  return _leafCardWidgets(node, serial, indent, section, spec, images);
}

/// Roughly how tall a leaf card will be, in points — the web pre-measures
/// the same way so it can push a card to a fresh page instead of splitting
/// it. Here the stake is higher: a pw.Container can't span pages at all
/// (only Flex/Wrap/Table can), so a card genuinely taller than one page
/// would abort the whole export with "Widget won't fit into the page".
/// When the estimate says that's a risk, [_leafCardWidgets] falls back to
/// emitting the card's parts as separate, individually-breakable widgets —
/// it loses the single enclosing border, which is a far better outcome
/// than losing the PDF.
double _estimateLeafHeight(ParameterNode node, double availW) {
  double lines(String? text, double fontSize, double width) {
    if (text == null || text.isEmpty) return 1;
    // Noto Sans averages a shade over half its point size per glyph for
    // mixed-case prose; 0.55 deliberately over-counts so the guard errs
    // toward the safe (flat) rendering.
    final perLine = math.max(1.0, width / (fontSize * 0.55));
    return (text.length / perLine).ceil().toDouble();
  }

  var h = math.max(42.0, 20 + lines(node.name, 9.5, availW * 0.55) * 13); // header band
  if (node.findingType != null) {
    h += 18 + lines(node.remark ?? '—', 9, availW - 20) * 12 + 20; // remark label + box
    h += 18; // evidence label
    final photos = node.photoUrls.length;
    if (photos == 0) {
      h += 26;
    } else {
      const size = 100.0, gap = 6.0;
      final perRow = math.max(1, ((availW + gap) / (size + gap)).floor());
      h += (photos / perRow).ceil() * (size + gap);
    }
    if (node.findingType == 'NC') h += 48;
  }
  return h + 32; // card padding + margins
}

// ── Leaf checkpoint — a bordered card with a tinted header band (serial,
// wrapped title, status pill, score box), then labeled AUDITOR REMARK and
// AUDITOR EVIDENCE blocks and, for an NC, a flat "NC ASSIGNED" alert.
// Mirrors exportAuditReportToPdf.js's own leaf branch. ──────────────────
List<pw.Widget> _leafCardWidgets(
  ParameterNode node,
  String serial,
  double indent,
  _SectionSpec section,
  _ReportSpec spec,
  Map<String, pw.MemoryImage?> images,
) {
  final tone = node.findingType != null ? _findingMeta[node.findingType!] : null;
  final maxScore = leafMax(node, section.maxScore);
  final nc = node.findingType == 'NC' && node.ncId != null ? spec.ncsById[node.ncId] : null;
  final availW = _contentWidth - indent - 28;

  // An unscored checkpoint has no body at all, so the band IS the card and
  // needs all four corners rounded — otherwise its square bottom edge
  // paints straight over the card border's own rounded corners.
  final hasBody = node.findingType != null;

  final headerBand = pw.Container(
    decoration: pw.BoxDecoration(
      color: tone?.bg ?? _C.neutralBand,
      borderRadius: hasBody
          ? const pw.BorderRadius.only(topLeft: pw.Radius.circular(10), topRight: pw.Radius.circular(10))
          : pw.BorderRadius.circular(10),
    ),
    padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Text(
          serial,
          style: pw.TextStyle(fontSize: 7.5, fontWeight: pw.FontWeight.bold, color: tone?.fg ?? _C.slate),
        ),
        pw.SizedBox(width: 8),
        pw.Expanded(
          child: pw.Text(
            node.name,
            style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: _C.ink),
          ),
        ),
        pw.SizedBox(width: 10),
        if (tone != null)
          _dotPill(tone.longLabel, tone)
        else
          pw.Text(
            'Not scored yet',
            style: pw.TextStyle(fontSize: 7.5, fontStyle: pw.FontStyle.italic, color: _C.slateLight),
          ),
        pw.SizedBox(width: 8),
        pw.Container(
          width: 44,
          height: 30,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            color: _C.white,
            border: pw.Border.all(color: tone?.border ?? _C.border, width: 1.25),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: tone != null
              ? pw.Column(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text(
                      _num(node.score),
                      style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: tone.fg),
                    ),
                    pw.Text('/${_num(maxScore)}', style: const pw.TextStyle(fontSize: 6, color: _C.slateLight)),
                  ],
                )
              : pw.Text('—', style: const pw.TextStyle(fontSize: 8, color: _C.slateLight)),
        ),
      ],
    ),
  );

  final body = <pw.Widget>[
    if (node.findingType != null) ...[
      pw.Text(
        'AUDITOR REMARK',
        style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: _C.amber),
      ),
      pw.SizedBox(height: 6),
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(10),
        decoration: pw.BoxDecoration(
          color: _C.amberBg,
          border: pw.Border.all(color: _C.amberBorder, width: 1),
          borderRadius: pw.BorderRadius.circular(6),
        ),
        child: pw.Text(
          (node.remark ?? '').trim().isNotEmpty ? node.remark!.trim() : '—',
          style: const pw.TextStyle(fontSize: 9, color: _C.amberText, lineSpacing: 2.7),
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Text(
        'AUDITOR EVIDENCE',
        style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold, color: _C.slate),
      ),
      pw.SizedBox(height: 6),
      if (node.photoUrls.isEmpty)
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: pw.BoxDecoration(color: _C.blueBgLight, borderRadius: pw.BorderRadius.circular(6)),
          child: pw.Text(
            'No photos provided',
            style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic, color: _C.slateLight),
          ),
        )
      else
        _photoGrid(node.photoUrls, images),
      if (nc != null) ...[
        pw.SizedBox(height: 10),
        // A point-in-time record that an NC exists and who owns it — no
        // open/closed wording or color, and no response thread. Same
        // deliberate scope as the web's own alert.
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(
            color: _findingMeta['NC']!.bg,
            border: pw.Border.all(color: _findingMeta['NC']!.border, width: 1),
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'NC ASSIGNED',
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold, color: _findingMeta['NC']!.fg),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                // NcPersonRef.fromJson (nc_model.dart) defaults a missing
                // auditee to the literal 'Unknown' (a deliberate, friendly
                // fallback for the in-app NC screens) rather than ''  —
                // so the isNotEmpty guard alone never catches it here.
                // Web's equivalent (nc.auditeeEmployeeId?.employeeName ||
                // "—") falls back to an em dash for the same missing
                // auditee; treat 'Unknown' as that same missing case so
                // the two PDFs read the same for an NC whose employee
                // record is gone.
                'Assigned to: ${(nc.auditee.name.isNotEmpty && nc.auditee.name != 'Unknown') ? nc.auditee.name : '—'}  ·  Due: ${_fmtDate(nc.targetDate)}',
                style: pw.TextStyle(fontSize: 7.5, color: _findingMeta['NC']!.fg, lineSpacing: 2.3),
              ),
            ],
          ),
        ),
      ],
    ],
  ];

  // Too tall to survive as one atomic Container — emit the same blocks
  // unwrapped so pw.MultiPage can break between them (see
  // [_estimateLeafHeight]).
  if (_estimateLeafHeight(node, availW) > _usablePageHeight - 40) {
    return [
      pw.Inseparable(
        child: pw.Container(
          margin: pw.EdgeInsets.only(left: indent),
          child: headerBand,
        ),
      ),
      pw.Container(
        margin: pw.EdgeInsets.only(left: indent, bottom: 10),
        padding: const pw.EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: body),
      ),
    ];
  }

  return [
    // Inseparable: every wrapper between here and the card's inner Column
    // delegates canSpan to its child (StatelessWidget/SingleChildWidget do,
    // and Column spans), so without this the card silently splits — header
    // band stranded at one page's foot, body opening the next, each drawing
    // its own border. The web pushes the whole card to a fresh page
    // instead; this is that.
    pw.Inseparable(
      child: pw.Container(
        margin: pw.EdgeInsets.only(left: indent, bottom: 10),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: tone?.border ?? _C.border, width: 1),
          borderRadius: pw.BorderRadius.circular(10),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            headerBand,
            if (hasBody) pw.Container(height: 1, color: tone?.border ?? _C.border),
            if (body.isNotEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: body),
              ),
          ],
        ),
      ),
    ),
  ];
}

/// Evidence thumbnails in a wrapping grid at the web's own 100pt main-
/// evidence size (ParameterScoreCard.jsx's 190px block, not NCThread's
/// small per-response strip). pw.Wrap is a SpanningWidget, so a long grid
/// breaks between rows rather than overflowing.
pw.Widget _photoGrid(List<String> urls, Map<String, pw.MemoryImage?> images) {
  const size = 100.0;
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
          border: pw.Border.all(color: _C.border, width: 1),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: img != null
            ? pw.ClipRRect(
                horizontalRadius: 4,
                verticalRadius: 4,
                // contain, not cover — the web's own drawPhotoRow scales
                // each photo down to fit ENTIRELY inside the square
                // (Math.min of the two axis ratios) rather than cropping
                // it to fill the square, so a non-square evidence photo
                // never loses content at its edges on either platform.
                child: pw.Image(img, fit: pw.BoxFit.contain, width: size, height: size),
              )
            : pw.Text('photo', style: const pw.TextStyle(fontSize: 6.5, color: _C.slateLight)),
      );
    }).toList(),
  );
}
