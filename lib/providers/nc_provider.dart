import 'dart:async';
import 'dart:convert';
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
import 'nc_paged_list.dart';

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
  // reasoning (a Full Access account's All Members default included) and for
  // the _selfEmployeeId-must-be-set-first caveat.
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
    // The two NC lists restart at page 1 (a different filter is a different list).
    return Future.wait([
      fetchRaisedByMe(),
      fetchRaisedStats(),
      fetchAgainstMe(),
      if (againstMeAllInUse) fetchAgainstMeAll(),
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
  // each fetch may write its result, error or loading flag. (The three paged
  // NC lists below keep their own, see NcPagedList.)
  int _raisedStatsSeq = 0;
  int _againstMeAllSeq = 0;
  int _calendarSeq = 0;
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
    raisedList.reset();
    mineList.reset();
    againstMeAll = [];
    againstMeAllInUse = false;
    calendarNcs = [];
    calendarInUse = false;
    isLoadingCalendarNcs = false;
    raisedStats = null;
    isLoadingRaisedStats = false;
    _raisedStatsLoader.clear();
    _mineStatsLoader.clear();
    _reportStatsLoader.clear();
    reportList.reset();
    _dropPlaceLists();
    ncReportStats = null;
    isLoadingNcReportStats = false;
    ncReportsInUse = false;
    ncReportsStale = false;
    ncReportByLocation = false;
    repeatRows = [];
    repeatsTotal = 0;
    repeatsMinCount = 2;
    repeatsError = null;
    repeatsMoreError = null;
    repeatsHasMore = false;
    _repeatsPagesRead = 0;
    _repeatsRefreshing = false;
    isLoadingRepeats = false;
    isLoadingMoreRepeats = false;
    activeNc = null;
    _movedToVerification.clear();
    isLoadingDetail = false;
    // Filters back to the Me default (also notifies).
    super.resetForLogout();
  }

  // ── The three paged NC lists ────────────────────────────────────────────
  // NC Monitoring's "raised by me", the auditee's "against me" and the Final
  // Report's NCs tab each load ONE page (NcPagedList.pageSize) at a time and
  // append the next as the screen scrolls near the end; the status chip, tile
  // picks and search text go to the server, so `total` is the true count of
  // what is being looked at. The old list/loading/error fields stay as getters.

  late final NcPagedList raisedList = NcPagedList(
    dio: _dio,
    path: ApiConstants.ncsRaised,
    raised: true,
    failure: 'Could not load raised NCs.',
    filters: () => ncFilterParams,
    epoch: () => _epoch,
    onChanged: notifyListeners,
    loadStats: _raisedStatsFor,
    // /ncs/raised/stats takes `search`: a bucket chip + search narrows the ids.
    statsHaveSearch: true,
    pager: true,
  );

  late final NcPagedList mineList = NcPagedList(
    dio: _dio,
    path: ApiConstants.ncsMine,
    raised: false,
    failure: 'Could not load your NCs.',
    filters: () => ncFilterParams,
    epoch: () => _epoch,
    onChanged: notifyListeners,
    loadStats: _mineStatsFor,
    pager: true,
  );

  late final NcPagedList reportList = NcPagedList(
    dio: _dio,
    path: ApiConstants.ncsReport,
    failure: 'Could not load the NCs.',
    filters: () => ncFilterParams,
    epoch: () => _epoch,
    onChanged: notifyListeners,
    loadStats: _reportStatsFor,
    statsHaveSearch: true,
    // A page is `limit` whole AUDITS (every matching NC of each), so the NCs of
    // one audit always arrive together and the tab can show them as one bundle.
    pageParams: const {'groupBy': 'audit'},
    pager: true,
  );

  /// What the screens (and the old tests) read: the loaded rows of each list.
  List<NcModel> get raisedByMe => raisedList.items;
  bool get isLoadingRaised => raisedList.isLoading;
  String? get raisedError => raisedList.error;

  List<NcModel> get raisedAgainstMe => mineList.items;
  bool get isLoadingMine => mineList.isLoading;
  String? get mineError => mineList.error;

  /// EVERY NC raised against me under the shared filters (not paged) — the
  /// auditee dashboard's "What needs attention" panel counts and buckets the whole
  /// list, so it must not be the page of NCs the "Against me" screen shows.
  /// [againstMeAllInUse] keeps it following filter changes and live updates once
  /// the dashboard has asked for it.
  bool againstMeAllInUse = false;
  List<NcModel> againstMeAll = [];

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
  /// NCs (the server's `onlyIds`), while the tiles keep the whole set. A tile pick
  /// narrows the PAGED list too: its NCs are read by the ids the tile counted, a
  /// page at a time. Both live on [reportList]; setting one drops what it had
  /// loaded (the caller's [fetchNcReport] reads page 1 again).
  String get ncReportSearch => reportList.search;
  set ncReportSearch(String value) => reportList.setNarrowing(search: value);
  Set<String> get ncReportTileKeys => reportList.tiles;
  set ncReportTileKeys(Set<String> value) => reportList.setNarrowing(tiles: value);
  bool ncReportByLocation = false;

  bool get isLoadingNcReport => reportList.isLoading;
  String? get ncReportError => reportList.error;

  /// The NCs of the page(s) loaded so far — one page (20 audits, every NC of
  /// each) at a time, [fetchNcReport] then [reportList]`.loadMore()`.
  List<NcModel> get reportNcs => reportList.items;

  /// How many NCs and how many audits the filters match (GET /ncs/report with
  /// groupBy=audit: `totalNcs` and `total`) — the count line's numbers, true even
  /// when fewer rows were loaded. Null until the first answer; the audit count is
  /// also null while a tile pick is read by id (the server counts audits only for
  /// its own pages).
  int? get ncReportTotalNcs => reportList.totalNcs;
  int? get ncReportTotalAudits => reportList.idsMode ? null : reportList.total;
  NcTileStats? ncReportStats;
  bool isLoadingNcReportStats = false;

  /// The location-wise view's lists: ONE per place that was opened, each reading
  /// just that place's NCs (the ids its header counted) a page at a time. Dropped
  /// when the filters, the search or the tile picks move (the places themselves
  /// change then), refreshed in place on a live update.
  final Map<String, NcPagedList> _placeLists = {};

  NcPagedList ncReportPlaceList(String placeKey) => _placeLists.putIfAbsent(
    placeKey,
    () => NcPagedList(
      dio: _dio,
      path: ApiConstants.ncsReport,
      failure: 'Could not load the NCs.',
      filters: () => ncFilterParams,
      epoch: () => _epoch,
      onChanged: notifyListeners,
      fixedIds: () => _placeNcIds(placeKey),
      statsHaveSearch: true,
    ),
  );

  /// The place's list when it exists (a scroll handler asking must not create one).
  NcPagedList? peekNcReportPlaceList(String placeKey) => _placeLists[placeKey];

  // A place's NCs from the server's byLocation tally — with tiles picked, only
  // those the tiles counted (the place numbers were narrowed by the second stats
  // request, and this keeps the rows right even when that request failed).
  List<String>? _placeNcIds(String placeKey) {
    final stats = ncReportStats;
    if (stats == null) return null;
    NcLocationStats? place;
    for (final p in stats.byLocation) {
      if (p.key == placeKey) place = p;
    }
    if (place == null) return const [];
    final picks = ncReportTileKeys;
    if (picks.isEmpty) return place.ncIds;
    final picked = {for (final k in picks) ...stats.idsFor(k)};
    return [for (final id in place.ncIds) if (picked.contains(id)) id];
  }

  void _dropPlaceLists() {
    for (final list in _placeLists.values) {
      list.reset();
    }
    _placeLists.clear();
  }

  // The same pages again, in place: no spinner, the scroll position survives.
  void _refreshPlaceLists() {
    for (final list in _placeLists.values) {
      if (list.hasLoaded) list.refreshLoaded();
    }
  }

  /// The Repeated NCs tab: the "min. times" pick (2, 3, 4, 5, 10), the groups
  /// loaded so far (paged — [repeatsTotal] is how many there are, [repeatsHasMore]
  /// whether a next page is left) and its state.
  int repeatsMinCount = 2;
  List<RepeatGroup> repeatRows = [];
  int repeatsTotal = 0;
  bool repeatsHasMore = false;
  bool isLoadingRepeats = false;
  bool isLoadingMoreRepeats = false;
  String? repeatsError;
  String? repeatsMoreError;

  /// How many first pages of repeats have landed — a tab that sees it move knows
  /// the list was replaced (a filter or the min. times moved) and scrolls to the top.
  int repeatsFirstPageCount = 0;
  static const _repeatsPageSize = 30;
  static const repeatsPageSize = _repeatsPageSize;
  // Server pages read so far — counted, not worked out from how many rows are
  // loaded (a row that cannot be read would throw the next page's number off).
  int _repeatsPagesRead = 0;
  bool _repeatsRefreshing = false;

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
  /// responded, approved, rejected) refreshes both lists so a screen
  /// showing them reflects the change live, without a manual pull-to-refresh —
  /// the pages already loaded are re-read and swapped in place (no spinner, the
  /// scroll position stays), not collapsed back to page 1.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map && (data['type']?.toString() ?? '').startsWith('nc_')) {
        // A burst of notifications refetches once, not once each.
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 500), () {
          refreshRaisedByMe();
          fetchRaisedStats();
          refreshAgainstMe();
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

  // ── NC Monitoring (auditor) and Against me (auditee) ───────────────────

  /// The first page of "NCs I raised" under the current filters, chip and
  /// search — what a filter change, a pull-to-refresh and the screen's first
  /// opening ask for. [fresh] false lets a bucket chip re-use the tile ids it
  /// already holds (a chip or search change), true asks for them again.
  Future<void> fetchRaisedByMe({bool fresh = true}) => raisedList.loadFirst(fresh: fresh);

  /// The pages already loaded, re-read in place — after an NC was approved or
  /// rejected, and on a live update. Keeps the scroll position.
  Future<void> refreshRaisedByMe() => raisedList.refreshLoaded();

  /// The first page of "NCs raised against me" (see [fetchRaisedByMe]).
  Future<void> fetchAgainstMe({bool fresh = true}) => mineList.loadFirst(fresh: fresh);

  /// The pages already loaded, re-read in place; also the dashboard's whole list
  /// when it has asked for one.
  Future<void> refreshAgainstMe() => Future.wait([
    mineList.refreshLoaded(),
    if (againstMeAllInUse) fetchAgainstMeAll(),
  ]);

  /// NC Monitoring just opened: a list that already holds what the screen was
  /// left showing (same chip and search) is refreshed in place — its scroll
  /// position is still good — else the first page is read.
  Future<void> openRaised() => raisedList.hasLoaded ? raisedList.refreshLoaded() : raisedList.loadFirst();

  /// The Against me screen just opened (see [openRaised]).
  Future<void> openAgainstMe() => mineList.hasLoaded ? mineList.refreshLoaded() : mineList.loadFirst();

  /// EVERY NC raised against me (GET /ncs/mine without page/limit, the whole
  /// array) under the same filters — for the auditee dashboard's "What needs
  /// attention" panel, which counts and buckets all of them. Quiet on failure:
  /// the panel just keeps what it had.
  Future<void> fetchAgainstMeAll() async {
    againstMeAllInUse = true;
    final epoch = _epoch;
    final seq = ++_againstMeAllSeq;
    bool stale() => epoch != _epoch || seq != _againstMeAllSeq;
    try {
      final res = await _dio.get(ApiConstants.ncsMine, queryParameters: ncFilterParams);
      if (stale()) return;
      againstMeAll = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notifyListeners();
    } on DioException {
      // keep the list as it was
    } catch (e, st) {
      debugPrint('NcProvider.fetchAgainstMeAll: unreadable answer: $e\n$st');
    }
  }

  // The tile stats behind each bucket, one request at a time per query and kept
  // for the next chip / tile tap (see NcStatsLoader).
  final NcStatsLoader _raisedStatsLoader = NcStatsLoader();
  final NcStatsLoader _mineStatsLoader = NcStatsLoader();
  final NcStatsLoader _reportStatsLoader = NcStatsLoader();

  String _statsKey(Map<String, dynamic>? params) => jsonEncode(params ?? const {});

  Future<NcTileStats?> _requestStats(String path, Map<String, dynamic>? params) async {
    final res = await _dio.get(path, queryParameters: params);
    return NcTileStats.tryParse(res.data['data']);
  }

  Map<String, dynamic>? _withSearch(Map<String, dynamic>? params, String search) {
    if (search.isEmpty) return params;
    return {...?params, 'search': search};
  }

  // The ids a bucket chip / tile of NC Monitoring reads: /ncs/raised/stats under
  // the list's filters, narrowed by the search text too.
  Future<NcTileStats?> _raisedStatsFor({required bool fresh, required String search}) {
    final params = _withSearch(ncFilterParams, search);
    return _raisedStatsLoader.get(
      _statsKey(params),
      () => _requestStats(ApiConstants.ncsRaisedStats, params),
      fresh: fresh,
    );
  }

  // The auditee side's buckets: /ncs/ats-summary sends the same five ids lists
  // (it has no search, so the list narrows by search itself).
  Future<NcTileStats?> _mineStatsFor({required bool fresh, required String search}) {
    final params = ncFilterParams;
    return _mineStatsLoader.get(
      _statsKey(params),
      () => _requestStats(ApiConstants.ncsAtsSummary, params),
      fresh: fresh,
    );
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
      stats = await _raisedStatsFor(fresh: true, search: '');
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
  Map<String, dynamic> get _ncReportParams => _withSearch(ncFilterParams, ncReportSearch) ?? {};

  // The ids a tile pick of the Final Report reads, and the tiles themselves:
  // /ncs/report/stats under the filters and the search text.
  Future<NcTileStats?> _reportStatsFor({required bool fresh, required String search}) {
    final params = _withSearch(ncFilterParams, search);
    return _reportStatsLoader.get(
      _statsKey(params),
      () => _requestStats(ApiConstants.ncsReportStats, params),
      fresh: fresh,
    );
  }

  /// The Reports tab's NC list — ONE page of GET /ncs/report (20 audits) under the
  /// current filters, search and tile picks; the next pages are
  /// [reportList]`.loadMore()`, called as the tab scrolls near its end.
  ///
  /// Paged with `groupBy=audit`: a page is `limit` whole AUDITS (every matching NC
  /// of each), `total` counts audits and `totalNcs` the NCs, so the several NCs of
  /// one audit always arrive together and the tab can show them as one bundle.
  /// With tiles picked the list is read by the ids the tiles counted instead
  /// (the server pages by audit only without `ids`), 20 at a time, and the tab
  /// groups what has arrived. Reading page 1 again drops the location-wise
  /// view's per-place lists (they follow the same filters).
  Future<void> fetchNcReport({bool fresh = true}) async {
    _dropPlaceLists();
    await reportList.loadFirst(fresh: fresh);
    if (reportList.hasLoaded && reportList.error == null) ncReportsStale = false;
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
      stats = await _reportStatsFor(fresh: true, search: ncReportSearch);
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
    // The places may have moved: the ones already opened re-read their pages.
    _refreshPlaceLists();
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

  Future<({List<RepeatGroup> rows, int? total, int read})> _requestRepeats(int page) async {
    final res = await _dio.get(
      ApiConstants.ncsRepeats,
      queryParameters: {...repeatParams, 'page': page, 'limit': _repeatsPageSize},
    );
    final data = res.data['data'];
    final raw = data is Map ? (data['rows'] as List? ?? []) : const [];
    return (
      rows: [
        for (final e in raw)
          ?RepeatGroup.tryParse(e),
      ],
      total: data is Map ? (data['total'] as num?)?.toInt() : null,
      read: raw.length,
    );
  }

  /// The first page of Repeated NCs groups under the current filters and "min.
  /// times" pick — or, with [more], the next one (the tab calls it as it scrolls
  /// near its end; [retry] is the footer's "Try again" after a failed page).
  Future<void> fetchRepeats({bool more = false, bool retry = false}) async {
    if (more) return _fetchMoreRepeats(retry: retry);
    final epoch = _epoch;
    final seq = ++_repeatsSeq;
    bool stale() => epoch != _epoch || seq != _repeatsSeq;
    isLoadingRepeats = true;
    repeatsError = null;
    // A next page or a live refresh that was on its way is superseded.
    isLoadingMoreRepeats = false;
    repeatsMoreError = null;
    _repeatsRefreshing = false;
    notifyListeners();
    try {
      final r = await _requestRepeats(1);
      if (stale()) return;
      final seen = <String>{};
      repeatRows = [
        for (final g in r.rows)
          if (seen.add(g.key)) g,
      ];
      repeatsTotal = r.total ?? repeatRows.length;
      _repeatsPagesRead = 1;
      repeatsFirstPageCount++;
      // An empty page ends the list however large `total` claims to be.
      repeatsHasMore = r.read > 0 && _repeatsPageSize < repeatsTotal;
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
        notifyListeners();
      }
    }
  }

  // The next page, appended. Never while a page is already loading, when everything
  // is loaded, and — unless [retry] — after a failure (a scroll listener must not
  // hammer a server that is down).
  Future<void> _fetchMoreRepeats({required bool retry}) async {
    if (isLoadingRepeats || isLoadingMoreRepeats || _repeatsRefreshing || !repeatsHasMore) return;
    if (repeatsMoreError != null && !retry) return;
    final epoch = _epoch;
    final seq = ++_repeatsSeq;
    bool stale() => epoch != _epoch || seq != _repeatsSeq;
    isLoadingMoreRepeats = true;
    repeatsMoreError = null;
    notifyListeners();
    try {
      final page = _repeatsPagesRead + 1;
      final r = await _requestRepeats(page);
      if (stale()) return;
      final seen = {for (final g in repeatRows) g.key};
      repeatRows = [
        ...repeatRows,
        for (final g in r.rows)
          if (seen.add(g.key)) g,
      ];
      repeatsTotal = r.total ?? repeatsTotal;
      _repeatsPagesRead = page;
      repeatsHasMore = r.read > 0 && page * _repeatsPageSize < repeatsTotal;
    } on DioException catch (e) {
      if (!stale()) {
        repeatsMoreError = extractErrorMessage(e, fallback: 'Could not load more repeated NCs.');
      }
    } catch (e, st) {
      debugPrint('NcProvider.fetchMoreRepeats: unreadable answer: $e\n$st');
      if (!stale()) repeatsMoreError = 'Could not load more repeated NCs.';
    } finally {
      if (!stale()) {
        isLoadingMoreRepeats = false;
        notifyListeners();
      }
    }
  }

  /// The page on screen (1-based) and how many pages [repeatsTotal] makes — the Repeated
  /// NCs tab shows ONE page at a time (Prev/Next, [goToRepeatsPage]).
  int get repeatsPage => _repeatsPagesRead < 1 ? 1 : _repeatsPagesRead;
  int get repeatsTotalPages => repeatsTotal <= 0 ? 1 : (repeatsTotal / _repeatsPageSize).ceil();

  /// Shows page [page] (clamped) in place of the one on screen. The rows shown stay until
  /// the page lands; a failure keeps them and sets [repeatsMoreError]. [isLoadingMoreRepeats]
  /// is "a page is on its way". A new page counts as a new first page for the screen
  /// ([repeatsFirstPageCount]): it starts from the top.
  Future<void> goToRepeatsPage(int page) async {
    if (isLoadingRepeats || isLoadingMoreRepeats || _repeatsRefreshing || _repeatsPagesRead == 0) return;
    final target = page.clamp(1, repeatsTotalPages);
    if (target == repeatsPage) return;
    final epoch = _epoch;
    final seq = ++_repeatsSeq;
    bool stale() => epoch != _epoch || seq != _repeatsSeq;
    isLoadingMoreRepeats = true;
    repeatsMoreError = null;
    notifyListeners();
    try {
      var page = target;
      var r = await _requestRepeats(page);
      if (stale()) return;
      // The total shrank since: land on the last real page rather than an empty one.
      if (r.rows.isEmpty && page > 1 && (r.total ?? 0) > 0) {
        page = (r.total! / _repeatsPageSize).ceil();
        r = await _requestRepeats(page);
        if (stale()) return;
      }
      final seen = <String>{};
      repeatRows = [
        for (final g in r.rows)
          if (seen.add(g.key)) g,
      ];
      repeatsTotal = r.total ?? repeatsTotal;
      _repeatsPagesRead = page;
      repeatsFirstPageCount++;
      repeatsHasMore = r.read > 0 && page * _repeatsPageSize < repeatsTotal;
    } on DioException catch (e) {
      if (!stale()) repeatsMoreError = extractErrorMessage(e, fallback: 'Could not load that page.');
    } catch (e, st) {
      debugPrint('NcProvider.goToRepeatsPage: unreadable answer: $e\n$st');
      if (!stale()) repeatsMoreError = 'Could not load that page.';
    } finally {
      if (!stale()) {
        isLoadingMoreRepeats = false;
        notifyListeners();
      }
    }
  }

  /// The page on screen, re-read and swapped in at once (a live update: no spinner, the
  /// scroll position stays); a failure keeps what is shown.
  Future<void> refreshRepeats() async {
    if (isLoadingRepeats) return; // a first page is on its way and is the freshest
    if (_repeatsPagesRead == 0) return fetchRepeats();
    final epoch = _epoch;
    final seq = ++_repeatsSeq;
    bool stale() => epoch != _epoch || seq != _repeatsSeq;
    final hadMore = isLoadingMoreRepeats;
    isLoadingMoreRepeats = false;
    _repeatsRefreshing = true;
    if (hadMore) notifyListeners();
    try {
      var page = _repeatsPagesRead;
      var r = await _requestRepeats(page);
      if (stale()) return;
      // The page on screen is past the end now (rows gone since): land on the last real one.
      if (r.rows.isEmpty && page > 1 && (r.total ?? 0) > 0) {
        page = (r.total! / _repeatsPageSize).ceil();
        r = await _requestRepeats(page);
        if (stale()) return;
      }
      final seen = <String>{};
      repeatRows = [
        for (final g in r.rows)
          if (seen.add(g.key)) g,
      ];
      repeatsTotal = r.total ?? repeatRows.length;
      _repeatsPagesRead = page;
      repeatsHasMore = r.read > 0 && page * _repeatsPageSize < repeatsTotal;
    } catch (e, st) {
      debugPrint('NcProvider.refreshRepeats: kept what is shown: $e\n$st');
    } finally {
      if (!stale()) {
        _repeatsRefreshing = false;
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
      // The pages on screen are re-read in place (no spinner, scroll position kept).
      reportList.refreshLoaded();
      fetchNcReportStats();
      refreshRepeats();
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
      // The Calendar's own scope rule (Me for everybody unless All Members was
      // picked on the Calendar) — see AuditFilterScope.calendarFilterParams.
      final res = await _dio.get(ApiConstants.ncsMine, queryParameters: calendarFilterParams);
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
