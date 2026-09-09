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
  Future<void> refetchForFilters() =>
      Future.wait([fetchMyAudits(), fetchAuditsAtMyLocation()]);

  bool isLoading = false;
  String? errorMessage;
  List<AuditModel> audits = [];

  bool isLoadingDetail = false;
  String? detailError;
  AuditDetailModel? activeAudit;

  List<EmployeeOption> auditeeCandidates = [];
  List<LocationOption> allLocations = [];

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
        fetchMyAudits();
        if (activeAudit != null) fetchAuditDetail(activeAudit!.id);
      }
    };
    SocketService.instance.on('new_notification', _onNewNotification!);
  }

  void stopListening() {
    _listening = false;
    if (_onNewNotification != null) {
      SocketService.instance.off('new_notification', _onNewNotification);
      _onNewNotification = null;
    }
  }

  /// Who's actually assigned to the given Locations — powers both the
  /// "select representative auditee" picker and the "raise NC against"
  /// picker (checkpoint_card.dart, raise_nc_sheet.dart, select_representative
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
  Future<void> fetchLocationEmployees(List<String> locationIds) async {
    if (locationIds.isEmpty) {
      auditeeCandidates = [];
      notifyListeners();
      return;
    }
    try {
      final res = await _dio.get(ApiConstants.employeesByLocation(locationIds));
      auditeeCandidates = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => EmployeeOption.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    } on DioException {
      // Picker just renders empty on failure — same "fail quiet"
      // convention used elsewhere in this app for supporting-list fetches.
    }
  }

  // ── Instant Audit builder (screens/audits/audit_detail_screen.dart's
  // "set up" section) — mirrors the web app's InstantAudit.jsx for the
  // "same" (one shared checklist) case, and extends it with the
  // "per-location" (a separate checklist per tagged location) case the
  // rest of the app already supports for normal audits, since web's own
  // Instant Audit flow doesn't offer that choice at all. Everything is
  // saved via the same PATCH /audits/:id/save-draft, only ever usable
  // while the audit is still "Draft" — which an Instant Audit always is.

  Future<void> fetchAllLocations() async {
    try {
      final res = await _dio.get(ApiConstants.locations);
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
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.myAudits,
        queryParameters: filterParams,
      );
      final list = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      audits = list;
    } on DioException catch (e) {
      errorMessage = extractErrorMessage(
        e,
        fallback: 'Could not load your audits.',
      );
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<String?> raiseNc({
    required String auditId,
    required String title,
    required String description,
    required DateTime targetDate,
    String? auditeeEmployeeId,
    String? severity,
  }) async {
    try {
      await _dio.post(
        ApiConstants.ncs,
        data: {
          'auditId': auditId,
          'title': title,
          'description': description,
          'targetDate': targetDate.toIso8601String(),
          'auditeeEmployeeId': ?auditeeEmployeeId,
          'severity': ?severity,
        },
      );
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not raise the NC. Please try again.',
      );
    }
  }

  // ── Audit detail / scoring workspace ──────────────────────────────────
  // Same GET /audits/:id the web app's AuditReportDetail.jsx reads —
  // full parameter tree, assignments, ncs. Access is enforced server-side
  // (SuperAdmin, this audit's own auditors/auditee/planner, or their
  // hierarchy scope), not by anything client-side.
  Future<void> fetchAuditDetail(String auditId) async {
    isLoadingDetail = true;
    detailError = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.auditById(auditId));
      activeAudit = AuditDetailModel.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      detailError = extractErrorMessage(
        e,
        fallback: 'Could not load this audit.',
      );
    } finally {
      isLoadingDetail = false;
      notifyListeners();
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

  // ── Reports (Profile → Reports) ───────────────────────────────────────
  // Same GET /audits/mine list fetchMyAudits already uses — always this
  // employee's own audits regardless of the My Audits team-scope toggle,
  // since Reports is a personal record, not a team view — but unfiltered
  // by status (mirrors the web app's CompletedAudits.jsx, which lists
  // every stage behind its own status dropdown, not Completed-only).
  // ReportsScreen narrows this down client-side via status chips, same
  // "fetch once, filter locally" pattern MyAuditsScreen's chips already
  // use over `audits` below.
  bool isLoadingReports = false;
  String? reportsError;
  List<AuditModel> reportAudits = [];

  Future<void> fetchReportAudits() async {
    isLoadingReports = true;
    reportsError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.myAudits,
        // Always self only — per this section's own doc comment above.
        // Can't reuse `filterParams`: it deliberately sends NO employeeIds
        // for Team scope, which resolveScopedEmployeeIds (server) reads as
        // "self + whole downstream hierarchy" — for a SuperAdmin/
        // full-access role, no scope at ALL — the exact opposite of what a
        // personal Reports list is for. Omitting this was a real bug: a
        // manager's Reports screen was silently pooling in every
        // subordinate's audits too, and a SuperAdmin's showed the entire
        // org's.
        queryParameters: selfEmployeeId != null
            ? {'employeeIds': selfEmployeeId}
            : null,
      );
      final list = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      list.sort((a, b) {
        final ad = a.completedDate ?? a.scheduledDate;
        final bd = b.completedDate ?? b.scheduledDate;
        if (ad == null && bd == null) return 0;
        if (ad == null) return 1;
        if (bd == null) return -1;
        return bd.compareTo(ad);
      });
      reportAudits = list;
    } on DioException catch (e) {
      reportsError = extractErrorMessage(
        e,
        fallback: 'Could not load your audits.',
      );
    } finally {
      isLoadingReports = false;
      notifyListeners();
    }
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
    if (auditTypeFilter.isNotEmpty) {
      params['auditType'] = auditTypeFilter.join(',');
    }
    return params.isEmpty ? null : params;
  }

  Future<void> fetchAuditsAtMyLocation() async {
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
      auditsAtMyLocation = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => AuditModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException {
      // Fail quiet, same convention as the other supporting-list fetches
      // above — worst case the calendar just shows NC dots with no blue
      // "audit visit" markers layered on top.
    } finally {
      isLoadingAtMyLocation = false;
      notifyListeners();
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
  /// parses it unchanged.
  Future<List<AuditDetailModel>> fetchBatchReport(String batchId) async {
    final res = await _dio.get(ApiConstants.auditBatchReport(batchId));
    final zones = (res.data['data']?['zones'] as List? ?? [])
        .whereType<Map>()
        .map((z) => AuditDetailModel.fromJson(Map<String, dynamic>.from(z)))
        .toList();
    return zones;
  }

  /// Uploads evidence photos for one checkpoint right away — independent
  /// of whether a finding/remark/score has been filled in yet. The server
  /// now attaches each photo to the checkpoint's own photoUrls the moment
  /// its upload finishes (see server/workers/evidenceUploadWorker.js),
  /// rather than only once scoreCheckpoint below is also called. This is
  /// what lets an auditor snap evidence now and fill in the finding/
  /// remark later without losing the photo if they navigate away first.
  /// Returns the error message on failure, null on success, then
  /// refreshes activeAudit so the tree reflects the newly-attached
  /// photo(s) immediately.
  Future<String?> uploadCheckpointEvidence({
    required String auditId,
    required String nodeId,
    required List<File> photos,
    String? locationId,
    void Function(UploadPhase phase, double? fraction)? onProgress,
  }) async {
    if (photos.isEmpty) return null;
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
      await Future.wait(
        jobs.map((j) => _waitForEvidenceJob(j['jobId'] as String)),
      );
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not upload this photo.');
    }
  }

  /// Saves this checkpoint's finding — remark, and (for OFI) score, NC
  /// details for a fresh NC. Evidence photos are handled separately (see
  /// uploadCheckpointEvidence above), so this never touches photoUrls.
  /// Returns the error message on failure, null on success, then
  /// refreshes activeAudit so the tree reflects the save immediately.
  Future<String?> scoreCheckpoint({
    required String auditId,
    required String nodeId,
    required String findingType,
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
          'findingType': findingType,
          'score': ?score,
          'remark': remark,
          'locationId': ?locationId,
          'auditeeEmployeeId': ?auditeeEmployeeId,
          'targetDate': ?targetDate?.toIso8601String(),
          'severity': ?severity,
        },
      );
      await fetchAuditDetail(auditId);
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not save this checkpoint.',
      );
    }
  }

  /// Auditor: fix a mistake on an already-raised NC — reassign who it's
  /// against, its severity/flag, or its due date. Server only allows this
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
      await fetchAuditDetail(auditId);
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
  /// assigned auditor starts scoring a non-Self audit (see
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
