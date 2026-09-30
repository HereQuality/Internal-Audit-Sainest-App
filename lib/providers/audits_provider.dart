import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/audit_detail_model.dart';
import '../models/audit_model.dart';
import '../models/employee_option.dart';
import '../models/location_option.dart';
import '../models/upload_phase.dart';
import '../core/utils/report_stats.dart';
import 'audit_filter_scope.dart';

class AuditsProvider extends ChangeNotifier with AuditFilterScope {
  final Dio _dio = DioClient.instance.dio;

  // "Me" vs "Team" scope for fetchMyAudits below — shared by
  // DashboardScreen's mini audit sections and MyAuditsScreen's full list
  // (both read this same `audits` field), so toggling on either screen
  // keeps the other in sync instead of the two drifting apart. See
  // widgets/scope_toggle.dart / DashboardProvider's identical pattern.
  // Defaults FALSE (Me) — an auditor opening the app on a phone is asking
  // "what do I have to do", not "what does my whole reporting line have to
  // do"; Team is the opt-in widening from there, one tap away. This
  // deliberately no longer mirrors the web TeamFilterPanel's own "All"
  // default: the two surfaces answer different questions.
  @override
  bool isTeamScope = false;
  String? _selfEmployeeId;
  @override
  String? get selfEmployeeId => _selfEmployeeId;
  // NOTE the asymmetry below: an unknown _selfEmployeeId falls back to
  // sending no param at all, which the server reads as the FULL hierarchy
  // — i.e. a silently WIDER scope than the "Me" showing as selected.
  // Harmless while Team was the default; not harmless now. main.dart's
  // _RootGate sets this on every authenticated build, before any screen's
  // first fetch, so the fallback is unreachable in practice — keep it that
  // way if you add a new fetch entry point (background isolate, deep link).
  void setSelfEmployeeId(String id) {
    _selfEmployeeId = id;
  }

  Future<void> setTeamScope(bool isTeam) {
    isTeamScope = isTeam;
    notifyListeners();
    return refetchForFilters();
  }

  /// Both audit lists respond to the filters: `audits` is what the Audits
  /// tab, the dashboard's "what needs attention" sections and the
  /// calendar's amber/green markers all read, and `auditsAtMyLocation` is
  /// the calendar's blue "someone is auditing your location" layer — a
  /// location/audit-type filter that skipped the second one would visibly
  /// only half-apply on the calendar.
  @override
  Future<void> refetchForFilters() => Future.wait([
    fetchMyAudits(),
    fetchAuditsAtMyLocation(),
    // The Final Report is open: its list and tiles follow the filters too.
    if (reportsInUse) fetchReportAudits(),
    if (reportsInUse) fetchReportStats(),
    // The leader's "My locations" list is showing: same filters, same reload.
    if (ledAuditsInUse) fetchLedAudits(),
  ]);

  bool isLoading = false;
  String? errorMessage;
  List<AuditModel> audits = [];

  /// [audits] under the Status multi-select (the other filters are applied
  /// server-side; Status is matched here over the loaded list, like the
  /// existing chips always were — see AuditFilterScope.matchesStatusFilter).
  List<AuditModel> get visibleAudits =>
      statusFilter.isEmpty ? audits : audits.where(matchesStatusFilter).toList();

  bool isLoadingDetail = false;
  String? detailError;
  AuditDetailModel? activeAudit;

  List<EmployeeOption> auditeeCandidates = [];
  List<LocationOption> allLocations = [];

  // Bumped on logout — see resetForLogout. Every fetch below remembers the
  // value it started under and, once it has changed, neither writes its
  // answer, nor its error, nor flips its loading flag: all of that belongs to
  // the account that left, and the next one may already have a request of its
  // own on the wire.
  int _epoch = 0;

  // Per-call sequence numbers, one per fetch: two quick filter changes (or a
  // save's refetch racing a socket refetch) put two requests on the wire and
  // the older answer may land last — only the newest call of each fetch may
  // write its result, its error or its loading flag.
  int _myAuditsSeq = 0;
  int _detailSeq = 0;
  int _reportAuditsSeq = 0;
  int _reportStatsSeq = 0;
  int _atMyLocationSeq = 0;

  /// Empties every list and the open audit, and puts the filters back to
  /// their defaults — call on logout, without refetching. Every list here is
  /// the previous account's audits (titles, locations, people); a shared
  /// phone's next login must not show them while its own fetch is in flight,
  /// and a fetch that was already on the wire for the previous account drops
  /// its answer ([_epoch]). The self id goes too: a SuperAdmin never gets one
  /// set (main.dart's _RootGate), so it would otherwise keep filtering by the
  /// previous employee.
  @override
  void resetForLogout() {
    stopListening();
    _epoch++;
    _selfEmployeeId = null;
    audits = [];
    auditsAtMyLocation = [];
    reportAudits = [];
    ledReportAudits = [];
    ledLocationIds = const [];
    ledDepartmentIds = const [];
    ledPlaceNames = const [];
    ledAudits = [];
    ledAuditsInUse = false;
    ledAuditsError = null;
    isLoadingLedAudits = false;
    reportsInUse = false;
    reportsLed = false;
    reportsStatus = null;
    reportsSearch = '';
    reportStats = null;
    isLoadingReportStats = false;
    activeAudit = null;
    auditeeCandidates = [];
    allLocations = [];
    errorMessage = null;
    detailError = null;
    reportsError = null;
    isLoading = false;
    isLoadingDetail = false;
    isLoadingReports = false;
    isLoadingAtMyLocation = false;
    super.resetForLogout();
  }

  bool _listening = false;
  // Stored so stopListening removes exactly this closure — Notifications
  // Provider and NcProvider also register their own 'new_notification'
  // handler, and socket_io_client's off(event) with no handler removes
  // EVERY listener for that event, not just the caller's own.
  void Function(dynamic data)? _onNewNotification;

