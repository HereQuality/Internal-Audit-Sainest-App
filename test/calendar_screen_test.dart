import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/list_view_memory.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/audits/audit_detail_screen.dart';
import 'package:internal_audit_app/screens/calendar/calendar_screen.dart';
import 'package:internal_audit_app/screens/nc/nc_response_screen.dart';
import 'package:internal_audit_app/screens/nc/nc_review_screen.dart';
import 'package:internal_audit_app/widgets/app_loading.dart';
import 'package:internal_audit_app/widgets/calendar_day_agenda.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The phone Calendar as a person uses it: three layer switches, a month grid whose
/// cells carry markers, and the agenda of the selected day. Today is fixed at
/// Tuesday 3 November 2026 so the month is the same on every run.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late _Data data;
  late AuditsProvider audits;
  late NcProvider ncs;
  late DashboardProvider dash;
  late ListViewMemory memory;

  // Noon local: the same calendar day wherever the test runs.
  String iso(int y, int m, int d) => DateTime(y, m, d, 12).toUtc().toIso8601String();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    SocketService.debugInstance = FakeSockets().service;
    data = _Data();
    adapter = FakeAdapter()..handler = data.handle;
    DioClient.instance.dio.httpClientAdapter = adapter;
    audits = AuditsProvider()..setSelfEmployeeId('me');
    ncs = NcProvider()..setSelfEmployeeId('me');
    dash = DashboardProvider()..setSelfEmployeeId('me');
    memory = ListViewMemory();
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 390,
    double height = 2600,
    double textScale = 1,
    bool dark = false,
    bool settle = true,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuditsProvider>.value(value: audits),
          ChangeNotifierProvider<DashboardProvider>.value(value: dash),
          ChangeNotifierProvider<NcProvider>.value(value: ncs),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider<ListViewMemory>.value(value: memory),
        ],
        child: MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: CalendarScreen(clock: () => DateTime(2026, 11, 3, 10)),
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  Finder day(String key) => find.byKey(ValueKey('calendar-day-$key'));

  Future<void> selectDay(WidgetTester tester, String key) async {
    await tester.tap(day(key));
    await tester.pumpAndSettle();
  }

  Finder chip(String label) => find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first;

  String chipCount(WidgetTester tester, String label) {
    final texts = find.descendant(of: chip(label), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data);
    return texts.last!;
  }

  Finder card(String title) => find.ancestor(of: find.text(title), matching: find.byType(Card)).first;

  Finder iconIn(Finder within, IconData icon) => find.descendant(of: within, matching: find.byIcon(icon));

  // ── fixtures ──────────────────────────────────────────────────────────────

  void richData() {
    data.mine = [
      _audit('a1', 'Weekly Safety Audit', iso(2026, 11, 3), status: 'In Progress', auditee: {'_id': 'aud1', 'employeeName': 'Meera Shah'}, extra: {
        'auditType': 'Safety',
        'recurrence': {'seriesId': 's1', 'frequency': 'Weekly', 'occurrenceIndex': 3, 'occurrenceCount': 12},
      }),
      _audit('a2', 'Boiler Room Check', iso(2026, 11, 3), status: 'Overdue', extra: {
        'selfAudit': true,
        'selfAuditReason': 'not_responding',
        'selfAuditRemark': 'Called twice',
      }),
      _audit('a5', 'Quarterly Review', iso(2026, 11, 9), end: iso(2026, 11, 11), status: 'Not Started', extra: {'scope': 'Cover bay 12 only'}),
    ];
    data.location = [
      _audit('a2', 'Boiler Room Check', iso(2026, 11, 3), status: 'Overdue', extra: {
        'selfAudit': true,
        'selfAuditReason': 'not_responding',
        'selfAuditRemark': 'Called twice',
      }),
      _audit('a3', 'Fire Drill Audit', iso(2026, 11, 3), status: 'Not Started', auditors: ['Rakesh Kumar'], auditee: {'_id': 'me', 'employeeName': 'Me User'}),
      _audit('a4', 'Packaging Audit', iso(2026, 11, 3), status: 'In Progress', auditors: ['Rakesh Kumar', 'Priya Nair'], auditee: {'_id': 'zed', 'employeeName': 'Zed Khan'}),
    ];
    data.ncs = [
      _nc('n1', 'Guard missing', status: 'Raised', start: iso(2026, 11, 2), target: iso(2026, 11, 10), auditee: 'me'),
      _nc('n2', 'Oil leak', status: 'Response Submitted', start: iso(2026, 10, 30), target: iso(2026, 11, 3), auditee: 'me'),
      _nc('n3', 'Old finding', status: 'Closed', start: iso(2026, 10, 28), target: iso(2026, 11, 20), auditee: 'me'),
      _nc('n4', 'Not my NC', status: 'Raised', start: iso(2026, 11, 1), target: iso(2026, 11, 12), auditee: 'someone-else'),
    ];
  }

  // ── the agenda ────────────────────────────────────────────────────────────

  group('the day agenda', () {
    testWidgets('opens on today with every card of the day — title, status, whose it is, when, who, auditee, where', (tester) async {
      richData();
      await mount(tester);

      expect(find.text('November 2026'), findsOneWidget);
      expect(find.text('Today · Tuesday 3 November 2026'), findsOneWidget);
      expect(find.text('5 items'), findsOneWidget);

      // My audit: its chips and rows.
      final weekly = card('Weekly Safety Audit');
      expect(find.descendant(of: weekly, matching: find.text('In Progress')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('My audit')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('Safety')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('Weekly · 3 of 12')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('3 Nov 2026')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('Auditor: Asha Rao')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('Auditee: Meera Shah')), findsOneWidget);
      expect(find.descendant(of: weekly, matching: find.text('Plant 1')), findsOneWidget);
    });

    testWidgets('a SELF audit reads "Self" for its auditee, with the reason and remark under it', (tester) async {
      richData();
      await mount(tester);
      final boiler = card('Boiler Room Check');
      expect(find.descendant(of: boiler, matching: find.text('Auditee: Self')), findsOneWidget);
      expect(find.descendant(of: boiler, matching: find.text('Auditee not responding — Called twice')), findsOneWidget);
      expect(find.descendant(of: boiler, matching: find.text('Overdue')), findsOneWidget);
    });

    testWidgets('an audit that is NOT mine leads with who is coming; one where I am the auditee says so', (tester) async {
      richData();
      await mount(tester);

      final packaging = card('Packaging Audit');
      expect(find.descendant(of: packaging, matching: find.text('Coming to audit: Rakesh Kumar, Priya Nair')), findsOneWidget);
      expect(find.descendant(of: packaging, matching: find.text('Not yours — at my location')), findsOneWidget);
      expect(find.descendant(of: packaging, matching: find.text('Auditee: Zed Khan')), findsOneWidget);
      // "Who is coming" is the first row: above the date.
      final comingY = tester.getTopLeft(find.descendant(of: packaging, matching: find.text('Coming to audit: Rakesh Kumar, Priya Nair'))).dy;
      final dateY = tester.getTopLeft(find.descendant(of: packaging, matching: find.text('3 Nov 2026'))).dy;
      expect(comingY, lessThan(dateY));

      final drill = card('Fire Drill Audit');
      expect(find.descendant(of: drill, matching: find.text('At my location — you are the auditee')), findsOneWidget);
      expect(find.descendant(of: drill, matching: find.text('Coming to audit: Rakesh Kumar')), findsOneWidget);
      expect(find.descendant(of: drill, matching: find.text('Auditee: Me User')), findsOneWidget);
      expect(find.descendant(of: drill, matching: find.text('Not Started')), findsOneWidget);
    });

    testWidgets('a department-only audit shows its departments as the place, never a blank', (tester) async {
      data.mine = [
        _audit('d1', 'HOD Round', iso(2026, 11, 3), noLocation: true, extra: {
          'departmentIds': [
            {'_id': 'dep1', 'departmentName': 'Warehouse Dept'},
          ],
        }),
      ];
      await mount(tester);
      expect(find.descendant(of: card('HOD Round'), matching: find.text('Warehouse Dept')), findsOneWidget);
    });

    testWidgets('cards are ordered audits first (mine, then at my location), the NCs last', (tester) async {
      richData();
      await mount(tester);
      double y(String title) => tester.getTopLeft(card(title)).dy;
      expect(y('Boiler Room Check'), lessThan(y('Weekly Safety Audit')));
      expect(y('Weekly Safety Audit'), lessThan(y('Fire Drill Audit')));
      expect(y('Fire Drill Audit'), lessThan(y('Packaging Audit')));
      expect(y('Packaging Audit'), lessThan(y('Oil leak')));
    });

    testWidgets('tapping an audit card opens that audit', (tester) async {
      richData();
      await mount(tester);
      await tester.tap(card('Packaging Audit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AuditDetailScreen), findsOneWidget);
      expect(tester.widget<AuditDetailScreen>(find.byType(AuditDetailScreen)).auditId, 'a4');
    });

    testWidgets('a day with nothing on it says so', (tester) async {
      richData();
      await mount(tester);
      await selectDay(tester, '2026-11-04');
      expect(find.text('Nothing scheduled this day'), findsOneWidget);
      expect(find.text('Wednesday 4 November 2026'), findsOneWidget);
      expect(find.byType(CalendarEntryCard), findsNothing);
    });

    testWidgets('an empty calendar still draws the grid, the switches and the empty day', (tester) async {
      await mount(tester);
      expect(find.text('Nothing scheduled this day'), findsOneWidget);
      expect(find.text('My audits'), findsOneWidget);
      expect(day('2026-11-03'), findsOneWidget);
      expect(chipCount(tester, 'My audits'), '0');
    });
  });

  // ── multi-day ranges ──────────────────────────────────────────────────────

  group('multi-day audits', () {
    testWidgets('every day of the range is marked, and the agenda says which day it is', (tester) async {
      richData();
      await mount(tester);
      for (final d in ['09', '10', '11']) {
        expect(iconIn(day('2026-11-$d'), Icons.assignment_turned_in_outlined), findsOneWidget, reason: 'Nov $d');
      }
      for (final d in ['08', '12']) {
        expect(iconIn(day('2026-11-$d'), Icons.assignment_turned_in_outlined), findsNothing, reason: 'Nov $d');
      }
      await selectDay(tester, '2026-11-10');
      final review = card('Quarterly Review');
      expect(find.descendant(of: review, matching: find.text('9 – 11 Nov 2026 · day 2 of 3')), findsOneWidget);
      expect(find.descendant(of: review, matching: find.text('Cover bay 12 only')), findsOneWidget, reason: 'the audit\'s scope');
      // Nobody has been named as the auditee yet: the card says nothing about one (no "Auditee: —").
      expect(find.descendant(of: review, matching: find.textContaining('Auditee')), findsNothing);
      await selectDay(tester, '2026-11-11');
      expect(find.text('9 – 11 Nov 2026 · day 3 of 3'), findsOneWidget);
    });

    testWidgets('the chip counts it once', (tester) async {
      richData();
      await mount(tester);
      expect(chipCount(tester, 'My audits'), '3'); // Weekly, Boiler, Quarterly
    });
  });

  // ── layers ────────────────────────────────────────────────────────────────

  group('the layer switches', () {
    testWidgets('an audit that is both mine and at my location is plotted ONCE and counted under both', (tester) async {
      richData();
      await mount(tester);

      expect(chipCount(tester, 'My audits'), '3');
      expect(chipCount(tester, 'Audit at My Location'), '3'); // Boiler (also mine), Fire Drill, Packaging
      expect(chipCount(tester, 'My NCs'), '4');

      // One card for it, with the "your audit at my location" mark.
      expect(find.text('Boiler Room Check'), findsOneWidget);
      expect(find.descendant(of: card('Boiler Room Check'), matching: find.text('At my location — your audit')), findsOneWidget);

      // On the cell it is counted under its first layer only: mine = Weekly + Boiler, location = Fire Drill + Packaging.
      final cell = day('2026-11-03');
      expect(iconIn(cell, Icons.assignment_turned_in_outlined), findsOneWidget);
      expect(iconIn(cell, Icons.place_outlined), findsOneWidget);
      expect(iconIn(cell, Icons.warning_amber_rounded), findsOneWidget);
      expect(find.descendant(of: cell, matching: find.text('2')), findsNWidgets(2));
    });

    testWidgets('switching a layer off hides what belongs only to it; what fits another layer stays', (tester) async {
      richData();
      await mount(tester);

      await tester.tap(chip('My audits'));
      await tester.pumpAndSettle();
      expect(find.text('Weekly Safety Audit'), findsNothing, reason: 'mine only');
      expect(find.text('Boiler Room Check'), findsOneWidget, reason: 'also at my location');
      expect(find.text('Fire Drill Audit'), findsOneWidget);
      expect(find.text('Oil leak'), findsOneWidget);
      expect(find.text('4 items · 1 hidden by the switches above'), findsOneWidget);
      // The Quarterly Review (mine only) leaves the grid too.
      expect(iconIn(day('2026-11-10'), Icons.assignment_turned_in_outlined), findsNothing);
      expect(iconIn(day('2026-11-10'), Icons.warning_amber_rounded), findsOneWidget, reason: 'the NC due that day is a different layer');
      // Switching off never changes the numbers on the chips.
      expect(chipCount(tester, 'My audits'), '3');

      await tester.tap(chip('Audit at My Location'));
      await tester.pumpAndSettle();
      expect(find.text('Boiler Room Check'), findsNothing);
      expect(find.text('Fire Drill Audit'), findsNothing);
      expect(find.text('Oil leak'), findsOneWidget);
      expect(find.byType(CalendarAuditCard), findsNothing);

      await tester.tap(chip('My NCs'));
      await tester.pumpAndSettle();
      expect(find.text('Everything is switched off'), findsOneWidget);
      expect(find.byType(CalendarEntryCard), findsNothing);
      expect(iconIn(day('2026-11-03'), Icons.warning_amber_rounded), findsNothing);

      await tester.tap(chip('Audit at My Location'));
      await tester.pumpAndSettle();
      expect(find.text('Fire Drill Audit'), findsOneWidget);
      expect(find.text('Boiler Room Check'), findsOneWidget);
      expect(find.text('Weekly Safety Audit'), findsNothing);
      expect(find.text('Oil leak'), findsNothing);
      expect(find.text('3 items · 2 hidden by the switches above'), findsOneWidget);
    });

    testWidgets('a day whose items are all hidden says so rather than "nothing scheduled"', (tester) async {
      richData();
      await mount(tester);
      await selectDay(tester, '2026-11-10');
      await tester.tap(chip('My audits'));
      await tester.tap(chip('My NCs'));
      await tester.pumpAndSettle();
      expect(find.text('Nothing shown this day'), findsOneWidget);
      expect(find.text('2 items are hidden by the switches above.'), findsOneWidget);
    });

    testWidgets('the picks are remembered with the month on screen — through a remount', (tester) async {
      richData();
      await mount(tester);
      await tester.tap(chip('My NCs'));
      await tester.tap(chip('Audit at My Location'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text('December 2026'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await mount(tester);

      expect(find.text('December 2026'), findsOneWidget);
      expect(find.byTooltip('Next month'), findsOneWidget);
      // The chips are still off (crossed-out): the Nov 10 NC no longer shows once back in November.
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      await selectDay(tester, '2026-11-10');
      expect(find.text('Guard missing'), findsNothing, reason: 'My NCs is still off');
      expect(find.text('Quarterly Review'), findsOneWidget, reason: 'My audits is still on');
      await selectDay(tester, '2026-11-03');
      expect(find.text('Fire Drill Audit'), findsNothing, reason: 'Audit at My Location is still off');
      expect(find.text('Boiler Room Check'), findsOneWidget, reason: 'it is also mine');
    });

    testWidgets('a fresh login (cleared memory) opens with every layer on', (tester) async {
      richData();
      await mount(tester);
      await tester.tap(chip('My NCs'));
      await tester.pumpAndSettle();
      memory.resetForLogout();
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(find.text('Oil leak'), findsOneWidget);
    });
  });

  // ── NCs ───────────────────────────────────────────────────────────────────

  group('NC rows', () {
    testWidgets('each NC is on the day it was raised and on its due day, with its dates, audit and raiser', (tester) async {
      richData();
      await mount(tester);

      // Raised Nov 2, due Nov 10.
      await selectDay(tester, '2026-11-02');
      var guard = card('Guard missing');
      expect(find.descendant(of: guard, matching: find.text('Raised this day')), findsOneWidget);
      await selectDay(tester, '2026-11-10');
      guard = card('Guard missing');
      expect(find.descendant(of: guard, matching: find.text('Due this day')), findsOneWidget);
      expect(find.descendant(of: guard, matching: find.text('NC-n1')), findsOneWidget);
      expect(find.descendant(of: guard, matching: find.text('Raised 2 Nov 2026')), findsOneWidget);
      expect(find.descendant(of: guard, matching: find.text('Due 10 Nov 2026')), findsOneWidget);
      expect(find.descendant(of: guard, matching: find.text('Audit: Weekly Safety Audit')), findsOneWidget);
      expect(find.descendant(of: guard, matching: find.text('Raised by: Vikram Rao')), findsOneWidget);
      expect(find.descendant(of: guard, matching: find.text('Major flag')), findsOneWidget);
    });

    testWidgets('an NC waiting for my answer: Respond opens the response screen', (tester) async {
      richData();
      await mount(tester);
      await selectDay(tester, '2026-11-10');
      expect(find.widgetWithText(FilledButton, 'Respond'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Respond'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NcResponseScreen), findsOneWidget);
      expect(tester.widget<NcResponseScreen>(find.byType(NcResponseScreen)).nc.id, 'n1');
    });

    // NcReviewScreen's own "Finding raised <date>" header row overflows under the test font (Ahem, one em per glyph)
    // at phone widths — unrelated to this screen, so the two tests that open it use a wide viewport.
    testWidgets('a response waiting for review: Review opens the review screen', (tester) async {
      richData();
      await mount(tester, width: 900);
      // Oil leak is due Nov 3 (today) and is Response Submitted.
      expect(find.widgetWithText(FilledButton, 'Review'), findsOneWidget);
      expect(find.descendant(of: card('Oil leak'), matching: find.text('Due today')), findsOneWidget);
      await tester.tap(card('Oil leak'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NcReviewScreen), findsOneWidget);
      expect(tester.widget<NcReviewScreen>(find.byType(NcReviewScreen)).nc.id, 'n2');
    });

    testWidgets('a closed NC is only viewed; another person\'s NC that is still waiting for them is not mine to answer', (tester) async {
      richData();
      await mount(tester, width: 900);
      await selectDay(tester, '2026-11-20');
      expect(find.widgetWithText(FilledButton, 'View'), findsOneWidget);

      await selectDay(tester, '2026-11-12');
      expect(find.descendant(of: card('Not my NC'), matching: find.text('Raised')), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Respond'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'View'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NcReviewScreen), findsOneWidget);
      expect(tester.widget<NcReviewScreen>(find.byType(NcReviewScreen)).readOnly, isTrue);
    });

    testWidgets('an NC past its due day that is not closed is marked Overdue', (tester) async {
      data.ncs = [_nc('late', 'Late fix', status: 'Raised', start: iso(2026, 10, 20), target: iso(2026, 11, 1), auditee: 'me')];
      await mount(tester);
      await selectDay(tester, '2026-11-01');
      expect(find.descendant(of: card('Late fix'), matching: find.text('Overdue')), findsOneWidget);
    });
  });

  // ── the month ─────────────────────────────────────────────────────────────

  group('the month', () {
    testWidgets('the chevrons step a month, the title shows it, and a step selects the 1st (or today in the current month)', (tester) async {
      richData();
      await mount(tester);
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text('December 2026'), findsOneWidget);
      expect(find.text('Tuesday 1 December 2026'), findsOneWidget);
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      expect(find.text('October 2026'), findsOneWidget);
      expect(find.text('Thursday 1 October 2026'), findsOneWidget);
    });

    testWidgets('a sideways swipe on the grid steps a month either way', (tester) async {
      richData();
      await mount(tester);
      await tester.fling(day('2026-11-17'), const Offset(-300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('December 2026'), findsOneWidget);
      await tester.fling(day('2026-12-17'), const Offset(300, 0), 1200);
      await tester.pumpAndSettle();
      expect(find.text('November 2026'), findsOneWidget);
    });

    testWidgets('the title opens a month and year picker', (tester) async {
      richData();
      await mount(tester);
      await tester.tap(find.text('November 2026'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next year'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feb'));
      await tester.pumpAndSettle();
      expect(find.text('February 2027'), findsOneWidget);
      expect(find.text('Monday 1 February 2027'), findsOneWidget);
    });

    testWidgets('Today returns to the current month and selects today — and is only there when away from it', (tester) async {
      richData();
      await mount(tester);
      expect(find.text('Today'), findsNothing, reason: 'already on today');
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.text('Today · Tuesday 3 November 2026'), findsOneWidget);
      expect(find.text('Today'), findsNothing);
      // Away within the month: another day selected also offers it.
      await selectDay(tester, '2026-11-09');
      expect(find.text('Today'), findsOneWidget);
    });

    testWidgets('the neighbouring months\' days are in the grid, dimmed, with their own markers', (tester) async {
      data.mine = [_audit('oct', 'End of October', iso(2026, 10, 28), status: 'Overdue')];
      data.location = [_audit('dec', 'Early December', iso(2026, 12, 2), status: 'Not Started')];
      await mount(tester);
      // The November grid runs Mon 26 Oct .. Sun 6 Dec.
      expect(day('2026-10-26'), findsOneWidget);
      expect(day('2026-12-06'), findsOneWidget);
      expect(iconIn(day('2026-10-28'), Icons.assignment_turned_in_outlined), findsOneWidget);
      expect(iconIn(day('2026-12-02'), Icons.place_outlined), findsOneWidget);
      await selectDay(tester, '2026-10-28');
      expect(find.text('End of October'), findsOneWidget);
      expect(find.text('November 2026'), findsOneWidget, reason: 'tapping a neighbour day does not move the month');
    });

    testWidgets('the month grid carries the status colour of the most pressing audit on each marker', (tester) async {
      richData();
      await mount(tester);
      final mineIcon = tester.widget<Icon>(iconIn(day('2026-11-03'), Icons.assignment_turned_in_outlined));
      final overdue = tester.widget<Icon>(iconIn(day('2026-11-03'), Icons.assignment_turned_in_outlined)).color;
      expect(mineIcon.color, overdue);
      // Overdue (Boiler) beats In Progress (Weekly): the marker is the Overdue red, not the blue of In Progress.
      final notStarted = tester.widget<Icon>(iconIn(day('2026-11-09'), Icons.assignment_turned_in_outlined)).color;
      expect(mineIcon.color, isNot(notStarted));
    });
  });

  // ── what is asked of the server ───────────────────────────────────────────

  group('what the screen asks for', () {
    testWidgets('the month on screen and its neighbours — audits, audits at my location, and NCs by due and by raised date', (tester) async {
      richData();
      await mount(tester);

      expect(adapter.where('GET', ApiConstants.myAudits).single.queryParameters, {
        'employeeIds': 'me',
        'fromDate': '2026-07-29',
        'toDate': '2027-01-04',
      });
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation).single.queryParameters, {
        'fromDate': '2026-07-29',
        'toDate': '2027-01-04',
      });
      expect(
        adapter.where('GET', ApiConstants.ncsMine).map((r) => r.queryParameters),
        unorderedEquals([
          {'employeeIds': 'me', 'dueFrom': '2026-09-27', 'dueTo': '2027-01-04'},
          {'employeeIds': 'me', 'fromDate': '2026-09-27', 'toDate': '2027-01-04'},
        ]),
      );
    });

    testWidgets('stepping to a neighbouring month needs no new request; leaving the loaded span asks again', (tester) async {
      richData();
      await mount(tester);
      adapter.requests.clear();

      await tester.tap(find.byTooltip('Next month')); // December: inside the window
      await tester.pumpAndSettle();
      expect(adapter.requests, isEmpty);
      await tester.tap(find.byTooltip('Previous month'));
      await tester.tap(find.byTooltip('Previous month')); // October: inside too
      await tester.pumpAndSettle();
      expect(adapter.requests, isEmpty);

      await tester.tap(find.byTooltip('Next month'));
      await tester.tap(find.byTooltip('Next month'));
      await tester.tap(find.byTooltip('Next month')); // January 2027: leaves it
      await tester.pumpAndSettle();
      final mine = adapter.where('GET', ApiConstants.myAudits).toList();
      expect(mine, hasLength(1));
      expect(mine.single.queryParameters['toDate'], '2027-03-01');
      expect(adapter.where('GET', ApiConstants.auditsAtMyLocation), hasLength(1));
      expect(adapter.where('GET', ApiConstants.ncsMine), hasLength(2));
    });

    testWidgets('a Date range picked on another screen does not narrow the Calendar, is not in its sheet, and survives its Clear', (tester) async {
      richData();
      audits.setFilterState(dateRange: (DateTime(2026, 10, 1), DateTime(2026, 10, 15)), auditTypes: ['Safety']);
      await mount(tester);

      final req = adapter.where('GET', ApiConstants.myAudits).single.queryParameters;
      expect(req['fromDate'], '2026-07-29');
      expect(req['toDate'], '2027-01-04');
      // The Safety type is a Calendar filter (it shows, with Clear); the date range is not.
      expect(find.text('Safety'), findsWidgets);
      expect(find.text('Date range'), findsNothing);

      await tester.tap(find.text('Filters'));
      await tester.pumpAndSettle();
      expect(find.text('Month'), findsOneWidget);
      expect(find.text('Date range'), findsNothing);
      // Dismissed without applying.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(audits.auditTypeFilter, isEmpty);
      expect(audits.dateFrom, DateTime(2026, 10, 1), reason: 'Clear must not wipe a pick the Calendar cannot show');
      expect(audits.dateTo, DateTime(2026, 10, 15));
    });

    testWidgets('a live audit notification re-reads the Calendar while it is open', (tester) async {
      richData();
      final sockets = FakeSockets();
      SocketService.debugInstance = sockets.service;
      SocketService.instance.connect('jwt');
      audits.startListening();
      addTearDown(audits.stopListening);
      await mount(tester);
      adapter.requests.clear();

      data.mine = [...data.mine, _audit('new', 'Freshly Assigned', iso(2026, 11, 3), status: 'Not Started')];
      sockets.sockets.single.receive('new_notification', {'type': 'audit_assigned'});
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.text('Freshly Assigned'), findsOneWidget);
    });
  });

  // ── loading and errors ────────────────────────────────────────────────────

  group('loading and errors', () {
    testWidgets('the first load shows a spinner, then the calendar', (tester) async {
      richData();
      final gate = Completer<void>();
      data.gate = gate.future;
      await mount(tester, settle: false);
      await tester.pump();
      expect(find.byType(AppLoading), findsOneWidget);
      expect(find.text('November 2026'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(AppLoading), findsNothing);
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.text('Weekly Safety Audit'), findsOneWidget);
    });

    testWidgets('every read failing is an error with Retry — not an empty month — and Retry loads it', (tester) async {
      richData();
      data.failing = {ApiConstants.myAudits, ApiConstants.auditsAtMyLocation, ApiConstants.ncsMine};
      await mount(tester);
      expect(find.text('Something went wrong'), findsOneWidget);
      expect(find.text('Nothing scheduled this day'), findsNothing);
      expect(find.text('November 2026'), findsNothing);

      data.failing = {};
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong'), findsNothing);
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.text('Weekly Safety Audit'), findsOneWidget);
    });

    testWidgets('one source failing keeps the rest on screen under a notice with Retry', (tester) async {
      richData();
      data.failing = {ApiConstants.ncsMine};
      await mount(tester);
      expect(find.textContaining("Couldn't refresh the calendar"), findsOneWidget);
      expect(find.text('Weekly Safety Audit'), findsOneWidget);
      expect(find.text('Oil leak'), findsNothing);

      data.failing = {};
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't refresh the calendar"), findsNothing);
      expect(find.text('Oil leak'), findsOneWidget);
    });

    testWidgets('pull to refresh re-reads everything', (tester) async {
      richData();
      await mount(tester);
      adapter.requests.clear();
      data.mine = [...data.mine, _audit('new', 'Pulled In', iso(2026, 11, 3), status: 'Not Started')];
      // The pull has to cover a quarter of the (tall, test) viewport.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 1000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(adapter.where('GET', ApiConstants.myAudits), isNotEmpty);
      expect(find.text('Pulled In'), findsOneWidget);
    });
  });

  // ── layout ────────────────────────────────────────────────────────────────

  group('layout', () {
    void rich() {
      richData();
      data.mine = [
        ...data.mine,
        _audit('long', 'A Very Long Audit Title That Keeps Going Past The End Of The Card For Sure', iso(2026, 11, 3),
            status: 'NC Verification Pending',
            auditors: ['Abdulrahman Muhammad Al-Farouq', 'Bartholomew Featherstonehaugh'],
            auditee: {'_id': 'x', 'employeeName': 'Maximilian Konstantinopolous-Papadimitriou'},
            location: 'Zone A - Hot Rolling Mill, Bay 12 (North), Sub Zone 7',
            extra: {'auditType': 'Cross Functional Team Audit', 'timeliness': 'Delayed Completed'}),
        for (var i = 0; i < 6; i++) _audit('x$i', 'Extra audit $i', iso(2026, 11, 3), status: 'Total Closed'),
      ];
      data.ncs = [
        ...data.ncs,
        _nc('longnc', 'A very long non conformance title that also keeps going and going', status: 'Raised', start: iso(2026, 11, 3), target: iso(2026, 11, 3), auditee: 'me', auditTitle: 'An audit with a really quite long title as well'),
      ];
    }

    for (final width in [320.0, 360.0, 390.0]) {
      for (final dark in [false, true]) {
        for (final scale in [1.0, 1.6]) {
          testWidgets('no overflow at ${width.toInt()} px, ${dark ? 'dark' : 'light'}, text scale $scale — the whole page scrolled through', (tester) async {
            rich();
            await mount(tester, width: width, height: 640, textScale: scale, dark: dark);
            expect(tester.takeException(), isNull);
            final scrollable = find.byType(CustomScrollView);
            for (var i = 0; i < 14; i++) {
              await tester.drag(scrollable, const Offset(0, -220));
              await tester.pump();
              expect(tester.takeException(), isNull, reason: 'after scrolling $i times');
            }
            // And back up, with another day (and the month picker) opened at this size.
            for (var i = 0; i < 14; i++) {
              await tester.drag(scrollable, const Offset(0, 260));
              await tester.pump();
            }
            await tester.pumpAndSettle();
            // At the largest text on the smallest phone the switches alone fill the first screen: scroll to the grid.
            await tester.scrollUntilVisible(find.byKey(const ValueKey('calendar-day-2026-11-10')), 200, scrollable: find.byType(Scrollable).first);
            await tester.tap(find.byKey(const ValueKey('calendar-day-2026-11-10')));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.byTooltip('Next month'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('the month picker fits at 320 px and text scale 1.6', (tester) async {
      rich();
      await mount(tester, width: 320, height: 640, textScale: 1.6);
      await tester.tap(find.byTooltip('Next month')); // also exercises the title shrinking
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('2026').first);
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final m in ['Jan', 'Dec']) {
        expect(find.text(m), findsOneWidget);
        expect(tester.getSize(find.ancestor(of: find.text(m), matching: find.byType(InkWell)).first).height, greaterThanOrEqualTo(44));
      }
    });

    for (final (width, scale) in [(320.0, 1.6), (390.0, 1.0)]) {
      testWidgets('every control is at least 44 px: ${width.toInt()} px, text scale $scale', (tester) async {
        rich();
        await mount(tester, width: width, height: 2600, textScale: scale);
        void atLeast44(Finder f, String what) {
          final Size s;
          try {
            s = tester.getSize(f);
          } catch (e) {
            fail('$what: $e');
          }
          expect(s.height, greaterThanOrEqualTo(44), reason: '$what height');
          expect(s.width, greaterThanOrEqualTo(44), reason: '$what width');
        }

        for (final label in ['My audits', 'Audit at My Location', 'My NCs']) {
          atLeast44(chip(label), 'the $label switch');
        }
        atLeast44(find.ancestor(of: find.byIcon(Icons.chevron_left), matching: find.byType(IconButton)).first, 'previous month');
        atLeast44(find.ancestor(of: find.byIcon(Icons.chevron_right), matching: find.byType(IconButton)).first, 'next month');
        atLeast44(find.widgetWithText(OutlinedButton, 'Filters'), 'Filters');
        atLeast44(find.ancestor(of: find.text('November 2026'), matching: find.byType(InkWell)).first, 'the month title');
        for (final d in ['2026-11-01', '2026-11-03', '2026-11-30', '2026-12-06']) {
          atLeast44(day(d), 'day $d');
        }
        for (final action in ['Respond', 'Review']) {
          final button = find.widgetWithText(FilledButton, action);
          for (var i = 0; i < 80 && button.evaluate().isEmpty; i++) {
            await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
            await tester.pump();
          }
          atLeast44(button.first, action);
        }
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 20000));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Next month'));
        await tester.pumpAndSettle();
        atLeast44(find.ancestor(of: find.byIcon(Icons.chevron_left), matching: find.byType(IconButton)).first, 'previous month');
        final today = find.ancestor(of: find.byIcon(Icons.today_outlined), matching: find.byType(width >= 360 && scale <= 1.3 ? TextButton : IconButton));
        atLeast44(today.first, 'Today');
      });
    }

    testWidgets('a day cell stays legible: the number is never scaled below its size, and 30 fits a 320 px cell at text scale 1.6', (tester) async {
      rich();
      await mount(tester, width: 320, height: 2600, textScale: 1.6);
      final cell = tester.getSize(day('2026-11-30'));
      final number = tester.getSize(find.descendant(of: day('2026-11-30'), matching: find.text('30')));
      expect(number.width, lessThanOrEqualTo(cell.width));
      final style = tester.widget<Text>(find.descendant(of: day('2026-11-30'), matching: find.text('30'))).style!;
      expect(style.fontSize, greaterThanOrEqualTo(14));
    });

    testWidgets('the selected day is highlighted and so is today', (tester) async {
      rich();
      await mount(tester);
      Color? ringOf(String key) {
        final box = tester.widget<Container>(find.descendant(of: day(key), matching: find.byType(Container)).first);
        final deco = box.decoration as BoxDecoration?;
        return deco?.border is Border ? (deco!.border as Border).top.color : null;
      }

      expect(ringOf('2026-11-03'), isNotNull, reason: 'today is selected on open');
      await selectDay(tester, '2026-11-10');
      expect(ringOf('2026-11-10'), isNotNull);
      expect(ringOf('2026-11-03'), isNull);
    });

    testWidgets('a short phone: tapping a day brings its agenda into view', (tester) async {
      rich();
      await mount(tester, width: 360, height: 640);
      final header = find.text('Today · Tuesday 3 November 2026');
      await tester.tap(day('2026-11-17'));
      await tester.pumpAndSettle();
      final h = find.text('Tuesday 17 November 2026');
      expect(h, findsOneWidget);
      final top = tester.getTopLeft(h).dy;
      expect(top, lessThan(640 * 0.62));
      expect(top, greaterThan(0));
      expect(header, findsNothing);
    });
  });
}

/// What the fake server answers.
class _Data {
  List<Map<String, dynamic>> mine = [];
  List<Map<String, dynamic>> location = [];
  List<Map<String, dynamic>> ncs = [];
  Set<String> failing = {};
  Future<void>? gate;

  Future<ResponseBody> handle(RequestOptions o) async {
    if (gate != null) await gate;
    if (failing.contains(o.path)) {
      return json(500, {'isOk': false, 'message': 'The server had a problem'});
    }
    switch (o.path) {
      case ApiConstants.myAudits:
        return json(200, {'isOk': true, 'data': mine});
      case ApiConstants.auditsAtMyLocation:
        return json(200, {'isOk': true, 'data': location});
      case ApiConstants.ncsMine:
        return json(200, {'isOk': true, 'data': ncs});
      default:
        // Opening an audit from a card: the detail the screen then reads.
        if (o.method == 'GET' && RegExp(r'^/audits/[^/]+$').hasMatch(o.path)) {
          return json(200, {
            'isOk': true,
            'data': {
              '_id': o.path.split('/').last,
              'title': 'Opened audit',
              'status': 'In Progress',
              'displayStatus': 'In Progress',
              'scoringSystem': 'normal',
              'structureMode': 'same',
              'maxScore': 10,
              'scheduledDate': '2026-11-03T00:00:00.000Z',
              'parameters': <Object>[],
            },
          });
        }
        return json(200, {'isOk': true, 'data': <Object>[]});
    }
  }
}

Map<String, dynamic> _audit(
  String id,
  String title,
  String start, {
  String? end,
  String status = 'In Progress',
  List<String> auditors = const ['Asha Rao'],
  Map<String, dynamic>? auditee,
  String location = 'Plant 1',
  bool noLocation = false,
  Map<String, dynamic> extra = const {},
}) => {
  '_id': id,
  'title': title,
  'status': 'Scheduled',
  'displayStatus': status,
  'scheduledDate': start,
  'scheduledEndDate': end,
  'auditorIds': [
    for (final name in auditors) {'_id': 'u-${name.toLowerCase().replaceAll(' ', '-')}', 'employeeName': name},
  ],
  'auditeeId': auditee,
  'auditeeIds': auditee == null ? <Object>[] : [auditee],
  'locationIds': noLocation
      ? <Object>[]
      : [
          {'_id': 'l1', 'name': location},
        ],
  ...extra,
};

Map<String, dynamic> _nc(
  String id,
  String title, {
  required String status,
  required String start,
  required String target,
  required String auditee,
  String auditTitle = 'Weekly Safety Audit',
}) => {
  '_id': id,
  'ncId': 'NC-$id',
  'title': title,
  'status': status,
  'severity': 'Major',
  'auditId': {'_id': 'a1', 'title': auditTitle},
  'raisedByEmployeeId': {'_id': 'u-vikram', 'employeeName': 'Vikram Rao'},
  'auditeeEmployeeId': {'_id': auditee, 'employeeName': 'Auditee $auditee'},
  'startDate': start,
  'targetDate': target,
};
