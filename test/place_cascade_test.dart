import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/place_cascade.dart';
import 'package:internal_audit_app/models/employee_option.dart';
import 'package:internal_audit_app/models/location_option.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/widgets/filter_sheet.dart';
import 'package:provider/provider.dart';

import 'support/session_fakes.dart';

/// The Location <-> People cascade: the pure helpers (a port of the web's
/// client/src/utils/placeCascade.test.js), the resolver the filter sheet and bar
/// share, and the sheet itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const locations = [
    LocationOption(id: 'z1', name: 'Zone 1', locationType: 'Zone'),
    LocationOption(
      id: 's1',
      name: 'Sub 1',
      locationType: 'SubZone',
      parentZoneId: 'z1',
    ),
    LocationOption(
      id: 's2',
      name: 'Sub 2',
      locationType: 'SubZone',
      parentZoneId: 'z1',
    ),
    LocationOption(id: 'z2', name: 'Zone 2', locationType: 'Zone'),
    LocationOption(id: 'a1', name: 'Area 1', locationType: 'Area'),
  ];

  const p1 = EmployeeOption(id: 'p1', name: 'Asha', locationIds: ['s1']);
  const p2 = EmployeeOption(
    id: 'p2',
    name: 'Bilal',
    locationIds: ['z2'],
    departmentIds: ['d1'],
  );
  const p3 = EmployeeOption(id: 'p3', name: 'Chitra', locationIds: ['a1']);
  const p4 = EmployeeOption(id: 'p4', name: 'Dev');
  const people = [p1, p2, p3, p4];

  List<String> ids(Iterable<EmployeeOption> l) => [for (final e in l) e.id];

  group('placeCascade helpers (web parity)', () {
    test('hasPlacePick ignores All and the none sentinel', () {
      expect(hasPlacePick(locationIds: [], departmentIds: []), isFalse);
      expect(hasPlacePick(locationIds: ['__none__'], departmentIds: []), isFalse);
      expect(hasPlacePick(locationIds: [], departmentIds: ['d1']), isTrue);
      expect(hasPlacePick(), isFalse);
    });

    test('picking a Zone brings in its Sub Zones', () {
      final e = expandPlaces(
        locationIds: ['z1'],
        departmentIds: [],
        locations: locations,
      );
      expect(e.locations.toList()..sort(), ['s1', 's2', 'z1']);
    });

    test('only the people of the picked place are offered', () {
      expect(
        ids(placeMembers(people, locationIds: ['z2'], locations: locations)),
        ['p2'],
      );
      expect(
        ids(placeMembers(people, locationIds: ['z1'], locations: locations)),
        ['p1'],
        reason: 'a Zone includes its Sub Zone people',
      );
      expect(
        ids(placeMembers(people, locationIds: ['a1'], locations: locations)),
        ['p3'],
      );
      expect(
        ids(placeMembers(people, departmentIds: ['d1'], locations: locations)),
        ['p2'],
      );
    });

    test('a person with no place is offered under no place', () {
      expect(
        placeMembers(
          people,
          locationIds: ['z1', 'z2', 'a1'],
          departmentIds: ['d1'],
          locations: locations,
        ).any((p) => p.id == 'p4'),
        isFalse,
      );
    });

    test('picking people offers only their places (with the Zone above a Sub Zone)', () {
      final r = placesOfPeople([p1], locations);
      expect(r.locations.toList()..sort(), ['s1', 'z1'],
          reason: 'the Zone above, and (via the Zone) not its other Sub Zone');
      expect(r.departments, isEmpty);
      final r2 = placesOfPeople([p2], locations);
      expect(r2.locations, {'z2'});
      expect(r2.departments, {'d1'});
    });

    test('a person of a Zone brings that Zone\'s Sub Zones along', () {
      const zoneMan = EmployeeOption(id: 'p5', name: 'Zed', locationIds: ['z1']);
      final r = placesOfPeople([zoneMan], locations);
      expect(r.locations.toList()..sort(), ['s1', 's2', 'z1']);
    });
  });

  group('WhoCascade', () {
    const qa = TeamRef(id: 't1', name: 'QA');
    const ops = TeamRef(id: 't2', name: 'Ops');
    const dir = [
      EmployeeOption(id: 'p1', name: 'Asha', locationIds: ['s1'], teams: [qa]),
      EmployeeOption(
        id: 'p2',
        name: 'Bilal',
        locationIds: ['z2'],
        departmentIds: ['d1'],
        teams: [ops],
      ),
      EmployeeOption(id: 'p3', name: 'Chitra', locationIds: ['a1'], teams: [qa]),
    ];

    WhoCascade resolve({
      List<String> teams = const [],
      List<String> members = const [],
      List<String> locs = const [],
      List<String> depts = const [],
      List<String> untouched = const [],
      List<EmployeeOption> directory = dir,
    }) => WhoCascade.resolve(
      directory: directory,
      locations: locations,
      teams: teams,
      members: members,
      locationIds: locs,
      departmentIds: depts,
      untouchedMembers: untouched,
    );

    test('no place, no picks: the whole directory, nothing narrowed', () {
      final w = resolve();
      expect(ids(w.pool), ['p1', 'p2', 'p3']);
      expect(w.placeRestriction, isNull);
      expect(w.placeApplies, isFalse);
    });

    test('a picked place leaves only its people in play, and teams of those people', () {
      final w = resolve(locs: ['z1']);
      expect(ids(w.pool), ['p1']);
      expect(w.placeApplies, isTrue);
      // Untouched Team / Members do not narrow the Location list.
      expect(w.placeRestriction, isNull);
      final d = resolve(depts: ['d1']);
      expect(ids(d.pool), ['p2']);
    });

    test('picks outside the place are set aside, not dropped', () {
      final w = resolve(teams: ['t1', 't2'], members: ['p2'], locs: ['z1']);
      expect(w.teams, ['t1']);
      expect(w.heldTeams, ['t2']);
      expect(w.members, isEmpty);
      expect(w.heldMembers, ['p2']);
      // Applied: the team's people WITHIN the place.
      expect(w.teamMembers, ['p1']);
      // The same picks with the place cleared are all live again.
      final back = resolve(teams: ['t1', 't2'], members: ['p2']);
      expect(back.teams, ['t1', 't2']);
      expect(back.heldTeams, isEmpty);
      expect(back.members, ['p2']);
      expect(back.heldMembers, isEmpty);
    });

    test('a team narrows the Location list to its people\'s places', () {
      final w = resolve(teams: ['t2']);
      expect(w.placeRestriction!.locations, {'z2'});
      expect(w.placeRestriction!.departments, {'d1'});
      final both = resolve(teams: ['t1']);
      expect(both.placeRestriction!.locations.toList()..sort(), ['a1', 's1', 'z1']);
    });

    test('picked Members narrow the Location list to their places', () {
      final w = resolve(members: ['p1']);
      expect(w.placeRestriction!.locations.toList()..sort(), ['s1', 'z1']);
    });

    test('untouched defaults (Me) do not narrow the Location list', () {
      // "Me" picked by hand equals the default: no narrowing.
      expect(resolve(members: ['p1'], untouched: ['p1']).placeRestriction, isNull);
      // But with a team also picked it is a real pick.
      expect(
        resolve(teams: ['t1'], members: ['p1'], untouched: ['p1']).placeRestriction,
        isNotNull,
      );
      // And a different person is never the default.
      expect(resolve(members: ['p2'], untouched: ['p1']).placeRestriction, isNotNull);
    });

    test('a team nobody at the place belongs to is set aside', () {
      final w = resolve(teams: ['t2'], depts: ['d1']);
      expect(w.teams, ['t2']); // Bilal is in d1
      final other = resolve(teams: ['t2'], locs: ['a1']);
      expect(other.teams, isEmpty);
      expect(other.heldTeams, ['t2']);
      expect(other.teamMembers, isEmpty);
    });

    test('without the directory nothing is narrowed or set aside', () {
      final w = resolve(
        teams: ['t2'],
        members: ['p2'],
        locs: ['z1'],
        directory: const [],
      );
      expect(w.teams, ['t2']);
      expect(w.members, ['p2']);
      expect(w.heldTeams, isEmpty);
      expect(w.placeRestriction, isNull);
      expect(w.placeApplies, isFalse);
    });

    test('EmployeeOption reads departmentIds (bare or populated)', () {
      final e = EmployeeOption.fromJson({
        '_id': 'x',
        'employeeName': 'X',
        'locationIds': ['z1'],
        'departmentIds': [
          'd1',
          {'_id': 'd2'},
        ],
      });
      expect(e.departmentIds, ['d1', 'd2']);
      expect(e.locationIds, ['z1']);
      expect(
        EmployeeOption.fromJson({'_id': 'y', 'employeeName': 'Y'}).departmentIds,
        isEmpty,
      );
    });
  });

  group('the filter sheet', () {
    late FakeAdapter adapter;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      adapter = FakeAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
      Map<String, dynamic> emp(
        String id,
        String name,
        List<String> locs,
        List<String> depts,
        Map<String, String> team,
      ) => {
        '_id': id,
        'employeeName': name,
        'locationIds': locs,
        'departmentIds': depts,
        'teamIds': [team],
        'isActive': true,
      };
      const qa = {'_id': 't1', 'teamName': 'QA'};
      const ops = {'_id': 't2', 'teamName': 'Ops'};
      const solo = {'_id': 't3', 'teamName': 'Solo'};
      adapter.handler = (o) async {
        switch (o.path) {
          case '/employees/my-hierarchy-scope':
            return json(200, {
              'isOk': true,
              'data': [
                emp('p1', 'Asha', ['s1'], [], qa),
                emp('p2', 'Bilal', ['z2'], ['d1'], ops),
                emp('p3', 'Chitra', ['a1'], [], qa),
                emp('p4', 'Dev', [], [], solo),
              ],
            });
          case '/locations/my-scope':
            return json(200, {
              'isOk': true,
              'data': [
                {'_id': 'z1', 'name': 'Zone 1', 'locationType': 'Zone'},
                {
                  '_id': 's1',
                  'name': 'Sub 1',
                  'locationType': 'SubZone',
                  'parentZoneId': 'z1',
                  'parentZoneName': 'Zone 1',
                },
                {
                  '_id': 's2',
                  'name': 'Sub 2',
                  'locationType': 'SubZone',
                  'parentZoneId': 'z1',
                  'parentZoneName': 'Zone 1',
                },
                {'_id': 'z2', 'name': 'Zone 2', 'locationType': 'Zone'},
                {'_id': 'a1', 'name': 'Area 1', 'locationType': 'Area'},
              ],
              'departments': [
                {'_id': 'd1', 'departmentName': 'Quality'},
                {'_id': 'd2', 'departmentName': 'Stores'},
              ],
              'departmentsByLocation': {},
              'meta': {'fullAccess': true},
            });
        }
        return json(200, {'isOk': true, 'data': []});
      };
    });

    Future<Future<AuditFilterSelection?> Function()> open(
      WidgetTester tester,
      AuditFilterSelection initial,
    ) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<AuditFilterSelection?>? pending;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AuthProvider()),
            ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () =>
                      pending = showAuditFilterSheet(context, initial: initial),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () async {
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        return pending!;
      };
    }

    Future<void> openTeamPicker(WidgetTester tester) async {
      await tester.tap(find.text('Team').first);
      await tester.pumpAndSettle();
    }

    Future<void> openMembersPicker(WidgetTester tester) async {
      await tester.tap(find.text('Members').first);
      await tester.pumpAndSettle();
    }

    Future<void> openWhere(WidgetTester tester) async {
      await tester.tap(find.text('Location & Department'));
      await tester.pumpAndSettle();
    }

    testWidgets('a picked Zone offers only the teams and members of its people (Sub Zones included)', (tester) async {
      await open(tester, const AuditFilterSelection(locations: ['z1']));

      await openTeamPicker(tester);
      // Asha is in Sub 1 of Zone 1: only her team, counted over the place.
      expect(find.text('QA'), findsOneWidget);
      expect(find.text('1 person'), findsOneWidget);
      expect(find.text('Ops'), findsNothing);
      expect(find.text('Solo'), findsNothing);
      await tester.tap(find.text('Apply teams')); // confirm, nothing ticked
      await tester.pumpAndSettle();

      await openMembersPicker(tester);
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bilal'), findsNothing);
      expect(find.text('Chitra'), findsNothing);
      // Nobody without a place is "at" one.
      expect(find.text('Dev'), findsNothing);
    });

    testWidgets('a picked Department offers only its people', (tester) async {
      await open(tester, const AuditFilterSelection(departments: ['d1']));
      await openMembersPicker(tester);
      expect(find.text('Bilal'), findsOneWidget);
      expect(find.text('Asha'), findsNothing);
    });

    testWidgets('picked people narrow the Location list to their places', (tester) async {
      await open(tester, const AuditFilterSelection(teams: ['t2'], teamMembers: ['p2']));
      await openWhere(tester);
      expect(find.text('Zone 2'), findsOneWidget);
      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('Zone 1'), findsNothing);
      expect(find.text('Sub 1'), findsNothing);
      expect(find.text('Area 1'), findsNothing);
      expect(find.text('Stores'), findsNothing);
    });

    testWidgets('a person of a Sub Zone brings the Zone above it along', (tester) async {
      await open(tester, const AuditFilterSelection(employees: ['p1']));
      await openWhere(tester);
      expect(find.text('Zone 1'), findsOneWidget);
      expect(find.text('Sub 1'), findsOneWidget);
      expect(find.text('Sub 2'), findsNothing);
      expect(find.text('Zone 2'), findsNothing);
      expect(find.text('Area 1'), findsNothing);
    });

    testWidgets('untouched Me / All Members do not narrow the Location list', (tester) async {
      await open(tester, const AuditFilterSelection());
      await openWhere(tester);
      for (final name in ['Zone 1', 'Sub 1', 'Sub 2', 'Zone 2', 'Area 1']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text('Quality'), findsOneWidget);
      expect(find.text('Stores'), findsOneWidget);
    });

    testWidgets('a team outside the picked place is set aside, kept, and comes back when the place is cleared', (tester) async {
      final apply = await open(
        tester,
        const AuditFilterSelection(
          teams: ['t2'],
          teamMembers: ['p2'],
          locations: ['z1'],
        ),
      );
      // Ops has nobody at Zone 1: not offered, not applied.
      expect(find.text('All teams'), findsOneWidget);
      expect(find.text('Ops'), findsNothing);

      // Applying keeps the pick as held; what is applied (and sent) is clean.
      var result = (await apply())!;
      expect(result.teams, isEmpty);
      expect(result.teamMembers, isEmpty);
      expect(result.employees, isEmpty);
      expect(result.heldTeams, ['t2']);
      expect(result.locations, ['z1']);

      // Re-open with the held pick (as the provider hands it back), clear the
      // place, and the team is live again.
      final apply2 = await open(
        tester,
        AuditFilterSelection(
          locations: const ['z1'],
          heldTeams: result.heldTeams,
        ),
      );
      expect(find.text('All teams'), findsOneWidget);
      await openWhere(tester);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Ops'), findsOneWidget);
      result = (await apply2())!;
      expect(result.teams, ['t2']);
      expect(result.teamMembers, ['p2']);
      expect(result.heldTeams, isEmpty);
      expect(result.locations, isEmpty);
    });

    testWidgets('a member outside the picked place is set aside; the scope sent matches what the sheet shows', (tester) async {
      final apply = await open(
        tester,
        const AuditFilterSelection(employees: ['p2', 'p1'], locations: ['z1']),
      );
      // Asha (Zone 1) stays; Bilal (Zone 2) is set aside.
      expect(find.text('Asha'), findsOneWidget);
      expect(find.text('Bilal'), findsNothing);
      final result = (await apply())!;
      expect(result.employees, ['p1']);
      expect(result.heldEmployees, ['p2']);
    });

    testWidgets('picking a team under a place resolves its members WITHIN the place', (tester) async {
      final apply = await open(tester, const AuditFilterSelection(locations: ['a1']));
      await openTeamPicker(tester);
      // QA has Asha (Zone 1) and Chitra (Area 1): only Chitra is at the place.
      expect(find.text('1 person'), findsOneWidget);
      await tester.tap(find.text('QA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply teams (1)'));
      await tester.pumpAndSettle();
      final result = (await apply())!;
      expect(result.teams, ['t1']);
      expect(result.teamMembers, ['p3']);
      expect(result.locations, ['a1']);
    });

    testWidgets('the scope the provider sends is the applied one (held picks never leak)', (tester) async {
      final apply = await open(
        tester,
        const AuditFilterSelection(
          teams: ['t2'],
          teamMembers: ['p2'],
          locations: ['z1'],
        ),
      );
      final result = (await apply())!;
      final audits = AuditsProvider()..setSelfEmployeeId('me');
      audits.setFilterState(
        isTeam: result.isTeam,
        employees: result.employees,
        teams: result.teams,
        teamMembers: result.teamMembers,
        heldTeams: result.heldTeams,
        heldEmployees: result.heldEmployees,
        locations: result.locations,
        departments: result.departments,
      );
      // Ops is set aside: back to the Me default, at Zone 1 — never "nobody",
      // never Bilal.
      expect(audits.filterParams, {'employeeIds': 'me', 'locationIds': 'z1'});
      expect(audits.heldTeamFilter, ['t2']);
      // Clearing wipes the held picks too.
      audits.setFilterState(heldTeams: const [], heldEmployees: const []);
      expect(audits.heldTeamFilter, isEmpty);
    });
  });
}
