import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/network/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_status.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/snackbar.dart';
import '../../models/audit_detail_model.dart';
import '../../models/audit_model.dart';
import '../../providers/audits_provider.dart';
import '../../utils/report_pdf_builder.dart';
import '../../utils/report_sections.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/status_filter_chip_row.dart';
import '../audits/audit_detail_screen.dart';

/// Profile -> Reports (titled "Final Report" to match the web app) — every
/// audit this employee can see, same GET /audits/mine list AuditsProvider.
/// fetchReportAudits wraps, narrowed by status chips (the same lifecycle
/// statuses MyAuditsScreen's chips use, plus "Completed" — see
/// `_statusFilters`) plus a search box
/// and a completed/scheduled-date range filter, mirroring the web app's
/// Final Report page (client/src/pages/CompletedAudits.jsx) and its own
/// search + DateRangeFilter. Each card is downloadable as a real PDF
/// (utils/report_pdf_builder.dart — deliberately PDF-only on mobile,
/// unlike the web per-report page's PDF+Excel dropdown (AuditFullReport.
/// jsx#handleDownloadExcel) — a single format is enough on a phone, and
/// PDF is what people actually reach for there) AND opens the same in-app
/// checkpoint-by-checkpoint detail
/// (findings, remarks, photos, NC threads) as web's AuditFullReport.jsx —
/// tapping a card pushes AuditDetailScreen, which already renders fully
/// read-only for anything no longer open for scoring (see its own
/// `_isActiveForScoring`), so a Completed audit shows exactly as a
/// "final report" without a second, parallel detail screen to keep in
/// sync with the scoring workspace.
///
/// A multi-zone Schedule/Frequency Audit (see AuditModel.scheduleBatchId)
/// this employee is personally assigned to more than one zone of groups
/// those zones into one expandable card — same "N locations" tap-to-expand
/// pattern the web table uses — instead of listing each zone as its own
/// separate, look-alike row. The group's own header additionally offers a
/// combined "Download PDF" spanning every zone in it.
///
/// A "per-location" audit (AuditModel.structureMode/locationCount — see
/// AuditModel.hasMultipleZones) is a DIFFERENT kind of multi-zone shape:
/// still just ONE document (unlike a batch above), with its own checklist
/// split internally across several zones (locationParameters). Its own
/// card offers the same "N zones ⌄" expand as the web page's
/// ownZoneSections, computing each zone's score lazily (only once
/// actually expanded, not upfront for every row) from one full report
/// fetch via utils/report_sections.dart — the same Dart port of
/// AuditReportShared.jsx already used to build the downloadable PDF.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

// Same "fetch once, filter locally" reasoning — and same matching rules
// (core/utils/audit_status.dart#auditMatchesStatusFilter) — as
// my_audits_screen.dart's own chips, in this screen's own order:
//   * 'Completed' (the DEFAULT, and this screen's pre-existing behaviour) is
//     every audit whose auditor has finished it — matched on the RAW stored
//     status, whatever its NC stage — so the Final Report list keeps showing
//     exactly the audits that have a final report. It sits right after 'All'
//     so the selected default chip is on screen when the row first paints.
//   * the two timeliness chips and the NC-stage chips narrow within it;
//   * Not Started / In Progress / Overdue are the unfinished stages, kept
//     from the old chip row (with Overdue new).
// Deliberately WITHOUT 'Draft', unlike MyAuditsScreen's own list: Reports
// is "download a report", and a Draft-status audit (which, per
// AuditDetailModel.isInstant's own doc comment, is also where every Instant
// Audit lives for its whole build-and-score life, not just genuinely-
// unstarted ones) has no finished report to hand out — a filter chip whose
// result is either nothing or a half-built one doesn't belong on this
// screen the way it does on My Audits' own "what do I still have to work
// on" list. Still reachable via 'All' if one somehow shows up here, just
// not surfaced as its own one-tap chip.
const _statusFilters = [
  'All',
  AuditStatus.completed,
  AuditStatus.delayedCompleted,
  AuditStatus.onTimeCompleted,
  AuditStatus.ncResponsePending,
  AuditStatus.ncVerificationPending,
  AuditStatus.totalClosed,
  AuditStatus.notStarted,
  AuditStatus.inProgress,
  AuditStatus.overdue,
];

