import 'dart:async';
import 'dart:io';

import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The scoring rules and the autosave engine of the "attempting an audit"
/// checkpoint card: fixed/ranged scores per finding, debounced saves that
/// never overlap, retry after a failure, flush on demand, and a remark typed
/// with no finding kept as an on-device draft.
class _Call {
  final String? findingType;
  final double? score;
  final String remark;
  _Call(this.findingType, this.score, this.remark);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('scoreRuleFor', () {
    test('Strong is fixed at the max, NC fixed at 0', () {
      final strong = scoreRuleFor('Strong Compliance', 10);
      expect(strong.fixed, isTrue);
      expect(strong.fixedValue, 10);
      final nc = scoreRuleFor('NC', 10);
      expect(nc.fixed, isTrue);
      expect(nc.fixedValue, 0);
    });

    test('Compliance takes 0..max, OFI takes 0..max-1', () {
      final c = scoreRuleFor('Compliance', 10);
      expect((c.fixed, c.min, c.max), (false, 0.0, 10.0));
      final o = scoreRuleFor('OFI', 10);
      expect((o.fixed, o.min, o.max), (false, 0.0, 9.0));
    });

    test('validateScoreText enforces the range and whole numbers', () {
      final ofi = scoreRuleFor('OFI', 10);
      expect(validateScoreText('', ofi), 'Enter a score');
      expect(validateScoreText('0', ofi), isNull);
      expect(validateScoreText('9', ofi), isNull);
      expect(validateScoreText('10', ofi), isNotNull);
      expect(validateScoreText('2.5', ofi), isNotNull);
      expect(validateScoreText('10', scoreRuleFor('Compliance', 10)), isNull);
      expect(validateScoreText('11', scoreRuleFor('Compliance', 10)), isNotNull);
      // A fixed finding never has anything to validate.
      expect(validateScoreText('', scoreRuleFor('NC', 10)), isNull);
    });
  });

  group('CheckpointCard autosave', () {
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

    Future<void> pump(WidgetTester tester, {ParameterNode? node, bool readOnly = false}) async {
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
              maxScore: 10,
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

    testWidgets('Strong saves right away with the full max as score', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Strong'));
      await tester.pump();
      expect(calls.single.findingType, 'Strong Compliance');
      expect(calls.single.score, 10);
      expect(find.text('10 / 10'), findsOneWidget);
    });

    testWidgets('picking Compliance starts blank — nothing sent until a score is typed, then debounced', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Compliance'));
      await tester.pump();
      expect(calls, isEmpty);
      expect(states.last, CheckpointSyncState.incomplete);

      await tester.enterText(find.byType(TextField).first, '7');
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, isEmpty); // still inside the debounce
      await tester.pump(const Duration(milliseconds: 700));
      expect(calls.single.score, 7);
    });

    testWidgets('OFI: nothing is sent until an in-range score is typed; out of range shows an inline error', (tester) async {
      await pump(tester);
      await tester.tap(find.text('OFI'));
      await tester.pump();
      expect(calls, isEmpty);
      expect(states.last, CheckpointSyncState.incomplete);

      await tester.enterText(find.byType(TextField).first, '10'); // max-1 is 9
      await tester.pump(const Duration(seconds: 2));
      expect(calls, isEmpty);
      expect(find.text('Must be 0–9'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '9');
      await tester.pump(const Duration(seconds: 2));
      expect(calls.single.findingType, 'OFI');
      expect(calls.single.score, 9);
    });

    testWidgets('NC always sends a numeric score (0) — the server rejects an NC save without one', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'NC', ncId: 'nc1', score: 1));
      await tester.enterText(find.byType(TextField).first, 'checked the guard');
      await tester.pump(const Duration(seconds: 2));
      expect(calls.single.findingType, 'NC');
      expect(calls.single.score, 0);
      expect(calls.single.remark, 'checked the guard');
      expect(find.text('0 / 10'), findsOneWidget);
    });

    testWidgets('an edit made while a save is in flight is sent afterwards, never overwritten by the older one', (tester) async {
      await pump(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Strong Compliance', score: 10));
      gate = Completer<String?>();
      await tester.enterText(find.byType(TextField).first, 'first');
      await tester.pump(const Duration(seconds: 1));
      expect(calls.length, 1);

      await tester.enterText(find.byType(TextField).first, 'first and second');
      await tester.pump(const Duration(seconds: 1));
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
      await tester.pump(const Duration(seconds: 1));
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

    testWidgets('flush() is false for a finding still missing its score — it is not saved', (tester) async {
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
      await tester.pump(const Duration(seconds: 2));
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
      await tester.pump(const Duration(seconds: 2));
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
