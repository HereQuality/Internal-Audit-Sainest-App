import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/nc_model.dart';
import '../../models/nc_report_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/list_view_memory.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart' show AuditFilterSelection, applyAuditFilterSelection;
import '../../widgets/max_width_scroll.dart';
import '../../widgets/report_tiles.dart';
import '../../widgets/status_badge.dart';
import '../nc/nc_response_screen.dart';
import '../nc/nc_review_screen.dart';

/// Opens an NC from the Final Report. Everyone the report hands an NC to may
/// READ its thread (the server lets Full Access, planners and members/leaders of
/// the NC's place open it), so that is what a tap does — the review screen in
/// read-only mode, whose Approve / Reject bar still only ever appears for the
/// NC's own raiser. The NC's own auditee, on an NC still waiting for their
/// answer, goes straight to the response form instead, as from the NC tab.
void openNcFromReport(BuildContext context, NcModel nc) {
  final me = context.read<AuthProvider>().user?.id;
  final respond = nc.status == 'Raised' && me != null && me == nc.auditee.id;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => respond
          ? NcResponseScreen(nc: nc)
          : NcReviewScreen(nc: nc, readOnly: true),
    ),
  );
}

/// The Final Report's NCs tab: the six NC tiles (each a tap-filter by the NC ids
/// it counted), search, "Group by location" and the NC list — every NC the
/// caller may see under the shared filter bar (GET /ncs/report).
///
/// The bucket pill and the place of each row are the SERVER's (`bucket`,
/// `placeLabel`) — nothing here decides which bucket an NC is in. In the
/// location-wise view the place headers are the server's `byLocation` too (its
/// total and bucket tallies over the whole filtered set), with `ncIds` saying
/// which loaded rows sit under which header.
class NcReportTab extends StatefulWidget {
  const NcReportTab({super.key});

  @override
  State<NcReportTab> createState() => _NcReportTabState();
}

class _NcReportTabState extends State<NcReportTab> {
  static const _memoryId = 'reports-ncs';

  late final ListScreenMemory _saved;
  late final ScrollController _scroll;
  late final TextEditingController _searchController;
  // The bucket tiles picked as filters (NcBucket keys); several OR together.
  late Set<String> _tiles;
  late bool _byLocation;
  Set<String> _expandedPlaces = {};
  // The audit bundles that are open (by group key, scoped to the place in the
  // location-wise view — one audit can sit under two places).
  Set<String> _expandedAudits = {};
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _saved = context.read<ListViewMemory>().screen(_memoryId);
    _tiles = {...?((_saved.extra['tiles'] as List?)?.cast<String>())};
    _byLocation = _saved.extra['grouped'] == true;
    _expandedPlaces = {...?((_saved.extra['expandedLocations'] as List?)?.cast<String>())};
    _expandedAudits = {...?((_saved.extra['expandedAudits'] as List?)?.cast<String>())};
    _searchController = TextEditingController(text: _saved.search);
    _scroll = ScrollController(initialScrollOffset: _saved.scroll)
      ..addListener(() {
        if (_scroll.hasClients) _saved.scroll = _scroll.offset;
      });
    // Before the host's first load: the request must carry what this tab shows.
    _syncQuery(context.read<NcProvider>());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncQuery(NcProvider p) {
    p.ncReportSearch = _saved.search;
    p.ncReportTileKeys = {..._tiles};
    p.ncReportByLocation = _byLocation;
  }

  void _remember() {
    _saved
      ..extra['tiles'] = _tiles.toList()
      ..extra['grouped'] = _byLocation
      ..extra['expandedLocations'] = _expandedPlaces.toList()
      ..extra['expandedAudits'] = _expandedAudits.toList();
  }

  Future<void> _reload() {
    final p = context.read<NcProvider>();
    _syncQuery(p);
    return Future.wait([p.fetchNcReport(), p.fetchNcReportStats()]);
  }

  // The place headers follow the tile picks while the location-wise view shows
  // (the server narrows them to the picked tiles' NCs), so the stats are asked
  // again whenever that narrowing starts, changes or ends — and not otherwise.
  bool get _narrowed => _byLocation && _tiles.isNotEmpty;

  void _afterChange({required bool wasNarrowed}) {
    _remember();
    final p = context.read<NcProvider>();
    _syncQuery(p);
    if (wasNarrowed || _narrowed) p.fetchNcReportStats();
  }

