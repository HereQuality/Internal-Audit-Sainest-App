import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/user_model.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/dashboard_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/screens/audits/audit_detail_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// A checkpoint marked "Not Applicable" (server/utils/scoring.js#NOT_APPLICABLE): handled — the audit can be completed
/// without it — but outside the score. Ported from the reference app and adapted to this one: the model's counts (which
/// include it, which leave it out), the requests the app sends for a score and for the N/A mark, and the audit screen.
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

  Map<String, dynamic> leaf(String id, {String? finding, num? score, String? remark, String? ncId, String? name}) => {
    '_id': id,
    'name': name ?? 'Checkpoint $id',
    'weight': null,
    'weightage': null,
    'findingType': finding,
    'score': score,
    'remark': remark,
    'photoUrls': <String>[],
    'ncId': ncId,
    'children': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> na(String id, {String? name}) => leaf(id, finding: 'Not Applicable', name: name);

  Map<String, dynamic> groupNode(String id, String name, List<Map<String, dynamic>> children) => {
    '_id': id,
    'name': name,
    'children': children,
  };

  AuditDetailModel audit(
    List<Map<String, dynamic>> parameters, {
    bool instant = false,
    String structure = 'per-location',
    Map<String, dynamic>? scoreResult,
    List<Map<String, dynamic>> departmentTrees = const [],
  }) => AuditDetailModel.fromJson({
    '_id': 'a1',
    'isInstant': instant,
    'status': instant ? 'Draft' : 'In Progress',
    'scoringSystem': 'normal',
    'structureMode': structure,
    'maxScore': 10,
    'locationIds': [
      {'_id': 'l1', 'name': 'Zone 1'},
    ],
    'locationParameters': structure == 'per-location'
        ? [
            {'locationId': 'l1', 'parameters': parameters},
          ]
        : <Map<String, dynamic>>[],
    'departmentParameters': departmentTrees,
    'parameters': structure == 'per-location' ? <Map<String, dynamic>>[] : parameters,
    'scoreResult': ?scoreResult,
  });

  group('the node and the score result', () {
    test('a checkpoint is Not Applicable when its finding says so — and it round-trips through toJson', () {
      final node = ParameterNode.fromJson(na('a'));
      expect(node.isNotApplicable, isTrue);
      expect(node.findingType, notApplicableFinding);
      expect(node.findingType, 'Not Applicable');
      expect(ParameterNode.fromJson(node.toJson()).isNotApplicable, isTrue, reason: 'a whole-list save sends it back as it is');
      expect(ParameterNode.fromJson(leaf('b', finding: 'NC')).isNotApplicable, isFalse);
      expect(ParameterNode.fromJson(leaf('c')).isNotApplicable, isFalse);
    });

    test('scoreResult.notApplicableCount is read, and is 0 from an older server', () {
      expect(AuditScoreResult.fromJson({'scoredCount': 3, 'leafCount': 3, 'notApplicableCount': 2, 'isFullyScored': true}).notApplicableCount, 2);
      expect(AuditScoreResult.fromJson({'scoredCount': 3, 'leafCount': 3}).notApplicableCount, 0);
      expect(AuditScoreResult.fromJson(null).notApplicableCount, 0);
    });
  });

  group('progress counting — done includes Not Applicable', () {
    final mixed = audit([
      leaf('a', finding: 'Compliance', score: 10),
      na('b'),
      leaf('c'),
      leaf('d', finding: 'NC', score: 0, ncId: 'nc1'),
    ]);

    test('Not Applicable counts as done — "done x / y" includes it — but is not in the finding tallies', () {
      expect(mixed.leafTotal, 4);
      expect(mixed.scoredTotal, 3, reason: 'Compliance, Not Applicable, NC; the blank one is still to do');
      expect(mixed.notApplicableTotal, 1);
      expect(mixed.ratedTotal, 2, reason: 'only a finding that carries a score');
      expect([for (final f in ['Strong Compliance', 'Compliance', 'OFI', 'NC']) mixed.findingCount(f)], [0, 1, 0, 1]);
    });

    test('the counts walk every place\'s checklist, nested groups and departments included', () {
      final a = audit(
        [
          groupNode('g', 'Group', [leaf('a', finding: 'OFI', score: 4), na('b'), leaf('c')]),
        ],
        departmentTrees: [
          {
            'departmentId': 'd1',
            'parameters': [na('x'), leaf('y', finding: 'Strong Compliance', score: 10)],
          },
        ],
      );
      expect((a.leafTotal, a.scoredTotal, a.notApplicableTotal, a.ratedTotal), (5, 4, 2, 2));
    });

    test('a shared checklist ("same") is read from the audit\'s own parameters', () {
      final a = audit([leaf('a', finding: 'Compliance', score: 10), na('b')], structure: 'same');
      expect((a.leafTotal, a.scoredTotal, a.notApplicableTotal), (2, 2, 1));
    });

    test('every checkpoint Not Applicable: an Instant audit is read from its checklist, a planned one from the cached score', () {
      expect(mixed.everyCheckpointNotApplicable, isFalse);
      expect(audit([na('a'), na('b')], instant: true).everyCheckpointNotApplicable, isTrue);
      expect(audit([na('a'), leaf('b')], instant: true).everyCheckpointNotApplicable, isFalse, reason: 'one is still blank');
      expect(audit(const [], instant: true).everyCheckpointNotApplicable, isFalse, reason: 'nothing there at all');

      AuditDetailModel planned(int na, int leaves) => audit([leaf('a')], scoreResult: {'leafCount': leaves, 'scoredCount': leaves, 'notApplicableCount': na});
      expect(planned(3, 3).everyCheckpointNotApplicable, isTrue);
      expect(planned(2, 3).everyCheckpointNotApplicable, isFalse);
      expect(planned(0, 0).everyCheckpointNotApplicable, isFalse);
    });

    test('the sentence shown when everything is Not Applicable is the server\'s own', () {
      expect(
        allNotApplicableText,
        'Every checkpoint is marked Not Applicable, so there is nothing to score. Make at least one applicable and score it before submitting.',
      );
    });

    test('the Score line: the percentage, done / total (N/A counts as done) and how many are N/A; — when nothing is graded', () {
      const withNa = AuditScoreResult(percentage: 90, scoredCount: 6, leafCount: 6, notApplicableCount: 4);
      expect(scoreSummaryLine(withNa), 'Score: 90% (6/6 · 4 N/A)');
      const none = AuditScoreResult(percentage: 80, scoredCount: 1, leafCount: 1);
      expect(scoreSummaryLine(none), 'Score: 80% (1/1)');
      const allNa = AuditScoreResult(scoredCount: 2, leafCount: 2, notApplicableCount: 2);
      expect(scoreSummaryLine(allNa), 'Score: — (2/2 · 2 N/A)', reason: 'nothing graded: no percentage, never 0%');
    });
  });

  group('the requests the app sends', () {
    late AuditsProvider provider;
    setUp(() => provider = AuditsProvider());

    Map<String, dynamic> lastPatchBody(String nodeId) {
      final patches = adapter.where('PATCH', ApiConstants.scoreParameter('a1', nodeId)).toList();
      expect(patches, isNotEmpty);
      return Map<String, dynamic>.from(patches.last.data as Map);
    }

    test('Compliance and Strong Compliance send NO score — the server stores the full max', () async {
      // The card hands the provider score: null for both (see checkpoint_autosave_test), and a null never goes on the wire.
      for (final finding in ['Compliance', 'Strong Compliance']) {
        expect(await provider.scoreCheckpoint(auditId: 'a1', nodeId: 'n1', findingType: finding, remark: 'ok', locationId: 'l1'), isNull);
        final body = lastPatchBody('n1');
        expect(body['findingType'], finding);
        expect(body.containsKey('score'), isFalse, reason: finding);
        expect(body['locationId'], 'l1');
      }
    });

    test('NC sends score 0, and OFI sends the whole number that was picked', () async {
      await provider.scoreCheckpoint(auditId: 'a1', nodeId: 'n1', findingType: 'NC', score: 0, remark: 'no guard');
      expect(lastPatchBody('n1')['score'], 0);
      await provider.scoreCheckpoint(auditId: 'a1', nodeId: 'n1', findingType: 'OFI', score: 7, remark: 'partly');
      expect(lastPatchBody('n1')['score'], 7);
    });

    test('marking Not Applicable sends { notApplicable: true } (and the place), making it applicable again sends false', () async {
      expect(await provider.setCheckpointNotApplicable(auditId: 'a1', nodeId: 'n1', notApplicable: true, locationId: 'l1'), isNull);
      expect(lastPatchBody('n1'), {'notApplicable': true, 'locationId': 'l1'});

      expect(await provider.setCheckpointNotApplicable(auditId: 'a1', nodeId: 'n1', notApplicable: false), isNull);
      expect(lastPatchBody('n1'), {'notApplicable': false}, reason: 'no place on a shared checklist');
      // Both refresh the audit afterwards, like any save.
      expect(adapter.where('GET', ApiConstants.auditById('a1')), hasLength(2));
    });

    test('a refusal carries the server\'s own sentence (an NC that already has a response), a server fault a plain one', () async {
      const message = 'NC-12 raised on this checkpoint already has a response on record (Response Submitted), so it can\'t be marked Not Applicable.';
      adapter.handler = (o) async => json(409, {'isOk': false, 'message': message});
      expect(await provider.setCheckpointNotApplicable(auditId: 'a1', nodeId: 'n1', notApplicable: true), message);

      adapter.handler = (o) async => json(500, {'isOk': false, 'message': 'Cast to ObjectId failed'});
      expect(await provider.setCheckpointNotApplicable(auditId: 'a1', nodeId: 'n1', notApplicable: true), 'The server had a problem. Please try again.');
    });

    test('a whole-audit Submit refused for every checkpoint being N/A shows the server\'s message', () async {
      adapter.handler = (o) async => json(400, {'isOk': false, 'message': allNotApplicableText});
      expect(await provider.completeAudit('a1'), allNotApplicableText);
      expect(await provider.mobileSubmitAudit('a1'), allNotApplicableText);
    });
  });

  group('what Final Submit needs from a checkpoint — a finding, an OFI\'s score, and a remark (a Not Applicable one needs none)', () {
    ParameterNode n(String? finding, {num? score, String? remark}) => ParameterNode.fromJson(leaf('x', finding: finding, score: score, remark: remark));
    const full = {'scoredCount': 2, 'leafCount': 2, 'notApplicableCount': 0, 'isFullyScored': true};

    test('no finding yet: unscored', () => expect(n(null).submitGap, SubmitGap.unscored));

    test('Strong Compliance, Compliance and NC carry their own score, so they only need the remark', () {
      for (final f in ['Strong Compliance', 'Compliance']) {
        expect(n(f, score: 10).submitGap, SubmitGap.remark, reason: f);
        expect(n(f, score: 10, remark: '   ').submitGap, SubmitGap.remark, reason: 'spaces are no remark');
        expect(n(f, score: 10, remark: 'Checked').submitGap, isNull, reason: f);
      }
      expect(n('NC', score: 0).submitGap, SubmitGap.remark);
      expect(n('NC', score: 0, remark: 'Guard missing').submitGap, isNull);
    });

    test('an OFI needs its picked score first — a picked 0 counts — and then the remark', () {
      expect(n('OFI').submitGap, SubmitGap.score);
      expect(n('OFI', remark: 'Label it').submitGap, SubmitGap.score, reason: 'a remark does not stand in for the score');
      expect(n('OFI', score: 0).submitGap, SubmitGap.remark);
      expect(n('OFI', score: 0, remark: 'Label it').submitGap, isNull);
      expect(n('OFI', score: 7, remark: 'Label it').submitGap, isNull);
    });

    test('Not Applicable needs neither a score nor a remark; a group is not a checkpoint', () {
      expect(n('Not Applicable').submitGap, isNull);
      expect(ParameterNode.fromJson(groupNode('g', 'Group', [leaf('a')])).submitGap, isNull);
    });

    test('an audit is ready only when every checkpoint is — and it is not while every one is Not Applicable', () {
      final ready = audit([leaf('a', finding: 'Compliance', score: 10, remark: 'ok'), na('b')], scoreResult: full);
      expect(ready.readyForFinalSubmit, isTrue);
      expect((ready.missingRemarkTotal, ready.missingScoreTotal), (0, 0));

      final noRemark = audit([leaf('a', finding: 'Compliance', score: 10, remark: 'ok'), leaf('b', finding: 'Compliance', score: 10)], scoreResult: full);
      expect(noRemark.readyForFinalSubmit, isFalse);
      expect((noRemark.missingRemarkTotal, noRemark.missingScoreTotal), (1, 0));

      final noScore = audit([leaf('a', finding: 'Compliance', score: 10, remark: 'ok'), leaf('b', finding: 'OFI', remark: 'ok')], scoreResult: full);
      expect(noScore.readyForFinalSubmit, isFalse);
      expect((noScore.missingRemarkTotal, noScore.missingScoreTotal), (0, 1));

      final unscored = audit([leaf('a', finding: 'Compliance', score: 10, remark: 'ok'), leaf('b')], scoreResult: {...full, 'scoredCount': 1, 'isFullyScored': false});
      expect(unscored.readyForFinalSubmit, isFalse);

      final allNa = audit([na('a'), na('b')], scoreResult: {...full, 'notApplicableCount': 2});
      expect(allNa.readyForFinalSubmit, isFalse);
    });

    test('it looks inside nested groups and every place\'s and department\'s checklist', () {
      final a = audit(
        [
          groupNode('g', 'Group', [leaf('a', finding: 'Compliance', score: 10, remark: 'ok'), leaf('b', finding: 'OFI', score: 2)]),
        ],
        departmentTrees: [
          {
            'departmentId': 'd1',
            'parameters': [leaf('y', finding: 'Strong Compliance', score: 10)],
          },
        ],
        scoreResult: {'scoredCount': 3, 'leafCount': 3, 'notApplicableCount': 0, 'isFullyScored': true},
      );
      expect((a.missingRemarkTotal, a.missingScoreTotal), (2, 0));
      expect(a.readyForFinalSubmit, isFalse);
    });
  });

  group('the audit screen', () {
    late AuthProvider auth;
    late AuditsProvider audits;
    late Map<String, dynamic> detail;

    setUp(() {
      auth = AuthProvider()..user = UserModel.fromJson({'_id': 'u1', 'roleType': 'Employee', 'employeeName': 'Asha R'});
      audits = AuditsProvider()..setSelfEmployeeId('u1');
      adapter.handler = (o) async {
        if (o.method == 'GET' && o.path == '/audits/a1') return json(200, {'isOk': true, 'data': detail});
        return json(200, {'isOk': true, 'data': []});
      };
    });

    tearDown(() => auth.dispose());

    Map<String, dynamic> auditJson({
      required List<Map<String, dynamic>> parameters,
      required Map<String, dynamic> score,
      String status = 'Completed',
      String structure = 'same',
      List<Map<String, dynamic>>? locationParameters,
    }) => {
      '_id': 'a1',
      'title': 'Line 1 GMP',
      'status': status,
      'displayStatus': status == 'Completed' ? 'Closed' : 'In Progress',
      'auditorIds': [
        {'_id': 'u1', 'employeeName': 'Asha R'},
      ],
      // Set, so the "select a representative" gate does not stand between the auditor and the checklist.
      'auditeeIds': [
        {'_id': 'e2', 'employeeName': 'Ravi K'},
      ],
      'scheduledDate': '2026-09-04T00:00:00.000Z',
      'scoringSystem': 'normal',
      'structureMode': structure,
      'maxScore': 10,
      'locationIds': [
        {'_id': 'L1', 'name': 'Zone 1'},
      ],
      'locationParameters': locationParameters ?? <Map<String, dynamic>>[],
      'parameters': parameters,
      'scoreResult': score,
    };

    Future<void> open(WidgetTester tester, {bool dark = false}) async {
      tester.view.physicalSize = const Size(360, 3000);
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
          child: MaterialApp(theme: dark ? AppTheme.dark() : AppTheme.light(), home: const AuditDetailScreen(auditId: 'a1')),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Housekeeping [Compliance 10, N/A, N/A], Fire exit Strong 10, and a group that is ALL Not Applicable: 4 of them in all.
    // The server's numbers: 20 of 20 = 100%, 6 handled of 6, 4 of them Not Applicable.
    List<Map<String, dynamic>> finishedTree() => [
      groupNode('g1', 'Housekeeping', [
        leaf('c1', finding: 'Compliance', score: 10, remark: 'In order', name: 'Floor is clean'),
        na('n1', name: 'Overhead crane checked'),
        na('n2', name: 'Hoist chains oiled'),
      ]),
      leaf('c2', finding: 'Strong Compliance', score: 10, remark: 'Clear', name: 'Fire exit is clear'),
      groupNode('g2', 'Spray booth', [na('n3', name: 'Booth filters changed'), na('n4', name: 'Solvent store locked')]),
    ];

    for (final dark in [false, true]) {
      testWidgets('a finished audit\'s report shows every N/A checkpoint grey, the Score line counts it as done but not as scored (${dark ? 'dark' : 'light'}, 360 wide)', (tester) async {
        detail = auditJson(
          parameters: finishedTree(),
          score: {'achieved': 20, 'maxPossible': 20, 'percentage': 100, 'scoredCount': 6, 'leafCount': 6, 'notApplicableCount': 4, 'isFullyScored': true},
        );
        await open(tester, dark: dark);

        for (final name in ['Overhead crane checked', 'Hoist chains oiled', 'Booth filters changed', 'Solvent store locked']) {
          expect(find.text(name), findsOneWidget, reason: name);
        }
        expect(find.text('N/A'), findsNWidgets(4), reason: 'the short pill on each');
        expect(find.text('Not applicable — left out of the score.'), findsNWidgets(4));
        expect(find.text('Score: 100% (6/6 · 4 N/A)'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'no overflow at 360 wide');
      });
    }

    testWidgets('when every checkpoint is N/A the Score line has no percentage — never 0% — and Final Submit refuses with the server\'s sentence', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [na('n1', name: 'Overhead crane checked'), na('n2', name: 'Hoist chains oiled')],
        score: {'achieved': 0, 'maxPossible': 0, 'percentage': null, 'scoredCount': 2, 'leafCount': 2, 'notApplicableCount': 2, 'isFullyScored': true},
      );
      await open(tester);
      expect(find.text('Score: — (2/2 · 2 N/A)'), findsOneWidget);
      expect(find.textContaining('0%'), findsNothing);

      await tester.ensureVisible(find.text('Final Submit'));
      await tester.tap(find.text('Final Submit'));
      await tester.pump();
      expect(find.text(allNotApplicableText), findsOneWidget);
      expect(find.text('Final Submit?'), findsNothing, reason: 'the confirmation never opens');
      expect(adapter.where('PATCH', ApiConstants.completeAudit('a1')), isEmpty);
    });

    testWidgets('an audit with a graded checkpoint beside the N/A ones can still be Final Submitted: the confirmation opens', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [leaf('c1', finding: 'Strong Compliance', score: 10, remark: 'Checked on site', name: 'Fire exit is clear'), na('n1', name: 'Overhead crane checked')],
        score: {'achieved': 10, 'maxPossible': 10, 'percentage': 100, 'scoredCount': 2, 'leafCount': 2, 'notApplicableCount': 1, 'isFullyScored': true},
      );
      await open(tester);
      await tester.ensureVisible(find.text('Final Submit'));
      await tester.tap(find.text('Final Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Final Submit?'), findsOneWidget);
    });

    testWidgets('a checkpoint that is still blank is where Final Submit points — an N/A one never holds the audit back', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [na('n1', name: 'Overhead crane checked'), leaf('b1', name: 'Guards are fitted')],
        score: {'achieved': 0, 'maxPossible': 0, 'percentage': null, 'scoredCount': 1, 'leafCount': 2, 'notApplicableCount': 1, 'isFullyScored': false},
      );
      await open(tester);
      await tester.ensureVisible(find.text('Final Submit'));
      await tester.tap(find.text('Final Submit'));
      await tester.pump();
      expect(find.text('Score this checkpoint before submitting.'), findsOneWidget);
      expect(find.text(allNotApplicableText), findsNothing);
    });

    testWidgets('tapping Not applicable on a checkpoint of a per-location audit sends { notApplicable: true } for that place', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        structure: 'per-location',
        parameters: const [],
        locationParameters: [
          {
            'locationId': 'L1',
            'parameters': [leaf('b1', name: 'Guards are fitted')],
          },
        ],
        score: {'achieved': 0, 'maxPossible': 0, 'percentage': null, 'scoredCount': 0, 'leafCount': 1, 'notApplicableCount': 0, 'isFullyScored': false},
      );
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('na-button')));
      await tester.pumpAndSettle();
      expect(find.text('Mark as not applicable?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('na-confirm')));
      await tester.pumpAndSettle();

      final sent = adapter.where('PATCH', ApiConstants.scoreParameter('a1', 'b1')).single;
      expect(Map<String, dynamic>.from(sent.data as Map), {'notApplicable': true, 'locationId': 'L1'});
      expect(find.byKey(const ValueKey('na-panel')), findsOneWidget);
    });

    testWidgets('Final Submit with a checkpoint that has no remark does not open the confirmation — it points at that checkpoint and says what it needs', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [leaf('c1', finding: 'Compliance', score: 10, remark: 'Checked', name: 'Fire exit is clear'), leaf('c2', finding: 'Compliance', score: 10, name: 'Guards are fitted')],
        score: {'achieved': 20, 'maxPossible': 20, 'percentage': 100, 'scoredCount': 2, 'leafCount': 2, 'notApplicableCount': 0, 'isFullyScored': true},
      );
      await open(tester);
      await tester.ensureVisible(find.text('Final Submit'));
      await tester.tap(find.text('Final Submit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Add a remark to this checkpoint before submitting.'), findsOneWidget);
      expect(find.text('Final Submit?'), findsNothing, reason: 'the confirmation never opens');
      expect(adapter.where('PATCH', ApiConstants.completeAudit('a1')), isEmpty);
    });

    testWidgets('an OFI whose score was never picked is where Final Submit points, asking for the score', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [leaf('c1', finding: 'Compliance', score: 10, remark: 'Checked', name: 'Fire exit is clear'), leaf('o1', finding: 'OFI', remark: 'Label it', name: 'Guards are fitted')],
        score: {'achieved': 10, 'maxPossible': 10, 'percentage': 100, 'scoredCount': 2, 'leafCount': 2, 'notApplicableCount': 0, 'isFullyScored': true},
      );
      await open(tester);
      await tester.ensureVisible(find.text('Final Submit'));
      await tester.tap(find.text('Final Submit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Pick a score for this OFI checkpoint before submitting.'), findsOneWidget);
      expect(find.text('Final Submit?'), findsNothing);
    });

    testWidgets('every applicable checkpoint with its score and remark, a Not Applicable one with neither: the confirmation opens', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [
          leaf('c1', finding: 'Strong Compliance', score: 10, remark: 'Clear', name: 'Fire exit is clear'),
          leaf('o1', finding: 'OFI', score: 4, remark: 'Label it', name: 'Guards are fitted'),
          na('n1', name: 'Overhead crane checked'),
        ],
        score: {'achieved': 14, 'maxPossible': 20, 'percentage': 70, 'scoredCount': 3, 'leafCount': 3, 'notApplicableCount': 1, 'isFullyScored': true},
      );
      await open(tester);
      await tester.ensureVisible(find.text('Final Submit'));
      await tester.tap(find.text('Final Submit'));
      await tester.pumpAndSettle();
      expect(find.text('Final Submit?'), findsOneWidget);
    });

    testWidgets('a checkpoint with a finding but no remark says so under the remark box — one that has its remark, or is Not Applicable, says nothing', (tester) async {
      detail = auditJson(
        status: 'In Progress',
        parameters: [
          leaf('c1', finding: 'Compliance', score: 10, remark: 'Checked', name: 'Fire exit is clear'),
          leaf('c2', finding: 'Compliance', score: 10, name: 'Guards are fitted'),
          na('n1', name: 'Overhead crane checked'),
          leaf('b1', name: 'Alarm panel'),
        ],
        score: {'achieved': 20, 'maxPossible': 20, 'percentage': 100, 'scoredCount': 3, 'leafCount': 4, 'notApplicableCount': 1, 'isFullyScored': false},
      );
      await open(tester);
      expect(find.text('Required to submit the audit'), findsOneWidget, reason: 'only the scored checkpoint with no remark');
      expect(tester.takeException(), isNull);
    });
  });
}
