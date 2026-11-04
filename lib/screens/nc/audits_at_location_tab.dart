import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_status.dart';
import '../../core/utils/formatters.dart';
import '../../models/audit_model.dart';
import '../../providers/audits_at_location_list.dart';
import '../../providers/audits_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/filter_options_provider.dart';
import '../../providers/list_view_memory.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/audit_filter_bar.dart' show FilterPill;
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart' show AuditFilterSelection, AuditStatusChoices, FilterButton, showAuditFilterSheet;
import '../../widgets/max_width_scroll.dart';
import '../../widgets/nc_page_footer.dart';
import '../../widgets/status_badge.dart';
import '../audits/audit_detail_screen.dart';

/// screens/nc/audits_at_location_tab.dart
/// ───────────────────────────────────────
/// The Auditee's "Audit at My Location" tab (second view of the auditee NC screen,
/// next to "NCs"): every audit scheduled at the places the signed-in person belongs
/// to or leads — who is coming to audit, what, where and when — whether or not they
/// are on it. The phone twin of the web Components/Common/AuditsAtMyLocationSection.jsx.
///
/// One CARD per audit (not a table): title, status, audit type, repeat badge, place(s),
/// auditor(s), auditee(s) — "Self" for a self audit — and the date or date range, with a
/// "You" mark when the signed-in person is the auditor or the auditee. A tap opens the
/// audit read-only (AuditDetailScreen decides what the viewer may do, exactly as for the
/// Calendar's blue "audit visit" markers).
///
/// The list is the SERVER's, one page of 20 at a time (AuditsAtLocationList): the total
/// is the true count ("46 audits"), the next page is appended as the user scrolls near
/// the end, a new filter starts again at page 1 while the rows stay on screen (dimmed)
/// until the new ones land, pull-to-refresh reads page 1 again, an `audit_` notification
/// refreshes the pages on screen (AuditsProvider's socket listener). Filters are this
/// tab's own — Location / Department, Audit type, Date range, Search and Status, which
/// defaults to Not Started + In Progress + Overdue (the audits still to come, nearest
/// first); widening it adds finished / skipped ones. Team, Members and Flag mean
/// nothing here and are not offered.
///
/// What the user set (filters, search text, scroll offset) is remembered in
/// ListViewMemory, so opening an audit and pressing Back — or a remount — finds the list
/// as it was left.
class AuditsAtLocationTab extends StatefulWidget {
  /// Whether this view is the one showing. The tab stays mounted while "NCs" shows; only
  /// the showing one loads pages and answers live updates.
  final bool active;

  const AuditsAtLocationTab({super.key, this.active = true});

  @override
  State<AuditsAtLocationTab> createState() => _AuditsAtLocationTabState();
}

class _AuditsAtLocationTabState extends State<AuditsAtLocationTab> {
  static const _memoryId = 'nc-at-location';

  /// Search text goes to the server this long after the last keystroke.
  static const _searchDelay = Duration(milliseconds: 400);

  late final AuditsProvider _provider;
  late final ListScreenMemory _saved;
  late final TextEditingController _search;
  late final ScrollController _scroll;
  Timer? _debounce;
  bool _afterBuildQueued = false;
  // A pull-to-refresh shows the refresh indicator instead of dimming the rows.
  bool _pulling = false;
  // How many first pages had landed when this screen last looked: one more means the
  // list was replaced (a filter moved) and the scroll goes back to the top.
  late int _seenFirstPages;

  AuditsAtLocationList get _list => _provider.atLocationList;

