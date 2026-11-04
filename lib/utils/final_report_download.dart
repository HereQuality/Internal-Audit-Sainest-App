import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart' show extractErrorMessage;
import 'final_report_all.dart';
import 'final_report_excel.dart';
import 'report_sheet_spec.dart';

/// utils/final_report_download.dart
/// ──────────────────────────────────
/// Reads EVERY row the Final Report's current filters match — page by page, never
/// just the page on screen — and turns them into the tab's [ReportWorkbookSpec].
/// The Dart twin of the web app's client/src/utils/finalReportDownloads.js plus the
/// Audits tab's fetchAllForExport (client/src/pages/CompletedAudits.jsx).
///
/// It asks the SAME endpoints the tab's own lists read (GET /audits/report,
/// /ncs/report, /ncs/repeats and the stats beside them) with the SAME query — the
/// caller hands in the screen's current filter selection as a [FinalReportRequest]
/// (built from the providers' own param builders, see final_report_request.dart),
/// so the file holds exactly what the filters match and the server alone decides
/// who may see what; nothing here re-implements a scope rule.
///
/// The network is a function ([ReportJsonGet]) so the paging, retry and cancel
/// rules are unit-tested with a fake server.

/// GET [path] with [query] and answer the decoded JSON body (`{isOk, data}`).
typedef ReportJsonGet = Future<dynamic> Function(String path, Map<String, dynamic> query);

/// The caller changed its mind: stops the export between requests, and (when a
/// real Dio request is in flight) aborts it.
class ExportCancelToken {
  /// Handed to Dio by the real getter, so cancelling also drops a request on the wire.
  final CancelToken dioToken = CancelToken();
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    if (!dioToken.isCancelled) dioToken.cancel('Excel download cancelled');
  }

  void throwIfCancelled() {
    if (_cancelled) throw const ExportCancelled();
  }
}

class ExportCancelled implements Exception {
  const ExportCancelled();

  @override
  String toString() => 'ExportCancelled';
}

/// The export could not be completed; [message] is fit to show the person.
class ReportExportException implements Exception {
  final String message;

  /// What actually went wrong underneath, for the log (never shown).
  final Object? cause;

  const ReportExportException(this.message, [this.cause]);

  @override
  String toString() => 'ReportExportException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Where the export is: "Preparing Excel… 120 of 340 reports" — or, in "Download All", which of
/// the three parts is being read: "Audits — 120 of 340 reports".
class ExportProgress {
  /// What is being counted ("reports", "NCs"); empty for the final build step.
  final String noun;
  final int done;
  final int? total;

  /// The file is being written (all rows are in).
  final bool building;

  /// "Download All" only: the tab whose rows are being read ("Audits", "NCs", "Repeated NCs").
  final String part;

  const ExportProgress({this.noun = '', this.done = 0, this.total, this.building = false, this.part = ''});

  const ExportProgress.building() : this(building: true);

  /// The same progress, said for [part].
  ExportProgress forPart(String part) =>
      ExportProgress(noun: noun, done: done, total: total, building: building, part: part);

  /// 0..1, or null when unknown (a spinner rather than a bar).
  double? get fraction {
    if (building) return null;
    final t = total;
    if (t == null || t <= 0) return null;
    return (done / t).clamp(0.0, 1.0);
  }

  String get text {
    if (building) return 'Building the Excel file…';
    // Before the first answer there is nothing to count yet.
    if (noun.isEmpty) return part.isEmpty ? 'Preparing Excel…' : '$part — preparing…';
    final t = total;
    final counted = t == null ? '$done $noun' : '$done of $t $noun';
    return part.isEmpty ? 'Preparing Excel… $counted' : '$part — $counted';
  }
}

typedef ExportProgressCallback = void Function(ExportProgress progress);

/// A snapshot of the screen's filter selection, taken when the person taps Download
/// Excel — later filter changes never reach a file that is being made.
class FinalReportRequest {
  final FinalReportTab tab;

