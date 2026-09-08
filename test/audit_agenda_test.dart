import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/widgets/audit_agenda.dart';

/// Covers buildAuditAgenda's month-tiering rule — the split between the
/// handful of past/future months shown individually by name and everything
/// further out, bucketed into "Past 6 Months"/"Past Year"/"Older" (and the
/// mirrored future labels). Exercised against a FIXED `today` rather than
/// DateTime.now(), same reasoning audit_agenda.dart's own header comment
/// gives for keeping every bucket rule a pure function of an explicit date.
void main() {
  // Today = 8 Sep 2026, matching the date this feature was built against.
  final today = DateTime(2026, 9, 8);

  AuditModel auditOn(DateTime date, {String title = 'Audit'}) => AuditModel(
        id: '${date.year}-${date.month}-${date.day}-$title',
        title: title,
        scope: '',
        status: 'Not Started',
        scheduledDate: date,
      );

  group('past tiering', () {
    test('this month + the 3 prior months are named individually', () {
      final audits = [
        auditOn(DateTime(2026, 9, 3)), // this month, before today -> distance 0
        auditOn(DateTime(2026, 8, 10)), // 1 month back
        auditOn(DateTime(2026, 7, 10)), // 2 months back
        auditOn(DateTime(2026, 6, 10)), // 3 months back
      ];
      final agenda = buildAuditAgenda(audits, today);

      expect(agenda.recentPastMonths.map((m) => m.month), [
        DateTime(2026, 6),
        DateTime(2026, 7),
        DateTime(2026, 8),
        DateTime(2026, 9),
      ]);
      expect(agenda.pastBuckets, isEmpty);
      // The flat source of truth stays the full set, for the summary bar.
      expect(agenda.pastCount, 4);
    });

    test('4-6 months back lands in "Past 6 Months"', () {
      final audits = [
        auditOn(DateTime(2026, 5, 10)), // 4 months back
        auditOn(DateTime(2026, 3, 10)), // 6 months back
      ];
      final agenda = buildAuditAgenda(audits, today);

      expect(agenda.recentPastMonths, isEmpty);
      expect(agenda.pastBuckets, hasLength(1));
      expect(agenda.pastBuckets.single.label, 'Past 6 Months');
      expect(agenda.pastBuckets.single.count, 2);
      // Oldest-first inside the bucket too.
      expect(agenda.pastBuckets.single.months.map((m) => m.month), [
        DateTime(2026, 3),
        DateTime(2026, 5),
      ]);
    });

    test('7-12 months back lands in "Past Year"; 13+ in "Older"', () {
      final audits = [
        auditOn(DateTime(2026, 2, 1)), // 7 months back
        auditOn(DateTime(2025, 9, 1)), // 12 months back
        auditOn(DateTime(2025, 8, 1)), // 13 months back -> Older
        auditOn(DateTime(2023, 1, 1)), // years back -> still just "Older"
      ];
      final agenda = buildAuditAgenda(audits, today);

      expect(agenda.pastBuckets.map((b) => b.label), [
        'Older',
        'Past Year',
      ]);
      final older = agenda.pastBuckets.firstWhere((b) => b.label == 'Older');
      final year = agenda.pastBuckets.firstWhere((b) => b.label == 'Past Year');
      expect(older.count, 2);
      expect(year.count, 2);
    });

    test('buckets render farthest-first, recent months last', () {
      final audits = [
        auditOn(DateTime(2026, 8, 1)), // recent
        auditOn(DateTime(2026, 4, 1)), // 6mo bucket
        auditOn(DateTime(2025, 9, 1)), // year bucket
        auditOn(DateTime(2024, 1, 1)), // older bucket
      ];
      final agenda = buildAuditAgenda(audits, today);
      expect(agenda.pastBuckets.map((b) => b.label), [
        'Older',
        'Past Year',
        'Past 6 Months',
      ]);
      expect(agenda.recentPastMonths, hasLength(1));
    });
  });

  group('future tiering', () {
    test('the next 3 months are named individually; nothing further out yet',
        () {
      final audits = [
        auditOn(DateTime(2026, 10, 5)), // 1 month ahead
        auditOn(DateTime(2026, 11, 5)), // 2 months ahead
        auditOn(DateTime(2026, 12, 5)), // 3 months ahead
      ];
      final agenda = buildAuditAgenda(audits, today);

      expect(agenda.recentLaterMonths.map((m) => m.month), [
        DateTime(2026, 10),
        DateTime(2026, 11),
        DateTime(2026, 12),
      ]);
      expect(agenda.futureBuckets, isEmpty);
    });

    test('buckets render nearest-first, ahead of the farther ones', () {
      final audits = [
        auditOn(DateTime(2027, 1, 1)), // 4 months ahead -> 6mo bucket
        auditOn(DateTime(2027, 6, 1)), // 9 months ahead -> year bucket
        auditOn(DateTime(2028, 6, 1)), // way out -> Later bucket
      ];
      final agenda = buildAuditAgenda(audits, today);

      expect(agenda.recentLaterMonths, isEmpty);
      expect(agenda.futureBuckets.map((b) => b.label), [
        'Next 6 Months',
        'Next Year',
        'Later',
      ]);
    });
  });

  test('same audit never appears in more than one tier', () {
    final audits = [
      // Day 1, not 15: today is the 8th, so day 15 of THIS month (m == 0)
      // would be in the future, not the past, throwing the "every audit
      // lands in exactly one past tier" premise below off by one.
      for (var m = 0; m < 30; m++)
        auditOn(DateTime(today.year, today.month - m, 1), title: 'a$m'),
    ];
    final agenda = buildAuditAgenda(audits, today);
    final seen = <String>{};
    for (final a in agenda.recentPastMonths.expand((g) => g.audits)) {
      seen.add(a.id);
    }
    for (final b in agenda.pastBuckets) {
      for (final a in b.months.expand((g) => g.audits)) {
        expect(seen.add(a.id), isTrue, reason: '${a.id} counted twice');
      }
    }
    expect(seen.length, audits.length);
  });
}
