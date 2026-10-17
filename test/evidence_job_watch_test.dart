import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/providers/evidence_job_watch.dart';

import 'support/session_fakes.dart';

/// How the phone finds out a photo's job is done. The socket event is free; the fallback ask used to be one request per
/// photo on a fixed 5 s beat. Now: ONE request for every photo still waiting, with a growing pause.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late FakeSockets sockets;
  late FakeSocket socket;
  const fast = [Duration(milliseconds: 20), Duration(milliseconds: 40), Duration(milliseconds: 80)];

  // job id -> what the server answers for it
  late Map<String, Map<String, dynamic>> answers;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    adapter = FakeAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    sockets = FakeSockets();
    SocketService.debugInstance = sockets.service;
    sockets.service.connect('token');
    socket = sockets.sockets.single;
    answers = {};
    adapter.handler = (o) async {
      if (o.path == '/audits/uploads/status') {
        final ids = (o.queryParameters['ids'] as String).split(',');
        return json(200, {
          'isOk': true,
          'data': {
            'jobs': {for (final id in ids) id: answers[id] ?? {'status': 'pending'}},
          },
        });
      }
      return json(404, {'isOk': false});
    };
  });

  EvidenceJobWatch watch({Duration timeout = const Duration(seconds: 5), List<Duration> steps = fast}) =>
      EvidenceJobWatch(DioClient.instance.dio, timeout: timeout, pollSteps: steps);

  int asks() => adapter.requests.where((r) => r.path.startsWith('/audits/uploads/status')).length;

  test('a socket event settles the job and the server is never asked', () async {
    final w = watch();
    final done = w.watch('1');
    socket.receive('evidence_upload_result', {'jobId': '1', 'status': 'completed', 'url': 'https://cdn/x.jpg'});
    expect(await done, 'https://cdn/x.jpg');
    w.close();
    expect(asks(), 0);
  });

  test('twenty photos still waiting cost ONE request per ask, not twenty', () async {
    final w = watch();
    final ids = [for (var i = 1; i <= 20; i++) '$i'];
    final futures = [for (final id in ids) w.watch(id)];
    for (final id in ids) {
      answers[id] = {'status': 'completed', 'url': 'https://cdn/$id.jpg'};
    }
    final urls = await Future.wait(futures);
    w.close();
    expect(urls.first, 'https://cdn/1.jpg');
    expect(urls, hasLength(20));
    expect(asks(), 1, reason: 'one batch request answered all twenty');
    expect(adapter.requests.first.queryParameters['ids'], ids.join(','));
  });

  test('only the jobs still waiting are asked about, and the pause grows between asks', () async {
    final w = watch();
    final a = w.watch('1');
    final b = w.watch('2');
    final stamps = <DateTime>[];
    adapter.handler = (o) async {
      stamps.add(DateTime.now());
      final ids = (o.queryParameters['ids'] as String).split(',');
      return json(200, {
        'isOk': true,
        'data': {
          'jobs': {
            for (final id in ids)
              id: (id == '1' && stamps.length >= 2) || (id == '2' && stamps.length >= 4) ? {'status': 'completed', 'url': 'u$id'} : {'status': 'pending'},
          },
        },
      });
    };
    await Future.wait([a, b]);
    w.close();
    expect(stamps.length, greaterThanOrEqualTo(4));
    // job 1 finished on the 2nd ask, so the 3rd and later ask about job 2 alone
    final asked = adapter.requests.where((r) => r.path == '/audits/uploads/status').map((r) => r.queryParameters['ids']).toList();
    expect(asked.first, '1,2');
    expect(asked.last, '2');
    final gap1 = stamps[1].difference(stamps[0]);
    final gap3 = stamps[3].difference(stamps[2]);
    expect(gap3, greaterThan(gap1), reason: 'each ask waits a little longer than the one before');
  });

  test('a job the server gave up on fails with the server\'s own words', () async {
    final w = watch();
    final f = w.watch('1');
    answers['1'] = {'status': 'failed', 'error': 'This audit is already Completed, so the photo was not added.'};
    await expectLater(f, throwsA(isA<EvidenceJobFailed>().having((e) => e.message, 'message', contains('already Completed'))));
    w.close();
  });

  test('a job that stays unanswered ends as timed out, not as a failure to retry', () async {
    final w = watch(timeout: const Duration(milliseconds: 100));
    await expectLater(w.watch('1'), throwsA(isA<EvidenceJobTimedOut>()));
    w.close();
  });

  test('a server without the batch route is asked once per job instead — and the batch route is not tried again', () async {
    final w = watch();
    final paths = <String>[];
    adapter.handler = (o) async {
      paths.add(o.path);
      if (o.path == '/audits/uploads/status') return json(404, {'isOk': false});
      final id = o.path.split('/').last;
      return json(200, {'isOk': true, 'data': {'status': 'completed', 'url': 'u$id'}});
    };
    final urls = await Future.wait([w.watch('7'), w.watch('8')]);
    w.close();
    expect(urls, ['u7', 'u8']);
    expect(paths.where((p) => p == '/audits/uploads/status'), hasLength(1));
    expect(paths.where((p) => p.startsWith('/audits/uploads/status/')), hasLength(2));
  });

  test('a job finishing before the next is even queued does not end the watch', () async {
    final w = watch();
    final first = w.watch('1');
    socket.receive('evidence_upload_result', {'jobId': '1', 'status': 'completed', 'url': 'u1'});
    expect(await first, 'u1');
    final second = w.watch('2');
    socket.receive('evidence_upload_result', {'jobId': '2', 'status': 'completed', 'url': 'u2'});
    expect(await second, 'u2');
    w.close();
  });

  test('closing removes the socket listener', () async {
    final w = watch();
    unawaited(w.watch('1').catchError((_) => ''));
    expect(socket.listenerCount('evidence_upload_result'), 1);
    w.close();
    expect(socket.listenerCount('evidence_upload_result'), 0);
  });
}
