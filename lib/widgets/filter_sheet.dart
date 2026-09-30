import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/audit_status.dart';
import '../core/utils/place_cascade.dart';
import '../models/employee_option.dart';
import '../models/nc_model.dart' show kNcFlags;
import '../providers/audit_filter_scope.dart';
import '../providers/audits_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/dashboard_provider.dart';
import '../providers/filter_options_provider.dart';
import '../providers/nc_provider.dart';
import 'location_filter_sheet.dart';
import 'picker_sheet.dart';

// Only ever rendered as "September 2025" in the Month stepper — kept at
// file scope (not rebuilt per frame inside build) because DateFormat
// parses its pattern on construction, and the stepper rebuilds on every
// chevron tap. Not in Formatters because nothing else in the app shows a
// bare month; Formatters.date stays the one date format everywhere else.
final _monthLabel = DateFormat('MMMM yyyy');
final _dayLabel = DateFormat('d MMM yyyy');

/// widgets/filter_sheet.dart
/// ───────────────────────────────────────
/// The one filter surface for every audit/NC screen (Dashboard, Audits, NC,
/// Calendar, Final Report) — the phone's answer to the web portal's filter
/// bar: Team, Members, Location (+ Department, grouped Area / Zone / Sub
/// Zone), Audit Type, Date range, Status (multi-select, with Include
/// skipped) and, for NCs, Flag. Folded into a single bottom sheet because
/// there is no room on a 360px screen for a row of always-open pickers; the
/// long lists (teams, members, locations) open their own searchable pickers.
///
/// Nothing here touches a provider's filter state. The sheet hands back
/// what was picked and the CALLING screen applies it with
/// [applyAuditFilterSelection] — which pushes it to Audits, Dashboard AND
/// NC providers so the state is shared across every screen, like the web's
/// "filters follow you from page to page". That makes Cancel genuinely
/// free: dismissing without Apply has changed nothing.
class AuditFilterSelection {
  /// "All Members" (true) vs "Me" (false). Ignored server-side whenever
  /// [employees] or [teams] narrow the people — see AuditFilterScope.
  final bool isTeam;

  /// Explicit Members picks (employee ids), empty for "no specific people".
  final List<String> employees;

  /// Team ids, and everyone in those teams (resolved by the sheet from the
  /// hierarchy directory — see AuditFilterScope.teamMemberIds).
  final List<String> teams;
  final List<String> teamMembers;

  /// Team / Members picks a picked place has SET ASIDE (people who don't belong
  /// to it): not applied — [teams] / [employees] / [teamMembers] hold only what
  /// the requests use — but kept here so clearing the place brings them back
  /// (see AuditFilterScope.heldTeamFilter).
  final List<String> heldTeams;
  final List<String> heldEmployees;

  /// Location ids and department ids — one "where" facet (empty both = All).
  final List<String> locations;
  final List<String> departments;

  /// Audit type NAMES, not ids — Audit.auditType stores the name and the
  /// server's `?auditType=` matches on it (models/audit_type_option.dart).
  final List<String> auditTypes;

  /// Inclusive scheduled-date window; null = open end.
  final DateTime? dateFrom;
  final DateTime? dateTo;

  /// Picked statuses (AuditStatus.pipeline) and the Include skipped switch —
  /// only meaningful on an audit list.
  final List<String> statuses;
  final bool includeSkipped;

  /// NC flag picks (only NC lists read them).
  final List<String> flags;

  /// First-of-month, and non-null ONLY when the sheet was opened with a
  /// month (i.e. by the Calendar). Every other caller gets null and can
  /// ignore the field entirely rather than having to guard against a month
  /// it never asked to show.
  final DateTime? month;

  const AuditFilterSelection({
    this.isTeam = false,
    this.employees = const [],
    this.teams = const [],
    this.teamMembers = const [],
    this.heldTeams = const [],
    this.heldEmployees = const [],
    this.locations = const [],
    this.departments = const [],
    this.auditTypes = const [],
    this.dateFrom,
    this.dateTo,
    this.statuses = const [],
    this.includeSkipped = false,
    this.flags = const [],
    this.month,
  });

  /// The resting state: just me, everywhere, every type, any date.
  static const cleared = AuditFilterSelection();

