import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../models/audit_type_option.dart';
import '../models/employee_option.dart';
import '../models/location_option.dart';

/// The option lists the filter sheet offers — people, locations, audit
/// types. Purely the CHOICES; what is actually selected lives on
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

  bool isLoading = false;
  bool _loaded = false;
  Future<void>? _inFlight;

  /// Back to unloaded — call on logout. This provider is a single,
  /// process-lifetime instance (main.dart's root MultiProvider), so
  /// without this the NEXT person to log in on the same device would open
  /// the filter sheet to the PREVIOUS account's whole reporting line and
  /// locations (this cache never expires or re-checks on its own — see
  /// `load`'s own `_loaded` short-circuit) until they happened to force a
  /// reload some other way. Safe mid-frame: only flips plain fields and
  /// notifies, nothing async.
  void resetForLogout() {
    _loaded = false;
    employees = [];
    locations = [];
    auditTypes = [];
    notifyListeners();
  }

  Future<void> load({bool force = false}) {
    if (_loaded && !force) return Future.value();
    // Two screens opening the sheet in quick succession (or a rebuild
    // mid-fetch) must not fire three parallel copies of the same three
    // GETs — hand every caller the same future.
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    isLoading = true;
    notifyListeners();
    // Each fetch fails independently and quietly: one unavailable list
    // should leave the other two filters fully usable rather than
    // collapsing the whole sheet into an error state. A section with no
    // options renders its own "nothing to pick from" line instead.
    await Future.wait([
      _fetchEmployees(),
      _fetchLocations(),
      _fetchAuditTypes(),
    ]);
    _loaded = true;
    isLoading = false;
    notifyListeners();
  }

  Future<void> _fetchEmployees() async {
    try {
      final res = await _dio.get(ApiConstants.myHierarchyScope);
      employees = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => EmployeeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    } on DioException {
      // Fail quiet — the Me/Team toggle still works without the per-person list.
    }
  }

  Future<void> _fetchLocations() async {
    try {
      final res = await _dio.get(ApiConstants.myLocationScope);
      locations = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LocationOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException {
      // Fail quiet.
    }
  }

  Future<void> _fetchAuditTypes() async {
    try {
      final res = await _dio.get(ApiConstants.auditTypes);
      auditTypes = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditTypeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException {
      // Fail quiet.
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
}
