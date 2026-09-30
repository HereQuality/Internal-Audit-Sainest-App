import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../models/audit_type_option.dart';
import '../models/department_option.dart';
import '../models/employee_option.dart';
import '../models/location_option.dart';

/// A team in the Team filter: id (what is compared), name, and how many people
/// of the directory belong to it.
class TeamOption {
  final String id;
  final String name;
  final int count;

  const TeamOption({required this.id, required this.name, required this.count});
}

/// The option lists the filter sheet offers — people, teams, locations,
/// departments, audit types. Purely the CHOICES; what is actually selected lives on
/// AuditsProvider/DashboardProvider (see AuditFilterScope), because that
/// is where the fetches those selections change already live.
///
/// Fetched once and cached for the session: all three are small,
/// slow-moving admin-managed lists, and the sheet has to open instantly.
/// [load] is safe to call on every sheet open — it no-ops once loaded and
/// coalesces concurrent callers onto one in-flight request.
class FilterOptionsProvider extends ChangeNotifier {
  final Dio _dio = DioClient.instance.dio;

  List<EmployeeOption> employees = [];
  List<LocationOption> locations = [];
  List<AuditTypeOption> auditTypes = [];
  List<DepartmentOption> departments = [];

  /// { locationId: [departmentId, ...] } — which departments exist at which
  /// location, so picking locations narrows the Department section.
  Map<String, List<String>> departmentsByLocation = {};

  /// A Full Access role / SuperAdmin sees every place (meta.fullAccess).
  bool fullAccess = false;

  /// Per-list failure flags — the sheet shows "Couldn't load … Retry" for a
  /// list that failed instead of a misleading "nothing to pick from".
  bool employeesFailed = false;
  bool locationsFailed = false;
  bool auditTypesFailed = false;

  bool isLoading = false;
  bool _loaded = false;
  Future<void>? _inFlight;

  // Bumped on logout: a load already on the wire for the previous account
  // drops its answer when it lands (it must not fill the next account's
  // people/locations), and is never handed to a later caller as `_inFlight`.
  int _epoch = 0;

  /// Back to unloaded — call on logout. This provider is a single,
  /// process-lifetime instance (main.dart's root MultiProvider), so
  /// without this the NEXT person to log in on the same device would open
  /// the filter sheet to the PREVIOUS account's whole reporting line and
  /// locations (this cache never expires or re-checks on its own — see
  /// `load`'s own `_loaded` short-circuit) until they happened to force a
  /// reload some other way. Safe mid-frame: only flips plain fields and
  /// notifies, nothing async.
  void resetForLogout() {
    _epoch++;
    _inFlight = null;
    isLoading = false;
    _loaded = false;
    employees = [];
    locations = [];
    auditTypes = [];
    departments = [];
    departmentsByLocation = {};
    fullAccess = false;
    employeesFailed = locationsFailed = auditTypesFailed = false;
    notifyListeners();
  }

  /// True when any list failed to load — the sheet's cue to offer Retry.
  bool get anyFailed => employeesFailed || locationsFailed || auditTypesFailed;

  Future<void> load({bool force = false}) {
    // A previous failure is retried on the next open rather than cached for
    // the whole session.
    if (_loaded && !force && !anyFailed) return Future.value();
    // Two screens opening the sheet in quick succession (or a rebuild
    // mid-fetch) must not fire three parallel copies of the same three
    // GETs — hand every caller the same future.
    final running = _inFlight;
    if (running != null) return running;
    late final Future<void> run;
    run = _load().whenComplete(() {
      if (identical(_inFlight, run)) _inFlight = null;
    });
    return _inFlight = run;
  }

  Future<void> _load() async {
    final epoch = _epoch;
    isLoading = true;
    notifyListeners();
    // Each fetch fails independently and quietly: one unavailable list
    // should leave the other two filters fully usable rather than
    // collapsing the whole sheet into an error state. A section with no
    // options renders its own "nothing to pick from" line instead.
    await Future.wait([
      _fetchEmployees(epoch),
      _fetchLocations(epoch),
      _fetchAuditTypes(epoch),
    ]);
    if (epoch != _epoch) return;
    _loaded = true;
    isLoading = false;
    notifyListeners();
  }

