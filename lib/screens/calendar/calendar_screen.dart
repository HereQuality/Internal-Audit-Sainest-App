import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/audit_date_range.dart';
import '../../providers/audits_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/filter_options_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/filter_sheet.dart';
import '../../widgets/month_calendar.dart';
import '../audits/audit_detail_screen.dart';
import '../nc/nc_response_screen.dart';
import '../nc/nc_review_screen.dart';

/// The single calendar both Auditor and Auditee mode push from
/// app_shell.dart's app-bar calendar icon — mirrors the web app's own
/// Calendar.jsx, which fetches and shows the exact same four categories
/// for EVERY role rather than splitting them across role-specific views:
/// this used to be two separate screens (auditor_calendar_screen.dart /
/// auditee_calendar_screen.dart) each showing a different partial subset
/// (auditor: only its own audits, all one status color; auditee: only NCs
/// raised against it + others' audits at its own location, never its own
/// audits) — which is exactly why the two stopped matching each other and
/// drifted from the web page they were both meant to mirror. One shared
/// implementation, fetching all three sources unconditionally regardless
/// of AppMode, is what keeps that from happening again.
///
///   - Non-Conformance (red) — NcProvider.raisedAgainstMe, one dot per
///     NcModel#targetDate, tap to respond (still "Raised") or review.
///   - Audit (amber) / Completed (green) — AuditsProvider.audits (this
///     employee's own, as auditor), split by AuditModel#status, expanded
///     across every day in AuditModel#scheduledDate..scheduledEndDate via
///     daysInAuditRange.
///   - Audit at Your Location (blue) — AuditsProvider.auditsAtMyLocation,
///     someone ELSE scheduled to audit one of this employee's own
///     locations. Deduped against `audits` above (same id showing as both
///     "mine" and "at my location" — this employee audits their own
///     location plenty) so nothing plots twice, once amber/green and once
///     blue — mirrors Calendar.jsx's own myAuditIds/isOthers filter.
///
/// The Filters button in this screen's AppBar is the same shared filter
/// state every other audit surface uses (providers/audit_filter_scope.dart)
/// plus one thing only this screen offers: a Month picker, requested by
/// passing a non-null `month` into showAuditFilterSheet. Month is purely a
/// VIEW concern — it scrolls the grid, it is never sent to the server (the
/// audit endpoints hand back the whole scheduled range and always have;
/// the calendar simply shows one month of it at a time). Everything else
/// in the sheet is applied to BOTH AuditsProvider and DashboardProvider,
/// because `audits` here is the very same list the Audits tab renders and
/// the dashboard tallies — filtering on one surface and not the others is
/// how the app would end up quietly disagreeing with itself about what
/// "my audits" means.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// The month on screen. Owned here rather than solely inside
  /// MonthCalendar because the filter sheet has to OPEN on it (and can set
  /// it), while the grid's own chevrons also move it — see MonthCalendar's
  /// visibleMonth/onVisibleMonthChanged pair, which is what keeps this
  /// field and the grid's internal cursor from drifting apart.
  late DateTime _visibleMonth;

  /// Whether the very first fetch of all three sources has finished.
  ///
  /// The alternative — inferring "still cold" from empty lists — misreads
  /// a legitimately empty result (a filter that matches nothing, a brand
  /// new account) as "still loading" and parks a full-screen spinner over
  /// an answer that has already arrived. See build() for how this gates
  /// the spinner.
  bool _hasCompletedFirstLoad = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visibleMonth = DateTime(now.year, now.month, 1);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  /// All three sources at once — awaited together only so the first-load
  /// flag flips once, when there is genuinely nothing left in flight,
  /// rather than after whichever fetch happens to land first.
  Future<void> _loadAll() async {
    final ncProvider = context.read<NcProvider>();
    final auditsProvider = context.read<AuditsProvider>();
    await Future.wait([
      ncProvider.fetchAgainstMe(),
      auditsProvider.fetchMyAudits(),
      auditsProvider.fetchAuditsAtMyLocation(),
    ]);
    if (!mounted) {
      return;
    }
    setState(() => _hasCompletedFirstLoad = true);
  }

  Future<void> _openFilters() async {
    final audits = context.read<AuditsProvider>();
    final result = await showAuditFilterSheet(
      context,
      isTeam: audits.isTeamScope,
      employees: audits.employeeFilter,
      locations: audits.locationFilter,
      auditTypes: audits.auditTypeFilter,
      // Non-null is what makes the sheet show its Month section at all —
      // this is the only screen that passes it, because it is the only one
      // whose content is laid out by month.
      month: _visibleMonth,
    );
    // Dismissed without applying — leave every dimension exactly as it was.
    if (result == null || !mounted) {
      return;
    }
    // Month first and locally: it never reaches the server, it just moves
    // the grid (and flows down into MonthCalendar.visibleMonth).
    if (result.month != null) {
      setState(() => _visibleMonth = DateTime(
        result.month!.year,
        result.month!.month,
        1,
      ));
    }
    if (!context.mounted) {
      return;
    }
    // Applied to BOTH providers, exactly as ScopeToggle already does for
    // the Me/Team flag alone: they hold separate copies of the same filter
    // (see AuditFilterScope's class doc for why), so updating one and not
    // the other leaves the dashboard's numbers describing a different
    // population than the list the user is looking at.
    await Future.wait([
      context.read<AuditsProvider>().applyFilters(
        isTeam: result.isTeam,
        employees: result.employees,
        locations: result.locations,
        auditTypes: result.auditTypes,
      ),
      context.read<DashboardProvider>().applyFilters(
        isTeam: result.isTeam,
        employees: result.employees,
        locations: result.locations,
        auditTypes: result.auditTypes,
      ),
    ]);
  }

  /// Back to the resting "just me, everywhere, every type" state — on both
  /// providers, for the same reason _openFilters applies to both. The
  /// visible month deliberately survives a Clear: it is a view position,
  /// not a filter, and yanking the user back to the current month while
  /// they are reading November is not what "clear filters" promises.
  Future<void> _clearFilters() {
    return Future.wait([
      context.read<AuditsProvider>().clearFilters(),
      context.read<DashboardProvider>().clearFilters(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final ncProvider = context.watch<NcProvider>();
    final auditsProvider = context.watch<AuditsProvider>();
    // Only for naming the active filters in the summary bar; the sheet is
    // what actually loads this cache.
    final filterOptions = context.watch<FilterOptionsProvider>();

    // Any of the three sources refetching — after a filter change that is
    // all three at once (AuditsProvider.refetchForFilters + the NC list is
    // untouched by filters, so realistically the two audit ones).
    final isBusy =
        ncProvider.isLoadingMine ||
        auditsProvider.isLoading ||
        auditsProvider.isLoadingAtMyLocation;

    final hasAnythingToShow =
        ncProvider.raisedAgainstMe.isNotEmpty ||
        auditsProvider.audits.isNotEmpty ||
        auditsProvider.auditsAtMyLocation.isNotEmpty;

    // A full-screen spinner is only ever right on a genuinely cold start:
    // nothing on screen yet AND the first pass over all three sources
    // still unfinished.
    //
    // This used to be an AND across all six "loading AND list still empty"
    // conditions, which happened to behave sensibly only because a refetch
    // always ran with the PREVIOUS filter's rows still sitting in the
    // lists. Filters break that assumption: a filter that legitimately
    // matches nothing empties all three lists, and the next refetch after
    // it would have blanked the whole calendar to a spinner. Gating on the
    // first-load flag instead means every later fetch keeps the grid — and
    // the month the user navigated to — on screen, with the hairline
    // progress bar above it as the only signal; flashing a spinner over
    // the calendar on every filter tweak costs the user their place for
    // the sake of a few hundred milliseconds. It also covers the frame
    // before initState's post-frame callback has even fired (isBusy is
    // still false there), which otherwise shows one frame of empty grid.
    final showColdStartSpinner = !_hasCompletedFirstLoad && !hasAnythingToShow;

    final myAuditIds = auditsProvider.audits.map((a) => a.id).toSet();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [
          // Centered so the button keeps its own compact height instead of
          // being stretched to the full toolbar height by the actions Row.
          Center(
            child: FilterButton(
              activeCount: auditsProvider.activeFilterCount,
              onTap: _openFilters,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (auditsProvider.hasActiveFilters)
            _ActiveFilterBar(
              labels: _activeFilterLabels(auditsProvider, filterOptions),
              onClear: _clearFilters,
            ),
          // Fixed 2px whether or not it is showing anything, so the grid
          // doesn't shift down and snap back on every refetch.
          SizedBox(
            height: 2,
            child: isBusy && !showColdStartSpinner
                ? const LinearProgressIndicator(minHeight: 2)
                : null,
          ),
          Expanded(
            child: showColdStartSpinner
                ? const AppLoading()
                : MonthCalendar(
                    visibleMonth: _visibleMonth,
                    // The grid's own chevrons report back here so the next
                    // filter-sheet open offers the month actually on
                    // screen, not the one this screen opened on.
                    onVisibleMonthChanged: (month) =>
                        setState(() => _visibleMonth = month),
                    legend: const _CalendarLegend(),
                    events: [
                      ...ncProvider.raisedAgainstMe
                          .where((nc) => nc.targetDate != null)
                          .map(
                            (nc) => CalendarEvent(
                              date: nc.targetDate!,
                              title: nc.title,
                              subtitle: nc.status,
                              color: AppColors.red,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => nc.status == 'Raised'
                                      ? NcResponseScreen(nc: nc)
                                      : NcReviewScreen(nc: nc),
                                ),
                              ),
                            ),
                          ),
                      ...auditsProvider.audits
                          .where((a) => a.scheduledDate != null)
                          .expand(
                            (a) => daysInAuditRange(a).map(
                              (day) => CalendarEvent(
                                date: day,
                                title: a.title,
                                subtitle: a.status,
                                color: a.status == 'Completed'
                                    ? AppColors.green
                                    : AppColors.amber,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        AuditDetailScreen(auditId: a.id),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      // The blue layer answers a different question from
                      // the amber/green one, and the filters reach it
                      // differently on purpose: AuditsProvider.refetch
                      // ForFilters re-runs this list with the location and
                      // audit-type params but NOT employeeIds, because
                      // GET /audits/at-my-location is scoped by the
                      // caller's own location membership (see audit.
                      // controller.js#getAuditsAtMyLocation) — an
                      // employeeIds there would mean nothing. So a people
                      // filter narrows the amber/green layer while blue
                      // stays put, which is exactly right: "who is coming
                      // to audit my location" was never a question about
                      // the people you filtered to.
                      //
                      // The dedupe below still holds under filters, and
                      // note what it now does: myAuditIds is the FILTERED
                      // set, so an audit of mine that the current people
                      // filter excludes drops out of amber/green and
                      // reappears here in blue. That is the honest answer
                      // — under a filter that isn't about me, that audit
                      // genuinely is "someone else's audit at my
                      // location". What it never does is plot twice.
                      ...auditsProvider.auditsAtMyLocation
                          .where(
                            (a) =>
                                a.scheduledDate != null &&
                                !myAuditIds.contains(a.id),
                          )
                          .expand(
                            (a) => daysInAuditRange(a).map(
                              (day) => CalendarEvent(
                                date: day,
                                title: a.title,
                                subtitle: a.auditorNames.isNotEmpty
                                    ? 'Audit visit — ${a.auditorNames.join(', ')}'
                                    : 'Audit visit at your location',
                                color: AppColors.blue,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) =>
                                        AuditDetailScreen(auditId: a.id),
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                    emptyDayBuilder: (context, _) => Center(
                      child: Text(
                        'Nothing due this day.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One short label per narrowed dimension, in the same order the sheet
/// lists them. Kept to counts past a single selection because this bar has
/// exactly one line to spend — the month grid needs the rest of the height
/// on a phone, and the sheet itself is one tap away for the detail.
List<String> _activeFilterLabels(
  AuditsProvider audits,
  FilterOptionsProvider options,
) {
  final labels = <String>[];
  if (audits.employeeFilter.isNotEmpty) {
    // A non-empty people pick WINS over the Me/Team flag (see
    // AuditFilterScope.filterParams), so showing "Team" alongside it would
    // describe a scope that isn't in force.
    labels.add(
      _summarise(
        audits.employeeFilter,
        {for (final e in options.employees) e.id: e.name},
        'person',
        'people',
      ),
    );
  } else if (audits.isTeamScope) {
    labels.add('Team');
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
      height: 38,
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
              minimumSize: const Size(0, 30),
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

class _CalendarLegendEntry {
  final String label;
  final Color color;
  const _CalendarLegendEntry(this.label, this.color);
}

const _legendEntries = [
  _CalendarLegendEntry('Non-Conformance', AppColors.red),
  _CalendarLegendEntry('Audit', AppColors.amber),
  _CalendarLegendEntry('Completed', AppColors.green),
  _CalendarLegendEntry('Audit at Your Location', AppColors.blue),
];

/// Same dot+label row as the web calendar's own legend (Calendar.jsx) —
/// wraps onto a second line on a narrow phone rather than the single
/// `d-flex flex-wrap` row web can afford at full width.
///
/// Deliberately static: it labels the four categories this screen can
/// draw, not the ones currently on screen. A legend that dropped entries
/// as a filter emptied them would make the colour scheme itself look like
/// it changes between months, and would hide the fact that e.g. the blue
/// layer is unaffected by a people filter.
class _CalendarLegend extends StatelessWidget {
  const _CalendarLegend();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Wrap(
        spacing: 14,
        runSpacing: 4,
        children: [
          for (final e in _legendEntries)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: 5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: e.color,
                  ),
                ),
                Text(
                  e.label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.outline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
