import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../core/utils/audit_status.dart';
import '../models/audit_model.dart';

/// The filter state shared by every audit-scoped list/stat fetch on the
/// phone — who (team / members), where (locations + departments), what kind
/// (audit type), when (date range) and, for audit lists, which status(es).
/// It mirrors the web portal's filter bar (useScopeFilter, LocationFilterSelect,
/// AuditTypeFilterSelect, DateRangeFilter, the Status multi-select).
///
/// Mixed into AuditsProvider, DashboardProvider and NcProvider rather than living in a
/// provider of its own, because each of those already owns the fetches the
/// filters have to re-run: a single shared filter object would still have
/// to reach back into both to refetch, and the two would have to stay
/// subscribed to it. This way `filterParams` is right next to the `_dio.get`
/// that spends it. The filter SHEET (widgets/filter_sheet.dart) is what
/// keeps the two providers' copies in step, exactly as ScopeToggle already
/// does for `isTeamScope`.
///
/// Server semantics to keep in mind: the default scope is Me; Me + a
/// Location = only my audits there; All Members + a Location = every audit
/// at that location (for places I belong to or lead), whoever the auditor is.
///
/// Every param here is understood by the server already — see
/// audit.controller.js's `resolveScopedEmployeeIds` (employeeIds),
/// `locationFilter` (locationIds, comma-separated) and `auditTypeFilter`
/// (auditType, comma-separated by NAME, since Audit.auditType stores the
/// name rather than a ref).
mixin AuditFilterScope on ChangeNotifier {
  /// "Me" vs "All Members" — the coarse toggle that most users never move
  /// off. Defaults to Me; see the implementing provider's own field comment.
  bool get isTeamScope;
  set isTeamScope(bool value);

  String? get selfEmployeeId;

  /// A precise pick of people from the Members filter. Non-empty always
  /// WINS over [isTeamScope] — picking specific people is a more specific
  /// statement than either end of the Me/All Members switch, and the sheet
  /// shows the two as one control anyway.
  List<String> employeeFilter = const [];

  /// Team ids picked in the Team filter (web: TeamFilterSelect). The sheet
  /// resolves them to people ([teamMemberIds], from the hierarchy directory
  /// it already holds) so this provider never needs the directory: with no
  /// explicit Members pick, a Team means "everyone in those teams".
  List<String> teamFilter = const [];

  /// Everyone in [teamFilter]'s teams, resolved by the sheet when it applied.
  /// (Within the picked place when there is one — see [heldTeamFilter].)
  List<String> teamMemberIds = const [];

  /// Team / Members picks a picked Location or Department has SET ASIDE: the
  /// people in them do not belong to that place, so they are not offered and
  /// not applied (they are absent from [teamFilter] / [employeeFilter], which
  /// are exactly what the requests and the pills use) — but they are not
  /// forgotten either: the sheet feeds them back in, so clearing the place
  /// brings them back (core/utils/place_cascade.dart#WhoCascade).
  List<String> heldTeamFilter = const [];
  List<String> heldEmployeeFilter = const [];

  /// Location ids to narrow to (Area / Zone / Sub Zone). Empty means every
  /// location this user can see (no param sent at all).
  List<String> locationFilter = const [];

  /// Department ids — with [locationFilter] ONE "where" facet: an audit
  /// matching either counts (server: buildAuditWhereFilter), and the pair
  /// ANDs with every other filter. "Only departments picked" is NOT "All".
  List<String> departmentFilter = const [];

  /// Audit type NAMES to narrow to (not ids — see the class doc above).
  List<String> auditTypeFilter = const [];

  /// Inclusive scheduled-date window (web: DateRangeFilter). Null = open end.
  DateTime? dateFrom;
  DateTime? dateTo;

  /// The unified statuses (AuditStatus.pipeline) picked in the Status filter;
  /// empty = all. Applied by [matchesStatusFilter] over the loaded audit list
  /// (audit lists only — the stat tiles always count every status, as on web).
  List<String> statusFilter = const [];

  /// The web's "Include skipped" switch: sends `includeSkipped=true` to the
  /// audit list so Skipped (and reassigned-away) audits are returned too.
  bool includeSkipped = false;

  /// NC flag (severity) picks — only NC lists read it (web: FlagFilterSelect).
  List<String> flagFilter = const [];

  static const _fmt = 'yyyy-MM-dd';

  /// Who the request is about, or null for "no employeeIds param" (= All
  /// Members: the server's own default, self + downstream, and the value
  /// under which a picked Location shows EVERY audit there — see
  /// audit.controller.js#whereWithScope). Me is an explicit `self`, which the
  /// server treats as a deliberate narrowing (only my audits at that place).
  String? get _employeeIdsParam {
    if (employeeFilter.isNotEmpty) return employeeFilter.join(',');
    if (teamFilter.isNotEmpty) {
      return teamMemberIds.isEmpty ? noneSentinel : teamMemberIds.join(',');
    }
    if (!isTeamScope && selfEmployeeId != null) return selfEmployeeId;
    return null;
  }

  /// The web's "nobody" sentinel — a Team with no members must match
  /// nothing, not fall back to everyone.
  static const noneSentinel = '__none__';

  /// Everything the audit endpoints need for the current filter state, or
  /// null when nothing at all should be sent.
  ///
  /// The employeeIds half deliberately sends NOTHING for All Members: an
  /// absent param is how the server is told "self + my whole downstream
  /// hierarchy" (resolveScopedEmployeeIds' own default). That also means an
  /// unknown [selfEmployeeId] while Me is selected silently widens to the
  /// full hierarchy — main.dart's _RootGate sets it on every authenticated
  /// build specifically so that can't happen; keep it that way if you add
  /// a new fetch entry point.
  Map<String, dynamic>? get filterParams {
    final params = <String, dynamic>{};
    final people = _employeeIdsParam;
    if (people != null) params['employeeIds'] = people;
    if (locationFilter.isNotEmpty) {
      params['locationIds'] = locationFilter.join(',');
    }
    if (departmentFilter.isNotEmpty) {
      params['departmentIds'] = departmentFilter.join(',');
    }
    if (auditTypeFilter.isNotEmpty) {
      params['auditType'] = auditTypeFilter.join(',');
    }
    if (dateFrom != null) params['fromDate'] = DateFormat(_fmt).format(dateFrom!);
    if (dateTo != null) params['toDate'] = DateFormat(_fmt).format(dateTo!);
    return params.isEmpty ? null : params;
  }

  /// [filterParams] plus what only the audit LIST honours (Include skipped).
  Map<String, dynamic>? get listFilterParams {
    final params = Map<String, dynamic>.from(filterParams ?? const {});
    if (includeSkipped) params['includeSkipped'] = 'true';
    return params.isEmpty ? null : params;
  }

  /// The NC lists' params: [filterParams] plus the flag (`severity`) pick.
  Map<String, dynamic>? get ncFilterParams {
    final params = Map<String, dynamic>.from(filterParams ?? const {});
    if (flagFilter.isNotEmpty) params['severity'] = flagFilter.join(',');
    return params.isEmpty ? null : params;
  }

  /// Whether [audit] passes the Status multi-select (any pick matches; none
  /// picked matches everything). A Skipped audit only arrives when
  /// [includeSkipped] asked the server for it, and is then shown under any
  /// status pick — it reads as its own thing, like the web's switch.
  bool matchesStatusFilter(AuditModel audit) {
    if (statusFilter.isEmpty) return true;
    if (includeSkipped && audit.status == 'Skipped') return true;
    return statusFilter.any((f) => auditMatchesStatusFilter(audit, f));
  }

  /// Whether a Status pick or Include skipped is narrowing the audit list.
  bool get hasStatusFilter => statusFilter.isNotEmpty || includeSkipped;

  bool get hasDateFilter => dateFrom != null || dateTo != null;

  /// Whether anything is narrowed beyond the plain Me default — drives the
  /// dot on the Filters button. Me alone is the resting state, so it does
  /// NOT count as an active filter; All Members (a deliberate widening) does.
  bool get hasActiveFilters => activeFilterCount > 0;

  /// How many distinct filters are narrowing the view — shown as a count
  /// badge next to "Filters".
  int get activeFilterCount => activeFilterCountFor();

  /// The same count for a screen that only offers some dimensions — a Status
  /// pick made on the Audits tab must not light the badge on the Dashboard
  /// (whose tiles ignore it) or a Flag pick on an audit screen.
  int activeFilterCountFor({
    bool status = true,
    bool date = true,
    bool flag = true,
  }) =>
      // Mirrors filterParams' own precedence: a specific-people pick WINS
      // over isTeamScope entirely (the flag is ignored once employeeFilter
      // is non-empty), so counting both here would let the badge read a
      // dimension the filter bar has already replaced with a people chip.
      (teamFilter.isNotEmpty ? 1 : 0) +
      (employeeFilter.isNotEmpty || (teamFilter.isEmpty && isTeamScope)
          ? 1
          : 0) +
      (locationFilter.isNotEmpty || departmentFilter.isNotEmpty ? 1 : 0) +
      (auditTypeFilter.isNotEmpty ? 1 : 0) +
      (date && hasDateFilter ? 1 : 0) +
      (status && statusFilter.isNotEmpty ? 1 : 0) +
      (status && includeSkipped ? 1 : 0) +
      (flag && flagFilter.isNotEmpty ? 1 : 0);

  /// Re-runs whatever this provider fetches under the current filters.
  /// Implemented per provider — DashboardProvider refetches its stat
  /// sources, AuditsProvider its audit lists.
  Future<void> refetchForFilters();

  /// Applies a whole filter set at once and refetches. Every argument is
  /// optional so a caller can move one dimension without restating the
  /// rest; pass an empty list to clear one. The dates are the exception
  /// (null can't mean both "leave" and "clear"): [dateRange] replaces both
  /// ends whenever it is passed, `(null, null)` clearing it.
  Future<void> applyFilters({
    bool? isTeam,
    List<String>? employees,
    List<String>? teams,
    List<String>? teamMembers,
    List<String>? locations,
    List<String>? departments,
    List<String>? auditTypes,
    (DateTime?, DateTime?)? dateRange,
    List<String>? statuses,
    bool? includeSkipped,
    List<String>? flags,
    List<String>? heldTeams,
    List<String>? heldEmployees,
  }) {
    setFilterState(
      isTeam: isTeam,
      employees: employees,
      teams: teams,
      teamMembers: teamMembers,
      heldTeams: heldTeams,
      heldEmployees: heldEmployees,
      locations: locations,
      departments: departments,
      auditTypes: auditTypes,
      dateRange: dateRange,
      statuses: statuses,
      includeSkipped: includeSkipped,
      flags: flags,
    );
    notifyListeners();
    return refetchForFilters();
  }

  /// Sets just the Status pick and notifies — no refetch, because Status is
  /// matched over the already-loaded audit list ([matchesStatusFilter]).
  void setStatusFilter(List<String> statuses) {
    setFilterState(statuses: statuses);
    notifyListeners();
  }

  /// The same assignment as [applyFilters] without the notify/refetch — for
  /// a caller that batches several providers and refetches itself.
  void setFilterState({
    bool? isTeam,
    List<String>? employees,
    List<String>? teams,
    List<String>? teamMembers,
    List<String>? locations,
    List<String>? departments,
    List<String>? auditTypes,
    (DateTime?, DateTime?)? dateRange,
    List<String>? statuses,
    bool? includeSkipped,
    List<String>? flags,
    List<String>? heldTeams,
    List<String>? heldEmployees,
  }) {
    if (isTeam != null) isTeamScope = isTeam;
    if (heldTeams != null) heldTeamFilter = List.unmodifiable(heldTeams);
    if (heldEmployees != null) heldEmployeeFilter = List.unmodifiable(heldEmployees);
    if (employees != null) employeeFilter = List.unmodifiable(employees);
    if (teams != null) teamFilter = List.unmodifiable(teams);
    if (teamMembers != null) teamMemberIds = List.unmodifiable(teamMembers);
    if (locations != null) locationFilter = List.unmodifiable(locations);
    if (departments != null) departmentFilter = List.unmodifiable(departments);
    if (auditTypes != null) auditTypeFilter = List.unmodifiable(auditTypes);
    if (dateRange != null) {
      dateFrom = dateRange.$1;
      dateTo = dateRange.$2;
    }
    if (statuses != null) statusFilter = List.unmodifiable(statuses);
    if (includeSkipped != null) this.includeSkipped = includeSkipped;
    if (flags != null) flagFilter = List.unmodifiable(flags);
  }

  /// Back to the resting state: just me, everywhere, every type, any date.
  Future<void> clearFilters() => applyFilters(
    isTeam: false,
    employees: const [],
    teams: const [],
    teamMembers: const [],
    heldTeams: const [],
    heldEmployees: const [],
    locations: const [],
    departments: const [],
    auditTypes: const [],
    dateRange: (null, null),
    statuses: const [],
    includeSkipped: false,
    flags: const [],
  );

  /// Wipes the filter state WITHOUT refetching — call on logout, not on a
  /// screen the user is actively looking at (unlike [clearFilters], which
  /// deliberately refetches so a visible list updates to match).
  ///
  /// Every provider in this app is created once, in main.dart's root
  /// MultiProvider, and lives for the whole process — logging out does
  /// NOT recreate AuditsProvider/DashboardProvider, it just swaps
  /// AuthProvider's own state back to unauthenticated. Without this, a
  /// person who picks specific colleagues on a shared device, then logs
  /// out, hands the NEXT person who logs in on that same device a filter
  /// still narrowed to the previous account's colleagues — ids that mean
  /// nothing (or, worse, resolve to someone ELSE's reports) under the new
  /// login. `isTeamScope` also goes back to its Me default explicitly
  /// (not left at whatever the previous account had it set to), matching
  /// what a fresh install would show. Deliberately doesn't touch
  /// [selfEmployeeId] — main.dart's _RootGate always calls
  /// setSelfEmployeeId with the NEWLY authenticated user's own id before
  /// any fetch can run, so the stale value can never actually be read.
  void resetForLogout() {
    isTeamScope = false;
    setFilterState(
      employees: const [],
      teams: const [],
      teamMembers: const [],
      heldTeams: const [],
      heldEmployees: const [],
      locations: const [],
      departments: const [],
      auditTypes: const [],
      dateRange: (null, null),
      statuses: const [],
      includeSkipped: false,
      flags: const [],
    );
    notifyListeners();
  }
}
