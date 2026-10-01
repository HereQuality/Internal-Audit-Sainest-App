import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/notifications/notification_navigation.dart';
import 'package:internal_audit_app/core/notifications/notification_scheduler.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/main.dart' show RootGate;
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/announcement_provider.dart';
import 'package:internal_audit_app/providers/app_mode_provider.dart';
import 'package:internal_audit_app/providers/app_update_provider.dart';
import 'package:internal_audit_app/providers/audit_filter_scope.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/maintenance_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/providers/notifications_provider.dart';
import 'package:internal_audit_app/providers/tickets_provider.dart';
import 'package:internal_audit_app/screens/calendar/calendar_screen.dart';
import 'package:internal_audit_app/widgets/audit_filter_bar.dart';
import 'package:internal_audit_app/widgets/filter_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// Who a filtered screen opens on: a user whose Role has FULL ACCESS (or a
/// SuperAdmin) opens on "All Members" (no employeeIds sent, and the untouched
/// default is NOT an active filter), every ordinary employee on "Me"
/// (employeeIds=self) — the web's useSelfScope. The Calendar alone keeps Me for
/// everybody (it loads unpaginated data). The default is recomputed per login.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    adapter = FakeAdapter()..handler = (o) async => json(200, {'isOk': true, 'data': []});
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  void usePhone(WidgetTester tester, {double height = 900}) {
    tester.view.physicalSize = Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // The three filter-holding providers as _RootGate leaves them for a login.
  ({AuditsProvider audits, DashboardProvider dash, NcProvider ncs}) trio({
    required bool fullAccess,
    String? selfId = 'me',
  }) {
    final audits = AuditsProvider();
    final dash = DashboardProvider();
    final ncs = NcProvider();
    if (selfId != null) {
      audits.setSelfEmployeeId(selfId);
      dash.setSelfEmployeeId(selfId);
      ncs.setSelfEmployeeId(selfId);
    }
    for (final AuditFilterScope p in [audits, dash, ncs]) {
      p.setDefaultTeamScope(fullAccess);
    }
    return (audits: audits, dash: dash, ncs: ncs);
  }

  List<AuditFilterScope> all(({AuditsProvider audits, DashboardProvider dash, NcProvider ncs}) t) =>
      [t.audits, t.dash, t.ncs];

  group('UserModel.hasFullAccess', () {
    Map<String, dynamic> payload({Object? flag = _absent, String roleType = 'Employee'}) => {
      '_id': 'u1',
      'roleType': roleType,
      'employeeName': 'N',
      'username': 'u',
      'emailOffice': 'e@x.com',
      'mobileNumber': '1',
      if (!identical(flag, _absent)) 'hasFullAccess': flag,
    };

    test('is read from the server flag, strictly true', () {
      expect(UserModel.fromJson(payload(flag: true)).hasFullAccess, isTrue);
      expect(UserModel.fromJson(payload(flag: false)).hasFullAccess, isFalse);
    });

    test('an older server that never sends it reads as no — and so does anything that is not the boolean true', () {
      expect(UserModel.fromJson(payload()).hasFullAccess, isFalse);
      expect(UserModel.fromJson(payload(flag: 'true')).hasFullAccess, isFalse);
      expect(UserModel.fromJson(payload(flag: 1)).hasFullAccess, isFalse);
      expect(UserModel.fromJson(payload(flag: null)).hasFullAccess, isFalse);
    });

    test('a SuperAdmin always has it, whatever the payload says', () {
      expect(UserModel.fromJson(payload(roleType: 'SuperAdmin')).hasFullAccess, isTrue);
      expect(UserModel.fromJson(payload(roleType: 'SuperAdmin', flag: false)).hasFullAccess, isTrue);
      expect(
        const UserModel(id: 'a', roleType: 'SuperAdmin', name: '', username: '', email: '', mobileNumber: '')
            .hasFullAccess,
        isTrue,
      );
    });

    test('survives copyWith (also the preferences-only one AuthProvider uses) and a profile update', () {
      final user = UserModel.fromJson(payload(flag: true));
      expect(user.copyWith(name: 'Other').hasFullAccess, isTrue);
      expect(user.copyWith(preferences: const UserPreferences(themeMode: 'dark')).hasFullAccess, isTrue);
      expect(user.copyWith(hasFullAccess: false).hasFullAccess, isFalse);

      final auth = AuthProvider()..user = user;
      addTearDown(auth.dispose);
      // The PUT /auth/me answer carries the flag itself and replaces the held user.
      auth.updateUser(UserModel.fromJson(payload(flag: true)));
      expect(auth.user!.hasFullAccess, isTrue);
      auth.updateUser(UserModel.fromJson(payload()));
      expect(auth.user!.hasFullAccess, isFalse);
    });
  });

  group('the default scope', () {
    test('an ordinary employee opens on Me: employeeIds=self, and Me is not an active filter', () {
      for (final p in all(trio(fullAccess: false))) {
        expect(p.defaultTeamScope, isFalse);
        expect(p.isTeamScope, isFalse);
        expect(p.filterParams, {'employeeIds': 'me'});
        expect(p.activeFilterCount, 0);
        expect(p.hasActiveFilters, isFalse);
      }
    });

    test('a Full Access user opens on All Members: NO employeeIds, and the default is not an active filter', () {
      for (final p in all(trio(fullAccess: true))) {
        expect(p.defaultTeamScope, isTrue);
        expect(p.isTeamScope, isTrue);
        expect(p.filterParams, isNull);
        expect(p.ncFilterParams, isNull);
        expect(p.listFilterParams, isNull);
        expect(p.activeFilterCount, 0);
        expect(p.hasActiveFilters, isFalse);
      }
    });

    test('a SuperAdmin (no employee id) is All Members by default and sends nothing, as before', () {
      for (final p in all(trio(fullAccess: true, selfId: null))) {
        expect(p.selfEmployeeId, isNull);
        expect(p.isTeamScope, isTrue);
        expect(p.filterParams, isNull);
        expect(p.activeFilterCount, 0);
      }
    });

    test('picking Me as a Full Access user is a real narrowing: employeeIds=self, counted, and shown as moved off the default', () {
      for (final p in all(trio(fullAccess: true))) {
        p.setFilterState(isTeam: false);
        expect(p.filterParams, {'employeeIds': 'me'});
        expect(p.activeFilterCount, 1);
        expect(p.hasActiveFilters, isTrue);
      }
    });

    test('picking All Members as an ordinary employee is unchanged: no employeeIds, counted', () {
      for (final p in all(trio(fullAccess: false))) {
        p.setFilterState(isTeam: true);
        expect(p.filterParams, isNull);
        expect(p.activeFilterCount, 1);
      }
    });

    test('a Location narrows both defaults the way it always did, and the scope itself still counts once or not at all', () {
      final ordinary = trio(fullAccess: false).audits..setFilterState(locations: ['zoneA']);
      expect(ordinary.filterParams, {'employeeIds': 'me', 'locationIds': 'zoneA'});
      expect(ordinary.activeFilterCount, 1);

      final full = trio(fullAccess: true).audits..setFilterState(locations: ['zoneA']);
      expect(full.filterParams, {'locationIds': 'zoneA'});
      expect(full.activeFilterCount, 1, reason: 'the place only; All Members is the default');
    });

    test('specific people win over the default and are counted once, for either account', () {
      for (final fullAccess in [false, true]) {
        final p = trio(fullAccess: fullAccess).audits;
        p.setFilterState(employees: ['a']);
        expect(p.filterParams, {'employeeIds': 'a'});
        expect(p.activeFilterCount, 1);
        p.setFilterState(employees: [], teams: ['t1'], teamMembers: ['a', 'b']);
        expect(p.filterParams, {'employeeIds': 'a,b'});
        expect(p.activeFilterCount, 1);
      }
    });

    test('Clear returns to the account default: All Members for Full Access, Me for an employee', () async {
      for (final p in all(trio(fullAccess: true))) {
        p.setFilterState(isTeam: false, locations: ['z'], auditTypes: ['Safety'], flags: ['Major']);
        expect(p.activeFilterCount, 4);
        await p.clearFilters();
        expect(p.isTeamScope, isTrue);
        expect(p.filterParams, isNull);
        expect(p.activeFilterCount, 0);
      }
      for (final p in all(trio(fullAccess: false))) {
        p.setFilterState(isTeam: true, locations: ['z']);
        await p.clearFilters();
        expect(p.isTeamScope, isFalse);
        expect(p.filterParams, {'employeeIds': 'me'});
        expect(p.activeFilterCount, 0);
      }
    });

    test('the default is adopted once, before any fetch, and repeating it never overrides a pick the user made', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      expect(p.setDefaultTeamScope(true), isFalse, reason: 'the first call after a login has nothing stale to reload');
      expect(p.isTeamScope, isTrue);

      p.setFilterState(isTeam: false); // the user picked Me
      expect(p.setDefaultTeamScope(true), isFalse);
      expect(p.isTeamScope, isFalse, reason: '_RootGate repeats this on every rebuild');
    });

    test('a role that changes MID-session moves an untouched toggle and says so, so the caller reloads', () {
      final p = AuditsProvider()..setSelfEmployeeId('me');
      p.setDefaultTeamScope(false);
      expect(p.isTeamScope, isFalse);

      expect(p.setDefaultTeamScope(true), isTrue);
      expect(p.isTeamScope, isTrue);
      expect(p.setDefaultTeamScope(false), isTrue);
      expect(p.isTeamScope, isFalse);
    });

    test('a different account on the same phone recomputes it (logout wipes the default and the scope)', () {
      final t = trio(fullAccess: true);
      final p = t.audits;
      p.setFilterState(isTeam: false, locations: ['z'], employees: ['x']);

      p.resetForLogout();
      expect(p.defaultTeamScope, isFalse);
      expect(p.isTeamScope, isFalse);
      expect(p.locationFilter, isEmpty);
      expect(p.activeFilterCount, 0);

      // An ordinary employee signs in next: Me, with their own id.
      p.setSelfEmployeeId('other');
      expect(p.setDefaultTeamScope(false), isFalse);
      expect(p.isTeamScope, isFalse);
      expect(p.filterParams, {'employeeIds': 'other'});
      p.setFilterState(isTeam: true); // they widen, then leave
      p.resetForLogout();

      // Full Access again: All Members, even though the previous account ended on All Members as an employee.
      p.setSelfEmployeeId('boss');
      p.setDefaultTeamScope(true);
      expect(p.isTeamScope, isTrue);
      expect(p.filterParams, isNull);
      expect(p.activeFilterCount, 0);
    });

    test('the filter state of the previous account is not left on All Members for an employee who signs in after a Full Access user', () {
      for (final p in all(trio(fullAccess: true))) {
        p.resetForLogout();
        p.setDefaultTeamScope(false);
        expect(p.isTeamScope, isFalse);
      }
    });
  });

  group('the Calendar keeps Me for everybody', () {
    test('a Full Access user: the shared scope is All Members, the Calendar asks for just me', () {
      final p = trio(fullAccess: true).audits;
      expect(p.filterParams, isNull);
      expect(p.calendarTeamScope, isFalse);
      expect(p.calendarFilterParams, {'employeeIds': 'me'});
      // Its own badge: Me is the Calendar's resting state.
      expect(p.activeFilterCountFor(status: false, flag: false, calendar: true), 0);
    });

    test('it widens only when All Members was picked on the Calendar, and Me ends that', () {
      final p = trio(fullAccess: true).audits;
      p.calendarAllMembers = true;
      expect(p.calendarTeamScope, isTrue);
      expect(p.calendarFilterParams, isNull);
      expect(p.activeFilterCountFor(status: false, flag: false, calendar: true), 1);

      p.setFilterState(isTeam: false); // Me, from anywhere
      expect(p.calendarAllMembers, isFalse);
      expect(p.calendarFilterParams, {'employeeIds': 'me'});
      p.setFilterState(isTeam: true); // All Members from another screen is not a Calendar pick
      expect(p.calendarTeamScope, isFalse);
    });

    test('Me picked elsewhere is the Calendar\'s default too, not an active filter there', () {
      final p = trio(fullAccess: true).audits..setFilterState(isTeam: false);
      expect(p.activeFilterCount, 1, reason: 'on the other screens it is a narrowing');
      expect(p.activeFilterCountFor(status: false, flag: false, calendar: true), 0);
    });

    test('Clear (resetScope) puts the account default back and the Calendar widening off', () async {
      final p = trio(fullAccess: true).audits..calendarAllMembers = true;
      await p.applyFilters(resetScope: true);
      expect(p.isTeamScope, isTrue);
      expect(p.calendarAllMembers, isFalse);
      expect(p.calendarFilterParams, {'employeeIds': 'me'});
    });

    test('an ordinary employee is exactly as before: the Calendar follows the shared scope', () {
      final p = trio(fullAccess: false).audits;
      expect(p.calendarFilterParams, {'employeeIds': 'me'});
      p.setFilterState(isTeam: true);
      expect(p.calendarTeamScope, isTrue);
      expect(p.calendarFilterParams, isNull);
      expect(p.activeFilterCountFor(status: false, flag: false, calendar: true), 1);
    });

    test('its own requests use the Calendar scope while every other request keeps the shared one', () async {
      final t = trio(fullAccess: true);
      await Future.wait([t.audits.fetchCalendarAudits(), t.audits.fetchMyAudits(), t.ncs.fetchCalendarNcs()]);

      final mine = adapter.where('GET', ApiConstants.myAudits).toList();
      // Both audit fetches hit /audits/mine: the Calendar's own asks for me, the list for everyone.
      expect(mine.map((r) => r.queryParameters['employeeIds']), unorderedEquals(['me', null]));
      expect(
        adapter.where('GET', ApiConstants.ncsMine).single.queryParameters,
        {'employeeIds': 'me'},
      );
    });
  });

  group('the filter bar and the filter sheet', () {
    Widget barApp(({AuditsProvider audits, DashboardProvider dash, NcProvider ncs}) t) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AuditsProvider>.value(value: t.audits),
        ChangeNotifierProvider<DashboardProvider>.value(value: t.dash),
        ChangeNotifierProvider<NcProvider>.value(value: t.ncs),
        ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: AuditFilterBar(showStatus: true)),
      ),
    );

    Set<bool> toggleSelection(WidgetTester tester) =>
        tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>)).selected;

    Finder segment(String label) =>
        find.descendant(of: find.byType(SegmentedButton<bool>), matching: find.text(label));

    testWidgets('Full Access: the toggle reads All Members, nothing is active, Me is a pill and Clear returns to All Members', (tester) async {
      final t = trio(fullAccess: true);
      await tester.pumpWidget(barApp(t));
      await tester.pumpAndSettle();

      expect(toggleSelection(tester), {true});
      expect(find.text('Clear'), findsNothing, reason: 'the default must not light Clear');
      expect(find.text('1'), findsNothing, reason: 'nor the Filters badge');

      await tester.tap(segment('Me'));
      await tester.pumpAndSettle();
      expect(toggleSelection(tester), {false});
      for (final p in all(t)) {
        expect(p.isTeamScope, isFalse);
        expect(p.filterParams, {'employeeIds': 'me'});
      }
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('Me'), findsNWidgets(2), reason: 'the segment and the pill');
      expect(find.text('1'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(toggleSelection(tester), {true});
      for (final p in all(t)) {
        expect(p.isTeamScope, isTrue);
        expect(p.filterParams, isNull);
      }
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('an ordinary employee: the toggle reads Me, All Members is the pill and Clear returns to Me', (tester) async {
      final t = trio(fullAccess: false);
      await tester.pumpWidget(barApp(t));
      await tester.pumpAndSettle();

      expect(toggleSelection(tester), {false});
      expect(find.text('Clear'), findsNothing);

      await tester.tap(segment('All Members'));
      await tester.pumpAndSettle();
      expect(toggleSelection(tester), {true});
      expect(find.text('Clear'), findsOneWidget);
      expect(find.text('All Members'), findsNWidgets(2), reason: 'the segment and the pill');
      expect(t.audits.filterParams, isNull);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(toggleSelection(tester), {false});
      expect(t.audits.filterParams, {'employeeIds': 'me'});
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('removing the scope pill goes back to the account default', (tester) async {
      final t = trio(fullAccess: true);
      t.audits.setFilterState(isTeam: false);
      await tester.pumpWidget(barApp(t));
      await tester.pumpAndSettle();
      expect(find.text('Me'), findsNWidgets(2));

      // The pill is the second 'Me' (the segment is first in the tree).
      await tester.tap(find.text('Me').last);
      await tester.pumpAndSettle();
      expect(t.audits.isTeamScope, isTrue);
      expect(find.text('Clear'), findsNothing);
    });

    Future<void> openSheet(
      WidgetTester tester,
      AuditFilterSelection initial,
      void Function(AuditFilterSelection? result) onResult,
    ) async {
      usePhone(tester, height: 1400);
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
                onPressed: () async => onResult(await showAuditFilterSheet(context, initial: initial)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    ChoiceChip chip(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    testWidgets('the sheet opens on All Members for Full Access, counts nothing, and Clear all returns to it', (tester) async {
      final audits = trio(fullAccess: true).audits;
      AuditFilterSelection? result;
      await openSheet(tester, AuditFilterSelection.fromScope(audits), (r) => result = r);

      expect(chip(tester, 'All Members').selected, isTrue);
      expect(chip(tester, 'Me').selected, isFalse);
      expect(find.text('Apply'), findsOneWidget, reason: 'no count on the Apply button');
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Clear all')).onPressed, isNull);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Me'));
      await tester.pumpAndSettle();
      expect(chip(tester, 'Me').selected, isTrue);
      expect(find.text('Apply (1)'), findsOneWidget, reason: 'Me is a narrowing for Full Access');
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Clear all')).onPressed, isNotNull);

      await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
      await tester.pumpAndSettle();
      expect(chip(tester, 'All Members').selected, isTrue);
      expect(find.text('Apply'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
      await tester.pumpAndSettle();
      expect(result!.isTeam, isTrue);
      expect(result!.defaultIsTeam, isTrue);
    });

    testWidgets('the sheet for an ordinary employee is as before: Me selected, All Members counted', (tester) async {
      final audits = trio(fullAccess: false).audits;
      await openSheet(tester, AuditFilterSelection.fromScope(audits), (_) {});

      expect(chip(tester, 'Me').selected, isTrue);
      expect(find.text('Apply'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'All Members'));
      await tester.pumpAndSettle();
      expect(find.text('Apply (1)'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
      await tester.pumpAndSettle();
      expect(chip(tester, 'Me').selected, isTrue);
    });
  });

  group('the Calendar screen', () {
    Future<({AuditsProvider audits, DashboardProvider dash, NcProvider ncs})> mountCalendar(
      WidgetTester tester, {
      required bool fullAccess,
    }) async {
      usePhone(tester);
      final t = trio(fullAccess: fullAccess);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuditsProvider>.value(value: t.audits),
          ChangeNotifierProvider<DashboardProvider>.value(value: t.dash),
          ChangeNotifierProvider<NcProvider>.value(value: t.ncs),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider(create: (_) => ListViewMemory()),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const CalendarScreen()),
      ));
      await tester.pumpAndSettle();
      return t;
    }

    // The employeeIds each audit request asked for since the last [forget]
    // (null = the param was not sent = All Members). A filter change reloads the
    // Audits list (shared scope) AND the Calendar's own list (Calendar scope) on
    // the same endpoint, so both appear here.
    Set<Object?> auditIds() => {
      for (final r in adapter.where('GET', ApiConstants.myAudits)) r.queryParameters['employeeIds'],
    };
    // The Calendar's NC list is the one /ncs/mine request that is not paged.
    Set<Object?> calendarNcIds() => {
      for (final r in adapter.where('GET', ApiConstants.ncsMine))
        if (!r.queryParameters.containsKey('page')) r.queryParameters['employeeIds'],
    };
    void forget() => adapter.requests.clear();

    ChoiceChip chip(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    Future<void> openFilters(WidgetTester tester) async {
      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
    }

    Future<void> apply(WidgetTester tester) async {
      await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.byType(FilledButton)));
      await tester.pumpAndSettle();
    }

    testWidgets('opens on Me for a Full Access user while every other screen is on All Members', (tester) async {
      final t = await mountCalendar(tester, fullAccess: true);

      expect(auditIds(), {'me'});
      expect(calendarNcIds(), {'me'});
      expect(t.audits.isTeamScope, isTrue);
      expect(t.audits.filterParams, isNull);
      expect(find.text('Clear'), findsNothing, reason: 'the Calendar\'s resting state is not an active filter');
      expect(t.audits.activeFilterCountFor(status: false, flag: false, calendar: true), 0);
    });

    testWidgets('its sheet opens on Me, and Apply without touching the scope changes nothing anywhere', (tester) async {
      final t = await mountCalendar(tester, fullAccess: true);
      await openFilters(tester);
      expect(chip(tester, 'Me').selected, isTrue);
      expect(chip(tester, 'All Members').selected, isFalse);

      forget();
      await apply(tester);
      for (final p in all(t)) {
        expect(p.isTeamScope, isTrue, reason: 'the other screens keep their All Members default');
        expect(p.filterParams, isNull);
        expect(p.calendarAllMembers, isFalse);
      }
      // The Audits list reloads on All Members (no employeeIds), the Calendar's own list on Me.
      expect(auditIds(), {null, 'me'});
      expect(calendarNcIds(), {'me'});
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('All Members picked on the Calendar widens it (and only it); Me, or Clear, narrows it again', (tester) async {
      final t = await mountCalendar(tester, fullAccess: true);

      await openFilters(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'All Members'));
      await tester.pumpAndSettle();
      forget();
      await apply(tester);

      expect(t.audits.calendarAllMembers, isTrue);
      expect(auditIds(), {null});
      expect(calendarNcIds(), {null});
      // The Calendar's own bar now says so, and offers Clear.
      expect(find.text('All Members'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);

      // Me again on the Calendar: only the Calendar narrows, the app-wide default stays.
      await openFilters(tester);
      expect(chip(tester, 'All Members').selected, isTrue);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Me'));
      await tester.pumpAndSettle();
      forget();
      await apply(tester);
      expect(t.audits.calendarAllMembers, isFalse);
      expect(t.audits.isTeamScope, isTrue);
      expect(auditIds(), {null, 'me'});
      expect(calendarNcIds(), {'me'});
      expect(find.text('Clear'), findsNothing);

      // And Clear after a widening returns to the Calendar's Me.
      await openFilters(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'All Members'));
      await tester.pumpAndSettle();
      await apply(tester);
      expect(t.audits.calendarAllMembers, isTrue);
      forget();
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(t.audits.calendarAllMembers, isFalse);
      expect(t.audits.isTeamScope, isTrue);
      expect(auditIds(), {null, 'me'});
      expect(calendarNcIds(), {'me'});
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('an ordinary employee: Me on open, All Members when picked, shared with the other screens as before', (tester) async {
      final t = await mountCalendar(tester, fullAccess: false);
      expect(auditIds(), {'me'});

      await openFilters(tester);
      expect(chip(tester, 'Me').selected, isTrue);
      await tester.tap(find.widgetWithText(ChoiceChip, 'All Members'));
      await tester.pumpAndSettle();
      forget();
      await apply(tester);

      for (final p in all(t)) {
        expect(p.isTeamScope, isTrue);
      }
      expect(auditIds(), {null});
      expect(calendarNcIds(), {null});
    });
  });

  group('main.dart\'s root gate', () {
    late AuthProvider auth;
    late AppModeProvider appMode;
    late AuditsProvider audits;
    late DashboardProvider dashboard;
    late NcProvider ncs;

    setUp(() {
      NotificationScheduler.clearTray = () async {};
      adapter.handler = (o) async => o.path == ApiConstants.maintenanceStatus
          ? json(200, {'data': {'isActive': false, 'message': ''}})
          : json(404, {'isOk': false});
      SocketService.debugInstance = FakeSockets().service;
      clearHeldNotificationTap();
      auth = AuthProvider();
      appMode = AppModeProvider()..loaded = true; // the role picker: the simplest signed-in content
      audits = AuditsProvider();
      dashboard = DashboardProvider();
      ncs = NcProvider();
    });

    tearDown(() {
      auth.dispose();
      DioClient.instance.onUnauthorized = null;
      clearHeldNotificationTap();
    });

    Future<void> mount(WidgetTester tester) => tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider<AppModeProvider>.value(value: appMode),
          ChangeNotifierProvider(create: (_) => AppUpdateProvider()),
          ChangeNotifierProvider(create: (_) => MaintenanceProvider()),
          ChangeNotifierProvider(create: (_) => AnnouncementProvider()),
          ChangeNotifierProvider(create: (_) => NotificationsProvider()),
          ChangeNotifierProvider<NcProvider>.value(value: ncs),
          ChangeNotifierProvider<AuditsProvider>.value(value: audits),
          ChangeNotifierProvider<DashboardProvider>.value(value: dashboard),
          ChangeNotifierProvider(create: (_) => TicketsProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider(create: (_) => ListViewMemory()),
        ],
        child: MaterialApp(navigatorKey: notificationNavigatorKey, home: const RootGate()),
      ),
    );

    Future<void> settleUi(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    Future<void> signIn(WidgetTester tester, UserModel user) async {
      auth.status = AuthStatus.authenticated;
      auth.updateUser(user);
      await settleUi(tester);
    }

    Future<void> signOut(WidgetTester tester, UserModel user) async {
      auth.status = AuthStatus.unauthenticated;
      auth.updateUser(user);
      await settleUi(tester);
    }

    UserModel employee(String id, {bool fullAccess = false}) => UserModel(
      id: id,
      roleType: 'Employee',
      name: 'n',
      username: 'u',
      email: 'e',
      mobileNumber: 'm',
      hasFullAccess: fullAccess,
    );

    testWidgets('a Full Access login lands on All Members everywhere, an employee on Me, and the next login on the same phone recomputes it', (tester) async {
      await mount(tester);

      final boss = employee('boss', fullAccess: true);
      await signIn(tester, boss);
      for (final AuditFilterScope p in [audits, dashboard, ncs]) {
        expect(p.defaultTeamScope, isTrue);
        expect(p.isTeamScope, isTrue);
        expect(p.filterParams, isNull);
        expect(p.activeFilterCount, 0);
      }
      expect(audits.selfEmployeeId, 'boss', reason: 'a Full Access Role is still a real employee: Me stays possible');
      audits.setFilterState(isTeam: false);
      expect(audits.filterParams, {'employeeIds': 'boss'});

      await signOut(tester, boss);
      for (final AuditFilterScope p in [audits, dashboard, ncs]) {
        expect(p.defaultTeamScope, isFalse);
        expect(p.isTeamScope, isFalse);
      }

      final worker = employee('worker');
      await signIn(tester, worker);
      for (final AuditFilterScope p in [audits, dashboard, ncs]) {
        expect(p.defaultTeamScope, isFalse);
        expect(p.isTeamScope, isFalse);
      }
      expect(audits.filterParams, {'employeeIds': 'worker'});

      await signOut(tester, worker);
      await signIn(tester, boss);
      expect(audits.isTeamScope, isTrue);
      expect(audits.filterParams, isNull);
    });

    testWidgets('a SuperAdmin (no employee id) lands on All Members and keeps sending no person filter', (tester) async {
      await mount(tester);
      await signIn(
        tester,
        const UserModel(id: 'admin', roleType: 'SuperAdmin', name: 'n', username: 'u', email: 'e', mobileNumber: 'm'),
      );
      expect(audits.selfEmployeeId, isNull);
      expect(audits.isTeamScope, isTrue);
      expect(audits.filterParams, isNull);
      expect(audits.activeFilterCount, 0);
    });
  });
}

// A sentinel for "the key is not in the payload at all" (null is a value too).
const Object _absent = Object();
