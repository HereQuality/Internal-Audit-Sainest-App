import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/utils/audit_status.dart';
import '../models/audit_model.dart';

/// providers/audits_at_location_list.dart
/// ───────────────────────────────────────
/// The Auditee's "Audit at My Location" tab: every audit scheduled at the places the
/// signed-in person belongs to (or leads) — who is coming to audit, what, where and
/// when — whether or not they are on it. The phone twin of the web's
/// Components/Common/AuditsAtMyLocationSection.jsx, over the SAME endpoint in its
/// paged mode (server: audit.controller.js#getAuditsAtMyLocation / pagedAuditsAtMyLocation):
/// GET /audits/at-my-location?page=&limit=&status=&search=&locationIds=&departmentIds=
/// &auditType=&fromDate=&toDate= answers `{audits, total, page, pages, limit}` with ONE
/// ROW PER AUDIT (a Daily series is a row per occurrence), `total` the number of audits,
/// and a stable date + id order so a page never repeats or drops a row.
///
/// Deliberately separate from AuditsProvider.auditsAtMyLocation, the unpaged list the
/// Calendar's blue markers read (no paging params -> the plain array): that one keeps
/// following the app-wide filters, this one has filters of its own (Location / Department,
/// Audit type, Date range, Status and the search text — Team / Members / Flag mean nothing
/// here).
///
/// Shaped like nc_paged_list.dart#NcPagedList: not a ChangeNotifier, it reports through
/// [onChanged] (its owner, AuditsProvider, notifies) and every call takes a number so an
/// answer that is no longer the newest — or whose account has signed out ([epoch] moved) —
/// is dropped without touching the list, its errors or its loading flags.
///
///  * [loadFirst]      page 1 — on open, on a filter / search change, on pull-to-refresh.
///                     The rows already on screen STAY until the answer lands (the screen
///                     dims them); a failure for another query than they answer clears
///                     them and sets [error], for the same one keeps them with [error].
///  * [loadMore]       the next page, appended — the screen asks near the end of the list.
///  * [refreshLoaded]  the pages already on screen re-read and swapped in at once, no
///                     spinner — a live update (an `audit_` notification), so the scroll
///                     position survives.

/// What the tab lists until another Status is picked: the audits still to come, nearest
/// first. Widening it adds the finished / skipped ones (listed newest first then).
const kAtLocationDefaultStatuses = [
  AuditStatus.notStarted,
  AuditStatus.inProgress,
  AuditStatus.overdue,
];

/// Every Status the tab offers: the eight pipeline statuses and Skipped. A live Instant
/// Audit (stored Draft) is nobody's plan yet and is never listed.
const kAtLocationStatusOptions = [...AuditStatus.pipeline, AuditStatus.skipped];

/// The tab's own filters. Statuses empty = "All statuses": it is sent spelled out
/// ([sentStatuses]) because with NO `status` param the server falls back to its
/// open-audits default.
@immutable
class AtLocationFilters {
  const AtLocationFilters({
    this.locationIds = const [],
    this.departmentIds = const [],
    this.auditTypes = const [],
    this.dateFrom,
    this.dateTo,
    this.statuses = kAtLocationDefaultStatuses,
  });

  final List<String> locationIds;
  final List<String> departmentIds;

  /// Audit type NAMES (the server matches Audit.auditType, a plain string).
  final List<String> auditTypes;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final List<String> statuses;

  static final _day = DateFormat('yyyy-MM-dd');

  bool get statusIsDefault =>
      statuses.length == kAtLocationDefaultStatuses.length && statuses.every(kAtLocationDefaultStatuses.contains);

  /// Nothing narrows or widens the list: the resting state.
  bool get isDefault =>
      locationIds.isEmpty &&
      departmentIds.isEmpty &&
      auditTypes.isEmpty &&
      dateFrom == null &&
      dateTo == null &&
      statusIsDefault;

  /// How many of the filters are on — the badge on the Filters button (Location and
  /// Department are one "where" facet, like the sheet counts them).
  int get activeCount =>
      (locationIds.isNotEmpty || departmentIds.isNotEmpty ? 1 : 0) +
      (auditTypes.isNotEmpty ? 1 : 0) +
      (dateFrom != null || dateTo != null ? 1 : 0) +
      (statusIsDefault ? 0 : 1);

  /// The statuses the request names: the pick, or every one for "All".
  List<String> get sentStatuses => statuses.isEmpty ? kAtLocationStatusOptions : statuses;

  Map<String, dynamic> toParams() => {
    if (locationIds.isNotEmpty) 'locationIds': locationIds.join(','),
    if (departmentIds.isNotEmpty) 'departmentIds': departmentIds.join(','),
    if (auditTypes.isNotEmpty) 'auditType': auditTypes.join(','),
    if (dateFrom != null) 'fromDate': _day.format(dateFrom!),
    if (dateTo != null) 'toDate': _day.format(dateTo!),
    'status': sentStatuses.join(','),
  };