  /// The query of the tab's list endpoint WITHOUT paging (what its provider sends).
  final Map<String, dynamic> listQuery;

  /// The query of the stats endpoint (the tab's tiles); null for the Repeated NCs tab, which has none.
  final Map<String, dynamic>? statsQuery;

  /// The Summary's "Filters applied" lines.
  final List<ReportFilterLine> filters;
  final String generatedBy;

  /// The Repeated NCs tab's "Min. times" pick.
  final int minCount;

  const FinalReportRequest({
    required this.tab,
    required this.listQuery,
    this.statsQuery,
    this.filters = const [],
    this.generatedBy = '',
    this.minCount = 2,
  });
}

/// "Download All": the three tabs' requests, each snapshotted under the filters its own tab uses
/// right now, taken together at the tap.
class FinalReportAllRequest {
  final FinalReportRequest audits;
  final FinalReportRequest ncs;
  final FinalReportRequest repeats;
  final String generatedBy;

  const FinalReportAllRequest({
    required this.audits,
    required this.ncs,
    required this.repeats,
    this.generatedBy = '',
  });
}

/// What an export read and built.
class FinalReportBuild {
  final ReportWorkbookSpec spec;

  /// Rows in the detail sheet (audits × locations, NCs, or repeated checkpoints).
  final int rowCount;

  /// Things the person should be told (a missing tile, a safety limit) — also written in the file.
  final List<String> warnings;

  const FinalReportBuild({required this.spec, required this.rowCount, this.warnings = const []});
}

/// The real network: Dio, the app's shared client (bearer token, 401 handling).
ReportJsonGet dioJsonGet(Dio dio, ExportCancelToken cancel) => (path, query) async {
  final res = await dio.get(path, queryParameters: query, cancelToken: cancel.dioToken);
  return res.data;
};

class _Paged {
  final List<Map> rows;
  final int? total;

  /// Pages skipped because the safety ceiling was reached; 0 = everything was read.
  final int skippedRows;

  const _Paged(this.rows, this.total, this.skippedRows);
}

class FinalReportDownloader {
  FinalReportDownloader({
    required this.get,
    ExportCancelToken? cancel,
    this.onProgress,
    this.retryDelays = const [Duration(milliseconds: 600), Duration(milliseconds: 1800)],
    this.pageSize = 100,
    this.maxPages = 400,
    this.concurrency = 3,
    this.idsPerRequest = 150,
    DateTime Function()? clock,
  }) : cancel = cancel ?? ExportCancelToken(),
       _clock = clock ?? DateTime.now;

  final ReportJsonGet get;
  final ExportCancelToken cancel;
  final ExportProgressCallback? onProgress;

  /// Waits before each retry of a failed request: its length is how many retries a request gets.
  final List<Duration> retryDelays;

  /// The server's own ceiling for every one of these list endpoints is 100 per page.
  final int pageSize;

  /// A safety ceiling on the pages read (pageSize x maxPages rows); beyond it the file says so.
  final int maxPages;

  /// Pages read at the same time once the first has said how many there are (the web reads three).
  final int concurrency;

  /// NC ids per GET /ncs/repeats/rows (the server takes up to 200; fewer keeps the URL short).
  final int idsPerRequest;
  final DateTime Function() _clock;

  // "Download All" reads three parts one after the other: the tab being read, stamped on every
  // progress line ("" for a single tab's download).
  String _part = '';

  void _emit(ExportProgress p) => onProgress?.call(_part.isEmpty ? p : p.forPart(_part));

  // A single tab's download says "Building…" once its rows are in; in "Download All" only the last
  // part's end is the end of the reading, so the combined build says it instead (see [runAll]).
  void _emitBuilding() {
    if (_part.isEmpty) onProgress?.call(const ExportProgress.building());
  }

