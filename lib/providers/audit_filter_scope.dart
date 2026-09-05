import 'package:flutter/foundation.dart';

/// The filter state shared by every audit-scoped list/stat fetch on the
/// phone — who (employees), where (locations), and what kind (audit type).
///
/// Mixed into AuditsProvider and DashboardProvider rather than living in a
/// provider of its own, because each of those already owns the fetches the
/// filters have to re-run: a single shared filter object would still have
/// to reach back into both to refetch, and the two would have to stay
/// subscribed to it. This way `filterParams` is right next to the `_dio.get`
/// that spends it. The filter SHEET (widgets/filter_sheet.dart) is what
/// keeps the two providers' copies in step, exactly as ScopeToggle already
/// does for `isTeamScope`.
///
/// Every param here is understood by the server already — see
/// audit.controller.js's `resolveScopedEmployeeIds` (employeeIds),
/// `locationFilter` (locationIds, comma-separated) and `auditTypeFilter`
/// (auditType, comma-separated by NAME, since Audit.auditType stores the
/// name rather than a ref).
mixin AuditFilterScope on ChangeNotifier {
  /// "Me" vs "Team" — the coarse toggle (widgets/scope_toggle.dart) that
  /// most users never move off. Defaults to Me; see the implementing
  /// provider's own field comment.
  bool get isTeamScope;
  set isTeamScope(bool value);

  String? get selfEmployeeId;

  /// A precise pick of people from the employee filter. Non-empty always
  /// WINS over [isTeamScope] — picking specific people is a more specific
  /// statement than either end of the Me/Team switch, and the sheet shows
  /// the two as one control anyway.
  List<String> employeeFilter = const [];

  /// Location ids to narrow to. Empty means every location this user can
  /// see (no param sent at all).
  List<String> locationFilter = const [];

  /// Audit type NAMES to narrow to (not ids — see the class doc above).
  List<String> auditTypeFilter = const [];

  /// Everything the audit endpoints need for the current filter state, or
  /// null when nothing at all should be sent.
  ///
  /// The employeeIds half deliberately sends NOTHING for Team scope: an
  /// absent param is how the server is told "self + my whole downstream
  /// hierarchy" (resolveScopedEmployeeIds' own default). That also means an
  /// unknown [selfEmployeeId] while Me is selected silently widens to the
  /// full hierarchy — main.dart's _RootGate sets it on every authenticated
  /// build specifically so that can't happen; keep it that way if you add
  /// a new fetch entry point.
  Map<String, dynamic>? get filterParams {
    final params = <String, dynamic>{};
    if (employeeFilter.isNotEmpty) {
      params['employeeIds'] = employeeFilter.join(',');
    } else if (!isTeamScope && selfEmployeeId != null) {
      params['employeeIds'] = selfEmployeeId;
    }
    if (locationFilter.isNotEmpty) {
      params['locationIds'] = locationFilter.join(',');
    }
    if (auditTypeFilter.isNotEmpty) {
      params['auditType'] = auditTypeFilter.join(',');
    }
    return params.isEmpty ? null : params;
  }

  /// Whether anything is narrowed beyond the plain Me default — drives the
  /// dot on the Filters button. Me alone is the resting state, so it does
  /// NOT count as an active filter; Team (a deliberate widening) does.
  bool get hasActiveFilters =>
      isTeamScope ||
      employeeFilter.isNotEmpty ||
      locationFilter.isNotEmpty ||
      auditTypeFilter.isNotEmpty;

  /// How many distinct filters are narrowing the view — shown as a count
  /// badge next to "Filters".
  int get activeFilterCount =>
      // Mirrors filterParams' own precedence: a specific-people pick WINS
      // over isTeamScope entirely (the flag is ignored once employeeFilter
      // is non-empty), so counting both here would let the badge read a
      // dimension the filter bar has already replaced with a people chip —
      // e.g. "My team" left on, then two colleagues hand-picked, would
      // count as 2 even though exactly one thing (the two people) is
      // actually narrowing the request.
      (employeeFilter.isNotEmpty ? 1 : (isTeamScope ? 1 : 0)) +
      (locationFilter.isNotEmpty ? 1 : 0) +
      (auditTypeFilter.isNotEmpty ? 1 : 0);

  /// Re-runs whatever this provider fetches under the current filters.
  /// Implemented per provider — DashboardProvider refetches its stat
  /// sources, AuditsProvider its audit lists.
  Future<void> refetchForFilters();

  /// Applies a whole filter set at once and refetches. Every argument is
  /// optional so a caller can move one dimension without restating the
  /// rest; pass an empty list to clear one.
  Future<void> applyFilters({
    bool? isTeam,
    List<String>? employees,
    List<String>? locations,
    List<String>? auditTypes,
  }) {
    if (isTeam != null) isTeamScope = isTeam;
    if (employees != null) employeeFilter = List.unmodifiable(employees);
    if (locations != null) locationFilter = List.unmodifiable(locations);
    if (auditTypes != null) auditTypeFilter = List.unmodifiable(auditTypes);
    notifyListeners();
    return refetchForFilters();
  }

  /// Back to the resting state: just me, everywhere, every type.
  Future<void> clearFilters() => applyFilters(
    isTeam: false,
    employees: const [],
    locations: const [],
    auditTypes: const [],
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
    employeeFilter = const [];
    locationFilter = const [];
    auditTypeFilter = const [];
    notifyListeners();
  }
}
