import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/audit_date_range.dart';
import '../../core/utils/calendar_entries.dart';
import '../../core/utils/calendar_window.dart';
import '../../models/audit_model.dart';
import '../../models/nc_model.dart';
import '../../providers/audits_provider.dart';
import '../../providers/filter_options_provider.dart';
import '../../providers/list_view_memory.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/calendar_day_agenda.dart';
import '../../widgets/calendar_layers.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/month_calendar.dart';
import '../audits/audit_detail_screen.dart';
import '../nc/nc_response_screen.dart';
import '../nc/nc_review_screen.dart';

/// The single calendar both Auditor and Auditee mode push from app_shell.dart's
/// app-bar calendar icon — the phone's twin of the web Calendar.jsx. One shared
/// implementation, fetching all three sources whatever the AppMode, is what keeps
/// the role-specific copies it replaced (each showing a different partial subset)
/// from drifting apart again.
///
/// Three LAYERS, each a switch with its own icon (the same icon sits on its day
/// markers and its cards), remembered in [ListViewMemory] with the month on screen:
///
///   - My audits — AuditsProvider.calendarAudits (GET /audits/mine, this
///     employee as auditor), drawn in the colour of the audit's unified status
///     (Not Started slate, In Progress blue, Overdue red, NC Response Pending
///     amber, NC Verification Pending violet, Total Closed teal — the legend under
///     the switches), on every day of its scheduledDate..scheduledEndDate.
///   - Audit at My Location — AuditsProvider.calendarAtMyLocation (GET
///     /audits/at-my-location): every audit at this employee's places, whoever
///     audits, with WHO IS COMING on its card. An audit that is also in "My
///     audits" is ONE entry that belongs to both layers (the web's
///     atMyLocationIds): plotted once, counted and switched under each.
///   - My NCs — NcProvider.calendarNcs (GET /ncs/mine): each NC on the day it was
///     raised and on its due date, with the same Respond / Review actions as the
///     NC list.
///
/// What is loaded is the month on screen and its neighbours
/// ([CalendarWindow.around]) — the web asks for its 42-day grid the same way — and
/// again once the grid leaves it. A failed read is SAID, with Retry, instead of
/// leaving an empty month that looks like "nothing scheduled".
///
/// The Filters button is the same shared filter state every other audit surface
/// uses (providers/audit_filter_scope.dart) — including the Me / All Members scope,
/// so a Full Access user opens on the whole organisation exactly as on the web
/// Calendar — plus one thing only this screen offers: a Month picker. Month is
/// purely a VIEW concern. There is NO Date range here, as
/// on the web (its month grid is the date filter): a range picked on another screen
/// no longer hides audits from this calendar. Status, Include skipped and Flag are
/// not offered either — the calendar reads its OWN lists (calendarAudits / calendarNcs),
/// fetched with the shared filters minus those, so a pick made on the Audits or NC
/// screen never silently narrows it.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, this.clock});

  /// What "now" is — only a test overrides it.
  @visibleForTesting
  final DateTime Function()? clock;

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// The month on screen (the 1st). Owned here rather than inside the grid
  /// because the filter sheet has to OPEN on it and can set it.
  late DateTime _visibleMonth;

  /// The day whose agenda is listed under the grid.
  late DateTime _selectedDay;

  /// The layers switched on.
  late Set<CalendarLayer> _layers;

  /// Whether the very first fetch of all three sources has finished.
  ///
  /// The alternative — inferring "still cold" from empty lists — misreads a
  /// legitimately empty result (a filter that matches nothing, a brand new
  /// account) as "still loading" and parks a full-screen spinner over an answer
  /// that has already arrived.
  bool _hasCompletedFirstLoad = false;

  late final AuditsProvider _audits;
  late final NcProvider _ncs;

  final ScrollController _scroll = ScrollController();
  final GlobalKey _agendaKey = GlobalKey();

  // The entries built from the providers' lists, kept while those lists are the
  // same objects: a day tap or a layer switch rebuilds the screen but not the data.
  List<AuditModel> _memoMine = const [];
  List<AuditModel> _memoLocation = const [];
  List<NcModel> _memoNcs = const [];
  String? _memoSelf;
  List<CalendarEntry> _memoEntries = const [];

  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  DateTime get _today => dayOnly(_now);

  @override
  void initState() {
    super.initState();
    // The month on screen, the day, and the layers survive a remount (role switch,
    // shell rebuild) — held in ListViewMemory, which logout wipes.
    final extra = context.read<ListViewMemory>().screen('calendar').extra;
    final remembered = extra['visibleMonth'];
    final now = _now;
    _visibleMonth = remembered is DateTime
        ? DateTime(remembered.year, remembered.month, 1)
        : DateTime(now.year, now.month, 1);
    final rememberedDay = extra['selectedDay'];
    final grid = CalendarWindow.gridOf(_visibleMonth);
    _selectedDay = rememberedDay is DateTime &&
            !dayOnly(rememberedDay).isBefore(grid.from) &&
            !dayOnly(rememberedDay).isAfter(grid.to)
        ? dayOnly(rememberedDay)
        : _selectionForMonth(_visibleMonth);
    _layers = _readLayers(extra['layers']);
    // This screen has its own audit + NC lists (no Status / Include skipped /
    // Flag filter here) — flagging it in use makes filter changes made from
    // ANY screen reload them too while it is open.
    _audits = context.read<AuditsProvider>()..calendarInUse = true;
    _ncs = context.read<NcProvider>()..calendarInUse = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _audits.calendarInUse = false;
    _ncs.calendarInUse = false;
    _scroll.dispose();
    super.dispose();
  }

  /// Today if it is in [month] (overwhelmingly the day you want, and it matches
  /// where the screen opens), otherwise the 1st — a stable landing spot.
  DateTime _selectionForMonth(DateTime month) {
    final today = _today;
    return today.year == month.year && today.month == month.month
        ? today
        : DateTime(month.year, month.month, 1);
  }

  /// Anything not remembered as off is on (the web's pickLayers).
  static Set<CalendarLayer> _readLayers(Object? remembered) {
    if (remembered is! Map) return {...CalendarLayer.values};
    return {
      for (final layer in CalendarLayer.values)
        if (remembered[layer.name] != false) layer,
    };
  }

  ListScreenMemory get _memory => context.read<ListViewMemory>().screen('calendar');

  void _remember() {
    final extra = _memory.extra;
    extra['visibleMonth'] = _visibleMonth;
    extra['selectedDay'] = _selectedDay;
    extra['layers'] = {for (final layer in CalendarLayer.values) layer.name: _layers.contains(layer)};
  }

  void _setVisibleMonth(DateTime month, {DateTime? select}) {
    final first = DateTime(month.year, month.month, 1);
    setState(() {
      _visibleMonth = first;
      _selectedDay = select ?? _selectionForMonth(first);
    });
    _remember();
    // Only asks again once the grid leaves what was loaded.
    final have = _audits.calendarWindow;
    if (have == null || !have.covers(CalendarWindow.forGrid(first))) {
      _loadAll();
    }
  }

  void _stepMonth(int delta) =>
      _setVisibleMonth(DateTime(_visibleMonth.year, _visibleMonth.month + delta, 1));

  void _goToday() {
    final today = _today;
    _setVisibleMonth(DateTime(today.year, today.month, 1), select: today);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  Future<void> _pickMonth() async {
    final picked = await showCalendarMonthPicker(context, month: _visibleMonth);
    if (picked != null && mounted) _setVisibleMonth(picked);
  }

  void _toggleLayer(CalendarLayer layer) {
    setState(() {
      _layers = _layers.contains(layer) ? ({..._layers}..remove(layer)) : {..._layers, layer};
    });
    _remember();
  }

  void _selectDay(DateTime day) {
    setState(() => _selectedDay = day);
    _remember();
    // On a short phone the agenda starts below the fold: bring it up so a tap on a day
    // visibly answers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final agenda = _agendaKey.currentContext;
      if (!mounted || agenda == null || !_scroll.hasClients) return;
      final box = agenda.findRenderObject();
      if (box is! RenderBox || !box.attached) return;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top > MediaQuery.sizeOf(context).height * 0.62) {
        Scrollable.ensureVisible(
          agenda,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: 0.2,
        );
      }
    });
  }

  /// The month's window on all three sources — awaited together only so the
  /// first-load flag flips once, when there is genuinely nothing left in flight,
  /// rather than after whichever fetch happens to land first.
  Future<void> _loadAll() async {
    final window = CalendarWindow.around(_visibleMonth);
    _audits.setCalendarWindow(window);
    _ncs.setCalendarWindow(window);
    await Future.wait([
      _ncs.fetchCalendarNcs(),
      _audits.fetchCalendarAudits(),
      _audits.fetchCalendarAtMyLocation(),
    ]);
    if (!mounted || _hasCompletedFirstLoad) {
      return;
    }
    setState(() => _hasCompletedFirstLoad = true);
  }

  Future<void> _openFilters() async {
    final audits = context.read<AuditsProvider>();
    // The same Me / All Members scope as every other screen (a Full Access user opens
    // on the whole organisation here as on the web Calendar).
    final initial = AuditFilterSelection.fromScope(
      audits,
      // A non-null month is what makes the sheet show its Month section at
      // all — this is the only screen that passes it, because it is the only
      // one whose content is laid out by month.
      month: _visibleMonth,
    );
    final result = await showAuditFilterSheet(
      context,
      initial: initial,
      // Neither Status/Flag nor a Date range applies to the month grid (the grid IS
      // the date filter, as on the web).
      showDateRange: false,
    );
    // Dismissed without applying — leave every dimension exactly as it was.
    if (result == null || !mounted) {
      return;
    }
    // Month first and locally: it never reaches the server, it just moves the grid.
    if (result.month != null) {
      _setVisibleMonth(DateTime(result.month!.year, result.month!.month, 1));
    }
    if (!context.mounted) {
      return;
    }
    // Pushed to every filter-holding provider (Audits, Dashboard, NC): the
    // filters are one shared state across the app, so the calendar and the
    // lists never describe different populations.
    await applyAuditFilterSelection(context, result);
  }

  /// Back to the resting state — the account's default scope, every location and
  /// type — on both providers, for the same reason _openFilters applies to both.
  /// The visible month deliberately survives a Clear: it is a view position, not a filter.
  Future<void> _clearFilters() {
    // Keeps any Status / Flag / Date range pick: this screen doesn't offer them, so
    // a "Clear" here must not wipe something the user can't see.
    final audits = context.read<AuditsProvider>();
    return applyAuditFilterSelection(
      context,
      AuditFilterSelection(
        // The account's default scope.
        resetScope: true,
        dateFrom: audits.dateFrom,
        dateTo: audits.dateTo,
        statuses: audits.statusFilter,
        includeSkipped: audits.includeSkipped,
        flags: audits.flagFilter,
      ),
    );
  }

  void _openAudit(String auditId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => AuditDetailScreen(auditId: auditId)),
    );
  }

  /// Respond to an NC waiting for my answer, review one waiting for a decision —
  /// the same two screens the NC list opens. Another person's NC that is still
  /// waiting for their answer (All Members) is only viewed.
  void _openNc(NcModel nc) {
    final selfId = _audits.selfEmployeeId;
    final route = CalendarNcCard.canRespond(nc, selfId)
        ? MaterialPageRoute<void>(builder: (_) => NcResponseScreen(nc: nc))
        : MaterialPageRoute<void>(builder: (_) => NcReviewScreen(nc: nc, readOnly: nc.status == 'Raised'));
    Navigator.of(context).push(route);
  }

  List<CalendarEntry> _entriesFor(AuditsProvider audits, NcProvider ncs) {
    if (!identical(_memoMine, audits.calendarAudits) ||
        !identical(_memoLocation, audits.calendarAtMyLocation) ||
        !identical(_memoNcs, ncs.calendarNcs) ||
        _memoSelf != audits.selfEmployeeId) {
      _memoMine = audits.calendarAudits;
      _memoLocation = audits.calendarAtMyLocation;
      _memoNcs = ncs.calendarNcs;
      _memoSelf = audits.selfEmployeeId;
      _memoEntries = buildCalendarEntries(
        myAudits: audits.calendarAudits,
        atMyLocation: audits.calendarAtMyLocation,
        ncs: ncs.calendarNcs,
        selfEmployeeId: audits.selfEmployeeId,
      );
    }
    return _memoEntries;
  }

  @override
  Widget build(BuildContext context) {
    final ncProvider = context.watch<NcProvider>();
    final auditsProvider = context.watch<AuditsProvider>();
    // Only for naming the active filters in the summary bar; the sheet is
    // what actually loads this cache.
    final filterOptions = context.watch<FilterOptionsProvider>();

    // Any of the three sources refetching — after a filter change that is
    // all three at once (both providers' refetchForFilters reload the
    // calendar's own NC and audit lists while this screen is open).
    final isBusy = ncProvider.isLoadingCalendarNcs ||
        auditsProvider.isLoadingCalendarAudits ||
        auditsProvider.isLoadingCalendarAtMyLocation;

    final hasAnythingToShow = ncProvider.calendarNcs.isNotEmpty ||
        auditsProvider.calendarAudits.isNotEmpty ||
        auditsProvider.calendarAtMyLocation.isNotEmpty;

    // A full-screen spinner is only ever right on a genuinely cold start: nothing
    // on screen yet AND the first pass over all three sources still unfinished.
    // Gating on the first-load flag (not on "the lists are empty") means a filter
    // that legitimately matches nothing never blanks the calendar to a spinner, and
    // every later fetch keeps the grid — and the month the user navigated to — on
    // screen, with the hairline progress bar above it as the only signal. It also
    // covers the frame before initState's post-frame callback has even fired.
    final showColdStartSpinner = !_hasCompletedFirstLoad && !hasAnythingToShow;

    final error = auditsProvider.calendarAuditsError ??
        auditsProvider.calendarAtMyLocationError ??
        ncProvider.calendarNcsError;
    // Nothing to show AND a read failed: say so (an empty month would read as "nothing
    // scheduled"). With data on screen the same failure is a banner above the grid.
    final showFullError = _hasCompletedFirstLoad && !isBusy && error != null && !hasAnythingToShow;

    final activeFilters = auditsProvider.activeFilterCountFor(
      status: false,
      date: false,
      flag: false,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          // Centered so the button keeps its own compact height instead of
          // being stretched to the full toolbar height by the actions Row.
          Center(
            child: FilterButton(
              minHeight: 44,
              activeCount: activeFilters,
              onTap: _openFilters,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (activeFilters > 0)
            _ActiveFilterBar(
              labels: _activeFilterLabels(auditsProvider, filterOptions),
              onClear: _clearFilters,
            ),
          // Fixed 2px whether or not it is showing anything, so the grid
          // doesn't shift down and snap back on every refetch.
          SizedBox(
            height: 2,
            child: isBusy && !showColdStartSpinner ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            child: showColdStartSpinner
                ? const AppLoading()
                : showFullError
                ? ErrorState(message: error, onRetry: _loadAll)
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: _buildCalendar(context, auditsProvider, ncProvider, error),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendar(BuildContext context, AuditsProvider audits, NcProvider ncs, String? error) {
    final scheme = Theme.of(context).colorScheme;
    final today = _today;
    final entries = _entriesFor(audits, ncs);
    final byDay = entriesByDay(entries, _layers);
    final counts = CalendarMonthCounts.of(entries, _visibleMonth);
    final dayEntries = byDay[_selectedDay] ?? const <CalendarEntry>[];
    final hidden = entries.where((e) => e.day == _selectedDay && !e.shownIn(_layers)).length;
    final showToday = _selectedDay != today || _visibleMonth.year != today.year || _visibleMonth.month != today.month;

    return RefreshIndicator(
      onRefresh: _loadAll,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _PinnedBarDelegate(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: CalendarMonthBar(
                month: _visibleMonth,
                showToday: showToday,
                onPrev: () => _stepMonth(-1),
                onNext: () => _stepMonth(1),
                onPick: _pickMonth,
                onToday: _goToday,
              ),
            ),
          ),
          if (error != null)
            SliverToBoxAdapter(
              child: _CalendarNotice(
                icon: Icons.cloud_off_outlined,
                message: "Couldn't refresh the calendar. $error",
                actionLabel: 'Retry',
                onAction: _loadAll,
              ),
            ),
          if (ncs.calendarNcsTruncated)
            const SliverToBoxAdapter(
              child: _CalendarNotice(
                icon: Icons.info_outline,
                message: 'Only the newest NCs are shown — narrow the filters to see the rest.',
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: CalendarLayerChips(on: _layers, counts: counts, onToggle: _toggleLayer),
            ),
          ),
          SliverToBoxAdapter(
            child: CalendarMonthGrid(
              month: _visibleMonth,
              today: today,
              selectedDay: _selectedDay,
              byDay: byDay,
              layers: _layers,
              onSelect: _selectDay,
              onPrev: () => _stepMonth(-1),
              onNext: () => _stepMonth(1),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: CalendarStatusLegend(
                showNotAttempted: entries.any((e) => e.isAudit && e.statusLabel == 'Not Attempted'),
                showSkipped: entries.any((e) => e.isAudit && e.statusLabel == 'Skipped'),
              ),
            ),
          ),
          SliverToBoxAdapter(child: Divider(key: _agendaKey, height: 1, color: scheme.outlineVariant)),
          SliverToBoxAdapter(
            child: CalendarDayHeader(day: _selectedDay, today: today, shown: dayEntries.length, hidden: hidden),
          ),
          if (dayEntries.isEmpty)
            SliverToBoxAdapter(
              child: CalendarDayEmpty(allLayersOff: _layers.isEmpty, hidden: hidden, day: _selectedDay),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverList.separated(
                itemCount: dayEntries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => CalendarEntryCard(
                  key: ValueKey('${_selectedDay.toIso8601String()}-${dayEntries[i].id}'),
                  entry: dayEntries[i],
                  today: today,
                  layers: _layers,
                  selfEmployeeId: audits.selfEmployeeId,
                  onOpenAudit: _openAudit,
                  onOpenNc: _openNc,
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
        ],
      ),
    );
  }
}

/// A bar pinned under the app bar while the page scrolls, so the month can be
/// changed from anywhere on it.
class _PinnedBarDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final Color color;

  const _PinnedBarDelegate({required this.child, required this.color});

  static const double _extent = 56;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: color,
      elevation: overlapsContent ? 2 : 0,
      child: SizedBox(height: _extent, child: child),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedBarDelegate oldDelegate) => true;
}

/// A one-line notice above the switches: a failed read (with Retry) or a note.
class _CalendarNotice extends StatelessWidget {
  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _CalendarNotice({required this.icon, required this.message, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(message, style: TextStyle(fontSize: 12.5, color: scheme.onErrorContainer)),
            ),
          ),
          if (onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(minimumSize: const Size(44, 44), foregroundColor: scheme.onErrorContainer),
              child: Text(actionLabel ?? 'Retry'),
            ),
        ],
      ),
    );
  }
}

