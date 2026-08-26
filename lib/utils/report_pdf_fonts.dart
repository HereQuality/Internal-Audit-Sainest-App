import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// utils/report_pdf_fonts.dart
/// ──────────────────────────────
/// The `pdf` package's default font (Helvetica, base-14) only covers
/// Latin/WinAnsi glyphs — any Devanagari (Hindi) text in an audit remark,
/// NC description, finding, or employee name (real, everyday input in
/// this app) silently renders as missing glyphs instead of throwing,
/// which is exactly what reads as "PDF text not properly coming" on the
/// exported report. Noto Sans (Latin) + Noto Sans Devanagari as a
/// fallback covers both scripts. PdfGoogleFonts fetches+caches these on
/// first use — network is already required to fetch the report data this
/// builds from, so this isn't a new offline requirement.
///
/// Cached in one Future so every report generated in an app session
/// reuses the same fetch instead of re-downloading per PDF.
Future<pw.ThemeData>? _themeFuture;

Future<pw.ThemeData> loadReportPdfTheme() {
  return _themeFuture ??= _load();
}

Future<pw.ThemeData> _load() async {
  final base = await PdfGoogleFonts.notoSansRegular();
  final bold = await PdfGoogleFonts.notoSansBold();
  final devanagari = await PdfGoogleFonts.notoSansDevanagariRegular();
  final devanagariBold = await PdfGoogleFonts.notoSansDevanagariBold();
  return pw.ThemeData.withFont(
    base: base,
    bold: bold,
    fontFallback: [devanagari, devanagariBold],
  );
}
