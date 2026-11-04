import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/employee_option.dart';
import 'package:internal_audit_app/models/self_audit.dart';
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/audits/audit_detail_screen.dart';
import 'package:internal_audit_app/screens/audits/select_representative_sheet.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/report_pdf_builder.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// A SELF audit: the auditor conducted the audit without an auditee because the auditee did not respond / was not
/// available. It is the other answer to the "select representative auditee" step — no one is named, the report's Auditee
/// reads "Self", and a reason + remark say why (server/utils/selfAudit.js, models/self_audit.dart).
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

  Map<String, dynamic> person(String name) => {'_id': name.toLowerCase(), 'employeeName': name};

  AuditDetailModel auditOf(Map<String, dynamic> over, {String status = 'In Progress'}) => AuditDetailModel.fromJson({
    '_id': 'a1',
    'title': 'Line 1 GMP',
    'status': status,
    'displayStatus': status == 'Completed' ? 'Closed' : 'In Progress',
    'scoringSystem': 'normal',
    'structureMode': 'same',
    'maxScore': 10,
    'scheduledDate': '2026-10-05T00:00:00.000Z',
    'auditorIds': [person('Asha')],
    'locationIds': [
      {'_id': 'l1', 'name': 'Zone 1'},
    ],
    'parameters': [
      {
        '_id': 'c1',
        'name': 'Fire exit is clear',
        'findingType': 'Compliance',
        'score': 10,
        'remark': 'Clear',
        'photoUrls': <String>[],
        'children': <Map<String, dynamic>>[],
      },
    ],
    'scoreResult': {'achieved': 10, 'maxPossible': 10, 'percentage': 100, 'scoredCount': 1, 'leafCount': 1, 'notApplicableCount': 0, 'isFullyScored': true},
    ...over,
  });

  const selfFields = {'selfAudit': true, 'selfAuditReason': 'not_responding', 'selfAuditRemark': 'Called twice, no answer'};

  // ── the model ─────────────────────────────────────────────────────────────

  group('the audit model', () {
    test('reads the flag, the reason and the remark', () {
      final a = auditOf({...selfFields});
      expect(a.selfAudit, isTrue);
      expect(a.selfAuditReason, 'not_responding');
      expect(a.selfAuditRemark, 'Called twice, no answer');
      expect(a.isSelfAudit, isTrue);
      expect(a.selfAuditNote, 'Auditee not responding — Called twice, no answer');
      expect(a.auditeeLabel(), 'Self');
    });

    test('an audit that is not a self audit says nothing of it', () {
      final a = auditOf({});
      expect(a.selfAudit, isFalse);
      expect(a.isSelfAudit, isFalse);
      expect(a.selfAuditNote, '');
      expect(a.auditeeLabel(), '—');
      expect(a.auditeeLabel(fallback: ''), '');
    });

    test('a named representative always wins over a stale flag', () {
      final a = auditOf({...selfFields, 'auditeeIds': [person('Ravi')]});
      expect(a.isSelfAudit, isFalse);
      expect(a.selfAuditNote, '');
      expect(a.auditeeLabel(), 'Ravi');
      expect(auditOf({...selfFields, 'auditeeId': person('Meena')}).isSelfAudit, isFalse);
    });

    test('the reasons, their labels and the note', () {
      expect(SelfAuditReason.fromCode('not_available'), SelfAuditReason.notAvailable);
      expect(SelfAuditReason.fromCode('on_leave'), isNull);
      expect(SelfAuditReason.notAvailable.label, 'Auditee not available');
      expect(selfAuditNoteOf('not_available', '  On leave  '), 'Auditee not available — On leave');
      expect(selfAuditNoteOf(null, 'Only a remark'), 'Only a remark');
      expect(selfAuditNoteOf('not_responding', ''), 'Auditee not responding');
    });
  });

  // ── the representative sheet ───────────────────────────────────────────────

  group('the representative sheet offers Self', () {
    Widget host(Widget Function(BuildContext) open, {double textScale = 1}) => MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: Builder(builder: open)),
    );

    void phone(WidgetTester tester, {double height = 900}) {
      tester.view.physicalSize = Size(390, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    final people = [
      for (final n in ['Ravi Kumar', 'Sara Khan'])
        EmployeeOption(id: n.split(' ').first.toLowerCase(), name: n),
    ];

    Future<void> pump(WidgetTester tester, List<EmployeeOption> employees, void Function(RepresentativeChoice?) got, {SelfAuditChoice? initialSelf, double textScale = 1}) async {
      await tester.pumpWidget(host(
        (context) => TextButton(
          onPressed: () async => got(await showSelectRepresentativeSheet(context, employees: employees, initialSelf: initialSelf)),
          child: const Text('open'),
        ),
        textScale: textScale,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    const selfButton = 'Self — the auditee is not responding or not available';

    testWidgets('naming people still works: Confirm returns the ids, not Self', (tester) async {
      phone(tester);
      RepresentativeChoice? result;
      await pump(tester, people, (r) => result = r);
      expect(find.text(selfButton), findsOneWidget);
      await tester.tap(find.text('Sara Khan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm (1)'));
      await tester.pumpAndSettle();
      expect(result?.isSelf, isFalse);
      expect(result?.employeeIds, ['sara']);
    });

    testWidgets('Self opens a form that needs a reason AND a remark, and returns both (trimmed)', (tester) async {
      phone(tester);
      RepresentativeChoice? result;
      await pump(tester, people, (r) => result = r);
      await tester.tap(find.text(selfButton));
      await tester.pumpAndSettle();

      expect(find.text('Self audit'), findsOneWidget);
      expect(find.text('Auditee not responding'), findsOneWidget);
      expect(find.text('Auditee not available'), findsOneWidget);
      // Nothing yet: it says what is missing, and cannot be confirmed.
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Choose why')).onPressed, isNull);

      await tester.tap(find.text('Auditee not available'));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Add a remark')).onPressed, isNull);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();
      expect(find.text('Add a remark'), findsOneWidget, reason: 'spaces are no remark');

      await tester.enterText(find.byType(TextField), '  On leave till Monday  ');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();

      expect(result?.isSelf, isTrue);
      expect(result?.employeeIds, isEmpty);
      expect(result?.self?.reason, SelfAuditReason.notAvailable);
      expect(result?.self?.remark, 'On leave till Monday');
    });

    testWidgets('closing the Self form goes back to the people list — it does not close everything', (tester) async {
      phone(tester);
      var answered = false;
      await pump(tester, people, (_) => answered = true);
      await tester.tap(find.text(selfButton));
      await tester.pumpAndSettle();
      expect(find.text('Self audit'), findsOneWidget);

      // Dismiss the form by dragging it down.
      await tester.drag(find.text('Self audit'), const Offset(0, 800));
      await tester.pumpAndSettle();

      expect(find.text('Select Representative Auditee'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(answered, isFalse);
    });

    testWidgets('with nobody to pick from the sheet still opens, says so, and Self works', (tester) async {
      phone(tester);
      RepresentativeChoice? result;
      await pump(tester, const [], (r) => result = r);
      expect(find.text('Nothing to pick from.'), findsOneWidget);
      expect(find.textContaining('No members were found'), findsOneWidget);
      await tester.tap(find.text(selfButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auditee not responding'));
      await tester.enterText(find.byType(TextField), 'No one at the site');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();
      expect(result?.isSelf, isTrue);
      expect(result?.self?.remark, 'No one at the site');
    });

    testWidgets('changing a self audit reopens it with its reason and remark filled in', (tester) async {
      phone(tester);
      RepresentativeChoice? result;
      await pump(
        tester,
        people,
        (r) => result = r,
        initialSelf: const SelfAuditChoice(reason: SelfAuditReason.notAvailable, remark: 'On leave'),
      );
      expect(find.text('Change Representative Auditee'), findsOneWidget);
      await tester.tap(find.text('Self — edit the reason or remark'));
      await tester.pumpAndSettle();
      expect(find.text('On leave'), findsOneWidget);
      // Reason and remark are already there, so it can be confirmed as it stands.
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();
      expect(result?.self?.reason, SelfAuditReason.notAvailable);
      expect(result?.self?.remark, 'On leave');
    });

    testWidgets('a small phone at large text with the keyboard up does not overflow, in the list', (tester) async {
      phone(tester, height: 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await pump(tester, people, (_) {}, textScale: 1.6);
      expect(tester.takeException(), isNull);
      expect(find.text('Select Representative Auditee'), findsOneWidget);
    });

    testWidgets('the Self form on a small phone at large text with the keyboard up and a long remark does not overflow, and still confirms', (tester) async {
      phone(tester, height: 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      SelfAuditChoice? result;
      await tester.pumpWidget(host(
        (context) => TextButton(
          onPressed: () async => result = await showSelfAuditSheet(context),
          child: const Text('open'),
        ),
        textScale: 1.6,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // The form scrolls inside the small space above the keyboard: reach the reason first.
      await tester.ensureVisible(find.text('Auditee not responding'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auditee not responding'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'x' * 400);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();
      expect(result?.remark, 'x' * 400);
    });
  });

  // ── the audit screen ───────────────────────────────────────────────────────

  group('the audit screen', () {
    late AuthProvider auth;
    late AuditsProvider audits;
    late Map<String, dynamic> detail;
    List<Map<String, dynamic>> members = [];

    setUp(() {
      auth = AuthProvider()..user = UserModel.fromJson({'_id': 'u1', 'roleType': 'Employee', 'employeeName': 'Asha'});
      audits = AuditsProvider()..setSelfEmployeeId('u1');
      members = [
        {'_id': 'e1', 'employeeName': 'Ravi Kumar', 'teamIds': <Object>[], 'isActive': true},
      ];
      detail = _screenAudit();
      adapter.handler = (o) async {
        if (o.method == 'GET' && o.path == '/audits/a1') return json(200, {'isOk': true, 'data': detail});
        if (o.method == 'GET' && o.path.startsWith('/employees/by-location')) return json(200, {'isOk': true, 'data': members});
        if (o.method == 'PATCH' && o.path == ApiConstants.auditRepresentative('a1')) {
          final body = o.data as Map;
          if (body['selfAudit'] == true) {
            detail = _screenAudit(extra: {
              'selfAudit': true,
              'selfAuditReason': body['selfAuditReason'],
              'selfAuditRemark': body['selfAuditRemark'],
            });
          } else {
            detail = _screenAudit(extra: {
              'auditeeIds': [
                for (final id in body['auditeeEmployeeIds'] as List) {'_id': id, 'employeeName': 'Ravi Kumar'},
              ],
            });
          }
          return json(200, {'isOk': true, 'data': {}});
        }
        return json(200, {'isOk': true, 'data': []});
      };
    });

    tearDown(() => auth.dispose());

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider<AuditsProvider>.value(value: audits),
            ChangeNotifierProvider(create: (_) => DashboardProvider()),
            ChangeNotifierProvider(create: (_) => NcProvider()),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const AuditDetailScreen(auditId: 'a1')),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('with no representative the sheet opens on its own and offers Self', (tester) async {
      await open(tester);
      expect(find.text('Select Representative Auditee'), findsOneWidget);
      expect(find.textContaining('Self —'), findsOneWidget);
    });

    testWidgets('choosing Self sends the reason and remark, lifts the gate, and the screen says Self with why', (tester) async {
      await open(tester);
      await tester.tap(find.textContaining('Self — the auditee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auditee not responding'));
      await tester.enterText(find.byType(TextField), 'Called twice, no answer');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();

      final sent = adapter.where('PATCH', ApiConstants.auditRepresentative('a1'));
      expect(sent, hasLength(1));
      expect(sent.single.data, {'selfAudit': true, 'selfAuditReason': 'not_responding', 'selfAuditRemark': 'Called twice, no answer'});

      // The gate is gone and the screen names Self and the reason.
      expect(find.textContaining('Select a representative auditee'), findsNothing);
      expect(find.text('Representative: Self'), findsOneWidget);
      expect(find.text('Self audit — Auditee not responding — Called twice, no answer'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

    testWidgets('a saved self audit is not asked again: no sheet, no blocking banner', (tester) async {
      detail = _screenAudit(extra: {'selfAudit': true, 'selfAuditReason': 'not_available', 'selfAuditRemark': 'On leave'});
      await open(tester);
      expect(find.text('Select Representative Auditee'), findsNothing);
      expect(find.textContaining('Select a representative auditee'), findsNothing);
      expect(find.text('Representative: Self'), findsOneWidget);
      expect(find.text('Self audit — Auditee not available — On leave'), findsOneWidget);
    });

    testWidgets('a location with nobody in it no longer dead-ends: the sheet opens and Self gets the auditor going', (tester) async {
      members = [];
      await open(tester);
      expect(find.text('Select Representative Auditee'), findsOneWidget);
      expect(find.text('Nothing to pick from.'), findsOneWidget);
      await tester.tap(find.textContaining('Self — the auditee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auditee not available'));
      await tester.enterText(find.byType(TextField), 'Nobody at the site today');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();
      expect(find.text('Representative: Self'), findsOneWidget);
    });

    testWidgets('a server refusal keeps the form: the error shows and the sheet comes back with what was typed', (tester) async {
      final ok = adapter.handler!;
      adapter.handler = (o) async {
        if (o.method == 'PATCH' && o.path == ApiConstants.auditRepresentative('a1')) {
          return json(400, {'isOk': false, 'message': 'Add a remark for the self audit — what you tried and what happened.'});
        }
        return ok(o);
      };
      await open(tester);
      await tester.tap(find.textContaining('Self — the auditee'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Auditee not responding'));
      await tester.enterText(find.byType(TextField), 'Called twice');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm Self audit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Add a remark for the self audit'), findsWidgets);
      // Nothing was saved, so the gate is still up.
      expect(find.text('Representative: Self'), findsNothing);
    });

    testWidgets('naming people after Self ends it: the screen lists the names again', (tester) async {
      detail = _screenAudit(extra: {'selfAudit': true, 'selfAuditReason': 'not_responding', 'selfAuditRemark': 'No answer'});
      await open(tester);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ravi Kumar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Representative: Ravi Kumar'), findsOneWidget);
      expect(find.textContaining('Self audit —'), findsNothing);
    });
  });

  // ── the report and the Excel ───────────────────────────────────────────────

  group('the report says Self', () {
    String textOf(Uint8List pdf) {
      final raw = latin1.decode(pdf);
      final words = <String>[];
      for (final m in RegExp(r'(?<!end)stream\r?\n').allMatches(raw)) {
        final end = raw.indexOf('endstream', m.end);
        if (end < 0) continue;
        List<int> data;
        try {
          data = ZLibCodec().decode(pdf.sublist(m.end, end));
        } catch (_) {
          continue;
        }
        final text = latin1.decode(data, allowInvalid: true);
        for (final t in RegExp(r'\[\(((?:\\.|[^\\)])*)\)\]TJ').allMatches(text)) {
          words.add(t.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (e) => e.group(1)!));
        }
      }
      return words.join(' ');
    }

    test('the PDF header reads AUDITEE: Self and a SELF AUDIT block gives the reason and the remark', () async {
      final text = textOf(await buildReportPdf(auditOf({...selfFields}, status: 'Completed')));
      expect(text, contains('AUDITEE:'));
      expect(text, contains('Self'));
      expect(text, contains('SELF AUDIT'));
      expect(text, contains('Auditee not responding'));
      expect(text, contains('Called twice, no answer'));
    });

    test('an audit with a named auditee has no SELF AUDIT block and shows the name', () async {
      final text = textOf(await buildReportPdf(auditOf({'auditeeIds': [person('Ravi')]}, status: 'Completed')));
      expect(text, contains('Ravi'));
      expect(text, isNot(contains('SELF AUDIT')));
    });

    test('a combined report: Self once after the names, and each self zone leads its note when there are several', () async {
      final zones = [
        auditOf({...selfFields, '_id': 'z1', 'locationIds': [{'_id': 'l1', 'name': 'Plant 1'}]}, status: 'Completed'),
        auditOf({'_id': 'z2', 'auditeeIds': [person('Ravi')], 'locationIds': [{'_id': 'l2', 'name': 'Plant 2'}]}, status: 'Completed'),
        auditOf({'_id': 'z3', 'selfAudit': true, 'selfAuditReason': 'not_available', 'selfAuditRemark': 'On leave', 'locationIds': [{'_id': 'l3', 'name': 'Plant 3'}]}, status: 'Completed'),
      ];
      final text = textOf(await buildCombinedReportPdf(zones));
      expect(text, contains('SELF AUDIT'));
      expect(text, contains('Called twice, no answer'));
      expect(text, contains('On leave'));
      expect(text, contains('Plant 1'));
      expect(text, contains('Plant 3'));
    });

    test('the Excel names the auditee Self — and a named one always wins', () {
      expect(auditeesOf({'selfAudit': true, 'auditeeIds': <Object>[]}), 'Self');
      expect(auditeesOf({'selfAudit': true}), 'Self');
      expect(auditeesOf({'selfAudit': true, 'auditeeIds': [person('Ravi')]}), 'Ravi');
      expect(auditeesOf({'selfAudit': false}), '');
      expect(auditeesOf({}), '');
    });
  });
}

Map<String, dynamic> _screenAudit({Map<String, dynamic> extra = const {}}) => {
  '_id': 'a1',
  'title': 'Line 1 GMP',
  'status': 'In Progress',
  'displayStatus': 'In Progress',
  'auditorIds': [
    {'_id': 'u1', 'employeeName': 'Asha'},
  ],
  'scheduledDate': '2026-09-04T00:00:00.000Z',
  'scoringSystem': 'normal',
  'structureMode': 'same',
  'maxScore': 10,
  'locationIds': [
    {'_id': 'L1', 'name': 'Zone 1'},
  ],
  'locationParameters': <Map<String, dynamic>>[],
  'parameters': [
    {
      '_id': 'c1',
      'name': 'Fire exit is clear',
      'findingType': 'Compliance',
      'score': 10,
      'remark': 'Checked',
      'photoUrls': <String>[],
      'children': <Map<String, dynamic>>[],
    },
  ],
  'scoreResult': {'achieved': 10, 'maxPossible': 10, 'percentage': 100, 'scoredCount': 1, 'leafCount': 1, 'notApplicableCount': 0, 'isFullyScored': true},
  ...extra,
};
