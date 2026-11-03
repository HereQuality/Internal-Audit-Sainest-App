import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils/snackbar.dart';
import '../providers/audits_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/filter_options_provider.dart';
import '../providers/nc_provider.dart';
import '../utils/final_report_download.dart';
import '../utils/final_report_excel.dart';
import '../utils/final_report_export_service.dart';
import '../utils/final_report_request.dart';

/// widgets/final_report_excel_bar.dart
/// ─────────────────────────────────────
/// The Final Report's "Download Excel" action — one slim bar under the tab bar, so it
/// sits in the same place whichever tab (Audits | NCs | Repeated NCs) is showing and
/// the three look alike (like the report cards' PDF icon, it is the primary colour, in
/// light and dark).
///
/// Tapping it downloads EVERY row the screen's current filters match — all pages, not
/// the page on screen (utils/final_report_download.dart) — builds the workbook the web
/// app's Excel has (Summary + detail rows + By Location / By Auditor / By Auditee) and
/// hands it to the phone's share sheet.
///
/// While it works the bar shows where it is ("Preparing Excel… 120 of 340 reports")
/// with a Cancel button instead of the Download button, so a second tap cannot start a
/// second download; the filters in force are snapshotted at the tap, so changing them
/// meanwhile cannot change the file. A failed download says why in a snackbar and leaves
/// the screen as it was.
class FinalReportExcelBar extends StatefulWidget {
  const FinalReportExcelBar({super.key, required this.tab, this.service});

  /// The tab showing — the one a tap on Download exports.
  final FinalReportTab tab;

  /// Tests hand in one with a fake server and a fake share sheet.
  final FinalReportExportService? service;

  @override
  State<FinalReportExcelBar> createState() => _FinalReportExcelBarState();
}

class _FinalReportExcelBarState extends State<FinalReportExcelBar> {
  late final FinalReportExportService _service = widget.service ?? FinalReportExportService();
  final _buttonKey = GlobalKey();

  bool _busy = false;
  bool _cancelling = false;
  FinalReportTab? _runningTab;
  ExportProgress? _progress;
  ExportCancelToken? _cancel;

  @override
  void dispose() {
    // Leaving the screen ends a download that is still reading pages.
    _cancel?.cancel();
    super.dispose();
  }

  // Where an iPad anchors the share popover: the Download button — read BEFORE it is
  // replaced by the progress row.
  Rect _shareOrigin() {
    final box = _buttonKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1);
  }

  Future<void> _start() async {
    // Set at once, before anything is awaited: a second tap finds the bar busy.
    if (_busy) return;
    final tab = widget.tab;
    final origin = _shareOrigin();
    final token = ExportCancelToken();
    setState(() {
      _busy = true;
      _cancelling = false;
      _runningTab = tab;
      _progress = const ExportProgress(noun: '');
      _cancel = token;
    });
    try {
      // The names the Summary prints for the picked people and places come from the same lists
      // the filter sheet uses (a no-op once they are loaded).
      final options = context.read<FilterOptionsProvider>();
      await options.load();
      if (!mounted) return;
      final request = buildFinalReportRequest(
        tab: tab,
        audits: context.read<AuditsProvider>(),
        ncs: context.read<NcProvider>(),
        options: options,
        generatedBy: context.read<AuthProvider>().user?.name ?? '',
      );
      final result = await _service.export(
        request,
        cancel: token,
        shareOrigin: origin,
        onProgress: (p) {
          if (mounted && !token.isCancelled) setState(() => _progress = p);
        },
      );
      if (mounted && result.warnings.isNotEmpty) showErrorSnackBar(context, result.warnings.join(' '));
    } on ExportCancelled {
      // The person cancelled: nothing to report, the bar is back to Download.
    } on ReportExportException catch (e) {
      debugPrint('FinalReportExcelBar: $e');
      if (mounted) showErrorSnackBar(context, e.message);
    } catch (e, st) {
      debugPrint('FinalReportExcelBar: unexpected failure: $e\n$st');
      if (mounted) showErrorSnackBar(context, 'Could not create the Excel file. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancelling = false;
          _runningTab = null;
          _progress = null;
          _cancel = null;
        });
      }
    }
  }

  void _cancelExport() {
    _cancel?.cancel();
    setState(() => _cancelling = true);
  }

  String get _caption => switch (widget.tab) {
    FinalReportTab.audits => 'Every report your filters match',
    FinalReportTab.ncs => 'Every NC your filters match',
    FinalReportTab.repeats => 'Every repeated checkpoint your filters match',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: _busy ? _progressRow(scheme, textTheme) : _downloadRow(scheme, textTheme),
    );
  }

  Widget _downloadRow(ColorScheme scheme, TextTheme textTheme) {
    final caption = Text(
      _caption,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textTheme.bodySmall?.copyWith(color: scheme.outline, fontWeight: FontWeight.w600),
    );
    final button = OutlinedButton.icon(
      key: _buttonKey,
      onPressed: _start,
      icon: const Icon(Icons.table_chart_outlined, size: 18),
      label: const Text('Download Excel', maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        // 44 px tall: the touch-target minimum.
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
    // With a large system text size the caption and the button no longer fit side by side on a
    // narrow phone: the caption goes above, and the button takes the width (its label shortens
    // rather than overflowing).
    final large = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.25;
    if (large) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [caption, const SizedBox(height: 4), button],
      );
    }
    return Row(
      children: [
        Expanded(child: caption),
        const SizedBox(width: 8),
        button,
      ],
    );
  }

  Widget _progressRow(ColorScheme scheme, TextTheme textTheme) {
    final progress = _progress ?? const ExportProgress(noun: '');
    final other = _runningTab != null && _runningTab != widget.tab;
    // The bar is shared by the three tabs: if the person switched tab meanwhile, say which one is being made.
    final text = _cancelling ? 'Cancelling…' : '${other ? '${finalReportTabLabel(_runningTab!)}: ' : ''}${progress.text}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  text,
                  key: const ValueKey('excel-progress-text'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('excel-cancel'),
              onPressed: _cancelling ? null : _cancelExport,
              style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
              child: const Text('Cancel'),
            ),
          ],
        ),
        LinearProgressIndicator(value: _cancelling ? null : progress.fraction, minHeight: 4),
        const SizedBox(height: 4),
      ],
    );
  }
}
