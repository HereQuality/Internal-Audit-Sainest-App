import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/utils/final_report_download.dart';
import 'package:internal_audit_app/utils/final_report_excel.dart';
import 'package:internal_audit_app/utils/final_report_export_service.dart';
import 'package:internal_audit_app/widgets/final_report_excel_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// The Final Report's "Download Excel" bar: one action on each tab, a progress state
/// ("Preparing Excel… 120 of 340 reports") with Cancel while it pages through, no second
/// download while one is running, and an error snackbar — not a broken screen — when it
/// fails. The service behind it (paging, retry, file, share) is tested in
/// final_report_download_test.dart; here it is a fake the test completes by hand.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    // The filter option lists the bar loads before it starts: empty and instant.
    DioClient.instance.dio.httpClientAdapter = FakeAdapter()..handler = (o) async => json(200, {'isOk': true, 'data': []});
  });

  Future<_Harness> pump(
    WidgetTester tester, {
    FinalReportTab tab = FinalReportTab.audits,
    double width = 390,
    ThemeData? theme,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = _Harness(tab);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.audits),
          ChangeNotifierProvider.value(value: h.ncs),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
          ChangeNotifierProvider.value(value: h.options),
        ],
        child: MaterialApp(
          theme: theme ?? AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: ValueListenableBuilder<FinalReportTab>(
              valueListenable: h.tab,
              builder: (context, tab, _) => Align(
                alignment: Alignment.topCenter,
                child: FinalReportExcelBar(tab: tab, service: h.service),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The option lists the bar reads before it starts are loaded for real, ahead of the tap (the fake
    // server answers at once), so a tap goes straight to the export.
    await tester.runAsync(() => h.options.load());
    return h;
  }

  final download = find.text('Download Excel');
  final downloadAll = find.text('Download All');
  final excelButton = find.widgetWithText(OutlinedButton, 'Download Excel');
  final allButton = find.widgetWithText(OutlinedButton, 'Download All');
  final cancel = find.byKey(const ValueKey('excel-cancel'));
  final progressText = find.byKey(const ValueKey('excel-progress-text'));
  String shown(WidgetTester tester) => tester.widget<Text>(progressText).data!;

  group('the action', () {
    for (final tab in FinalReportTab.values) {
      testWidgets('is on the ${finalReportTabLabel(tab)} tab, 44 px tall, with what it will export', (tester) async {
        await pump(tester, tab: tab);
        expect(download, findsOneWidget);
        expect(downloadAll, findsOneWidget);
        expect(find.byIcon(Icons.table_chart_outlined), findsOneWidget);
        expect(find.byIcon(Icons.layers_outlined), findsOneWidget);
        expect(tester.getSize(excelButton).height, greaterThanOrEqualTo(44));
        expect(tester.getSize(allButton).height, greaterThanOrEqualTo(44));
        expect(
          find.text(switch (tab) {
            FinalReportTab.audits => 'Every report your filters match',
            FinalReportTab.ncs => 'Every NC your filters match',
            FinalReportTab.repeats => 'Every repeated checkpoint your filters match',
          }),
          findsOneWidget,
        );
      });
    }

    for (final dark in [false, true]) {
      for (final width in [320.0, 360.0]) {
        for (final scale in [1.0, 1.6]) {
          testWidgets('both buttons fit ${width.round()} px wide (${dark ? 'dark' : 'light'} theme, text x$scale), idle and while busy, on every tab', (tester) async {
            final h = await pump(tester, width: width, theme: dark ? AppTheme.dark() : AppTheme.light(), textScale: scale);
            for (final tab in FinalReportTab.values) {
              h.tab.value = tab;
              await tester.pump();
              expect(download, findsOneWidget);
              expect(downloadAll, findsOneWidget);
              expect(tester.takeException(), isNull);
              // Each stays inside the screen and is at least 44 px tall, whether side by side or stacked.
              for (final button in [excelButton, allButton]) {
                final r = tester.getRect(button);
                expect(r.left, greaterThanOrEqualTo(0));
                expect(r.right, lessThanOrEqualTo(width));
                expect(r.height, greaterThanOrEqualTo(44));
              }
              expect(tester.getRect(excelButton).overlaps(tester.getRect(allButton)), isFalse);
            }
            await tester.tap(download);
            await tester.pump();
            await tester.pump();
            h.service.onProgress!(const ExportProgress(noun: 'repeated checkpoints', done: 1200, total: 3400));
            await tester.pump();
            expect(shown(tester), contains('Preparing Excel… 1200 of 3400 repeated checkpoints'));
            expect(tester.takeException(), isNull);
            expect(tester.getSize(cancel).height, greaterThanOrEqualTo(44));
            for (final tab in FinalReportTab.values) {
              h.tab.value = tab;
              await tester.pump();
              expect(tester.takeException(), isNull);
            }
            h.service.pending!.completeError(const ExportCancelled());
            await tester.pump();
            await tester.pump();

            // Download All while busy: its own, longer progress line fits too.
            await tester.tap(downloadAll);
            await tester.pump();
            await tester.pump();
            h.service.onProgress!(const ExportProgress(noun: 'NCs in those checkpoints', done: 1200, total: 3400, part: 'Repeated NCs'));
            await tester.pump();
            expect(shown(tester), 'Repeated NCs — 1200 of 3400 NCs in those checkpoints');
            expect(tester.takeException(), isNull);
            h.service.pendingAll!.completeError(const ExportCancelled());
            await tester.pump();
            await tester.pump();
          });
        }
      }
    }

    testWidgets('side by side when both labels fit in half the width', (tester) async {
      // (The test font is the wide "Ahem": a label is about 2.5x as wide as in the app's real font, so
      // the width that is "roomy" here is wider than a phone. On a 360-390 px phone the real labels fit.)
      await pump(tester, width: 700);
      final excel = tester.getRect(excelButton);
      final all = tester.getRect(allButton);
      expect(excel.top, all.top);
      expect(excel.right, lessThan(all.left));
      expect(excel.width, closeTo(all.width, 0.5));
    });

    testWidgets('one above the other on a narrow one (320 px), each taking the width', (tester) async {
      await pump(tester, width: 320);
      final excel = tester.getRect(excelButton);
      final all = tester.getRect(allButton);
      expect(excel.left, all.left);
      expect(excel.bottom, lessThan(all.top));
      expect(excel.width, all.width);
    });
  });

  group('downloading', () {
    testWidgets('shows where it is, with Cancel, and no Download button — a second tap cannot start a second download', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      // At once: the bar is busy, even before the first answer.
      expect(download, findsNothing);
      expect(shown(tester), 'Preparing Excel…');
      expect(cancel, findsOneWidget);

      h.service.onProgress!(const ExportProgress(noun: 'reports', done: 120, total: 340));
      await tester.pump();
      expect(shown(tester), 'Preparing Excel… 120 of 340 reports');
      final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
      expect(bar.value, closeTo(120 / 340, 1e-6));

      h.service.onProgress!(const ExportProgress.building());
      await tester.pump();
      expect(shown(tester), 'Building the Excel file…');
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, isNull);

      expect(h.service.calls, hasLength(1));
      h.service.pending!.complete(const FinalReportExportResult(fileName: 'f.xlsx', rowCount: 340));
      await tester.pump();
      await tester.pump();
      expect(download, findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('exports the tab showing, with the filters in force at the tap', (tester) async {
      final h = await pump(tester, tab: FinalReportTab.ncs);
      h.ncs.setFilterState(isTeam: true, flags: ['Major']);
      h.ncs.ncReportSearch = 'guard';
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      final r = h.service.calls.single;
      expect(r.tab, FinalReportTab.ncs);
      expect(r.listQuery['severity'], 'Major');
      expect(r.listQuery['search'], 'guard');
      expect(r.statsQuery!['omitIds'], '1');
      // Changing the filters while it works does not change the file being made.
      h.ncs.setFilterState(flags: ['Minor']);
      expect(r.listQuery['severity'], 'Major');
      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
    });

    testWidgets('hands the share sheet the Download button\'s place on screen (where an iPad anchors its popover)', (tester) async {
      final h = await pump(tester);
      final button = tester.getRect(excelButton);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      final origin = h.service.origin!;
      expect(origin.width, greaterThan(40));
      expect(origin.height, greaterThanOrEqualTo(44));
      expect(origin, button);
      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
    });

    testWidgets('says which tab is being made if the person moves to another meanwhile — and still allows no second download', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      h.service.onProgress!(const ExportProgress(noun: 'reports', done: 10, total: 20));
      await tester.pump();
      h.tab.value = FinalReportTab.ncs;
      await tester.pump();
      expect(shown(tester), 'Audits: Preparing Excel… 10 of 20 reports');
      expect(download, findsNothing);
      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
      expect(download, findsOneWidget);
    });
  });

  group('Download All', () {
    for (final tab in FinalReportTab.values) {
      testWidgets('from the ${finalReportTabLabel(tab)} tab it exports the three tabs at once, each under its own tab\'s filters at the tap', (tester) async {
        final h = await pump(tester, tab: tab);
        h.audits
          ..setFilterState(isTeam: true)
          ..reportsStatus = 'Overdue'
          ..reportsSearch = 'press';
        h.ncs
          ..setFilterState(isTeam: true, flags: ['Major'])
          ..ncReportSearch = 'guard'
          ..ncReportTileKeys = {'overdue'}
          ..repeatsMinCount = 3
          ..repeatsSearch = 'floor';
        await tester.tap(downloadAll);
        await tester.pump();
        await tester.pump();
        expect(h.service.calls, isEmpty, reason: 'it is not the single-tab download');
        final r = h.service.allCalls.single;
        expect(r.audits.listQuery['status'], 'Overdue');
        expect(r.audits.listQuery['search'], 'press');
        expect(r.ncs.listQuery['bucket'], 'overdue');
        expect(r.ncs.listQuery['severity'], 'Major');
        expect(r.ncs.listQuery['search'], 'guard');
        expect(r.repeats.listQuery['minCount'], 3);
        expect(r.repeats.listQuery['search'], 'floor');
        // Whatever happens to the filters now does not reach the file being made.
        h.audits.reportsStatus = 'Completed';
        h.ncs.repeatsSearch = 'other';
        expect(r.audits.listQuery['status'], 'Overdue');
        expect(r.repeats.listQuery['search'], 'floor');
        h.service.pendingAll!.completeError(const ExportCancelled());
        await tester.pump();
        await tester.pump();
      });
    }

    testWidgets('names the part it is reading, with Cancel, and neither Download button — no second download of either kind', (tester) async {
      final h = await pump(tester, tab: FinalReportTab.ncs);
      await tester.tap(downloadAll);
      await tester.pump();
      await tester.pump();
      expect(download, findsNothing);
      expect(downloadAll, findsNothing);
      expect(cancel, findsOneWidget);
      expect(shown(tester), 'Audits — preparing…');

      h.service.onProgress!(const ExportProgress(noun: 'reports', done: 120, total: 340, part: 'Audits'));
      await tester.pump();
      expect(shown(tester), 'Audits — 120 of 340 reports');
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(120 / 340, 1e-6));
      h.service.onProgress!(const ExportProgress(noun: 'NCs', done: 20, total: 40, part: 'NCs'));
      await tester.pump();
      // Whichever tab is showing, the line names the part — never a tab-switch prefix on top of it.
      expect(shown(tester), 'NCs — 20 of 40 NCs');
      h.tab.value = FinalReportTab.audits;
      await tester.pump();
      expect(shown(tester), 'NCs — 20 of 40 NCs');
      h.service.onProgress!(const ExportProgress(noun: 'repeated checkpoints', done: 1, total: 2, part: 'Repeated NCs'));
      await tester.pump();
      expect(shown(tester), 'Repeated NCs — 1 of 2 repeated checkpoints');
      h.service.onProgress!(const ExportProgress.building());
      await tester.pump();
      expect(shown(tester), 'Building the Excel file…');

      expect(h.service.allCalls, hasLength(1));
      h.service.pendingAll!.complete(const FinalReportExportResult(fileName: 'Final-Report-All-2026-11-03.xlsx', rowCount: 9));
      await tester.pump();
      await tester.pump();
      expect(download, findsOneWidget);
      expect(downloadAll, findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('hands the share sheet the Download All button\'s place (where an iPad anchors its popover)', (tester) async {
      final h = await pump(tester);
      final button = tester.getRect(allButton);
      await tester.tap(downloadAll);
      await tester.pump();
      await tester.pump();
      expect(h.service.origin, button);
      h.service.pendingAll!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
    });

    testWidgets('Cancel works at any point; a cancel is not an error', (tester) async {
      final h = await pump(tester);
      await tester.tap(downloadAll);
      await tester.pump();
      await tester.pump();
      h.service.onProgress!(const ExportProgress(noun: 'NCs', done: 100, total: 300, part: 'NCs'));
      await tester.pump();
      await tester.tap(cancel);
      await tester.pump();
      expect(h.service.token!.isCancelled, isTrue);
      expect(shown(tester), 'Cancelling…');
      h.service.pendingAll!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
      expect(download, findsOneWidget);
      expect(downloadAll, findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('if any part fails the whole download fails with the plain message, and both buttons are back', (tester) async {
      final h = await pump(tester);
      await tester.tap(downloadAll);
      await tester.pump();
      await tester.pump();
      h.service.pendingAll!.completeError(const ReportExportException('Could not reach the server. Check your connection and try again.'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not reach the server. Check your connection and try again.'), findsOneWidget);
      expect(download, findsOneWidget);
      expect(downloadAll, findsOneWidget);
      // Usable again: the per-tab download still works.
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      expect(h.service.calls, hasLength(1));
      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
    });

    testWidgets('warnings from the parts (a part\'s tiles were missing) are said', (tester) async {
      final h = await pump(tester);
      await tester.tap(downloadAll);
      await tester.pump();
      await tester.pump();
      h.service.pendingAll!.complete(FinalReportExportResult(fileName: 'f.xlsx', rowCount: 3, warnings: ['NCs: $statsMissingNote']));
      await tester.pump();
      await tester.pump();
      expect(find.text('NCs: $statsMissingNote'), findsOneWidget);
    });

    testWidgets('leaving the screen cancels it too', (tester) async {
      final h = await pump(tester);
      await tester.tap(downloadAll);
      await tester.pump();
      await tester.pump();
      final token = h.service.token!;
      await tester.pumpWidget(const SizedBox());
      expect(token.isCancelled, isTrue);
      h.service.pendingAll!.completeError(const ExportCancelled());
      await tester.pump();
    });
  });

  group('cancelling', () {
    testWidgets('Cancel stops the download, says so while it winds down, and gives the Download button back', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      await tester.tap(cancel);
      await tester.pump();
      expect(h.service.token!.isCancelled, isTrue);
      expect(shown(tester), 'Cancelling…');
      expect(tester.widget<TextButton>(cancel).onPressed, isNull);
      // Late progress from a request that was on the wire does not undo "Cancelling…".
      h.service.onProgress!(const ExportProgress(noun: 'reports', done: 100, total: 340));
      await tester.pump();
      expect(shown(tester), 'Cancelling…');

      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
      expect(download, findsOneWidget);
      // A cancel is not an error: nothing is announced.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('leaving the screen cancels a download still reading pages', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      final token = h.service.token!;
      await tester.pumpWidget(const SizedBox());
      expect(token.isCancelled, isTrue);
      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
    });
  });

  group('when it fails', () {
    testWidgets('a clear error snackbar, and the screen is usable again — Download works a second time', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      h.service.pending!.completeError(const ReportExportException('Could not reach the server. Check your connection and try again.'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not reach the server. Check your connection and try again.'), findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).backgroundColor, Theme.of(tester.element(download)).colorScheme.error);
      expect(download, findsOneWidget);

      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      expect(h.service.calls, hasLength(2));
      h.service.pending!.completeError(const ExportCancelled());
      await tester.pump();
      await tester.pump();
    });

    testWidgets('an unexpected error is a plain sentence, never a crash', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      h.service.pending!.completeError(StateError('boom'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Could not create the Excel file. Please try again.'), findsOneWidget);
      expect(download, findsOneWidget);
    });

    testWidgets('a download that finished with a warning (the tiles were missing) says so', (tester) async {
      final h = await pump(tester);
      await tester.tap(download);
      await tester.pump();
      await tester.pump();
      h.service.pending!.complete(const FinalReportExportResult(fileName: 'f.xlsx', rowCount: 3, warnings: [statsMissingNote]));
      await tester.pump();
      await tester.pump();
      expect(find.text(statsMissingNote), findsOneWidget);
      expect(download, findsOneWidget);
    });
  });
}

class _Harness {
  _Harness(FinalReportTab initial) : tab = ValueNotifier(initial);

  final audits = AuditsProvider()..setSelfEmployeeId('me');
  final ncs = NcProvider()..setSelfEmployeeId('me');
  final options = FilterOptionsProvider();
  final ValueNotifier<FinalReportTab> tab;
  final service = _FakeService();
}

/// An export that waits for the test: [pending] is completed (or failed) by hand.
class _FakeService implements FinalReportExportService {
  final List<FinalReportRequest> calls = [];
  final List<FinalReportAllRequest> allCalls = [];
  Completer<FinalReportExportResult>? pending;
  // The pending job, whichever kind it is.
  Completer<FinalReportExportResult>? pendingAll;
  ExportProgressCallback? onProgress;
  ExportCancelToken? token;
  Rect? origin;

  @override
  List<Duration>? get retryDelays => null;

  @override
  Future<FinalReportExportResult> export(
    FinalReportRequest request, {
    ExportCancelToken? cancel,
    ExportProgressCallback? onProgress,
    Rect? shareOrigin,
  }) {
    calls.add(request);
    this.onProgress = onProgress;
    token = cancel;
    origin = shareOrigin;
    return (pending = Completer<FinalReportExportResult>()).future;
  }

  @override
  Future<FinalReportExportResult> exportAll(
    FinalReportAllRequest request, {
    ExportCancelToken? cancel,
    ExportProgressCallback? onProgress,
    Rect? shareOrigin,
  }) {
    allCalls.add(request);
    this.onProgress = onProgress;
    token = cancel;
    origin = shareOrigin;
    return (pendingAll = Completer<FinalReportExportResult>()).future;
  }
}
