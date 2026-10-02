import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/network/dio_client.dart';
import '../models/nc_model.dart';
import '../models/nc_report_model.dart';

/// The list screen's status chips that are DERIVED buckets (the server's own
/// split, utils/ncScoring.js#computeNcBuckets), not a stored NC status. A stored
/// status travels as `status=`; a bucket has no query param of its own, so it
/// travels as the ids the stat tiles already counted under it (`ids=`).
const ncChipBuckets = <String, String>{
  'In Progress': NcBucket.inProgress,
  'Overdue': NcBucket.overdue,
  'Pending Approval': NcBucket.pendingApproval,
  'Delayed': NcBucket.delayed,
  'On Time': NcBucket.onTime,
};

/// The bucket a chip stands for, null for All / Open / Closed / a raw status.
String? ncBucketOfChip(String chip) => ncChipBuckets[chip];

/// What a status chip asks of the server: query [params] for a chip the server
/// can filter on itself, or a [bucket] key for one it can only answer with ids.
class NcChipQuery {
  const NcChipQuery({this.params = const {}, this.bucket});

  final Map<String, dynamic> params;
  final String? bucket;
}

/// One chip -> its server form. Same meaning as the on-device rules the list
/// used to apply to the whole loaded list:
///   All                     nothing
///   Open                    every stored status but Closed (`open=true` where the
///                           endpoint has it — /ncs/mine — else the three statuses)
///   In Progress / Overdue / Pending Approval / Delayed / On Time
///                           a derived bucket -> [NcChipQuery.bucket]
///   anything else           a stored status (Closed, Raised, ...) -> `status=`
NcChipQuery ncChipQuery(String chip, {required bool raised}) {
  if (chip == 'All') return const NcChipQuery();
  final bucket = ncBucketOfChip(chip);
  if (bucket != null) return NcChipQuery(bucket: bucket);
  if (chip == 'Open') {
    return raised
        ? const NcChipQuery(params: {'status': 'Raised,Response Submitted,Verification'})
        : const NcChipQuery(params: {'open': 'true'});
  }
  return NcChipQuery(params: {'status': chip});
}

/// A tile-stats request that several callers share: one request in flight per
/// query at a time (the list's "ids behind this bucket" and the tiles themselves
/// ask for the same numbers within one tick), and the last answer kept so a chip
/// or tile tap re-uses it instead of asking again.
///
/// `key` is whatever distinguishes one query from another (the filter params and
/// the search text); `fresh` skips the kept answer (a pull-to-refresh, a filter
/// change) but still joins a request that is already on its way.
class NcStatsLoader {
  NcTileStats? _value;
  String? _valueKey;
  Future<NcTileStats?>? _flight;
  String? _flightKey;
  int _generation = 0;

  Future<NcTileStats?> get(
    String key,
    Future<NcTileStats?> Function() request, {
    bool fresh = false,
  }) {
    final running = _flight;
    if (running != null && _flightKey == key) return running;
    if (!fresh && _value != null && _valueKey == key) return Future.value(_value);
    final generation = _generation;
    late final Future<NcTileStats?> flight;
    flight = request()
        .then((stats) {
          if (stats != null && generation == _generation) {
            _value = stats;
            _valueKey = key;
          }
          return stats;
        })
        .whenComplete(() {
          if (identical(_flight, flight)) {
            _flight = null;
            _flightKey = null;
          }
        });
    _flight = flight;
    _flightKey = key;
    return flight;
  }

  /// Forgets the kept answer and lets a request still on the wire land unseen
  /// (logout).
  void clear() {
    _generation++;
    _value = null;
    _valueKey = null;
    _flight = null;
    _flightKey = null;
  }
}

class _Snap {
  const _Snap({
    this.items = const <NcModel>[],
    this.total,
    this.totalNcs,
    this.pages = 0,
    this.ids,
    this.cursor = 0,
    this.hasMore = true,
  });

