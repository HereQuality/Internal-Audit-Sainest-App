import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../core/network/dio_client.dart';
import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_status.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/report_stats.dart';
import '../../core/utils/snackbar.dart';
import '../../models/audit_detail_model.dart';
import '../../models/audit_model.dart';
import '../../providers/audits_provider.dart';
import '../../providers/filter_options_provider.dart';
import '../../providers/list_view_memory.dart';
import '../../providers/nc_provider.dart';
import '../../utils/report_pdf_builder.dart';
import '../../utils/report_sections.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/audit_agenda.dart' show AgendaEntry;
import '../../widgets/audit_filter_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart' show AuditFilterSelection, applyAuditFilterSelection;
import '../../widgets/max_width_scroll.dart';
import '../../widgets/report_tiles.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/status_filter_chip_row.dart';
import '../audits/audit_detail_screen.dart';
import '../reports/nc_report_tab.dart';
import '../reports/repeated_ncs_tab.dart';

/// The Reports tab (titled "Final Report" to match the web app) — a bottom-bar
/// destination of BOTH panels, with three tabs like the web page: Audits | NCs |
/// Repeated NCs, under ONE shared filter bar (Team, Members, Location +
/// Department, Audit Type, Date; Flag on the NC tabs) that all three honour.
///
/// Every list comes from the Final Report's own endpoints, open to every
/// logged-in user (GET /audits/report, /ncs/report, /ncs/repeats and the stats
/// beside them): the people + places rule is the server's — Me (the default) is
/// a real narrowing to the audits (and bundle zones) I am on, All Members is what
/// adds the places I belong to or lead, a Team / Members pick narrows — so
/// nothing here re-implements scope.
///
/// [embedded] is the shell tab: AppShell already owns the Scaffold and AppBar, so
/// this draws only its body; standalone (the default) it brings its own. The tab
/// stays mounted while another tab shows, so [isActive] says whether it is the
/// one on screen — only then do filter changes refetch it (a change made
/// elsewhere just marks it stale, and opening it reloads).
///
/// The Audits tab is narrowed by status chips, a search box and the tiles (each a
/// tap-filter), mirroring the web app's Final Report page
/// (client/src/pages/CompletedAudits.jsx). Each card is downloadable as a real
/// PDF (utils/report_pdf_builder.dart — deliberately PDF-only on mobile,
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
/// groups its zones into one expandable card — same "N locations"
/// tap-to-expand pattern the web table uses — instead of listing each zone as
/// its own separate, look-alike row. The group's own header additionally offers
/// a combined "Download PDF" spanning every zone in it.
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
  final bool embedded;
  final bool isActive;

  const ReportsScreen({super.key, this.embedded = false, this.isActive = true});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen>
    with SingleTickerProviderStateMixin {
  // Also the Audits tab's memory id — the host only adds the picked tab to it.
  static const _memoryId = 'reports';

  late final ListScreenMemory _saved;
  late final TabController _tabs;
  // Held from initState: dispose has no context to read them with.
  late final AuditsProvider _audits;
  late final NcProvider _ncs;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _saved = context.read<ListViewMemory>().screen(_memoryId);
    _audits = context.read<AuditsProvider>();
    _ncs = context.read<NcProvider>();
    _tabs = TabController(
      length: 3,
      vsync: this,
      initialIndex: _saved.tab.clamp(0, 2),
    )..addListener(_onTab);
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _activate());
    }
  }

  @override
  void didUpdateWidget(ReportsScreen old) {
    super.didUpdateWidget(old);
    if (widget.isActive == old.isActive) return;
    if (widget.isActive) {
      // Not now: this runs while the shell is building, and the loads below
      // notify their providers straight away.
      WidgetsBinding.instance.addPostFrameCallback((_) => _activate());
    } else {
      _deactivate();
    }
  }

  @override
  void dispose() {
    _deactivate();
    _tabs.dispose();
    super.dispose();
  }

  void _onTab() {
    if (_tabs.index == _saved.tab) return;
    _saved.tab = _tabs.index;
    // A search box focused on the tab being left must not follow to the next.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {});
  }

  // This tab is the one on screen: filter changes now refetch its three lists,
  // and what moved while it was away (or never loaded) is loaded now.
  void _activate() {
    if (!mounted || !widget.isActive) return;
    _audits.reportsInUse = true;
    _ncs.ncReportsInUse = true;
    if (!_loaded || _audits.reportsStale || _ncs.ncReportsStale) _load();
  }

  void _deactivate() {
    _audits.reportsInUse = false;
    _ncs.ncReportsInUse = false;
  }

  Future<void> _load() async {
    _loaded = true;
    await Future.wait([
      _audits.fetchReportAudits(),
      _audits.fetchReportStats(),
      _ncs.fetchNcReport(),
      _ncs.fetchNcReportStats(),
      _ncs.fetchRepeats(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        // ONE filter bar for all three tabs. Flag only narrows NCs, so it is
        // offered (and counted, and shown as a pill) on the two NC tabs.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: AuditFilterBar(showFlag: _tabs.index != 0),
        ),
        TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Audits'),
            Tab(text: 'NCs'),
            Tab(text: 'Repeated NCs'),
          ],
        ),
        // Not a TabBarView: its horizontal swipe would swallow the drag that
        // moves the shell to the previous tab (Reports is the last one).
        Expanded(
          child: IndexedStack(
            index: _tabs.index,
            children: const [
              _AuditsReportTab(),
              NcReportTab(),
              RepeatedNcsTab(),
            ],
          ),
        ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: const Text('Final Report')), body: body);
  }
}

