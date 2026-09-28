import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/report_stats.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/models/employee_option.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/screens/audits/my_audits_screen.dart';
import 'package:internal_audit_app/screens/profile/reports_screen.dart';
import 'package:internal_audit_app/screens/audits/select_representative_sheet.dart';
import 'package:internal_audit_app/widgets/audit_agenda.dart';
import 'package:internal_audit_app/widgets/audit_filter_bar.dart';
import 'package:internal_audit_app/widgets/filter_sheet.dart';
import 'package:internal_audit_app/widgets/picker_sheet.dart';
import 'package:provider/provider.dart';

import 'support/session_fakes.dart';

/// The pickers, the shared filter state that mirrors the web portal's filters,
/// and the accordion / keep-my-place behaviour of the lists.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    adapter = FakeAdapter()..handler = (o) async => json(200, {'isOk': true, 'data': []});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  void usePhone(WidgetTester tester, {double height = 1400}) {
    tester.view.physicalSize = Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  group('filter params follow the server semantics', () {
    test('Me is the default: an explicit self, and a Location narrows it, never widens it', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      expect(p.filterParams, {'employeeIds': 'me'});
      p.setFilterState(locations: ['zoneA']);
      expect(p.filterParams, {'employeeIds': 'me', 'locationIds': 'zoneA'});
    });

    test('All Members sends NO employeeIds, so a Location shows every audit there', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      p.setFilterState(isTeam: true, locations: ['zoneA'], departments: ['qa']);
      expect(p.filterParams, {'locationIds': 'zoneA', 'departmentIds': 'qa'});
    });

    test('a Team means its members; picked Members win over the Team', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      p.setFilterState(teams: ['t1'], teamMembers: ['a', 'b']);
      expect(p.filterParams, {'employeeIds': 'a,b'});
      p.setFilterState(employees: ['b']);
      expect(p.filterParams, {'employeeIds': 'b'});
      // A team nobody belongs to matches nobody — not everyone.
      p.setFilterState(employees: [], teamMembers: []);
      expect(p.filterParams, {'employeeIds': '__none__'});
    });

    test('date range, audit type; Include skipped is list-only; flag is NC-only', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      p.setFilterState(
        auditTypes: ['Safety', 'Quality'],
        dateRange: (DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
        includeSkipped: true,
        flags: ['Major'],
      );
      expect(p.filterParams, {
        'employeeIds': 'me',
        'auditType': 'Safety,Quality',
        'fromDate': '2026-09-01',
        'toDate': '2026-09-30',
      });
      expect(p.listFilterParams!['includeSkipped'], 'true');
      expect(p.filterParams!.containsKey('includeSkipped'), isFalse);
      expect(p.ncFilterParams!['severity'], 'Major');
    });

    test('the badge counts each facet once and can ignore what a screen does not offer', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      expect(p.activeFilterCount, 0); // Me alone is the resting state
      p.setFilterState(
        isTeam: true,
        locations: ['a'],
        departments: ['d'],
        statuses: ['Overdue'],
        includeSkipped: true,
      );
      // All Members + one "where" facet + status + skipped
      expect(p.activeFilterCount, 4);
      expect(p.activeFilterCountFor(status: false), 2);
    });

    test('Status is matched client-side by any pick; Skipped only shows with the switch', () {
      final p = AuditsProvider();
      AuditModel a(String id, String status, {String? display}) =>
          AuditModel(id: id, title: id, scope: '', status: status, displayStatus: display);
      final overdue = a('o', 'In Progress', display: 'Overdue');
      final running = a('r', 'In Progress', display: 'In Progress');
      final skipped = a('s', 'Skipped');
      p.audits = [overdue, running, skipped];
      expect(p.visibleAudits, hasLength(3));
      p.setFilterState(statuses: ['Overdue', 'In Progress']);
      expect(p.visibleAudits.map((e) => e.id), ['o', 'r']);
      p.setFilterState(includeSkipped: true);
      expect(p.visibleAudits.map((e) => e.id), ['o', 'r', 's']);
    });

    test('logout puts every filter back', () {
      final p = NcProvider()..setSelfEmployeeId('me');
      p.setFilterState(isTeam: true, teams: ['t'], locations: ['l'], flags: ['Major'], includeSkipped: true);
      p.resetForLogout();
      expect(p.activeFilterCount, 0);
      expect(p.isTeamScope, isFalse);
      expect(p.flagFilter, isEmpty);
    });
  });

  group('Final Report tiles', () {
    AuditModel done(String id, double got, double of, String timeliness, {String? batch}) => AuditModel(
      id: id,
      title: id,
      scope: '',
      status: 'Completed',
      timeliness: timeliness,
      scoreAchieved: got,
      scoreMax: of,
      scheduleBatchId: batch,
    );

    test('the score is Σ achieved / Σ possible, never an average of percentages', () {
      // 100% of 10 and 0% of 90: an average would say 50, the truth is 10.
      final stats = ReportStats.fromAudits([
        done('a', 10, 10, 'On-Time Completed'),
        done('b', 0, 90, 'Delayed Completed'),
      ]);
      expect(stats.percentage, 10);
      expect(stats.totalAudits, 2);
      expect(stats.onTimeCompleted, 1);
      expect(stats.delayedCompleted, 1);
    });

    test('a bundle counts once, and Delayed if any zone was late', () {
      final stats = ReportStats.fromAudits([
        done('z1', 5, 10, 'On-Time Completed', batch: 'b'),
        done('z2', 5, 10, 'Delayed Completed', batch: 'b'),
      ]);
      expect(stats.totalAudits, 1);
      expect(stats.delayedCompleted, 1);
      expect(stats.onTimeCompleted, 0);
      expect(stats.percentage, 50);
    });

    test('the server object is read as is, anything else is not stats', () {
      final s = ReportStats.tryParse({
        'percentage': 82.4,
        'achieved': 412,
        'maxPossible': 500,
        'totalAudits': 9,
        'onTimeCompleted': 6,
        'delayedCompleted': 2,
      })!;
      expect(s.percentage, 82);
      expect(s.totalAudits, 9);
      expect(ReportStats.tryParse(<dynamic>[]), isNull);
    });
  });

  group('agenda accordion', () {
    test('opening a sibling closes the open one; nested groups keep their parent open', () {
      final e = AgendaExpansion();
      e.toggleDay('day:1');
      e.toggleDay('day:2');
      expect(e.isDayExpanded('day:1'), isFalse);
      expect(e.isDayExpanded('day:2'), isTrue);

      e.toggleMonth('month:9');
      e.toggleSeries('month:9/series:x', parent: 'month:9');
      expect(e.isMonthExpanded('month:9'), isTrue);
      expect(e.isSeriesExpanded('month:9/series:x'), isTrue);
      // day:2 was a sibling of month:9 at the top level.
      expect(e.isDayExpanded('day:2'), isFalse);

      // Another top-level group folds month:9 AND what was open inside it.
      e.toggleMonth('month:10');
      expect(e.isMonthExpanded('month:9'), isFalse);
      expect(e.isSeriesExpanded('month:9/series:x'), isFalse);
      e.toggleMonth('month:9');
      expect(e.isSeriesExpanded('month:9/series:x'), isFalse, reason: 're-opening starts fresh');
    });

    test('the past region is one group of the top level; tapping Today folds everything', () {
      final e = AgendaExpansion();
      e.pastExpanded = true;
      e.toggleMonth('month:8', parent: AgendaExpansion.pastKey);
      expect(e.pastExpanded, isTrue);
      expect(e.isMonthExpanded('month:8'), isTrue);
      // A forward group folds the past region.
      e.toggleDay('day:1');
      expect(e.pastExpanded, isFalse);
      e.collapseAll();
      expect(e.anyExpanded, isFalse);
    });

    test('logout empties what the lists remember', () {
      final m = ListViewMemory();
      m.agendaExpansion.toggleDay('day:1');
      m.screen('audits')
        ..search = 'x'
        ..scroll = 120;
      m.resetForLogout();
      expect(m.agendaExpansion.anyExpanded, isFalse);
      expect(m.screen('audits').search, isEmpty);
      expect(m.screen('audits').scroll, 0);
    });
  });

  group('picker sheet', () {
    Widget host(Widget Function(BuildContext) open, {double textScale = 1}) => MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: Builder(builder: open)),
    );

    final people = [
      for (final n in ['Asha Menon', 'Ravi Kumar', 'Sara Khan', 'Tom Lee', 'Uma Rao', 'Vik Shah', 'Wen Li', 'Xu Ping'])
        EmployeeOption(id: n.split(' ').first.toLowerCase(), name: n),
    ];

    testWidgets('representative: search narrows, Confirm needs a pick and returns the ids', (tester) async {
      usePhone(tester);
      List<String>? result;
      await tester.pumpWidget(host((context) => TextButton(
        onPressed: () async => result = await showSelectRepresentativeSheet(context, employees: people),
        child: const Text('open'),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Eight people: a search box is offered, and Confirm is disabled.
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      expect(find.text('Select at least 1'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'khan');
      await tester.pumpAndSettle();
      expect(find.text('Sara Khan'), findsOneWidget);
      expect(find.text('Asha Menon'), findsNothing);
      await tester.tap(find.text('Sara Khan'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm (1)'), findsOneWidget);

      // The selection survives clearing the search.
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tom Lee'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm (2)'), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(result, ['sara', 'tom']);
    });

    testWidgets('an already chosen representative arrives ticked', (tester) async {
      usePhone(tester);
      await tester.pumpWidget(host((context) => TextButton(
        onPressed: () => showSelectRepresentativeSheet(context, employees: people, initiallySelected: ['ravi']),
        child: const Text('open'),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Change Representative Auditee'), findsOneWidget);
      expect(find.text('Confirm (1)'), findsOneWidget);
    });

    testWidgets('dismissing returns null and a single picker returns the tapped value', (tester) async {
      usePhone(tester);
      String? picked = 'unchanged';
      await tester.pumpWidget(host((context) => TextButton(
        onPressed: () async => picked = await showSinglePickerSheet<String>(
          context,
          title: 'Pick',
          items: const [
            PickerItem(value: 'a', label: 'Alpha'),
            PickerItem(value: 'b', label: 'Beta'),
          ],
        ),
        child: const Text('open'),
      )));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // Two rows: too short to need a search box.
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(picked, 'b');
    });

    testWidgets('a long list at large text, with the keyboard up, does not overflow', (tester) async {
      usePhone(tester, height: 700);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(host(
        (context) => TextButton(
          onPressed: () => showSelectRepresentativeSheet(context, employees: [
            for (var i = 0; i < 40; i++) EmployeeOption(id: '$i', name: 'Person number $i with a fairly long name'),
          ]),
          child: const Text('open'),
        ),
        textScale: 1.6,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('filter sheet + bar', () {
    Map<String, dynamic> emp(String id, String name, List<Map<String, String>> teams) =>
        {'_id': id, 'employeeName': name, 'teamIds': teams, 'isActive': true};

    void serve() {
      adapter.handler = (o) async {
        if (o.path == '/employees/my-hierarchy-scope') {
          return json(200, {
            'isOk': true,
            'data': [
              emp('me', 'Me Myself', [
                {'_id': 't1', 'teamName': 'QA'},
              ]),
              emp('r', 'Ravi', [
                {'_id': 't1', 'teamName': 'QA'},
              ]),
              emp('s', 'Sara', [
                {'_id': 't2', 'teamName': 'Ops'},
              ]),
            ],
          });
        }
        if (o.path == '/locations/my-scope') {
          return json(200, {
            'isOk': true,
            'data': [
              {'_id': 'z1', 'name': 'Zone 1', 'locationType': 'Zone'},
              {'_id': 'sz1', 'name': 'Sub 1', 'locationType': 'SubZone', 'parentZoneId': 'z1', 'parentZoneName': 'Zone 1'},
            ],
            'departments': [
              {'_id': 'd1', 'departmentName': 'Quality'},
            ],
            'departmentsByLocation': {
              'z1': ['d1'],
            },
            'meta': {'fullAccess': false},
          });
        }
        if (o.path.startsWith('/audit-types')) {
          return json(200, {
            'isOk': true,
            'data': [
              {'_id': 'a1', 'name': 'Safety'},
            ],
          });
        }
        return json(200, {'isOk': true, 'data': []});
      };
    }

    Future<AuditFilterSelection?> openSheet(
      WidgetTester tester, {
      bool showStatus = true,
      bool showFlag = false,
      double textScale = 1,
    }) async {
      usePhone(tester, height: 1100);
      AuditFilterSelection? result;
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showAuditFilterSheet(
                  context,
                  initial: const AuditFilterSelection(),
                  showStatus: showStatus,
                  showFlag: showFlag,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('offers Team, Members, Location, Audit Type, Date range, Status and Include skipped', (tester) async {
      serve();
      await openSheet(tester);
      for (final label in ['Filters', 'Who', 'Team', 'Members', 'Where', 'Audit Type', 'Date range', 'Status']) {
        expect(find.text(label), findsWidgets, reason: label);
      }
      expect(find.text('Location & Department'), findsOneWidget);
      expect(find.text('Safety'), findsOneWidget);
      // The eight unified statuses are chips.
      for (final s in [
        'Not Started',
        'In Progress',
        'Overdue',
        'Delayed Completed',
        'On-Time Completed',
        'NC Response Pending',
        'NC Verification Pending',
        'Total Closed',
      ]) {
        expect(find.widgetWithText(FilterChip, s), findsOneWidget, reason: s);
      }
      expect(find.text('Include skipped / reassigned audits'), findsOneWidget);
    });

    testWidgets('the Dashboard-style sheet has no Status section, the NC one has Flag', (tester) async {
      serve();
      await openSheet(tester, showStatus: false, showFlag: true);
      expect(find.text('Status'), findsNothing);
      expect(find.text('Flag'), findsOneWidget);
    });

    testWidgets('picking a Team and Apply resolves it to its members', (tester) async {
      serve();
      late Future<AuditFilterSelection?> pending;
      usePhone(tester, height: 1100);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => pending = showAuditFilterSheet(context, initial: const AuditFilterSelection()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Team').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('QA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply teams (1)'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Apply (1)'));
      await tester.pumpAndSettle();
      final result = (await pending)!;
      expect(result.teams, ['t1']);
      expect(result.teamMembers.toSet(), {'me', 'r'});
      expect(result.employees, isEmpty);
    });

    testWidgets('Location & Department: a Zone ticks its Sub Zones, departments narrow to it', (tester) async {
      serve();
      late Future<AuditFilterSelection?> pending;
      usePhone(tester, height: 1100);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => pending = showAuditFilterSheet(context, initial: const AuditFilterSelection()),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Location & Department'));
      await tester.pumpAndSettle();
      // Grouped like the web: sections, a Sub Zone labelled with its Zone.
      expect(find.text('ZONE'), findsOneWidget);
      expect(find.text('SUB ZONE'), findsOneWidget);
      expect(find.text('DEPARTMENT'), findsOneWidget);
      expect(find.text('in Zone 1'), findsOneWidget);
      await tester.tap(find.text('Zone 1').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Quality'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Done ('));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Apply ('));
      await tester.pumpAndSettle();
      final result = (await pending)!;
      expect(result.locations.toSet(), {'z1', 'sz1'});
      expect(result.departments, ['d1']);
    });

    testWidgets('the bar shows removable pills for what is active and Clear puts Me back', (tester) async {
      serve();
      // Wide enough that every pill is built (the pill row is a lazy,
      // sideways-scrolling list).
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final audits = AuditsProvider()..setSelfEmployeeId('me');
      audits.setFilterState(
        isTeam: true,
        auditTypes: ['Safety'],
        dateRange: (DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
        statuses: ['Overdue'],
      );
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuditsProvider>.value(value: audits),
          ChangeNotifierProvider(create: (_) => DashboardProvider()),
          ChangeNotifierProvider(create: (_) => NcProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AuditFilterBar(showStatus: true)),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('All Members'), findsWidgets);
      expect(find.text('Safety'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
      expect(find.textContaining('1 Sep'), findsOneWidget);
      // Filters + badge (All Members, type, date, status = 4)
      expect(find.text('4'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(audits.activeFilterCount, 0);
      expect(audits.isTeamScope, isFalse);
      expect(find.text('Clear'), findsNothing);
    });
  });

  group('Audits list keeps its place', () {
    Map<String, dynamic> row(String id, DateTime day) => {
      '_id': id,
      'title': 'Audit $id',
      'scope': '',
      'status': 'Not Started',
      'displayStatus': 'Not Started',
      'scheduledDate': day.toUtc().toIso8601String(),
    };

    late ListViewMemory memory;
    late AuditsProvider audits;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuditsProvider>.value(value: audits),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => DashboardProvider()),
          ChangeNotifierProvider(create: (_) => NcProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider<ListViewMemory>.value(value: memory),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: MyAuditsScreen()),
        ),
      ));
      await tester.pumpAndSettle();
    }

    setUp(() {
      memory = ListViewMemory();
      audits = AuditsProvider();
      final today = DateTime.now();
      DateTime day(int d) => DateTime(today.year, today.month, today.day).add(Duration(days: d));
      adapter.handler = (o) async => json(200, {
        'isOk': true,
        'data': o.path == ApiConstants.myAudits
            ? [row('today', day(0)), row('t1', day(1)), row('t2', day(2))]
            : [],
      });
    });

    testWidgets('one group open at a time; tapping Today folds the rest', (tester) async {
      await pump(tester);
      expect(find.text('Audit today'), findsOneWidget);
      expect(find.text('Audit t1'), findsNothing);

      await tester.tap(find.text('Tomorrow'));
      await tester.pumpAndSettle();
      expect(find.text('Audit t1'), findsOneWidget);

      // Opening the next day folds Tomorrow (accordion).
      final later = find.byWidgetPredicate(
        (w) => w is Text && w.data != null && RegExp(r'^[A-Z][a-z]{2} \d{1,2} [A-Z][a-z]{2}$').hasMatch(w.data!),
      );
      await tester.tap(later.first);
      await tester.pumpAndSettle();
      expect(find.text('Audit t2'), findsOneWidget);
      expect(find.text('Audit t1'), findsNothing);

      await tester.tap(find.textContaining('Today ·'));
      await tester.pumpAndSettle();
      expect(find.text('Audit t2'), findsNothing);
      expect(find.text('Audit today'), findsOneWidget);
    });

    testWidgets('the open group, the search text and the status pick survive the screen being rebuilt', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Tomorrow'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 't1');
      await tester.pumpAndSettle();
      expect(find.text('Audit t1'), findsOneWidget);

      // The screen goes away entirely (a remount, e.g. a dashboard tile jump
      // re-keys it) and comes back: nothing was lost.
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(find.text('Audit t1'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, 't1');

      // Logout wipes it: a new account starts from a blank list.
      memory.resetForLogout();
      await tester.pumpWidget(const SizedBox());
      await pump(tester);
      expect(find.text('Audit t1'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, isEmpty);
    });
  });

  group('Final Report', () {
    Map<String, dynamic> row(
      String id, {
      String title = 'Report',
      String? seriesId,
      String? location,
      double got = 8,
      double of = 10,
    }) => {
      '_id': id,
      'title': title,
      'scope': '',
      'status': 'Completed',
      'displayStatus': 'Total Closed',
      'timeliness': 'On-Time Completed',
      'scheduledDate': DateTime.now().toUtc().toIso8601String(),
      'completedDate': DateTime.now().toUtc().toIso8601String(),
      'scoreResult': {'achieved': got, 'maxPossible': of, 'percentage': (got / of * 100).round()},
      'recurrence': seriesId == null ? null : {'seriesId': seriesId, 'frequency': 'Weekly', 'occurrenceCount': 3},
      'locationIds': [
        if (location != null) {'_id': location, 'name': location},
      ],
    };

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuditsProvider()),
          ChangeNotifierProvider(create: (_) => DashboardProvider()),
          ChangeNotifierProvider(create: (_) => NcProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider(create: (_) => ListViewMemory()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const ReportsScreen()),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('lists only my audits by default, tiles from the completed-stats endpoint, series as one row', (tester) async {
      adapter.handler = (o) async {
        switch (o.path) {
          case '/audits/mine':
            return json(200, {
              'isOk': true,
              'data': [
                row('1', title: 'Weekly hygiene', seriesId: 's1', location: 'Plant A'),
                row('2', title: 'Weekly hygiene', seriesId: 's1', location: 'Plant A'),
                row('3', title: 'Weekly hygiene', seriesId: 's1', location: 'Plant A'),
                row('4', title: 'One-off', location: 'Plant B'),
              ],
            });
          case '/audits/stats/completed':
            return json(200, {
              'isOk': true,
              'data': {
                'percentage': 80,
                'achieved': 32,
                'maxPossible': 40,
                'totalAudits': 2,
                'onTimeCompleted': 2,
                'delayedCompleted': 0,
              },
            });
          case '/audits/led-places':
            return json(200, {
              'isOk': true,
              'data': {'locations': [], 'departments': []},
            });
        }
        return json(200, {'isOk': true, 'data': []});
      };
      await pump(tester);

      // Default scope is Me and nothing else: no leader switch.
      expect(find.text('My locations'), findsNothing);
      // The tiles are the server's numbers.
      expect(find.text('Total Score'), findsOneWidget);
      expect(find.text('80%'), findsWidgets);
      expect(find.text('32 / 40 pts'), findsOneWidget);
      expect(find.text('Total Audits'), findsOneWidget);
      expect(find.text('On-Time Completed'), findsWidgets);
      expect(find.text('Delayed Completed'), findsWidgets);
      // The series is ONE row with its badge and label, the one-off is a card.
      expect(find.text('Weekly series · 3 occurrences'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('One-off'), findsOneWidget);
      // The request carried the shared filters' default (Me), plus what makes
      // the tiles match the list.
      final stats = adapter.requests.firstWhere((r) => r.path == '/audits/stats/completed');
      expect(stats.queryParameters['hideUnstarted'], 'true');

      // Expanding the series shows its occurrences; opening a series is an
      // accordion so only one is ever open.
      await tester.tap(find.text('Weekly series · 3 occurrences'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly hygiene'), findsNWidgets(4)); // header + 3 occurrences
    });

    testWidgets('a leader gets a My locations view that lists other auditors\' audits there', (tester) async {
      adapter.handler = (o) async {
        switch (o.path) {
          case '/audits/mine':
            return json(200, {'isOk': true, 'data': [row('mine', title: 'Mine')]});
          case '/audits/at-places-i-lead':
            return json(200, {
              'isOk': true,
              'data': {
                'audits': [row('theirs', title: 'Colleague audit', location: 'Zone 9')],
                'total': 1,
                'page': 1,
                'limit': 100,
              },
            });
          case '/audits/led-places':
            return json(200, {
              'isOk': true,
              'data': {
                'locations': [
                  {'_id': 'z9', 'name': 'Zone 9'},
                ],
                'departments': [],
              },
            });
        }
        return json(200, {'isOk': true, 'data': []});
      };
      await pump(tester);
      expect(find.text('My locations'), findsOneWidget);
      expect(find.text('Mine'), findsOneWidget);
      expect(find.text('Colleague audit'), findsNothing);

      await tester.tap(find.text('My locations'));
      await tester.pumpAndSettle();
      expect(find.text('Colleague audit'), findsOneWidget);
      expect(find.text('Mine'), findsNothing);
      // employeeIds is never sent to the led list (the server ignores it, and
      // "just me" would empty it), and the tiles ask as All Members over the
      // places I lead.
      final led = adapter.requests.lastWhere((r) => r.path == '/audits/at-places-i-lead');
      expect(led.queryParameters.containsKey('employeeIds'), isFalse);
      final stats = adapter.requests.lastWhere((r) => r.path == '/audits/stats/completed');
      expect(stats.queryParameters.containsKey('employeeIds'), isFalse);
      expect(stats.queryParameters['locationIds'], 'z9');
    });

    testWidgets('no stats endpoint for this role: the tiles are worked out from the rows', (tester) async {
      adapter.handler = (o) async {
        if (o.path == '/audits/mine') {
          return json(200, {
            'isOk': true,
            'data': [row('a', got: 10, of: 10), row('b', got: 0, of: 90)],
          });
        }
        if (o.path == '/audits/stats/completed') return json(403, {'isOk': false});
        return json(200, {'isOk': true, 'data': []});
      };
      await pump(tester);
      // Σ / Σ = 10%, not the 50% an average of 100% and 0% would give.
      expect(find.text('10%'), findsWidgets);
      expect(find.text('10 / 100 pts'), findsOneWidget);
    });
  });
}
