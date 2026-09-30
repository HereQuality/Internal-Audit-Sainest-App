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

class _Snap {
  const _Snap({
    this.items = const <NcModel>[],
    this.total,
    this.pages = 0,
    this.ids,
    this.cursor = 0,
    this.hasMore = true,
  });

  final List<NcModel> items;
  final int? total;
  // Server pages read so far (plain mode)...
  final int pages;
  // ...or, for a bucket chip, the ids to read and how many were read (ids mode).
  final List<String>? ids;
  final int cursor;
  final bool hasMore;
}

/// One NC list (NC Monitoring's "raised by me" or the auditee's "against me")
/// that loads ONE page of [pageSize] at a time.
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
/// The status chip and the search text go to the server (`status`/`open`/`ids`,
/// `search`), so a page is always a page of what is being looked at and `total` is
/// the true count. Every call takes a number; an answer whose number is no longer
/// the newest — or whose account has signed out ([epoch] moved) — is dropped
/// without touching the list, its error or its loading flags.
class NcPagedList {
  NcPagedList({
    required this.dio,
    required this.path,
    required this.raised,
    required this.failure,
    required this.filters,
    required this.epoch,
    required this.onChanged,
    required this.loadStats,
  });

  static const pageSize = 20;
  // With a search text a bucket chip cannot know how many of its ids match, so it
  // reads its ids in bigger slices and keeps going until a page is filled.
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
  final Future<NcTileStats?> Function() loadStats;

  List<NcModel> items = [];

  /// How many NCs the server says match (null while unknown: a bucket chip with a
  /// search text cannot say until every one of its ids has been read).
  int? total;
  bool hasMore = false;

  /// A first page (or a reload) is on its way / the next page is.
  bool isLoading = false;
  bool isLoadingMore = false;

  /// The first page could not be read / the next one could not.
  String? error;
  String? moreError;

  String chip = 'All';
  String search = '';

  int _seq = 0;
  bool _loaded = false;
  bool _refreshing = false;
  int _pages = 0;
  List<String>? _ids;
  int _cursor = 0;

  /// Whether [items] is an answer for the current chip and search.
  bool get hasLoaded => _loaded;

  /// Sets the status chip and/or the search text; true when either moved. The
  /// list is not reloaded here — that is the caller's [loadFirst].
  bool setNarrowing({String? chip, String? search}) {
    final nextChip = chip ?? this.chip;
    final nextSearch = (search ?? this.search).trim();
    if (nextChip == this.chip && nextSearch == this.search) return false;
    this.chip = nextChip;
    this.search = nextSearch;
    // What is loaded belongs to the previous chip/search: nothing may be appended
    // to it, and it is not a starting point for a refresh.
    _loaded = false;
    hasMore = false;
    return true;
  }

  /// Back to empty and to the "All", no-search default — on logout.
  void reset() {
    _seq++;
    items = [];
    total = null;
    hasMore = false;
    isLoading = false;
    isLoadingMore = false;
    error = null;
    moreError = null;
    chip = 'All';
    search = '';
    _loaded = false;
    _refreshing = false;
    _pages = 0;
    _ids = null;
    _cursor = 0;
  }

  // ── requests ────────────────────────────────────────────────────────────

  Map<String, dynamic> _params() => {
    ...?filters(),
    ...ncChipQuery(chip, raised: raised).params,
    if (search.isNotEmpty) 'search': search,
  };

