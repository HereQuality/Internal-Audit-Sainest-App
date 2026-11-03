import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/nc_model.dart';
import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// "Not applicable" on the checkpoint card (ported from the reference app and adapted to this one): a deliberate tap, ALWAYS
/// asked about first (what is cleared is named when something is recorded), that sends its own request through the card's
/// queue, clears what is recorded, and from then on lets nothing be sent for the checkpoint — no autosave, no remark, no
/// photo — until "Make applicable again" returns it blank.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  const pastDebounce = Duration(seconds: 3);
  const photoUrls = ['https://cdn.example/a.jpg', 'https://cdn.example/b.jpg'];

  final saves = <({String? findingType, double? score, String remark})>[];
  final naCalls = <bool>[];
  final states = <CheckpointSyncState>[];
  Completer<String?>? naGate;
  String? naError;
  final key = GlobalKey<CheckpointCardState>();

  NcModel nc({String status = 'Raised'}) => NcModel(
    id: 'nc1',
    ncId: 'NC-12',
    auditId: 'a1',
    auditTitle: 'Line 1 GMP',
    title: 'Guard missing',
    description: '',
    status: status,
    severity: 'Minor',
    raisedBy: const NcPersonRef(id: 'emp1', name: 'Asha R'),
    auditee: const NcPersonRef(id: 'aud2', name: 'Ravi K'),
    targetDate: DateTime(2030, 1, 15),
  );

  Future<String?> onSetNotApplicable(bool value) async {
    naCalls.add(value);
    if (naGate != null) return naGate!.future;
    final e = naError;
    naError = null;
    return e;
  }

  Future<void> pump(
    WidgetTester tester, {
    ParameterNode? node,
    bool readOnly = false,
    bool withNotApplicable = true,
    NcModel? linkedNc,
    Brightness? brightness,
    double textScale = 1,
    Future<UploadPhotosResult> Function(List<File>)? onUpload,
    bool reset = true,
  }) async {
    if (reset) {
      saves.clear();
      naCalls.clear();
      states.clear();
      naGate = null;
      naError = null;
    }
    await tester.pumpWidget(MaterialApp(
      theme: brightness == null ? null : (brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light()),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: CheckpointCard(
            key: key,
            node: node ?? const ParameterNode(id: 'p1', name: 'Guarding'),
            serial: '1',
            readOnly: readOnly,
            maxScore: 10,
            draftKey: 'draft:p1',
            linkedNc: linkedNc,
            onSave: ({findingType, score, required remark, auditeeEmployeeId, targetDate, severity}) async {
              saves.add((findingType: findingType, score: score, remark: remark));
              return null;
            },
            onUploadPhotos: ({required photos, onProgress}) => (onUpload ?? (_) async => const UploadPhotosResult())(photos),
            onSetNotApplicable: withNotApplicable ? onSetNotApplicable : null,
            onSyncStateChanged: states.add,
          ),
        ),
      ),
    ));
  }

  final naButton = find.byKey(const ValueKey('na-button'));
  final panel = find.byKey(const ValueKey('na-panel'));
  final undo = find.byKey(const ValueKey('na-undo'));
  final confirmText = find.byKey(const ValueKey('na-confirm-text'));
  final confirm = find.byKey(const ValueKey('na-confirm'));
  final cancel = find.byKey(const ValueKey('na-cancel'));

  // Runs the dialog's open / close animation and no more: pumpAndSettle would never settle while a field is focused or a
  // spinner turns, and runs the fake clock on past the autosave's 2.5 s.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  String questionText(WidgetTester tester) => tester.widget<Text>(confirmText).data!;

  const strong = ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Strong Compliance', score: 10);

  group('marking a checkpoint Not Applicable', () {
    testWidgets('it is ALWAYS asked first — even with nothing recorded — and only "Mark not applicable" turns the card into the panel', (tester) async {
      await pump(tester);
      expect(naButton, findsOneWidget);
      expect(find.text('Not applicable'), findsOneWidget);

      await tester.tap(naButton);
      await settle(tester);
      expect(find.text('Mark as not applicable?'), findsOneWidget);
      expect(questionText(tester), 'It will be left out of the score.', reason: 'nothing recorded, so nothing is named as cleared');
      expect(find.text('Mark not applicable'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(naCalls, isEmpty, reason: 'nothing is sent until it is confirmed');
      expect(panel, findsNothing);

      // Cancel: nothing happens, and the button asks again next time.
      await tester.tap(cancel);
      await settle(tester);
      expect(naCalls, isEmpty);
      expect(panel, findsNothing);
      expect(naButton, findsOneWidget);

      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);
      expect(naCalls, [true]);

      expect(panel, findsOneWidget);
      expect(find.text('Left out of the score. Nothing needs to be filled in here.'), findsOneWidget);
      expect(find.text('Make applicable again'), findsOneWidget);
      expect(find.text("You'll fill in the finding again."), findsOneWidget);
      // chips, score, remark and photos are gone — none of them applies
      expect(find.text('Strong'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.camera_alt_outlined), findsNothing);
    });

    testWidgets('only one question at a time: the handler pressed twice opens ONE dialog, and a tap outside it asks nothing of the card', (tester) async {
      await pump(tester);
      final press = tester.widget<TextButton>(naButton).onPressed!;
      press();
      press(); // before the first question has even opened
      await settle(tester);
      expect(find.text('Mark as not applicable?'), findsOneWidget);

      // a tap on the card behind the question lands on the barrier and just closes it — no request, no second question
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);
      expect(find.text('Mark as not applicable?'), findsNothing);
      expect(naCalls, isEmpty);
      expect(panel, findsNothing);

      // and it can be asked again, and answered
      await tester.tap(naButton);
      await settle(tester);
      expect(find.text('Mark as not applicable?'), findsOneWidget);
      await tester.tap(confirm);
      await settle(tester);
      expect(naCalls, [true]);
      expect(panel, findsOneWidget);
    });

    testWidgets('while the request is saving the card is the panel — there is no button left to tap twice, and the undo is held', (tester) async {
      await pump(tester);
      naGate = Completer<String?>();
      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);
      expect(naButton, findsNothing);
      expect(tester.widget<OutlinedButton>(undo).onPressed, isNull);
      expect(naCalls, [true]);

      naGate!.complete(null);
      await settle(tester);
      expect(naCalls, [true], reason: 'one request, however many taps');
      expect(tester.widget<OutlinedButton>(undo).onPressed, isNotNull);
    });

    testWidgets('with something recorded it asks first, in words — and Cancel leaves the checkpoint exactly as it was', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Compliance', score: 10, remark: 'seen', photoUrls: photoUrls));
      await tester.tap(naButton);
      await settle(tester);

      expect(find.text('Mark as not applicable?'), findsOneWidget);
      expect(questionText(tester), 'It will be left out of the score. The finding, score, remark and 2 photos recorded on it will be cleared.');

      await tester.tap(cancel);
      await settle(tester);
      expect(naCalls, isEmpty);
      expect(panel, findsNothing);
      expect(find.text('Compliance'), findsOneWidget);
      expect(find.text('seen'), findsOneWidget);
    });

    testWidgets('the question lists only what exists', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', photoUrls: ['https://cdn.example/a.jpg']));
      await tester.tap(naButton);
      await settle(tester);
      expect(questionText(tester), 'It will be left out of the score. The 1 photo recorded on it will be cleared.');
      await tester.tap(cancel);
      await settle(tester);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', remark: 'just a note'));
      await tester.tap(naButton);
      await settle(tester);
      expect(questionText(tester), 'It will be left out of the score. The remark recorded on it will be cleared.');
    });

    testWidgets('an NC raised on it is named: it is withdrawn unless the auditee has already responded', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'NC', score: 0, remark: 'no guard', ncId: 'nc1'), linkedNc: nc());
      await tester.tap(naButton);
      await settle(tester);
      expect(
        questionText(tester),
        'It will be left out of the score. The finding, score and remark recorded on it will be cleared. '
        'NC-12 raised on it will be withdrawn, unless the auditee has already responded to it.',
      );
      await tester.tap(confirm);
      await settle(tester);

      expect(naCalls, [true]);
      expect(panel, findsOneWidget);
    });

    testWidgets('an NC that has a response: the server refuses, its sentence is shown, and the card is back as it was', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'NC', score: 0, ncId: 'nc1'), linkedNc: nc(status: 'Response Submitted'));
      naError = 'NC-12 raised on this checkpoint already has a response on record (Response Submitted), so it can\'t be marked Not Applicable.';
      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);

      expect(panel, findsNothing);
      expect(find.textContaining('already has a response on record'), findsOneWidget);
      expect(find.text('NC'), findsOneWidget);
    });

    testWidgets('while the request is on its way the panel is already up, says Saving…, and the sync state is saving', (tester) async {
      await pump(tester, node: strong);
      naGate = Completer<String?>();
      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);

      expect(panel, findsOneWidget);
      expect(find.text('Saving…'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(undo).onPressed, isNull, reason: 'one request at a time');
      expect(states.last, CheckpointSyncState.saving);

      naGate!.complete(null);
      await settle(tester);
      expect(find.text('Saving…'), findsNothing);
      expect(states.last, CheckpointSyncState.clean);
    });

    testWidgets('what was typed and is still waiting for its autosave is never sent after the mark', (tester) async {
      await pump(tester, node: strong);
      await tester.enterText(find.byType(TextField).first, 'typed just now');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(naButton);
      await settle(tester);
      expect(questionText(tester), contains('remark'));
      await tester.tap(confirm);
      await settle(tester);

      await tester.pump(pastDebounce);
      await tester.pump(const Duration(seconds: 30));
      expect(saves, isEmpty, reason: 'no autosave, no retry, nothing after the mark');
      expect(naCalls, [true]);
      expect(await key.currentState!.flush(), isTrue);
      expect(saves, isEmpty);
    });

    testWidgets('a refusal puts the card back as it was, says why, and what was waiting goes out after all', (tester) async {
      await pump(tester, node: strong);
      await tester.enterText(find.byType(TextField).first, 'typed just now');
      await tester.pump(const Duration(milliseconds: 300));
      naError = 'Cannot score — audit is already Completed.';
      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);

      expect(panel, findsNothing);
      expect(find.text('Strong'), findsOneWidget);
      expect(find.text('typed just now'), findsOneWidget);
      expect(find.text('Cannot score — audit is already Completed.'), findsOneWidget);
      expect(saves.map((s) => s.remark), ['typed just now']);
    });

    testWidgets('an OFI waiting for its pick is not sent after the mark either', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);
      expect(panel, findsOneWidget);
      expect(find.byKey(const ValueKey('ofi-picker')), findsNothing);
      await tester.pump(const Duration(seconds: 30));
      expect(saves, isEmpty);
      expect(states.last, CheckpointSyncState.clean);
    });

    testWidgets('a photo still uploading is waited for; its failure is not shown, not retried — and the device forgets it', (tester) async {
      final file = File('${Directory.systemTemp.createTempSync('na_photo').path}/shot.jpg')..writeAsBytesSync([1, 2, 3]);
      SharedPreferences.setMockInitialValues({'draft:p1:photos': jsonEncode([file.path])});
      final upload = Completer<UploadPhotosResult>();
      var uploads = 0;
      await pump(tester, onUpload: (_) {
        uploads++;
        return upload.future;
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(uploads, 1);

      await tester.tap(naButton);
      await settle(tester);
      expect(questionText(tester), contains('1 photo'));
      await tester.tap(confirm);
      await tester.pump();
      expect(naCalls, isEmpty, reason: 'behind the upload that is still running — one request at a time');

      upload.complete(UploadPhotosResult(failedPaths: {file.path}, error: 'Could not reach the server.'));
      await tester.pump();
      await tester.pump();
      expect(naCalls, [true]);
      await tester.pump(const Duration(seconds: 30));
      expect(uploads, 1, reason: 'no retry for a checkpoint that takes no photos');
      expect(find.text('Could not reach the server.'), findsNothing);
      expect((await SharedPreferences.getInstance()).getString('draft:p1:photos'), isNull, reason: 'it would otherwise come back on the next open');
    });
  });

  group('making it applicable again', () {
    testWidgets('is immediate, asks nothing, and returns a BLANK checkpoint that is filled in afresh', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'OFI', score: 7, remark: 'seen'));
      await tester.tap(naButton);
      await settle(tester);
      await tester.tap(confirm);
      await settle(tester);
      expect(panel, findsOneWidget);

      await tester.tap(undo);
      await settle(tester);
      expect(naCalls, [true, false]);
      expect(panel, findsNothing);
      for (final chip in ['Strong', 'Compliance', 'OFI', 'NC']) {
        expect(find.text(chip), findsOneWidget);
      }
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty, reason: 'the old remark does not come back');
      expect(find.text('seen'), findsNothing);
      expect(find.textContaining('Score'), findsNothing, reason: 'no finding picked, so no score box and no OFI buttons');
      expect(find.byKey(const ValueKey('ofi-picker')), findsNothing);
      expect(saves, isEmpty, reason: 'undoing sends nothing but the undo');

      // and it works like any checkpoint again
      await tester.tap(find.text('Compliance'));
      await tester.pump();
      expect(saves.single.findingType, 'Compliance');
      expect(saves.single.score, isNull);
    });

    testWidgets('a refusal leaves it Not Applicable and says why', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Not Applicable'));
      naError = 'The server had a problem. Please try again.';
      await tester.tap(undo);
      await settle(tester);
      expect(panel, findsOneWidget);
      expect(find.text('The server had a problem. Please try again.'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(undo).onPressed, isNotNull, reason: 'the person can try again');
    });
  });

  group('a checkpoint that is Not Applicable when the card opens', () {
    testWidgets('shows the panel, takes nothing from the device (a stale draft stays unread) and sends nothing', (tester) async {
      SharedPreferences.setMockInitialValues({'draft:p1': 'an old draft', 'draft:p1:photos': jsonEncode(['/gone/shot.jpg'])});
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Not Applicable'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 30));

      expect(panel, findsOneWidget);
      expect(find.text('an old draft'), findsNothing);
      expect(saves, isEmpty);
      expect(naCalls, isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('draft:p1'), isNull);
      expect(prefs.getString('draft:p1:photos'), isNull);
    });

    testWidgets('follows the server when it is marked, or made applicable again, from somewhere else', (tester) async {
      await pump(tester, node: strong);
      expect(find.text('Strong'), findsOneWidget);

      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Not Applicable'), reset: false);
      await tester.pump();
      expect(panel, findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding'), reset: false);
      await tester.pump();
      expect(panel, findsNothing);
      expect(find.text('Strong'), findsOneWidget);
      expect(saves, isEmpty);
      expect(naCalls, isEmpty, reason: 'it only followed — it asked for nothing');
    });
  });

  group('where the button is offered', () {
    testWidgets('only when the screen gives the card a way to do it — and never on a read-only card', (tester) async {
      await pump(tester, withNotApplicable: false);
      expect(naButton, findsNothing);
      expect(find.text('Not applicable'), findsNothing);

      await pump(tester, readOnly: true, node: strong);
      expect(naButton, findsNothing);
    });

    testWidgets('a read-only Not Applicable checkpoint says so, with the short pill', (tester) async {
      await pump(tester, readOnly: true, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Not Applicable'));
      expect(find.text('N/A'), findsOneWidget);
      expect(find.text('Not applicable — left out of the score.'), findsOneWidget);
      expect(find.text('Not yet scored'), findsNothing);
      expect(find.textContaining('Score:'), findsNothing);
    });

    testWidgets('a read-only one still shows the NC it may carry', (tester) async {
      await pump(
        tester,
        readOnly: true,
        node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Not Applicable', ncId: 'nc1'),
        linkedNc: nc(),
      );
      expect(find.text('Not applicable — left out of the score.'), findsOneWidget);
      expect(find.text('Ravi K'), findsOneWidget);
    });
  });

  group('looks right', () {
    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name} theme, 360dp wide, large text: the button, the question and the panel fit', (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await pump(tester, brightness: brightness, textScale: 1.4, node: const ParameterNode(id: 'p1', name: 'A fairly long checkpoint name that has to wrap on a small phone', findingType: 'NC', score: 0, remark: 'no guard', ncId: 'nc1', photoUrls: photoUrls), linkedNc: nc());
        expect(naButton, findsOneWidget);
        expect(tester.getSize(naButton).height, greaterThanOrEqualTo(36), reason: 'a thumb must find it (the tap target is padded to 48)');
        expect(tester.takeException(), isNull, reason: 'the card with the button');

        await tester.tap(naButton);
        await settle(tester);
        expect(find.text('Mark as not applicable?'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'the question');

        await tester.tap(confirm);
        await settle(tester);
        expect(panel, findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'the panel');

        await pump(tester, brightness: brightness, textScale: 1.4, readOnly: true, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Not Applicable'));
        expect(tester.takeException(), isNull, reason: 'the read-only card');
      });
    }

    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name} theme, 360dp wide, large text: the OFI buttons wrap onto rows with 48dp touch targets', (tester) async {
        tester.view.physicalSize = const Size(360, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await pump(tester, brightness: brightness, textScale: 1.4);
        await tester.tap(find.text('OFI'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final first = tester.getRect(find.byKey(const ValueKey('ofi-0')));
        final last = tester.getRect(find.byKey(const ValueKey('ofi-9')));
        expect(first.width, greaterThanOrEqualTo(48));
        expect(first.height, greaterThanOrEqualTo(48));
        expect(last.top, greaterThan(first.top), reason: 'ten buttons do not fit one row at 360dp: they wrap');
        expect(last.right, lessThanOrEqualTo(360));
      });
    }
  });
}
