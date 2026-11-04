import 'dart:typed_data';
import 'dart:ui' show Rect;

import '../core/network/dio_client.dart';
import 'final_report_download.dart';
import 'report_file_share.dart';
import 'report_sheet_spec.dart';
import 'xlsx_report_writer.dart';

/// utils/final_report_export_service.dart
/// ────────────────────────────────────────
/// The whole "Download Excel" job, start to finish: read every row the filters match
/// ([FinalReportDownloader]), write the workbook off the UI thread
/// ([encodeReportWorkbookInBackground]) and open the share sheet
/// ([ReportFileSharer]). Each step is a constructor argument, so the screen's flow
/// (progress, cancel, error messages) is tested without a server, a file system or a
/// share sheet.

class FinalReportExportResult {
  /// The file's name, with ".xlsx".
  final String fileName;
  final int rowCount;

  /// Things worth telling the person (also written in the file's Summary).
  final List<String> warnings;
  final ReportShareOutcome shareOutcome;

  const FinalReportExportResult({
    required this.fileName,
    required this.rowCount,
    this.warnings = const [],
    this.shareOutcome = ReportShareOutcome.unknown,
  });
}

class FinalReportExportService {
  FinalReportExportService({
    ReportJsonGet Function(ExportCancelToken cancel)? getter,
    Future<Uint8List> Function(ReportWorkbookSpec spec)? encode,
    ReportFileSharer? sharer,
    this.retryDelays,
  }) : _getter = getter ?? ((cancel) => dioJsonGet(DioClient.instance.dio, cancel)),
       _encode = encode ?? encodeReportWorkbookInBackground,
       _sharer = sharer ?? const SharePlusReportFileSharer();

  final ReportJsonGet Function(ExportCancelToken cancel) _getter;
  final Future<Uint8List> Function(ReportWorkbookSpec spec) _encode;
  final ReportFileSharer _sharer;

  /// Waits before each retry of a failed request (null = the downloader's own: two retries).
  final List<Duration>? retryDelays;

  /// Runs the export for [request]. Throws [ExportCancelled] if [cancel] fires,
  /// [ReportExportException] (with a message fit to show) when a request finally fails.
  Future<FinalReportExportResult> export(
    FinalReportRequest request, {
    ExportCancelToken? cancel,
    ExportProgressCallback? onProgress,
    Rect? shareOrigin,
  }) {
    final token = cancel ?? ExportCancelToken();
    return _finish(
      token,
      shareOrigin,
      () => _downloader(token, onProgress).run(request),
    );
  }

  /// "Download All": the three tabs' parts, one after the other, in ONE workbook
  /// (`Final-Report-All-<yyyy-MM-dd>.xlsx`). Same rules as [export].
  Future<FinalReportExportResult> exportAll(
    FinalReportAllRequest request, {
    ExportCancelToken? cancel,
    ExportProgressCallback? onProgress,
    Rect? shareOrigin,
  }) {
    final token = cancel ?? ExportCancelToken();
    return _finish(
      token,
      shareOrigin,
      () => _downloader(token, onProgress).runAll(request),
    );
  }

  FinalReportDownloader _downloader(ExportCancelToken token, ExportProgressCallback? onProgress) =>
      FinalReportDownloader(
        get: _getter(token),
        cancel: token,
        onProgress: onProgress,
        retryDelays: retryDelays ?? const [Duration(milliseconds: 600), Duration(milliseconds: 1800)],
      );

  // Read, write the file off the UI thread, open the share sheet.
  Future<FinalReportExportResult> _finish(
    ExportCancelToken token,
    Rect? shareOrigin,
    Future<FinalReportBuild> Function() read,
  ) async {
    final build = await read();

    token.throwIfCancelled();
    final Uint8List bytes;
    try {
      bytes = await _encode(build.spec);
    } catch (e) {
      throw ReportExportException('Could not create the Excel file. Please try again.', e);
    }
    token.throwIfCancelled();

    final fileName = '${build.spec.filename}.xlsx';
    final ReportShareOutcome outcome;
    try {
      outcome = await _sharer.shareXlsx(fileName: fileName, bytes: bytes, origin: shareOrigin);
    } catch (e) {
      throw ReportExportException('The Excel file was made but could not be opened for sharing. Please try again.', e);
    }
    return FinalReportExportResult(
      fileName: fileName,
      rowCount: build.rowCount,
      warnings: build.warnings,
      shareOutcome: outcome,
    );
  }
}