// Same "fetch once, filter locally" reasoning — and same matching rules
// (core/utils/audit_status.dart#auditMatchesStatusFilter) — as
// my_audits_screen.dart's own chips, in this screen's own order:
//   * 'All' is the default: the list is every started audit, the same rows
//     the tiles above count (Total Audits, In Progress, Completed...);
//   * 'Completed' is every audit whose auditor has finished it — matched on the
//     RAW stored status, whatever its NC stage;
//   * the two timeliness chips and the NC-stage chips narrow within it;
//   * Not Started / In Progress / Overdue are the unfinished stages.
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

/// The Audits tab: the stat tiles, search, status chips and the report cards.
class _AuditsReportTab extends StatefulWidget {
  const _AuditsReportTab();

  @override
  State<_AuditsReportTab> createState() => _AuditsReportTabState();
}

class _AuditsReportTabState extends State<_AuditsReportTab> {
  static const _memoryId = 'reports';

  // Which row's PDF is currently generating — gates that one row's download
  // button (spinner in place of the icon) without blocking the rest of the
  // list.
  String? _downloadingAuditId;
  // Which batch's COMBINED pdf is generating — separate from the single-
  // audit state above since a batch card's own download button sits
  // alongside its members' individual ones.
  String? _downloadingBatchId;

  // Everything the user can set on this screen is remembered in
  // ListViewMemory, so opening a report and pressing Back — or leaving and
  // returning — finds the same view, chip, search, tiles, expanded card and
  // scroll position (wiped on logout).
  late final ListScreenMemory _saved;
  late final ScrollController _scroll;

  // The raw stored-status / display-status chip (see _statusFilters).
  late String _statusFilter;
  late final TextEditingController _searchController;
  late String _search;
  // The tiles picked as filters ('inProgress' | 'overdue' | 'notStarted' |
  // 'onTime' | 'delayed' | 'skipped' | 'notAttempted' | 'other' —
  // ReportStats.idsFor). Several can be on, they OR together, and
  // they AND with the chip and the search.
  late Set<String> _tiles;
  // Location-wise view: one header per location above its audits.
  late bool _byLocation;
  // Accordion: the key of the ONE bundle / series card that is open.
  String? _expandedKey;
  // Location-wise view: every group starts COLLAPSED — just its header
  // (place, report count, cumulative score), its own audits hidden until
  // that header is tapped. More than one can be open at once, unlike
  // _expandedKey above.
  Set<String> _expandedLocationKeys = {};
  Timer? _statsDebounce;

  @override
  void initState() {
    super.initState();
    _saved = context.read<ListViewMemory>().screen(_memoryId);
    _statusFilter = _saved.extra['status'] as String? ?? 'All';
    _byLocation = _saved.extra['grouped'] == true;
    // A remembered 'completed' tile (the tile no longer exists) must not linger as a hidden filter.
    _tiles = {...?((_saved.extra['tiles'] as List?)?.cast<String>().where((k) => k != 'completed'))};
    _expandedKey = _saved.extra['expanded'] as String?;
    _expandedLocationKeys = {
      ...?((_saved.extra['expandedLocations'] as List?)?.cast<String>()),
    };
    _search = _saved.search;
    _searchController = TextEditingController(text: _saved.search);
    _scroll = ScrollController(initialScrollOffset: _saved.scroll)
      ..addListener(() {
        if (_scroll.hasClients) _saved.scroll = _scroll.offset;
      });
    // Before the host's first load: the tiles must describe these rows.
    _syncQuery(context.read<AuditsProvider>());
  }