  void _toggleTile(String bucket) {
    final was = _narrowed;
    setState(
      () => _tiles = _tiles.contains(bucket)
          ? ({..._tiles}..remove(bucket))
          : {..._tiles, bucket},
    );
    _afterChange(wasNarrowed: was);
  }

  void _clearTiles() {
    if (_tiles.isEmpty) return;
    final was = _narrowed;
    setState(() => _tiles = {});
    _afterChange(wasNarrowed: was);
  }

  // The search goes to the server (GET /ncs/report?search=) so the list, the
  // tiles and the place headers all describe the same NCs; debounced, it changes
  // on every keystroke.
  void _onSearch(String v) {
    _saved.search = v;
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(Duration(milliseconds: v.isEmpty ? 0 : 450), () {
      if (mounted) _reload();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<NcProvider>();
    final rows = p.reportNcs;
    final stats = p.ncReportStats;
    final showError = p.ncReportError != null && rows.isEmpty;
    final showLoading = p.isLoadingNcReport && rows.isEmpty && !showError;
    // A tile pick narrows by the NC ids the tile counted — the server's list,
    // not a re-derivation of its bucket rule.
    final tileIds = _tiles.isEmpty || stats == null
        ? null
        : {for (final k in _tiles) ...stats.idsFor(k)};
    final filtered = tileIds == null
        ? rows
        : [for (final nc in rows) if (tileIds.contains(nc.id)) nc];
    final scheme = Theme.of(context).colorScheme;
    final hasFilters = p.activeFilterCountFor(status: false) > 0;

    return RefreshIndicator(
      onRefresh: _reload,
      child: MaxWidthScroll(
        child: ListView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            if (stats != null && stats.hasBuckets)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: ReportTileGrid(
                  tiles: ncBucketTiles(
                    stats,
                    selected: _tiles,
                    onToggle: _toggleTile,
                    onClear: _clearTiles,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onChanged: _onSearch,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Search NCs, audit, person...',
                  suffixIcon: _searchController.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchController.clear();
                            _onSearch('');
                          },
                        ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            if (filtered.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _countLine(p, filtered, tileIds != null),
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
                        _afterChange(wasNarrowed: was);
                      },
                    ),
                  ],
                ),
              ),
            if (showLoading)
              SizedBox(height: MediaQuery.of(context).size.height * 0.4, child: const AppLoading())
            else if (showError)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: ErrorState(message: p.ncReportError!, onRetry: _reload),
              )
            else if (rows.isEmpty)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: hasFilters || _searchController.text.isNotEmpty
                    ? EmptyState(
                        icon: Icons.filter_alt_off_outlined,
                        title: 'No NCs match your filters',
                        subtitle: 'Try widening the people, place, date or flag.',
                        action: OutlinedButton.icon(
                          onPressed: () =>
                              applyAuditFilterSelection(context, AuditFilterSelection.cleared),
                          icon: const Icon(Icons.filter_alt_off_outlined),
                          label: const Text('Clear filters'),
                        ),
                      )
                    : const EmptyState(
                        icon: Icons.fact_check_outlined,
                        title: 'No NCs yet',
                        subtitle: 'NCs you raised or are answerable for show up here.',
                      ),
              )
            else if (filtered.isEmpty)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: const EmptyState(
                  icon: Icons.filter_alt_off_outlined,
                  title: 'No NCs under the picked tiles',
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _byLocation
                      ? _placeSections(filtered, stats)
                      : _auditItems(filtered, scope: ''),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // "86 NCs · 41 audits": the server's own totals for what the filters match
  // (true even when fewer rows were loaded); with a tile picked, what the tile
  // leaves — counted from those rows.
  String _countLine(NcProvider p, List<NcModel> rows, bool tilePicked) {
    final ncs = tilePicked ? rows.length : (p.ncReportTotalNcs ?? rows.length);
    final audits = tilePicked
        ? groupNcsByAudit(rows).length
        : (p.ncReportTotalAudits ?? groupNcsByAudit(rows).length);
    return '$ncs ${ncs == 1 ? 'NC' : 'NCs'} · $audits ${audits == 1 ? 'audit' : 'audits'}';
  }

  void _toggleAudit(String key) {
    setState(() {
      if (!_expandedAudits.add(key)) _expandedAudits.remove(key);
    });
    _remember();
  }

  // [rows] as cards: the NCs of one audit together as ONE expandable bundle, an
  // audit's lone NC (or an NC with no audit) as a plain card. Only the NCs that
  // are in [rows] — what the filters and tile picks leave — are in a bundle.
  List<Widget> _auditItems(List<NcModel> rows, {required String scope}) {
    final groups = groupNcsByAudit(rows);
    return [
      for (final (i, g) in groups.indexed) ...[
        if (i > 0) const SizedBox(height: 10),
        if (!g.isBundle)
          _NcReportCard(nc: g.ncs.single)
        else
          _NcGroupCard(
            group: g,
            isOpen: _expandedAudits.contains('$scope${g.key}'),
            onToggle: () => _toggleAudit('$scope${g.key}'),
          ),
      ],
    ];
  }

  void _togglePlace(String key) {
    setState(() {
      if (!_expandedPlaces.add(key)) _expandedPlaces.remove(key);
    });
    _remember();
  }

  // The location-wise view: one header per place — its NC count and the bucket
  // tallies — above that place's rows. The numbers are the SERVER's `byLocation`
  // (whole filtered set, narrowed to the tile's NCs while a tile is picked); only
  // with no breakdown (a failed request) are the rows grouped by their own
  // `placeLabel` and counted on the device.
  List<Widget> _placeSections(List<NcModel> filtered, NcTileStats? stats) {
    final places = stats?.byLocation ?? const <NcLocationStats>[];
    final fromServer = places.isNotEmpty && places.any((pl) => pl.ncIds.isNotEmpty);
    final List<(NcLocationStats, List<NcModel>)> groups;
    if (fromServer) {
      groups = [
        for (final place in places)
          (place, [for (final nc in filtered) if (place.ncIds.contains(nc.id)) nc]),
      ];
    } else {
      final byLabel = <String, List<NcModel>>{};
      for (final nc in filtered) {
        byLabel.putIfAbsent(nc.placeLabel ?? 'No location', () => []).add(nc);
      }
      final labels = byLabel.keys.toList()
        ..sort((a, b) {
          final an = a == 'No location', bn = b == 'No location';
          if (an != bn) return an ? 1 : -1;
          return a.toLowerCase().compareTo(b.toLowerCase());
        });
      groups = [
        for (final label in labels)
          (
            NcLocationStats(
              key: label,
              label: label,
              total: byLabel[label]!.length,
              inProgress: byLabel[label]!.where((n) => n.bucket == NcBucket.inProgress).length,
              overdue: byLabel[label]!.where((n) => n.bucket == NcBucket.overdue).length,
              pendingApproval:
                  byLabel[label]!.where((n) => n.bucket == NcBucket.pendingApproval).length,
              delayed: byLabel[label]!.where((n) => n.bucket == NcBucket.delayed).length,
              onTime: byLabel[label]!.where((n) => n.bucket == NcBucket.onTime).length,
            ),
            byLabel[label]!,
          ),
      ];
    }
    return [
      for (final (place, rows) in groups) ...[
        _PlaceHeader(
          place: place,
          isExpanded: _expandedPlaces.contains(place.key),
          onToggle: () => _togglePlace(place.key),
        ),
        if (_expandedPlaces.contains(place.key)) ...[
          ..._auditItems(rows, scope: '${place.key}|'),
          const SizedBox(height: 10),
        ],
      ],
    ];
  }
}

/// A place's header in the NC location-wise view: name, NC count and the bucket
/// tallies (only the buckets that have any).
class _PlaceHeader extends StatelessWidget {
  final NcLocationStats place;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _PlaceHeader({required this.place, required this.isExpanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: scheme.outline),
                const SizedBox(width: 2),
                Icon(Icons.place_outlined, size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    place.label,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${place.total} ${place.total == 1 ? 'NC' : 'NCs'}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 46, top: 2),
              child: Wrap(
                spacing: 10,
                runSpacing: 2,
                children: [
                  for (final bucket in NcBucket.all)
                    if (place.countFor(bucket) > 0)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(color: ncBucketColor(bucket), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${place.countFor(bucket)} ${NcBucket.pill(bucket)}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.outline,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One NC of the report: title and id, its audit and place, who raised it and
/// who it is against, the raised / due dates, and the bucket + flag pills.
class _NcReportCard extends StatelessWidget {
  final NcModel nc;

  // Inside an audit bundle the audit is the bundle's own title, not repeated.
  final bool showAudit;

  const _NcReportCard({required this.nc, this.showAudit = true});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final bucket = nc.bucket;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openNcFromReport(context, nc),
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
                        Text(nc.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(nc.ncId, style: TextStyle(color: scheme.outline, fontSize: 11.5)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (bucket != null) NcBucketBadge(bucket: bucket),
                      const SizedBox(height: 4),
                      NcFlagBadge(flag: nc.severity),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (showAudit && nc.auditDeleted)
                const _Line(icon: Icons.fact_check_outlined, text: 'Audit deleted', muted: true)
              else if (showAudit && nc.auditTitle.isNotEmpty)
                _Line(icon: Icons.fact_check_outlined, text: nc.auditTitle),
              _Line(icon: Icons.place_outlined, text: nc.placeLabel ?? 'No location'),
              _Line(
                icon: Icons.swap_horiz_rounded,
                text: 'Raised by ${nc.raisedBy.name} → ${nc.auditee.name} (auditee)',
              ),
              const SizedBox(height: 4),
              Text(
                [
                  'Raised ${Formatters.date(nc.startDate)}',
                  'Due ${Formatters.date(nc.targetDate)}',
                  if (nc.completionDate != null) 'Closed ${Formatters.date(nc.completionDate)}',
                ].join(' · '),
                style: small?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Several NCs of ONE audit as one expandable card: the audit, "N NCs", where,
/// who raised them and who they are against (or "Multiple"), the earliest raised
/// and due dates, how they split by stage and flag — and, opened, each NC as its
/// own (tappable) card. A multi-zone audit carries a Bundle marker.
class _NcGroupCard extends StatelessWidget {
  final NcAuditGroup group;
  final bool isOpen;
  final VoidCallback onToggle;

  const _NcGroupCard({required this.group, required this.isOpen, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    final place = group.common((n) => n.placeLabel ?? 'No location') ?? 'Multiple';
    final raiser = group.common((n) => n.raisedBy.name) ?? 'Multiple';
    final against = group.common((n) => n.auditee.name) ?? 'Multiple';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          margin: EdgeInsets.zero,
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
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // A deleted audit has no title to show: muted and
                            // italic, so it reads as a fact, not a blank.
                            Text(
                              group.auditDeleted
                                  ? 'Audit deleted'
                                  : (group.auditTitle.isEmpty ? 'Audit' : group.auditTitle),
                              style: group.auditDeleted
                                  ? TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontStyle: FontStyle.italic,
                                      color: scheme.outline,
                                    )
                                  : const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  '${group.ncs.length} NCs',
                                  style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w800, fontSize: 12.5),
                                ),
                                if (group.isMultiZoneAudit)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.layers_outlined, size: 12, color: scheme.primary),
                                      const SizedBox(width: 3),
                                      Text(
                                        'Bundle',
                                        style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w700, fontSize: 11.5),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Icon(isOpen ? Icons.expand_less : Icons.expand_more, color: scheme.outline),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _Line(icon: Icons.place_outlined, text: place),
                  _Line(icon: Icons.swap_horiz_rounded, text: 'Raised by $raiser → $against (auditee)'),
                  const SizedBox(height: 4),
                  Text(
                    [
                      'Raised ${Formatters.date(group.earliestRaised)}',
                      'Due ${Formatters.date(group.earliestTarget)}',
                    ].join(' · '),
                    style: small?.copyWith(color: scheme.outline),
                  ),
                  const SizedBox(height: 8),
                  // Stage and flag tallies — each row's own bucket / flag, counted.
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final bucket in NcBucket.all)
                        if (group.countBucket(bucket) > 0)
                          StatusBadge(
                            label: '${NcBucket.pill(bucket)} ×${group.countBucket(bucket)}',
                            color: ncBucketColor(bucket),
                          ),
                      for (final flag in kNcFlags)
                        if (group.countFlag(flag) > 0)
                          StatusBadge(
                            label: '$flag ×${group.countFlag(flag)}',
                            color: flag == 'Major' ? AppColors.red : AppColors.amber,
                          ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isOpen)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, nc) in group.ncs.indexed) ...[
                  if (i > 0) const SizedBox(height: 8),
                  _NcReportCard(nc: nc, showAudit: false),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final String text;

  // Drawn muted and italic (an audit that no longer exists).
  final bool muted;

  const _Line({required this.icon, required this.text, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, size: 13, color: scheme.outline),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: muted
                  ? Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontStyle: FontStyle.italic,
                      color: scheme.outline,
                    )
                  : Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
