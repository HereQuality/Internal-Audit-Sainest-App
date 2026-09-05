import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/models/audit_model.dart';

/// Covers the two things AuditModel gained for the phone agenda — the
/// recurrence/auditType fields the agenda groups by, and the local-time
/// date parsing its day bucketing depends on. Both are silent-failure
/// shapes: a missing recurrence just makes every occurrence its own row,
/// and a UTC-vs-local date just files an audit under the wrong day, so
/// neither would show up as a crash.
void main() {
  // The real thing /audits/mine returns: a whole lean Mongo document, with
  // locations/auditors populated and recurrence present on an occurrence
  // of a Frequency Audit.
  Map<String, dynamic> occurrenceJson({
    String? seriesId = '65f000000000000000000001',
    String? frequency = 'Weekly',
    dynamic auditType = 'Safety Audit',
    String scheduledDate = '2026-09-04T00:00:00.000Z',
  }) => {
    '_id': '65a000000000000000000009',
    'title': 'Line 1 GMP',
    'scope': 'Production',
    'status': 'Not Started',
    'scheduledDate': scheduledDate,
    'auditType': auditType,
    'structureMode': 'same',
    'locationIds': [
      {'_id': 'loc1', 'name': 'Zone A'},
    ],
    'departmentIds': [
      {'_id': 'dep1', 'departmentName': 'Packing'},
    ],
    'auditorIds': [
      {'_id': 'emp1', 'employeeName': 'Asha R'},
    ],
    'recurrence': {
      'seriesId': seriesId,
      'frequency': frequency,
      'occurrenceIndex': 3,
      'occurrenceCount': 12,
    },
  };

  group('AuditModel recurrence', () {
    test('parses seriesId, frequency and occurrence counters', () {
      final a = AuditModel.fromJson(occurrenceJson());
      expect(a.seriesId, '65f000000000000000000001');
      expect(a.frequency, 'Weekly');
      expect(a.occurrenceIndex, 3);
      expect(a.occurrenceCount, 12);
      expect(a.isRecurring, isTrue);
    });

    test('a one-off audit is not recurring', () {
      // What the server actually stores for a non-recurring audit: the
      // recurrence sub-document exists but every field in it is null.
      final a = AuditModel.fromJson(
        occurrenceJson(seriesId: null, frequency: null),
      );
      expect(a.seriesId, isNull);
      expect(a.frequency, isNull);
      expect(a.isRecurring, isFalse);
    });

    test('an absent recurrence object is not recurring', () {
      final json = occurrenceJson()..remove('recurrence');
      expect(AuditModel.fromJson(json).isRecurring, isFalse);
    });

    test('a populated seriesId still yields the id, not a Map', () {
      // Defensive: the endpoint returns the raw ObjectId today, but a
      // future .populate() here must not silently turn every occurrence
      // back into its own ungrouped row.
      final json = occurrenceJson();
      json['recurrence'] = {
        'seriesId': {'_id': '65f000000000000000000001', 'name': 'weekly gmp'},
        'frequency': 'Weekly',
      };
      expect(AuditModel.fromJson(json).seriesId, '65f000000000000000000001');
    });
  });

  group('AuditModel auditType', () {
    test('parses the plain string name', () {
      expect(AuditModel.fromJson(occurrenceJson()).auditType, 'Safety Audit');
    });

    test('an empty or missing audit type reads as null, not an empty string', () {
      expect(AuditModel.fromJson(occurrenceJson(auditType: '')).auditType, isNull);
      expect(AuditModel.fromJson(occurrenceJson(auditType: null)).auditType, isNull);
      final json = occurrenceJson()..remove('auditType');
      expect(AuditModel.fromJson(json).auditType, isNull);
    });
  });

  group('AuditModel dates', () {
    test('scheduledDate comes back in local time', () {
      final a = AuditModel.fromJson(occurrenceJson());
      expect(a.scheduledDate, isNotNull);
      expect(a.scheduledDate!.isUtc, isFalse);
    });

    test('the local calendar day is what day-bucketing will see', () {
      // The bug this guards: parsing without .toLocal() leaves a UTC
      // DateTime, so DateTime(d.year, d.month, d.day) buckets by the UTC
      // day while Formatters prints the local one. Ahead of UTC, a late
      // UTC-evening timestamp is already the NEXT day locally.
      final a = AuditModel.fromJson(
        occurrenceJson(scheduledDate: '2026-09-04T20:30:00.000Z'),
      );
      final expected = DateTime.parse('2026-09-04T20:30:00.000Z').toLocal();
      expect(a.scheduledDate!.year, expected.year);
      expect(a.scheduledDate!.month, expected.month);
      expect(a.scheduledDate!.day, expected.day);
    });

    test('a missing date stays null rather than becoming the epoch', () {
      final json = occurrenceJson()..remove('scheduledDate');
      expect(AuditModel.fromJson(json).scheduledDate, isNull);
      expect(AuditModel.fromJson(json).completedDate, isNull);
    });
  });

  test('existing fields still parse (location label, auditors)', () {
    final a = AuditModel.fromJson(occurrenceJson());
    // locationIds names and departmentIds names joined into one label.
    expect(a.location, 'Zone A, Packing');
    expect(a.auditorNames, ['Asha R']);
    expect(a.title, 'Line 1 GMP');
    expect(a.status, 'Not Started');
  });
}
