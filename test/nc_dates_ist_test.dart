import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/utils/nc_timeliness.dart';

/// Everyone works in India (IST, UTC+05:30): an NC's due date is an IST calendar
/// day, and its turnaround score counts IST days. Mirrors the server
/// (server/utils/ncTargetDate.js, dueDate.js#computeTurnaroundRatio).
void main() {
  group('ncDayString - what the phone sends for an NC due date', () {
    test('a date the person picked is sent as that plain day: no time, no timezone', () {
      expect(ncDayString(DateTime(2026, 11, 11)), '2026-11-11');
      expect(ncDayString(DateTime(2026, 1, 5)), '2026-01-05');
      expect(ncDayString(DateTime(2026, 12, 31)), '2026-12-31');
    });

    test('a date that came from the server (UTC midnight) keeps its day', () {
      expect(ncDayString(DateTime.utc(2026, 11, 11)), '2026-11-11');
    });

    test('an instant from the server is placed on its IST day (the old broken stored value 18:30Z is 00:00 IST the next day)', () {
      expect(ncDayString(DateTime.utc(2026, 11, 10, 18, 30)), '2026-11-11');
      expect(ncDayString(DateTime.utc(2026, 11, 10, 20)), '2026-11-11');
      expect(ncDayString(DateTime.utc(2026, 11, 11, 10)), '2026-11-11');
      expect(ncDayString(DateTime.utc(2026, 11, 10, 18, 29)), '2026-11-10');
    });

    test('it never contains a time or a timezone', () {
      expect(ncDayString(DateTime(2026, 11, 11, 23, 59)), matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });
  });

  group('computeTurnaroundRatio counts IST days', () {
    // raised 4 Nov 15:30 IST, due 6 Nov (a bare date), closed late
    final raised = DateTime.utc(2026, 11, 4, 10);
    final due = DateTime.utc(2026, 11, 6);

    test('closed at 03:00 IST on the 8th = 2 planned / 4 actual days = 50 (it was 67 on the UTC day)', () {
      expect(computeTurnaroundRatio(raised, due, DateTime.utc(2026, 11, 7, 21, 30)), 50);
    });

    test('closed at 11:30 IST the same day gives the same score: the time of day does not matter', () {
      expect(computeTurnaroundRatio(raised, due, DateTime.utc(2026, 11, 8, 6)), 50);
    });

    test('raised at 03:00 IST and closed at 02:00 IST, due the day after raising: 1 / 3 = 33', () {
      expect(computeTurnaroundRatio(DateTime.utc(2026, 11, 3, 21, 30), DateTime.utc(2026, 11, 5), DateTime.utc(2026, 11, 6, 20, 30)), 33);
    });

    test('the deadline itself is unchanged: the end of the IST day', () {
      expect(effectiveDeadline(DateTime.utc(2026, 11, 11)).toUtc(), DateTime.utc(2026, 11, 11, 18, 29, 59, 999));
    });
  });
}