  final List<NcModel> items;
  final int? total;
  final int? totalNcs;
  // Server pages read so far (plain mode)...
  final int pages;
  // ...or, for a bucket chip / tile pick / a fixed set, the ids to read and how
  // many were read (ids mode).
  final List<String>? ids;
  final int cursor;
  final bool hasMore;
}

/// The tile stats a bucket narrowing is answered from: [search] is only a
/// request to narrow the ids by it too (when the endpoint can).
typedef NcStatsSource = Future<NcTileStats?> Function({required bool fresh, required String search});

/// One NC list (NC Monitoring's "raised by me", the auditee's "against me", the
/// Final Report's NCs tab, or one place of its location-wise view) that loads ONE
/// page of [pageSize] at a time.
///
///  * [loadFirst]      page 1 — on open, on a filter / chip / search change, on
///                     pull-to-refresh.
///  * [loadMore]       the next page, appended — the screen calls it as the user
///                     scrolls near the end; guarded so it never runs twice at once
///                     (nor over a failure until [loadMore] is told to `retry`).
///  * [refreshLoaded]  the pages already on screen, re-read and swapped in at once
///                     (no spinner, no flicker) — a live update, so the scroll
///                     position survives.
///
/// The status chip, the tile picks and the search text go to the server
/// (`status`/`open`, `search`; a derived bucket as the `ids` the tiles counted), so
/// a page is always a page of what is being looked at and `total` is the true
/// count. Every call takes a number; an answer whose number is no longer the
/// newest — or whose account has signed out ([epoch] moved) — is dropped without
/// touching the list, its error or its loading flags.
///
/// A bucket chip / tile pick has no query param, so its list is read by `ids`:
/// the ids come from the stats endpoint ([loadStats]), newest first, and are asked
/// for [pageSize] at a time (a short URL however many NCs the bucket holds). A
/// [fixedIds] list (a place of the location-wise view) is read the same way.
class NcPagedList {
  NcPagedList({
    required this.dio,
    required this.path,
    required this.failure,
    required this.filters,
    required this.epoch,
    required this.onChanged,
    this.raised = true,
    this.loadStats,
    this.statsHaveSearch = false,
    this.pageParams = const {},
    this.fixedIds,
    this.pager = false,
  });

  static const pageSize = 20;
  // With a search text a bucket chip whose stats cannot be narrowed by it does not
  // know how many of its ids match, so it reads its ids in bigger slices and keeps
  // going until a page is filled.
  static const _searchSlice = 100;

  final Dio dio;
  final String path;

  /// Auditor side (/ncs/raised) or auditee side (/ncs/mine) — only `Open` differs.
  final bool raised;

  /// The error text of a first page that could not be read.
  final String failure;

  /// The shared filter params (people, place, audit type, dates, flag).
  final Map<String, dynamic>? Function() filters;

  /// The owner's sign-out counter: a request that finds it changed is stale.
  final int Function() epoch;
  final VoidCallback onChanged;

  /// The tile stats (the ids behind each bucket); throws when the request fails.
  /// Null for a list that has no bucket narrowing.
  final NcStatsSource? loadStats;

  /// Whether [loadStats] narrows the ids by the search text itself (the raised
  /// and report stats endpoints take `search`; /ncs/ats-summary does not).
  final bool statsHaveSearch;

  /// Extra params of every plain page (the report's `groupBy=audit`).
  final Map<String, dynamic> pageParams;

  /// A list of exactly these NCs (a place's), read by id; null for a normal list.
  final List<String>? Function()? fixedIds;

  /// Opt-in page mode: the list shows ONE page at a time ([goToPage], Prev/Next on
  /// the screen) instead of appending as the user scrolls. The first page is
  /// page 1; [refreshLoaded] re-reads only the page on screen. Off for a list
  /// that scrolls (the Final Report's NCs tab, a place's NCs).
  final bool pager;

  List<NcModel> items = [];

  /// How many the server says match, in the unit it pages by (null while unknown:
  /// a bucket chip with a search text its stats cannot narrow cannot say until
  /// every one of its ids has been read). With `groupBy=audit` that is AUDITS.
  int? total;