class _ReportsScreenState extends State<ReportsScreen> {
  // Which row's PDF is currently generating — gates that one row's download
  // button (spinner in place of the icon) without blocking the rest of the
  // list.
  String? _downloadingAuditId;
  // Which batch's COMBINED pdf is generating — separate from the single-
  // audit state above since a batch card's own download button sits
  // alongside its members' individual ones.
  String? _downloadingBatchId;
  final Set<String> _expandedBatchIds = {};
  // Defaults to Completed — this screen's pre-existing behavior and the
  // web Final Report page's own default view — the other stages
  // (mirroring MyAuditsScreen's status chips) are one tap away. This is the
  // raw stored-Completed gate (see _statusFilters), not a display status.
  String _statusFilter = AuditStatus.completed;
  final TextEditingController _searchController = TextEditingController();
  String _search = '';
  // Inclusive day-precision bounds, same convention as the web page's own
  // DateRangeFilter — matched below against each audit's completedDate,
  // falling back to scheduledDate for anything not finished yet (a Draft/
  // Not Started/In Progress row has no completedDate at all).
  DateTime? _fromDate;
  DateTime? _toDate;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() => context.read<AuditsProvider>().fetchReportAudits();

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final firstDate = DateTime(now.year - 5);
    final lastDate = now.add(const Duration(days: 365));
    final picked = await showDateRangePicker(
      context: context,
      firstDate: firstDate,
      lastDate: lastDate,
      initialDateRange: _fromDate != null && _toDate != null
          ? DateTimeRange(start: _fromDate!, end: _toDate!)
          : null,
    );
    if (picked == null) return;
    setState(() {
      _fromDate = DateTime(
        picked.start.year,
        picked.start.month,
        picked.start.day,
      );
      _toDate = DateTime(picked.end.year, picked.end.month, picked.end.day);
    });
  }

  bool _matchesSearch(AuditModel a) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return a.title.toLowerCase().contains(q) ||
        a.location.toLowerCase().contains(q) ||
        (a.auditee.name?.toLowerCase().contains(q) ?? false) ||
        a.auditorNames.any((n) => n.toLowerCase().contains(q));
  }

  bool _matchesDateRange(AuditModel a) {
    if (_fromDate == null && _toDate == null) return true;
    final d = a.completedDate ?? a.scheduledDate;
    if (d == null) return false;
    final day = DateTime(d.year, d.month, d.day);
    if (_fromDate != null && day.isBefore(_fromDate!)) return false;
    if (_toDate != null && day.isAfter(_toDate!)) return false;
    return true;
  }

  String _sanitizedFileName(String title) {
    final cleaned = title.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '-');
    return cleaned.isEmpty ? 'audit-report' : cleaned;
  }

  Future<void> _download(AuditModel audit) async {
    setState(() => _downloadingAuditId = audit.id);
    try {
      final detail = await context
          .read<AuditsProvider>()
          .fetchAuditReportDetail(audit.id);
      if (detail == null) throw Exception('Could not load this report.');
      final bytes = await buildReportPdf(detail);
      await Printing.sharePdf(
        bytes: bytes,
        filename: '${_sanitizedFileName(audit.title)}.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(
        context,
        e is DioException
            ? extractErrorMessage(e, fallback: 'Could not generate this report. Please try again.')
            : 'Could not generate this report. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _downloadingAuditId = null);
    }
  }

  // Every zone in the batch, not just the ones `members` lists (this
  // employee's own — see _groupByBatch above, sourced from GET
  // /audits/mine) — AuditsProvider#fetchBatchReport's own header comment
  // has the full story: looping fetchAuditReportDetail per member here
  // used to silently drop every OTHER auditor's zone from a "combined"
  // report, the mobile side of the "only his own coming, not the full
  // one" gap against the web app's Final Report page. That endpoint's own
  // access rule (audit.controller.js#getBatchReport) is a per-ROLE menu
  // grant ("Final Report"/"Schedule Audit" read), which varies by company
  // setup and isn't something this screen can know ahead of time — a role
  // without it falls back to the old per-member loop below (still every
  // zone THIS employee is personally on, same as before) rather than the
  // combined download just failing outright.
  Future<void> _downloadCombined(
    String batchId,
    List<AuditModel> members,
    String title,
  ) async {
    setState(() => _downloadingBatchId = batchId);
    final provider = context.read<AuditsProvider>();
    try {
      List<AuditDetailModel> zones;
      // The batch aggregate the combined PDF prints as its Status — from the
      // batch report response itself; null on the per-member fallback below,
      // where buildCombinedReportPdf reads it off the zones instead.
      String? batchStatus;
      try {
        final report = await provider.fetchBatchReport(batchId);
        zones = report.zones;
        batchStatus = report.statusLabel;
      } on DioException {
        // Used to only fall back here on a 403 (no "Final Report"/"Schedule
        // Audit" menu grant) and rethrow anything else — but a combined
        // batch report is the single heaviest request this screen makes
        // (every zone's full parameter tree + NCs in one response), so on a
        // slow connection it's also the one most likely to hit a plain
        // receiveTimeout. That used to fail the whole download outright
        // ("the merged/combined audit's report just isn't there") even
        // though this employee's own zone(s) were perfectly reachable one
        // at a time. Any DioException now falls back the same way a 403
        // already did — best-effort, this employee's own zones only —
        // rather than only a permission gap degrading gracefully.
        zones = [];
        for (final m in members) {
          final detail = await provider.fetchAuditReportDetail(m.id);
          if (detail != null) zones.add(detail);
        }
      }
      if (zones.isEmpty) throw Exception('Could not load this report.');
      final bytes = await buildCombinedReportPdf(
        zones,
        batchStatus: batchStatus,
      );
      await Printing.sharePdf(
        bytes: bytes,
        filename: '${_sanitizedFileName(title)}-combined.pdf',
      );
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(
        context,
        e is DioException
            ? extractErrorMessage(e, fallback: 'Could not generate this report. Please try again.')
            : 'Could not generate this report. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _downloadingBatchId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AuditsProvider>();
    final bool showEmptyState =
        !provider.isLoadingReports &&
        provider.reportsError == null &&
        provider.reportAudits.isEmpty;
    final bool showError =
        provider.reportsError != null && provider.reportAudits.isEmpty;
    final bool showLoading =
        provider.isLoadingReports &&
        provider.reportAudits.isEmpty &&
        !showError;
    final filtered = provider.reportAudits
        .where((a) => auditMatchesStatusFilter(a, _statusFilter))
        .where(_matchesSearch)
        .where(_matchesDateRange)
        .toList();
    final items = _groupByBatch(filtered);
    final hasActiveTextOrDateFilter =
        _search.trim().isNotEmpty || _fromDate != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Final Report')),
      body: Column(
        children: [
          if (!showLoading && !showError && !showEmptyState) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Search reports...',
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _search = '');
                                },
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _DateFilterButton(
                    fromDate: _fromDate,
                    toDate: _toDate,
                    onTap: _pickDateRange,
                    onClear: () => setState(() {
                      _fromDate = null;
                      _toDate = null;
                    }),
                  ),
                ],
              ),
            ),
            StatusFilterChipRow(
              options: _statusFilters,
              selected: _statusFilter,
              // 'Completed' (any finished audit) has no colour of its own
              // in the new palette, so it stays a plain chip.
              dotColorFor: (o) => o == 'All' || o == AuditStatus.completed
                  ? null
                  : AppColors.readable(context, AppColors.forAuditStatus(o)),
              onSelected: (v) => setState(() => _statusFilter = v),
            ),
          ],
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: showLoading || showEmptyState || showError
                    ? EdgeInsets.zero
                    : const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  if (showLoading)
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: const AppLoading(),
                    )
                  else if (showError)
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: ErrorState(
                        message: provider.reportsError!,
                        onRetry: _load,
                      ),
                    )
                  else if (showEmptyState)
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: const EmptyState(
                        icon: Icons.description_outlined,
                        title: 'No reports yet',
                        subtitle:
                            'Your audits will show up here once they\'re scheduled.',
                      ),
                    )
                  else if (items.isEmpty)
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.5,
                      child: EmptyState(
                        icon: Icons.filter_alt_off_outlined,
                        title: hasActiveTextOrDateFilter
                            ? 'No audits match your filters'
                            : auditStatusEmptyTitle(_statusFilter),
                      ),
                    )
                  else
                    for (int i = 0; i < items.length; i++) ...[
                      _buildItem(items[i]),
                      if (i != items.length - 1) const SizedBox(height: 10),
                    ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItem(_TopLevelItem item) {
    if (item.batchId == null) {
      final audit = item.members.first;
      if (audit.hasMultipleZones) {
        return _PerLocationReportCard(
          audit: audit,
          isDownloading: _downloadingAuditId == audit.id,
          onDownload: () => _download(audit),
        );
      }
      return _ReportCard(
        audit: audit,
        isDownloading: _downloadingAuditId == audit.id,
        onDownload: () => _download(audit),
      );
    }
    final batchId = item.batchId!;
    return _BatchReportCard(
      batchId: batchId,
      members: item.members,
      isExpanded: _expandedBatchIds.contains(batchId),
      onToggle: () => setState(() {
        if (!_expandedBatchIds.remove(batchId)) _expandedBatchIds.add(batchId);
      }),
      isDownloadingCombined: _downloadingBatchId == batchId,
      onDownloadCombined: () =>
          _downloadCombined(batchId, item.members, item.members.first.title),
      downloadingMemberId: _downloadingAuditId,
      onDownloadMember: _download,
    );
  }
}

