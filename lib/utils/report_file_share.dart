import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// utils/report_file_share.dart
/// ──────────────────────────────
/// Hands a finished report file to the person: writes it to the app's temporary
/// folder and opens the phone's share sheet (Excel, Drive, WhatsApp, email,
/// "Save to Files"…) — the Excel counterpart of what `Printing.sharePdf` does for
/// the report PDFs.

/// What the person did with the share sheet. Android cannot say (it only reports
/// that the sheet was shown), so [unknown] is the usual answer there.
enum ReportShareOutcome { shared, dismissed, unknown }

abstract class ReportFileSharer {
  /// Opens the share sheet for [bytes] as a file named [fileName]. [origin] is where an
  /// iPad anchors the share popover (the Download button).
  Future<ReportShareOutcome> shareXlsx({required String fileName, required Uint8List bytes, Rect? origin});
}

const xlsxMimeType = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

class SharePlusReportFileSharer implements ReportFileSharer {
  const SharePlusReportFileSharer();

  @override
  Future<ReportShareOutcome> shareXlsx({required String fileName, required Uint8List bytes, Rect? origin}) async {
    final base = await getTemporaryDirectory();
    final folder = Directory('${base.path}${Platform.pathSeparator}final_report_exports');
    if (!await folder.exists()) await folder.create(recursive: true);
    // Earlier downloads are of no use once a new one is made: the share sheet has copied what it needs.
    await for (final old in folder.list()) {
      if (old is File && old.path.toLowerCase().endsWith('.xlsx')) {
        try {
          await old.delete();
        } on FileSystemException {
          // In use by a share target still reading it: leave it, the next download tries again.
        }
      }
    }
    final file = File('${folder.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
    final result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: xlsxMimeType, name: fileName)],
        fileNameOverrides: [fileName],
        subject: fileName,
        sharePositionOrigin: origin,
      ),
    );
    return switch (result.status) {
      ShareResultStatus.success => ReportShareOutcome.shared,
      ShareResultStatus.dismissed => ReportShareOutcome.dismissed,
      ShareResultStatus.unavailable => ReportShareOutcome.unknown,
    };
  }
}
