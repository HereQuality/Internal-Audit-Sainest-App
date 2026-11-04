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
import 'package:internal_audit_app/widgets/final_report_excel_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The Excel actions on the real Final Report screen (Download Excel for the tab, and Download All): every one of the three tabs has them,
/// in the same place, under the shared filter bar and the tab bar, at the narrowest phone
/// width, in both themes — and it does not get in the way of the lists.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    SocketService.debugInstance = FakeSockets().service;
    DioClient.instance.dio.httpClientAdapter = FakeAdapter()
      ..handler = (o) async {
        switch (o.path) {
          case ApiConstants.auditsReport:
            return json(200, {
              'isOk': true,
              'data': {'audits': <Object>[], 'total': 0, 'page': 1, 'limit': 20},
            });
          case ApiConstants.ncsReport:
            return json(200, {
              'isOk': true,
              'data': {'ncs': <Object>[], 'total': 0, 'page': 1, 'limit': 20},
            });
          case ApiConstants.ncsRepeats:
            return json(200, {
              'isOk': true,
              'data': {'rows': <Object>[], 'total': 0, 'page': 1, 'limit': 30},
            });
          default:
            return json(200, {'isOk': true, 'data': <String, dynamic>{}});
        }
      };
  });

  Future<void> pumpScreen(WidgetTester tester, {double width = 320, ThemeData? theme}) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuditsProvider()..setSelfEmployeeId('me')),
          ChangeNotifierProvider(create: (_) => NcProvider()..setSelfEmployeeId('me')),
          ChangeNotifierProvider(create: (_) => DashboardProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider(create: (_) => FilterOptionsProvider()),
          ChangeNotifierProvider(create: (_) => ListViewMemory()),
        ],
        child: MaterialApp(theme: theme ?? AppTheme.light(), home: const ReportsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text(name)));
    await tester.pumpAndSettle();
  }

  for (final dark in [false, true]) {
    testWidgets('every tab has "Download Excel" under the tab bar, at 320 px wide, ${dark ? 'dark' : 'light'} theme', (tester) async {
      await pumpScreen(tester, theme: dark ? AppTheme.dark() : AppTheme.light());
      final tabBar = tester.getRect(find.byType(TabBar));
      for (final (name, caption) in [
        ('Audits', 'Every report your filters match'),
        ('NCs', 'Every NC your filters match'),
        ('Repeated NCs', 'Every repeated checkpoint your filters match'),
      ]) {
        await openTab(tester, name);
        expect(find.byType(FinalReportExcelBar), findsOneWidget, reason: name);
        expect(find.text('Download Excel'), findsOneWidget, reason: name);
        expect(find.text(caption), findsOneWidget, reason: name);
        // The same place on every tab: right under the tab bar, above the list.
        final bar = tester.getRect(find.byType(FinalReportExcelBar));
        expect(bar.top, greaterThanOrEqualTo(tabBar.bottom - 0.5), reason: name);
        expect(bar.top - tabBar.bottom, lessThan(8), reason: name);
        // Both buttons: this tab's Excel, and Download All (every tab, one file) — each a 44 px touch target.
        expect(find.text('Download All'), findsOneWidget, reason: name);
        for (final label in ['Download Excel', 'Download All']) {
          final button = find.descendant(of: find.byType(FinalReportExcelBar), matching: find.widgetWithText(OutlinedButton, label));
          expect(tester.getSize(button).height, greaterThanOrEqualTo(44), reason: '$name $label');
          expect(tester.getRect(button).right, lessThanOrEqualTo(320), reason: '$name $label');
        }
        expect(tester.takeException(), isNull, reason: name);
      }
    });
  }

  testWidgets('the Excel bar sits in one place whichever tab is showing, and the lists still have room', (tester) async {
    await pumpScreen(tester);
    await openTab(tester, 'Audits');
    final first = tester.getRect(find.byType(FinalReportExcelBar));
    await openTab(tester, 'NCs');
    final second = tester.getRect(find.byType(FinalReportExcelBar));
    await openTab(tester, 'Repeated NCs');
    final third = tester.getRect(find.byType(FinalReportExcelBar));
    expect(second, first);
    expect(third, first);
    // The list below it is still the tab's own (the empty state under the bar).
    expect(find.text('No repeats in this window'), findsOneWidget);
  });
}