  @override
  void initState() {
    super.initState();
    _provider = context.read<AuditsProvider>();
    _saved = context.read<ListViewMemory>().screen(_memoryId);
    _search = TextEditingController(text: _saved.search);
    _scroll = ScrollController(initialScrollOffset: _saved.scroll)..addListener(_onScroll);
    // What the list holds must be the filters and search this screen shows, from its
    // first build (a list left on another query is dropped here and read again below).
    _list.setQuery(
      filters: _saved.extra['filters'] as AtLocationFilters? ?? const AtLocationFilters(),
      search: _saved.search,
    );
    _list.inUse = widget.active;
    _seenFirstPages = _list.firstPageCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  @override
  void didUpdateWidget(AuditsAtLocationTab old) {
    super.didUpdateWidget(old);
    if (widget.active == old.active) return;
    _list.inUse = widget.active;
    // What moved while another view was showing is read when this one comes back.
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _list.refreshLoaded();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _list.inUse = false;
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // A list that still holds what this screen was left showing is refreshed in place (its
  // scroll position is still good), else page 1 is read.
  void _open() => _list.hasLoaded ? _list.refreshLoaded() : _list.loadFirst();

  Future<void> _refresh() async {
    _pulling = true;
    try {
      await _list.loadFirst();
    } finally {
      _pulling = false;
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _saved.scroll = _scroll.offset;
    _maybeLoadMore();
  }

  void _maybeLoadMore() {
    final list = _list;
    if (!widget.active || !list.hasMore || list.isLoading || list.isLoadingMore) return;
    if (nearListEnd(_scroll)) list.loadMore();
  }

  // After each build: scroll back to the top when the list was replaced, and keep loading
  // while the end is still near (a tall screen — or a short page — would otherwise never
  // scroll, so never ask for more).
  void _afterBuild(AuditsAtLocationList list) {
    if (_afterBuildQueued) return;
    final replaced = list.firstPageCount != _seenFirstPages;
    final canLoad = widget.active && list.hasMore && !list.isLoading && !list.isLoadingMore && list.moreError == null;
    if (!replaced && !canLoad) return;
    _afterBuildQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _afterBuildQueued = false;
      if (!mounted) return;
      if (_list.firstPageCount != _seenFirstPages) {
        _seenFirstPages = _list.firstPageCount;
        _saved.scroll = 0;
        if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
      }
      _maybeLoadMore();
    });
  }

  void _onSearch(String v) {
    _saved.search = v;
    setState(() {});
    _debounce?.cancel();
    void apply() {
      if (mounted && _list.setQuery(search: v)) _list.loadFirst();
    }

    if (v.trim().isEmpty) {
      apply();
    } else {
      _debounce = Timer(_searchDelay, apply);
    }
  }

  // New filters start again at page 1 (a stale higher page would be asked of a smaller result).
  void _applyFilters(AtLocationFilters next) {
    _saved.extra['filters'] = next;
    setState(() {});
    if (_list.setQuery(filters: next)) _list.loadFirst();
  }

  void _clearAll() {
    _debounce?.cancel();
    _search.clear();
    _saved.search = '';
    _saved.extra['filters'] = const AtLocationFilters();
    setState(() {});
    if (_list.setQuery(filters: const AtLocationFilters(), search: '')) _list.loadFirst();
  }

  Future<void> _openFilters() async {
    final f = _list.filters;
    final result = await showAuditFilterSheet(
      context,
      initial: AuditFilterSelection(
        locations: f.locationIds,
        departments: f.departmentIds,
        auditTypes: f.auditTypes,
        dateFrom: f.dateFrom,
        dateTo: f.dateTo,
        statuses: f.statuses,
      ),
      showStatus: true,
      showPeople: false,
      statusChoices: const AuditStatusChoices(
        options: kAtLocationStatusOptions,
        defaults: kAtLocationDefaultStatuses,
        hint: 'Not Started, In Progress and Overdue are the audits still to come. Untick every status to see all of them.',
      ),
    );
    // The sheet can outlive this screen (a logout, a mode switch).
    if (result == null || !mounted) return;
    _applyFilters(
      AtLocationFilters(
        locationIds: result.locations,
        departmentIds: result.departments,
        auditTypes: result.auditTypes,
        dateFrom: result.dateFrom,
        dateTo: result.dateTo,
        statuses: result.statuses,
      ),
    );
  }

  void _openAudit(AuditModel audit) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AuditDetailScreen(auditId: audit.id)));
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilds on every AuditsProvider change: the list reports through it.
    context.watch<AuditsProvider>();
    final myId = context.read<AuthProvider>().user?.id;
    final list = _list;
    final items = list.items;
    final showError = list.error != null && items.isEmpty;
    final showLoading = !showError && items.isEmpty && (list.isLoading || !list.hasLoaded);
    final showEmpty = !showLoading && !showError && items.isEmpty;
    // The rows stay on screen — dimmed and inert — while another query's first page loads.
    final dimmed = items.isNotEmpty && ((list.isLoading && !_pulling) || !list.hasLoaded);
    _afterBuild(list);

    return Column(
      children: [
        _FilterHeader(
          searchController: _search,
          onSearchChanged: _onSearch,
          filters: list.filters,
          narrowed: list.isNarrowed,
          onOpenFilters: _openFilters,
          onChangeFilters: _applyFilters,
          onClear: _clearAll,
          count: items.isEmpty
              ? null
              : NcCountLine(
                  loaded: items.length,
                  total: list.total,
                  hasMore: list.hasMore,
                  noun: 'audits',
                  nounOne: 'audit',
                ),
        ),
        // A live or pull refresh that failed with rows on screen: they stay, and say so.
        if (list.error != null && items.isNotEmpty)
          _RefreshFailed(message: list.error!, onRetry: _refresh),
        Expanded(
          child: MaxWidthScroll(
            child: showLoading
                ? const AppLoading()
                : showError
                ? _FillScroll(child: ErrorState(message: list.error!, onRetry: _refresh))
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: showEmpty
                        ? _FillScroll(
                            child: EmptyState(
                              icon: Icons.location_off_outlined,
                              title: 'No audits at your locations match',
                              subtitle: list.isNarrowed
                                  ? 'Try widening the status, place, type or dates, or clear the search.'
                                  : 'Nothing is scheduled at your places right now. Pick another Status in Filters to see finished audits.',
                              action: list.isNarrowed
                                  ? OutlinedButton.icon(
                                      onPressed: _clearAll,
                                      icon: const Icon(Icons.filter_alt_off_outlined),
                                      label: const Text('Clear filters'),
                                    )
                                  : null,
                            ),
                          )
                        : AnimatedOpacity(
                            key: const ValueKey('at-location-rows'),
                            duration: const Duration(milliseconds: 150),
                            opacity: dimmed ? 0.5 : 1,
                            child: IgnorePointer(
                              ignoring: dimmed,
                              child: ListView.separated(
                                key: const ValueKey('at-location-list'),
                                controller: _scroll,
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                                itemCount: items.length + 1,
                                separatorBuilder: (_, _) => const SizedBox(height: 10),
                                itemBuilder: (_, i) {
                                  if (i == items.length) {
                                    return NcPageFooter(
                                      hasMore: list.hasMore,
                                      isLoadingMore: list.isLoadingMore,
                                      error: list.moreError,
                                      onRetry: () => list.loadMore(retry: true),
                                    );
                                  }
                                  final audit = items[i];
                                  return AtLocationAuditCard(
                                    key: ValueKey('at-location-${audit.id}'),
                                    audit: audit,
                                    myId: myId,
                                    onTap: () => _openAudit(audit),
                                  );
                                },
                              ),
                            ),
                          ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// A centred placeholder that scrolls when it is taller than the room it has (a large text
/// size on a small phone) instead of overflowing, and still lets a pull-to-refresh start.
class _FillScroll extends StatelessWidget {
  final Widget child;

  const _FillScroll({required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}

class _RefreshFailed extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _RefreshFailed({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.error)),
          ),
          TextButton(
            key: const ValueKey('at-location-refresh-retry'),
            style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}

// ── the filter header ───────────────────────────────────────────────────────

final _pillDate = DateFormat('d MMM');
final _pillDateYear = DateFormat('d MMM yyyy');

/// Search, the Filters button with the server's count beside it, and one scrolling row of
/// removable pills for whatever differs from the default (Location, Department, Audit
/// type, Date range, Status) with "Clear" pinned to its left. The same sheet and pills as
/// the app's other lists (widgets/filter_sheet.dart, audit_filter_bar.dart), minus the
/// Team / Members / Flag sections, with touch areas of at least 44 px.
class _FilterHeader extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final AtLocationFilters filters;
  final bool narrowed;
  final VoidCallback onOpenFilters;
  final ValueChanged<AtLocationFilters> onChangeFilters;
  final VoidCallback onClear;

  /// "Showing 20 of 46 audits" / "46 audits"; null while there are no rows.
  final Widget? count;

  const _FilterHeader({
    required this.searchController,
    required this.onSearchChanged,
    required this.filters,
    required this.narrowed,
    required this.onOpenFilters,
    required this.onChangeFilters,
    required this.onClear,
    required this.count,
  });

  static String _lookup(Iterable<(String, String)> pairs, String id, String fallback) {
    // A generic word rather than a raw ObjectId: an unresolved id means the option cache was dropped.
    for (final (key, name) in pairs) {
      if (key == id && name.isNotEmpty) return name;
    }
    return fallback;
  }

  static String _rangeLabel(DateTime? from, DateTime? to) {
    if (from != null && to != null) {
      final sameYear = from.year == to.year;
      return '${sameYear ? _pillDate.format(from) : _pillDateYear.format(from)} – ${_pillDateYear.format(to)}';
    }
    if (from != null) return 'From ${_pillDateYear.format(from)}';
    return 'Until ${_pillDateYear.format(to!)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // watch: the option cache fills in asynchronously the first time the sheet opens, and
    // these pills turn ids back into names.
    final options = context.watch<FilterOptionsProvider>();
    final f = filters;

    List<String> without(List<String> l, String x) => [...l]..remove(x);

    final pills = <Widget>[
      for (final id in f.locationIds)
        FilterPill(
          icon: Icons.place_outlined,
          label: _lookup(options.locations.map((l) => (l.id, l.name)), id, 'Location'),
          tapHeight: 44,
          onRemove: () => onChangeFilters(f.copyWith(locationIds: without(f.locationIds, id))),
        ),
      for (final id in f.departmentIds)
        FilterPill(
          icon: Icons.apartment_outlined,
          label: _lookup(options.departments.map((d) => (d.id, d.name)), id, 'Department'),
          tapHeight: 44,
          onRemove: () => onChangeFilters(f.copyWith(departmentIds: without(f.departmentIds, id))),
        ),
      for (final type in f.auditTypes)
        FilterPill(
          label: type,
          tapHeight: 44,
          onRemove: () => onChangeFilters(f.copyWith(auditTypes: without(f.auditTypes, type))),
        ),
      if (f.dateFrom != null || f.dateTo != null)
        FilterPill(
          icon: Icons.event_outlined,
          label: _rangeLabel(f.dateFrom, f.dateTo),
          tapHeight: 44,
          onRemove: () => onChangeFilters(f.copyWith(dateRange: (null, null))),
        ),
      if (!f.statusIsDefault)
        if (f.statuses.isEmpty)
          // Nothing ticked = every status; removing the pill goes back to the audits still to come.
          FilterPill(
            label: 'All statuses',
            tapHeight: 44,
            onRemove: () => onChangeFilters(f.copyWith(statuses: kAtLocationDefaultStatuses)),
          )
        else
          for (final s in f.statuses)
            FilterPill(
              label: s,
              tapHeight: 44,
              onRemove: () {
                final remaining = without(f.statuses, s);
                onChangeFilters(f.copyWith(statuses: remaining.isEmpty ? kAtLocationDefaultStatuses : remaining));
              },
            ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: searchController,
            textInputAction: TextInputAction.search,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search audit, auditor or place...',
              suffixIcon: searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: 'Clear search',
                      onPressed: () {
                        searchController.clear();
                        onSearchChanged('');
                      },
                    ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              // The server's own count of what the list holds, however many pages are on screen.
              Expanded(child: count ?? const SizedBox.shrink()),
              const SizedBox(width: 8),
              SizedBox(
                height: 44,
                child: FilterButton(activeCount: f.activeCount, onTap: onOpenFilters),
              ),
            ],
          ),
          if (f.statusIsDefault && !narrowed)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                'Audits still to come, nearest first. Use Filters to see finished or skipped ones.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ),
          if (narrowed)
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  TextButton(
                    key: const ValueKey('at-location-clear'),
                    onPressed: onClear,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    child: const Text('Clear', style: TextStyle(fontSize: 12.5)),
                  ),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [for (final p in pills) Center(child: p)],
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

// ── one audit ───────────────────────────────────────────────────────────────

/// One audit at one of my places. [myId] (the signed-in employee) decides the "You" mark:
/// it is shown when that person is one of the auditors or on the auditee side.
class AtLocationAuditCard extends StatelessWidget {
  final AuditModel audit;
  final String? myId;
  final VoidCallback onTap;

  const AtLocationAuditCard({super.key, required this.audit, required this.myId, required this.onTap});

  static String dateText(AuditModel a) {
    final start = a.scheduledDate;
    if (start == null) return '—';
    final end = a.scheduledEndDate;
    final first = Formatters.date(start);
    if (end != null && Formatters.date(end) != first) return '$first – ${Formatters.date(end)}';
    return first;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iAmAuditor = audit.hasAuditor(myId);
    final iAmAuditee = audit.hasAuditee(myId);
    final overdue = audit.displayLabel == AuditStatus.overdue;
    final skipped = audit.status == AuditStatus.skipped || audit.displayLabel == AuditStatus.skipped;

    return Card(
      // Overdue: a red-tinted border, like the other audit cards — the word "Overdue" in the badge carries
      // the same signal for anyone who cannot rely on colour.
      shape: overdue
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: AppColors.red.withValues(alpha: 0.55)),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(audit.title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              // The title has the whole width to itself; the badges wrap under it (a long status such as
              // "NC Verification Pending" beside a long title would squeeze the title to nothing).
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusBadge(label: audit.displayLabel, color: AppColors.forAuditStatus(audit.displayLabel)),
                  if (TimelinessPill.shortLabel(audit.timeliness) != null) TimelinessPill(timeliness: audit.timeliness),
                  if (audit.auditType != null) _Chip(label: audit.auditType!),
                  if (audit.isRepeating) _RepeatBadge(frequency: audit.frequency),
                  if (iAmAuditor || iAmAuditee) _YouBadge(auditor: iAmAuditor, auditee: iAmAuditee),
                ],
              ),
              const SizedBox(height: 10),
              _InfoRow(
                icon: Icons.place_outlined,
                child: audit.placeLabels.isEmpty
                    ? Text('No place set', style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline))
                    : Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [for (final p in audit.placeLabels) _Chip(label: p)],
                      ),
              ),
              _InfoRow(
                icon: Icons.person_outline,
                child: _People(label: 'Auditor', people: audit.auditors, myId: myId, empty: '—'),
              ),
              _InfoRow(
                icon: Icons.groups_outlined,
                // No named people: the model says why ("Self" for a self audit, else a dash).
                child: audit.auditeePeople.isEmpty
                    ? Text('Auditee: ${audit.auditeeLabel()}', style: theme.textTheme.bodySmall)
                    : _People(label: 'Auditee', people: audit.auditeePeople, myId: myId, empty: '—'),
              ),
              if (audit.selfAuditNote.isNotEmpty)
                _InfoRow(
                  icon: Icons.info_outline,
                  child: Text(
                    audit.selfAuditNote,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ),
              _InfoRow(icon: Icons.event_outlined, child: Text(dateText(audit), style: theme.textTheme.bodySmall)),
              if (skipped)
                _InfoRow(
                  icon: Icons.block,
                  child: Text(
                    [
                      (audit.skipReason ?? '').isEmpty ? 'No remark recorded' : audit.skipReason!,
                      if (audit.skippedByName.isNotEmpty) 'Skipped by ${audit.skippedByName}',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final Widget child;

  const _InfoRow({required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 15, color: Theme.of(context).colorScheme.outline),
          ),
          const SizedBox(width: 6),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// "Auditor: Asha (You), Ravi (inactive)" — the people's names, the signed-in person's own marked "You".
class _People extends StatelessWidget {
  final String label;
  final List<({String id, String name, bool inactive})> people;
  final String? myId;
  final String empty;

  const _People({required this.label, required this.people, required this.myId, required this.empty});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodySmall;
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(
            text: '$label: ',
            style: TextStyle(color: scheme.outline, fontWeight: FontWeight.w600),
          ),
          if (people.isEmpty) TextSpan(text: empty),
          for (var i = 0; i < people.length; i++) ...[
            if (i > 0) const TextSpan(text: ', '),
            TextSpan(text: people[i].name),
            if (people[i].id == myId)
              TextSpan(
                text: ' (You)',
                style: TextStyle(fontWeight: FontWeight.w800, color: scheme.primary),
              ),
            if (people[i].inactive)
              TextSpan(
                text: ' (inactive)',
                style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.readable(context, AppColors.red)),
              ),
          ],
        ],
      ),
    );
  }
}

/// A muted chip — the audit type, a place.
class _Chip extends StatelessWidget {
  final String label;

  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// "this audit repeats": a Repeat icon and the repeat type (Daily / Weekly / ...), the web's RecurringBadge.
class _RepeatBadge extends StatelessWidget {
  final String? frequency;

  const _RepeatBadge({required this.frequency});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = (frequency ?? '').isEmpty ? 'Repeats' : frequency!;
    return Semantics(
      label: (frequency ?? '').isEmpty ? 'Repeating audit' : 'Repeats ${frequency!.toLowerCase()}',
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('at-location-repeat'),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          color: const Color(0xFF6366F1).withValues(alpha: 0.12),
          border: Border.all(color: const Color(0xFF6366F1).withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.repeat_rounded, size: 12, color: Color(0xFF6366F1)),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The clear "this one is mine" mark: "You · Auditor", "You · Auditee" or "You · Auditor & Auditee".
class _YouBadge extends StatelessWidget {
  final bool auditor;
  final bool auditee;

  const _YouBadge({required this.auditor, required this.auditee});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final role = auditor && auditee ? 'Auditor & Auditee' : (auditor ? 'Auditor' : 'Auditee');
    return Container(
      key: const ValueKey('at-location-you'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.person_pin_circle_outlined, size: 13, color: scheme.onPrimaryContainer),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              'You · $role',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: scheme.onPrimaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
