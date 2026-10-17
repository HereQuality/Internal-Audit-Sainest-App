import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/utils/evidence_photo.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// Evidence photos on a real phone against the live server. Every case here is a way a photo was reported "processed"
/// and then was simply gone — or failed forever — that an emulator on the developer's own machine never hits:
///  - a gallery photo whose NAME lies about its type (the server dropped it without a word),
///  - the server answering "accepted" with no job in it,
///  - one refused photo sinking the others sent with it,
///  - a saved photo vanishing because the refresh that follows the upload failed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FakeAdapter adapter;
  late FakeSockets sockets;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('evidence_test');
    adapter = FakeAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    sockets = FakeSockets();
    SocketService.debugInstance = sockets.service;
    AuditsProvider.refreshRetryDelay = Duration.zero;
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
    AuditsProvider.refreshRetryDelay = const Duration(seconds: 1);
    AuditsProvider.evidenceWaitTimeout = const Duration(seconds: 150);
  });

  const jpegHeader = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1];
  const pngHeader = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
  const webpHeader = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50];
  const heicHeader = [0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63];

  File photo(String name, [List<int> bytes = jpegHeader]) => File('${dir.path}/$name')..writeAsBytesSync([...bytes, ...List.filled(64, 7)]);

  group('evidencePhotoPart — a photo is labelled by what it IS, not by its name', () {
    test('a JPEG named .heic (what Android hands over for a re-encoded HEIC) goes out as image/jpeg, named .jpg', () async {
      final part = await evidencePhotoPart(photo('scaled_IMG_0412.heic'));
      expect(part.contentType.toString(), 'image/jpeg');
      expect(part.filename, 'scaled_IMG_0412.jpg');
    });

    test('a photo with no extension at all gets one, and its real type', () async {
      final part = await evidencePhotoPart(photo('image_picker_8f3a', pngHeader));
      expect(part.contentType.toString(), 'image/png');
      expect(part.filename, 'image_picker_8f3a.png');
    });

    test('PNG and WebP keep their own types even under a .jpg name', () async {
      expect((await evidencePhotoPart(photo('a.jpg', pngHeader))).contentType.toString(), 'image/png');
      expect((await evidencePhotoPart(photo('b.jpg', webpHeader))).contentType.toString(), 'image/webp');
    });

    test('a genuine HEIC is refused up front, in words — not sent for the server to drop', () async {
      await expectLater(
        evidencePhotoPart(photo('IMG_1.heic', heicHeader)),
        throwsA(isA<UnsupportedPhotoException>().having((e) => e.message, 'message', contains('HEIC'))),
      );
    });

    test('junk and a vanished file are refused with a sentence too', () async {
      await expectLater(
        evidencePhotoPart(photo('notes.jpg', const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])),
        throwsA(isA<UnsupportedPhotoException>().having((e) => e.message, 'message', contains('not a JPEG'))),
      );
      await expectLater(
        evidencePhotoPart(File('${dir.path}/gone.jpg')),
        throwsA(isA<UnsupportedPhotoException>().having((e) => e.message, 'message', contains('no longer be read'))),
      );
    });
  });

  group('AuditsProvider.uploadCheckpointEvidence', () {
    late FakeSocket socket;
    // How the fake server answers the n-th evidence POST: a job id, an empty job list, or an HTTP error.
    late Future<ResponseBody> Function(RequestOptions options, int n) onUpload;
    var uploads = 0;
    var auditReads = 0;
    var auditReadFails = 0;
    // What the audit read back says checkpoint n1 holds; null = the audit has no such checkpoint.
    List<String>? auditHolds;
    final jobsFor = <String, String>{}; // jobId -> fileName
    // What the worker reports for each job once it "finishes": 'completed' (with a URL) or 'failed'.
    final outcome = <String, String>{};

    String fileNameOf(RequestOptions o) => ((o.data as FormData).files.single.value).filename!;

    setUp(() {
      uploads = 0;
      auditReads = 0;
      auditReadFails = 0;
      auditHolds = null;
      jobsFor.clear();
      outcome.clear();
      sockets.service.connect('token');
      socket = sockets.sockets.single;
      onUpload = (o, n) async {
        final jobId = 'job$n';
        jobsFor[jobId] = fileNameOf(o);
        return json(202, {
          'isOk': true,
          'data': {
            'jobs': [
              {'jobId': jobId, 'fileName': fileNameOf(o)},
            ],
          },
        });
      };
      adapter.handler = (o) async {
        if (o.method == 'POST' && o.path.endsWith('/evidence')) {
          final n = ++uploads;
          final response = await onUpload(o, n);
          // The worker "finishes" shortly after the request is answered.
          final jobId = 'job$n';
          Timer(const Duration(milliseconds: 20), () {
            final status = outcome[jobId] ?? 'completed';
            if (status == 'silent') return; // the worker never answers
            socket.receive('evidence_upload_result', {
              'jobId': jobId,
              'status': status,
              if (status == 'completed') 'url': 'https://cdn.example/${jobsFor[jobId]}',
              if (status == 'failed') 'error': 'Cloudinary said no',
            });
          });
          return response;
        }
        if (o.method == 'GET' && o.path.startsWith('/audits/a1')) {
          auditReads++;
          if (auditReads <= auditReadFails) connectionError(o);
          return json(200, {
            'isOk': true,
            'data': {
              '_id': 'a1',
              'parameters': [
                if (auditHolds != null) {'_id': 'n1', 'name': 'Guarding', 'photoUrls': auditHolds, 'children': <dynamic>[]},
              ],
            },
          });
        }
        return json(404, {'isOk': false});
      };
    });

    Future<UploadPhotosResult> upload(AuditsProvider p, List<File> photos, {void Function(UploadPhase, double?)? onProgress}) =>
        p.uploadCheckpointEvidence(auditId: 'a1', nodeId: 'n1', photos: photos, onProgress: onProgress);

    test('each photo is its own request with ONE file in it, labelled by its real type', () async {
      final a = photo('a.heic');
      final b = photo('b.jpg', pngHeader);
      final result = await upload(AuditsProvider(), [a, b]);

      final posts = adapter.requests.where((r) => r.method == 'POST').toList();
      expect(posts, hasLength(2));
      final parts = [for (final r in posts) (r.data as FormData).files.single.value];
      expect(parts.map((f) => f.contentType.toString()), ['image/jpeg', 'image/png']);
      expect(parts.map((f) => f.filename), ['a.jpg', 'b.png']);

      expect(result.allSucceeded, isTrue);
      expect(result.uploadedUrls[a.path], 'https://cdn.example/a.jpg');
      expect(result.uploadedUrls[b.path], 'https://cdn.example/b.png');
    });

    test('"accepted" with no job in it is a FAILED photo, not a success that quietly never happened', () async {
      onUpload = (o, n) async => json(202, {'isOk': true, 'data': {'jobs': <dynamic>[]}});
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(result.failedPaths, {a.path});
      expect(result.error, contains('did not accept'));
      expect(result.uploadedUrls, isEmpty);
    });

    test('a photo the server refuses fails alone — the others in the same pick still go through', () async {
      onUpload = (o, n) async {
        if (n == 2) return json(400, {'isOk': false, 'message': 'Each photo must be 5 MB or smaller.'});
        final jobId = 'job$n';
        jobsFor[jobId] = fileNameOf(o);
        return json(202, {
          'isOk': true,
          'data': {
            'jobs': [
              {'jobId': jobId},
            ],
          },
        });
      };
      final a = photo('a.jpg');
      final big = photo('b.jpg');
      final c = photo('c.jpg');
      final result = await upload(AuditsProvider(), [a, big, c]);
      expect(result.failedPaths, {big.path});
      expect(result.error, 'Each photo must be 5 MB or smaller.');
      expect(result.uploadedUrls.keys.toSet(), {a.path, c.path});
    });

    test('an unsupported photo is never sent at all; the rest still are', () async {
      final heic = photo('x.heic', heicHeader);
      final good = photo('g.jpg');
      final result = await upload(AuditsProvider(), [heic, good]);
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(1));
      expect(result.failedPaths, {heic.path});
      expect(result.error, contains('HEIC'));
      expect(result.uploadedUrls.keys, [good.path]);
    });

    test('a job the worker reports as failed fails that photo, with the worker\'s own reason', () async {
      outcome['job1'] = 'failed';
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(result.failedPaths, {a.path});
      expect(result.error, 'Cloudinary said no');
    });

    test('a proxy turning the body away (413, HTML not JSON) is explained, not "Could not upload"', () async {
      onUpload = (o, n) async => ResponseBody.fromString('<html>413 Request Entity Too Large</html>', 413);
      final result = await upload(AuditsProvider(), [photo('a.jpg')]);
      expect(result.error, contains('too large'));
    });

    test('the audit is read again after an upload, and a failed read is retried — the photo is still reported confirmed', () async {
      auditReadFails = 2;
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(auditReads, 3, reason: 'two failed reads, then one that lands');
      expect(result.uploadedUrls.keys, [a.path]);
    });

    test('even when the audit can never be read again, the confirmed photo is in the result', () async {
      auditReadFails = 99;
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(auditReads, 3, reason: 'three tries, then it stops asking');
      expect(result.allSucceeded, isTrue);
      expect(result.uploadedUrls[a.path], 'https://cdn.example/a.jpg');
    });

    test('a job that "completed" but whose photo is NOT on the audit is a failed photo — not shown as saved, then gone on reopening', () async {
      // The worker said done (and gave a URL); the audit, read back, holds no such photo.
      auditHolds = ['https://cdn.example/somebody-elses.jpg'];
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(result.failedPaths, {a.path});
      expect(result.uploadedUrls, isEmpty);
      expect(result.error, contains('could not be saved'));
    });

    test('each photo is checked on its own: the one the audit holds is saved, the one it does not is not', () async {
      auditHolds = ['https://cdn.example/a.jpg']; // b.jpg never got attached
      final a = photo('a.jpg');
      final b = photo('b.jpg');
      final result = await upload(AuditsProvider(), [a, b]);
      expect(result.uploadedUrls.keys, [a.path]);
      expect(result.failedPaths, {b.path});
    });

    test('a photo the audit holds is confirmed', () async {
      auditHolds = ['https://cdn.example/a.jpg'];
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(result.allSucceeded, isTrue);
      expect(result.uploadedUrls[a.path], 'https://cdn.example/a.jpg');
    });

    test('an audit that could not be read proves nothing — the server\'s word stands', () async {
      auditReadFails = 99;
      final a = photo('a.jpg');
      final result = await upload(AuditsProvider(), [a]);
      expect(result.allSucceeded, isTrue);
    });

    test('there is no limit on how many photos go up in one go', () async {
      final many = [for (var i = 0; i < 12; i++) photo('p$i.jpg')];
      final result = await upload(AuditsProvider(), many);
      expect(adapter.requests.where((r) => r.method == 'POST'), hasLength(12));
      expect(result.uploadedUrls, hasLength(12));
    });

    test('which failures are worth retrying: a dropped connection and a server hiccup yes — a refused file, a job the server gave up on, a job still running no', () async {
      // refused by the server (a 4xx)
      onUpload = (o, n) async => json(400, {'isOk': false, 'message': 'Each photo must be 5 MB or smaller.'});
      final refused = photo('refused.jpg');
      var r = await upload(AuditsProvider(), [refused]);
      expect(r.permanentPaths, {refused.path});

      // not a photo at all — never sent
      final heic = photo('x.heic', heicHeader);
      r = await upload(AuditsProvider(), [heic]);
      expect(r.permanentPaths, {heic.path});

      // the server's job failed after its own tries
      onUpload = (o, n) async {
        jobsFor['job$n'] = fileNameOf(o);
        return json(202, {'isOk': true, 'data': {'jobs': [{'jobId': 'job$n'}]}});
      };
      uploads = 0;
      outcome['job1'] = 'failed';
      final gaveUp = photo('gaveup.jpg');
      r = await upload(AuditsProvider(), [gaveUp]);
      expect(r.failedPaths, {gaveUp.path});
      expect(r.permanentPaths, {gaveUp.path});

      // its job is still running when the wait ends: sending again would add it twice
      uploads = 0;
      outcome['job1'] = 'silent';
      AuditsProvider.evidenceWaitTimeout = const Duration(milliseconds: 150);
      final slow = photo('slow.jpg');
      r = await upload(AuditsProvider(), [slow]);
      expect(r.permanentPaths, {slow.path});
      expect(r.error, contains('still working'));

      // a dropped connection, and a 500: worth another go
      for (final answer in [
        (RequestOptions o) => connectionError(o),
        (RequestOptions o) => ResponseBody.fromString('oops', 500),
      ]) {
        onUpload = (o, n) async => answer(o);
        final flaky = photo('flaky.jpg');
        r = await upload(AuditsProvider(), [flaky]);
        expect(r.failedPaths, {flaky.path});
        expect(r.permanentPaths, isEmpty);
      }
    });

    test('progress goes uploading → processing, and never claims processing for a photo that was never sent', () async {
      final phases = <UploadPhase>[];
      await upload(AuditsProvider(), [photo('a.jpg')], onProgress: (p, _) => phases.add(p));
      expect(phases.first, UploadPhase.uploading);
      expect(phases.last, UploadPhase.processing);

      phases.clear();
      await upload(AuditsProvider(), [photo('x.heic', heicHeader)], onProgress: (p, _) => phases.add(p));
      expect(phases, isNot(contains(UploadPhase.processing)));
    });
  });

  group('CheckpointCard — a saved photo never looks gone', () {
    const url = 'https://cdn.example/a.jpg';
    late File pending;

    // The card re-sends photos left in its on-device draft when it starts (what makes a camera shot survive the app
    // being killed) — the one way to drive an upload from a test without a camera.
    Future<void> pumpCard(WidgetTester tester, {required ParameterNode node, required Future<UploadPhotosResult> Function(List<File>) onUpload}) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CheckpointCard(
              node: node,
              serial: '1',
              readOnly: false,
              maxScore: 10,
              draftKey: 'draft:p1',
              onSave: ({findingType, score, required remark, auditeeEmployeeId, targetDate, severity}) async => null,
              onUploadPhotos: ({required photos, onProgress}) => onUpload(photos),
              onSyncStateChanged: (_) {},
            ),
          ),
        ),
      ));
    }

    ParameterNode nodeWith(List<String> photos) => ParameterNode(id: 'p1', name: 'Guarding', photoUrls: photos);

    List<String> shown(WidgetTester tester) => [for (final w in tester.widgetList<CachedNetworkImage>(find.byType(CachedNetworkImage))) w.imageUrl];

    setUp(() {
      pending = photo('shot.jpg');
      SharedPreferences.setMockInitialValues({'draft:p1:photos': jsonEncode([pending.path])});
    });

    testWidgets('a failure that can never succeed is NOT sent again on its own — a failure that can is, once, after a pause', (tester) async {
      var calls = 0;
      var permanent = true;
      await pumpCard(tester, node: nodeWith(const []), onUpload: (photos) async {
        calls++;
        return UploadPhotosResult(
          failedPaths: {photos.single.path},
          permanentPaths: permanent ? {photos.single.path} : const {},
          error: 'Each photo must be 5 MB or smaller.',
        );
      });
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 30));
      expect(calls, 1, reason: 'a refused photo is not retried by timer');
      expect(find.text('Each photo must be 5 MB or smaller.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget, reason: 'the person can still ask');

      // the same card, now with a failure worth retrying
      await tester.pumpWidget(const SizedBox());
      calls = 0;
      permanent = false;
      SharedPreferences.setMockInitialValues({'draft:p1:photos': jsonEncode([pending.path])});
      await pumpCard(tester, node: nodeWith(const []), onUpload: (photos) async {
        calls++;
        return UploadPhotosResult(failedPaths: {photos.single.path}, error: 'Could not reach the server.');
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, 2, reason: 'a dropped connection is worth a second try');
      await tester.pump(const Duration(seconds: 9));
      expect(calls, 3);
      await tester.pump(const Duration(seconds: 60));
      expect(calls, 3, reason: 'then it stops and waits for the person');
    });

    testWidgets('the photo shows from the upload result even when the refreshed audit does not list it yet', (tester) async {
      await pumpCard(tester, node: nodeWith(const []), onUpload: (photos) async => UploadPhotosResult(uploadedUrls: {photos.single.path: url}));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();

      expect(shown(tester), [url], reason: 'confirmed by the server, so on screen — not dropped with nothing in its place');
      // The picked thumbnail (an Image of the local file) is gone: one photo, not two.
      expect(find.byWidgetPredicate((w) => w is Image && w.image is FileImage), findsNothing);
    });

    testWidgets('a stale refresh that arrives afterwards (audit still without the photo) cannot take it off the screen', (tester) async {
      await pumpCard(tester, node: nodeWith(const []), onUpload: (photos) async => UploadPhotosResult(uploadedUrls: {photos.single.path: url}));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(shown(tester), [url]);

      // The parent rebuilds the card with a fresh node that does not list the photo.
      await pumpCard(tester, node: nodeWith(<String>[]), onUpload: (photos) async => const UploadPhotosResult());
      await tester.pump();
      expect(shown(tester), [url]);
    });

    testWidgets('once the audit does list it, it is shown once — not twice', (tester) async {
      await pumpCard(tester, node: nodeWith(const []), onUpload: (photos) async => UploadPhotosResult(uploadedUrls: {photos.single.path: url}));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(shown(tester), [url]);

      await pumpCard(tester, node: nodeWith([url]), onUpload: (photos) async => const UploadPhotosResult());
      await tester.pump();
      expect(shown(tester), [url]);

      // …and a LATER refresh that has dropped it (the auditor removed it elsewhere) no longer resurrects it.
      await pumpCard(tester, node: nodeWith(<String>[]), onUpload: (photos) async => const UploadPhotosResult());
      await tester.pump();
      expect(shown(tester), isEmpty);
    });
  });
}