/// One short label per narrowed dimension, in the same order the sheet
/// lists them. Kept to counts past a single selection because this bar has
/// exactly one line to spend — the page needs the rest of the height on a
/// phone, and the sheet itself is one tap away for the detail.
List<String> _activeFilterLabels(
  AuditsProvider audits,
  FilterOptionsProvider options,
) {
  final labels = <String>[];
  if (audits.teamFilter.isNotEmpty) {
    labels.add(
      _summarise(
        audits.teamFilter,
        {for (final t in options.teams) t.id: t.name},
        'team',
        'teams',
      ),
    );
  }
  if (audits.employeeFilter.isNotEmpty) {
    // A non-empty people pick WINS over the Me/All Members flag (see
    // AuditFilterScope.filterParams), so showing "All Members" alongside it
    // would describe a scope that isn't in force.
    labels.add(
      _summarise(
        audits.employeeFilter,
        {for (final e in options.employees) e.id: e.name},
        'person',
        'people',
      ),
    );
  } else if (audits.teamFilter.isEmpty && audits.isTeamScope != audits.defaultTeamScope) {
    // Only a scope that differs from the account's own default is a filter (Me for an employee,
    // All Members for Full Access) — the same rule as every other screen's bar.
    labels.add(audits.isTeamScope ? 'All Members' : 'Me');
  }
  if (audits.locationFilter.isNotEmpty) {
    labels.add(
      _summarise(
        audits.locationFilter,
        {for (final l in options.locations) l.id: l.display},
        'location',
        'locations',
      ),
    );
  }
  if (audits.departmentFilter.isNotEmpty) {
    labels.add(
      _summarise(
        audits.departmentFilter,
        {for (final d in options.departments) d.id: d.name},
        'department',
        'departments',
      ),
    );
  }
  // No "Date range": the calendar does not apply one (the month grid is its date filter).
  if (audits.auditTypeFilter.isNotEmpty) {
    // Audit types are filtered by NAME rather than id (models/audit_type_
    // option.dart explains why), so a single pick is already displayable
    // without a lookup table.
    labels.add(
      audits.auditTypeFilter.length == 1
          ? audits.auditTypeFilter.first
          : '${audits.auditTypeFilter.length} audit types',
    );
  }
  return labels;
}

/// A single selection reads best by name; anything more collapses to a
/// count. The `?? '1 $one'` fallback covers the case where the options
/// cache never populated — FilterOptionsProvider fails each of its three
/// fetches quietly and independently, so a name lookup can legitimately
/// come back empty while a filter built from an earlier successful load is
/// still applied.
String _summarise(
  List<String> selected,
  Map<String, String> nameById,
  String one,
  String many,
) {
  if (selected.length == 1) {
    return nameById[selected.first] ?? '1 $one';
  }
  return '${selected.length} $many';
}

/// The "you are looking at a narrowed calendar" line. One row high and
/// horizontally scrollable rather than a wrapping Wrap: a phone showing a
/// month grid cannot afford a filter summary that silently grows to two or
/// three lines and pushes the last week of the month off screen.
class _ActiveFilterBar extends StatelessWidget {
  final List<String> labels;
  final VoidCallback onClear;

  const _ActiveFilterBar({required this.labels, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: 12, right: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.filter_alt_outlined, size: 15, color: scheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: labels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) => Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: onClear,
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Clear', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}
