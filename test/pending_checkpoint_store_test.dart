import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/storage/pending_checkpoint_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The on-device copy of a checkpoint edit the server has not confirmed yet
/// (see pending_checkpoint_store.dart): what is stored, what is ignored, and
/// how one audit's edits are found again after the app was closed or killed.
PendingCheckpoint _edit({
  String? findingType = 'Compliance',
  double? score,
  String remark = 'Pallets in the walkway',
  String? auditee,
  DateTime? date,
  String? severity,
  DateTime? savedAt,
}) =>
    PendingCheckpoint(
      findingType: findingType,
      score: score,
      remark: remark,
      auditeeEmployeeId: auditee,
      targetDate: date,
      severity: severity,
      savedAt: savedAt ?? DateTime.now(),
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PendingCheckpoint', () {
    test('survives a round trip through storage, an NC due date as a plain day with no time or timezone', () {
      final original = _edit(findingType: 'NC', score: 0, auditee: 'emp1', date: DateTime(2026, 11, 11), severity: 'Major');
      final json = original.toJson();
      expect(json['date'], '2026-11-11');
      final back = PendingCheckpoint.fromJson(jsonDecode(jsonEncode(json)))!;
      expect(back.findingType, 'NC');
      expect(back.score, 0);
      expect(back.remark, 'Pallets in the walkway');
      expect(back.auditeeEmployeeId, 'emp1');
      expect(back.targetDate, DateTime(2026, 11, 11));
      expect(back.severity, 'Major');
    });

    test('anything that is not a well-formed record is ignored, never a crash', () {
      for (final bad in <Object?>[null, 'text', 5, <String, dynamic>{}, {'v': 2}, {'v': 1}, {'v': 1, 'savedAt': 'not a date'}]) {
        expect(PendingCheckpoint.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('an edit older than two weeks is stale', () {
      final now = DateTime(2026, 11, 20);
      expect(_edit(savedAt: DateTime(2026, 11, 10)).isStale(now), isFalse);
      expect(_edit(savedAt: DateTime(2026, 11, 5)).isStale(now), isTrue);
    });
  });

  group('PendingCheckpointStore', () {
    const key = 'checkpoint_draft:aud1::node1';

    test('write -> read -> clear', () async {
      expect(await PendingCheckpointStore.read(key), isNull);
      await PendingCheckpointStore.write(key, _edit(findingType: 'OFI', score: 7));
      final read = await PendingCheckpointStore.read(key);
      expect(read!.findingType, 'OFI');
      expect(read.score, 7);
      await PendingCheckpointStore.clear(key);
      expect(await PendingCheckpointStore.read(key), isNull);
    });

    test('a null key (a card with nothing to key on) does nothing and never throws', () async {
      await PendingCheckpointStore.write(null, _edit());
      await PendingCheckpointStore.clear(null);
      expect(await PendingCheckpointStore.read(null), isNull);
    });

    test('a corrupt stored value reads as no pending edit', () async {
      SharedPreferences.setMockInitialValues({'$key:pending': '{not json'});
      expect(await PendingCheckpointStore.read(key), isNull);
    });

    test("forAudit finds only that audit's edits, oldest first, and drops stale or corrupt ones", () async {
      final now = DateTime.now();
      await PendingCheckpointStore.write('checkpoint_draft:aud1::nodeB', _edit(remark: 'second', savedAt: now.subtract(const Duration(minutes: 1))));
      await PendingCheckpointStore.write('checkpoint_draft:aud1:loc9:nodeA', _edit(remark: 'first', savedAt: now.subtract(const Duration(minutes: 5))));
      await PendingCheckpointStore.write('checkpoint_draft:aud2::nodeC', _edit(remark: 'other audit'));
      await PendingCheckpointStore.write('checkpoint_draft:aud1::old', _edit(remark: 'stale', savedAt: now.subtract(const Duration(days: 30))));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('checkpoint_draft:aud1::broken:pending', '###');

      final found = await PendingCheckpointStore.forAudit('aud1');
      expect(found.map((e) => e.pending.remark), ['first', 'second']);
      expect(found.map((e) => e.draftKey), ['checkpoint_draft:aud1:loc9:nodeA', 'checkpoint_draft:aud1::nodeB']);
      // the stale and the corrupt ones were forgotten, the other audit's was left alone
      expect(prefs.containsKey('checkpoint_draft:aud1::old:pending'), isFalse);
      expect(prefs.containsKey('checkpoint_draft:aud1::broken:pending'), isFalse);
      expect(prefs.containsKey('checkpoint_draft:aud2::nodeC:pending'), isTrue);
    });

    test('clearAudit forgets one audit only', () async {
      await PendingCheckpointStore.write('checkpoint_draft:aud1::n1', _edit());
      await PendingCheckpointStore.write('checkpoint_draft:aud2::n1', _edit());
      await PendingCheckpointStore.clearAudit('aud1');
      expect(await PendingCheckpointStore.forAudit('aud1'), isEmpty);
      expect(await PendingCheckpointStore.forAudit('aud2'), hasLength(1));
    });

    test('the remark-only draft and the photo draft of the same checkpoint are not touched', () async {
      SharedPreferences.setMockInitialValues({key: 'a remark typed before any finding', '$key:photos': '["/tmp/a.jpg"]'});
      await PendingCheckpointStore.write(key, _edit());
      await PendingCheckpointStore.clear(key);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(key), 'a remark typed before any finding');
      expect(prefs.getString('$key:photos'), '["/tmp/a.jpg"]');
    });
  });

  group('DraftKey', () {
    test('splits a draft key back into audit, location and checkpoint', () {
      final plain = DraftKey.parse('checkpoint_draft:aud1::node1')!;
      expect([plain.auditId, plain.locationId, plain.nodeId], ['aud1', null, 'node1']);
      final perLocation = DraftKey.parse('checkpoint_draft:aud1:loc7:node1')!;
      expect([perLocation.auditId, perLocation.locationId, perLocation.nodeId], ['aud1', 'loc7', 'node1']);
    });

    test('anything else is not a draft key', () {
      for (final bad in ['', 'draft:p1', 'checkpoint_draft:aud1:node1', 'checkpoint_draft::loc:node', 'checkpoint_draft:aud1:loc:', 'other:aud1::node1']) {
        expect(DraftKey.parse(bad), isNull, reason: bad);
      }
    });
  });
}
