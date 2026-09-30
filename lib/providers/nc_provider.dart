import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/nc_model.dart';
import '../models/nc_report_model.dart';
import 'audit_filter_scope.dart';

/// Same two-sided access rule as the web app's NCManagement.jsx (auditor:
/// NCs I raised) and Auditee.jsx (auditee: NCs raised against me) — one
/// person can hold both, each list is independently scoped server-side.
class NcProvider extends ChangeNotifier with AuditFilterScope {
  final Dio _dio = DioClient.instance.dio;

  // The same shared filter state as AuditsProvider/DashboardProvider
  // (AuditFilterScope): Me / All Members, Team, Members, Location +
  // Department, Audit Type, Date range and Flag all narrow both NC lists
  // below. The NC endpoints AND the place with the person scope (an NC row
  // must be in the requester's own scope AND at the picked place), so the
  // location filter is safe to send here now. One state covers both lists
  // (not a separate one per side) since a single person can appear in both.
  // Defaults FALSE (Me) — see AuditsProvider's identical field for the
  // reasoning and for the _selfEmployeeId-must-be-set-first caveat.
  @override
  bool isTeamScope = false;
  String? _selfEmployeeId;
  @override
  String? get selfEmployeeId => _selfEmployeeId;

  void setSelfEmployeeId(String id) {
    _selfEmployeeId = id;
  }

  Future<void> setTeamScope(bool isTeam) {
    isTeamScope = isTeam;
    notifyListeners();
    return refetchForFilters();
  }

  @override
  Future<void> refetchForFilters() {
    // The Reports tab is not the one showing (it stays mounted in the shell): it
    // is not refetched behind the user's back — it notes it is out of date and
    // reloads when it is opened again.
    if (!ncReportsInUse) ncReportsStale = true;
    return Future.wait([
      fetchRaisedByMe(),
      fetchRaisedStats(),
      fetchAgainstMe(),
      if (calendarInUse) fetchCalendarNcs(),
      // The Reports tab is showing: its NCs, Repeated NCs and tiles follow the
      // filters too.
      if (ncReportsInUse) ...[fetchNcReport(), fetchNcReportStats(), fetchRepeats()],
    ]);
  }

  // Bumped on logout: a fetch already on the wire for the previous account
  // finds the number changed when it lands and drops its answer — its error
  // and its loading flag too — instead of putting that account's NCs back
  // after the reset or ending the next account's own loading state.
  int _epoch = 0;

  // Per-call sequence numbers: two quick filter changes put two requests on
  // the wire, and the older answer may land last — only the newest call of
  // each fetch may write its result, error or loading flag.
  int _raisedSeq = 0;
  int _raisedStatsSeq = 0;
  int _mineSeq = 0;
  int _calendarSeq = 0;
  int _ncReportSeq = 0;
  int _ncReportStatsSeq = 0;
  int _repeatsSeq = 0;

  // NCs whose move-to-Verification already succeeded but whose verify did not
  // — a retry must go straight to verify (moving again is a 400).
  final Set<String> _movedToVerification = {};

  /// Back to the Me default and empty, without refetching — call on logout.
  /// See AuditFilterScope.resetForLogout's doc for why this matters on a
  /// shared device: every provider here is a single, process-lifetime
  /// instance, so without this the NEXT person to log in would inherit
  /// whichever scope the PREVIOUS account left this on — and see that
  /// account's NC lists until their own fetch lands. The self id goes too: a
  /// SuperAdmin never gets one set (main.dart's _RootGate), so it would
  /// otherwise keep filtering by the previous employee.
  @override
  void resetForLogout() {
    stopListening();
    _epoch++;
    _selfEmployeeId = null;
    raisedByMe = [];
    raisedAgainstMe = [];
    calendarNcs = [];
    calendarInUse = false;
    isLoadingCalendarNcs = false;
    raisedStats = null;
    isLoadingRaisedStats = false;
    reportNcs = [];
    ncReportTotalNcs = null;
    ncReportTotalAudits = null;
    ncReportStats = null;
    ncReportError = null;
    isLoadingNcReport = false;
    isLoadingNcReportStats = false;
    ncReportsInUse = false;
    ncReportsStale = false;
    ncReportSearch = '';
    ncReportTileKeys = const {};
    ncReportByLocation = false;
    repeatRows = [];
    repeatsTotal = 0;
    repeatsMinCount = 2;
    repeatsError = null;
    isLoadingRepeats = false;
    isLoadingMoreRepeats = false;
    activeNc = null;
    _movedToVerification.clear();
    raisedError = null;
    mineError = null;
    isLoadingRaised = false;
    isLoadingMine = false;
    isLoadingDetail = false;
    // Filters back to the Me default (also notifies).
    super.resetForLogout();
  }