  /// Reads everything [request] matches and builds the workbook description.
  Future<FinalReportBuild> run(FinalReportRequest request) async {
    try {
      return switch (request.tab) {
        FinalReportTab.audits => await _audits(request),
        FinalReportTab.ncs => await _ncs(request),
        FinalReportTab.repeats => await _repeats(request),
      };
    } on ExportCancelled {
      rethrow;
    } on ReportExportException {
      rethrow;
    } catch (e) {
      if (cancel.isCancelled) throw const ExportCancelled();
      throw ReportExportException('Could not create the Excel file. Please try again.', e);
    }
  }

  /// "Download All": the Audits, NCs and Repeated NCs parts, each read exactly as its own tab's
  /// download reads it (under the filters that tab uses — [request] carries all three), and folded
  /// into ONE workbook by [buildAllReport]. The parts run one AFTER the other, never together: each
  /// reads every row its filters match, and three such readers at once would be three heavy
  /// requests on the server and on a phone's connection. The progress line names the part being
  /// read. If ANY part fails — or the person cancels — the whole download stops: there is never a
  /// file with a part missing.
  Future<FinalReportBuild> runAll(FinalReportAllRequest request) async {
    try {
      _part = 'Audits';
      final audits = await _audits(request.audits);
      _part = 'NCs';
      final ncs = await _ncs(request.ncs);
      _part = 'Repeated NCs';
      final repeats = await _repeats(request.repeats);
      _part = '';
      cancel.throwIfCancelled();
      onProgress?.call(const ExportProgress.building());
      final spec = buildAllReport(
        audits: audits.spec,
        ncs: ncs.spec,
        repeats: repeats.spec,
        generatedBy: request.generatedBy,
        generatedAt: _clock(),
      );
      return FinalReportBuild(
        spec: spec,
        rowCount: audits.rowCount + ncs.rowCount + repeats.rowCount,
        warnings: [
          for (final w in audits.warnings) 'Audits: $w',
          for (final w in ncs.warnings) 'NCs: $w',
          for (final w in repeats.warnings) 'Repeated NCs: $w',
        ],
      );
    } on ExportCancelled {
      rethrow;
    } on ReportExportException {
      rethrow;
    } catch (e) {
      if (cancel.isCancelled) throw const ExportCancelled();
      throw ReportExportException('Could not create the Excel file. Please try again.', e);
    } finally {
      _part = '';
    }
  }

  // ── Audits ────────────────────────────────────────────────────────────────

  Future<FinalReportBuild> _audits(FinalReportRequest r) async {
    // The tiles are a second, small request: it runs beside the (long) row reading.
    final statsFuture = _optionalData(ApiConstants.auditsReportStats, r.statsQuery);
    final paged = await _readAll(ApiConstants.auditsReport, r.listQuery, listKey: 'audits', noun: 'reports');
    final stats = await statsFuture;
    cancel.throwIfCancelled();
    _emitBuilding();

    final export = auditExportRows(paged.rows);
    final warnings = <String>[
      if (stats == null) statsMissingNote,
      if (paged.skippedRows > 0) _ceilingNote(paged, 'reports'),
    ];
    final spec = buildAuditsReport(
      rows: export.rows,
      bundles: export.bundles,
      stats: stats,
      filters: r.filters,
      generatedBy: r.generatedBy,
      generatedAt: _clock(),
      extraNotes: [if (paged.skippedRows > 0) _ceilingNote(paged, 'reports')],
    );
    return FinalReportBuild(spec: spec, rowCount: export.rows.length, warnings: warnings);
  }

  // ── NCs ───────────────────────────────────────────────────────────────────

  Future<FinalReportBuild> _ncs(FinalReportRequest r) async {
    final statsFuture = _optionalData(ApiConstants.ncsReportStats, r.statsQuery);
    // The flat shape (no groupBy): `total` counts NCs, so the page count is exact.
    final paged = await _readAll(ApiConstants.ncsReport, r.listQuery, listKey: 'ncs', noun: 'NCs');
    final stats = await statsFuture;
    cancel.throwIfCancelled();
    _emitBuilding();

    final now = _clock();
    final rows = ncExportRows(paged.rows, now: now);
    final warnings = <String>[
      if (stats == null) statsMissingNote,
      if (paged.skippedRows > 0) _ceilingNote(paged, 'NCs'),
    ];
    final spec = buildNcsReport(
      rows: rows,
      stats: stats,
      filters: r.filters,
      generatedBy: r.generatedBy,
      generatedAt: now,
      extraNotes: [if (paged.skippedRows > 0) _ceilingNote(paged, 'NCs')],
    );
    return FinalReportBuild(spec: spec, rowCount: rows.length, warnings: warnings);
  }