  /// How many NCs match — [total] unless the answer counted something else.
  int? totalNcs;
  bool hasMore = false;

  /// The page on screen (1-based) while a [pager] list can be paged; null when it
  /// scrolls instead — also for a bucket chip with a search its stats cannot
  /// narrow, whose total (so page count) is unknown until every id was read.
  int? windowPage;

  /// Whether the screen should show Prev/Next for this list.
  bool get pagerMode => pager && windowPage != null && total != null && _loaded;

  /// How many pages [total] makes (1 while unknown).
  int get totalPages => total == null ? 1 : math.max(1, (total! / pageSize).ceil());

  /// A first page (or a reload) is on its way / the next page is.
  bool isLoading = false;
  bool isLoadingMore = false;

  /// The first page could not be read / the next one could not.
  String? error;
  String? moreError;

  String chip = 'All';
  String search = '';

  /// The bucket tiles picked as filters (several OR together).
  Set<String> tiles = const {};

  /// How many first pages have landed — a screen that sees it move after a filter
  /// change knows the list was replaced and scrolls back to the top.
  int firstPageCount = 0;

  int _seq = 0;
  bool _loaded = false;
  bool _refreshing = false;
  int _pages = 0;
  List<String>? _ids;
  int _cursor = 0;

  /// Whether [items] is an answer for the current chip, tiles and search.
  bool get hasLoaded => _loaded;

  /// Whether the list is read by id (a bucket chip, tile picks, a fixed set).
  bool get idsMode => _ids != null;

  bool get _usesIds => fixedIds != null || _bucketKeys.isNotEmpty;

  Set<String> get _bucketKeys => {...tiles, ?ncBucketOfChip(chip)};

  // The ids already say which NCs match the search text, or the list's own search
  // has to run on each slice.
  bool get _scanBySearch => search.isNotEmpty && !statsHaveSearch && fixedIds == null;

  /// Sets the status chip, the tile picks and/or the search text; true when any
  /// moved. What was loaded belongs to the previous narrowing, so it is dropped at
  /// once (an answer still on its way for it will be ignored) and the list is not
  /// reloaded here — that is the caller's [loadFirst].
  bool setNarrowing({String? chip, String? search, Set<String>? tiles}) {
    final nextChip = chip ?? this.chip;
    final nextSearch = (search ?? this.search).trim();
    final nextTiles = tiles ?? this.tiles;
    if (nextChip == this.chip && nextSearch == this.search && setEquals(nextTiles, this.tiles)) {
      return false;
    }
    this.chip = nextChip;
    this.search = nextSearch;
    this.tiles = {...nextTiles};
    _seq++;
    _clear();
    return true;
  }

  void _clear() {
    items = [];
    total = null;
    totalNcs = null;
    hasMore = false;
    isLoading = false;
    isLoadingMore = false;
    error = null;
    moreError = null;
    _loaded = false;
    _refreshing = false;
    _pages = 0;
    _ids = null;
    _cursor = 0;
    windowPage = null;
  }

  /// Back to empty and to the "All", no-search default — on logout.
  void reset() {
    _seq++;
    chip = 'All';
    search = '';
    tiles = const {};
    _clear();
  }

  // ── requests ────────────────────────────────────────────────────────────

  Map<String, dynamic> _params({bool withSearch = true}) => {
    ...?filters(),
    ...ncChipQuery(chip, raised: raised).params,
    if (withSearch && search.isNotEmpty) 'search': search,
  };