  bool isLoadingRaised = false;
  String? raisedError;
  List<NcModel> raisedByMe = [];

  bool isLoadingMine = false;
  String? mineError;
  List<NcModel> raisedAgainstMe = [];

  /// The Calendar's own copy of "NCs raised against me". The Calendar has no
  /// Flag filter (web's neither), so it must not read [raisedAgainstMe]: that
  /// list is fetched with the NC screen's Flag pick as `severity`, which would
  /// narrow the calendar with a filter it cannot show or clear. Fetched with
  /// [filterParams] (no severity); [calendarInUse] keeps it following filter
  /// changes while the Calendar is open.
  bool calendarInUse = false;
  bool isLoadingCalendarNcs = false;
  List<NcModel> calendarNcs = [];

  /// NC Monitoring's six tiles (GET /ncs/raised/stats) under the same filters as
  /// [raisedByMe] — null until loaded or when the request failed (the tiles are
  /// then simply not drawn; the list is unaffected).
  NcTileStats? raisedStats;
  bool isLoadingRaisedStats = false;

  // ── Final Report · NCs tab and Repeated NCs tab ────────────────────────
  // GET /ncs/report lists every NC the caller may see, GET /ncs/report/stats
  // gives its six tiles, the id list behind each and the per-place tallies
  // (byLocation) over the whole filtered set, and GET /ncs/repeats the groups of
  // the same checkpoint wording raised again at the same place. The people rule
  // is the server's (an NC is a person's as raiser or auditee; a Team / specific
  // Members pick narrows): this sends the shared filters and renders what comes
  // back —
  // the bucket and the place label of each row are the server's, never derived.

  /// True while the Reports tab is the one showing, so a filter change reaches
  /// these lists too; [ncReportsStale] says one moved while it was not.
  bool ncReportsInUse = false;
  bool ncReportsStale = false;

  /// The search box (server-side, so the tiles and the list describe the same
  /// NCs) and the tile picks (NcBucket keys) + whether the location-wise view is
  /// on — with both, the place tallies are asked for over just the picked tiles'
  /// NCs (the server's `onlyIds`), while the tiles keep the whole set.
  String ncReportSearch = '';
  Set<String> ncReportTileKeys = const {};
  bool ncReportByLocation = false;

  bool isLoadingNcReport = false;
  String? ncReportError;
  List<NcModel> reportNcs = [];

  /// How many NCs and how many audits the filters match (GET /ncs/report with
  /// groupBy=audit: `totalNcs` and `total`) — the count line's numbers, true even
  /// when fewer rows were loaded. Null until the first answer.
  int? ncReportTotalNcs;
  int? ncReportTotalAudits;
  NcTileStats? ncReportStats;
  bool isLoadingNcReportStats = false;

  /// The Repeated NCs tab: the "min. times" pick (2, 3, 4, 5, 10), the groups
  /// loaded so far (paged — [repeatsTotal] is how many there are) and its state.
  int repeatsMinCount = 2;
  List<RepeatGroup> repeatRows = [];
  int repeatsTotal = 0;
  bool isLoadingRepeats = false;
  bool isLoadingMoreRepeats = false;
  String? repeatsError;
  static const _repeatsPageSize = 30;

  bool isLoadingDetail = false;
  NcModel? activeNc;

  bool _listening = false;
  // Stored so stopListening removes exactly this closure — Notifications
  // Provider and AuditsProvider also register their own 'new_notification'
  // handler, and socket_io_client's off(event) with no handler removes
  // EVERY listener for that event, not just the caller's own.
  void Function(dynamic data)? _onNewNotification;

