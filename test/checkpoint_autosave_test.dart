import 'dart:async';
import 'dart:io';

import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The scoring rules and the autosave engine of the "attempting an audit"
/// checkpoint card: nothing is typed any more — Strong and Compliance are the
/// full max (no score sent), NC is 0, an OFI is a score picked from 0..max-1 —
/// then debounced saves that never overlap, retry after a failure, flush on
/// demand, and a remark typed with no finding kept as an on-device draft.
class _Call {
  final String? findingType;
  final double? score;
  final String remark;
  _Call(this.findingType, this.score, this.remark);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('scoreRuleFor', () {
    test('Strong and Compliance are both fixed at the max, NC is fixed at 0', () {
      for (final f in ['Strong Compliance', 'Compliance']) {
        final r = scoreRuleFor(f, 10);
        expect((r.fixed, r.fixedValue), (true, 10.0), reason: f);
      }
      final nc = scoreRuleFor('NC', 10);
      expect((nc.fixed, nc.fixedValue), (true, 0.0));
    });

    test('OFI is the one choice: 0..max-1', () {
      final o = scoreRuleFor('OFI', 10);
      expect((o.fixed, o.min, o.max), (false, 0.0, 9.0));
    });

    test('every range is derived from the audit\'s own max, never a hard-coded 10', () {
      final strong = scoreRuleFor('Compliance', 3);
      expect((strong.fixed, strong.fixedValue), (true, 3.0));
      final o = scoreRuleFor('OFI', 3);
      expect((o.min, o.max), (0.0, 2.0));
    });
  });

  group('ofiScoreOptions', () {
    test('a max of 10 offers 0..9 — ten picks, never 10 itself', () {
      expect(ofiScoreOptions(10), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('an older audit with a max of 3 offers 0..2', () {
      expect(ofiScoreOptions(3), [0, 1, 2]);
    });

    test('a max of 1 (or less) leaves only 0 — there is no room below it', () {
      expect(ofiScoreOptions(1), [0]);
      expect(ofiScoreOptions(0), [0]);
    });

    test('a big scale offers every whole number below it', () {
      final o = ofiScoreOptions(100);
      expect((o.first, o.last, o.length), (0, 99, 100));
    });
  });

  group('CheckpointCard autosave', () {
    // Longer than CheckpointCardState._debounceDelay (2.5s since the photo-upload rework) — a
    // typed edit has been sent by the time this has passed.
    const pastDebounce = Duration(seconds: 3);
    final calls = <_Call>[];
    Completer<String?>? gate;
    String? nextError;
    final states = <CheckpointSyncState>[];

    Future<String?> onSave({
      String? findingType,
      double? score,
      required String remark,
      String? auditeeEmployeeId,
      DateTime? targetDate,
      String? severity,
    }) async {
      calls.add(_Call(findingType, score, remark));
      if (gate != null) return gate!.future;
      final e = nextError;
      nextError = null;
      return e;
    }

    Future<String?> onUpload({required List<File> photos, void Function(dynamic, double?)? onProgress}) async => null;

    final key = GlobalKey<CheckpointCardState>();

    Future<void> pump(WidgetTester tester, {ParameterNode? node, bool readOnly = false, double maxScore = 10}) async {
      calls.clear();
      states.clear();
      gate = null;
      nextError = null;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CheckpointCard(
              key: key,
              node: node ?? const ParameterNode(id: 'p1', name: 'Guarding'),
              serial: '1',
              readOnly: readOnly,
              maxScore: maxScore,
              draftKey: 'draft:p1',
              onSave: onSave,
              onUploadPhotos: ({required photos, onProgress}) async {
                final error = await onUpload(photos: photos);
                return UploadPhotosResult(error: error);
              },
              onSyncStateChanged: states.add,
            ),
          ),
        ),
      ));
    }

    testWidgets('Strong saves right away and sends no score — the server stores the full max', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Strong'));
      await tester.pump();
      expect(calls.single.findingType, 'Strong Compliance');
      expect(calls.single.score, isNull);
      expect(find.text('10 / 10'), findsOneWidget);
    });