  Future<({List<NcModel> rows, int? total, int? totalNcs, bool plain, int? page})> _get(
    Map<String, dynamic> params,
  ) async {
    final res = await dio.get(path, queryParameters: params);
    final data = res.data['data'];
    final Iterable<dynamic> raw;
    int? total;
    int? totalNcs;
    int? page;
    var plain = false;
    if (data == null) {
      raw = const [];
      plain = true;
    } else if (data is List) {
      // No page/limit answered with the whole list (an older server): that is
      // everything there is.
      raw = data;
      plain = true;
    } else if (data is Map) {
      raw = (data['ncs'] as List?) ?? const [];
      total = (data['total'] as num?)?.toInt();
      totalNcs = (data['totalNcs'] as num?)?.toInt();
      page = (data['page'] as num?)?.toInt();
    } else {
      throw const FormatException('Unexpected NC list answer');
    }
    final rows = [
      for (final e in raw)
        if (e is Map) NcModel.fromJson(Map<String, dynamic>.from(e)),
    ];
    return (rows: rows, total: total, totalNcs: totalNcs, plain: plain, page: page);
  }

  /// Pages `from.pages + 1 .. untilPage` of the plain (server-paged) list,
  /// appended to [from]. Null when the answer went stale on the way.
  Future<_Snap?> _nextPages(_Snap from, int untilPage, bool Function() stale) async {
    final items = [...from.items];
    final seen = {for (final n in items) n.id};
    var page = from.pages;
    var more = from.hasMore;
    var total = from.total;
    var totalNcs = from.totalNcs;
    while (page < untilPage && more) {
      final next = page + 1;
      final r = await _get({..._params(), ...pageParams, 'page': next, 'limit': pageSize});
      if (stale()) return null;
      for (final n in r.rows) {
        if (seen.add(n.id)) items.add(n);
      }
      page = next;
      if (r.plain) {
        total = items.length;
        totalNcs = total;
        more = false;
      } else {
        total = r.total ?? items.length;
        totalNcs = r.totalNcs ?? total;
        // An empty page ends the list however large `total` claims to be.
        more = r.rows.isNotEmpty && page * pageSize < total;
      }
    }
    return _Snap(items: items, total: total, totalNcs: totalNcs, pages: page, hasMore: more);
  }

  /// The ids' slice from `from.cursor` on, until [minRows] rows were gathered AND
  /// the cursor reached [untilCursor] (or the ids ran out). The answer is narrowed
  /// to the ids asked for, whatever the server sent back.
  Future<_Snap?> _nextSlices(
    _Snap from,
    bool Function() stale, {
    int minRows = pageSize,
    int untilCursor = 0,
  }) async {
    final ids = from.ids!;
    final scan = _scanBySearch;
    final slice = scan ? _searchSlice : pageSize;
    final items = [...from.items];
    final seen = {for (final n in items) n.id};
    var cursor = from.cursor;
    var gathered = 0;
    while (cursor < ids.length && (gathered < minRows || cursor < untilCursor)) {
      final part = ids.sublist(cursor, math.min(cursor + slice, ids.length));
      final r = await _get({..._params(withSearch: scan), 'ids': part.join(',')});
      if (stale()) return null;
      final asked = part.toSet();
      for (final n in r.rows) {
        if (asked.contains(n.id) && seen.add(n.id)) {
          items.add(n);
          gathered++;
        }
      }
      cursor += part.length;
    }
    final more = cursor < ids.length;
    // Every id is an NC the tile counted: the total is the tile's number. With a
    // search the stats cannot narrow it is known only once every id has been read.
    final total = scan ? (more ? null : items.length) : ids.length;
    return _Snap(items: items, total: total, totalNcs: total, ids: ids, cursor: cursor, hasMore: more);
  }

  /// The ids to read, newest first (an ObjectId's leading bytes are its creation
  /// time), so a bucket reads in the order the plain list does.
  Future<List<String>> _resolveIds(bool fresh) async {
    final fixed = fixedIds;
    final Iterable<String> ids;
    if (fixed != null) {
      ids = fixed() ?? const <String>[];
    } else {
      final source = loadStats;
      if (source == null) throw const FormatException('No stats source for a bucket list');
      final stats = await source(fresh: fresh, search: statsHaveSearch ? search : '');
      if (stats == null || !stats.hasBuckets) {
        throw const FormatException('No bucket ids in the stats answer');
      }
      ids = {for (final bucket in _bucketKeys) ...stats.idsFor(bucket)};
    }
    return {...ids}.toList()..sort((a, b) => b.compareTo(a));
  }