class _TopLevelItem {
  final String? batchId; // null = single audit; item.members has exactly 1
  final List<AuditModel> members;
  const _TopLevelItem({this.batchId, required this.members});
}

// Same grouping the web Final Report page's own batchGroups/topLevelAudits
// use: a batch where only ONE of this employee's own zones shows up here
// renders as a plain single card, not a "1 location" expandable one; a
// batch with more than one of this employee's own zones visible renders
// once, at its first-seen position, as one expandable card.
List<_TopLevelItem> _groupByBatch(List<AuditModel> audits) {
  final byBatch = <String, List<AuditModel>>{};
  for (final a in audits) {
    final bId = a.scheduleBatchId;
    if (bId == null) continue;
    byBatch.putIfAbsent(bId, () => []).add(a);
  }
  final seen = <String>{};
  final result = <_TopLevelItem>[];
  for (final a in audits) {
    final bId = a.scheduleBatchId;
    final group = bId != null ? byBatch[bId] : null;
    if (group == null || group.length <= 1) {
      result.add(_TopLevelItem(members: [a]));
      continue;
    }
    if (seen.contains(bId)) continue;
    seen.add(bId!);
    result.add(_TopLevelItem(batchId: bId, members: group));
  }
  return result;
}

// Opens the range picker; once a range is set, shows it as a small dated
// chip instead of a bare icon so the active filter stays visible without
// having to reopen the picker — same "show what's active" idea as the
// status ChoiceChips above it, just for a range instead of one value.
class _DateFilterButton extends StatelessWidget {
  final DateTime? fromDate;
  final DateTime? toDate;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _DateFilterButton({
    required this.fromDate,
    required this.toDate,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = fromDate != null && toDate != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 44,
        padding: EdgeInsets.symmetric(horizontal: active ? 10 : 12),
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
          border: Border.all(
            color: active ? Colors.transparent : scheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_month_outlined,
              size: 18,
              color: active ? scheme.primary : scheme.outline,
            ),
            if (active) ...[
              const SizedBox(width: 6),
              Text(
                '${Formatters.date(fromDate)} – ${Formatters.date(toDate)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 2),
              InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(999),
                child: Icon(Icons.close, size: 15, color: scheme.primary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Color _scoreColor(BuildContext context, double? score) {
  final scheme = Theme.of(context).colorScheme;
  if (score == null) return scheme.outline;
  if (score >= 75) return Colors.green;
  if (score >= 50) return Colors.orange;
  return Colors.red;
}

Widget _scoreBadge(BuildContext context, double? score) {
  final color = _scoreColor(context, score);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      score != null ? '${score.round()}%' : '—',
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w700,
        fontSize: 12.5,
      ),
    ),
  );
}

// A small, icon-only "Download PDF" action — replaces what used to be a
// full-width labeled button on every card/row here, which ate a whole
// extra line each for something everyone already recognizes as a PDF
// icon. Wrapped in its own tap-through guard (a disabled IconButton
// mid-download has no gesture recognizer of its own, so without this the
// surrounding card/row's own InkWell — expand toggle, or "open detail" —
// would win the tap instead and act out from under a download that's
// still running), same reasoning as every other download button here.
class _PdfIconButton extends StatelessWidget {
  final bool isDownloading;
  final VoidCallback onPressed;
  final double size;

  const _PdfIconButton({
    required this.isDownloading,
    required this.onPressed,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: IconButton(
        onPressed: isDownloading ? null : onPressed,
        tooltip: 'Download PDF',
        visualDensity: VisualDensity.compact,
        constraints: BoxConstraints.tightFor(
          width: size + 12,
          height: size + 12,
        ),
        padding: EdgeInsets.zero,
        icon: isDownloading
            ? SizedBox(
                height: size - 4,
                width: size - 4,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: scheme.outline,
                ),
              )
            : Icon(
                Icons.picture_as_pdf_outlined,
                size: size,
                color: scheme.primary,
              ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final AuditModel audit;
  final bool isDownloading;
  final VoidCallback onDownload;

  const _ReportCard({
    required this.audit,
    required this.isDownloading,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      // Opens the same scoring workspace MyAuditsScreen's own cards do
      // (AuditDetailScreen) — for anything no longer active for scoring
      // (Completed, in practice everything this screen defaults to) it
      // already renders fully read-only, so this doubles as the in-app
      // "final report" view web's AuditFullReport.jsx is on the browser.
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AuditDetailScreen(auditId: audit.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          audit.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        if (audit.location.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            audit.location,
                            style: TextStyle(
                              color: scheme.outline,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                        // On-Time / Delayed for a finished audit, beside the
                        // NC-stage badge on the right rather than instead of
                        // it. Under the left column's text (not the badge
                        // column) so the right column keeps its two rows.
                        if (TimelinessPill.shortLabel(audit.timeliness) !=
                            null) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TimelinessPill(timeliness: audit.timeliness),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusBadge(
                        label: audit.displayLabel,
                        color: AppColors.forAuditStatus(audit.displayLabel),
                      ),
                      const SizedBox(height: 4),
                      _scoreBadge(context, audit.scorePercentage),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 14, color: scheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      audit.auditorNames.isNotEmpty
                          ? audit.auditorNames.join(', ')
                          : '—',
                      style: TextStyle(color: scheme.outline, fontSize: 12.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.event_available_outlined,
                    size: 14,
                    color: scheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    Formatters.date(audit.completedDate),
                    style: TextStyle(color: scheme.outline, fontSize: 12.5),
                  ),
                  const SizedBox(width: 4),
                  _PdfIconButton(
                    isDownloading: isDownloading,
                    onPressed: onDownload,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchReportCard extends StatelessWidget {
  final String batchId;
  final List<AuditModel> members;
  final bool isExpanded;
  final VoidCallback onToggle;
  final bool isDownloadingCombined;
  final VoidCallback onDownloadCombined;
  final String? downloadingMemberId;
  final ValueChanged<AuditModel> onDownloadMember;

  const _BatchReportCard({
    required this.batchId,
    required this.members,
    required this.isExpanded,
    required this.onToggle,
    required this.isDownloadingCombined,
    required this.onDownloadCombined,
    required this.downloadingMemberId,
    required this.onDownloadMember,
  });

  // Sum-achieved-over-sum-max across every zone — never an average of
  // each zone's own %, same rule pages/CompletedAudits.jsx#batchScore
  // already uses on the web. Null (not 0%) if any member's own score
  // hasn't come back yet, same "nothing to show" convention as a single
  // report's own null percentage.
  double? get _combinedPercentage {
    if (members.any((m) => m.scoreAchieved == null || m.scoreMax == null))
      return null;
    final achieved = members.fold<double>(
      0,
      (sum, m) => sum + (m.scoreAchieved ?? 0),
    );
    final max = members.fold<double>(0, (sum, m) => sum + (m.scoreMax ?? 0));
    return max > 0 ? (achieved / max * 100) : null;
  }

  // The batch's ONE status — the server's aggregate over every zone of the
  // batch (batchDisplayStatus: the final status appears only once every zone
  // is done), which replaces the old "all zones agree, else Mixed" guess
  // over just this employee's own zones. See auditGroupStatus for the
  // older-server fallback.
  String get _groupStatus => auditGroupStatus(members);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = members.first;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              first.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.layers_outlined,
                                        size: 12,
                                        color: scheme.primary,
                                      ),
                                      const SizedBox(width: 4),
                                      // Flexible: the status badge beside
                                      // this column can now be ~150px wide
                                      // ("NC Verification Pending"), and at
                                      // a large text size the chip must
                                      // give way rather than overflow.
                                      Flexible(
                                        child: Text(
                                          '${members.length} locations',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: scheme.primary,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                // The whole batch's On-Time / Delayed —
                                // set by the server only once every zone is
                                // completed (batchTimeliness), so it never
                                // shows for a batch still in progress.
                                TimelinessPill(
                                  timeliness: auditGroupTimeliness(members),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // The status badge sits ABOVE the score/PDF/chevron
                      // cluster rather than in the same row: a lifecycle
                      // status can be "NC Verification Pending" (~150px),
                      // which in one row left the title and the "N
                      // locations" chip about 50px on a phone.
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          StatusBadge(
                            label: _groupStatus,
                            color: AppColors.forAuditStatus(_groupStatus),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _scoreBadge(context, _combinedPercentage),
                              const SizedBox(width: 4),
                              // Combined — spans every zone in this batch,
                              // not just one member (see onDownloadCombined).
                              _PdfIconButton(
                                isDownloading: isDownloadingCombined,
                                onPressed: onDownloadCombined,
                              ),
                              Icon(
                                isExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                color: scheme.outline,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              child: Column(
                children: [
                  for (final m in members)
                    InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AuditDetailScreen(auditId: m.id),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            top: BorderSide(
                              color: scheme.outlineVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.location_on_outlined,
                              size: 13,
                              color: scheme.outline,
                            ),
                            const SizedBox(width: 4),
                            // The zone's status goes UNDER its name (with
                            // its On-Time / Delayed pill), not beside it:
                            // "NC Verification Pending" next to a score and
                            // a PDF button left the name a few characters.
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.location.isNotEmpty ? m.location : m.title,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                      color: scheme.onSurface,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    crossAxisAlignment: WrapCrossAlignment.center,
                                    children: [
                                      StatusBadge(
                                        label: m.displayLabel,
                                        color: AppColors.forAuditStatus(
                                          m.displayLabel,
                                        ),
                                      ),
                                      TimelinessPill(timeliness: m.timeliness),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            _scoreBadge(context, m.scorePercentage),
                            const SizedBox(width: 2),
                            _PdfIconButton(
                              isDownloading: downloadingMemberId == m.id,
                              onPressed: () => onDownloadMember(m),
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// One zone's own score within a "per-location" audit's own checklist —
// see _PerLocationReportCard below.
class _ZoneScore {
  final String label;
  final int? pct;
  const _ZoneScore({required this.label, required this.pct});
}

// A "per-location" audit (AuditModel.hasMultipleZones) is still ONE
// document — unlike _BatchReportCard above (several separate documents
// sharing scheduleBatchId), there's nothing to group here; this single
// card just reveals its OWN internal zones on demand, same "N zones ⌄"
// expand as the web Final Report page's ownZoneSections (pages/
// CompletedAudits.jsx). ReportsScreen's own AuditModel list is
// deliberately lightweight (no parameter tree — see its class doc
// comment), so each zone's own score is computed lazily, only once this
// card is actually expanded, from one full report fetch (the same GET
// already used for the PDF download) via utils/report_sections.dart — the
// Dart port of AuditReportShared.jsx already used to build that PDF.
// A StatefulWidget of its own (unlike _ReportCard/_BatchReportCard above,
// whose expand/download state is hoisted to _ReportsScreenState) since
// the fetch-and-cache-once-expanded lifecycle here is genuinely private
// to this one card — same reasoning checkpoint_card.dart's own isolated
// State already follows for ITS async save/upload lifecycle.
class _PerLocationReportCard extends StatefulWidget {
  final AuditModel audit;
  final bool isDownloading;
  final VoidCallback onDownload;

  const _PerLocationReportCard({
    required this.audit,
    required this.isDownloading,
    required this.onDownload,
  });

  @override
  State<_PerLocationReportCard> createState() =>
      _PerLocationReportCardState();
}

class _PerLocationReportCardState extends State<_PerLocationReportCard> {
  bool _expanded = false;
  bool _loadingZones = false;
  String? _zonesError;
  // Cached once fetched — re-collapsing/re-expanding within the same
  // screen visit reuses this instead of re-fetching the whole report
  // every time.
  List<_ZoneScore>? _zones;

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) _loadZonesIfNeeded();
  }

  Future<void> _loadZonesIfNeeded() async {
    if (_zones != null || _loadingZones) return;
    setState(() {
      _loadingZones = true;
      _zonesError = null;
    });
    final detail = await context.read<AuditsProvider>().fetchAuditReportDetail(
          widget.audit.id,
        );
    if (!mounted) return;
    setState(() {
      _loadingZones = false;
      if (detail == null) {
        _zonesError = 'Could not load these zones.';
      } else {
        _zones = _computeZoneScores(detail);
      }
    });
  }

  // Sum-then-divide over each zone's own scored leaves — never an average
  // of pre-calculated percentages, same rule sumAchievedMax's own doc
  // comment (and every other rollup in this app) already follows.
  List<_ZoneScore> _computeZoneScores(AuditDetailModel detail) {
    final isWeightage = detail.scoringSystem == 'weightage';
    return buildReportSections(detail).map((section) {
      final leaves = collectScoredLeaves(section.tree);
      final am = sumAchievedMax(
        leaves,
        isWeightage ? 'weightage' : 'normal',
        detail.maxScore,
      );
      return _ZoneScore(label: section.label, pct: percentageOf(am));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final audit = widget.audit;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          audit.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.layers_outlined,
                                size: 12,
                                color: scheme.primary,
                              ),
                              const SizedBox(width: 4),
                              // Flexible for the same reason as the batch
                              // card's "N locations" chip.
                              Flexible(
                                child: Text(
                                  '${audit.locationCount} zones',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: scheme.primary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (TimelinessPill.shortLabel(audit.timeliness) !=
                            null) ...[
                          const SizedBox(height: 4),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TimelinessPill(timeliness: audit.timeliness),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Badge above the score/PDF/chevron cluster, not in the
                  // same row — see _BatchReportCard's header for why (a
                  // lifecycle status can be "NC Verification Pending").
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      StatusBadge(
                        label: audit.displayLabel,
                        color: AppColors.forAuditStatus(audit.displayLabel),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _scoreBadge(context, audit.scorePercentage),
                          const SizedBox(width: 4),
                          _PdfIconButton(
                            isDownloading: widget.isDownloading,
                            onPressed: widget.onDownload,
                          ),
                          Icon(
                            _expanded ? Icons.expand_less : Icons.expand_more,
                            color: scheme.outline,
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.3),
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              child: _loadingZones
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : _zonesError != null
                      ? Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _zonesError!,
                                  style: TextStyle(
                                    color: scheme.error,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                              TextButton.icon(
                                onPressed: _loadZonesIfNeeded,
                                icon: const Icon(Icons.refresh, size: 15),
                                label: const Text('Retry'),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  minimumSize: Size.zero,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          children: [
                            // Every zone opens the SAME audit — a
                            // "per-location" audit is one document, so
                            // there's no separate zone-scoped screen to
                            // push (unlike a batch member above, which is
                            // its own document with its own id); this is
                            // just a quicker way in than scrolling the
                            // full checklist to find that zone.
                            for (final z in _zones!)
                              InkWell(
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        AuditDetailScreen(auditId: audit.id),
                                  ),
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        color: scheme.outlineVariant
                                            .withValues(alpha: 0.5),
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.location_on_outlined,
                                        size: 13,
                                        color: scheme.outline,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          z.label,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13,
                                            color: scheme.onSurface,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      _scoreBadge(
                                        context,
                                        z.pct?.toDouble(),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
            ),
        ],
      ),
    );
  }
}
