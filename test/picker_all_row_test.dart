import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/widgets/picker_sheet.dart';

// The multi picker's "All" row: when nobody is picked under "no pick = all" every
// checkbox is ticked, ticking everyone by hand equals the All row, and an empty
// selection cannot be confirmed (an empty list would read as All).
Future<void> _open(
  WidgetTester tester, {
  bool initiallyAll = false,
  List<String> selected = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                await showMultiPickerSheet<String>(
                  context,
                  title: 'Members',
                  allLabel: 'All Members',
                  initiallyAll: initiallyAll,
                  selected: selected,
                  confirmLabel: 'Apply members',
                  items: const [
                    PickerItem(value: 'a', label: 'Asha'),
                    PickerItem(value: 'b', label: 'Ravi'),
                    PickerItem(value: 'c', label: 'Mann'),
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

int _ticked(WidgetTester tester) => tester
    .widgetList<Checkbox>(find.byType(Checkbox))
    .where((c) => c.value == true)
    .length;

void main() {
  testWidgets('with initiallyAll every row and the All row are ticked', (tester) async {
    await _open(tester, initiallyAll: true);
    expect(find.text('All Members'), findsOneWidget);
    // All row + 3 people.
    expect(_ticked(tester), 4);
    expect(find.text('Apply members (All)'), findsOneWidget);
  });

  testWidgets('a subset leaves the All row unticked; ticking the last one ticks it', (tester) async {
    await _open(tester, selected: const ['a', 'b']);
    expect(_ticked(tester), 2);
    expect(find.text('Apply members (2)'), findsOneWidget);
    await tester.tap(find.text('Mann'));
    await tester.pump();
    expect(_ticked(tester), 4, reason: 'everyone ticked = the All row is ticked too');
    expect(find.text('Apply members (All)'), findsOneWidget);
  });

  testWidgets('the All row unticks everything and Confirm then needs a pick', (tester) async {
    await _open(tester, initiallyAll: true);
    await tester.tap(find.text('All Members'));
    await tester.pump();
    expect(_ticked(tester), 0);
    expect(find.text('Select at least 1'), findsOneWidget);
    await tester.tap(find.text('All Members'));
    await tester.pump();
    expect(_ticked(tester), 4);
  });

  testWidgets('a picker without allLabel has no All row', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => showMultiPickerSheet<String>(
                context,
                title: 'Team',
                items: const [PickerItem(value: 'a', label: 'QA')],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('All Members'), findsNothing);
    expect(_ticked(tester), 0);
  });
}