  // ── Repeated NCs ──────────────────────────────────────────────────────────

  /// Every repeated checkpoint under the filters (and the "Min. times" pick), then
  /// every NC of those checkpoints, so each can be listed with its location, date,
  /// audit, who raised it and who it is against.
  Future<FinalReportBuild> _repeats(FinalReportRequest r) async {
    final groups = await _readAll(ApiConstants.ncsRepeats, r.listQuery, listKey: 'rows', noun: 'repeated checkpoints', idOf: (g) => g['key']);

    final ids = <String>{
      for (final g in groups.rows)
        for (final id in (g['ncIds'] is List ? g['ncIds'] as List : const [])) id.toString(),
    }.toList();
    final chunks = <List<String>>[
      for (var i = 0; i < ids.length; i += idsPerRequest) ids.sublist(i, math.min(i + idsPerRequest, ids.length)),
    ];
    final ncsById = <String, Map>{};
    var read = 0;
    _emit(ExportProgress(noun: 'NCs in those checkpoints', done: 0, total: ids.length));
    for (var from = 0; from < chunks.length; from += concurrency) {
      final batch = chunks.sublist(from, math.min(from + concurrency, chunks.length));
      final answers = await Future.wait([
        for (final chunk in batch) _getWithRetry(ApiConstants.ncsRepeatRows, {'ids': chunk.join(',')}),
      ]);
      for (final answer in answers) {
        final data = answer is Map ? answer['data'] : null;
        for (final nc in (data is List ? data : const [])) {
          if (nc is Map && nc['_id'] != null) ncsById[nc['_id'].toString()] = nc;
        }
      }
      read += batch.fold<int>(0, (n, c) => n + c.length);
      _emit(ExportProgress(noun: 'NCs in those checkpoints', done: math.min(read, ids.length), total: ids.length));
    }
    cancel.throwIfCancelled();
    _emitBuilding();

    final warnings = <String>[if (groups.skippedRows > 0) _ceilingNote(groups, 'repeated checkpoints')];
    final spec = buildRepeatsReport(
      groups: groups.rows,
      ncsById: ncsById,
      minCount: r.minCount,
      filters: r.filters,
      generatedBy: r.generatedBy,
      generatedAt: _clock(),
      extraNotes: [if (groups.skippedRows > 0) _ceilingNote(groups, 'repeated checkpoints')],
    );
    return FinalReportBuild(spec: spec, rowCount: groups.rows.length, warnings: warnings);
  }

  // ── Reading ───────────────────────────────────────────────────────────────

  String _ceilingNote(_Paged p, String noun) =>
      'Only the first ${pageSize * maxPages} of ${p.total} $noun are in this file: '
      'a single download stops there. Narrow the filters (dates, place, people) and download again for the rest.';

  /// A small extra request (the tiles) whose failure must not stop the export: null when it failed.
  Future<Map?> _optionalData(String path, Map<String, dynamic>? query) async {
    if (query == null) return null;
    try {
      final answer = await _getWithRetry(path, query);
      final data = answer is Map ? answer['data'] : null;
      return data is Map ? data : null;
    } on ExportCancelled {
      return null;
    } on ReportExportException {
      return null;
    }
  }