  _Snap _current() => _Snap(
    items: items,
    total: total,
    totalNcs: totalNcs,
    pages: _pages,
    ids: _ids,
    cursor: _cursor,
    hasMore: hasMore,
  );

  void _apply(_Snap s) {
    items = s.items;
    total = s.total;
    totalNcs = s.totalNcs;
    _pages = s.pages;
    _ids = s.ids;
    _cursor = s.cursor;
    hasMore = s.hasMore;
    _loaded = true;
  }

  // ── the three loads ─────────────────────────────────────────────────────

  /// Page 1 under the current filters, chip, tiles and search — replaces the
  /// list. What was showing stays until the answer lands (a failure then leaves
  /// it, with [error] set, rather than blanking the screen). [fresh] asks the
  /// stats again instead of re-using the last answer (a bucket list only).
  Future<void> loadFirst({bool fresh = true}) async {
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    isLoading = true;
    error = null;
    // A next page or a live refresh that was on its way is superseded.
    isLoadingMore = false;
    moreError = null;
    _refreshing = false;
    onChanged();
    try {
      final _Snap? snap;
      if (_usesIds) {
        final ids = await _resolveIds(fresh);
        if (stale()) return;
        snap = await _nextSlices(_Snap(ids: ids), stale);
      } else {
        snap = await _nextPages(const _Snap(), 1, stale);
      }
      if (snap == null) return;
      _apply(snap);
      // A bucket chip + a search its stats cannot narrow has no known total: that one scrolls.
      windowPage = pager && !(_usesIds && _scanBySearch) ? 1 : null;
      firstPageCount++;
    } on DioException catch (e) {
      if (!stale()) error = extractErrorMessage(e, fallback: failure);
    } catch (e, st) {
      // An answer the models cannot read must end the loading state and say so,
      // not escape as an unhandled error from a fire-and-forget fetch.
      debugPrint('NcPagedList($path).loadFirst: unreadable answer: $e\n$st');
      if (!stale()) error = failure;
    } finally {
      if (!stale()) {
        isLoading = false;
        onChanged();
      }
    }
  }

  /// The next page, appended. Does nothing while a page is already loading, when
  /// everything is loaded, and — unless [retry] — after a failure (so a scroll
  /// listener cannot hammer a server that is down; the footer's Retry passes it).
  Future<void> loadMore({bool retry = false}) async {
    if (isLoading || isLoadingMore || _refreshing || !hasMore || !_loaded) return;
    if (moreError != null && !retry) return;
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    isLoadingMore = true;
    moreError = null;
    onChanged();
    try {
      final base = _current();
      final snap = base.ids != null
          ? await _nextSlices(base, stale)
          : await _nextPages(base, base.pages + 1, stale);
      if (snap == null) return;
      _apply(snap);
    } on DioException catch (e) {
      if (!stale()) moreError = extractErrorMessage(e, fallback: 'Could not load more NCs.');
    } catch (e, st) {
      debugPrint('NcPagedList($path).loadMore: unreadable answer: $e\n$st');
      if (!stale()) moreError = 'Could not load more NCs.';
    } finally {
      if (!stale()) {
        isLoadingMore = false;
        onChanged();
      }
    }
  }

