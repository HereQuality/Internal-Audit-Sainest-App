import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/models/audit_detail_model.dart';
import 'package:internal_audit_app/models/upload_phase.dart';
import 'package:internal_audit_app/screens/audits/checkpoint_card.dart';
import 'package:internal_audit_app/utils/bold_marks.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:internal_audit_app/widgets/bold_text.dart';

void main() {
  test('stripBold removes the marks and nothing else', () {
    expect(stripBold('a **b** c'), 'a b c');
    expect(stripBold('**a** and **b**'), 'a and b');
    expect(stripBold('plain'), 'plain');
    expect(stripBold(null), '');
    expect(stripBold('a ** b'), 'a ** b'); // a lone pair of stars is left as typed
    expect(stripBold('two\n**lines\nbold**'), 'two\nlines\nbold');
  });

  test('hasBold sees a real pair only', () {
    expect(hasBold('x **y** z'), isTrue);
    expect(hasBold('x ** y'), isFalse);
    expect(hasBold('****'), isFalse);
    expect(hasBold(null), isFalse);
  });

  test('boldSegments cuts the name into runs, and the runs join back to the stripped name', () {
    final segs = boldSegments('a **b** c');
    expect(segs.map((s) => s.text).toList(), ['a ', 'b', ' c']);
    expect(segs.map((s) => s.bold).toList(), [false, true, false]);
    const t = 'x **y** z **w**';
    expect(boldSegments(t).map((s) => s.text).join(), stripBold(t));
    expect(boldSegments(''), isEmpty);
  });

  testWidgets('BoldText draws a bold run heavier than the rest, and a plain name as a plain Text', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Column(children: [BoldText('Is the **latest approved** WI'), BoldText('no marks here')])),
    ));
    final rich = tester.widgetList<RichText>(find.byType(RichText)).where((r) => r.text.toPlainText().contains('latest approved')).first;
    final spans = <TextSpan>[];
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.text != null) spans.add(s);
      return true;
    });
    expect(spans.map((s) => s.text).toList(), ['Is the ', 'latest approved', ' WI']);
    expect(spans[1].style?.fontWeight, FontWeight.w800);
    expect(spans[0].style?.fontWeight, isNull);
    expect(find.text('no marks here'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
  });

  testWidgets('the real checkpoint card draws a name\'s bold stretches bold, keeps its line breaks, and shows no asterisks', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CheckpointCard(
            node: const ParameterNode(id: 'p1', name: 'Explain the process **parameters**, defects\n\nref(docs)\n**test(Plan)**'),
            serial: '1.1',
            readOnly: false,
            maxScore: 3,
            draftKey: 'draft:p1',
            onSave: ({findingType, score, required remark, auditeeEmployeeId, targetDate, severity}) async => null,
            onUploadPhotos: ({required photos, onProgress}) async => UploadPhotosResult(error: null),
            onSyncStateChanged: (_) {},
          ),
        ),
      ),
    ));
    expect(find.textContaining('**'), findsNothing);
    final rich = tester.widgetList<RichText>(find.byType(RichText)).firstWhere((r) => r.text.toPlainText().contains('parameters'));
    final bolds = <String>[];
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.text != null && s.style?.fontWeight == FontWeight.w800) bolds.add(s.text!);
      return true;
    });
    expect(bolds, ['parameters', 'test(Plan)']);
    expect(rich.text.toPlainText(), 'Explain the process parameters, defects\n\nref(docs)\ntest(Plan)'); // line breaks kept
  });
}
