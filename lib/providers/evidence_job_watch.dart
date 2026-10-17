import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/socket_service.dart';

/// The server finished with this photo's job and could not save it (it already tried several times itself).
class EvidenceJobFailed implements Exception {
  final String message;
  const EvidenceJobFailed(this.message);
  @override
  String toString() => message;
}

/// The server had not answered for this photo's job when the wait ran out. The job may STILL finish later.
class EvidenceJobTimedOut implements Exception {
  const EvidenceJobTimedOut();
  @override
  String toString() => 'The server is still working on this photo. Check again in a moment.';
}

/// Waits for the queued upload jobs of ONE pick of photos (see AuditsProvider#uploadCheckpointEvidence).
///
/// The socket event "evidence_upload_result" is the main signal and costs no request. As a fallback for a missed event
/// (a dropped connection, the app in the background) it asks the server — but ONE request for every job still waiting
/// (GET /audits/uploads/status?ids=…), not one per photo, and with a growing pause between asks (5 s, 8 s, 12 s, then
/// 15 s) instead of a fixed beat. It used to be one request per photo every 5 s: twenty photos meant twenty checks a tick.
/// Against a server without the batch route it falls back to one request per job, once.
class EvidenceJobWatch {
  EvidenceJobWatch(this._dio, {this.timeout = const Duration(seconds: 150), this.pollSteps = defaultPollSteps});

  /// Pause before the first ask, then between asks; the last step repeats.
  static const defaultPollSteps = [Duration(seconds: 5), Duration(seconds: 8), Duration(seconds: 12), Duration(seconds: 15)];

  final Dio _dio;
  // Long on purpose: a photo waits in the server's queue behind other people's photos, and giving up while it is
  // still queued reported a photo as failed that then turned up on its own a minute later.
  final Duration timeout;
  final List<Duration> pollSteps;

  final Map<String, Completer<String>> _pending = {};
  final Map<String, Timer> _deadlines = {};
  Timer? _pollTimer;
  int _step = 0;
  bool _handlerOn = false;
  bool _closed = false;
  bool _batchRoute = true;

  /// How many times the server was asked (for tests and for logs).
  @visibleForTesting
  int asks = 0;

  /// Completes with the hosted URL once the job is done; fails with [EvidenceJobFailed] / [EvidenceJobTimedOut].
  Future<String> watch(String jobId) {
    final existing = _pending[jobId];
    if (existing != null) return existing.future;
    final completer = Completer<String>();
    _pending[jobId] = completer;
    _deadlines[jobId] = Timer(timeout, () => _finish(jobId, error: const EvidenceJobTimedOut()));
    if (!_handlerOn) {
      _handlerOn = true;
      SocketService.instance.on('evidence_upload_result', _onSocket);
    }
    _pollTimer ??= Timer(_delay(), _poll);
    return completer.future;
  }

  Duration _delay() => pollSteps[_step < pollSteps.length ? _step : pollSteps.length - 1];

  void _onSocket(dynamic data) {
    if (data is! Map) return;
    _apply(data['jobId']?.toString(), data['status']?.toString(), url: data['url'], error: data['error']);
  }

  void _apply(String? jobId, String? status, {Object? url, Object? error}) {
    if (jobId == null || !_pending.containsKey(jobId)) return;
    if (status == 'completed' && url is String) {
      _finish(jobId, url: url);
    } else if (status == 'failed') {
      _finish(jobId, error: EvidenceJobFailed((error is String && error.isNotEmpty) ? error : 'The server could not save this photo.'));
    }
  }

  void _finish(String jobId, {String? url, Object? error}) {
    final completer = _pending.remove(jobId);
    _deadlines.remove(jobId)?.cancel();
    if (completer != null && !completer.isCompleted) {
      if (url != null) {
        completer.complete(url);
      } else {
        completer.completeError(error ?? const EvidenceJobTimedOut());
      }
    }
  }

  Future<void> _poll() async {
    _pollTimer = null;
    if (_closed || _pending.isEmpty) return;
    final ids = _pending.keys.toList();
    asks++;
    try {
      if (_batchRoute) {
        try {
          final res = await _dio.get(ApiConstants.evidenceUploadStatuses, queryParameters: {'ids': ids.join(',')});
          final jobs = res.data['data']['jobs'];
          if (jobs is Map) {
            for (final id in ids) {
              final job = jobs[id];
              if (job is Map) _apply(id, job['status']?.toString(), url: job['url'], error: job['error']);
            }
          }
        } on DioException catch (e) {
          // A server that predates the batch route: ask per job from now on.
          if (e.response?.statusCode == 404) {
            _batchRoute = false;
          } else {
            rethrow;
          }
        }
      }
      if (!_batchRoute) {
        await Future.wait(ids.map((id) async {
          try {
            final res = await _dio.get(ApiConstants.evidenceUploadStatus(id));
            final job = res.data['data'];
            if (job is Map) _apply(id, job['status']?.toString(), url: job['url'], error: job['error']);
          } catch (_) {
            // transient — the next ask, or the deadline, settles it
          }
        }));
      }
    } catch (_) {
      // transient — keep waiting until the deadline
    }
    if (_closed || _pending.isEmpty) return;
    _step++;
    _pollTimer = Timer(_delay(), _poll);
  }

  /// Stops listening and asking — the caller closes it once it has every answer it wanted (a job that finishes before
  /// the next is even queued must not end the watch). Jobs still waiting are failed as timed out.
  void close() {
    if (_closed) return;
    _closed = true;
    _pollTimer?.cancel();
    if (_handlerOn) SocketService.instance.off('evidence_upload_result', _onSocket);
    for (final t in _deadlines.values) {
      t.cancel();
    }
    final left = Map.of(_pending);
    _pending.clear();
    _deadlines.clear();
    for (final c in left.values) {
      if (!c.isCompleted) c.completeError(const EvidenceJobTimedOut());
    }
  }
}
