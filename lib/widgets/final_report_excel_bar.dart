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
/// The Final Report's Excel actions — one slim bar under the tab bar, so it sits in the
/// same place whichever tab (Audits | NCs | Repeated NCs) is showing and the tabs look
/// alike (like the report cards' PDF icon, the buttons are the primary colour, in light
/// and dark). Two outlined 44 px buttons:
///
///  * "Download Excel" — THIS tab: EVERY row the screen's current filters match — all
///    pages, not the page on screen (utils/final_report_download.dart) — as the web
///    app's workbook (Summary + detail rows + By Location / By Auditor / By Auditee);
///  * "Download All" — the Audits, NCs and Repeated NCs workbooks in ONE file with one
///    Summary (utils/final_report_all.dart), each part read one after the other under
///    the filters its own tab uses right now.
///
/// Either hands the finished file to the phone's share sheet. The buttons sit side by
/// side when both labels fit and stack when they do not (a 320 px phone, a large system
/// text size), never overflowing.
///
/// While it works the bar shows where it is ("Preparing Excel… 120 of 340 reports", or
/// in Download All "Audits — 120 of 340 reports" / "NCs — …" / "Repeated NCs — …") with
/// a Cancel button instead of the two buttons, so a second tap cannot start a second
/// download; the filters in force are snapshotted at the tap, so changing them meanwhile
/// cannot change the file. A failed download — any part of Download All — says why in a
/// snackbar and leaves the screen as it was; a file is never made with a part missing.
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
  final _excelKey = GlobalKey();
  final _allKey = GlobalKey();

  bool _busy = false;
  bool _cancelling = false;
  FinalReportTab? _runningTab;
  // "Download All" is the job running (no single tab owns it).
  bool _runningAll = false;
  ExportProgress? _progress;
  ExportCancelToken? _cancel;

  @override
  void dispose() {
    // Leaving the screen ends a download that is still reading pages.
    _cancel?.cancel();
    super.dispose();
  }

  // Where an iPad anchors the share popover: the Download button that was tapped — read
  // BEFORE it is replaced by the progress row.
  Rect _shareOrigin(GlobalKey button) {
    final box = button.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.sizeOf(context);
    return Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1);
  }

  Future<void> _start({bool all = false}) async {
    // Set at once, before anything is awaited: a second tap finds the bar busy.
    if (_busy) return;
    final tab = widget.tab;
    final origin = _shareOrigin(all ? _allKey : _excelKey);
    final token = ExportCancelToken();
    setState(() {
      _busy = true;
      _cancelling = false;
      _runningAll = all;
      _runningTab = all ? null : tab;
      _progress = ExportProgress(part: all ? 'Audits' : '');
      _cancel = token;
    });
    try {
      // The names the Summary prints for the picked people and places come from the same lists
      // the filter sheet uses (a no-op once they are loaded).
      final options = context.read<FilterOptionsProvider>();
      await options.load();
      if (!mounted) return;
      final audits = context.read<AuditsProvider>();
      final ncs = context.read<NcProvider>();
      final generatedBy = context.read<AuthProvider>().user?.name ?? '';
      void onProgress(ExportProgress p) {
        if (mounted && !token.isCancelled) setState(() => _progress = p);
      }

      // Both snapshot every filter NOW, in one synchronous step, whatever happens to the screen after.
      final result = all
          ? await _service.exportAll(
              buildFinalReportAllRequest(audits: audits, ncs: ncs, options: options, generatedBy: generatedBy),
              cancel: token,
              shareOrigin: origin,
              onProgress: onProgress,
            )
          : await _service.export(
              buildFinalReportRequest(tab: tab, audits: audits, ncs: ncs, options: options, generatedBy: generatedBy),
              cancel: token,
              shareOrigin: origin,
              onProgress: onProgress,
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
          _runningAll = false;
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

  static const _excelLabel = 'Download Excel';
  static const _allLabel = 'Download All';

  Widget _downloadRow(ColorScheme scheme, TextTheme textTheme) {
    final caption = Text(
      _caption,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: textTheme.bodySmall?.copyWith(color: scheme.outline, fontWeight: FontWeight.w600),
    );
    OutlinedButton button(Key key, VoidCallback onPressed, IconData icon, String label) => OutlinedButton.icon(
      key: key,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        // 44 px tall: the touch-target minimum.
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
    );
    final excel = button(_excelKey, _start, Icons.table_chart_outlined, _excelLabel);
    final all = Tooltip(
      message: 'Audits, NCs and Repeated NCs together in ONE Excel file, with one Summary',
      child: button(_allKey, () => _start(all: true), Icons.layers_outlined, _allLabel),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        caption,
        const SizedBox(height: 4),
        // Side by side when each label fits in half the width; otherwise one above the other, each
        // taking the width (a 320 px phone, or a large system text size). Measured at the text size
        // in force, so nothing is guessed from the screen width alone.
        LayoutBuilder(
          builder: (context, constraints) {
            final style = (Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 14));
            double natural(String label) {
              final painter = TextPainter(
                text: TextSpan(text: label, style: style),
                textDirection: TextDirection.ltr,
                textScaler: MediaQuery.textScalerOf(context),
                maxLines: 1,
              )..layout();
              // icon + gap + the button's own padding and border, and a little air.
              return painter.width + 18 + 8 + 24 + 6;
            }

            final half = (constraints.maxWidth - 8) / 2;
            if (natural(_excelLabel) <= half && natural(_allLabel) <= half) {
              return Row(
                children: [
                  Expanded(child: excel),
                  const SizedBox(width: 8),
                  Expanded(child: all),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [excel, const SizedBox(height: 8), all],
            );
          },
        ),
      ],
    );
  }

  Widget _progressRow(ColorScheme scheme, TextTheme textTheme) {
    final progress = _progress ?? const ExportProgress(noun: '');
    // Download All names the part it is reading itself. For one tab: the bar is shared by the three
    // tabs, so if the person switched tab meanwhile, say which one is being made.
    final other = !_runningAll && _runningTab != null && _runningTab != widget.tab;
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