  /// What a provider holds right now, as a selection.
  factory AuditFilterSelection.fromScope(
    AuditFilterScope scope, {
    DateTime? month,
  }) {
    return AuditFilterSelection(
      isTeam: scope.isTeamScope,
      employees: scope.employeeFilter,
      teams: scope.teamFilter,
      teamMembers: scope.teamMemberIds,
      heldTeams: scope.heldTeamFilter,
      heldEmployees: scope.heldEmployeeFilter,
      locations: scope.locationFilter,
      departments: scope.departmentFilter,
      auditTypes: scope.auditTypeFilter,
      dateFrom: scope.dateFrom,
      dateTo: scope.dateTo,
      statuses: scope.statusFilter,
      includeSkipped: scope.includeSkipped,
      flags: scope.flagFilter,
      month: month,
    );
  }

  AuditFilterSelection copyWith({
    bool? isTeam,
    List<String>? employees,
    List<String>? teams,
    List<String>? teamMembers,
    List<String>? heldTeams,
    List<String>? heldEmployees,
    List<String>? locations,
    List<String>? departments,
    List<String>? auditTypes,
    (DateTime?, DateTime?)? dateRange,
    List<String>? statuses,
    bool? includeSkipped,
    List<String>? flags,
    DateTime? month,
  }) {
    return AuditFilterSelection(
      isTeam: isTeam ?? this.isTeam,
      employees: employees ?? this.employees,
      teams: teams ?? this.teams,
      teamMembers: teamMembers ?? this.teamMembers,
      heldTeams: heldTeams ?? this.heldTeams,
      heldEmployees: heldEmployees ?? this.heldEmployees,
      locations: locations ?? this.locations,
      departments: departments ?? this.departments,
      auditTypes: auditTypes ?? this.auditTypes,
      dateFrom: dateRange != null ? dateRange.$1 : dateFrom,
      dateTo: dateRange != null ? dateRange.$2 : dateTo,
      statuses: statuses ?? this.statuses,
      includeSkipped: includeSkipped ?? this.includeSkipped,
      flags: flags ?? this.flags,
      month: month ?? this.month,
    );
  }
}

/// Pushes [selection] into every filter-holding provider (Audits, Dashboard,
/// NC) and refetches them — the filters are one shared state across the app,
/// not per-screen, so a filter set on the Audits tab is the one the Dashboard
/// tiles and the NC list are computed under too (the web keeps filters across
/// pages the same way).
///
/// Providers are read before the first await so there is no `context` use
/// afterwards.
Future<void> applyAuditFilterSelection(
  BuildContext context,
  AuditFilterSelection selection,
) {
  final providers = <AuditFilterScope>[
    context.read<AuditsProvider>(),
    context.read<DashboardProvider>(),
    context.read<NcProvider>(),
  ];
  return Future.wait([
    for (final p in providers)
      p.applyFilters(
        isTeam: selection.isTeam,
        employees: selection.employees,
        teams: selection.teams,
        teamMembers: selection.teamMembers,
        heldTeams: selection.heldTeams,
        heldEmployees: selection.heldEmployees,
        locations: selection.locations,
        departments: selection.departments,
        auditTypes: selection.auditTypes,
        dateRange: (selection.dateFrom, selection.dateTo),
        statuses: selection.statuses,
        includeSkipped: selection.includeSkipped,
        flags: selection.flags,
      ),
  ]);
}

/// Opens the filter sheet seeded with [initial].
///
/// Which sections show is per screen: [showStatus] (audit lists — Status +
/// Include skipped), [showFlag] (NC lists), [showDateRange]. Pass a non-null
/// `initial.month` to switch the Month section on (the Calendar); leave it
/// null everywhere else.
///
/// Returns null if dismissed without applying — back button, tap-outside
/// and drag-to-close all land there, so a null result means "leave every
/// filter exactly as it was", never "clear them".
Future<AuditFilterSelection?> showAuditFilterSheet(
  BuildContext context, {
  required AuditFilterSelection initial,
  bool showStatus = false,
  bool showFlag = false,
  bool showDateRange = true,
}) {
  return showModalBottomSheet<AuditFilterSelection>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    // Capped on a tablet-width screen instead of stretching this sheet's
    // rows (location chips, date fields...) edge to edge — the sheet
    // route's own default Alignment.bottomCenter already centers a
    // narrower-than-screen sheet horizontally, so no extra Center/Align is
    // needed on top of this.
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _AuditFilterSheet(
      initial: initial,
      showStatus: showStatus,
      showFlag: showFlag,
      showDateRange: showDateRange,
    ),
  );
}

class _AuditFilterSheet extends StatefulWidget {
  final AuditFilterSelection initial;
  final bool showStatus;
  final bool showFlag;
  final bool showDateRange;

