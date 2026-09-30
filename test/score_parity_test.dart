import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/core/utils/nc_timeliness.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/utils/report_sections.dart';
import 'package:internal_audit_app/widgets/score_row.dart';

/// Phone numbers must equal the server's: dueDate.js#effectiveDeadline (IST
/// end of day for a bare date), ncScoring.js#computeAtsScore (null while
/// open), scoring.js#sumTree (sum the STORED per-leaf score) and the web's
/// fmtPct (1dp, no trailing .0).
void main() {
  group('effectiveDeadline', () {
    test('bare date = 18:29:59.999 UTC of that date (end of day IST)', () {
      final d = effectiveDeadline(DateTime.utc(2026, 10, 12));
      expect(d, DateTime.utc(2026, 10, 12, 18, 29, 59, 999));
    });
    test('a date with a real time is that exact instant', () {
      final t = DateTime.utc(2026, 10, 12, 11, 30);
      expect(effectiveDeadline(t), t);
    });
  });

  group('computeNcTimeliness', () {
    final start = DateTime.utc(2026, 10, 1);
    final target = DateTime.utc(2026, 10, 12);
    test('overdue open NC has no ats', () {
      final r = computeNcTimeliness(
        startDate: start,
        targetDate: target,
        completionDate: null,
        now: DateTime.utc(2026, 10, 12, 18, 30),
      );
      expect(r.verdict, NcTimelinessVerdict.overdue);
      expect(r.ats, isNull);
    });
    test('still in progress at 18:29 UTC on the due date', () {
      final r = computeNcTimeliness(
        startDate: start,
        targetDate: target,
        completionDate: null,
        now: DateTime.utc(2026, 10, 12, 18, 29),
      );
      expect(r.verdict, NcTimelinessVerdict.inProgress);
    });
    test('closed 19:00 UTC on the due date is delayed (IST already next day)', () {
      final r = computeNcTimeliness(
        startDate: start,
        targetDate: target,
        completionDate: DateTime.utc(2026, 10, 12, 19),
      );
      expect(r.verdict, NcTimelinessVerdict.delayed);
    });
    test('closed 18:00 UTC on the due date is on time, ats 100', () {
      final r = computeNcTimeliness(
        startDate: start,
        targetDate: target,
        completionDate: DateTime.utc(2026, 10, 12, 18),
      );
      expect(r.verdict, NcTimelinessVerdict.onTime);
      expect(r.ats, 100);
    });
  });

  group('rawAchievedMax sums the stored leaf score', () {
    const compliancePartial = ParameterNode(id: 'a', name: 'a', findingType: 'Compliance', score: 6);
    const strong = ParameterNode(id: 'b', name: 'b', findingType: 'Strong Compliance', score: 10);
    const nc = ParameterNode(id: 'c', name: 'c', findingType: 'NC', score: 0);
    const unscored = ParameterNode(id: 'd', name: 'd');

    test('normal mode: Compliance is its typed score, not forced to max', () {
      final leaves = collectScoredLeaves([compliancePartial, strong, nc, unscored]);
      final am = rawAchievedMax(leaves, 'normal', 10);
      expect(am.achieved, 16);
      expect(am.max, 30);
    });

    test('unscored leaves never count even if passed in', () {
      final am = rawAchievedMax([unscored], 'normal', 10);
      expect(am.max, 0);
    });

    test('a stored NC score is summed as-is (server does not force it)', () {
      const legacyNc = ParameterNode(id: 'e', name: 'e', findingType: 'NC', score: 3);
      expect(rawAchievedMax([legacyNc], 'normal', 10).achieved, 3);
    });

    test('weightage mode: ratio * weightage over weightage', () {
      const l = ParameterNode(id: 'f', name: 'f', findingType: 'Compliance', score: 5, weightage: 4);
      final am = rawAchievedMax([l], 'weightage', 10);
      expect(am.achieved, 2);
      expect(am.max, 4);
    });
  });

  group('formatScorePct', () {
    test('1dp, trailing .0 dropped', () {
      expect(formatScorePct(77.8), '77.8');
      expect(formatScorePct(78), '78');
      expect(formatScorePct(77.84), '77.8');
      expect(formatScorePct(0), '0');
    });
  });
}