  @override
  void dispose() {
    _statsDebounce?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // The status chip as the server understands it, for the stat tiles: 'All'
  // means no status filter, the rest are the same labels the list endpoints
  // take (the legacy 'Completed' is stored-status equality there).
  String? get _statsStatus => _statusFilter == 'All' ? null : _statusFilter;

  void _syncQuery(AuditsProvider p) {
    p.reportsStatus = _statsStatus;
    p.reportsSearch = _search;
    p.reportsTileKeys = {..._tiles};
    p.reportsByLocation = _byLocation;
  }

  Future<void> _reload() {
    final p = context.read<AuditsProvider>();
    _syncQuery(p);
    return Future.wait([p.fetchReportAudits(), p.fetchReportStats()]);
  }

  void _remember() {
    _saved
      ..extra['status'] = _statusFilter
      ..extra['grouped'] = _byLocation
      ..extra['tiles'] = _tiles.toList()
      ..extra['expanded'] = _expandedKey
      ..extra['expandedLocations'] = _expandedLocationKeys.toList();
  }

  void _toggleLocationGroup(String key) {
    setState(() {
      if (!_expandedLocationKeys.add(key)) _expandedLocationKeys.remove(key);
    });
    _remember();
  }

  // The place headers follow the tile picks while the location-wise view shows
  // (the server narrows them to the picked tiles' audits), so the stats are
  // asked again whenever that narrowing starts, changes or ends — and not
  // otherwise.
  bool get _narrowed => _byLocation && _tiles.isNotEmpty;

  void _afterViewChange({required bool wasNarrowed}) {
    _remember();
    if (wasNarrowed || _narrowed) {
      _refreshTiles();
    } else {
      _syncQuery(context.read<AuditsProvider>());
    }
  }

  void _toggleTile(String key) {
    final was = _narrowed;
    setState(
      () => _tiles = _tiles.contains(key)
          ? ({..._tiles}..remove(key))
          : {..._tiles, key},
    );
    _afterViewChange(wasNarrowed: was);
  }

  void _clearTiles() {
    if (_tiles.isEmpty) return;
    final was = _narrowed;
    setState(() => _tiles = {});
    _afterViewChange(wasNarrowed: was);
  }

  // The chip and the search text are client-side filters over the loaded rows
  // (as ever); the stat tiles ask the server for the same population, so they
  // are re-requested — the search debounced, it changes on every keystroke.
  void _refreshTiles({bool debounce = false}) {
    final p = context.read<AuditsProvider>();
    _syncQuery(p);
    _statsDebounce?.cancel();
    if (debounce) {
      _statsDebounce = Timer(const Duration(milliseconds: 450), () {
        if (mounted) p.fetchReportStats();
      });
    } else {
      p.fetchReportStats();
    }
  }

  bool _matchesSearch(AuditModel a) {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return true;
    return a.title.toLowerCase().contains(q) ||
        a.location.toLowerCase().contains(q) ||
        (a.auditee.name?.toLowerCase().contains(q) ?? false) ||
        a.auditorNames.any((n) => n.toLowerCase().contains(q));
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
      final pdfStats = ReportPdfStats();
      final bytes = await buildReportPdf(detail, stats: pdfStats);
      if (bytes.isEmpty) throw Exception('Could not generate this report.');
      await Printing.sharePdf(
        bytes: bytes,
        filename: '${_sanitizedFileName(audit.title)}.pdf',
      );
      // Photos that still failed after the builder's retry are grey boxes in
      // the PDF — say so, instead of leaving the user to find out on page 90.
      final photoWarning = pdfStats.photoWarning;
      if (mounted && photoWarning != null) showErrorSnackBar(context, photoWarning);
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

  // The zones the CARD shows. A card that lists every zone of its bundle asks for
  // the whole batch; one that lists only some (`members` fewer than the
  // bundle's batchZoneCount — "Me" lists just the zones you are on) asks for
  // exactly those, via zoneIds, so the combined PDF matches what the card shows.
  // AuditsProvider#fetchBatchReport's own header comment has the full story:
  // looping fetchAuditReportDetail per member here used to silently drop every
  // OTHER auditor's zone from a "combined" report, the mobile side of the
  // "only his own coming, not the full one" gap against the web app's Final
  // Report page. That endpoint (audit.controller.js#getBatchReport) is open to
  // anyone involved in any zone of the batch or a member of a place it covers;
  // anything it still refuses (a role outside both, a slow connection's
  // timeout) falls back to the old per-member loop below (still every zone THIS
  // employee can open) rather than the combined download just failing
  // outright.
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
        final report = await provider.fetchBatchReport(
          batchId,
          zoneIds: isPartialBundle(members) ? [for (final m in members) m.id] : null,
        );
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
      final pdfStats = ReportPdfStats();
      final bytes = await buildCombinedReportPdf(
        zones,
        batchStatus: batchStatus,
        stats: pdfStats,
      );
      if (bytes.isEmpty) throw Exception('Could not generate this report.');
      await Printing.sharePdf(
        bytes: bytes,
        filename: '${_sanitizedFileName(title)}-combined.pdf',
      );
      final photoWarning = pdfStats.photoWarning;
      if (mounted && photoWarning != null) showErrorSnackBar(context, photoWarning);
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
    final source = provider.reportAudits;
    final bool showError = provider.reportsError != null && source.isEmpty;
    final bool showLoading =
        provider.isLoadingReports && source.isEmpty && !showError;
    // The chip and the search narrow the loaded rows on the device; the tiles
    // then come from the server for the same population (chip + search are sent
    // with the stats request), tile picks narrowing the rows last.
    final base = source
        .where((a) => auditMatchesStatusFilter(a, _statusFilter))
        .where(_matchesSearch)
        .toList();
    final bool showEmptyState =
        !showLoading && !showError && source.isEmpty;
    final hasFilters =
        provider.activeFilterCountFor(status: false, flag: false) > 0;
    // The tiles are the server's (GET /audits/report/stats, the same population
    // as the list), but only while they agree with the rows on screen: the
    // device's search can be narrower than the server's. When they differ — or
    // the request failed — the tiles are worked out from the rows, so numbers
    // match what is listed.
    final rowStats = ReportStats.fromAudits(base);
    final serverStats = provider.reportStats;
    final stats = serverStats != null &&
            (showLoading || serverStats.totalAudits == rowStats.totalAudits)
        ? serverStats
        : rowStats;
    // A tile pick narrows by the audit ids the tile counted (every member of a
    // bundle is among them) — the ids, not a re-derivation of the rule.
    final tileIds = _tiles.isEmpty
        ? null
        : {for (final k in _tiles) ...stats.idsFor(k)};
    final filtered = tileIds == null
        ? base
        : base.where((a) => tileIds.contains(a.id)).toList();
    final items = _groupTopLevel(filtered);
    final scheme = Theme.of(context).colorScheme;
    const gutter = EdgeInsets.symmetric(horizontal: 16);

    return RefreshIndicator(
      onRefresh: _reload,
      child: MaxWidthScroll(
        child: ListView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _ReportStatTiles(
                stats: stats,
                scopeLabel: _scopeLabel(provider),
                picked: _tiles,
                onToggle: _toggleTile,
                onClear: _clearTiles,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            _saved.search = '';
                            setState(() => _search = '');
                            _refreshTiles();
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onChanged: (v) {
                  _saved.search = v;
                  setState(() => _search = v);
                  _refreshTiles(debounce: true);
                },
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
              onSelected: (v) {
                setState(() => _statusFilter = v);
                _remember();
                _refreshTiles();
              },
            ),
            if (items.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${items.length} ${items.length == 1 ? 'report' : 'reports'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.place_outlined, size: 16),
                      label: const Text('Group by location'),
                      selected: _byLocation,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      onSelected: (v) {
                        final was = _narrowed;
                        setState(() => _byLocation = v);
                        _afterViewChange(wasNarrowed: was);
                      },
                    ),
                  ],
                ),
              ),
            if (showLoading)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: const AppLoading(),
              )
            else if (showError)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: ErrorState(
                  message: provider.reportsError!,
                  onRetry: _reload,
                ),
              )
            else if (showEmptyState)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: hasFilters
                    ? EmptyState(
                        icon: Icons.filter_alt_off_outlined,
                        title: 'No audits match your filters',
                        subtitle:
                            'Try widening the people, place or date range.',
                        action: OutlinedButton.icon(
                          onPressed: () => applyAuditFilterSelection(
                            context,
                            AuditFilterSelection.cleared,
                          ),
                          icon: const Icon(Icons.filter_alt_off_outlined),
                          label: const Text('Clear filters'),
                        ),
                      )
                    : const EmptyState(
                        icon: Icons.description_outlined,
                        title: 'No reports yet',
                        subtitle:
                            'Audits you are on show up here once they start. Pick All Members to include the places you belong to or lead.',
                      ),
              )
            else if (items.isEmpty)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: EmptyState(
                  icon: Icons.filter_alt_off_outlined,
                  title: _tiles.isNotEmpty
                      ? 'No audits under the picked tiles'
                      : _search.trim().isNotEmpty
                      ? 'No audits match your filters'
                      : auditStatusEmptyTitle(_statusFilter),
                ),
              )
            else
              Padding(
                padding: gutter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _byLocation
                      ? _locationSections(items, filtered, stats)
                      : [
                          for (int i = 0; i < items.length; i++) ...[
                            _buildItem(items[i]),
                            if (i != items.length - 1) const SizedBox(height: 10),
                          ],
                        ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // What the tiles are "of": the picked places.
  String? _scopeLabel(AuditsProvider p) {
    final options = context.watch<FilterOptionsProvider>();
    final names = <String>[
      for (final id in p.locationFilter)
        options.locations.where((l) => l.id == id).map((l) => l.name).firstOrNull ??
            'Location',
      for (final id in p.departmentFilter)
        options.departments.where((d) => d.id == id).map((d) => d.name).firstOrNull ??
            'Department',
    ];
    return names.isEmpty ? null : names.join(', ');
  }

  // A multi-location bundle is exploded into one synthetic single-zone item per
  // member — each already carries its OWN real location (see
  // AuditModel.location) — instead of being kept whole and dumped into one
  // shared "Multi-location bundles" bucket regardless of which real places
  // its zones were actually at, which used to mix totally unrelated
  // bundles' scores into one meaningless combined %. Mirrors the identical
  // fix on the web Final Report page (pages/CompletedAudits.jsx).
  List<_TopLevelItem> _explodeBundles(List<_TopLevelItem> items) => [
    for (final item in items)
      if (item.batchId != null)
        for (final m in item.members) _TopLevelItem(members: [m])
      else
        item,
  ];

  // The location-wise view: one header per place — its name, how many reports
  // and its CUMULATIVE score (Σ achieved / Σ possible, never an average of
  // percentages) — above that place's rows.
  //
  // The header numbers are the SERVER's `byLocation` (over the whole filtered
  // set, narrowed to the tile's audits while a tile is picked), never worked
  // out from the rows loaded here; `auditIds` says which loaded rows sit under
  // which header. Only when the server sent no breakdown (an older server, a
  // failed request) does the view group the rows by their own place and count
  // them on the device.
  List<Widget> _locationSections(
    List<_TopLevelItem> items,
    List<AuditModel> filtered,
    ReportStats stats,
  ) {
    final places = stats.byLocation;
    if (places.isEmpty || places.every((p) => p.auditIds.isEmpty)) {
      return _localLocationSections(items);
    }
    return [for (final place in places) ..._placeSection(place, filtered)];
  }

  // One place: its server-numbered header and, once opened, its rows.
  List<Widget> _placeSection(ReportLocationStats place, List<AuditModel> filtered) {
    final ids = place.auditIds.toSet();
    final rows = [for (final a in filtered) if (ids.contains(a.id)) a];
    final expanded = _expandedLocationKeys.contains(place.key);
    return [
      _LocationHeader(
        label: place.label,
        count: place.count,
        // The server's score over the place's FINISHED audits only (none finished:
        // null, so no score is drawn — never 0 or 100).
        percentage: place.percentage,
        isExpanded: expanded,
        onToggle: () => _toggleLocationGroup(place.key),
      ),
      if (expanded)
        for (final item in _explodeBundles(_groupTopLevel(rows))) ...[
          _buildItem(item),
          const SizedBox(height: 10),
        ],
    ];
  }

  // The on-device grouping (see _locationSections): by each row's own place.
  List<Widget> _localLocationSections(List<_TopLevelItem> items) {
    final exploded = _explodeBundles(items);
    final groups = <String, List<_TopLevelItem>>{};
    for (final item in exploded) {
      final key = item.members.first.location.isNotEmpty
          ? item.members.first.location
          : 'No location';
      groups.putIfAbsent(key, () => []).add(item);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        // A zone with no resolvable place sorts last, the rest alphabetical.
        final an = a == 'No location', bn = b == 'No location';
        if (an != bn) return an ? 1 : -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return [
      for (final key in keys) ...[
        () {
          // Only the Completed audits at the place add to its score (same rule
          // as the server's byLocation); none finished draws no score.
          final score = finishedScoreOf([
            for (final i in groups[key]!) ...i.members,
          ]);
          return _LocationHeader(
            label: key,
            count: groups[key]!.length,
            percentage: score.percentage,
            isExpanded: _expandedLocationKeys.contains(key),
            onToggle: () => _toggleLocationGroup(key),
          );
        }(),
        if (_expandedLocationKeys.contains(key))
          for (final item in groups[key]!) ...[
            _buildItem(item),
            const SizedBox(height: 10),
          ],
      ],
    ];
  }

  void _toggleExpanded(String key) {
    setState(() => _expandedKey = _expandedKey == key ? null : key);
    _remember();
  }

  Widget _buildItem(_TopLevelItem item) {
    if (item.seriesId != null) {
      final key = 'series:${item.seriesId}';
      return _SeriesReportCard(
        entry: AgendaEntry(item.members),
        isExpanded: _expandedKey == key,
        onToggle: () => _toggleExpanded(key),
        downloadingId: _downloadingAuditId,
        onDownload: _download,
      );
    }
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
    final key = 'batch:$batchId';
    return _BatchReportCard(
      batchId: batchId,
      members: item.members,
      isExpanded: _expandedKey == key,
      onToggle: () => _toggleExpanded(key),
      isDownloadingCombined: _downloadingBatchId == batchId,
      onDownloadCombined: () =>
          _downloadCombined(batchId, item.members, item.members.first.title),
      downloadingMemberId: _downloadingAuditId,
      onDownloadMember: _download,
    );
  }
}

/// How many zones the bundle [members] belong to has in total, from the
/// `batchZoneCount` the server stamps on each row; null when it did not say.
int? _bundleZoneTotal(List<AuditModel> members) {
  int? total;
  for (final m in members) {
    final n = m.batchZoneCount;
    if (n != null && (total == null || n > total)) total = n;
  }
  return total;
}

/// Whether a bundle card lists fewer zones than the bundle has — "Me" lists only
/// the zones you are on.
bool isPartialBundle(List<AuditModel> members) {
  final total = _bundleZoneTotal(members);
  return total != null && members.length < total;
}

/// The bundle card's "N locations", or "N of M locations" when the card holds
/// only some of the bundle's zones.
String bundleLocationsLabel(List<AuditModel> members) {
  final total = _bundleZoneTotal(members);
  return isPartialBundle(members)
      ? '${members.length} of $total locations'
      : '${members.length} locations';
}

class _TopLevelItem {
  final String? batchId; // set = a multi-zone bundle; members has 2+
  final String? seriesId; // set = a recurring series; members has 2+
  // A single audit has exactly one member and neither id.
  final List<AuditModel> members;
  const _TopLevelItem({this.batchId, this.seriesId, required this.members});
}

// Same grouping the web Final Report page's own batchGroups/topLevelAudits
// use: a batch where only ONE of this employee's own zones shows up here
// renders as a plain single card, not a "1 location" expandable one; a
// batch with more than one of this employee's own zones visible renders
// once, at its first-seen position, as one expandable card. On top of that,
// the occurrences of one recurring series (same recurrence.seriesId — never
// just the same frequency word) that are not part of a bundle collapse into
// one expandable series row, exactly like the web's series rows.
List<_TopLevelItem> _groupTopLevel(List<AuditModel> audits) {
  final byBatch = <String, List<AuditModel>>{};
  for (final a in audits) {
    final bId = a.scheduleBatchId;
    if (bId == null) continue;
    byBatch.putIfAbsent(bId, () => []).add(a);
  }
  final bySeries = <String, List<AuditModel>>{};
  for (final a in audits) {
    final sId = a.seriesId;
    if (sId == null || a.scheduleBatchId != null) continue;
    bySeries.putIfAbsent(sId, () => []).add(a);
  }
  final seen = <String>{};
  final result = <_TopLevelItem>[];
  for (final a in audits) {
    final bId = a.scheduleBatchId;
    final group = bId != null ? byBatch[bId] : null;
    if (group != null && group.length > 1) {
      if (seen.add('b:$bId')) {
        result.add(_TopLevelItem(batchId: bId, members: group));
      }
      continue;
    }
    final sId = bId == null ? a.seriesId : null;
    final series = sId != null ? bySeries[sId] : null;
    if (series != null && series.length > 1) {
      if (seen.add('s:$sId')) {
        // Oldest occurrence first, like the agenda's series row.
        final ordered = [...series]..sort((x, y) {
          final xd = x.scheduledDate;
          final yd = y.scheduledDate;
          if (xd == null || yd == null) return 0;
          return xd.compareTo(yd);
        });
        result.add(_TopLevelItem(seriesId: sId, members: ordered));
      }
      continue;
    }
    result.add(_TopLevelItem(members: [a]));
  }
  return result;
}

// ── Stat tiles ──────────────────────────────────────────────────────────

/// The Final Report tiles, for whatever is in view: cumulative Total Score
/// (Σ achieved / Σ possible — never an average of each audit's %), Total
/// Audits, then the buckets Total Audits is made of — In Progress, Overdue,
/// Not Started (only when > 0), On-Time Completed, Delayed Completed, Skipped
/// (only when > 0) and, muted and outside the sum, Not Attempted (only when
/// > 0) — so Total = In Progress + Overdue + Not Started + On-Time + Delayed +
/// Skipped. Every bucket tile is a tap-filter over the list (Total Audits
/// clears them); the score comes from Completed audits only and Total Audits
/// leaves out the Not Attempted ones (the owner's rules, 2026-09-30).
class _ReportStatTiles extends StatelessWidget {
  final ReportStats stats;
  final String? scopeLabel;
  final Set<String> picked;
  final ValueChanged<String> onToggle;
  final VoidCallback onClear;

  const _ReportStatTiles({
    required this.stats,
    required this.picked,
    required this.onToggle,
    required this.onClear,
    this.scopeLabel,
  });

  String _points(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = stats.percentage;
    final scoreColor = pct == null
        ? scheme.outline
        : pct >= 75
        ? Colors.green
        : pct >= 50
        ? Colors.orange
        : Colors.red;
    ReportTileData filter(
      String key,
      String label,
      String value,
      IconData icon,
      Color color, {
      bool muted = false,
    }) => ReportTileData(
      id: key,
      label: label,
      value: value,
      icon: icon,
      color: color,
      muted: muted,
      selected: picked.contains(key),
      onTap: () => onToggle(key),
    );
    final tiles = [
      ReportTileData(
        id: 'score',
        label: 'Total Score',
        // Worked out from Completed audits only (the owner's rule, 2026-09-30):
        // never a "so far" grade over open work, so never starred; "—" while
        // nothing has finished.
        value: pct == null ? '—' : '$pct%',
        sub: stats.maxPossible > 0
            ? '${_points(stats.achieved)} / ${_points(stats.maxPossible)} pts'
            : null,
        icon: Icons.emoji_events_outlined,
        color: scoreColor,
      ),
      ReportTileData(
        id: 'total',
        label: 'Total Audits',
        value: '${stats.totalAudits}',
        icon: Icons.assignment_outlined,
        color: scheme.primary,
        onTap: onClear,
      ),
      filter(
        'inProgress',
        'In Progress',
        '${stats.inProgress}',
        Icons.timelapse_rounded,
        AppColors.forAuditStatus(AuditStatus.inProgress),
      ),
      // The rest of Total Audits, so the tiles add up (owner, 2026-09-30):
      // Total = In Progress + Overdue + Not Started + On-Time + Delayed + Skipped
      // (+ Other). Overdue is always shown; the others only when there is one.
      filter(
        'overdue',
        'Overdue',
        '${stats.overdue}',
        Icons.warning_amber_rounded,
        AppColors.forAuditStatus(AuditStatus.overdue),
      ),
      if (stats.notStarted > 0)
        filter(
          'notStarted',
          'Not Started',
          '${stats.notStarted}',
          Icons.hourglass_empty_rounded,
          AppColors.forAuditStatus(AuditStatus.notStarted),
        ),
      filter(
        'onTime',
        'On-Time Completed',
        '${stats.onTimeCompleted}',
        Icons.check_circle_outline,
        AppColors.forAuditStatus(AuditStatus.onTimeCompleted),
      ),
      filter(
        'delayed',
        'Delayed Completed',
        '${stats.delayedCompleted}',
        Icons.history_toggle_off_rounded,
        AppColors.forAuditStatus(AuditStatus.delayedCompleted),
      ),
      if (stats.skipped > 0)
        filter(
          'skipped',
          'Skipped',
          '${stats.skipped}',
          Icons.skip_next_rounded,
          AppColors.forAuditStatus(AuditStatus.skipped),
        ),
      // A bundle / audit that fits none of the buckets above — rare, but shown
      // so the tiles still add up to Total Audits.
      if (stats.other > 0)
        filter(
          'other',
          'Other',
          '${stats.other}',
          Icons.more_horiz_rounded,
          AppColors.slate,
          muted: true,
        ),
      // Counted apart: never part of Total Audits, so it reads muted.
      if (stats.notAttempted > 0)
        filter(
          'notAttempted',
          'Not Attempted (not in Total)',
          '${stats.notAttempted}',
          Icons.block_rounded,
          AppColors.forAuditStatus(AuditStatus.notAttempted),
          muted: true,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (scopeLabel != null) ...[
          Row(
            children: [
              Icon(Icons.place_outlined, size: 14, color: scheme.outline),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  scopeLabel!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
        ],
        ReportTileGrid(tiles: tiles),
      ],
    );
  }
}

/// A location's header in the location-wise view: the place, how many reports
/// and their cumulative score.
class _LocationHeader extends StatelessWidget {
  final String label;
  final int count;
  // Σ achieved / Σ possible over the place's Completed audits (the server's),
  // null while none has finished — then no score is shown.
  final int? percentage;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _LocationHeader({
    required this.label,
    required this.count,
    required this.percentage,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Tappable — collapsed by default, revealing this location's own
    // audits only once tapped (see _expandedLocationKeys' own doc).
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(
              isExpanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: scheme.outline,
            ),
            const SizedBox(width: 2),
            Icon(Icons.place_outlined, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              [
                '$count ${count == 1 ? 'report' : 'reports'}',
                if (percentage != null) '$percentage%',
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.outline,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The small "this audit repeats" marker every list uses (the web's
/// RecurringBadge): a repeat icon plus the short repeat type ("Weekly"), or a
/// bare "Recurring" when the frequency word is missing. Nothing for an audit
/// that is not part of a series.
class _RecurringBadge extends StatelessWidget {
  final String? frequency;

  const _RecurringBadge({required this.frequency});

  static bool isRecurring(AuditModel a) => a.seriesId != null || a.frequency != null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = (frequency == null || frequency!.isEmpty) ? 'Recurring' : frequency!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.repeat_rounded, size: 11, color: scheme.onTertiaryContainer),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The one repeat type a group of audits shares ("Weekly"), "Mixed" when
  /// they differ, null when none of them repeats — the web's bundleFrequency.
  static String? sharedFrequency(List<AuditModel> members) {
    final recurring = members.where(isRecurring).toList();
    if (recurring.isEmpty) return null;
    final all = {for (final m in recurring) if (m.frequency != null) m.frequency!};
    if (all.length > 1) return 'Mixed';
    return all.isEmpty ? '' : all.first;
  }
}

/// A recurring series collapsed into one row: the series title, "Weekly
/// series · N occurrences" (or another frequency), the span of dates, a per-status tally (a series
/// has no single status of its own), the cumulative score of its finished
/// occurrences and a Recurring badge — expanding to the occurrences' own
/// report cards. Like the web's series row it never opens anything itself:
/// there is no single occurrence a tap could unambiguously mean.
class _SeriesReportCard extends StatelessWidget {
  final AgendaEntry entry;
  final bool isExpanded;
  final VoidCallback onToggle;
  final String? downloadingId;
  final ValueChanged<AuditModel> onDownload;

  const _SeriesReportCard({
    required this.entry,
    required this.isExpanded,
    required this.onToggle,
    required this.downloadingId,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Completed occurrences only: an open / Not Attempted one has no score yet.
    final score = finishedScoreOf(entry.occurrences);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
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
                        child: Text(
                          entry.lead.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _scoreBadge(context, score.percentage?.toDouble()),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        color: scheme.outline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _RecurringBadge(frequency: entry.lead.frequency),
                      Text(
                        entry.seriesLabel,
                        style: TextStyle(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.date_range_outlined, size: 14, color: scheme.outline),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          entry.dateSpan,
                          style: TextStyle(color: scheme.outline, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.statusSummary,
                    style: TextStyle(color: scheme.outline, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded)
          // Indented so the occurrences read as belonging to the row above.
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in entry.occurrences) ...[
                  _ReportCard(
                    audit: a,
                    isDownloading: downloadingId == a.id,
                    onDownload: () => onDownload(a),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
      ],
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

// isPartial: a "*" for a BATCH's score when only some of its zones are
// finished — the score then covers just the finished ones. Never set for a
// single audit: an audit that is not Completed shows "—", not a partial grade.
Widget _scoreBadge(BuildContext context, double? score, {bool isPartial = false}) {
  final color = _scoreColor(context, score);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      score != null ? '${score.round()}%${isPartial ? '*' : ''}' : '—',
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
                        if (TimelinessPill.shortLabel(audit.timeliness) != null ||
                            _RecurringBadge.isRecurring(audit)) ...[
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (_RecurringBadge.isRecurring(audit))
                                _RecurringBadge(frequency: audit.frequency),
                              TimelinessPill(timeliness: audit.timeliness),
                            ],
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
                      // No score shown until this audit has actually finished.
                      _scoreBadge(
                        context,
                        audit.status == AuditStatus.completed ? audit.scorePercentage : null,
                      ),
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

  // Whether every zone is actually Completed. The score below covers only the
  // finished zones, so a batch that is only partly finished carries a "*" (see
  // reports_screen.dart's _scoreBadge isPartial param), like the web's
  // pages/CompletedAudits.jsx; one with no finished zone shows "—".
  bool get _combinedFinished => members.every((m) => m.status == AuditStatus.completed);

  // Σ achieved / Σ possible across the COMPLETED zones only — never an average
  // of each zone's own %, and an open, Not Attempted, Skipped or Draft zone is
  // neither 0 nor 100 but simply left out (the owner's rule, 2026-09-30). Null
  // while no zone has finished.
  double? get _combinedPercentage =>
      finishedScoreOf(members).percentage?.toDouble();

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
                                          bundleLocationsLabel(members),
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
                                // No separate "Bundle" word chip — the "N locations" one
                                // right above already says that; a second badge repeating
                                // it read as confusing clutter, not new information.
                                if (_RecurringBadge.sharedFrequency(members) != null)
                                  _RecurringBadge(
                                    frequency: _RecurringBadge.sharedFrequency(members),
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
                              _scoreBadge(context, _combinedPercentage, isPartial: !_combinedFinished),
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
                            _scoreBadge(
                              context,
                              m.status == AuditStatus.completed ? m.scorePercentage : null,
                            ),
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
    // A zone of an audit that is not Completed yet has no final score: "—",
    // never its progress so far (the owner's rule, 2026-09-30).
    final finished = widget.audit.status == AuditStatus.completed;
    return buildReportSections(detail).map((section) {
      final leaves = collectScoredLeaves(section.tree);
      final am = sumAchievedMax(
        leaves,
        isWeightage ? 'weightage' : 'normal',
        detail.maxScore,
      );
      return _ZoneScore(
        label: section.label,
        pct: finished ? percentageOf(am) : null,
      );
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
                          _scoreBadge(
                            context,
                            audit.status == AuditStatus.completed ? audit.scorePercentage : null,
                          ),
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