  const _AuditFilterSheet({
    required this.initial,
    required this.showStatus,
    required this.showFlag,
    required this.showDateRange,
  });

  @override
  State<_AuditFilterSheet> createState() => _AuditFilterSheetState();
}

class _AuditFilterSheetState extends State<_AuditFilterSheet> {
  // The whole selection is local until Apply — the sheet is a draft of a
  // filter, not a live control.
  late bool _isTeam = widget.initial.isTeam;
  // Team / Members hold EVERYTHING picked, the ones a picked place has set aside
  // included: the place narrows what is offered and applied (see [_who]) but
  // never rewrites these, so clearing the place brings its picks back.
  late List<String> _teams = _union(widget.initial.teams, widget.initial.heldTeams);
  late List<String> _members = _union(
    widget.initial.employees,
    widget.initial.heldEmployees,
  );
  late List<String> _locations = [...widget.initial.locations];
  late List<String> _departments = [...widget.initial.departments];
  late List<String> _auditTypes = [...widget.initial.auditTypes];
  late DateTime? _from = widget.initial.dateFrom;
  late DateTime? _to = widget.initial.dateTo;
  late List<String> _statuses = [...widget.initial.statuses];
  late bool _includeSkipped = widget.initial.includeSkipped;
  late List<String> _flags = [...widget.initial.flags];
  late DateTime? _month = _normaliseMonth(widget.initial.month);

  // The Me/All Members ids are relabelled "Me" in the Members list, matching
  // the web MemberFilterSelect's `isSelf ? "Me"`.
  String? _selfId;

  bool get _showMonth => widget.initial.month != null;

