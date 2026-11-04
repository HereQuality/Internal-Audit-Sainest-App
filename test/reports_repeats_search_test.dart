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
import 'package:internal_audit_app/screens/profile/reports_screen.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/final_report_request.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The Repeated NCs tab's search box: the Audits and NCs tabs each have one, and now this tab
/// has its own ("Search checkpoint or location...") — sent to GET /ncs/repeats as `search`
/// (the server matches the checkpoint wording, the location or the department, case-insensitively,
/// and counts the matching groups), debounced, back on page 1, remembered, naming itself when
/// nothing matches, and carried into the tab's Excel and into Download All.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late List<Map<String, dynamic>> groups;

  Map<String, dynamic> group(String key, String title, String place, {String? department, int count = 3}) => {
    'key': key,
    'title': title,
    'locationName': place,
    'departmentName': department,
    'count': count,
    'openCount': 1,
    'firstDate': '2026-07-01T00:00:00.000Z',
    'lastDate': '2026-09-01T00:00:00.000Z',
    'latestStatus': 'Raised',
    'ncIds': ['n-$key'],
  };

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    SocketService.debugInstance = FakeSockets().service;
    groups = [
      group('k1', 'Wet floor near the press', 'Plant 1'),
      group('k2', 'Guard missing', 'Plant 2', department: 'Maintenance'),
      group('k3', 'Oil leak', 'Warehouse'),
    ];
    adapter = FakeAdapter()
      ..handler = (o) async {
        if (o.path == ApiConstants.ncsRepeats) {
          // What the server does: ?search= narrows the GROUPS by wording / location / department, `total` is the
          // number of matching groups, a group's own count is never narrowed.
          final q = o.queryParameters;
          final search = '${q['search'] ?? ''}'.trim().toLowerCase();
          final matched = [
            for (final g in groups)
              if (search.isEmpty || [g['title'], g['locationName'], g['departmentName']].any((v) => v != null && '$v'.toLowerCase().contains(search))) g,
          ];
          final page = (q['page'] as num?)?.toInt() ?? 1;
          final limit = (q['limit'] as num?)?.toInt() ?? 30;
          return json(200, {
            'isOk': true,
            'data': {'rows': matched.skip((page - 1) * limit).take(limit).toList(), 'total': matched.length, 'page': page, 'limit': limit, 'minCount': q['minCount']},
          });
        }
        if (o.path == ApiConstants.auditsReport) {
          return json(200, {
            'isOk': true,
            'data': {'audits': <Object>[], 'total': 0, 'page': 1, 'limit': 20},
          });
        }
        if (o.path == ApiConstants.ncsReport) {
          return json(200, {
            'isOk': true,
            'data': {'ncs': <Object>[], 'total': 0, 'page': 1, 'limit': 20},
          });
        }
        return json(200, {'isOk': true, 'data': <String, dynamic>{}});
      };
    DioClient.instance.dio.httpClientAdapter = adapter;
  });

  /// Every GET /ncs/repeats so far, as the URL it was asked with (query string included).
  List<Uri> repeatsRequests() => [for (final r in adapter.where('GET', ApiConstants.ncsRepeats)) r.uri];

  late NcProvider ncs;

  Future<void> pumpScreen(WidgetTester tester, {ListViewMemory? memory, double width = 390, ThemeData? theme}) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mem = memory ?? ListViewMemory();
    // Open on the Repeated NCs tab (the third).
    mem.screen('reports').tab = 2;
    ncs = NcProvider()..setSelfEmployeeId('me');
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuditsProvider()..setSelfEmployeeId('me')),
          ChangeNotifierProvider.value(value: ncs),
          ChangeNotifierProvider(create: (_) => DashboardProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider<ListViewMemory>.value(value: mem),
        ],
        child: MaterialApp(theme: theme ?? AppTheme.light(), home: const ReportsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  final field = find.byKey(const ValueKey('repeats-search'));

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(field, text);
    await tester.pump();
  }

  Future<void> afterDebounce(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
  }

  testWidgets('the tab has a search box, like the Audits and NCs tabs, with the web tab\'s wording', (tester) async {
    await pumpScreen(tester);
    expect(field, findsOneWidget);
    expect(find.text('Search checkpoint or location...'), findsOneWidget);
    // All three groups to start with, and no search in the first request.
    expect(find.text('Wet floor near the press'), findsOneWidget);
    expect(find.text('Guard missing'), findsOneWidget);
    expect(find.text('Oil leak'), findsOneWidget);
    expect(repeatsRequests().first.queryParameters.containsKey('search'), isFalse);
  });

  testWidgets('fits at 320 px wide, in the dark theme too, without overflow', (tester) async {
    await pumpScreen(tester, width: 320, theme: AppTheme.dark());
    expect(tester.takeException(), isNull);
    expect(tester.getSize(field).height, greaterThanOrEqualTo(40));
    await type(tester, 'a long search with several words in it');
    expect(tester.takeException(), isNull);
  });

  testWidgets('is debounced like the other tabs: nothing is asked while typing, one request once it pauses — `search` in the URL, page 1', (tester) async {
    await pumpScreen(tester);
    final before = repeatsRequests().length;
    await type(tester, 'w');
    await tester.pump(const Duration(milliseconds: 100));
    await type(tester, 'we');
    await tester.pump(const Duration(milliseconds: 100));
    await type(tester, 'wet');
    await tester.pump(const Duration(milliseconds: 399));
    expect(repeatsRequests().length, before, reason: 'still inside the debounce');
    await afterDebounce(tester);
    final asked = repeatsRequests();
    expect(asked.length, before + 1);
    expect(asked.last.toString(), contains('search=wet'));
    expect(asked.last.queryParameters['search'], 'wet');
    expect(asked.last.queryParameters['page'], '1');
    expect(asked.last.queryParameters['minCount'], '2');
    expect(ncs.repeatsSearch, 'wet');
  });

  testWidgets('narrows the list on the server: the matching group is shown, with its own count untouched', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'wet');
    await afterDebounce(tester);
    expect(find.text('Wet floor near the press'), findsOneWidget);
    expect(find.text('Guard missing'), findsNothing);
    expect(find.text('Oil leak'), findsNothing);
    expect(find.text('1 repeated checkpoint'), findsOneWidget);
    // ×3: the group's own count is what the server says, not narrowed by the search.
    expect(find.text('×3'), findsOneWidget);
  });

  testWidgets('matches the location and the department too, in any case', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'MAINTENANCE');
    await afterDebounce(tester);
    expect(find.text('Guard missing'), findsOneWidget);
    expect(find.text('Oil leak'), findsNothing);
    await type(tester, 'warehouse');
    await afterDebounce(tester);
    expect(find.text('Oil leak'), findsOneWidget);
    expect(find.text('Guard missing'), findsNothing);
  });

  testWidgets('starts the list over from page 1, even from a later page', (tester) async {
    groups = [for (var i = 0; i < 70; i++) group('k$i', 'Checkpoint $i', 'Plant ${i % 5}')];
    await pumpScreen(tester);
    // (not awaited: the request is answered while the test pumps)
    ncs.goToRepeatsPage(2);
    await tester.pumpAndSettle();
    expect(repeatsRequests().last.queryParameters['page'], '2');
    await type(tester, 'Checkpoint 6');
    await afterDebounce(tester);
    final last = repeatsRequests().last;
    expect(last.queryParameters['search'], 'Checkpoint 6');
    expect(last.queryParameters['page'], '1');
    expect(ncs.repeatsPage, 1);
  });

  testWidgets('says what was searched when nothing matches — not "no repeats" — and Clear search brings the list back', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'zebra');
    await afterDebounce(tester);
    expect(find.text('No repeated checkpoints match "zebra"'), findsOneWidget);
    expect(find.text('No repeats in this window'), findsNothing);
    expect(find.text('Clear search'), findsWidgets);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Wet floor near the press'), findsOneWidget);
    expect(find.text('Oil leak'), findsOneWidget);
    expect(repeatsRequests().last.queryParameters.containsKey('search'), isFalse);
    expect(ncs.repeatsSearch, '');
    // With no search, an empty list is still the plain "no repeats" state.
    groups = [];
    await tester.drag(find.byType(ListView).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.text('No repeats in this window'), findsOneWidget);
  });

  testWidgets('the clear (x) button empties the box and reloads at once', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'wet');
    await afterDebounce(tester);
    final before = repeatsRequests().length;
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, '');
    expect(repeatsRequests().length, before + 1);
    expect(repeatsRequests().last.queryParameters.containsKey('search'), isFalse);
    expect(find.text('Guard missing'), findsOneWidget);
  });

  testWidgets('spaces around the words are not a different search: no new request', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'wet');
    await afterDebounce(tester);
    final before = repeatsRequests().length;
    await type(tester, '  wet ');
    await afterDebounce(tester);
    expect(repeatsRequests().length, before);
    // and it is sent trimmed.
    await type(tester, '  oil  ');
    await afterDebounce(tester);
    expect(repeatsRequests().last.queryParameters['search'], 'oil');
  });

  testWidgets('is remembered like the other tab state: back on the tab, the box and the list are as they were', (tester) async {
    final memory = ListViewMemory();
    await pumpScreen(tester, memory: memory);
    await type(tester, 'oil');
    await afterDebounce(tester);
    expect(find.text('Guard missing'), findsNothing);

    // A fresh screen (a remount) over the same memory.
    await tester.pumpWidget(const SizedBox());
    await pumpScreen(tester, memory: memory);
    expect(tester.widget<TextField>(field).controller!.text, 'oil');
    expect(repeatsRequests().last.queryParameters['search'], 'oil');
    expect(find.text('Oil leak'), findsOneWidget);
    expect(find.text('Guard missing'), findsNothing);
    expect(ncs.repeatsSearch, 'oil');

    // A different account starts clean.
    memory.resetForLogout();
    ncs.resetForLogout();
    expect(ncs.repeatsSearch, '');
    expect(memory.screen('reports-repeats').search, '');
  });

  testWidgets('pull-to-refresh and the Min. times pick keep the search', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'wet');
    await afterDebounce(tester);
    await tester.tap(find.byKey(const ValueKey('repeat-min-times')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3+').last);
    await tester.pumpAndSettle();
    final last = repeatsRequests().last;
    expect(last.queryParameters['minCount'], '3');
    expect(last.queryParameters['search'], 'wet');
    await tester.drag(find.byType(ListView).first, const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(repeatsRequests().last.queryParameters['search'], 'wet');
  });

  testWidgets('the Repeated NCs Excel and Download All carry the search: the request and the "Filters applied" line', (tester) async {
    await pumpScreen(tester);
    await type(tester, 'wet');
    await afterDebounce(tester);
    final audits = tester.element(field).read<AuditsProvider>();
    final options = tester.element(field).read<FilterOptionsProvider>();

    final single = buildFinalReportRequest(tab: FinalReportTab.repeats, audits: audits, ncs: ncs, options: options);
    expect(single.listQuery['search'], 'wet');
    expect(single.filters.firstWhere((f) => f.$1 == 'Search').$2, '"wet"');

    final all = buildFinalReportAllRequest(audits: audits, ncs: ncs, options: options);
    expect(all.repeats.listQuery['search'], 'wet');
    expect(all.repeats.filters.firstWhere((f) => f.$1 == 'Search').$2, '"wet"');
    // The other tabs' own searches are theirs: typing here does not touch them.
    expect(all.audits.listQuery.containsKey('search'), isFalse);
    expect(all.ncs.listQuery.containsKey('search'), isFalse);
  });
}
