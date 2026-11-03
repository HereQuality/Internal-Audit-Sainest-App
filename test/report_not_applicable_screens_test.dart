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
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// A checkpoint marked "Not Applicable" in the in-app Reports tab (ported from the reference app): the Reports tab lists an
/// audit's places with their scores, and a place of nothing but Not Applicable checkpoints has no score to show, so it
/// reads "—" like a place not graded yet — never a 0%, and not an "N/A" badge. (The audit screen, which is the report view
/// of a finished audit, is covered in not_applicable_test.dart; the PDF in report_not_applicable_test.dart.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    adapter = FakeAdapter()..handler = (o) async => json(200, {'isOk': true, 'data': []});
    DioClient.instance.dio.httpClientAdapter = adapter;
    SocketService.debugInstance = FakeSockets().service;
  });

  Map<String, dynamic> leaf(String id, String name, String? finding, {num? score, String? remark}) => {
    '_id': id,
    'name': name,
    'findingType': finding,
    'score': score,
    'remark': remark,
    'photoUrls': <String>[],
    'children': <Map<String, dynamic>>[],
  };

  for (final dark in [false, true]) {
    testWidgets('a zone with nothing graded reads "—" (${dark ? 'dark' : 'light'}, 360 wide)', (tester) async {
      const places = {
        'L1': {'_id': 'L1', 'name': 'Assembly Line 1', 'code': 'AL1'},
        'L2': {'_id': 'L2', 'name': 'Paint Shop', 'code': 'PS'},
      };
      final detail = {
        '_id': 'a1',
        'title': '5S Review - Plant 1',
        'status': 'Completed',
        'displayStatus': 'Total Closed',
        'scoringSystem': 'normal',
        'maxScore': 10,
        'structureMode': 'per-location',
        'parameters': <Map<String, dynamic>>[],
        'locationIds': [places['L1'], places['L2']],
        'locationParameters': [
          {
            'locationId': 'L1',
            'parameters': [leaf('c1', 'Floor is clean', 'Compliance', score: 10, remark: 'In order')],
          },
          {
            'locationId': 'L2',
            'parameters': [leaf('n1', 'Booth filters changed', 'Not Applicable'), leaf('n2', 'Solvent store locked', 'Not Applicable')],
          },
        ],
        'scoreResult': {'achieved': 10, 'maxPossible': 10, 'percentage': 100, 'scoredCount': 3, 'leafCount': 3, 'notApplicableCount': 2, 'isFullyScored': true},
      };
      adapter.handler = (o) async {
        if (o.path == ApiConstants.auditsReport) {
          return json(200, {
            'isOk': true,
            'data': {
              'audits': [
                {
                  '_id': 'a1',
                  'title': '5S Review - Plant 1',
                  'scope': '',
                  'status': 'Completed',
                  'displayStatus': 'Total Closed',
                  'timeliness': 'On-Time Completed',
                  'structureMode': 'per-location',
                  'scheduledDate': DateTime.now().toUtc().toIso8601String(),
                  'completedDate': DateTime.now().toUtc().toIso8601String(),
                  'auditorIds': [
                    {'_id': 'u1', 'employeeName': 'Asha'},
                  ],
                  'scoreResult': {'achieved': 10, 'maxPossible': 10, 'percentage': 100},
                  'locationIds': [places['L1'], places['L2']],
                },
              ],
              'total': 1,
              'page': 1,
              'limit': 100,
            },
          });
        }
        if (o.path == ApiConstants.auditById('a1')) return json(200, {'isOk': true, 'data': detail});
        return json(200, {'isOk': true, 'data': []});
      };

      tester.view.physicalSize = const Size(360, 1800);
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
          child: MaterialApp(theme: dark ? AppTheme.dark() : AppTheme.light(), home: const ReportsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('5S Review - Plant 1'));
      await tester.pumpAndSettle();

      expect(find.text('Assembly Line 1 (AL1)'), findsOneWidget);
      expect(find.text('Paint Shop (PS)'), findsOneWidget);
      expect(find.text('100%'), findsWidgets, reason: 'the graded zone (and the audit)');
      expect(find.text('—'), findsWidgets, reason: 'the zone with nothing graded');
      expect(find.text('N/A'), findsNothing);
      expect(find.text('0%'), findsNothing);
      expect(tester.takeException(), isNull, reason: 'no overflow at 360 wide');
    });
  }
}
