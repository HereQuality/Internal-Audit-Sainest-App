import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/models/audit_detail_model.dart';
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

  // ── Unified status vocabulary (status contract) ────────────────────────
  // The server now sends displayStatus/timeliness/ncSummary/batchDisplayStatus/
  // batchTimeliness next to the old `status`. The label the user reads comes
  // from displayStatus; `status` keeps driving every gate, so both must
  // survive parsing untouched, and an older server that sends none of the new
  // fields must still render its old status.
  group('AuditModel unified status', () {
    Map<String, dynamic> completed({Map<String, dynamic> extra = const {}}) =>
        occurrenceJson()
          ..['status'] = 'Completed'
          ..addAll(extra);

    test('parses displayStatus, timeliness, ncSummary and the batch pair', () {
      final a = AuditModel.fromJson(completed(extra: {
        'displayStatus': 'NC Response Pending',
        'timeliness': 'Delayed Completed',
        'ncSummary': {'total': 3, 'responsePending': 1, 'verificationPending': 1, 'closed': 1},
        'scheduleBatchId': 'batch1',
        'batchDisplayStatus': 'In Progress',
        'batchTimeliness': null,
      }));
      expect(a.displayStatus, 'NC Response Pending');
      expect(a.timeliness, 'Delayed Completed');
      expect(a.ncSummary, isNotNull);
      expect(a.ncSummary!.total, 3);
      expect(a.ncSummary!.responsePending, 1);
      expect(a.ncSummary!.verificationPending, 1);
      expect(a.ncSummary!.closed, 1);
      expect(a.batchDisplayStatus, 'In Progress');
      expect(a.batchTimeliness, isNull);
    });

    test('the raw status is untouched: gates keep reading it, labels read displayStatus', () {
      final a = AuditModel.fromJson(completed(extra: {'displayStatus': 'Total Closed'}));
      expect(a.status, 'Completed');
      expect(a.displayStatus, 'Total Closed');
      expect(a.displayLabel, 'Total Closed');
    });

    test('an older server (no new fields) falls back to status for every label', () {
      final a = AuditModel.fromJson(occurrenceJson());
      expect(a.displayStatus, isNull);
      expect(a.timeliness, isNull);
      expect(a.ncSummary, isNull);
      expect(a.batchDisplayStatus, isNull);
      expect(a.batchTimeliness, isNull);
      expect(a.displayLabel, 'Not Started');
      expect(a.batchLabel, 'Not Started');
    });

    test('a status-less payload still defaults status to Scheduled (unchanged)', () {
      final json = occurrenceJson()..remove('status');
      final a = AuditModel.fromJson(json);
      expect(a.status, 'Scheduled');
      expect(a.displayLabel, 'Scheduled');
    });

    test('blank strings and a non-object ncSummary read as absent, not as empty values', () {
      final a = AuditModel.fromJson(occurrenceJson()
        ..['displayStatus'] = '  '
        ..['timeliness'] = ''
        ..['ncSummary'] = 'nope'
        ..['batchDisplayStatus'] = '');
      expect(a.displayStatus, isNull);
      expect(a.timeliness, isNull);
      expect(a.ncSummary, isNull);
      expect(a.batchDisplayStatus, isNull);
      expect(a.displayLabel, 'Not Started');
    });

    test('an unknown label from the server is kept verbatim, never mapped to another status', () {
      final a = AuditModel.fromJson(occurrenceJson()..['displayStatus'] = 'On Hold');
      expect(a.displayLabel, 'On Hold');
    });

    test('batchLabel prefers the batch aggregate over this zone\'s own status', () {
      final a = AuditModel.fromJson(completed(extra: {
        'displayStatus': 'Total Closed',
        'scheduleBatchId': 'batch1',
        'batchDisplayStatus': 'NC Verification Pending',
      }));
      expect(a.displayLabel, 'Total Closed');
      expect(a.batchLabel, 'NC Verification Pending');
    });

    test('ncSummary tolerates missing / string counts', () {
      final s = AuditNcSummary.tryParse({'total': '2', 'closed': 2});
      expect(s!.total, 2);
      expect(s.closed, 2);
      expect(s.responsePending, 0);
      expect(AuditNcSummary.tryParse(null), isNull);
    });
  });

  group('AuditorStats', () {
    Map<String, dynamic> statsJson() => {
      'assignedAudits': 20,
      'inProgress': 7,
      'ncPending': 5,
      'completed': 9,
      'assigned': 2,
      'ongoing': 3,
      'overdue': 4,
      // Completed audits split two ways that must agree: by timeliness
      // (1 + 8 = 9) and by NC stage (4 + 3 + 2 = 9).
      'delayed': 1,
      'onTimeCompleted': 8,
      'ncResponsePending': 4,
      'ncVerificationPending': 3,
      'totalClosed': 2,
      'assignedIds': ['a1', 'a2'],
      'ongoingIds': ['o1'],
      'overdueIds': ['d1', 'd2', 'd3', 'd4'],
      'delayedIds': ['x1'],
      'onTimeCompletedIds': ['t1'],
      'ncResponsePendingIds': ['r1'],
      'ncVerificationPendingIds': ['v1', 'v2'],
      'totalClosedIds': ['c1'],
      'auditAtsScore': 82.5,
      'auditOtcScore': 90,
    };

    test('parses the per-status tallies and their id lists', () {
      final s = AuditorStats.fromJson(statsJson());
      expect(s.notStarted, 2);
      expect(s.ongoing, 3);
      expect(s.overdue, 4);
      expect(s.delayed, 1);
      expect(s.onTimeCompleted, 8);
      expect(s.ncResponsePending, 4);
      expect(s.ncVerificationPending, 3);
      expect(s.totalClosed, 2);
      expect(s.notStartedIds, ['a1', 'a2']);
      expect(s.overdueIds, ['d1', 'd2', 'd3', 'd4']);
      expect(s.ncVerificationPendingIds, ['v1', 'v2']);
      expect(s.totalClosedIds, ['c1']);
    });

    test('the pre-existing keys still mean what they did', () {
      final s = AuditorStats.fromJson(statsJson());
      expect(s.assignedAudits, 20);
      expect(s.inProgress, 7);
      expect(s.ncPending, 5);
      expect(s.completed, 9);
      expect(s.auditAtsScore, 82.5);
      expect(s.auditOtcScore, 90);
    });

    test('countFor / idsFor map each vocabulary label onto its tally', () {
      final s = AuditorStats.fromJson(statsJson());
      expect(s.countFor('Not Started'), 2);
      expect(s.countFor('In Progress'), 3); // ongoing: overdue excluded
      expect(s.countFor('Overdue'), 4);
      expect(s.countFor('Delayed Completed'), 1);
      expect(s.countFor('On-Time Completed'), 8);
      expect(s.countFor('NC Response Pending'), 4);
      expect(s.countFor('NC Verification Pending'), 3);
      expect(s.countFor('Total Closed'), 2);
      expect(s.countFor('Draft'), 0);
      expect(s.countFor('nonsense'), 0);
      expect(s.idsFor('In Progress'), ['o1']);
      expect(s.idsFor('Not Started'), ['a1', 'a2']);
      expect(s.idsFor('Skipped'), isEmpty);
    });

    test('the tallies of completed audits agree both ways (On-Time + Delayed = NC Response + NC Verification + Total Closed)', () {
      final s = AuditorStats.fromJson(statsJson());
      expect(
        s.countFor('On-Time Completed') + s.countFor('Delayed Completed'),
        s.countFor('NC Response Pending') + s.countFor('NC Verification Pending') + s.countFor('Total Closed'),
      );
      expect(s.hasNcStageCounts, isTrue);
    });

    test('hasNcStageCounts is false when the server predates the NC-stage tallies', () {
      // The timeliness tallies exist on an older server, the NC-stage ones do
      // not — so the app must not present the missing three as zeros.
      final s = AuditorStats.fromJson({'assignedAudits': 9, 'delayed': 2, 'onTimeCompleted': 5});
      expect(s.hasNcStageCounts, isFalse);
      expect(s.delayed, 2);
      expect(s.onTimeCompleted, 5);
      // …and one missing key is enough: a partial set is not trusted either.
      expect(AuditorStats.fromJson({'ncResponsePending': 1, 'ncVerificationPending': 1}).hasNcStageCounts, isFalse);
      // A server that sends all three as 0 (a company with no completed audit) is fine.
      expect(
        AuditorStats.fromJson({'ncResponsePending': 0, 'ncVerificationPending': 0, 'totalClosed': 0}).hasNcStageCounts,
        isTrue,
      );
    });

    test('a server that sends none of the new keys yields zeros, not a crash', () {
      final s = AuditorStats.fromJson({'assignedAudits': 9, 'inProgress': 4});
      expect(s.assignedAudits, 9);
      expect(s.notStarted, 0);
      expect(s.overdue, 0);
      expect(s.totalClosed, 0);
      expect(s.overdueIds, isEmpty);
      // Too old to send `ongoing`: fall back to inProgress rather than show 0.
      expect(s.ongoing, 4);
    });

    test('an explicit ongoing of 0 is honoured (not replaced by inProgress)', () {
      final s = AuditorStats.fromJson({'inProgress': 4, 'ongoing': 0});
      expect(s.ongoing, 0);
    });

    test('counts and ids tolerate strings / non-lists', () {
      final s = AuditorStats.fromJson({'overdue': '3', 'overdueIds': 'oops', 'totalClosedIds': [1, 2]});
      expect(s.overdue, 3);
      expect(s.overdueIds, isEmpty);
      expect(s.totalClosedIds, ['1', '2']);
    });
  });

  group('AuditDetailModel / BatchReport unified status', () {
    Map<String, dynamic> detailJson({Map<String, dynamic> extra = const {}}) => {
      '_id': 'z1',
      'title': 'Batch audit',
      'status': 'Completed',
      ...extra,
    };

    test('parses the new fields and prints displayStatus, gating on status', () {
      final d = AuditDetailModel.fromJson(detailJson(extra: {
        'displayStatus': 'NC Verification Pending',
        'timeliness': 'On-Time Completed',
        'ncSummary': {'total': 2, 'responsePending': 0, 'verificationPending': 2, 'closed': 0},
        'batchDisplayStatus': 'In Progress',
        'batchTimeliness': 'Delayed Completed',
      }));
      expect(d.status, 'Completed');
      expect(d.displayStatus, 'NC Verification Pending');
      expect(d.displayLabel, 'NC Verification Pending');
      expect(d.timeliness, 'On-Time Completed');
      expect(d.ncSummary!.verificationPending, 2);
      expect(d.batchDisplayStatus, 'In Progress');
      expect(d.batchTimeliness, 'Delayed Completed');
    });

    test('a Not Attempted audit is told by windowClosed / displayStatus — its raw status stays In Progress', () {
      final closed = AuditDetailModel.fromJson(detailJson(extra: {'status': 'In Progress', 'windowClosed': true, 'displayStatus': 'Not Attempted'}));
      expect(closed.status, 'In Progress');
      expect(closed.windowClosed, isTrue);
      expect(closed.isNotAttempted, isTrue);
      // either signal alone is enough (an older build of the server sends only one of them)
      expect(AuditDetailModel.fromJson(detailJson(extra: {'status': 'In Progress', 'windowClosed': true})).isNotAttempted, isTrue);
      expect(AuditDetailModel.fromJson(detailJson(extra: {'status': 'In Progress', 'displayStatus': 'Not Attempted'})).isNotAttempted, isTrue);
      // an open audit — even a late one — is not
      expect(AuditDetailModel.fromJson(detailJson(extra: {'status': 'In Progress', 'displayStatus': 'Overdue'})).isNotAttempted, isFalse);
      expect(AuditDetailModel.fromJson(detailJson()).isNotAttempted, isFalse);
    });

    test('an older server falls back to status', () {
      final d = AuditDetailModel.fromJson(detailJson());
      expect(d.displayStatus, isNull);
      expect(d.displayLabel, 'Completed');
      expect(d.timeliness, isNull);
      expect(d.ncSummary, isNull);
    });

    test('BatchReport reads the top-level aggregate and every zone\'s fields', () {
      final r = BatchReport.fromJson({
        'status': 'Mixed',
        'displayStatus': 'Overdue',
        'timeliness': null,
        'zones': [
          detailJson(extra: {'_id': 'z1', 'displayStatus': 'Total Closed', 'batchDisplayStatus': 'Overdue'}),
          detailJson(extra: {'_id': 'z2', 'status': 'In Progress', 'displayStatus': 'Overdue', 'batchDisplayStatus': 'Overdue'}),
        ],
      });
      expect(r.zones, hasLength(2));
      expect(r.zones.first.displayLabel, 'Total Closed');
      expect(r.displayStatus, 'Overdue');
      expect(r.timeliness, isNull);
      // The response's own coarse "Mixed" is not what the PDF prints.
      expect(r.statusLabel, 'Overdue');
    });

    test('batchStatusOf: aggregate, else the zones\' batchDisplayStatus, else the first zone\'s label', () {
      final zones = [
        AuditDetailModel.fromJson(detailJson(extra: {'displayStatus': 'Total Closed', 'batchDisplayStatus': 'NC Response Pending'})),
        AuditDetailModel.fromJson(detailJson(extra: {'_id': 'z2', 'displayStatus': 'NC Response Pending', 'batchDisplayStatus': 'NC Response Pending'})),
      ];
      expect(batchStatusOf(zones, aggregate: 'Total Closed'), 'Total Closed');
      expect(batchStatusOf(zones), 'NC Response Pending');
      expect(batchStatusOf(zones, aggregate: ''), 'NC Response Pending');
      final old = [AuditDetailModel.fromJson(detailJson())];
      expect(batchStatusOf(old), 'Completed');
      expect(batchStatusOf(const []), '');
    });

    test('a batch report with no data object parses to no zones', () {
      final r = BatchReport.fromJson(const {});
      expect(r.zones, isEmpty);
      expect(r.statusLabel, '');
    });
  });
}
