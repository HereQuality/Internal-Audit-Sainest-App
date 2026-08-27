import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/widgets/status_filter_chip_row.dart';

// Throwaway visual-verification harness — renders the fixed filter chip
// row through the app's real AppTheme and saves a PNG for manual
// inspection. Not a real regression test (no assertions); delete after use.
Future<void> _capture(
  WidgetTester tester,
  String filename, {
  required Widget child,
  Size size = const Size(430, 60),
}) async {
  await tester.binding.setSurfaceSize(size);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        backgroundColor: const Color(0xFFF6F7FB),
        body: RepaintBoundary(key: const Key('capture'), child: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final boundary = tester
      .element(find.byKey(const Key('capture')))
      .findRenderObject() as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 3.0);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File(
    '/tmp/claude-1000/-home-mann-HQEPL-Internal-Audit/3cffb75a-0250-4aa6-b522-6bbe3c5a86e4/scratchpad/$filename',
  );
  await file.writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('audit status filter row', (tester) async {
    await _capture(
      tester,
      'chip_audits.png',
      child: StatusFilterChipRow(
        options: const ['All', 'Not Started', 'In Progress', 'Completed', 'Draft'],
        selected: 'All',
        onSelected: (_) {},
      ),
    );
  });

  testWidgets('nc status filter row', (tester) async {
    await _capture(
      tester,
      'chip_nc.png',
      child: StatusFilterChipRow(
        options: const ['All', 'In Progress', 'Pending Approval', 'Overdue', 'On Time'],
        selected: 'All',
        onSelected: (_) {},
      ),
    );
  });
}