  AtLocationFilters copyWith({
    List<String>? locationIds,
    List<String>? departmentIds,
    List<String>? auditTypes,
    (DateTime?, DateTime?)? dateRange,
    List<String>? statuses,
  }) => AtLocationFilters(
    locationIds: locationIds ?? this.locationIds,
    departmentIds: departmentIds ?? this.departmentIds,
    auditTypes: auditTypes ?? this.auditTypes,
    dateFrom: dateRange != null ? dateRange.$1 : dateFrom,
    dateTo: dateRange != null ? dateRange.$2 : dateTo,
    statuses: statuses ?? this.statuses,
  );

  /// Identity of the query (order of a multi-pick does not matter).
  String get key {
    String sorted(List<String> l) => ([...l]..sort()).join(',');
    return [
      sorted(locationIds),
      sorted(departmentIds),
      sorted(auditTypes),
      dateFrom == null ? '' : _day.format(dateFrom!),
      dateTo == null ? '' : _day.format(dateTo!),
      sorted(statuses),
    ].join('|');
  }

  @override
  bool operator ==(Object other) => other is AtLocationFilters && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class AuditsAtLocationList {
  AuditsAtLocationList({required this.dio, required this.epoch, required this.onChanged});

  /// Audits per page — the web table asks for 10; a phone card is taller than a row but a
  /// scroll-loaded page of 20 keeps the requests few (the NC lists page by 20 too).
  static const pageSize = 20;
  static const failure = 'Could not load the audits at your locations.';

  final Dio dio;

  /// The owner's sign-out counter: a request that finds it changed is stale.
  final int Function() epoch;
  final VoidCallback onChanged;

  /// The rows loaded so far (pages 1..N appended), in the server's order.
  List<AuditModel> items = [];

  /// How many audits the server says match — the true count, however many are loaded.
  int? total;
  bool hasMore = false;

  /// A first page (or a reload) is on its way / the next page is.
  bool isLoading = false;
  bool isLoadingMore = false;

  /// The first page could not be read / the next one could not.
  String? error;
  String? moreError;

  AtLocationFilters filters = const AtLocationFilters();
  String search = '';

  /// How many first pages have landed — a screen that sees it move knows the list was
  /// replaced and scrolls back to the top.
  int firstPageCount = 0;

  /// The tab is on screen: a live update (an `audit_` notification) refreshes it. Set by
  /// the screen; a tab nobody opened never reads the server.
  bool inUse = false;

  String? _itemsKey;
  int _seq = 0;
  int _pages = 0;
  bool _refreshing = false;

  String get _key => '${filters.key}#$search';

  /// Whether [items] answer the current filters and search (false right after they
  /// moved, until the new first page lands).
  bool get hasLoaded => _itemsKey == _key;

  /// Anything narrows or widens the list beyond the default.
  bool get isNarrowed => !filters.isDefault || search.isNotEmpty;

  /// Sets the filters and/or the search text; true when either moved. What was loaded
  /// belongs to the previous query, so an answer still on its way for it is ignored and
  /// the rows stay (dimmed by the screen) until the caller's [loadFirst] lands.
  bool setQuery({AtLocationFilters? filters, String? search}) {
    final nextFilters = filters ?? this.filters;
    final nextSearch = (search ?? this.search).trim();
    if (nextFilters == this.filters && nextSearch == this.search) return false;
    this.filters = nextFilters;
    this.search = nextSearch;
    _seq++;
    isLoading = false;
    isLoadingMore = false;
    _refreshing = false;
    error = null;
    moreError = null;
    hasMore = false;
    return true;
  }

  /// Back to empty and to the default query — on logout.
  void reset() {
    _seq++;
    items = [];
    total = null;
    hasMore = false;
    isLoading = false;
    isLoadingMore = false;
    _refreshing = false;
    error = null;
    moreError = null;
    filters = const AtLocationFilters();
    search = '';
    _itemsKey = null;
    _pages = 0;
    inUse = false;
  }

  // ── requests ────────────────────────────────────────────────────────────

  Future<({List<AuditModel> rows, int total, int page, bool hasMore})> _read(int page) async {
    final res = await dio.get(
      ApiConstants.auditsAtMyLocation,
      queryParameters: {
        ...filters.toParams(),
        if (search.isNotEmpty) 'search': search,
        'page': page,
        'limit': pageSize,
      },
    );
    final data = res.data['data'];
    final Iterable<dynamic> raw;
    int? total;
    int? served;
    int size = pageSize;
    var plain = false;
    if (data == null) {
      raw = const [];
      plain = true;
    } else if (data is List) {
      // No paging answered with the whole list (an older server): that is everything there is.
      raw = data;
      plain = true;
    } else if (data is Map) {
      raw = (data['audits'] as List?) ?? const [];
      total = (data['total'] as num?)?.toInt();
      served = (data['page'] as num?)?.toInt();
      size = (data['limit'] as num?)?.toInt() ?? pageSize;
    } else {
      throw const FormatException('Unexpected audits-at-my-location answer');
    }
    final rows = [
      for (final e in raw)
        if (e is Map) AuditModel.fromJson(Map<String, dynamic>.from(e)),
    ];
    final count = plain ? rows.length : (total ?? rows.length);
    final servedPage = served ?? page;
    return (
      rows: rows,
      total: count,
      page: servedPage,
      // An empty page ends the list however large `total` claims to be, and so does an answer for
      // another page than asked (the server serves the LAST page for one past the end).
      hasMore: !plain && rows.isNotEmpty && servedPage == page && page * size < count,
    );
  }

  /// Page 1 under the current filters and search — replaces the list. The rows on
  /// screen stay until the answer lands.
  Future<void> loadFirst() async {
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    final key = _key;
    isLoading = true;
    error = null;
    // A next page or a live refresh that was on its way is superseded.
    isLoadingMore = false;
    moreError = null;
    _refreshing = false;
    onChanged();
    try {
      final r = await _read(1);
      if (stale()) return;
      items = _unique(r.rows);
      total = r.total;
      hasMore = r.hasMore;
      _pages = 1;
      _itemsKey = key;
      firstPageCount++;
    } on DioException catch (e) {
      if (!stale()) _failed(key, extractErrorMessage(e, fallback: failure));
    } catch (e, st) {
      // An answer the model cannot read must end the loading state and say so, not escape
      // as an unhandled error from a fire-and-forget fetch.
      debugPrint('AuditsAtLocationList.loadFirst: unreadable answer: $e\n$st');
      if (!stale()) _failed(key, failure);
    } finally {
      if (!stale()) {
        isLoading = false;
        onChanged();
      }
    }
  }

  // A first page that could not be read: rows that answer ANOTHER query are not shown under
  // this one's filters (they go), rows of the same query (a pull-to-refresh) stay with the error.
  void _failed(String key, String message) {
    error = message;
    if (_itemsKey != key) {
      items = [];
      total = null;
      hasMore = false;
      _pages = 0;
      _itemsKey = null;
    }
  }

  /// The next page, appended. Does nothing while a page is already loading, when
  /// everything is loaded, and — unless [retry] — after a failure (so a scroll listener
  /// cannot hammer a server that is down; the footer's "Try again" passes it).
  Future<void> loadMore({bool retry = false}) async {
    if (isLoading || isLoadingMore || _refreshing || !hasMore || !hasLoaded) return;
    if (moreError != null && !retry) return;
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    isLoadingMore = true;
    moreError = null;
    onChanged();
    try {
      final next = _pages + 1;
      final r = await _read(next);
      if (stale()) return;
      items = _unique([...items, ...r.rows]);
      total = r.total;
      hasMore = r.hasMore;
      if (r.page == next) _pages = next;
    } on DioException catch (e) {
      if (!stale()) moreError = extractErrorMessage(e, fallback: 'Could not load more audits.');
    } catch (e, st) {
      debugPrint('AuditsAtLocationList.loadMore: unreadable answer: $e\n$st');
      if (!stale()) moreError = 'Could not load more audits.';
    } finally {
      if (!stale()) {
        isLoadingMore = false;
        onChanged();
      }
    }
  }

  /// Re-reads the pages that are on screen (1..N) and swaps them in at once. Quiet: no
  /// loading flag, and a failure keeps what is shown. With nothing loaded yet it is a
  /// first page.
  Future<void> refreshLoaded() async {
    if (isLoading) return; // a first page is on its way and will be the freshest
    if (!hasLoaded) return loadFirst();
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    final hadMore = isLoadingMore;
    isLoadingMore = false;
    _refreshing = true;
    if (hadMore) onChanged();
    try {
      var rows = <AuditModel>[];
      var count = total ?? 0;
      var more = false;
      var pages = 0;
      for (var page = 1; page <= math.max(_pages, 1); page++) {
        final r = await _read(page);
        if (stale()) return;
        // The list shrank under the pages on screen: the server served the last page instead.
        if (r.page != page) break;
        rows = [...rows, ...r.rows];
        count = r.total;
        more = r.hasMore;
        pages = page;
        if (!more) break;
      }
      if (stale()) return;
      items = _unique(rows);
      total = count;
      hasMore = more;
      _pages = math.max(pages, 1);
      error = null;
      moreError = null;
    } catch (e, st) {
      debugPrint('AuditsAtLocationList.refreshLoaded: kept what is shown: $e\n$st');
    } finally {
      if (!stale()) {
        _refreshing = false;
        onChanged();
      }
    }
  }

  // A row seen twice (a page that moved under a live update) is listed once.
  static List<AuditModel> _unique(List<AuditModel> rows) {
    final seen = <String>{};
    return [
      for (final a in rows)
        if (seen.add(a.id)) a,
    ];
  }
}