  @override
  void initState() {
    super.initState();
    _selfId = context.read<AuthProvider>().user?.id;
    // load() is idempotent and coalesces concurrent callers, so firing it
    // on every open is free — but it flips isLoading and notifies
    // synchronously, which during this first build would be a
    // setState-during-build crash. Post-frame is the cheap fix.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<FilterOptionsProvider>().load();
    });
  }

  static List<String> _union(List<String> a, List<String> b) => [
    ...a,
    for (final x in b)
      if (!a.contains(x)) x,
  ];

  /// What Team / Members really mean under the picked place (people who don't
  /// belong to it are set aside; the Location list narrows to the picked
  /// people's places) — see core/utils/place_cascade.dart. Waits for the
  /// directory: until it has loaded nothing is narrowed or set aside.
  WhoCascade _who(
    FilterOptionsProvider options, {
    List<String>? locations,
    List<String>? departments,
  }) => WhoCascade.resolve(
    directory: options.employees,
    locations: options.locations,
    teams: _teams,
    members: _members,
    locationIds: locations ?? _locations,
    departmentIds: departments ?? _departments,
    // Me is the untouched default: it must not narrow the Location list.
    untouchedMembers: !_isTeam && _selfId != null ? [_selfId!] : const [],
  );

  static DateTime? _normaliseMonth(DateTime? value) =>
      value == null ? null : DateTime(value.year, value.month, 1);

  /// Back to the resting default WITHOUT closing the sheet, so "reset then
  /// pick two things" is one continuous gesture. Nothing is pushed to the
  /// providers until Apply.
  void _reset() {
    setState(() {
      _isTeam = false;
      _teams = [];
      _members = [];
      _locations = [];
      _departments = [];
      _auditTypes = [];
      _from = null;
      _to = null;
      _statuses = [];
      _includeSkipped = false;
      _flags = [];
      final now = DateTime.now();
      _month = _showMonth ? DateTime(now.year, now.month, 1) : null;
    });
  }

  // Counts what is really applied: a pick the place set aside is not one.
  int _draftCountFor(WhoCascade who) =>
      (who.teams.isNotEmpty ? 1 : 0) +
      (who.members.isNotEmpty || (who.teams.isEmpty && _isTeam) ? 1 : 0) +
      (_locations.isNotEmpty || _departments.isNotEmpty ? 1 : 0) +
      (_auditTypes.isNotEmpty ? 1 : 0) +
      (widget.showDateRange && (_from != null || _to != null) ? 1 : 0) +
      (widget.showStatus && _statuses.isNotEmpty ? 1 : 0) +
      (widget.showStatus && _includeSkipped ? 1 : 0) +
      (widget.showFlag && _flags.isNotEmpty ? 1 : 0);

  /// Me / All Members. Both CLEAR the Team and Members picks: the controls
  /// are one decision ("who am I looking at"), and leaving a stale list
  /// behind would mean tapping "Me" visibly selected the chip while the
  /// query kept returning someone else's audits — a specific pick wins.
  void _pickScope(bool isTeam) {
    setState(() {
      _isTeam = isTeam;
      _teams = [];
      _members = [];
    });
  }

  Future<void> _pickTeams(FilterOptionsProvider options) async {
    final who = _who(options);
    final picked = await showMultiPickerSheet<String>(
      context,
      title: 'Team',
      subtitle: who.placeApplies
          ? 'Teams of the people at the picked place.'
          : 'Everyone in the picked teams.',
      searchHint: 'Search teams',
      selected: who.teams,
      confirmLabel: 'Apply teams',
      items: [
        // Only the teams of the people the picked place leaves in play, counted
        // over those people.
        for (final t in options.teamsOf(who.pool))
          PickerItem(
            value: t.id,
            label: t.name,
            sublabel: '${t.count} ${t.count == 1 ? 'person' : 'people'}',
          ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      // A team the place set aside is not on offer to untick: it stays saved.
      _teams = _union(picked, who.heldTeams);
      // Members cascades from Team: keep only people still inside the teams;
      // if none remain the new team simply means "all of it".
      if (_teams.isNotEmpty && _members.isNotEmpty) {
        final inTeams = options.membersOfTeams(_teams).map((e) => e.id).toSet();
        _members = _members.where(inTeams.contains).toList();
      }
    });
  }

  List<EmployeeOption> _memberPool(WhoCascade who) {
    // The people the picked place leaves in play, inside the picked team(s).
    final teamSet = who.teams.toSet();
    final pool = [
      for (final e in who.pool)
        if (teamSet.isEmpty || e.teams.any((t) => teamSet.contains(t.id))) e,
    ];
    // 'Me' first, then active people by name, then the deactivated ones.
    pool.sort((a, b) {
      if (a.id == _selfId) return -1;
      if (b.id == _selfId) return 1;
      if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return pool;
  }

  Future<void> _pickMembers(FilterOptionsProvider options) async {
    final who = _who(options);
    final pool = _memberPool(who);
    final picked = await showMultiPickerSheet<String>(
      context,
      title: 'Members',
      subtitle: who.placeApplies ? 'People at the picked place.' : null,
      searchHint: 'Search members',
      // "All Members" row: opens with everything ticked while no one is picked
      // under All Members, and ticking everyone by hand is the same thing.
      allLabel: pool.length > 1 ? 'All Members' : null,
      initiallyAll: _isTeam && who.members.isEmpty,
      selected: who.members,
      confirmLabel: 'Apply members',
      items: [
        for (final e in pool)
          PickerItem(
            value: e.id,
            label: e.id == _selfId
                ? 'Me'
                : (e.isActive ? e.name : '${e.name} (inactive)'),
            sublabel: e.teams.isEmpty
                ? null
                : e.teams.map((t) => t.name).join(', '),
          ),
      ],
    );
    if (picked == null || !mounted) return;
    // Everyone ticked = All Members (no explicit list, and the scope reads All).
    if (pool.length > 1 && picked.length == pool.length) {
      setState(() {
        _isTeam = true;
        _members = [];
      });
      return;
    }
    setState(() => _members = _union(picked, who.heldMembers));
  }

  Future<void> _pickWhere(FilterOptionsProvider options) async {
    final result = await showLocationFilterSheet(
      context,
      locations: options.locations,
      departments: options.departments,
      departmentsByLocation: options.departmentsByLocation,
      selectedLocations: _locations,
      selectedDepartments: _departments,
      loading: options.isLoading,
      failed: options.locationsFailed,
      fullAccess: options.fullAccess,
      // Picked people / teams narrow the places on offer to the ones they belong
      // to. Asked again for the sheet's LIVE ticks: ticking a place can set a
      // pick aside, which changes which people count.
      restrictTo: (locs, depts) =>
          _who(options, locations: locs, departments: depts).placeRestriction,
    );
    if (result == null || !mounted) return;
    setState(() {
      _locations = result.locations;
      _departments = result.departments;
    });
  }

  Future<void> _pickDate({required bool from}) async {
    final now = DateTime.now();
    final initial = (from ? _from : _to) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 5, 12, 31),
      helpText: from ? 'From date' : 'To date',
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (from) {
        _from = picked;
        if (_to != null && _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from != null && _from!.isAfter(picked)) _from = picked;
      }
    });
  }

  void _datePreset(String which) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() {
      switch (which) {
        case 'month':
          _from = DateTime(now.year, now.month, 1);
          _to = DateTime(now.year, now.month + 1, 0);
        case 'last-month':
          _from = DateTime(now.year, now.month - 1, 1);
          _to = DateTime(now.year, now.month, 0);
        case '30':
          _from = today.subtract(const Duration(days: 29));
          _to = today;
        case 'year':
          _from = DateTime(now.year, 1, 1);
          _to = DateTime(now.year, 12, 31);
      }
    });
  }

  void _stepMonth(int delta) {
    final current = _month;
    if (current == null) return;
    // DateTime normalises an out-of-range month itself.
    setState(() => _month = DateTime(current.year, current.month + delta, 1));
  }

  void _thisMonth() {
    final now = DateTime.now();
    setState(() => _month = DateTime(now.year, now.month, 1));
  }

  void _apply() {
    final options = context.read<FilterOptionsProvider>();
    // What Team / Members mean under the picked place: the people the place set
    // aside are neither applied nor forgotten (held), so the scope sent to the
    // server is exactly what the sheet shows.
    final who = _who(options);
    // Without a directory nothing was narrowed or set aside on screen; keep
    // what was held before so an unrelated Apply never turns it back on.
    final ready = options.employees.isNotEmpty;
    final heldT = widget.initial.heldTeams;
    final heldM = widget.initial.heldEmployees;
    final teams = ready ? who.teams : _teams.where((t) => !heldT.contains(t)).toList();
    final members = ready
        ? who.members
        : _members.where((m) => !heldM.contains(m)).toList();
    // Team → people, resolved here from the directory the sheet already
    // holds (within the picked place, as the Members list is); a team the
    // directory can't resolve (not loaded) keeps the previous resolution so an
    // unrelated Apply never wipes it.
    final teamMembers = teams.isEmpty
        ? const <String>[]
        : (ready ? who.teamMembers : widget.initial.teamMembers);
    Navigator.of(context).pop(
      AuditFilterSelection(
        isTeam: _isTeam,
        employees: members,
        teams: teams,
        teamMembers: teamMembers,
        heldTeams: ready ? who.heldTeams : _teams.where(heldT.contains).toList(),
        heldEmployees: ready
            ? who.heldMembers
            : _members.where(heldM.contains).toList(),
        locations: _locations,
        departments: _departments,
        auditTypes: _auditTypes,
        dateFrom: widget.showDateRange ? _from : widget.initial.dateFrom,
        dateTo: widget.showDateRange ? _to : widget.initial.dateTo,
        statuses: widget.showStatus ? _statuses : widget.initial.statuses,
        includeSkipped: widget.showStatus
            ? _includeSkipped
            : widget.initial.includeSkipped,
        flags: widget.showFlag ? _flags : widget.initial.flags,
        // Null whenever the section wasn't shown — a caller that never
        // offered a month must not be handed one it would then have to
        // know to ignore.
        month: _showMonth ? _month : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options = context.watch<FilterOptionsProvider>();
    final media = MediaQuery.of(context);
    final who = _who(options);

    // Height-bounded and internally scrollable, so the Apply button is
    // pinned and can never end up below the fold. Never taller than what's
    // actually left once the keyboard and the status bar have taken their
    // share.
    final maxSheetHeight = math.min(
      media.size.height * 0.9,
      media.size.height - media.viewInsets.bottom - media.padding.top - 8,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      // A Material, not a decorated Container: the rows below paint ink on
      // the nearest Material — under a coloured Container that ink is lost.
      child: Material(
        color: scheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: math.max(maxSheetHeight, 260)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              _buildHeader(context, who),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (options.anyFailed && !options.isLoading)
                        _RetryBanner(
                          onRetry: () => options.load(force: true),
                        ),
                      _buildPeopleSection(context, options, who),
                      const _SectionGap(),
                      _buildWhereSection(context, options),
                      const _SectionGap(),
                      _buildAuditTypeSection(context, options),
                      if (widget.showDateRange) ...[
                        const _SectionGap(),
                        _buildDateSection(context),
                      ],
                      if (widget.showStatus) ...[
                        const _SectionGap(),
                        _buildStatusSection(context),
                      ],
                      if (widget.showFlag) ...[
                        const _SectionGap(),
                        _buildFlagSection(context),
                      ],
                      if (_showMonth) ...[
                        const _SectionGap(),
                        _buildMonthSection(context),
                      ],
                    ],
                  ),
                ),
              ),
              _buildFooter(context, who),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, WhoCascade who) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Row(
        children: [
          Text(
            'Filters',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (_draftCountFor(who) > 0) ...[
            const SizedBox(width: 8),
            _CountPill(count: _draftCountFor(who)),
          ],
          const Spacer(),
          TextButton(
            onPressed: _draftCountFor(who) == 0 && !_showMonth ? null : _reset,
            style: TextButton.styleFrom(foregroundColor: scheme.primary),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }

  // ── People: Me / All Members, Team, Members ───────────────────────────
  Widget _buildPeopleSection(
    BuildContext context,
    FilterOptionsProvider options,
    WhoCascade who,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // What is really applied: a pick the picked place set aside does not count.
    final specific = who.members.isNotEmpty || who.teams.isNotEmpty;
    final loading = options.isLoading && options.employees.isEmpty;
    final poolTeams = options.teamsOf(who.pool);
    final memberPool = _memberPool(who);
    final held = who.heldTeams.length + who.heldMembers.length;

    String teamSummary() {
      if (who.teams.isEmpty) return 'All teams';
      if (who.teams.length == 1) {
        for (final t in options.teams) {
          if (t.id == who.teams.first) return t.name;
        }
        return '1 team';
      }
      return '${who.teams.length} teams';
    }

    String memberSummary() {
      if (who.members.isEmpty) {
        return who.teams.isEmpty
            ? 'Choose specific people'
            : 'Everyone in the team';
      }
      if (who.members.length == 1) {
        if (who.members.first == _selfId) return 'Only me';
        for (final e in options.employees) {
          if (e.id == who.members.first) return e.name;
        }
        return '1 member';
      }
      return '${who.members.length} members';
    }

    // Directory empty = not loaded / failed: tap retries. Directory loaded but
    // the picked place has no people (or no teams) = a plain, untappable note.
    final noDirectory = options.employees.isEmpty;
    final teamsOnPlace =
        !loading && !noDirectory && who.placeApplies && poolTeams.isEmpty;
    final peopleOnPlace =
        !loading && !noDirectory && who.placeApplies && memberPool.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Who'),
        const SizedBox(height: 8),
        // Wrap, not Row: a longer/translated label must be free to fall onto
        // a second line rather than overflow at 360px.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              avatar: const Icon(Icons.person_outline, size: 16),
              label: const Text('Me'),
              selected: !specific && !_isTeam,
              onSelected: (_) => _pickScope(false),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.groups_outlined, size: 16),
              label: const Text('All Members'),
              selected: !specific && _isTeam,
              onSelected: (_) => _pickScope(true),
            ),
          ],
        ),
        if (specific) ...[
          const SizedBox(height: 6),
          Text(
            'Showing the team / people picked below — tap Me or All Members to go back.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
        if (who.placeApplies) ...[
          const SizedBox(height: 6),
          Text(
            held > 0
                ? 'Team and Members list only the people at the picked location / department. '
                      '$held pick${held == 1 ? '' : 's'} outside it ${held == 1 ? 'is' : 'are'} set aside — clear the location to bring ${held == 1 ? 'it' : 'them'} back.'
                : 'Team and Members list only the people at the picked location / department.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
        const SizedBox(height: 10),
        _PickTile(
          icon: Icons.diversity_3_outlined,
          title: 'Team',
          summary: loading ? 'Loading…' : teamSummary(),
          active: who.teams.isNotEmpty,
          onTap: loading || teamsOnPlace
              ? null
              : (noDirectory || options.teams.isEmpty)
              ? () => options.load(force: true)
              : () => _pickTeams(options),
          disabledHint: teamsOnPlace
              ? 'No teams at the picked location'
              : !loading && options.teams.isEmpty
              ? 'No teams available — tap to retry'
              : null,
        ),
        const SizedBox(height: 8),
        _PickTile(
          icon: Icons.person_search_outlined,
          title: 'Members',
          summary: loading ? 'Loading…' : memberSummary(),
          active: who.members.isNotEmpty,
          onTap: loading || peopleOnPlace
              ? null
              : noDirectory
              ? () => options.load(force: true)
              : () => _pickMembers(options),
          disabledHint: peopleOnPlace
              ? (who.teams.isEmpty
                    ? 'No people at the picked location'
                    : 'No people of the picked team at the location')
              : !loading && options.employees.isEmpty
              ? 'No people available — tap to retry'
              : null,
        ),
      ],
    );
  }

  // ── Where: Location + Department ─────────────────────────────────────
  Widget _buildWhereSection(
    BuildContext context,
    FilterOptionsProvider options,
  ) {
    String summary() {
      final picked = _locations.length + _departments.length;
      if (picked == 0) return 'All locations';
      if (picked == 1) {
        if (_locations.length == 1) {
          for (final l in options.locations) {
            if (l.id == _locations.first) return l.name;
          }
          return '1 location';
        }
        for (final d in options.departments) {
          if (d.id == _departments.first) return d.name;
        }
        return '1 department';
      }
      return [
        if (_locations.isNotEmpty)
          '${_locations.length} location${_locations.length == 1 ? '' : 's'}',
        if (_departments.isNotEmpty)
          '${_departments.length} dept${_departments.length == 1 ? '' : 's'}',
      ].join(', ');
    }

    final loading =
        options.isLoading &&
        options.locations.isEmpty &&
        options.departments.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Where'),
        const SizedBox(height: 8),
        _PickTile(
          icon: Icons.place_outlined,
          title: 'Location & Department',
          summary: loading ? 'Loading…' : summary(),
          active: _locations.isNotEmpty || _departments.isNotEmpty,
          onTap: loading ? null : () => _pickWhere(options),
        ),
      ],
    );
  }

  // ── Audit type ────────────────────────────────────────────────────────
  Widget _buildAuditTypeSection(
    BuildContext context,
    FilterOptionsProvider options,
  ) {
    // Selection travels by NAME (the server matches Audit.auditType, a
    // plain string), so two types configured with the same name are one
    // and the same filter — deduped here rather than rendering two chips
    // that mysteriously toggle together.
    final names = <String>[];
    final seen = <String>{};
    for (final type in options.auditTypes) {
      if (type.name.isNotEmpty && seen.add(type.name)) names.add(type.name);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Audit Type'),
        const SizedBox(height: 8),
        if (options.isLoading && options.auditTypes.isEmpty)
          const _LoadingLine('Loading audit types…')
        else if (names.isEmpty)
          _MutedLine(
            options.auditTypesFailed
                ? "Couldn't load audit types."
                : 'No audit types available to filter by.',
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in names)
                FilterChip(
                  label: Text(name),
                  selected: _auditTypes.contains(name),
                  onSelected: (v) => setState(() {
                    _auditTypes = v
                        ? [..._auditTypes, name]
                        : _auditTypes.where((n) => n != name).toList();
                  }),
                ),
            ],
          ),
      ],
    );
  }

  // ── Date range ────────────────────────────────────────────────────────
  Widget _buildDateSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionTitle('Date range')),
            if (_from != null || _to != null)
              TextButton(
                onPressed: () => setState(() {
                  _from = null;
                  _to = null;
                }),
                child: const Text('Clear'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _DateField(
                label: 'From',
                value: _from,
                onTap: () => _pickDate(from: true),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _DateField(
                label: 'To',
                value: _to,
                onTap: () => _pickDate(from: false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final (id, label) in const [
              ('month', 'This month'),
              ('last-month', 'Last month'),
              ('30', 'Last 30 days'),
              ('year', 'This year'),
            ])
              ActionChip(
                label: Text(label),
                side: BorderSide(color: scheme.outlineVariant),
                onPressed: () => _datePreset(id),
              ),
          ],
        ),
      ],
    );
  }

  // ── Status (audit lists) ──────────────────────────────────────────────
  Widget _buildStatusSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Status'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final status in AuditStatus.pipeline)
              FilterChip(
                avatar: Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    // readable(): the raw status tokens are dark by design
                    // (badge text on a light tint) and sink into dark mode.
                    color: AppColors.readable(
                      context,
                      AppColors.forAuditStatus(status),
                    ),
                    shape: BoxShape.circle,
                  ),
                ),
                label: Text(status),
                selected: _statuses.contains(status),
                onSelected: (v) => setState(() {
                  _statuses = v
                      ? [..._statuses, status]
                      : _statuses.where((s) => s != status).toList();
                }),
              ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Include skipped / reassigned audits'),
          value: _includeSkipped,
          onChanged: (v) => setState(() => _includeSkipped = v),
        ),
      ],
    );
  }

  // ── Flag (NC lists) ───────────────────────────────────────────────────
  Widget _buildFlagSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Flag'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final flag in kNcFlags)
              FilterChip(
                label: Text(flag),
                selected: _flags.contains(flag),
                onSelected: (v) => setState(() {
                  _flags = v
                      ? [..._flags, flag]
                      : _flags.where((f) => f != flag).toList();
                }),
              ),
          ],
        ),
      ],
    );
  }

  // ── Month (Calendar only) ─────────────────────────────────────────────
  Widget _buildMonthSection(BuildContext context) {
    final month = _month;
    if (month == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionTitle('Month')),
            TextButton(onPressed: _thisMonth, child: const Text('This month')),
          ],
        ),
        // icon / label / icon — the label is the only flexible child, so
        // there is nothing here that can overflow however long the month
        // name gets.
        Row(
          children: [
            IconButton(
              onPressed: () => _stepMonth(-1),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous month',
            ),
            Expanded(
              child: Text(
                _monthLabel.format(month),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: () => _stepMonth(1),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next month',
            ),
          ],
        ),
      ],
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────
  Widget _buildFooter(BuildContext context, WhoCascade who) {
    final scheme = Theme.of(context).colorScheme;
    // Outside the scroll view entirely — the one thing in this sheet that
    // must never need a scroll to reach.
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: FilledButton(
            onPressed: _apply,
            child: Text(
              _draftCountFor(who) == 0
                  ? 'Apply'
                  : 'Apply (${_draftCountFor(who)})',
            ),
          ),
        ),
      ),
    );
  }
}