    testWidgets('Compliance is the full max with NO score field: it saves at once and sends no score', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Compliance'));
      await tester.pump();
      expect(calls.single.findingType, 'Compliance');
      expect(calls.single.score, isNull);
      expect(states.last, isNot(CheckpointSyncState.incomplete));
      expect(find.text('10 / 10'), findsOneWidget);
      expect(find.text('full marks'), findsOneWidget);
      // The remark box is the only text field left on the card.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byKey(const ValueKey('ofi-picker')), findsNothing);
    });

    testWidgets('Compliance on an older audit shows its own max (3 / 3), not a 10', (tester) async {
      await pump(tester, maxScore: 3);
      await tester.tap(find.text('Compliance'));
      await tester.pump();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(calls.single.score, isNull);
    });

    testWidgets('OFI offers a button for every whole number 0..9 (max 10) — and no 10', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      for (var v = 0; v <= 9; v++) {
        expect(find.byKey(ValueKey('ofi-$v')), findsOneWidget, reason: 'button $v');
      }
      expect(find.byKey(const ValueKey('ofi-10')), findsNothing);
      // Nothing is typed: the remark is the only text field.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Pick 0–9 (out of 10)'), findsOneWidget);
    });

    testWidgets('OFI on an older audit with a max of 3 offers only 0, 1, 2', (tester) async {
      await pump(tester, maxScore: 3);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      for (var v = 0; v <= 2; v++) {
        expect(find.byKey(ValueKey('ofi-$v')), findsOneWidget, reason: 'button $v');
      }
      expect(find.byKey(const ValueKey('ofi-3')), findsNothing);
      expect(find.text('Pick 0–2 (out of 3)'), findsOneWidget);
    });

    testWidgets('OFI is required: nothing is sent and the card is incomplete until a score is picked, then it autosaves', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      expect(calls, isEmpty);
      expect(states.last, CheckpointSyncState.incomplete);
      expect(find.text('Pick a score to save'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('ofi-7')));
      await tester.pump();
      // A tap saves at once — no debounce to wait out.
      expect(calls.single.findingType, 'OFI');
      expect(calls.single.score, 7);
      expect(find.text('7 / 10'), findsOneWidget);
      expect(find.text('Pick a score to save'), findsNothing);
    });

    testWidgets('changing the OFI pick saves the new score; tapping the picked one again sends nothing', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ofi-9')));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ofi-9')));
      await tester.pump();
      expect(calls.length, 1);
      await tester.tap(find.byKey(const ValueKey('ofi-0')));
      await tester.pump();
      expect(calls.length, 2);
      expect(calls.last.score, 0);
    });

    testWidgets('the picked OFI score is the highlighted button, and a stored one comes back highlighted', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'OFI', score: 4, ncId: null));
      double borderOf(int v) {
        final shape = tester.widget<Material>(find.byKey(ValueKey('ofi-$v'))).shape! as RoundedRectangleBorder;
        return shape.side.width;
      }

      expect(borderOf(4), 2);
      expect(borderOf(3), 1);
      expect(find.text('4 / 10'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ofi-8')));
      await tester.pump();
      expect(borderOf(8), 2);
      expect(borderOf(4), 1);
    });

    testWidgets('an OFI score stored outside the buttons reads as not picked — and is asked for again', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'OFI', score: 10));
      expect(find.text('Pick 0–9 (out of 10)'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'edited remark');
      await tester.pump(pastDebounce);
      expect(calls, isEmpty);
      expect(states.last, CheckpointSyncState.incomplete);
    });

    testWidgets('a big scale falls back to a dropdown instead of a hundred buttons', (tester) async {
      await pump(tester, maxScore: 100);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      expect(find.byKey(const ValueKey('ofi-dropdown')), findsOneWidget);
      expect(find.byKey(const ValueKey('ofi-5')), findsNothing);
      expect(calls, isEmpty);

      await tester.tap(find.byKey(const ValueKey('ofi-dropdown')));
      await tester.pumpAndSettle();
      // The menu is a lazy list (100 picks): choose one that is on screen.
      await tester.tap(find.text('7').last);
      await tester.pumpAndSettle();
      expect(calls.single.findingType, 'OFI');
      expect(calls.single.score, 7);
    });

    testWidgets('switching from OFI to Compliance drops the pick; switching back starts blank again', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ofi-6')));
      await tester.pump();
      await tester.tap(find.text('Compliance'));
      await tester.pump();
      expect(calls.last.findingType, 'Compliance');
      expect(calls.last.score, isNull);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      expect(find.text('Pick 0–9 (out of 10)'), findsOneWidget);
      expect(states.last, CheckpointSyncState.incomplete);
    });

    testWidgets('NC always sends a numeric score (0) — the server rejects an NC save without one', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'NC', ncId: 'nc1', score: 1));
      await tester.enterText(find.byType(TextField).first, 'checked the guard');
      await tester.pump(pastDebounce);
      expect(calls.single.findingType, 'NC');
      expect(calls.single.score, 0);
      expect(calls.single.remark, 'checked the guard');
      expect(find.text('0 / 10'), findsOneWidget);
    });

    testWidgets('an edit made while a save is in flight is sent afterwards, never overwritten by the older one', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Strong Compliance', score: 10));
      gate = Completer<String?>();
      await tester.enterText(find.byType(TextField).first, 'first');
      await tester.pump(pastDebounce);
      expect(calls.length, 1);

      await tester.enterText(find.byType(TextField).first, 'first and second');
      await tester.pump(pastDebounce);
      expect(calls.length, 1); // serialized: the second waits its turn

      final g = gate!;
      gate = null;
      g.complete(null);
      await tester.pump();
      await tester.pump();
      expect(calls.length, 2);
      expect(calls.last.remark, 'first and second');
    });

    testWidgets('a failed save retries by itself', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Strong Compliance', score: 10));
      nextError = 'Could not reach the server.';
      await tester.enterText(find.byType(TextField).first, 'note');
      await tester.pump(pastDebounce);
      expect(calls.length, 1);
      expect(states.last, CheckpointSyncState.failed);

      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(calls.length, 2);
      expect(states.last, CheckpointSyncState.clean);
      expect(find.text('Saved'), findsOneWidget);
    });

    testWidgets('flush() sends pending typing immediately, without waiting for the debounce', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Strong Compliance', score: 10));
      await tester.enterText(find.byType(TextField).first, 'about to background');
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, isEmpty);
      final ok = await tester.runAsync(() => key.currentState!.flush());
      expect(ok, isTrue);
      expect(calls.single.remark, 'about to background');
    });

    testWidgets('flush() is false for an OFI still missing its pick — it is not saved', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      expect(states.last, CheckpointSyncState.incomplete);
      final ok = await tester.runAsync(() => key.currentState!.flush());
      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    testWidgets('a remark typed with no finding saves on its own, the same way a photo does', (tester) async {
      await pump(tester);
      await tester.enterText(find.byType(TextField).first, 'only a remark');
      await tester.pump(pastDebounce);
      await tester.pump();
      expect(calls.single.findingType, isNull);
      expect(calls.single.score, isNull);
      expect(calls.single.remark, 'only a remark');
      expect(find.text('Saved'), findsOneWidget);
      // Sent to the server, so no local fallback copy is left behind.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('draft:p1'), isNull);
    });

    testWidgets('a remark-only save that fails keeps a local copy as a fallback', (tester) async {
      await pump(tester);
      nextError = 'Could not reach the server.';
      await tester.enterText(find.byType(TextField).first, 'offline remark');
      await tester.pump(pastDebounce);
      await tester.pump();
      expect(calls.single.remark, 'offline remark');
      expect(states.last, CheckpointSyncState.failed);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('draft:p1'), 'offline remark');
    });

    testWidgets('a saved device draft comes back and rides along with the first save', (tester) async {
      SharedPreferences.setMockInitialValues({'draft:p1': 'remembered remark'});
      await pump(tester);
      await tester.pump();
      await tester.pump();
      expect(find.text('remembered remark'), findsOneWidget);
      await tester.tap(find.text('Strong'));
      await tester.pump();
      expect(calls.single.remark, 'remembered remark');
    });

    testWidgets('removing the card with an unsent edit still sends it (a location-tab switch)', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Strong Compliance', score: 10));
      await tester.enterText(find.byType(TextField).first, 'typed then switched tab');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();
      expect(calls.single.remark, 'typed then switched tab');
    });
  });
}