  /// ONE page of the list — page [page] of the server's pages, or the same slice
  /// of [ids] — as a snapshot of just those rows. A page past the end (rows
  /// deleted since) lands on the last real one. Null when the answer went stale.
  Future<_Snap?> _readWindow(int page, bool Function() stale, {List<String>? ids}) async {
    if (ids != null) {
      final last = math.max(1, (ids.length / pageSize).ceil());
      final p = page.clamp(1, last);
      final start = (p - 1) * pageSize;
      final part = ids.sublist(math.min(start, ids.length), math.min(start + pageSize, ids.length));
      final rows = <NcModel>[];
      if (part.isNotEmpty) {
        final r = await _get({..._params(withSearch: false), 'ids': part.join(',')});
        if (stale()) return null;
        final asked = part.toSet();
        final seen = <String>{};
        for (final n in r.rows) {
          if (asked.contains(n.id) && seen.add(n.id)) rows.add(n);
        }
      }
      final end = start + part.length;
      return _Snap(items: rows, total: ids.length, totalNcs: ids.length, ids: ids, cursor: end, pages: p, hasMore: end < ids.length);
    }
    var p = page;
    var r = await _get({..._params(), ...pageParams, 'page': p, 'limit': pageSize});
    if (stale()) return null;
    if (!r.plain && r.rows.isEmpty && p > 1 && (r.total ?? 0) > 0) {
      p = (r.total! / pageSize).ceil();
      r = await _get({..._params(), ...pageParams, 'page': p, 'limit': pageSize});
      if (stale()) return null;
    }
    final total = r.plain ? r.rows.length : (r.total ?? r.rows.length);
    return _Snap(
      items: r.rows,
      total: total,
      totalNcs: r.plain ? total : (r.totalNcs ?? total),
      // The NC lists answer a page past the end with the LAST page and say which one they served.
      pages: r.page ?? p,
      hasMore: !r.plain && r.rows.isNotEmpty && (r.page ?? p) * pageSize < total,
    );
  }

  /// Shows page [page] (clamped) in place of the one on screen — what Prev/Next
  /// call. The rows already on screen stay until the page lands; a failure keeps
  /// them and sets [moreError]. Only for a [pagerMode] list.
  Future<void> goToPage(int page) async {
    if (!pagerMode || isLoading || _refreshing) return;
    final target = page.clamp(1, totalPages);
    if (target == windowPage) return;
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    isLoading = true;
    isLoadingMore = false;
    moreError = null;
    onChanged();
    try {
      final snap = await _readWindow(target, stale, ids: _ids);
      if (snap == null) return;
      _apply(snap);
      windowPage = snap.pages;
      firstPageCount++;
    } on DioException catch (e) {
      if (!stale()) moreError = extractErrorMessage(e, fallback: 'Could not load that page.');
    } catch (e, st) {
      debugPrint('NcPagedList($path).goToPage: unreadable answer: $e\n$st');
      if (!stale()) moreError = 'Could not load that page.';
    } finally {
      if (!stale()) {
        isLoading = false;
        onChanged();
      }
    }
  }

  /// Re-reads the pages that are on screen (page 1..N, or the same number of the
  /// ids) and swaps them in at once. Quiet: no loading flag, and a failure keeps
  /// what is shown. With nothing loaded yet it is a first page.
  Future<void> refreshLoaded() async {
    if (isLoading) return; // a first page is on its way and will be the freshest
    if (!_loaded) return loadFirst();
    final owner = epoch();
    final seq = ++_seq;
    bool stale() => owner != epoch() || seq != _seq;
    final hadMore = isLoadingMore;
    isLoadingMore = false;
    _refreshing = true;
    if (hadMore) onChanged();
    try {
      final _Snap? snap;
      if (windowPage != null) {
        // Page mode: only the page being looked at is re-read.
        List<String>? ids;
        if (_usesIds && _ids != null) {
          ids = await _resolveIds(true);
          if (stale()) return;
        }
        snap = await _readWindow(windowPage!, stale, ids: ids);
        if (snap != null) windowPage = snap.pages;
      } else if (_usesIds && _ids != null) {
        final ids = await _resolveIds(true);
        if (stale()) return;
        snap = await _nextSlices(
          _Snap(ids: ids),
          stale,
          minRows: _cursor == 0 ? pageSize : 0,
          untilCursor: _cursor,
        );
      } else {
        snap = await _nextPages(const _Snap(), math.max(_pages, 1), stale);
      }
      if (snap == null) return;
      _apply(snap);
    } catch (e, st) {
      debugPrint('NcPagedList($path).refreshLoaded: kept what is shown: $e\n$st');
    } finally {
      if (!stale()) {
        _refreshing = false;
        onChanged();
      }
    }
  }
}
