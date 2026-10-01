import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/nc_model.dart';
import '../../models/nc_report_model.dart';
import '../../providers/list_view_memory.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/max_width_scroll.dart';
import '../../widgets/nc_page_footer.dart';
import '../../widgets/report_tiles.dart';
import '../../widgets/status_badge.dart';
import 'nc_report_tab.dart' show openNcFromReport;

/// The "min. times" choices — the web tab's own list.
const repeatMinCounts = [2, 3, 4, 5, 10];

/// The Final Report's Repeated NCs tab — "does the same checkpoint keep going
/// wrong at this place?" (web: RepeatFindingsTab.jsx). A repeat is the SAME
/// checkpoint wording raised again at the SAME place: only capitals, extra
/// spaces and trailing punctuation are ignored, so a different spelling, extra
/// words or another place is a different group (server: GET /ncs/repeats,
/// utils/ncRepeat.js). Nobody's name enters the grouping.
///
/// Honours the shared filter bar's Location + Department, Audit Type, Flag and
/// Date — but NOT its people half (Me / All Members / Team / Members): the
/// server groups org-wide, exactly as the web tab does. With no date picked it
/// looks back six months, and says so.
///
/// A row is the group (×count, open count, place, first → last date); tapping it
/// lists each NC behind it — its id, raised date, audit, who raised it and who
/// it is against, flag and status — and tapping an NC opens its read-only thread.
///
/// The groups load ONE page (30) at a time: the next page is appended by itself as
/// the tab scrolls near its end (a small spinner at the foot; "Try again" when a
/// page failed) until the server's total is on screen.
class RepeatedNcsTab extends StatefulWidget {
  const RepeatedNcsTab({super.key});

  @override
  State<RepeatedNcsTab> createState() => _RepeatedNcsTabState();
}

class _RepeatedNcsTabState extends State<RepeatedNcsTab> {
  static const _memoryId = 'reports-repeats';

  late final ListScreenMemory _saved;
  late final ScrollController _scroll;
  // Accordion: the key of the ONE group that is open.
  String? _openKey;
  // The NCs behind each opened group, by `key|ids` so a group whose NCs changed
  // (a filter moved, a new repeat arrived) misses the cache. A null value is a
  // request that failed.
  final Map<String, List<NcModel>?> _ncs = {};
  final Set<String> _loadingNcs = {};
  bool _afterBuildQueued = false;
  // How many first pages had landed when this tab last looked: one more means the
  // list was replaced (a filter or the min. times moved) and the scroll goes back
  // to the top.
  late int _seenFirstPages;

  @override
  void initState() {
    super.initState();
    _saved = context.read<ListViewMemory>().screen(_memoryId);
    _openKey = _saved.extra['open'] as String?;
    _scroll = ScrollController(initialScrollOffset: _saved.scroll)..addListener(_onScroll);
    // Before the host's first load: the request must carry the remembered pick.
    final p = context.read<NcProvider>();
    final min = _saved.extra['min'];
    if (min is int && repeatMinCounts.contains(min)) {
      p.repeatsMinCount = min;
    }
    _seenFirstPages = p.repeatsFirstPageCount;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _saved.scroll = _scroll.offset;
  }

