import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/storage/pending_checkpoint_store.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bug 70: a score and remark entered with no signal used to live only in
/// memory. If the app was closed or killed before the server confirmed them,
/// they were gone. Now every unconfirmed edit is also kept on the device, and
/// put back and sent when the checkpoint is opened again.
class _Call {
  _Call(this.findingType, this.score, this.remark, this.auditee, this.date, this.severity);
  final String? findingType;
  final double? score;
  final String remark;
  final String? auditee;
  final DateTime? date;
  final String? severity;
}

const _draftKey = 'checkpoint_draft:aud1::p1';
const _pendingKey = '$_draftKey:pending';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final calls = <_Call>[];
  var offline = false;

  Future<String?> onSave({
    String? findingType,
    double? score,
    required String remark,
    String? auditeeEmployeeId,
    DateTime? targetDate,
    String? severity,
  }) async {
    calls.add(_Call(findingType, score, remark, auditeeEmployeeId, targetDate, severity));
    return offline ? 'Could not reach the server.' : null;
  }

  Future<void> open(WidgetTester tester, {ParameterNode? node, bool readOnly = false}) async {
    calls.clear();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CheckpointCard(
            node: node ?? const ParameterNode(id: 'p1', name: 'Guarding'),
            serial: '1',
            readOnly: readOnly,
            maxScore: 10,
            draftKey: _draftKey,
            onSave: onSave,
            onUploadPhotos: ({required photos, onProgress}) async => const UploadPhotosResult(error: null),
            onSyncStateChanged: (_) {},
          ),
        ),
      ),
    ));
    // let the restore (an async read of the device storage) finish
    await tester.pump();
    await tester.pump();
  }

  // The app being closed / killed: the card is torn down. Time then passes with no signal, so the card's own
  // last-chance retries (3 tries, 3+6+9 s apart) all fail as well.
  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('a scored checkpoint whose save fails is kept on the device', (tester) async {
    offline = true;
    await open(tester);
    await tester.tap(find.text('Compliance'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Guard absent at the gate');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    final saved = await PendingCheckpointStore.read(_draftKey);
    expect(saved, isNotNull);
    expect(saved!.findingType, 'Compliance');
    expect(saved.remark, 'Guard absent at the gate');
    await closeApp(tester);
  });

  testWidgets('THE BUG: offline score + remark, app killed, reopened - the edit comes back and is sent', (tester) async {
    offline = true;
    await open(tester);
    await tester.tap(find.text('OFI'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ofi-7')));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Fire exit half blocked');
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(calls, isNotEmpty);
    await closeApp(tester);

    // The phone has no signal and is closed. It is later opened again - with signal - and the audit comes back from
    // the server WITHOUT this edit (the server never received it).
    expect((await PendingCheckpointStore.read(_draftKey)), isNotNull, reason: 'still on the device after the app was killed');
    offline = false;
    await open(tester);

    expect(calls, isNotEmpty, reason: 'sent again by itself');
    expect(calls.last.findingType, 'OFI');
    expect(calls.last.score, 7);
    expect(calls.last.remark, 'Fire exit half blocked');
    expect(find.text('Fire exit half blocked'), findsOneWidget, reason: 'the card shows what the person had entered');
    expect(find.text('7 / 10'), findsOneWidget);
    // confirmed by the server: nothing left on the device
    await tester.pump(const Duration(seconds: 1));
    expect(await PendingCheckpointStore.read(_draftKey), isNull);
  });

  testWidgets('a fresh NC keeps its auditee, due date and flag too', (tester) async {
    SharedPreferences.setMockInitialValues({
      _pendingKey: '{"v":1,"findingType":"NC","score":0,"remark":"Oil on the floor","auditee":"emp9","date":"2026-11-11","severity":"Major","savedAt":"${DateTime.now().toUtc().toIso8601String()}"}',
    });
    offline = false;
    await open(tester);

    expect(calls.single.findingType, 'NC');
    expect(calls.single.score, 0);
    expect(calls.single.auditee, 'emp9');
    expect(calls.single.date, DateTime(2026, 11, 11));
    expect(calls.single.severity, 'Major');
    await tester.pump(const Duration(seconds: 1));
    expect(await PendingCheckpointStore.read(_draftKey), isNull);
  });

  testWidgets('a save that succeeds leaves nothing on the device', (tester) async {
    offline = false;
    await open(tester);
    await tester.tap(find.text('Strong'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(calls.single.findingType, 'Strong Compliance');
    expect(await PendingCheckpointStore.read(_draftKey), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().where((k) => k.endsWith(':pending')), isEmpty);
  });

  testWidgets('an edit the server already has is dropped, not sent again', (tester) async {
    SharedPreferences.setMockInitialValues({
      _pendingKey: '{"v":1,"findingType":"Compliance","score":null,"remark":"Same as saved","auditee":null,"date":null,"severity":null,"savedAt":"${DateTime.now().toUtc().toIso8601String()}"}',
    });
    await open(tester, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Compliance', score: 10, remark: 'Same as saved'));
    expect(calls, isEmpty);
    expect(await PendingCheckpointStore.read(_draftKey), isNull);
  });

  testWidgets('an edit older than two weeks is forgotten, never sent', (tester) async {
    final old = DateTime.now().subtract(const Duration(days: 20)).toUtc().toIso8601String();
    SharedPreferences.setMockInitialValues({
      _pendingKey: '{"v":1,"findingType":"Compliance","score":null,"remark":"ancient","auditee":null,"date":null,"severity":null,"savedAt":"$old"}',
    });
    await open(tester);
    expect(calls, isEmpty);
    expect(await PendingCheckpointStore.read(_draftKey), isNull);
  });

  testWidgets('a corrupt stored value is ignored: the card opens normally', (tester) async {
    SharedPreferences.setMockInitialValues({_pendingKey: '{broken'});
    await open(tester);
    expect(calls, isEmpty);
    expect(find.text('Guarding'), findsOneWidget);
  });

  testWidgets('a read-only checkpoint (audit finished) is never changed by an old pending edit', (tester) async {
    SharedPreferences.setMockInitialValues({
      _pendingKey: '{"v":1,"findingType":"NC","score":0,"remark":"late edit","auditee":"emp9","date":"2026-11-11","severity":"Major","savedAt":"${DateTime.now().toUtc().toIso8601String()}"}',
    });
    await open(tester, readOnly: true, node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'Compliance', score: 10, remark: 'final'));
    expect(calls, isEmpty);
    expect(find.text('final'), findsOneWidget);
  });
}