  Future<void> _fetchEmployees(int epoch) async {
    try {
      final res = await _dio.get(
        ApiConstants.myHierarchyScope,
        // Deactivated people keep their audits/NCs on record, so their team
        // must stay pickable — the web's directory does the same.
        queryParameters: {'includeInactive': 'true'},
      );
      if (epoch != _epoch) return;
      employeesFailed = false;
      employees = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => EmployeeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } catch (_) {
      // Fail quiet — the Me/All Members toggle still works without the
      // per-person list; the sheet offers Retry. Any error, not just a
      // DioException: an unreadable answer must end the load too.
      if (epoch == _epoch) employeesFailed = true;
    }
  }

  Future<void> _fetchLocations(int epoch) async {
    try {
      final res = await _dio.get(ApiConstants.myLocationScope);
      if (epoch != _epoch) return;
      locations = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LocationOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      departments = (res.data['departments'] as List? ?? [])
          .whereType<Map>()
          .map((e) => DepartmentOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final byLocation = res.data['departmentsByLocation'];
      departmentsByLocation = byLocation is Map
          ? {
              for (final e in byLocation.entries)
                e.key.toString(): [
                  for (final d in (e.value as List? ?? [])) d.toString(),
                ],
            }
          : {};
      final meta = res.data['meta'];
      fullAccess = meta is Map && meta['fullAccess'] == true;
      locationsFailed = false;
    } catch (_) {
      if (epoch == _epoch) locationsFailed = true;
    }
  }

  Future<void> _fetchAuditTypes(int epoch) async {
    try {
      final res = await _dio.get(ApiConstants.auditTypes);
      if (epoch != _epoch) return;
      auditTypes = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditTypeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      auditTypesFailed = false;
    } catch (_) {
      if (epoch == _epoch) auditTypesFailed = true;
    }
  }

  /// The people pickable given the locations currently selected — an
  /// employee filter should only ever offer people who are actually
  /// stationed where you are looking. An empty [locationIds] means no
  /// narrowing (everyone in the hierarchy).
  ///
  /// Employees with no location on their record are kept either way: they
  /// are not "somewhere else", they are unassigned, and dropping them
  /// would silently make them unpickable the moment any location filter is
  /// on — including, for a lot of orgs, the manager doing the filtering.
  List<EmployeeOption> employeesAt(List<String> locationIds) {
    if (locationIds.isEmpty) return employees;
    final wanted = locationIds.toSet();
    return employees
        .where((e) =>
            e.locationIds.isEmpty || e.locationIds.any(wanted.contains))
        .toList();
  }

  /// The teams present in the hierarchy directory, by name, with headcounts
  /// (deactivated people included — picking the team scopes to all of them).
  List<TeamOption> get teams => teamsOf(employees);

  /// The teams of just [people], by name, with the headcount WITHIN [people] —
  /// the Team list once a picked place has narrowed the people
  /// (core/utils/place_cascade.dart#WhoCascade.pool): only the teams of the
  /// people who belong to the place, counted over those people.
  List<TeamOption> teamsOf(Iterable<EmployeeOption> people) {
    final byId = <String, TeamOption>{};
    for (final e in people) {
      for (final t in e.teams) {
        final prev = byId[t.id];
        byId[t.id] = TeamOption(
          id: t.id,
          name: t.name,
          count: (prev?.count ?? 0) + 1,
        );
      }
    }
    return byId.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  /// Everyone in the directory who belongs to at least one of [teamIds]
  /// (empty = no team narrowing = the whole directory) — Members cascades
  /// from Team like on the web (utils/scope.js#membersOfTeams).
  List<EmployeeOption> membersOfTeams(List<String> teamIds) {
    if (teamIds.isEmpty) return employees;
    final wanted = teamIds.toSet();
    return employees
        .where((e) => e.teams.any((t) => wanted.contains(t.id)))
        .toList();
  }
}