  Future<({List<NcModel> rows, int? total, bool plain})> _get(Map<String, dynamic> params) async {
    final res = await dio.get(path, queryParameters: params);
    final data = res.data['data'];
    final Iterable<dynamic> raw;
    int? total;
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
    } else {
      throw const FormatException('Unexpected NC list answer');
    }
    final rows = [
      for (final e in raw)
        if (e is Map) NcModel.fromJson(Map<String, dynamic>.from(e)),
    ];
    return (rows: rows, total: total, plain: plain);
  }

  /// Pages `from.pages + 1 .. untilPage` of the plain (server-paged) list,
  /// appended to [from]. Null when the answer went stale on the way.
  Future<_Snap?> _nextPages(_Snap from, int untilPage, bool Function() stale) async {
    final items = [...from.items];
    final seen = {for (final n in items) n.id};
    var page = from.pages;
    var more = from.hasMore;
    var total = from.total;
    while (page < untilPage && more) {
      final next = page + 1;
      final r = await _get({..._params(), 'page': next, 'limit': pageSize});
      if (stale()) return null;
      for (final n in r.rows) {
        if (seen.add(n.id)) items.add(n);
      }
      page = next;
      if (r.plain) {
        total = items.length;
        more = false;
      } else {
        total = r.total ?? items.length;
        // An empty page ends the list however large `total` claims to be.
        more = r.rows.isNotEmpty && page * pageSize < total;
      }
    }
    return _Snap(items: items, total: total, pages: page, hasMore: more);
  }

  /// The bucket chip's slice of ids from `from.cursor` on, until [minRows] rows
  /// were gathered AND the cursor reached [untilCursor] (or the ids ran out). The
  /// answer is narrowed to the ids asked for, whatever the server sent back.
  Future<_Snap?> _nextSlices(
    _Snap from,
    bool Function() stale, {
    int minRows = pageSize,
    int untilCursor = 0,
  }) async {
    final ids = from.ids!;
    final slice = search.isEmpty ? pageSize : _searchSlice;
    final items = [...from.items];
    final seen = {for (final n in items) n.id};
    var cursor = from.cursor;
    var gathered = 0;
    while (cursor < ids.length && (gathered < minRows || cursor < untilCursor)) {
      final part = ids.sublist(cursor, math.min(cursor + slice, ids.length));
      final r = await _get({..._params(), 'ids': part.join(',')});
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
    // Without a search every id is a row the tile counted: the total is the
    // tile's number. With one it is known only once every id has been read.
    final total = search.isEmpty ? ids.length : (more ? null : items.length);
    return _Snap(items: items, total: total, ids: ids, cursor: cursor, hasMore: more);
  }

  /// The ids behind a bucket, newest first (an ObjectId's leading bytes are its
  /// creation time), so a bucket reads in the order the plain list does.
  Future<List<String>> _bucketIds(String bucket) async {
    final stats = await loadStats();
    if (stats == null || !stats.hasBuckets) {
      throw const FormatException('No bucket ids in the stats answer');
    }
    return [...stats.idsFor(bucket)]..sort((a, b) => b.compareTo(a));
  }

  _Snap _current() => _Snap(
    items: items,
    total: total,
    pages: _pages,
    ids: _ids,
    cursor: _cursor,
    hasMore: hasMore,
  );

  void _apply(_Snap s) {
    items = s.items;
    total = s.total;
    _pages = s.pages;
    _ids = s.ids;
    _cursor = s.cursor;
    hasMore = s.hasMore;
    _loaded = true;
  }

  // ── the three loads ─────────────────────────────────────────────────────

  /// Page 1 under the current filters, chip and search — replaces the list. What
  /// was showing stays until the answer lands (a failure then leaves it, with
  /// [error] set, rather than blanking the screen).
  Future<void> loadFirst() async {
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
      final bucket = ncBucketOfChip(chip);
      final _Snap? snap;
      if (bucket != null) {
        final ids = await _bucketIds(bucket);
        if (stale()) return;
        snap = await _nextSlices(_Snap(ids: ids), stale);
      } else {
        snap = await _nextPages(const _Snap(), 1, stale);
      }
      if (snap == null) return;
      _apply(snap);
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

  /// Re-reads the pages that are on screen (page 1..N, or the same number of a
  /// bucket's ids) and swaps them in at once. Quiet: no loading flag, and a failure
  /// keeps what is shown. With nothing loaded yet it is a first page.
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
      final bucket = ncBucketOfChip(chip);
      final _Snap? snap;
      if (bucket != null && _ids != null) {
        final ids = await _bucketIds(bucket);
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