  static bool _retryable(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.cancel) return false;
      final status = e.response?.statusCode;
      // A client error will not get better by asking again (403: no access, 400: bad filter) — except
      // "request timeout" and "too many requests".
      if (status != null && status >= 400 && status < 500 && status != 408 && status != 429) return false;
      return true;
    }
    // An answer that cannot be read is not a network blip.
    return false;
  }

  /// One request, tried again after a short wait when the network or the server
  /// hiccups (a phone on a patchy connection) — a final failure stops the export
  /// with a message fit to show, never a half-empty file.
  Future<dynamic> _getWithRetry(String path, Map<String, dynamic> query) async {
    for (var attempt = 0;; attempt++) {
      cancel.throwIfCancelled();
      try {
        final answer = await get(path, query);
        cancel.throwIfCancelled();
        return answer;
      } on ExportCancelled {
        rethrow;
      } catch (e) {
        if (cancel.isCancelled || (e is DioException && e.type == DioExceptionType.cancel)) throw const ExportCancelled();
        if (!_retryable(e) || attempt >= retryDelays.length) {
          throw ReportExportException(
            e is DioException
                ? extractErrorMessage(e, fallback: 'Could not download the data for the Excel file. Please try again.')
                : 'Could not read the data for the Excel file. Please try again.',
            e,
          );
        }
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  /// All rows of a paged list: the first page alone (its `total` says how many pages
  /// there are), the rest [concurrency] at a time, each retried. Rows come back in
  /// page order; a row seen twice (the list grew while the export was reading) is
  /// kept once. A query that names `ids` is one unpaged answer.
  Future<_Paged> _readAll(
    String path,
    Map<String, dynamic> query, {
    required String listKey,
    required String noun,
    Object? Function(Map row)? idOf,
  }) async {
    final unpaged = query.containsKey('ids');
    Future<(List<Map>, int?, int)> page(int n) async {
      final answer = await _getWithRetry(path, unpaged ? query : {...query, 'page': n, 'limit': pageSize});
      final data = answer is Map ? answer['data'] : null;
      final List raw;
      int? total;
      var limit = pageSize;
      if (data is Map) {
        raw = data[listKey] is List ? data[listKey] as List : const [];
        total = (data['total'] as num?)?.toInt();
        limit = (data['limit'] as num?)?.toInt() ?? pageSize;
      } else if (data is List) {
        // No paging in the answer (an older server): that is everything there is.
        raw = data;
        total = data.length;
      } else {
        throw const ReportExportException('Could not read the data for the Excel file. Please try again.');
      }
      return ([for (final e in raw) if (e is Map) e], total, limit);
    }

    final first = await page(1);
    final rows = <Map>[...first.$1];
    var total = first.$2;
    final limit = first.$3 < 1 ? pageSize : first.$3;
    // `done` counts what the list pages by (groups, NCs), not the rows a page carries: a page of
    // 100 audit groups holds more than 100 rows.
    _emit(ExportProgress(noun: noun, done: math.min(limit, total ?? rows.length), total: total));

    var skipped = 0;
    if (!unpaged) {
      if (total != null) {
        var pageCount = math.max((total / limit).ceil(), 1);
        if (pageCount > maxPages) {
          skipped = total - maxPages * limit;
          pageCount = maxPages;
        }
        for (var from = 2; from <= pageCount; from += concurrency) {
          final batch = [for (var p = from; p < from + concurrency && p <= pageCount; p++) p];
          final answers = await Future.wait([for (final p in batch) page(p)]);
          for (final a in answers) {
            rows.addAll(a.$1);
          }
          _emit(ExportProgress(noun: noun, done: math.min(batch.last * limit, total), total: total));
        }
      } else {
        // An answer without a `total`: read on until a page comes back empty.
        for (var p = 2; p <= maxPages && first.$1.isNotEmpty; p++) {
          final a = await page(p);
          if (a.$1.isEmpty) break;
          rows.addAll(a.$1);
          _emit(ExportProgress(noun: noun, done: rows.length));
        }
        total = rows.length;
      }
    }

    // Dedupe, first occurrence wins.
    final seen = <String>{};
    final unique = <Map>[];
    for (final row in rows) {
      final id = (idOf != null ? idOf(row) : row['_id'])?.toString();
      if (id == null || seen.add(id)) unique.add(row);
    }
    return _Paged(unique, total, skipped > 0 ? skipped : 0);
  }
}