  /// Wires a socket listener once, after login — mirrors
  /// NotificationsProvider.startListening(). Any `nc_*` event (raised,
  /// responded, approved, rejected) refetches both lists so a screen
  /// showing them reflects the change live, without a manual pull-to-refresh.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map && (data['type']?.toString() ?? '').startsWith('nc_')) {
        // A burst of notifications refetches once, not once each.
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 500), () {
          fetchRaisedByMe();
          fetchRaisedStats();
          fetchAgainstMe();
          if (calendarInUse) fetchCalendarNcs();
          _refreshReports();
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

  Future<void> fetchRaisedByMe() async {
    final epoch = _epoch;
    final seq = ++_raisedSeq;
    bool stale() => epoch != _epoch || seq != _raisedSeq;
    isLoadingRaised = true;
    raisedError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsRaised,
        queryParameters: ncFilterParams,
      );
      if (stale()) return;
      raisedByMe = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      if (!stale()) {
        raisedError = extractErrorMessage(
          e,
          fallback: 'Could not load raised NCs.',
        );
      }
    } catch (e, st) {
      // An answer the models cannot read must end the loading state and say so,
      // not escape as an unhandled error from a fire-and-forget refetch.
      debugPrint('NcProvider.fetchRaisedByMe: unreadable answer: $e\n$st');
      if (!stale()) raisedError = 'Could not load raised NCs.';
    } finally {
      if (!stale()) {
        isLoadingRaised = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchAgainstMe() async {
    final epoch = _epoch;
    final seq = ++_mineSeq;
    bool stale() => epoch != _epoch || seq != _mineSeq;
    isLoadingMine = true;
    mineError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsMine,
        queryParameters: ncFilterParams,
      );
      if (stale()) return;
      raisedAgainstMe = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      if (!stale()) {
        mineError = extractErrorMessage(e, fallback: 'Could not load your NCs.');
      }
    } catch (e, st) {
      debugPrint('NcProvider.fetchAgainstMe: unreadable answer: $e\n$st');
      if (!stale()) mineError = 'Could not load your NCs.';
    } finally {
      if (!stale()) {
        isLoadingMine = false;
        notifyListeners();
      }
    }
  }

  /// NC Monitoring's tiles: GET /ncs/raised/stats under the same filters as
  /// [fetchRaisedByMe]. Fails quietly — a failed request only hides the tiles.
  Future<void> fetchRaisedStats() async {
    final epoch = _epoch;
    final seq = ++_raisedStatsSeq;
    bool stale() => epoch != _epoch || seq != _raisedStatsSeq;
    isLoadingRaisedStats = true;
    notifyListeners();
    NcTileStats? stats;
    try {
      final res = await _dio.get(
        ApiConstants.ncsRaisedStats,
        queryParameters: ncFilterParams,
      );
      stats = NcTileStats.tryParse(res.data['data']);
    } on DioException {
      stats = null;
    } catch (e, st) {
      debugPrint('NcProvider.fetchRaisedStats: unreadable answer: $e\n$st');
      stats = null;
    }
    if (stale()) return;
    raisedStats = stats;
    isLoadingRaisedStats = false;
    notifyListeners();
  }

  /// What both Final Report NC requests take: the shared filters (people, place,
  /// Audit Type, Date, Flag) plus the search box.
  Map<String, dynamic> get _ncReportParams => {
    ...?ncFilterParams,
    if (ncReportSearch.trim().isNotEmpty) 'search': ncReportSearch.trim(),
  };

  /// The Reports tab's NC list — every page of GET /ncs/report, 100 at a time
  /// (the endpoint's maximum), so the tiles and place headers can be matched to
  /// rows by id.
  ///
  /// Paged with `groupBy=audit`: a page is `limit` whole AUDITS (every matching NC
  /// of each), `total` counts audits and `totalNcs` the NCs, so the several NCs of
  /// one audit always arrive together and the tab can show them as one bundle.
  /// (Never sent with `ids` — a tile pick is applied here on the device.)
  Future<void> fetchNcReport() async {
    final epoch = _epoch;
    final seq = ++_ncReportSeq;
    bool stale() => epoch != _epoch || seq != _ncReportSeq;
    isLoadingNcReport = true;
    ncReportError = null;
    notifyListeners();
    try {
      const limit = 100;
      final params = {..._ncReportParams, 'limit': limit, 'groupBy': 'audit'};
      final seen = <String>{};
      final all = <NcModel>[];
      int? totalNcs;
      int? totalAudits;
      var page = 1;
      while (page <= 30) {
        final res = await _dio.get(
          ApiConstants.ncsReport,
          queryParameters: {...params, 'page': page},
        );
        if (stale()) return;
        final data = res.data['data'];
        final rows = data is Map ? (data['ncs'] as List? ?? []) : const [];
        for (final e in rows.whereType<Map>()) {
          final nc = NcModel.fromJson(Map<String, dynamic>.from(e));
          if (seen.add(nc.id)) all.add(nc);
        }
        final total = data is Map ? (data['total'] as num?)?.toInt() ?? 0 : 0;
        totalAudits = total;
        totalNcs = data is Map ? (data['totalNcs'] as num?)?.toInt() : null;
        // `total` counts audits, `limit` audits a page: the last page comes from
        // those, not from how many NCs have arrived.
        if (rows.isEmpty || page * limit >= total) break;
        page++;
      }
      reportNcs = all;
      ncReportTotalAudits = totalAudits;
      ncReportTotalNcs = totalNcs;
      ncReportsStale = false;
    } on DioException catch (e) {
      if (!stale()) {
        ncReportError = extractErrorMessage(e, fallback: 'Could not load the NCs.');
      }
    } catch (e, st) {
      debugPrint('NcProvider.fetchNcReport: unreadable answer: $e\n$st');
      if (!stale()) ncReportError = 'Could not load the NCs.';
    } finally {
      if (!stale()) {
        isLoadingNcReport = false;
        notifyListeners();
      }
    }
  }

  /// The six tiles and the place tallies for the same NCs (GET /ncs/report/stats).
  Future<void> fetchNcReportStats() async {
    final epoch = _epoch;
    final seq = ++_ncReportStatsSeq;
    bool stale() => epoch != _epoch || seq != _ncReportStatsSeq;
    isLoadingNcReportStats = true;
    notifyListeners();
    NcTileStats? stats;
    try {
      final params = _ncReportParams;
      final res = await _dio.get(ApiConstants.ncsReportStats, queryParameters: params);
      stats = NcTileStats.tryParse(res.data['data']);
      // Location-wise AND a tile picked: the place tallies must describe the
      // tile's NCs, so ask again for just them. Best effort — without it the
      // headers keep the whole set's numbers.
      if (stats != null && ncReportByLocation && ncReportTileKeys.isNotEmpty) {
        final ids = {for (final k in ncReportTileKeys) ...stats.idsFor(k)};
        try {
          final narrowed = await _dio.get(
            ApiConstants.ncsReportStats,
            queryParameters: {...params, 'onlyIds': ids.join(',')},
          );
          final rows = NcTileStats.tryParse(narrowed.data['data'])?.byLocation;
          if (rows != null) stats = stats.withByLocation(rows);
        } on DioException {
          // keep the whole set's headers
        }
      }
    } on DioException {
      stats = null;
    } catch (e, st) {
      debugPrint('NcProvider.fetchNcReportStats: unreadable answer: $e\n$st');
      stats = null;
    }
    if (stale()) return;
    ncReportStats = stats;
    isLoadingNcReportStats = false;
    notifyListeners();
  }

  /// What GET /ncs/repeats takes. The server groups org-wide — who raised or
  /// received an NC never enters a group — so the people half of the shared
  /// filters (Me / All Members / Team / Members) is NOT sent; Location +
  /// Department, Audit Type, Flag and Date are. With no date picked the tab looks
  /// back six months, like the web's, and says so.
  Map<String, dynamic> get repeatParams {
    final params = <String, dynamic>{'minCount': repeatsMinCount};
    if (locationFilter.isNotEmpty) params['locationIds'] = locationFilter.join(',');
    if (departmentFilter.isNotEmpty) params['departmentIds'] = departmentFilter.join(',');
    if (auditTypeFilter.isNotEmpty) params['auditType'] = auditTypeFilter.join(',');
    if (flagFilter.isNotEmpty) params['severity'] = flagFilter.join(',');
    final from = dateFrom ?? (hasDateFilter ? null : repeatDefaultFrom());
    if (from != null) params['fromDate'] = DateFormat('yyyy-MM-dd').format(from);
    if (dateTo != null) params['toDate'] = DateFormat('yyyy-MM-dd').format(dateTo!);
    return params;
  }

  /// Six months before [now] — the Repeated NCs tab's window when no date range
  /// is picked.
  static DateTime repeatDefaultFrom([DateTime? now]) {
    final n = now ?? DateTime.now();
    return DateTime(n.year, n.month - 6, n.day);
  }

  /// Whether the Repeated NCs tab is using its own last-six-months window.
  bool get repeatsUseDefaultWindow => !hasDateFilter;

  /// The first page of Repeated NCs groups (or the next one, [more]) under the
  /// current filters and "min. times" pick.
  Future<void> fetchRepeats({bool more = false}) async {
    final epoch = _epoch;
    final seq = ++_repeatsSeq;
    bool stale() => epoch != _epoch || seq != _repeatsSeq;
    final page = more ? (repeatRows.length ~/ _repeatsPageSize) + 1 : 1;
    if (more) {
      isLoadingMoreRepeats = true;
    } else {
      isLoadingRepeats = true;
      repeatsError = null;
    }
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsRepeats,
        queryParameters: {...repeatParams, 'page': page, 'limit': _repeatsPageSize},
      );
      if (stale()) return;
      final data = res.data['data'];
      final rows = data is Map ? (data['rows'] as List? ?? []) : const [];
      final parsed = [
        for (final e in rows)
          ?RepeatGroup.tryParse(e),
      ];
      repeatRows = more ? [...repeatRows, ...parsed] : parsed;
      repeatsTotal = data is Map ? (data['total'] as num?)?.toInt() ?? repeatRows.length : 0;
    } on DioException catch (e) {
      if (!stale()) {
        repeatsError = extractErrorMessage(e, fallback: 'Could not load the repeated NCs.');
      }
    } catch (e, st) {
      debugPrint('NcProvider.fetchRepeats: unreadable answer: $e\n$st');
      if (!stale()) repeatsError = 'Could not load the repeated NCs.';
    } finally {
      if (!stale()) {
        isLoadingRepeats = false;
        isLoadingMoreRepeats = false;
        notifyListeners();
      }
    }
  }

  /// The NCs behind one Repeated NCs row (GET /ncs/repeats/rows) — populated
  /// with their audit, raiser and auditee. Null when the request failed.
  Future<List<NcModel>?> fetchRepeatNcs(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final epoch = _epoch;
    try {
      final res = await _dio.get(
        ApiConstants.ncsRepeatRows,
        queryParameters: {'ids': ids.join(',')},
      );
      if (epoch != _epoch) return null;
      return [
        for (final e in (res.data['data'] as List? ?? []).whereType<Map>())
          NcModel.fromJson(Map<String, dynamic>.from(e)),
      ];
    } on DioException {
      return null;
    } catch (e, st) {
      debugPrint('NcProvider.fetchRepeatNcs: unreadable answer: $e\n$st');
      return null;
    }
  }

  // An NC moved (this person responded, approved or sent one back): the Reports
  // tab follows, straight away when it is showing, else on its next opening.
  void _refreshReports() {
    if (ncReportsInUse) {
      fetchNcReport();
      fetchNcReportStats();
      fetchRepeats();
    } else {
      ncReportsStale = true;
    }
  }

  Future<void> fetchCalendarNcs() async {
    final epoch = _epoch;
    final seq = ++_calendarSeq;
    bool stale() => epoch != _epoch || seq != _calendarSeq;
    isLoadingCalendarNcs = true;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.ncsMine, queryParameters: filterParams);
      if (stale()) return;
      calendarNcs = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (e, st) {
      debugPrint('NcProvider.fetchCalendarNcs: $e\n$st');
    } finally {
      if (!stale()) {
        isLoadingCalendarNcs = false;
        notifyListeners();
      }
    }
  }

  void setActive(NcModel nc) {
    activeNc = nc;
    notifyListeners();
  }

  /// GET /ncs/:id — resolves a single NC by id without needing it to
  /// already be sitting in raisedByMe/raisedAgainstMe. Used to turn a
  /// notification's referenceId (nc.controller.js's nc_raised/nc_approved/
  /// nc_rejected types) into a full NcModel to navigate to (see
  /// notifications_screen.dart). Returns null on failure — the caller
  /// falls back to just leaving the notification marked read — which is also
  /// what an answer that outlived its account gets: null, and no state written.
  Future<NcModel?> fetchById(String id) async {
    final epoch = _epoch;
    try {
      final res = await _dio.get(ApiConstants.ncDetail(id));
      if (epoch != _epoch) return null;
      final nc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      activeNc = nc;
      notifyListeners();
      return nc;
    } on DioException {
      return null;
    } catch (e, st) {
      debugPrint('NcProvider.fetchById: unreadable answer: $e\n$st');
      return null;
    }
  }

  void clearActive() {
    activeNc = null;
  }

  /// Auditee: submit the 4-field corrective-action response (+ optional
  /// photos) — server appends this as a new responseHistory entry
  /// (cycle = reopenCount+1), see nc.controller.js#respondToNC.
  Future<String?> respond({
    required String ncId,
    required String correctionAction,
    required String rootCause,
    required String correctiveAction,
    required String preventiveAction,
    List<File> photos = const [],
    List<String> keepPhotoUrls = const [],
  }) async {
    try {
      // Files are added to form.files below, not via fromMap — a Dart map
      // literal silently collapses duplicate 'photos' keys to the last
      // one, uploading only the last picked photo (see audits_provider.dart).
      // Same reasoning applies to keepPhotoUrls below.
      final form = FormData.fromMap({
        'correctionAction': correctionAction,
        'rootCause': rootCause,
        'correctiveAction': correctiveAction,
        'preventiveAction': preventiveAction,
      });
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
      // Evidence photos carried over from a previous (rejected) attempt
      // that the auditee kept as-is rather than re-uploading — server only
      // honors URLs already on this NC (nc.controller.js#respondToNC).
      for (final url in keepPhotoUrls) {
        form.fields.add(MapEntry('keepPhotoUrls', url));
      }
      final res = await _dio.post(ApiConstants.ncRespond(ncId), data: form);
      activeNc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      notifyListeners();
      _refreshReports();
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not submit your response.',
      );
    } catch (e, st) {
      // A photo that can no longer be read, or a saved-but-unreadable answer:
      // the person still needs to hear the outcome, not be left on a spinner.
      debugPrint('NcProvider.respond failed: $e\n$st');
      return 'Could not submit your response.';
    }
  }

  /// Auditor: approve (closes + scores) or reject (mandatory remark, back
  /// to Raised) — moves a still-"Response Submitted" NC into Verification
  /// first if needed, same as the web review thread does.
  Future<String?> verify({
    required String ncId,
    required bool currentlyResponseSubmitted,
    required String action,
    String? note,
  }) async {
    if (action == 'Reject' && (note == null || note.trim().isEmpty)) {
      return 'A remark is required when rejecting.';
    }
    try {
      if (currentlyResponseSubmitted && !_movedToVerification.contains(ncId)) {
        await _dio.post(ApiConstants.ncMoveToVerification(ncId));
        _movedToVerification.add(ncId);
      }
      final res = await _dio.post(
        ApiConstants.ncVerify(ncId),
        data: {
          'action': action,
          if (note != null && note.trim().isNotEmpty)
            'verificationNote': note.trim(),
        },
      );
      _movedToVerification.remove(ncId);
      activeNc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      notifyListeners();
      fetchRaisedStats();
      _refreshReports();
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update this NC.');
    } catch (e, st) {
      debugPrint('NcProvider.verify failed: $e\n$st');
      return 'Could not update this NC.';
    }
  }
}
