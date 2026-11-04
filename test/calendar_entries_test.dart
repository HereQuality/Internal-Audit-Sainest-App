import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/utils/audit_date_range.dart';
import 'package:internal_audit_app/core/utils/calendar_entries.dart';
import 'package:internal_audit_app/core/utils/calendar_window.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/models/nc_model.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// What the phone Calendar plots and asks the server for — the logic under
/// screens/calendar/calendar_screen.dart, which test/calendar_screen_test.dart
/// then drives through the real screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Noon local: the same calendar day wherever the test runs.
  String iso(int y, int m, int d, [int h = 12]) => DateTime(y, m, d, h).toUtc().toIso8601String();

  AuditModel audit(
    String id, {
    String title = 'Audit',
    required String start,
    String? end,
    String status = 'In Progress',
    List<Map<String, dynamic>>? auditee,
    bool self = false,
  }) => AuditModel.fromJson({
    '_id': id,
    'title': title,
    'status': 'Scheduled',
    'displayStatus': status,
    'scheduledDate': start,
    'scheduledEndDate': end,
    'selfAudit': self,
    'auditeeId': auditee == null || auditee.isEmpty ? null : auditee.first,
    'auditeeIds': auditee,
  });

  NcModel nc(String id, {String? start, String? target, String status = 'Raised'}) => NcModel.fromJson({
    '_id': id,
    'ncId': 'NC-$id',
    'title': 'NC $id',
    'status': status,
    'startDate': start,
    'targetDate': target,
  });

  group('CalendarWindow', () {
    test('gridOf: the Monday-first cells of November 2026 run from Mon 26 Oct to Sun 6 Dec', () {
      final grid = CalendarWindow.gridOf(DateTime(2026, 11, 1));
      expect(grid.from, DateTime(2026, 10, 26));
      expect(grid.to, DateTime(2026, 12, 6));
      // A month that starts on a Monday and ends on a Sunday has no neighbours in the grid.
      final feb = CalendarWindow.gridOf(DateTime(2027, 2, 1));
      expect(feb.from, DateTime(2027, 2, 1));
      expect(feb.to, DateTime(2027, 2, 28));
    });

    test('forGrid pads the grid by a day each way (the web\'s windowFrom / windowTo)', () {
      final w = CalendarWindow.forGrid(DateTime(2026, 11, 1));
      expect(w.from, DateTime(2026, 10, 25));
      expect(w.to, DateTime(2026, 12, 7));
    });

    test('around: the month before, the month and the month after', () {
      final w = CalendarWindow.around(DateTime(2026, 11, 1));
      expect(w.from, DateTime(2026, 9, 27));
      expect(w.to, DateTime(2027, 1, 4));
      for (final m in [DateTime(2026, 10, 1), DateTime(2026, 11, 1), DateTime(2026, 12, 1)]) {
        expect(w.covers(CalendarWindow.forGrid(m)), isTrue, reason: '$m');
      }
      expect(w.covers(CalendarWindow.forGrid(DateTime(2027, 1, 1))), isFalse);
      expect(w.covers(CalendarWindow.forGrid(DateTime(2026, 9, 1))), isFalse);
    });

    test('audits are asked for from 60 days earlier (a multi-day audit that began before the window)', () {
      final w = CalendarWindow.around(DateTime(2026, 11, 1));
      expect(w.auditFrom, DateTime(2026, 7, 29));
      expect(maxAuditRangeDays, 60);
    });

    test('param is yyyy-MM-dd', () {
      expect(CalendarWindow.param(DateTime(2026, 3, 5)), '2026-03-05');
    });
  });

  group('buildCalendarEntries', () {
    test('an audit in both feeds is ONE entry per day that belongs to both layers', () {
      final both = audit('a1', start: iso(2026, 11, 3));
      final entries = buildCalendarEntries(myAudits: [both], atMyLocation: [both], ncs: const []);
      expect(entries, hasLength(1));
      expect(entries.single.layers, {CalendarLayer.mine, CalendarLayer.location});
      expect(entries.single.isMine, isTrue);
      expect(entries.single.atMyLocation, isTrue);
      expect(entries.single.isOthers, isFalse);
    });

    test('one in the location feed only is somebody else\'s; one in mine only is not at my location', () {
      final entries = buildCalendarEntries(
        myAudits: [audit('mine', start: iso(2026, 11, 3))],
        atMyLocation: [audit('theirs', start: iso(2026, 11, 3))],
        ncs: const [],
      );
      final byId = {for (final e in entries) e.recordId: e};
      expect(byId['mine']!.layers, {CalendarLayer.mine});
      expect(byId['theirs']!.layers, {CalendarLayer.location});
      expect(byId['theirs']!.isOthers, isTrue);
    });

    test('a multi-day audit has an entry on every day of its range, numbered', () {
      final entries = buildCalendarEntries(
        myAudits: [audit('a1', start: iso(2026, 11, 9), end: iso(2026, 11, 11))],
        atMyLocation: const [],
        ncs: const [],
      );
      expect(entries.map((e) => e.day), [DateTime(2026, 11, 9), DateTime(2026, 11, 10), DateTime(2026, 11, 11)]);
      expect(entries.map((e) => e.dayNumber), [1, 2, 3]);
      expect(entries.every((e) => e.dayCount == 3 && e.isMultiDay), isTrue);
      expect(entries.map((e) => e.id).toSet(), hasLength(3), reason: 'each day is its own plotted item');
    });

    test('an audit with no scheduled date cannot be placed and is left out', () {
      final entries = buildCalendarEntries(
        myAudits: [AuditModel.fromJson({'_id': 'x', 'title': 'No date'})],
        atMyLocation: const [],
        ncs: const [],
      );
      expect(entries, isEmpty);
    });

    test('an NC is plotted on the day it was raised and on its due date (a closed one keeps both)', () {
      final entries = buildCalendarEntries(
        myAudits: const [],
        atMyLocation: const [],
        ncs: [nc('n1', start: iso(2026, 11, 2), target: iso(2026, 11, 10), status: 'Closed'), nc('n2', target: iso(2026, 11, 5))],
      );
      expect(entries.where((e) => e.recordId == 'n1').map((e) => (e.kind, e.day)), [
        (CalendarEntryKind.ncRaised, DateTime(2026, 11, 2)),
        (CalendarEntryKind.ncDue, DateTime(2026, 11, 10)),
      ]);
      expect(entries.where((e) => e.recordId == 'n2').single.kind, CalendarEntryKind.ncDue, reason: 'no raised date, no raised entry');
      expect(entries.every((e) => e.layers.single == CalendarLayer.nc), isTrue);
    });

    test('an NC is filed under the LOCAL day of its instant, not the UTC day', () {
      final instant = DateTime.utc(2026, 11, 10, 23, 30);
      final entries = buildCalendarEntries(
        myAudits: const [],
        atMyLocation: const [],
        ncs: [nc('n1', target: instant.toIso8601String())],
      );
      expect(entries.single.day, dayOnly(instant.toLocal()));
    });

    test('the same NC read twice (the due-window and the raised-window answers) is plotted once', () {
      final entries = buildCalendarEntries(
        myAudits: const [],
        atMyLocation: const [],
        ncs: [nc('n1', target: iso(2026, 11, 10)), nc('n1', target: iso(2026, 11, 10))],
      );
      expect(entries, hasLength(1));
    });

    test('"you are the auditee" reads the id the audit names, populated or bare', () {
      final named = audit('a1', start: iso(2026, 11, 3), auditee: [
        {'_id': 'me', 'employeeName': 'Me'},
      ]);
      final bare = AuditModel.fromJson({
        '_id': 'a2',
        'title': 'Bare',
        'scheduledDate': iso(2026, 11, 3),
        'auditeeIds': ['someone', 'me'],
      });
      final other = audit('a3', start: iso(2026, 11, 3), auditee: [
        {'_id': 'x', 'employeeName': 'X'},
      ]);
      final entries = buildCalendarEntries(
        myAudits: const [],
        atMyLocation: [named, bare, other],
        ncs: const [],
        selfEmployeeId: 'me',
      );
      expect({for (final e in entries) e.recordId: e.iAmAuditee}, {'a1': true, 'a2': true, 'a3': false});
      final nobody = buildCalendarEntries(myAudits: const [], atMyLocation: [named], ncs: const []);
      expect(nobody.single.iAmAuditee, isFalse, reason: 'unknown self id never marks anyone');
    });
  });

  group('entriesByDay and the layer switches', () {
    final entries = buildCalendarEntries(
      myAudits: [audit('both', title: 'B both', start: iso(2026, 11, 3)), audit('mine', title: 'A mine', start: iso(2026, 11, 3))],
      atMyLocation: [audit('both', title: 'B both', start: iso(2026, 11, 3)), audit('loc', title: 'C loc', start: iso(2026, 11, 3))],
      ncs: [nc('n1', target: iso(2026, 11, 3), start: iso(2026, 11, 3))],
    );
    final day = DateTime(2026, 11, 3);

    List<String> ids(Set<CalendarLayer> on) => [for (final e in entriesByDay(entries, on)[day] ?? <CalendarEntry>[]) e.id.split('@').first];

    test('every layer on: audits first (mine layer, then at my location; a day\'s audits by title), the NCs last — due before raised — each audit once', () {
      expect(ids({...CalendarLayer.values}), ['mine', 'both', 'loc', 'n1:ncDue', 'n1:ncRaised']);
    });

    test('mine off: an audit that is also at my location stays (it fits another layer that is on)', () {
      expect(ids({CalendarLayer.location, CalendarLayer.nc}), ['both', 'loc', 'n1:ncDue', 'n1:ncRaised']);
    });

    test('location off: it stays under mine; only-location audits go', () {
      expect(ids({CalendarLayer.mine, CalendarLayer.nc}), ['mine', 'both', 'n1:ncDue', 'n1:ncRaised']);
    });

    test('mine and location off: only the NCs', () {
      expect(ids({CalendarLayer.nc}), ['n1:ncDue', 'n1:ncRaised']);
    });

    test('everything off: nothing', () {
      expect(entriesByDay(entries, <CalendarLayer>{}), isEmpty);
    });

    test('an entry is listed under its first layer that is on', () {
      final both = entries.firstWhere((e) => e.recordId == 'both');
      expect(both.primaryLayer({...CalendarLayer.values}), CalendarLayer.mine);
      expect(both.primaryLayer({CalendarLayer.location}), CalendarLayer.location);
    });
  });

  group('CalendarMonthCounts', () {
    test('counts each audit once per layer however many days it lasts, and only the month on screen', () {
      final entries = buildCalendarEntries(
        myAudits: [
          audit('long', start: iso(2026, 11, 9), end: iso(2026, 11, 13)),
          audit('both', start: iso(2026, 11, 3)),
          audit('oct', start: iso(2026, 10, 20)),
        ],
        atMyLocation: [audit('both', start: iso(2026, 11, 3)), audit('loc', start: iso(2026, 11, 4))],
        ncs: [
          nc('n1', start: iso(2026, 11, 2), target: iso(2026, 11, 10)),
          nc('n2', start: iso(2026, 10, 2), target: iso(2026, 12, 10)),
        ],
      );
      final c = CalendarMonthCounts.of(entries, DateTime(2026, 11, 1));
      expect(c.mine, 2);
      expect(c.location, 2);
      expect(c.nc, 1);
      expect(c.ncRaised, 1);
      expect(c.ncDue, 1);
      expect(c.of(CalendarLayer.mine), 2);
    });
  });

  group('small helpers', () {
    test('the most urgent status wins a day cell\'s colour', () {
      List<CalendarEntry> of(List<String> statuses) => buildCalendarEntries(
        myAudits: [for (var i = 0; i < statuses.length; i++) audit('a$i', start: iso(2026, 11, 3), status: statuses[i])],
        atMyLocation: const [],
        ncs: const [],
      );
      expect(mostUrgentStatus(of(['Total Closed', 'In Progress', 'Overdue'])), 'Overdue');
      expect(mostUrgentStatus(of(['Not Started', 'In Progress'])), 'In Progress');
      expect(mostUrgentStatus(of(['Total Closed', 'Something New'])), 'Total Closed');
      expect(mostUrgentStatus(const []), isNull);
    });

    test('calendarRangeLabel', () {
      expect(calendarRangeLabel(DateTime(2026, 11, 10)), '10 Nov 2026');
      expect(calendarRangeLabel(DateTime(2026, 11, 10), DateTime(2026, 11, 10)), '10 Nov 2026');
      expect(calendarRangeLabel(DateTime(2026, 11, 10), DateTime(2026, 11, 14)), '10 – 14 Nov 2026');
      expect(calendarRangeLabel(DateTime(2026, 10, 28), DateTime(2026, 11, 3)), '28 Oct – 3 Nov 2026');
      expect(calendarRangeLabel(DateTime(2026, 12, 30), DateTime(2027, 1, 2)), '30 Dec 2026 – 2 Jan 2027');
    });

    test('daysInAuditRange steps by calendar day and stops at the cap', () {
      final long = audit('a', start: iso(2026, 1, 1), end: iso(2026, 12, 31));
      expect(daysInAuditRange(long), hasLength(maxAuditRangeDays));
      expect(daysInAuditRange(long).last, DateTime(2026, 3, 1));
    });
  });

  group('the Calendar\'s requests', () {
    late FakeAdapter adapter;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      SocketService.debugInstance = FakeSockets().service;
      adapter = FakeAdapter()..handler = (o) async => json(200, {'isOk': true, 'data': []});
      DioClient.instance.dio.httpClientAdapter = adapter;
    });

    AuditsProvider auditsProvider() => AuditsProvider()..setSelfEmployeeId('me');
    NcProvider ncProvider() => NcProvider()..setSelfEmployeeId('me');

    test('without a window they ask exactly what they always did (Me, no dates)', () async {
      await Future.wait([auditsProvider().fetchCalendarAudits(), ncProvider().fetchCalendarNcs(), auditsProvider().fetchCalendarAtMyLocation()]);
      expect(adapter.where('GET', ApiConstants.myAudits).single.queryParameters, {'employeeIds': 'me'});
      expect(adapter.where('GET', ApiConstants.ncsMine).single.queryParameters, {'employeeIds': 'me'});
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation).single.queryParameters, isEmpty);
    });

    test('with the window: audits and audits at my location are windowed by start date (reaching back 60 days), NCs twice — by due date and by raised date', () async {
      final window = CalendarWindow.around(DateTime(2026, 11, 1));
      final audits = auditsProvider()..setCalendarWindow(window);
      final ncs = ncProvider()..setCalendarWindow(window);
      await Future.wait([audits.fetchCalendarAudits(), ncs.fetchCalendarNcs(), audits.fetchCalendarAtMyLocation()]);

      expect(adapter.where('GET', ApiConstants.myAudits).single.queryParameters, {
        'employeeIds': 'me',
        'fromDate': '2026-07-29',
        'toDate': '2027-01-04',
      });
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation).single.queryParameters, {
        'fromDate': '2026-07-29',
        'toDate': '2027-01-04',
      });
      final ncReqs = adapter.where('GET', ApiConstants.ncsMine).map((r) => r.queryParameters).toList();
      expect(ncReqs, unorderedEquals([
        {'employeeIds': 'me', 'dueFrom': '2026-09-27', 'dueTo': '2027-01-04'},
        {'employeeIds': 'me', 'fromDate': '2026-09-27', 'toDate': '2027-01-04'},
      ]));
    });

    test('a Date range picked on another screen never narrows the Calendar; place and type picks do', () async {
      final window = CalendarWindow.around(DateTime(2026, 11, 1));
      final audits = auditsProvider()
        ..setCalendarWindow(window)
        ..setFilterState(
          dateRange: (DateTime(2026, 10, 1), DateTime(2026, 10, 31)),
          locations: ['l1'],
          departments: ['d1'],
          auditTypes: ['Safety'],
        );
      final ncs = ncProvider()
        ..setCalendarWindow(window)
        ..setFilterState(dateRange: (DateTime(2026, 10, 1), DateTime(2026, 10, 31)), locations: ['l1']);
      await Future.wait([audits.fetchCalendarAudits(), ncs.fetchCalendarNcs(), audits.fetchCalendarAtMyLocation()]);

      expect(adapter.where('GET', ApiConstants.myAudits).single.queryParameters, {
        'employeeIds': 'me',
        'locationIds': 'l1',
        'departmentIds': 'd1',
        'auditType': 'Safety',
        'fromDate': '2026-07-29',
        'toDate': '2027-01-04',
      });
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation).single.queryParameters, {
        'locationIds': 'l1',
        'departmentIds': 'd1',
        'auditType': 'Safety',
        'fromDate': '2026-07-29',
        'toDate': '2027-01-04',
      });
      for (final r in adapter.where('GET', ApiConstants.ncsMine)) {
        expect(r.queryParameters['fromDate'] ?? r.queryParameters['dueFrom'], '2026-09-27');
        expect(r.queryParameters['locationIds'], 'l1');
      }
      // The shared pick itself is untouched — the Audits tab still uses it.
      expect(audits.dateFrom, DateTime(2026, 10, 1));
    });

    test('the NC answers of the two windows are merged by id', () async {
      adapter.handler = (o) async {
        final due = o.queryParameters.containsKey('dueFrom');
        return json(200, {
          'isOk': true,
          'data': [
            {'_id': 'shared', 'title': 'Both windows', 'targetDate': iso(2026, 11, 10)},
            {'_id': due ? 'only-due' : 'only-raised', 'title': 'One window'},
          ],
        });
      };
      final ncs = ncProvider()..setCalendarWindow(CalendarWindow.around(DateTime(2026, 11, 1)));
      await ncs.fetchCalendarNcs();
      expect(ncs.calendarNcs.map((n) => n.id), unorderedEquals(['shared', 'only-due', 'only-raised']));
      expect(ncs.calendarNcsError, isNull);
      expect(ncs.calendarNcsTruncated, isFalse);
    });

    test('a truncated bare NC list is noted, not silent', () async {
      adapter.handler = (o) async => json(200, {'isOk': true, 'data': <Object>[], 'truncated': true});
      final ncs = ncProvider();
      await ncs.fetchCalendarNcs();
      expect(ncs.calendarNcsTruncated, isTrue);
    });

    test('a failed read keeps what was showing, says so, and clears when the next read works', () async {
      adapter.handler = (o) async => json(200, {
        'isOk': true,
        'data': [
          {'_id': 'a1', 'title': 'Kept', 'scheduledDate': iso(2026, 11, 3)},
        ],
      });
      final audits = auditsProvider();
      await Future.wait([audits.fetchCalendarAudits(), audits.fetchCalendarAtMyLocation()]);
      expect(audits.calendarAudits.single.title, 'Kept');
      expect(audits.calendarAuditsError, isNull);

      adapter.handler = (o) async => connectionError(o);
      await Future.wait([audits.fetchCalendarAudits(), audits.fetchCalendarAtMyLocation()]);
      expect(audits.calendarAudits.single.title, 'Kept');
      expect(audits.calendarAtMyLocation.single.title, 'Kept');
      expect(audits.calendarAuditsError, isNotNull);
      expect(audits.calendarAtMyLocationError, isNotNull);
      expect(audits.isLoadingCalendarAudits, isFalse);
      expect(audits.isLoadingCalendarAtMyLocation, isFalse);

      adapter.handler = (o) async => json(200, {'isOk': true, 'data': <Object>[]});
      await Future.wait([audits.fetchCalendarAudits(), audits.fetchCalendarAtMyLocation()]);
      expect(audits.calendarAuditsError, isNull);
      expect(audits.calendarAtMyLocationError, isNull);
    });

    test('a row that cannot be parsed is an error too — it no longer escapes and hangs the first load', () async {
      adapter.handler = (o) async => json(200, {
        'isOk': true,
        'data': [
          {'_id': 'bad', 'title': 'Bad', 'batchZoneCount': 'not a number'},
        ],
      });
      final audits = auditsProvider();
      await audits.fetchCalendarAudits(); // completes, does not throw
      expect(audits.calendarAuditsError, isNotNull);
      expect(audits.isLoadingCalendarAudits, isFalse);
    });

    test('a 500 carries the server\'s own message', () async {
      adapter.handler = (o) async => json(500, {'isOk': false, 'message': 'Database is down'});
      final ncs = ncProvider();
      await ncs.fetchCalendarNcs();
      expect(ncs.calendarNcsError, contains('Database is down'));
    });

    test('logout empties the Calendar\'s own lists, window and errors', () async {
      adapter.handler = (o) async => json(200, {
        'isOk': true,
        'data': [
          {'_id': 'a1', 'title': 'Old account', 'scheduledDate': iso(2026, 11, 3)},
        ],
      });
      final window = CalendarWindow.around(DateTime(2026, 11, 1));
      final audits = auditsProvider()..setCalendarWindow(window);
      final ncs = ncProvider()..setCalendarWindow(window);
      await Future.wait([audits.fetchCalendarAudits(), audits.fetchCalendarAtMyLocation(), ncs.fetchCalendarNcs()]);
      expect(audits.calendarAtMyLocation, isNotEmpty);

      audits.resetForLogout();
      ncs.resetForLogout();
      expect(audits.calendarAudits, isEmpty);
      expect(audits.calendarAtMyLocation, isEmpty);
      expect(audits.calendarWindow, isNull);
      expect(ncs.calendarNcs, isEmpty);
      expect(ncs.calendarWindow, isNull);
    });

    test('a read that was on the wire at logout is dropped, and so is its failure', () async {
      final gate = <Future<void>>[];
      adapter.handler = (o) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        throw DioException(requestOptions: o, type: DioExceptionType.connectionError);
      };
      final audits = auditsProvider();
      final fetch = audits.fetchCalendarAtMyLocation();
      gate.add(fetch);
      audits.resetForLogout();
      await Future.wait(gate);
      expect(audits.calendarAtMyLocationError, isNull);
    });

    test('while the Calendar is open an audit_* notification re-reads its audits and the audits at my places', () async {
      final sockets = FakeSockets();
      SocketService.debugInstance = sockets.service;
      SocketService.instance.connect('jwt');
      final audits = auditsProvider()
        ..calendarInUse = true
        ..startListening();
      sockets.sockets.single.receive('new_notification', {'type': 'audit_assigned'});
      await Future<void>.delayed(const Duration(milliseconds: 700));

      expect(adapter.where('GET', ApiConstants.myAudits), isNotEmpty);
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation), isNotEmpty);
      // fetchMyAudits (the list) + fetchCalendarAudits (own) both read /audits/mine.
      expect(adapter.where('GET', ApiConstants.myAudits).length, 2);
      audits.stopListening();
    });

    test('a filter change re-reads the Calendar\'s lists, and the long-standing audits-at-my-location list still works', () async {
      final audits = auditsProvider()..calendarInUse = true;
      await audits.applyFilters(auditTypes: ['Safety']);
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation), hasLength(2),
          reason: 'fetchAuditsAtMyLocation (unchanged) + the Calendar\'s own');
      expect(audits.auditsAtMyLocation, isEmpty);
    });
  });
}