  // After each build: back to the top when the list was replaced, and keep loading
  // while the end is still near (a tall screen — or a short page — would otherwise
  // never scroll, so never ask for more).
  void _afterBuild(NcProvider p) {
    if (_afterBuildQueued) return;
    final replaced = p.repeatsFirstPageCount != _seenFirstPages;
    if (!replaced) return;
    _afterBuildQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _afterBuildQueued = false;
      if (!mounted) return;
      final count = context.read<NcProvider>().repeatsFirstPageCount;
      if (count != _seenFirstPages) {
        _seenFirstPages = count;
        _saved.scroll = 0;
        if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
      }
    });
  }

  String _cacheKey(RepeatGroup g) => '${g.key}|${g.ncIds.join(',')}';

  // Turns the list to page [page]; a new page starts from the top (the screen sees
  // repeatsFirstPageCount move).
  Future<void> _goToPage(int page) => context.read<NcProvider>().goToRepeatsPage(page);

  Future<void> _reload() => context.read<NcProvider>().fetchRepeats();

  void _pickMin(int n) {
    _saved.extra['min'] = n;
    setState(() => _openKey = null);
    _saved.extra['open'] = null;
    final p = context.read<NcProvider>();
    p.repeatsMinCount = n;
    p.fetchRepeats();
  }

  Future<void> _toggle(RepeatGroup g) async {
    final opening = _openKey != g.key;
    setState(() => _openKey = opening ? g.key : null);
    _saved.extra['open'] = _openKey;
    if (!opening) return;
    final key = _cacheKey(g);
    if (_ncs.containsKey(key) && _ncs[key] != null) return;
    setState(() => _loadingNcs.add(key));
    final rows = await context.read<NcProvider>().fetchRepeatNcs(g.ncIds);
    if (!mounted) return;
    setState(() {
      _ncs[key] = rows;
      _loadingNcs.remove(key);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.watch<NcProvider>();
    final scheme = Theme.of(context).colorScheme;
    final rows = p.repeatRows;
    final showError = p.repeatsError != null && rows.isEmpty;
    final showLoading = p.isLoadingRepeats && rows.isEmpty && !showError;
    _afterBuild(p);
    final window = p.repeatsUseDefaultWindow
        ? 'Showing the last 6 months — pick a date range in Filters to change it.'
        : [
            'From ${p.dateFrom == null ? 'the start' : Formatters.date(p.dateFrom)}',
            if (p.dateTo != null) 'to ${Formatters.date(p.dateTo)}',
          ].join(' ');

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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Same checkpoint wording, same place',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text('Min. times', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    key: const ValueKey('repeat-min-times'),
                    value: p.repeatsMinCount,
                    isDense: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final n in repeatMinCounts)
                        DropdownMenuItem(value: n, child: Text('$n+')),
                    ],
                    onChanged: (n) {
                      if (n != null && n != p.repeatsMinCount) _pickMin(n);
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
              child: Text(
                'Across the whole company — Team / Members do not narrow this tab. $window',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline, fontSize: 11.5),
              ),
            ),
            if (showLoading)
              SizedBox(height: MediaQuery.of(context).size.height * 0.4, child: const AppLoading())
            else if (showError)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: ErrorState(message: p.repeatsError!, onRetry: _reload),
              )
            else if (rows.isEmpty)
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.4,
                child: EmptyState(
                  icon: Icons.repeat_rounded,
                  title: 'No repeats in this window',
                  subtitle:
                      'No checkpoint has been raised ${p.repeatsMinCount}+ times at the same place.',
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The server's own count of the groups, however many pages are
                    // on screen so far.
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: NcCountLine(
                              loaded: rows.length,
                              total: p.repeatsTotal,
                              hasMore: p.repeatsHasMore,
                              noun: 'repeated checkpoints',
                              nounOne: 'repeated checkpoint',
                              offset: (p.repeatsPage - 1) * NcProvider.repeatsPageSize,
                            ),
                          ),
                          // The same Prev/Next as the foot of the list, small.
                          NcPagerCompact(
                            page: p.repeatsPage,
                            totalPages: p.repeatsTotalPages,
                            busy: p.isLoadingMoreRepeats,
                            onPage: _goToPage,
                          ),
                        ],
                      ),
                    ),
                    for (final g in rows) ...[
                      _RepeatCard(
                        group: g,
                        isOpen: _openKey == g.key,
                        onToggle: () => _toggle(g),
                        ncs: _ncs[_cacheKey(g)],
                        isLoading: _loadingNcs.contains(_cacheKey(g)),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (p.repeatsMoreError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          p.repeatsMoreError!,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    NcPagerBar(
                      page: p.repeatsPage,
                      totalPages: p.repeatsTotalPages,
                      busy: p.isLoadingMoreRepeats,
                      onPage: _goToPage,
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

/// One repeated checkpoint: ×count, the wording, the place and first → last
/// date, how many are still open — and, opened, the NCs behind it.
class _RepeatCard extends StatelessWidget {
  final RepeatGroup group;
  final bool isOpen;
  final VoidCallback onToggle;
  // Null while not loaded yet (or when that request failed — see isLoading).
  final List<NcModel>? ncs;
  final bool isLoading;

  const _RepeatCard({
    required this.group,
    required this.isOpen,
    required this.onToggle,
    required this.ncs,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final open = group.openCount > 0;
    final openColor = open ? AppColors.amber : AppColors.green;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.red.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '×${group.count}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: AppColors.readable(context, AppColors.red),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(group.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          '${group.place ?? 'No place'} · ${Formatters.date(group.firstDate)} → ${Formatters.date(group.lastDate)}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                        ),
                        const SizedBox(height: 6),
                        StatusBadge(
                          label: open ? '${group.openCount} open' : 'All closed',
                          color: openColor,
                        ),
                      ],
                    ),
                  ),
                  Icon(isOpen ? Icons.expand_less : Icons.expand_more, color: scheme.outline),
                ],
              ),
            ),
          ),
          if (isOpen)
            Container(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: isLoading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 10),
                      child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
                    )
                  : ncs == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('These NCs could not be loaded. Tap the row to try again.', style: Theme.of(context).textTheme.bodySmall),
                    )
                  : ncs!.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('No NCs to show.', style: Theme.of(context).textTheme.bodySmall),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final nc in ncs!) _RepeatNcTile(nc: nc)],
                    ),
            ),
        ],
      ),
    );
  }
}

/// One NC behind a repeated checkpoint, every fact labelled: its NC id, when it
/// was raised, which audit it was in, who raised it and who it is against, its
/// flag and status. Tap opens its read-only thread.
class _RepeatNcTile extends StatelessWidget {
  final NcModel nc;

  const _RepeatNcTile({required this.nc});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => openNcFromReport(context, nc),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      nc.ncId,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13.5),
                    ),
                    const SizedBox(width: 8),
                    // A Wrap, not a Row: a long status ("Response Submitted") next
                    // to the flag must drop to a second line, not run off the card.
                    Expanded(
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          NcFlagBadge(flag: nc.severity),
                          StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _Fact(label: 'Raised', value: Formatters.date(nc.startDate)),
                _Fact(label: 'Audit', value: nc.auditTitle.isEmpty ? '—' : nc.auditTitle),
                _Fact(label: 'Raised by', value: nc.raisedBy.name),
                _Fact(label: 'Against', value: nc.auditee.name),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;

  const _Fact({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: scheme.outline),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}
