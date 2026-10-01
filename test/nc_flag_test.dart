import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/employee_option.dart';
import 'package:internal_audit_app/models/nc_model.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:internal_audit_app/screens/audits/nc_details_sheet.dart';

/// An NC's "Flag" is the wire/DB field `severity`, renamed for the user.
/// It has exactly two values — Major and Minor. "Observation" is legacy:
/// an old NC that still carries it (or has no severity at all) must be READ
/// AS Minor everywhere the phone displays it or seeds a picker from it, and
/// never offered as a choice. Both shapes are silent failures if missed — a
/// stray "Observation" chip just looks wrong, and a legacy value handed to
/// a dropdown that has no item for it throws — hence a test per path.
void main() {
  group('flagOf', () {
    test('Major stays Major', () {
      expect(flagOf('Major'), 'Major');
    });

    test('Minor stays Minor', () {
      expect(flagOf('Minor'), 'Minor');
    });

    test('legacy Observation reads as Minor', () {
      expect(flagOf('Observation'), 'Minor');
    });

    test('missing / empty / unknown values read as Minor', () {
      expect(flagOf(null), 'Minor');
      expect(flagOf(''), 'Minor');
      expect(flagOf('Critical'), 'Minor');
      expect(flagOf('major'), 'Minor'); // the server enum is exact-case
    });

    test('the picker set is exactly Major and Minor', () {
      expect(kNcFlags, ['Major', 'Minor']);
      expect(kNcFlags, isNot(contains('Observation')));
    });
  });

  group('NcModel.fromJson severity', () {
    Map<String, dynamic> ncJson({Object? severity = 'unset'}) => {
          '_id': 'nc1',
          'ncId': 'NC-001',
          'auditId': 'a1',
          'title': 'Guard missing',
          'status': 'Raised',
          if (severity != 'unset') 'severity': severity,
        };

    test('keeps Major and Minor', () {
      expect(NcModel.fromJson(ncJson(severity: 'Major')).severity, 'Major');
      expect(NcModel.fromJson(ncJson(severity: 'Minor')).severity, 'Minor');
    });

    test('a legacy Observation NC comes through as Minor', () {
      expect(NcModel.fromJson(ncJson(severity: 'Observation')).severity, 'Minor');
    });

    test('an NC with no severity key (or a null one) comes through as Minor', () {
      expect(NcModel.fromJson(ncJson()).severity, 'Minor');
      expect(NcModel.fromJson(ncJson(severity: null)).severity, 'Minor');
    });
  });

  // Opens [open] from a button, the way every one of these sheets is reached
  // in the app, and settles on the open sheet.
  Future<void> pumpAndOpen(WidgetTester tester, void Function(BuildContext) open) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(onPressed: () => open(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // Opens the Flag dropdown and asserts what it offers.
  Future<void> expectFlagMenuIsMajorMinorOnly(WidgetTester tester) async {
    final dropdown = find.ancestor(of: find.text('Flag'), matching: find.byType(DropdownButtonFormField<String>));
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    expect(find.text('Major'), findsWidgets);
    expect(find.text('Minor'), findsWidgets);
    expect(find.text('Observation'), findsNothing);
  }

  // Someone at the audited location other than the acting auditor — the
  // pool the NC pickers are always fed with (the auditor is never in it, and
  // the picker is never skipped: an NC is always raised against a person).
  const ravi = EmployeeOption(id: 'emp2', name: 'Ravi K');

  group('NC details sheet (raise a checkpoint NC / edit an NC)', () {
    testWidgets('labels the field Flag, never Severity, and offers Major/Minor only', (tester) async {
      await pumpAndOpen(tester, (context) {
        showNcDetailsSheet(context, employees: const [ravi], initialRemark: '');
      });

      expect(find.text('Flag'), findsOneWidget);
      expect(find.text('Severity'), findsNothing);
      await expectFlagMenuIsMajorMinorOnly(tester);
    });

    testWidgets('editing a legacy Observation NC opens without crashing, shows Minor, and saves Minor', (tester) async {
      NcDetailsResult? result;
      await pumpAndOpen(tester, (context) async {
        result = await showNcDetailsSheet(
          context,
          employees: const [ravi],
          initialAuditeeId: 'emp2',
          initialRemark: 'kept',
          initialSeverity: 'Observation',
          initialTargetDate: DateTime(2030, 1, 15),
          mode: NcSheetMode.edit,
        );
      });

      expect(tester.takeException(), isNull);
      expect(find.text('Observation'), findsNothing);
      expect(find.text('Minor'), findsOneWidget); // the dropdown's selected value

      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.severity, 'Minor');
    });

    testWidgets('editing a Major NC keeps Major selected', (tester) async {
      NcDetailsResult? result;
      await pumpAndOpen(tester, (context) async {
        result = await showNcDetailsSheet(
          context,
          employees: const [ravi],
          initialAuditeeId: 'emp2',
          initialRemark: '',
          initialSeverity: 'Major',
          initialTargetDate: DateTime(2030, 1, 15),
          mode: NcSheetMode.edit,
        );
      });

      expect(find.text('Major'), findsOneWidget);
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();
      expect(result!.severity, 'Major');
      expect(result!.auditeeEmployeeId, 'emp2');
    });

    testWidgets('always asks who the NC is against — the picker is there, and saving needs a pick', (tester) async {
      NcDetailsResult? result;
      await pumpAndOpen(tester, (context) async {
        result = await showNcDetailsSheet(
          context,
          employees: const [ravi],
          initialRemark: 'kept',
          initialTargetDate: DateTime(2030, 1, 15),
        );
      });

      expect(find.text('Raise NC against'), findsOneWidget);
      expect(find.textContaining('Self Audit'), findsNothing);
      expect(find.text("No one else is tagged to this audit's location."), findsNothing);

      // Nothing picked — nothing is defaulted (least of all to the auditor),
      // so Save is refused and the sheet stays open.
      await tester.ensureVisible(find.text('Save & Raise NC'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save & Raise NC'));
      await tester.pumpAndSettle();
      expect(find.text('Pick who this NC is against'), findsOneWidget);
      expect(result, isNull);
      expect(find.text('Save & Raise NC'), findsOneWidget);
    });

    testWidgets('with nobody else at the location it says so and blocks raising', (tester) async {
      await pumpAndOpen(tester, (context) {
        showNcDetailsSheet(context, employees: const [], initialRemark: '');
      });

      expect(find.text('Raise NC against'), findsOneWidget);
      expect(find.text("No one else is tagged to this audit's location."), findsOneWidget);
      final save = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Save & Raise NC'));
      expect(save.onPressed, isNull);
    });
  });

  group('Checkpoint card NC panel', () {
    // Built directly (not via fromJson, which already reads a legacy value
    // as Minor) so these exercise the card's own display path with the raw
    // stored value, the way a legacy NC would reach it from any other
    // construction site.
    NcModel ncWith(String severity) => NcModel(
          id: 'nc1',
          ncId: 'NC-001',
          auditId: 'a1',
          auditTitle: 'Line 1 GMP',
          title: 'Guard missing',
          description: '',
          status: 'Raised',
          severity: severity,
          raisedBy: const NcPersonRef(id: 'emp1', name: 'Asha R'),
          auditee: const NcPersonRef(id: 'emp2', name: 'Ravi K'),
        );

    Future<void> pumpCard(WidgetTester tester, NcModel nc) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CheckpointCard(
              node: const ParameterNode(id: 'p1', name: 'Guarding', findingType: 'NC', ncId: 'nc1'),
              serial: '1.1',
              readOnly: true,
              maxScore: 5,
              onSave: ({
                String? findingType,
                double? score,
                required String remark,
                String? auditeeEmployeeId,
                DateTime? targetDate,
                String? severity,
              }) async => null,
              onUploadPhotos: ({required photos, onProgress}) async => const UploadPhotosResult(),
              linkedNc: nc,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('shows the row as Flag with the value, never Severity', (tester) async {
      await pumpCard(tester, ncWith('Major'));

      expect(find.text('Flag'), findsOneWidget);
      expect(find.text('Major'), findsOneWidget);
      expect(find.text('Severity'), findsNothing);
    });

    testWidgets('a legacy Observation NC shows Minor', (tester) async {
      await pumpCard(tester, ncWith('Observation'));

      expect(find.text('Flag'), findsOneWidget);
      expect(find.text('Minor'), findsOneWidget);
      expect(find.text('Observation'), findsNothing);
    });

    testWidgets('an NC with an empty or unknown severity shows Minor', (tester) async {
      await pumpCard(tester, ncWith(''));
      expect(find.text('Minor'), findsOneWidget);

      await pumpCard(tester, ncWith('Critical'));
      expect(find.text('Minor'), findsOneWidget);
      expect(find.text('Critical'), findsNothing);
    });
  });
}