  /// Wires a socket listener once, after login — mirrors
  /// NotificationsProvider.startListening(). Any `audit_*` event (currently
  /// just reassignment) refetches the list, and the open detail workspace
  /// too if there is one, so both reflect the change live without a manual
  /// pull-to-refresh/reload.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map &&
          (data['type']?.toString() ?? '').startsWith('audit_')) {
        // A burst of notifications refetches once, not once each.
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 500), () {
          fetchMyAudits();
          // A reassignment (by this leader elsewhere, a scheduler, ...) changes
          // who is on the audits at their places.
          if (ledAuditsInUse) fetchLedAudits(quiet: true);
          if (activeAudit != null) {
            fetchAuditDetail(activeAudit!.id, quiet: true);
          }
        });
      }
    };
    SocketService.instance.on('new_notification', _onNewNotification!);
  }

  Timer? _refreshTimer;

  void stopListening() {
    _refreshTimer?.cancel();
    _listening = false;
    if (_onNewNotification != null) {
      SocketService.instance.off('new_notification', _onNewNotification);
      _onNewNotification = null;
    }
  }

  /// Who's actually assigned to the given Locations — powers both the
  /// "select representative auditee" picker and the "raise NC against"
  /// picker (checkpoint_card.dart, nc_details_sheet.dart, select_representative
  /// _sheet.dart), same pool the web app's equivalent picker offers.
  /// Deliberately NOT scoped by the logged-in auditor's own manager-
  /// hierarchy (who reports to whom) or by audit type — an auditee is
  /// whoever is actually at the zone being audited, full stop. Call once
  /// the active audit's own location ids are known (see audit_detail_
  /// screen.dart's _load) and again any time that scope changes (e.g. an
  /// Instant Audit's tagged locations). Fully replaces the previous list
  /// rather than merging into it, so a location dropped from scope also
  /// drops its members here, not just adds new ones as locations are
  /// tagged.
  ///
  /// [departmentIds] is the same lookup for a department-scoped (Cross
  /// Functional Team) audit, which is saved with an EMPTY locationIds — with
  /// only locations passed such an audit had nobody to pick from and the
  /// representative step silently never appeared. Returns false when the
  /// request failed (the list is then cleared, never left showing the
  /// previous audit's people), so a caller can say so instead of showing an
  /// empty picker.
  Future<bool> fetchLocationEmployees(
    List<String> locationIds, {
    List<String> departmentIds = const [],
  }) async {
    if (locationIds.isEmpty && departmentIds.isEmpty) {
      auditeeCandidates = [];
      notifyListeners();
      return true;
    }
    final epoch = _epoch;
    final request = ++_candidatesRequest;
    try {
      final res = await _dio.get(
        ApiConstants.employeesByLocation(
          locationIds,
          departmentIds: departmentIds,
        ),
      );
      // Logged out, or a newer lookup (another audit / a re-tag) started
      // meanwhile — its answer is the one that counts.
      if (epoch != _epoch || request != _candidatesRequest) return true;
      auditeeCandidates = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => EmployeeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
      return true;
    } on DioException {
      if (epoch != _epoch || request != _candidatesRequest) return true;
      auditeeCandidates = [];
      notifyListeners();
      return false;
    }
  }

  int _candidatesRequest = 0;

  // ── Instant Audit builder (screens/audits/audit_detail_screen.dart's
  // "set up" section) — mirrors the web app's InstantAudit.jsx for the
  // "same" (one shared checklist) case, and extends it with the
  // "per-location" (a separate checklist per tagged location) case the
  // rest of the app already supports for normal audits, since web's own
  // Instant Audit flow doesn't offer that choice at all. Everything is
  // saved via the same PATCH /audits/:id/save-draft, only ever usable
  // while the audit is still "Draft" — which an Instant Audit always is.

  Future<void> fetchAllLocations() async {
    final epoch = _epoch;
    try {
      final res = await _dio.get(ApiConstants.locations);
      if (epoch != _epoch) return;
      allLocations = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LocationOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    } on DioException {
      // Fail quiet — worst case the picker has nothing to add from yet.
    }
  }

  /// Full replace of the audit's location scope tags — add/remove a
  /// location by sending the next complete list, same as
  /// InstantAudit.jsx#handleScopeChange. If already in "per-location" mode,
  /// also syncs locationParameters to match: a newly-tagged location gets
  /// an empty checklist of its own, a removed one's checklist is dropped
  /// with it — otherwise locationIds and locationParameters would silently
  /// drift apart. Refetches the audit afterward.
  Future<String?> updateInstantAuditScope(
    String auditId,
    List<String> locationIds,
  ) async {
    final audit = activeAudit;
    final body = <String, dynamic>{'locationIds': locationIds};
    if (audit != null && audit.structureMode == 'per-location') {
      final existing = {
        for (final g in audit.locationParameters) g.locationId: g,
      };
      body['locationParameters'] = locationIds
          .map(
            (id) =>
                existing[id]?.toJson() ?? {'locationId': id, 'parameters': []},
          )
          .toList();
    }
    try {
      await _dio.patch(ApiConstants.saveAuditDraft(auditId), data: body);
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not update the audit\'s location.',
      );
    }
  }

  /// Switches between one shared checklist and a separate checklist per
  /// tagged location. Switching TO "per-location" seeds one empty group
  /// per currently-tagged location (preserving any that already exist,
  /// e.g. from a previous switch back and forth) — the flat `parameters`
  /// checklist built so far is left as-is server-side but no longer shown
  /// (screens/audits/audit_detail_screen.dart reads locationParameters
  /// once structureMode is "per-location"), not deleted, so switching back
  /// to "same" recovers it.
  Future<String?> setInstantAuditStructureMode(
    String auditId,
    String mode,
  ) async {
    final audit = activeAudit;
    final body = <String, dynamic>{'structureMode': mode};
    if (mode == 'per-location' && audit != null) {
      final existing = {
        for (final g in audit.locationParameters) g.locationId: g,
      };
      body['locationParameters'] = audit.locationLabels
          .map(
            (l) =>
                existing[l.id]?.toJson() ??
                {'locationId': l.id, 'parameters': []},
          )
          .toList();
    }
    try {
      await _dio.patch(ApiConstants.saveAuditDraft(auditId), data: body);
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not change the checklist mode.',
      );
    }
  }

  /// Appends one flat leaf checkpoint {name, weight: null, children: []}
  /// — to the audit's shared `parameters` when `locationId` is omitted, or
  /// to just that one location's own checklist when given (structureMode
  /// "per-location"). Must serialize every existing node's current state
  /// via ParameterNode.toJson() first (see that method's doc comment for
  /// why: save-draft replaces the whole field, so sending anything less
  /// would wipe out every checkpoint already scored — same reasoning
  /// applies per-location via LocationParameterGroup.toJson()).
  Future<String?> addInstantCheckpoint(
    String auditId,
    String name, {
    String? locationId,
  }) async {
    final newLeaf = {'name': name, 'weight': null, 'children': []};
    final body = locationId == null
        ? {
            'structureMode': 'same',
            'parameters': [
              ...(activeAudit?.parameters ?? const []).map((n) => n.toJson()),
              newLeaf,
            ],
          }
        : {
            'structureMode': 'per-location',
            'locationParameters': (activeAudit?.locationParameters ?? const [])
                .map(
                  (g) => g.locationId == locationId
                      ? {
                          'locationId': g.locationId,
                          'parameters': [
                            ...g.parameters.map((n) => n.toJson()),
                            newLeaf,
                          ],
                        }
                      : g.toJson(),
                )
                .toList(),
          };
    try {
      await _dio.patch(ApiConstants.saveAuditDraft(auditId), data: body);
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not add the checkpoint.');
    }
  }

  /// Removes one not-yet-scored checkpoint — same "added by mistake"
  /// escape hatch InstantAudit.jsx offers, only ever for a leaf with no
  /// findingType yet (checked by the caller). Same same-vs-per-location
  /// branching as addInstantCheckpoint above.
  Future<String?> removeInstantCheckpoint(
    String auditId,
    String nodeId, {
    String? locationId,
  }) async {
    final body = locationId == null
        ? {
            'structureMode': 'same',
            'parameters': (activeAudit?.parameters ?? const [])
                .where((n) => n.id != nodeId)
                .map((n) => n.toJson())
                .toList(),
          }
        : {
            'structureMode': 'per-location',
            'locationParameters': (activeAudit?.locationParameters ?? const [])
                .map(
                  (g) => g.locationId == locationId
                      ? {
                          'locationId': g.locationId,
                          'parameters': g.parameters
                              .where((n) => n.id != nodeId)
                              .map((n) => n.toJson())
                              .toList(),
                        }
                      : g.toJson(),
                )
                .toList(),
          };
    try {
      await _dio.patch(ApiConstants.saveAuditDraft(auditId), data: body);
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not remove the checkpoint.',
      );
    }
  }

  Future<void> fetchMyAudits() async {
    final epoch = _epoch;
    final seq = ++_myAuditsSeq;
    bool stale() => epoch != _epoch || seq != _myAuditsSeq;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.myAudits,
        // + Include skipped (list-only) — see AuditFilterScope.listFilterParams.
        queryParameters: listFilterParams,
      );
      if (stale()) return;
      final list = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      audits = list;
    } on DioException catch (e) {
      if (!stale()) {
        errorMessage = extractErrorMessage(
          e,
          fallback: 'Could not load your audits.',
        );
      }
    } finally {
      if (!stale()) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  // ── Audit detail / scoring workspace ──────────────────────────────────
  // Same GET /audits/:id the web app's AuditReportDetail.jsx reads —
  // full parameter tree, assignments, ncs. Access is enforced server-side
  // (SuperAdmin, this audit's own auditors/auditee/planner, or their
  // hierarchy scope), not by anything client-side.
  // [quiet] is for refreshing the audit that is already open (after a save,
  // on a socket event): no loading flag, and one notify when the answer
  // lands instead of two.
  Future<void> fetchAuditDetail(String auditId, {bool quiet = false}) async {
    final epoch = _epoch;
    final seq = ++_detailSeq;
    bool stale() => epoch != _epoch || seq != _detailSeq;
    if (!quiet) {
      isLoadingDetail = true;
      detailError = null;
      notifyListeners();
    }
    try {
      final res = await _dio.get(ApiConstants.auditById(auditId));
      if (stale()) return;
      activeAudit = AuditDetailModel.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      if (!stale()) {
        detailError = extractErrorMessage(
          e,
          fallback: 'Could not load this audit.',
        );
      }
    } finally {
      if (!stale()) {
        isLoadingDetail = false;
        notifyListeners();
      }
    }
  }

  void clearActiveAudit() {
    activeAudit = null;
    detailError = null;
  }

  /// Same clear as above, plus flags a fresh load in flight — call from a
  /// NEW AuditDetailScreen's initState (not dispose, which already uses
  /// clearActiveAudit alone) so that screen's very first build already
  /// shows the loading spinner, never the previous audit it's replacing
  /// (activeAudit is a singleton field here, shared across every visit —
  /// Navigator.pop()'s transition keeps the outgoing screen, and so its
  /// own dispose()/clear, mounted until the pop animation finishes, which
  /// a fast-enough next tap can race) or a misleading "Audit not found"
  /// (isLoadingDetail would otherwise still read false on that very first
  /// frame, before fetchAuditDetail's own request even starts). Not
  /// folded into fetchAuditDetail itself — that's also how the CURRENTLY
  /// open audit refetches after every save, where flashing back to
  /// "loading" on every checkpoint autosave would be its own regression.
  void beginActiveAuditReload() {
    activeAudit = null;
    detailError = null;
    isLoadingDetail = true;
  }

  // ── Reports (Profile → Reports, titled "Final Report") ────────────────
  // Two views, like the web's My audits / Audits at places I lead switch:
  //  * "My audits" — GET /audits/mine under the SHARED filters (Team,
  //    Members, Location + Department, Audit Type, Date range). The default
  //    scope is Me, so a plain visit lists only this auditor's own audits;
  //    All Members widens it, and Me + a Location is only my audits there
  //    while All Members + a Location is every audit at that location (for
  //    places I belong to or lead) — all decided server-side
  //    (audit.controller.js#whereWithScope), so this just sends the params.
  //  * "My locations" (only for a leader — [ledPlaceIds] non-empty) — GET
  //    /audits/at-places-i-lead: every audit at a place I lead, whoever the
  //    auditor is. That endpoint deliberately ignores employeeIds.
  // ReportsScreen narrows either list client-side via status chips + search,
  // the same "fetch once, filter locally" pattern MyAuditsScreen uses.
  bool isLoadingReports = false;
  String? reportsError;
  List<AuditModel> reportAudits = [];

  /// Audits at the places this employee leads (empty for a non-leader).
  List<AuditModel> ledReportAudits = [];

  /// What this employee leads, from GET /audits/led-places: location ids,
  /// department ids and display names. Empty = not a leader, which is how the
  /// Final Report decides whether to offer its "My locations" view at all.
  List<String> ledLocationIds = const [];
  List<String> ledDepartmentIds = const [];
  List<String> ledPlaceNames = const [];
  bool get isPlaceLeader =>
      ledLocationIds.isNotEmpty || ledDepartmentIds.isNotEmpty;

  /// The four Final Report tiles for what is in view — the server's, or null
  /// until loaded / when the endpoint isn't open to this role (the screen then
  /// works them out from the rows on screen, see ReportStats.fromAudits).
  ReportStats? reportStats;
  bool isLoadingReportStats = false;

  /// What the Final Report screen currently asks for, kept here so a FILTER
  /// change (which reaches this provider through refetchForFilters) reloads
  /// the report lists and tiles too: the screen registers itself while it is
  /// open ([reportsInUse]), and says which view / status chip / search text
  /// the rows and the tiles are for.
  bool reportsInUse = false;
  bool reportsLed = false;
  String? reportsStatus;
  String reportsSearch = '';

  Future<void> fetchLedPlaces() async {
    final epoch = _epoch;
    try {
      final res = await _dio.get(ApiConstants.ledPlaces);
      if (epoch != _epoch) return;
      final data = res.data['data'];
      final locations = data is Map ? (data['locations'] as List? ?? []) : [];
      final departments = data is Map ? (data['departments'] as List? ?? []) : [];
      ledLocationIds = [
        for (final l in locations.whereType<Map>()) l['_id'].toString(),
      ];
      ledDepartmentIds = [
        for (final d in departments.whereType<Map>()) d['_id'].toString(),
      ];
      ledPlaceNames = [
        for (final l in locations.whereType<Map>()) (l['name'] ?? '').toString(),
        for (final d in departments.whereType<Map>())
          (d['departmentName'] ?? '').toString(),
      ].where((n) => n.isNotEmpty).toList();
      notifyListeners();
    } on DioException {
      // Fail quiet: without it the Final Report simply has no second view.
    }
  }

  // ── Leader: "My locations" on the Audits tab — the audits still to be done
  // at the places I lead, whoever they are assigned to, each with the
  // server's own canReassign verdict. Not the Final Report's list above (that
  // one is finished audits, for reading).
  List<AuditModel> ledAudits = [];
  bool isLoadingLedAudits = false;
  String? ledAuditsError;

  /// True while the Audits tab is showing "My locations", so a live
  /// notification refreshes it too.
  bool ledAuditsInUse = false;
  int _ledAuditsSeq = 0;

  /// The audits at the places I lead that can still change hands: not started,
  /// in progress or overdue (the web view's own default).
  Future<void> fetchLedAudits({bool quiet = false}) async {
    final epoch = _epoch;
    final seq = ++_ledAuditsSeq;
    bool stale() => epoch != _epoch || seq != _ledAuditsSeq;
    if (!quiet) {
      isLoadingLedAudits = true;
      ledAuditsError = null;
      notifyListeners();
    }
    try {
      final list = await _fetchLedAudits(status: 'Not Started,In Progress,Overdue');
      if (stale()) return;
      // Soonest first: what needs a stand-in next is at the top.
      list.sort((a, b) {
        final ad = a.scheduledDate, bd = b.scheduledDate;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return ad.compareTo(bd);
      });
      ledAudits = list;
      ledAuditsError = null;
    } on DioException catch (e) {
      if (!stale()) {
        ledAuditsError = extractErrorMessage(e, fallback: 'Could not load the audits at your locations.');
      }
    } finally {
      if (!stale()) {
        isLoadingLedAudits = false;
        notifyListeners();
      }
    }
  }

  /// Who could take [audit] over from one of its auditors: active members of
  /// the audited place, not already on the audit, and qualified for its audit
  /// type — the same pool the web dialog offers. A Cross Functional Team audit
  /// (or one with no place) has no member list to offer here: the server
  /// refuses a leader on a CFT audit anyway. Returns null on a failed lookup.
  Future<List<EmployeeOption>?> fetchReassignCandidates(AuditModel audit) async {
    if (audit.isCFT || (audit.locationIdList.isEmpty && audit.departmentIdList.isEmpty)) {
      return const [];
    }
    final epoch = _epoch;
    try {
      final responses = await Future.wait([
        _dio.get(ApiConstants.employeesByLocation(audit.locationIdList, departmentIds: audit.departmentIdList)),
        _dio.get(ApiConstants.auditTypes),
      ]);
      if (epoch != _epoch) return null;
      final people = (responses[0].data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => EmployeeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      String? typeId;
      for (final t in (responses[1].data['data'] as List? ?? []).whereType<Map>()) {
        if (t['name']?.toString() == audit.auditType) typeId = t['_id']?.toString();
      }
      final onAudit = {for (final a in audit.auditors) a.id};
      final seen = <String>{};
      final out = [
        for (final p in people)
          if (p.isActive &&
              !onAudit.contains(p.id) &&
              (typeId == null || p.auditTypeIds.isEmpty || p.auditTypeIds.contains(typeId)) &&
              seen.add(p.id))
            p,
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } on DioException {
      return null;
    }
  }

  /// PATCH /audits/:id/reassign-auditor. The server decides whether it is
  /// allowed and says why not in plain words, which come back as [message].
  /// Either way the lists are refetched afterwards on a success or a 409 (the
  /// audit changed under the open dialog), so what is on screen is current.
  Future<({bool ok, String message})> reassignAuditor(
    String auditId, {
    required String toAuditorId,
    required String fromAuditorId,
    String? reason,
    bool alsoUpcoming = false,
  }) async {
    try {
      final res = await _dio.patch(
        ApiConstants.reassignAuditor(auditId),
        data: {
          'toAuditorId': toAuditorId,
          'fromAuditorId': fromAuditorId,
          'applyTo': alsoUpcoming ? 'thisAndUpcoming' : 'this',
          if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
        },
      );
      unawaited(fetchLedAudits(quiet: true));
      unawaited(fetchMyAudits());
      final message = res.data is Map ? res.data['message']?.toString() : null;
      return (ok: true, message: message ?? 'Auditor changed.');
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) unawaited(fetchLedAudits(quiet: true));
      return (
        ok: false,
        message: extractErrorMessage(e, fallback: 'Could not change the auditor. Please try again.'),
      );
    }
  }

  static int _byRecency(AuditModel a, AuditModel b) {
    final ad = a.completedDate ?? a.scheduledDate;
    final bd = b.completedDate ?? b.scheduledDate;
    if (ad == null && bd == null) return 0;
    if (ad == null) return 1;
    if (bd == null) return -1;
    return bd.compareTo(ad);
  }

  /// Loads the list for the Final Report view chosen in [reportsLed] ("My
  /// locations" or "My audits") under the current shared filters. The stat
  /// tiles are a separate request, [fetchReportStats].
  Future<void> fetchReportAudits() async {
    final led = reportsLed;
    final epoch = _epoch;
    final seq = ++_reportAuditsSeq;
    bool stale() => epoch != _epoch || seq != _reportAuditsSeq;
    isLoadingReports = true;
    reportsError = null;
    notifyListeners();
    try {
      final List<AuditModel> list;
      if (led) {
        list = await _fetchLedAudits();
      } else {
        final res = await _dio.get(
          ApiConstants.myAudits,
          // The SHARED filters, Me by default (employeeIds = self). NOT
          // listFilterParams: Include skipped is an Audits-tab switch.
          queryParameters: {
            ...?filterParams,
            // Same population rule as the tiles (fetchReportStats). The search
            // box narrows these rows on the device (the screen filters the
            // loaded list), so it is not sent.
            'hideUnstarted': 'true',
          },
        );
        list = (res.data['data'] as List? ?? [])
            .whereType<Map>()
            .map((e) => AuditModel.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      if (stale()) return;
      list.sort(_byRecency);
      if (led) {
        ledReportAudits = list;
      } else {
        reportAudits = list;
      }
    } on DioException catch (e) {
      if (!stale()) {
        reportsError = extractErrorMessage(
          e,
          fallback: led
              ? 'Could not load the audits at your locations.'
              : 'Could not load your audits.',
        );
      }
    } finally {
      if (!stale()) {
        isLoadingReports = false;
        notifyListeners();
      }
    }
  }

  // Every audit at a place I lead, paged 100 at a time (the endpoint's
  // maximum) — the Final Report list is one scroll, not a paginated table.
  Future<List<AuditModel>> _fetchLedAudits({
    String status = 'Not Started,In Progress,Overdue,Completed',
  }) async {
    final params = Map<String, dynamic>.from(filterParams ?? const {})
      // The led list ignores employeeIds by design (a "just me" default would
      // empty a list whose point is other people's audits).
      ..remove('employeeIds')
      // Without a status the server defaults to the still-open ones; the Final
      // Report wants every started audit (the default here), the reassign
      // list only the ones still to be done — so name them.
      ..['status'] = status
      ..['limit'] = 100;
    final all = <AuditModel>[];
    var page = 1;
    while (page <= 20) {
      final res = await _dio.get(
        ApiConstants.auditsAtPlacesILead,
        queryParameters: {...params, 'page': page},
      );
      final data = res.data['data'];
      final rows = data is Map ? (data['audits'] as List? ?? []) : const [];
      all.addAll(
        rows.whereType<Map>().map(
          (e) => AuditModel.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
      final total = data is Map ? (data['total'] as num?)?.toInt() ?? 0 : 0;
      if (rows.isEmpty || all.length >= total) break;
      page++;
    }
    return all;
  }

  /// The Final Report tiles from GET /audits/stats/completed under the same
  /// filters as the list, so the numbers equal the web's. "My locations" asks
  /// as All Members over the places I lead (or the picked ones among them),
  /// which the server reads as every audit there. If the endpoint isn't open
  /// to this role (it needs Final Report read access) [reportStats] stays null
  /// and the screen works the same four numbers out from the loaded list.
  Future<void> fetchReportStats() async {
    final led = reportsLed;
    final epoch = _epoch;
    final seq = ++_reportStatsSeq;
    isLoadingReportStats = true;
    notifyListeners();
    ReportStats? stats;
    try {
      final params = Map<String, dynamic>.from(filterParams ?? const {});
      if (led) {
        params.remove('employeeIds');
        if (!params.containsKey('locationIds') &&
            !params.containsKey('departmentIds')) {
          if (ledLocationIds.isNotEmpty) {
            params['locationIds'] = ledLocationIds.join(',');
          }
          if (ledDepartmentIds.isNotEmpty) {
            params['departmentIds'] = ledDepartmentIds.join(',');
          }
        }
      }
      // The Final Report's own rule: only started audits (server:
      // hideUnstarted) — the same rows its table lists.
      params['hideUnstarted'] = 'true';
      // The tiles describe what the list shows: its status chip and search.
      if (reportsStatus != null) params['status'] = reportsStatus;
      if (reportsSearch.trim().isNotEmpty) params['search'] = reportsSearch.trim();
      final res = await _dio.get(
        ApiConstants.completedStats,
        queryParameters: params,
      );
      stats = ReportStats.tryParse(res.data['data']);
    } on DioException {
      stats = null;
    }
    if (epoch != _epoch || seq != _reportStatsSeq) return;
    reportStats = stats;
    isLoadingReportStats = false;
    notifyListeners();
  }

  // ── "Audits at my location" (Calendar) ──────────────────────────────────
  // Every audit scheduled at one of this employee's own locations, whether
  // or not they're personally the assigned auditor/auditee — what powers
  // the Calendar's blue "someone's coming to audit your location" markers
  // (screens/calendar/calendar_screen.dart). Kept as its own list rather
  // than folded into `audits`/`reportAudits` above since those two are
  // both "assigned to me" views and this one deliberately is not.
  bool isLoadingAtMyLocation = false;
  List<AuditModel> auditsAtMyLocation = [];

  Map<String, dynamic>? get _placeAndTypeParams {
    final params = <String, dynamic>{};
    if (locationFilter.isNotEmpty) {
      params['locationIds'] = locationFilter.join(',');
    }
    if (departmentFilter.isNotEmpty) {
      params['departmentIds'] = departmentFilter.join(',');
    }
    if (auditTypeFilter.isNotEmpty) {
      params['auditType'] = auditTypeFilter.join(',');
    }
    return params.isEmpty ? null : params;
  }

  Future<void> fetchAuditsAtMyLocation() async {
    final epoch = _epoch;
    final seq = ++_atMyLocationSeq;
    bool stale() => epoch != _epoch || seq != _atMyLocationSeq;
    isLoadingAtMyLocation = true;
    notifyListeners();
    try {
      // Deliberately NOT filterParams: this endpoint is scoped by which
      // locations the CALLER belongs to, never by employeeIds (see
      // audit.controller.js#getAuditsAtMyLocation) — sending an
      // employeeIds here would be meaningless. It does honour
      // locationFilter/auditTypeFilter, so pass just those.
      final res = await _dio.get(
        ApiConstants.auditsAtMyLocation,
        queryParameters: _placeAndTypeParams,
      );
      if (stale()) return;
      auditsAtMyLocation = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException {
      // Fail quiet, same convention as the other supporting-list fetches
      // above — worst case the calendar just shows NC dots with no blue
      // "audit visit" markers layered on top.
    } finally {
      if (!stale()) {
        isLoadingAtMyLocation = false;
        notifyListeners();
      }
    }
  }

  /// Full-detail fetch for building a downloadable PDF report — same
  /// GET /audits/:id?report=true the web app's AuditFullReport.jsx reads
  /// (audit.controller.js#getAuditDetails). Deliberately separate from
  /// fetchAuditDetail/activeAudit above so opening a report from the
  /// Reports list never disturbs the scoring workspace's own state.
  Future<AuditDetailModel?> fetchAuditReportDetail(String auditId) async {
    final res = await _dio.get(
      ApiConstants.auditById(auditId),
      queryParameters: {'report': 'true'},
    );
    return AuditDetailModel.fromJson(
      Map<String, dynamic>.from(res.data['data']),
    );
  }

  /// Every zone of a multi-document batch, side by side — the mobile
  /// counterpart to fetchAuditReportDetail above for a "combined" report,
  /// which that one alone can't produce for a batch: it only ever fetches
  /// zones this employee is personally an auditor on (this screen's own
  /// list is scoped to GET /audits/mine), so looping it per zone silently
  /// dropped every OTHER auditor's zone from a "combined" PDF — same gap
  /// the web app closed with a dedicated GET /audits/batch/:batchId/report
  /// (audit.controller.js#getBatchReport: unscoped once authorized for at
  /// least one zone, on purpose — "the whole point of a whole-batch report
  /// is every zone side by side"). Each zone in the response is shaped
  /// exactly like GET /audits/:id's own `data`, so AuditDetailModel.fromJson
  /// parses it unchanged. Returns the zones together with the response's
  /// batch-level `displayStatus`/`timeliness` (the one status the combined
  /// PDF prints — see BatchReport.statusLabel) instead of the bare zone list
  /// this used to, which threw that aggregate away.
  Future<BatchReport> fetchBatchReport(String batchId) async {
    final res = await _dio.get(ApiConstants.auditBatchReport(batchId));
    final data = res.data['data'];
    return BatchReport.fromJson(
      data is Map ? Map<String, dynamic>.from(data) : const {},
    );
  }

  /// Uploads evidence photos for one checkpoint right away — independent
  /// of whether a finding/remark/score has been filled in yet. The server
  /// now attaches each photo to the checkpoint's own photoUrls the moment
  /// its upload finishes (see server/workers/evidenceUploadWorker.js),
  /// rather than only once scoreCheckpoint below is also called. This is
  /// what lets an auditor snap evidence now and fill in the finding/
  /// remark later without losing the photo if they navigate away first.
  /// Returns which of `photos` (by path) didn't get confirmed and, if any
  /// didn't, a message about them — see UploadPhotosResult's own doc
  /// comment for why this is per-file rather than all-or-nothing. Refreshes
  /// activeAudit so the tree reflects whichever photos DID attach, even
  /// when others in the same batch failed.
  Future<UploadPhotosResult> uploadCheckpointEvidence({
    required String auditId,
    required String nodeId,
    required List<File> photos,
    String? locationId,
    void Function(UploadPhase phase, double? fraction)? onProgress,
  }) async {
    if (photos.isEmpty) return const UploadPhotosResult();
    // fileName -> File, so a job's own result (identified by fileName, the
    // one thing the server echoes back — see uploadParameterEvidence) maps
    // back to exactly the local file it came from.
    final byFileName = {for (final f in photos) f.path.split('/').last: f};
    try {
      // NOT FormData.fromMap({for (f in files) 'photos': ...}) — a Dart
      // map literal silently collapses duplicate keys to the last one,
      // so that would upload only the last photo no matter how many
      // were picked. form.files is a List<MapEntry>, which correctly
      // keeps every 'photos' entry as its own multipart part.
      final form = FormData();
      for (final file in photos) {
        form.files.add(
          MapEntry(
            'photos',
            await MultipartFile.fromFile(
              file.path,
              filename: file.path.split('/').last,
            ),
          ),
        );
      }
      onProgress?.call(UploadPhase.uploading, 0);
      // Server queues one background job per file and responds fast
      // with jobIds instead of blocking on Cloudinary (see
      // server/controllers/audit.controller.js#uploadParameterEvidence)
      // — _waitForEvidenceJob below waits for each to actually finish
      // uploading AND attaching to the checkpoint server-side.
      final uploadRes = await _dio.post(
        ApiConstants.uploadEvidence(auditId, nodeId),
        data: form,
        queryParameters: locationId != null ? {'locationId': locationId} : null,
        onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call(UploadPhase.uploading, sent / total);
        },
      );
      final jobs = (uploadRes.data['data']['jobs'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      onProgress?.call(UploadPhase.processing, null);
      // Waited on PER JOB, not one Future.wait for the lot — a batch of
      // several photos (picked together from the gallery) can genuinely
      // partially succeed: a slower one timing out under server load must
      // not drag the ones that already finished back into "failed", which
      // used to mean the whole batch got resent on every retry, wasting
      // bandwidth re-uploading photos that had already attached and never
      // actually converging for a batch with one persistently slow file.
      String? firstError;
      final failedPaths = <String>{};
      await Future.wait(jobs.map((j) async {
        final fileName = j['fileName'] as String?;
        final file = fileName != null ? byFileName[fileName] : null;
        try {
          await _waitForEvidenceJob(j['jobId'] as String);
        } catch (e) {
          if (file != null) failedPaths.add(file.path);
          firstError ??= e is Exception && e is! DioException
              ? e.toString().replaceFirst('Exception: ', '')
              : null;
        }
      }));
      // Refresh even on a partial failure — whichever photos DID attach
      // must show up as confirmed right away, not wait for a fully clean
      // batch that a single stubborn file may keep preventing.
      try {
        await fetchAuditDetail(auditId, quiet: true);
      } catch (_) {}
      if (failedPaths.isEmpty) return const UploadPhotosResult();
      return UploadPhotosResult(
        failedPaths: failedPaths,
        error: (firstError?.isNotEmpty ?? false) ? firstError : 'Could not upload this photo.',
      );
    } catch (e) {
      // The upload request itself failed (not a specific job) — every
      // photo in this attempt is unconfirmed.
      return UploadPhotosResult(
        failedPaths: photos.map((f) => f.path).toSet(),
        error: _saveErrorMessage(e, 'Could not upload this photo.'),
      );
    }
  }

  /// Turns whatever a checkpoint save/upload threw into a message an auditor
  /// can act on. The server's own text is kept for 4xx (those are written
  /// for people: "Remark is mandatory…", "not an assigned auditor…") but a
  /// 5xx carries a raw exception string (Mongoose/Node) that means nothing
  /// on a phone, so it is replaced. Also catches non-Dio failures (a bad
  /// response shape, say) so a save can never end in an uncaught error that
  /// leaves the checkpoint card stuck on "Saving…".
  String _saveErrorMessage(Object e, String fallback) {
    if (e is DioException) {
      final status = e.response?.statusCode ?? 0;
      if (status >= 500) {
        return 'The server had a problem saving this. We\'ll keep trying.';
      }
      if (status == 401) return 'Your session expired. Please sign in again.';
      return extractErrorMessage(e, fallback: fallback);
    }
    return fallback;
  }

  /// Saves this checkpoint's finding — remark, score, and NC details for a
  /// fresh NC. Evidence photos are handled separately (see
  /// uploadCheckpointEvidence above), so this never touches photoUrls.
  ///
  /// `score` must always be sent: the server (audit.controller.js#
  /// scoreParameter) derives Strong Compliance/Compliance itself (full
  /// marks, ignoring what's sent) but REQUIRES a numeric score for OFI and
  /// for NC — an NC save with no score is rejected with "A numeric score is
  /// required for an NC finding.", which is what made raising an NC from a
  /// checkpoint fail. Returns the error message on failure, null on
  /// success, then refreshes activeAudit so the tree reflects the save.
  Future<String?> scoreCheckpoint({
    required String auditId,
    required String nodeId,
    // Null = no finding picked yet — a remark-only save (server:
    // audit.controller.js#scoreParameter's isRemarkOnly branch), same as a
    // photo already saves independent of the finding.
    String? findingType,
    double? score,
    required String remark,
    String? locationId,
    String? auditeeEmployeeId,
    DateTime? targetDate,
    String? severity,
  }) async {
    try {
      await _dio.patch(
        ApiConstants.scoreParameter(auditId, nodeId),
        data: {
          'findingType': ?findingType,
          'score': ?score,
          'remark': remark,
          'locationId': ?locationId,
          'auditeeEmployeeId': ?auditeeEmployeeId,
          'targetDate': ?targetDate?.toIso8601String(),
          'severity': ?severity,
        },
      );
    } catch (e) {
      return _saveErrorMessage(e, 'Could not save this checkpoint.');
    }
    // The PATCH already succeeded — a failed refresh must not read as a
    // failed save (the card would retry and resend a save that landed).
    try {
      await fetchAuditDetail(auditId, quiet: true);
    } catch (_) {}
    return null;
  }

  /// Auditor: fix a mistake on an already-raised NC — reassign who it's
  /// against, its flag (`severity` on the wire), or its due date. Server only allows this
  /// for the raising auditor, and only while the NC is still "Raised"
  /// (nc.controller.js#updateNC) — passing all three every time, since
  /// this always comes from checkpoint_card.dart's edit form which
  /// collects all three together, same shape scoreCheckpoint's own NC
  /// fields use.
  Future<String?> updateNc({
    required String auditId,
    required String ncId,
    String? auditeeEmployeeId,
    String? severity,
    DateTime? targetDate,
  }) async {
    try {
      await _dio.patch(
        ApiConstants.ncDetail(ncId),
        data: {
          'auditeeEmployeeId': ?auditeeEmployeeId,
          'severity': ?severity,
          'targetDate': ?targetDate?.toIso8601String(),
        },
      );
      await fetchAuditDetail(auditId, quiet: true);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not update this NC.',
      );
    }
  }

  /// Waits for one queued evidence-upload job (see uploadCheckpointEvidence
  /// above) to finish. Socket event ("evidence_upload_result", pushed by
  /// server/workers/evidenceUploadWorker.js) is the primary signal; the
  /// periodic status poll is a belt-and-suspenders fallback for a missed
  /// event (brief disconnect, app briefly backgrounded) — whichever
  /// resolves the completer first wins, both paths are idempotent.
  ///
  /// The poller doesn't start immediately alongside the socket listener —
  /// it waits _pollGrace first. Most uploads finish well under that window
  /// (the socket event arrives in well under a second once the worker's
  /// done), so in the common case this GET never fires at all instead of
  /// racing the socket from second 0 on every single photo. When it does
  /// kick in as a genuine fallback, it polls every 5s (was 3s) instead —
  /// together this is what was behind "too many API calls while saving" on
  /// a checkpoint with several photos, since each photo gets its own
  /// _waitForEvidenceJob running concurrently (Future.wait in
  /// uploadCheckpointEvidence above).
  Future<String> _waitForEvidenceJob(
    String jobId, {
    Duration timeout = const Duration(seconds: 45),
  }) {
    const pollGrace = Duration(seconds: 5);
    const pollInterval = Duration(seconds: 5);
    final completer = Completer<String>();
    Timer? pollStart;
    Timer? poller;
    Timer? timer;
    late final void Function(dynamic data) handler;

    void cleanup() {
      SocketService.instance.off('evidence_upload_result', handler);
      pollStart?.cancel();
      poller?.cancel();
      timer?.cancel();
    }

    Future<void> pollOnce() async {
      if (completer.isCompleted) return;
      try {
        final res = await _dio.get(ApiConstants.evidenceUploadStatus(jobId));
        final data = res.data['data'];
        if (data['status'] == 'completed') {
          completer.complete(data['url'] as String);
          cleanup();
        } else if (data['status'] == 'failed') {
          completer.completeError(Exception(data['error'] ?? 'Upload failed'));
          cleanup();
        }
      } catch (_) {
        // transient — keep polling until timeout
      }
    }

    handler = (data) {
      if (completer.isCompleted || data is! Map || data['jobId'] != jobId)
        return;
      if (data['status'] == 'completed') {
        completer.complete(data['url'] as String);
      } else if (data['status'] == 'failed') {
        completer.completeError(Exception(data['error'] ?? 'Upload failed'));
      } else {
        return;
      }
      cleanup();
    };
    SocketService.instance.on('evidence_upload_result', handler);

    pollStart = Timer(pollGrace, () {
      if (completer.isCompleted) return;
      pollOnce();
      poller = Timer.periodic(pollInterval, (_) => pollOnce());
    });

    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(
          Exception('Upload is taking longer than expected — please retry.'),
        );
        cleanup();
      }
    });

    return completer.future;
  }

  /// Removes one already-uploaded evidence photo — actually deletes the
  /// file on Cloudinary server-side (see
  /// audit.controller.js#deleteParameterEvidence), not just drops the URL
  /// from the checkpoint. Called immediately on tap (not deferred to the
  /// checkpoint's own autosave) so a photo removed right before leaving
  /// the screen doesn't silently survive in storage.
  Future<String?> deleteEvidencePhoto({
    required String auditId,
    required String nodeId,
    required String url,
    String? locationId,
  }) async {
    try {
      await _dio.delete(
        ApiConstants.uploadEvidence(auditId, nodeId),
        data: {'url': url},
        queryParameters: locationId != null ? {'locationId': locationId} : null,
      );
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not remove this photo.');
    }
  }

  /// "Final Submit" — closes the audit out entirely (server re-validates
  /// full scoring + zero open NCs; the button is also disabled client-side
  /// for the same reasons, see audit_detail_screen.dart).
  Future<String?> completeAudit(
    String auditId, {
    String? finalAuditorRemark,
  }) async {
    try {
      await _dio.patch(
        ApiConstants.completeAudit(auditId),
        data: {'finalAuditorRemark': ?finalAuditorRemark},
      );
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not submit this audit.');
    }
  }

  /// The "select representative auditee" step, asked once before an
  /// assigned auditor starts scoring (see
  /// audit_detail_screen.dart's gating logic in _load) — now multi-select,
  /// at least one required. Writes to the same audit-level auditeeIds
  /// field the NC-raise picker's default falls back to (via auditeeIds[0]
  /// mirrored onto the legacy singular auditeeId — see scoreParameter's
  /// ncAuditeeId resolution server-side, models/Audit.js#auditeeIds) —
  /// this just fills that default in up front instead of leaving it unset
  /// until the first NC. Refetches so activeAudit.auditeeIds reflects it
  /// immediately.
  Future<String?> setAuditRepresentative(
    String auditId,
    List<String> employeeIds,
  ) async {
    try {
      await _dio.patch(
        ApiConstants.auditRepresentative(auditId),
        data: {'auditeeEmployeeIds': employeeIds},
      );
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not save the representative.',
      );
    }
  }

  /// "Submit" — the soft, first-pass confirmation (server:
  /// audit.controller.js#mobileSubmitAudit). Distinct from completeAudit
  /// above: this doesn't close the audit, it's what unlocks web editing
  /// for it (see awaitingMobileSubmission there) — Instant Audits never
  /// need it since web can already score those from the start.
  Future<String?> mobileSubmitAudit(String auditId) async {
    try {
      await _dio.patch(ApiConstants.mobileSubmitAudit(auditId));
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not submit this audit.');
    }
  }
}
