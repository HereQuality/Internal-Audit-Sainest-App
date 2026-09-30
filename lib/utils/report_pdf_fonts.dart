import 'dart:async';
import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// utils/report_pdf_fonts.dart
/// ──────────────────────────────
/// The `pdf` package's default font (Helvetica, base-14) only covers
/// Latin/WinAnsi glyphs — any Devanagari (Hindi) text in an audit remark,
/// NC description, finding, or employee name (real, everyday input in
/// this app) silently renders as missing glyphs instead of throwing,
/// which is exactly what reads as "PDF text not properly coming" on the
/// exported report.
///
/// The base/bold faces are deliberately left AS Helvetica (i.e. `base`/
/// `bold` below are never set — see [_load]) rather than swapped for Noto
/// Sans wholesale: Helvetica is also jsPDF's own default font on the web
/// export (client/src/utils/pdfWriter.js never calls `pdf.addFont`, so
/// every `w.pdf.setFont("helvetica", ...)` there is this exact same
/// built-in face) — the ONE thing report_pdf_builder.dart's own port
/// could just inherit for free instead of approximating, so it does. Noto
/// Sans Devanagari is added only as a `fontFallback` — the `pdf` package
/// already resolves a fallback font automatically for any glyph the base
/// face can't cover, so ordinary Latin text (the vast majority of a
/// report) renders in the SAME Helvetica the web PDF uses, and only
/// actual Devanagari text quietly switches face mid-string. PdfGoogleFonts
/// fetches+caches the fallback on first use — network is already required
/// to fetch the report data this builds from, so this isn't a new offline
/// requirement.
///
/// Cached in one Future so every report generated in an app session
/// reuses the same fetch instead of re-downloading per PDF. Each of the
/// four font fetches is capped at [_perFontTimeout] — fonts.gstatic.com
/// being slow or unreachable (flaky mobile data, a corporate firewall)
/// used to hang this Future forever with no timeout at all, which is
/// exactly what read as "the report just never finishes downloading".
/// A timeout or any other failure now falls back to the package's own
/// base-14 fonts (Latin-only, but a PDF that actually generates) instead
/// of failing the whole export. The failed attempt is NOT cached as
/// `_themeFuture` — only a genuinely successful (fonts loaded) or
/// deliberately-fallback theme is, via [_resultFuture] below — so a
/// transient failure (e.g. one bad network blip) doesn't lock every
/// later report in this same app session into the Latin-only fallback;
/// the next download attempt gets a fresh try at the real fonts.
///
/// What is cached is the fallback faces' raw BYTES ([ByteData]), never a
/// ready-made [pw.ThemeData]: a `pw.TtfFont` remembers the PdfDocument it
/// last drew into, so a cached font object kept every previous report's whole
/// document (and every embedded photo) alive until the next one, and could not
/// be handed to the background isolate the PDF is now built in without
/// dragging that old document along. Fresh font objects are made per report
/// from the cached bytes by [reportPdfThemeFrom] — cheap, the download is what
/// is cached.
Future<List<ByteData?>>? _resultFuture;

const _perFontTimeout = Duration(seconds: 12);

/// The fallback faces' bytes: one entry per face, `null` for a face the
/// download quietly replaced with the package's own Helvetica (printing's
/// PdfGoogleFonts returns that instead of throwing when a fetch fails) — and
/// an empty list when the fetch timed out or threw (Latin-only fallback).
Future<List<ByteData?>> loadReportPdfFontData() {
  return _resultFuture ??= _load().catchError((Object _, StackTrace _) {
    // Don't let a failed attempt sit cached — clear it so the NEXT report
    // generated this session gets a fresh shot at the real fonts instead
    // of being stuck on the fallback for the rest of the app's lifetime.
    _resultFuture = null;
    return <ByteData?>[];
  });
}

/// A fresh theme (fresh font objects — see above) for one report, built from
/// [loadReportPdfFontData]'s result. Pure Dart, safe to call inside a
/// background isolate.
pw.ThemeData reportPdfThemeFrom(List<ByteData?> fontData) {
  if (fontData.isEmpty) return pw.ThemeData();
  // No `base`/`bold` here — leaving those unset keeps the package's own
  // default (Font.helvetica()/Font.helveticaBold(), confirmed in its
  // TextStyle.defaultStyle()), the same face the web PDF draws every
  // string with. Only Devanagari script — which that face has no glyphs
  // for at all — falls through to Noto Sans.
  return pw.ThemeData.withFont(
    fontFallback: [
      for (final data in fontData) data == null ? pw.Font.helvetica() : pw.Font.ttf(data),
    ],
  );
}

Future<pw.ThemeData> loadReportPdfTheme() async => reportPdfThemeFrom(await loadReportPdfFontData());

Future<List<ByteData?>> _load() async {
  final devanagari = await PdfGoogleFonts.notoSansDevanagariRegular().timeout(_perFontTimeout);
  final devanagariBold = await PdfGoogleFonts.notoSansDevanagariBold().timeout(_perFontTimeout);
  return [
    for (final font in [devanagari, devanagariBold]) font is pw.TtfFont ? font.data : null,
  ];
}