/// A tappable summary row that opens one of the searchable pickers: icon,
/// title, the current pick as a muted line, chevron. Tinted while a pick is
/// active so it is clear at a glance which filters are on.
class _PickTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String summary;
  final bool active;
  final VoidCallback? onTap;
  final String? disabledHint;

  const _PickTile({
    required this.icon,
    required this.title,
    required this.summary,
    required this.active,
    required this.onTap,
    this.disabledHint,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: active
          ? scheme.primaryContainer.withValues(alpha: 0.4)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 20, color: active ? scheme.primary : scheme.outline),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.outline,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      disabledHint ?? summary,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onTap;

  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          prefixIcon: const Icon(Icons.event_outlined, size: 18),
        ),
        isEmpty: value == null,
        child: Text(
          value == null ? 'Any' : _dayLabel.format(value!),
          style: TextStyle(color: value == null ? scheme.outline : null),
        ),
      ),
    );
  }
}

class _RetryBanner extends StatelessWidget {
  final VoidCallback onRetry;

  const _RetryBanner({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              "Some filter options couldn't load.",
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _SectionGap extends StatelessWidget {
  const _SectionGap();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 22);
}

/// The trigger that opens [showAuditFilterSheet] — sized to sit in a
/// screen's header row beside a ScopeToggle, which is why it is an
/// outlined, shrink-wrapped 40px control rather than a full-height button.
/// [activeCount] comes straight from AuditFilterScope.activeFilterCount;
/// 0 means the resting state and shows no badge at all, so the badge only
/// ever appears when something really is narrowing the view.
class FilterButton extends StatelessWidget {
  final int activeCount;
  final VoidCallback onTap;

  const FilterButton({
    super.key,
    required this.activeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.tune_rounded, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Filters'),
          if (activeCount > 0) ...[
            const SizedBox(width: 6),
            _CountPill(count: activeCount),
          ],
        ],
      ),
      style: OutlinedButton.styleFrom(
        // 40px floor with shrinkWrap: tall enough to stay a comfortable
        // tap target, short enough not to out-size the SegmentedButton it
        // sits next to. Material's default padded target would add 8px of
        // invisible height and push the header row out of line.
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // No VisualDensity.compact here: compact takes 8px off a button's
        // minimum height, so the 40px floor above rendered as a 32px button
        // (visibly shorter than the SegmentedButton beside it).
        padding: const EdgeInsets.symmetric(horizontal: 14),
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The small primaryContainer count badge shared by the Filters button and
/// the "Choose specific people" disclosure — same pill ExpandableSection
/// puts on its section headers, so a count reads the same wherever it
/// appears.
class _CountPill extends StatelessWidget {
  final int count;

  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    );
  }
}

/// Per-section loading line rather than one spinner over the whole sheet:
/// FilterOptionsProvider fetches its three lists independently and lets any
/// one of them fail quietly, so a section still waiting must not hold the
/// other two hostage.
class _LoadingLine extends StatelessWidget {
  final String label;

  const _LoadingLine(this.label);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.outline,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _MutedLine extends StatelessWidget {
  final String text;

  const _MutedLine(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.outline),
      ),
    );
  }
}
