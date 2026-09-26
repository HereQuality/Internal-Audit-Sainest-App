import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/screens/audits/my_audits_screen.dart';
import 'package:internal_audit_app/screens/dashboard/dashboard_screen.dart';
import 'package:internal_audit_app/screens/profile/reports_screen.dart';
import 'package:internal_audit_app/widgets/audit_agenda.dart';
import 'package:internal_audit_app/widgets/status_badge.dart';
import 'package:internal_audit_app/widgets/status_filter_chip_row.dart';
import 'package:internal_audit_app/widgets/today_audits_section.dart';

/// The unified audit statuses on screen: the badges and pills, the filter
/// chip row, the dashboard's status tiles and where they route, the
/// dashboard's In Progress / Overdue sections and the agenda card following
/// the server's displayStatus, and — end to end through the real providers —
/// the Audits tab's chips filtering by it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now();
  DateTime daysFromNow(int d) => DateTime(now.year, now.month, now.day).add(Duration(days: d));

  AuditModel audit(
    String id, {
    String status = 'In Progress',
    String? displayStatus,
    String? timeliness,
    DateTime? scheduledDate,
    DateTime? scheduledEndDate,
  }) => AuditModel(
    id: id,
    title: 'Audit $id',
    scope: '',
    status: status,
    displayStatus: displayStatus,
    timeliness: timeliness,
    scheduledDate: scheduledDate ?? daysFromNow(-3),
    scheduledEndDate: scheduledEndDate,
  );

  // MediaQuery overrides do not resize the test surface (800x600 by default),
  // and "is this chip on screen" is only meaningful at a real phone width.
  void usePhone(WidgetTester tester, {double height = 1400}) {
    tester.view.physicalSize = Size(390, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app(Widget child, {double textScale = 1.0}) => MaterialApp(
    theme: AppTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: child),
    ),
  );

  group('TimelinessPill', () {
    testWidgets('shows On-Time / Delayed for the two server labels', (tester) async {
      await tester.pumpWidget(app(const Column(children: [
        TimelinessPill(timeliness: 'On-Time Completed'),
        TimelinessPill(timeliness: 'Delayed Completed'),
      ])));
      expect(find.text('On-Time'), findsOneWidget);
      expect(find.text('Delayed'), findsOneWidget);
    });

    testWidgets('draws nothing for null or a label it does not know', (tester) async {
      await tester.pumpWidget(app(const Column(children: [
        TimelinessPill(timeliness: null),
        TimelinessPill(timeliness: 'Sometime'),
      ])));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('StatusBadge with any label', () {
    testWidgets('an unknown server label renders as a neutral pill with its own text', (tester) async {
      await tester.pumpWidget(app(const StatusBadge(label: 'On Hold', color: Color(0xFF64748B))));
      expect(find.text('On Hold'), findsOneWidget);
    });
  });

  group('StatusFilterChipRow', () {
    const options = [
      'All',
      'Not Started',
      'In Progress',
      'Overdue',
      'Delayed Completed',
      'On-Time Completed',
      'NC Response Pending',
      'NC Verification Pending',
      'Total Closed',
    ];

    testWidgets('scrolls the selected chip into view even when it starts off the right edge', (tester) async {
      usePhone(tester);
      await tester.pumpWidget(app(const StatusFilterChipRow(
        options: options,
        selected: 'Total Closed',
        onSelected: _ignore,
      )));
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('Total Closed'));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
    });

    testWidgets('re-centres when the selection changes from outside, and reports taps', (tester) async {
      usePhone(tester);
      String selected = 'All';
      final picked = <String>[];
      late StateSetter setOuter;
      await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
        setOuter = setState;
        return StatusFilterChipRow(
          options: options,
          selected: selected,
          onSelected: picked.add,
        );
      })));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('All')).left, greaterThanOrEqualTo(0));

      setOuter(() => selected = 'NC Verification Pending');
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.text('NC Verification Pending'));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));

      await tester.tap(find.text('NC Verification Pending'));
      expect(picked, ['NC Verification Pending']);
    });

    testWidgets('draws a dot only for options the colour callback answers for', (tester) async {
      await tester.pumpWidget(app(StatusFilterChipRow(
        options: const ['All', 'Overdue'],
        selected: 'All',
        onSelected: _ignore,
        dotColorFor: (o) => o == 'All' ? null : const Color(0xFFAF352C),
      )));
      await tester.pumpAndSettle();
      final overdueChip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Overdue'));
      final allChip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All'));
      expect(overdueChip.avatar, isNotNull);
      expect(allChip.avatar, isNull);
    });
  });

  group('AuditStatsGrid (dashboard tiles)', () {
    const stats = AuditorStats(
      assignedAudits: 30,
      inProgress: 9,
      ncPending: 11,
      completed: 14,
      notStarted: 2,
      ongoing: 3,
      overdue: 4,
      // Completed audits split two ways that must agree: by timeliness
      // (5 + 6 = 11) and by NC stage (3 + 4 + 4 = 11).
      delayed: 5,
      onTimeCompleted: 6,
      ncResponsePending: 3,
      ncVerificationPending: 4,
      totalClosed: 4,
    );

    Future<List<(int, String?)>> pumpGrid(WidgetTester tester, {double textScale = 1.0}) async {
      usePhone(tester);
      final taps = <(int, String?)>[];
      await tester.pumpWidget(app(
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AuditStatsGrid(stats: stats, onNavigateToTab: (tab, {filter}) => taps.add((tab, filter))),
        ),
        textScale: textScale,
      ));
      return taps;
    }

    testWidgets('one tile per lifecycle status, in the owner\'s order, with the server\'s counts', (tester) async {
      await pumpGrid(tester);
      const expected = {
        'Not Started': '2',
        'In Progress': '3', // ongoing — overdue excluded, NOT stats.inProgress (9)
        'Overdue': '4',
        'Delayed Completed': '5',
        'On-Time Completed': '6',
        'NC Response Pending': '3',
        'NC Verification Pending': '4',
        'Total Closed': '4',
        'NC Pending': '11',
      };
      for (final e in expected.entries) {
        final label = find.text(e.key);
        expect(label, findsOneWidget, reason: e.key);
        // The tile's number sits in the same card as its label.
        final card = find.ancestor(of: label, matching: find.byType(Card));
        expect(find.descendant(of: card, matching: find.text(e.value)), findsOneWidget, reason: e.key);
      }
      // The retired tiles are gone.
      expect(find.text('Assigned Audits'), findsNothing);
      expect(find.text('Completed'), findsNothing);
      // Reading order = the owner's list.
      double top(String l) => tester.getTopLeft(find.text(l)).dy * 1000 + tester.getTopLeft(find.text(l)).dx;
      final order = expected.keys.toList();
      for (var i = 1; i < order.length; i++) {
        expect(top(order[i]), greaterThan(top(order[i - 1])), reason: '${order[i]} after ${order[i - 1]}');
      }
    });

    testWidgets('the numbers the tiles DISPLAY agree: On-Time + Delayed = NC Response + NC Verification + Total Closed', (tester) async {
      await pumpGrid(tester);
      int shown(String label) {
        final card = find.ancestor(of: find.text(label), matching: find.byType(Card));
        // The tile's number is the only all-digit text in its card.
        final digits = find.descendant(of: card, matching: find.byWidgetPredicate(
          (w) => w is Text && w.data != null && RegExp(r'^\d+$').hasMatch(w.data!),
        ));
        return int.parse(tester.widget<Text>(digits).data!);
      }

      expect(
        shown('On-Time Completed') + shown('Delayed Completed'),
        shown('NC Response Pending') + shown('NC Verification Pending') + shown('Total Closed'),
      );
    });

    testWidgets('every tile number is the server\'s tally, not a count of the loaded list', (tester) async {
      // The grid is handed nothing but AuditorStats: there is no audit list
      // for it to count, so a number can only be the server's. Feed values
      // no list could produce (a filter-narrowed list is far smaller than
      // the server-side tally) and they come through untouched.
      await tester.pumpWidget(app(SingleChildScrollView(
        child: AuditStatsGrid(
          stats: const AuditorStats(
            notStarted: 120,
            ongoing: 240,
            overdue: 360,
            delayed: 480,
            onTimeCompleted: 600,
            ncResponsePending: 300,
            ncVerificationPending: 400,
            totalClosed: 380,
          ),
        ),
      )));
      for (final n in ['120', '240', '360', '480', '600', '300', '400', '380']) {
        expect(find.text(n), findsOneWidget, reason: n);
      }
    });

    testWidgets('an older server without the NC-stage tallies hides those tiles instead of showing zeros', (tester) async {
      usePhone(tester);
      await tester.pumpWidget(app(SingleChildScrollView(
        child: AuditStatsGrid(
          stats: AuditorStats.fromJson({'assignedAudits': 9, 'assigned': 1, 'ongoing': 2, 'overdue': 0, 'delayed': 2, 'onTimeCompleted': 5}),
        ),
      )));
      expect(find.text('On-Time Completed'), findsOneWidget);
      expect(find.text('Delayed Completed'), findsOneWidget);
      expect(find.text('NC Response Pending'), findsNothing);
      expect(find.text('NC Verification Pending'), findsNothing);
      expect(find.text('Total Closed'), findsNothing);
      expect(find.text('Not Started'), findsOneWidget);
    });

    testWidgets('each status tile opens the Audits tab under the chip of the same name', (tester) async {
      final taps = await pumpGrid(tester);
      for (final label in [
        'Not Started',
        'In Progress',
        'Overdue',
        'Delayed Completed',
        'On-Time Completed',
        'NC Response Pending',
        'NC Verification Pending',
        'Total Closed',
      ]) {
        taps.clear();
        await tester.tap(find.text(label));
        expect(taps, [(1, label)], reason: label);
      }
    });

    testWidgets('NC Pending still goes to the NC Monitoring tab', (tester) async {
      final taps = await pumpGrid(tester);
      await tester.tap(find.text('NC Pending'));
      expect(taps, [(2, 'Open')]);
    });

    testWidgets('long labels fit at large text sizes (no overflow)', (tester) async {
      for (final scale in [1.0, 1.3, 1.6]) {
        await pumpGrid(tester, textScale: scale);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale $scale');
        expect(find.text('NC Verification Pending'), findsOneWidget);
      }
    });
  });

  group('dashboard In Progress / Overdue sections follow displayStatus', () {
    Future<void> pumpSections(WidgetTester tester, List<AuditModel> audits) => tester.pumpWidget(app(
      SingleChildScrollView(
        child: Column(children: [
          InProgressAuditsSection(audits: audits),
          OverdueAuditsSection(audits: audits),
        ]),
      ),
    ));

    testWidgets('the server\'s Overdue lands under Overdue and only there', (tester) async {
      // Raw status is In Progress for BOTH (that is what the server keeps
      // sending as `status`); only displayStatus tells them apart. The
      // overdue one even has a FUTURE end date, the in-progress one a PAST
      // one — the client's own date rule would get both wrong.
      final overdue = audit('late', displayStatus: 'Overdue', scheduledEndDate: daysFromNow(5));
      final running = audit('running', displayStatus: 'In Progress', scheduledEndDate: daysFromNow(-2));
      await pumpSections(tester, [overdue, running]);

      expect(find.text('In Progress Audits'), findsOneWidget);
      expect(find.text('Overdue Audits'), findsOneWidget);
      final inProgressSection = find.ancestor(of: find.text('In Progress Audits'), matching: find.byType(Column)).first;
      final overdueSection = find.ancestor(of: find.text('Overdue Audits'), matching: find.byType(Column)).first;
      expect(find.descendant(of: inProgressSection, matching: find.text('Audit running')), findsOneWidget);
      expect(find.descendant(of: inProgressSection, matching: find.text('Audit late')), findsNothing);
      expect(find.descendant(of: overdueSection, matching: find.text('Audit late')), findsOneWidget);
      expect(find.descendant(of: overdueSection, matching: find.text('Audit running')), findsNothing);
    });

    testWidgets('the badge on each card prints the display label', (tester) async {
      await pumpSections(tester, [
        audit('late', displayStatus: 'Overdue'),
        audit('running', displayStatus: 'In Progress'),
      ]);
      expect(find.text('Overdue'), findsOneWidget); // the badge (section title is "Overdue Audits")
      expect(find.text('In Progress'), findsOneWidget);
    });

    testWidgets('a completed audit never lands in either section', (tester) async {
      await pumpSections(tester, [
        audit('done', status: 'Completed', displayStatus: 'NC Response Pending', timeliness: 'Delayed Completed'),
      ]);
      expect(find.text('In Progress Audits'), findsNothing);
      expect(find.text('Overdue Audits'), findsNothing);
    });

    testWidgets('older server (no displayStatus): the old rules still apply', (tester) async {
      final overdueByDate = audit('oldLate', scheduledDate: daysFromNow(-10), scheduledEndDate: daysFromNow(-2));
      final onSchedule = audit('oldFine', scheduledDate: daysFromNow(-1), scheduledEndDate: daysFromNow(3));
      final done = audit('oldDone', status: 'Completed', scheduledDate: daysFromNow(-10), scheduledEndDate: daysFromNow(-2));
      await pumpSections(tester, [overdueByDate, onSchedule, done]);

      final overdueSection = find.ancestor(of: find.text('Overdue Audits'), matching: find.byType(Column)).first;
      expect(find.descendant(of: overdueSection, matching: find.text('Audit oldLate')), findsOneWidget);
      expect(find.descendant(of: overdueSection, matching: find.text('Audit oldFine')), findsNothing);
      expect(find.text('Audit oldDone'), findsNothing);
      // Raw status still In Progress -> the In Progress section, as before.
      final inProgressSection = find.ancestor(of: find.text('In Progress Audits'), matching: find.byType(Column)).first;
      expect(find.descendant(of: inProgressSection, matching: find.text('Audit oldFine')), findsOneWidget);
    });
  });

  group('agenda', () {
    final today = DateTime(now.year, now.month, now.day);

    test('isAuditOverdue prefers the server\'s displayStatus over the date rule', () {
      // Future end date but the server says Overdue -> overdue.
      expect(isAuditOverdue(audit('a', displayStatus: 'Overdue', scheduledEndDate: daysFromNow(5)), today), isTrue);
      // Past end date but the server says In Progress -> not overdue.
      expect(isAuditOverdue(audit('b', displayStatus: 'In Progress', scheduledEndDate: daysFromNow(-5)), today), isFalse);
      // A finished audit is never overdue, whatever its dates.
      expect(
        isAuditOverdue(
          audit('c', status: 'Completed', displayStatus: 'NC Response Pending', scheduledEndDate: daysFromNow(-5)),
          today,
        ),
        isFalse,
      );
    });

    test('isAuditOverdue falls back to the date rule with no displayStatus', () {
      expect(isAuditOverdue(audit('d', scheduledEndDate: daysFromNow(-1)), today), isTrue);
      expect(isAuditOverdue(audit('e', scheduledEndDate: daysFromNow(1)), today), isFalse);
      expect(isAuditOverdue(audit('f', status: 'Completed', scheduledEndDate: daysFromNow(-1)), today), isFalse);
    });

    test('a series summary is tallied from the display labels', () {
      final entry = AgendaEntry([
        audit('1', displayStatus: 'Overdue'),
        audit('2', displayStatus: 'Overdue'),
        audit('3', status: 'Completed', displayStatus: 'Total Closed'),
        audit('4', status: 'Not Started', displayStatus: 'Not Started'),
      ]);
      expect(entry.statusSummary, '2 Overdue, 1 Total Closed, 1 Not Started');
    });

    test('a series summary from an older server falls back to the raw statuses', () {
      final entry = AgendaEntry([
        audit('1', status: 'Not Started'),
        audit('2', status: 'Not Started'),
        audit('3', status: 'Completed'),
      ]);
      expect(entry.statusSummary, '2 Not Started, 1 Completed');
    });

    testWidgets('the card\'s badge says Overdue once — no second Overdue pill beside it', (tester) async {
      await tester.pumpWidget(app(AgendaAuditCard(
        audit: audit('late', displayStatus: 'Overdue', scheduledEndDate: daysFromNow(-1)),
        today: today,
      )));
      expect(find.text('Overdue'), findsOneWidget);
    });

    testWidgets('older server: the badge says In Progress and the Overdue pill still flags it', (tester) async {
      await tester.pumpWidget(app(AgendaAuditCard(
        audit: audit('oldLate', scheduledEndDate: daysFromNow(-1)),
        today: today,
      )));
      expect(find.text('In Progress'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
    });

    testWidgets('the On-Time / Delayed pill follows the server\'s timeliness alone (no client rule)', (tester) async {
      // An NC-stage audit the server sent no timeliness for gets no pill —
      // the app does not work one out from the dates.
      await tester.pumpWidget(app(AgendaAuditCard(
        audit: audit(
          'done',
          status: 'Completed',
          displayStatus: 'Total Closed',
          scheduledDate: daysFromNow(-10),
          scheduledEndDate: daysFromNow(-5),
        ),
        today: today,
      )));
      expect(find.text('Total Closed'), findsOneWidget);
      expect(find.text('Delayed'), findsNothing);
      expect(find.text('On-Time'), findsNothing);
    });

    testWidgets('a finished audit shows its NC stage and its On-Time / Delayed pill', (tester) async {
      await tester.pumpWidget(app(AgendaAuditCard(
        audit: audit(
          'done',
          status: 'Completed',
          displayStatus: 'NC Response Pending',
          timeliness: 'Delayed Completed',
        ),
        today: today,
      )));
      expect(find.text('NC Response Pending'), findsOneWidget);
      expect(find.text('Delayed'), findsOneWidget);
      expect(find.text('Completed'), findsNothing);
    });
  });

  group('MyAuditsScreen status chips (real providers, fake network)', () {
    late _AuditsAdapter adapter;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      adapter = _AuditsAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
    });

    Map<String, dynamic> row(
      String id,
      String status,
      String display, {
      String? timeliness,
    }) => {
      '_id': id,
      'title': 'Audit $id',
      'scope': '',
      'status': status,
      'displayStatus': display,
      'timeliness': timeliness,
      // Today, so every card lands in the agenda's always-expanded Today
      // section instead of behind a collapsed past/later header.
      'scheduledDate': now.toUtc().toIso8601String(),
    };

    Future<void> pumpScreen(WidgetTester tester, {String? initialFilter}) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuditsProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => DashboardProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: MyAuditsScreen(initialStatusFilter: initialFilter)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    setUp(() {
      adapter.audits = [
        row('overdue', 'In Progress', 'Overdue'),
        row('running', 'In Progress', 'In Progress'),
        row('waiting', 'Completed', 'NC Response Pending', timeliness: 'Delayed Completed'),
        row('verifying', 'Completed', 'NC Verification Pending', timeliness: 'On-Time Completed'),
        row('closed', 'Completed', 'Total Closed', timeliness: 'On-Time Completed'),
      ];
    });

    testWidgets('a tile\'s filter arrives pre-selected and narrows the list to that status', (tester) async {
      await pumpScreen(tester, initialFilter: 'Overdue');
      expect(find.text('Audit overdue'), findsOneWidget);
      expect(find.text('Audit running'), findsNothing);
      expect(find.text('Audit closed'), findsNothing);
      // Never sent to the server: the filter stays client-side.
      expect(adapter.sawStatusParam, isFalse);
    });

    testWidgets('every status chip narrows to the audits whose badge says it', (tester) async {
      await pumpScreen(tester);
      // All five under "All".
      for (final id in ['overdue', 'running', 'waiting', 'verifying', 'closed']) {
        expect(find.text('Audit $id'), findsOneWidget, reason: 'All -> $id');
      }

      Future<void> pick(String chip) async {
        final finder = find.widgetWithText(ChoiceChip, chip);
        // The row scrolls sideways: bring the chip on screen the way a thumb
        // would before tapping it.
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      Set<String> shown() => {
        for (final id in ['overdue', 'running', 'waiting', 'verifying', 'closed'])
          if (find.text('Audit $id').evaluate().isNotEmpty) id,
      };

      await pick('In Progress');
      expect(shown(), {'running'}); // the overdue one is NOT In Progress
      await pick('Overdue');
      expect(shown(), {'overdue'});
      await pick('NC Response Pending');
      expect(shown(), {'waiting'});
      await pick('NC Verification Pending');
      expect(shown(), {'verifying'});
      await pick('Total Closed');
      expect(shown(), {'closed'});
      // The timeliness chips match by timeliness, across NC stages.
      await pick('Delayed Completed');
      expect(shown(), {'waiting'});
      await pick('On-Time Completed');
      expect(shown(), {'verifying', 'closed'});
      await pick('All');
      expect(shown(), hasLength(5));
    });

    testWidgets('a chip nothing matches says which status is empty', (tester) async {
      adapter.audits = [row('running', 'In Progress', 'In Progress')];
      await pumpScreen(tester, initialFilter: 'Total Closed');
      expect(find.text('No audits are Total Closed'), findsOneWidget);
    });

    testWidgets('the cards print the display label, never the raw status', (tester) async {
      await pumpScreen(tester);
      expect(find.text('NC Response Pending'), findsWidgets);
      expect(find.text('Total Closed'), findsWidgets);
      expect(find.text('Completed'), findsNothing);
    });
  });

  group('ReportsScreen (Final Report list)', () {
    late _AuditsAdapter adapter;

    setUp(() {
      FlutterSecureStorage.setMockInitialValues({});
      adapter = _AuditsAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;
    });

    Map<String, dynamic> row(
      String id,
      String status,
      String display, {
      String? timeliness,
      String? title,
      String? batchId,
      String? batchDisplay,
      String? batchTimeliness,
    }) => {
      '_id': id,
      'title': title ?? 'Report $id',
      'scope': '',
      'status': status,
      'displayStatus': display,
      'timeliness': timeliness,
      'scheduleBatchId': batchId,
      'batchDisplayStatus': batchDisplay,
      'batchTimeliness': batchTimeliness,
      'completedDate': now.toUtc().toIso8601String(),
      'scheduledDate': now.toUtc().toIso8601String(),
    };

    // [width] defaults to a phone. Widget tests draw every glyph as a full-em
    // square (the Ahem test font), ~1.8x wider than Roboto/SF, so a test that
    // wants "does it fit on a real phone" widens the surface by that factor
    // instead of asserting against text that is nearly twice as wide as real.
    Future<void> pumpScreen(WidgetTester tester, {double textScale = 1.0, double width = 390}) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [ChangeNotifierProvider(create: (_) => AuditsProvider())],
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const ReportsScreen(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    // A status as printed on a report CARD — the chips carry the same words.
    Finder onCard(String text) => find.descendant(of: find.byType(Card), matching: find.text(text));

    Future<void> pick(WidgetTester tester, String chip) async {
      final finder = find.widgetWithText(ChoiceChip, chip);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('defaults to every audit whose RAW status is Completed, badged by NC stage', (tester) async {
      adapter.audits = [
        row('closed', 'Completed', 'Total Closed', timeliness: 'On-Time Completed'),
        row('waiting', 'Completed', 'NC Response Pending', timeliness: 'Delayed Completed'),
        row('open', 'In Progress', 'Overdue'),
      ];
      await pumpScreen(tester);

      // The default view keeps showing finished audits — whatever their NC
      // stage — and only those.
      expect(find.text('Report closed'), findsOneWidget);
      expect(find.text('Report waiting'), findsOneWidget);
      expect(find.text('Report open'), findsNothing);
      expect(onCard('Total Closed'), findsOneWidget);
      expect(onCard('NC Response Pending'), findsOneWidget);
      // The raw word never reaches a badge (it is only the chip's own label).
      expect(onCard('Completed'), findsNothing);
      // On-Time / Delayed pills sit with the finished audits.
      expect(find.text('On-Time'), findsOneWidget);
      expect(find.text('Delayed'), findsOneWidget);
    });

    testWidgets('the status chips narrow the list by display status / timeliness', (tester) async {
      adapter.audits = [
        row('closed', 'Completed', 'Total Closed', timeliness: 'On-Time Completed'),
        row('waiting', 'Completed', 'NC Response Pending', timeliness: 'Delayed Completed'),
        row('open', 'In Progress', 'Overdue'),
      ];
      await pumpScreen(tester);

      await pick(tester, 'Overdue');
      expect(find.text('Report open'), findsOneWidget);
      expect(find.text('Report closed'), findsNothing);

      await pick(tester, 'Delayed Completed');
      expect(find.text('Report waiting'), findsOneWidget);
      expect(find.text('Report closed'), findsNothing);

      await pick(tester, 'Total Closed');
      expect(find.text('Report closed'), findsOneWidget);
      expect(find.text('Report waiting'), findsNothing);

      await pick(tester, 'NC Verification Pending');
      expect(find.text('No audits are NC Verification Pending'), findsOneWidget);

      await pick(tester, 'All');
      expect(find.text('Report open'), findsOneWidget);
      expect(find.text('Report closed'), findsOneWidget);
    });

    testWidgets('a batch parent row shows the batch aggregate, its members their own status', (tester) async {
      // Both of this employee's zones are Total Closed, but another zone of
      // the batch (not on this list) is still open: the parent must say
      // In Progress — not Total Closed, not "Completed", not "Mixed".
      adapter.audits = [
        row('z1', 'Completed', 'Total Closed', title: 'Multi-zone audit', batchId: 'b1', batchDisplay: 'In Progress'),
        row('z2', 'Completed', 'Total Closed', title: 'Multi-zone audit', batchId: 'b1', batchDisplay: 'In Progress'),
      ];
      await pumpScreen(tester);

      expect(find.text('2 locations'), findsOneWidget);
      expect(onCard('In Progress'), findsOneWidget);
      expect(find.text('Mixed'), findsNothing);
      // The batch is not finished, so the server sent no batchTimeliness —
      // and the parent row does not invent one from its zones.
      expect(find.text('Delayed'), findsNothing);
      expect(find.text('On-Time'), findsNothing);
      expect(onCard('Total Closed'), findsNothing); // members are collapsed

      await tester.tap(find.text('2 locations'));
      await tester.pumpAndSettle();
      expect(onCard('Total Closed'), findsNWidgets(2)); // each zone's own
      expect(onCard('In Progress'), findsOneWidget); // still the parent's
    });

    testWidgets('a finished batch carries its aggregate status and On-Time / Delayed', (tester) async {
      adapter.audits = [
        row('z1', 'Completed', 'Total Closed', title: 'Multi-zone audit', batchId: 'b1',
            batchDisplay: 'NC Response Pending', batchTimeliness: 'Delayed Completed'),
        row('z2', 'Completed', 'NC Response Pending', title: 'Multi-zone audit', batchId: 'b1',
            batchDisplay: 'NC Response Pending', batchTimeliness: 'Delayed Completed'),
      ];
      await pumpScreen(tester);

      expect(onCard('NC Response Pending'), findsOneWidget);
      expect(find.text('Delayed'), findsOneWidget);
    });

    testWidgets('the longest status fits the batch header and the zone rows, also at large text', (tester) async {
      adapter.audits = [
        row('z1', 'Completed', 'NC Verification Pending', title: 'Multi-zone audit', batchId: 'b1',
            batchDisplay: 'NC Verification Pending', batchTimeliness: 'On-Time Completed', timeliness: 'On-Time Completed'),
        row('z2', 'Completed', 'NC Verification Pending', title: 'Multi-zone audit', batchId: 'b1',
            batchDisplay: 'NC Verification Pending', batchTimeliness: 'On-Time Completed', timeliness: 'On-Time Completed'),
      ];
      for (final scale in [1.0, 1.3]) {
        // Fresh screen each time — the previous pass left the batch expanded.
        await tester.pumpWidget(const SizedBox());
        // A 390pt phone in Ahem terms (see pumpScreen), times the text scale.
        await pumpScreen(tester, textScale: scale, width: 390 * 1.8 * scale);
        // Expand by the title: at a squeezed width the "N locations" chip
        // text can be too narrow to hit.
        await tester.tap(find.text('Multi-zone audit'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'scale $scale');
        expect(onCard('NC Verification Pending'), findsNWidgets(3)); // parent + two zones
      }
    });
  });
}

void _ignore(String _) {}

/// GET /audits/mine answers with [audits]; everything else with an empty
/// list. Records whether the app ever sent a `status` query parameter.
class _AuditsAdapter implements HttpClientAdapter {
  List<Map<String, dynamic>> audits = [];
  bool sawStatusParam = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.queryParameters.containsKey('status')) sawStatusParam = true;
    final data = options.path == ApiConstants.myAudits ? audits : <dynamic>[];
    return ResponseBody.fromString(
      jsonEncode({'isOk': true, 'data': data}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
