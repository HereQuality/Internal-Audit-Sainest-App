import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/utils/report_file_share.dart';

/// The last step of "Download Excel": the file written to the app's temporary folder and
/// handed to the share sheet. The two plugins (the temporary folder and the share sheet)
/// are stood in for at their method channels, so what is checked is what this app sends
/// them — the real sheet, and the real Android FileProvider, are not exercised here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  late Directory temp;
  final shared = <Map<Object?, Object?>>[];
  var shareAnswer = 'dev.fluttercommunity.plus/share/success';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('final_report_share_test');
    shared.clear();
    shareAnswer = 'dev.fluttercommunity.plus/share/success';
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, (call) async => temp.path);
    messenger.setMockMethodCallHandler(shareChannel, (call) async {
      shared.add(Map<Object?, Object?>.from(call.arguments as Map));
      return shareAnswer;
    });
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathChannel, null);
    messenger.setMockMethodCallHandler(shareChannel, null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('writes the file under its name and opens the share sheet for it as an Excel workbook', () async {
    final bytes = Uint8List.fromList([80, 75, 3, 4, 1, 2, 3]);
    final outcome = await const SharePlusReportFileSharer().shareXlsx(
      fileName: 'Final-Report-NCs-2026-11-03.xlsx',
      bytes: bytes,
      origin: const Rect.fromLTWH(10, 20, 150, 44),
    );
    expect(outcome, ReportShareOutcome.shared);

    final call = shared.single;
    final path = (call['paths'] as List).single as String;
    expect(path, endsWith('Final-Report-NCs-2026-11-03.xlsx'));
    expect(File(path).readAsBytesSync(), bytes);
    expect((call['mimeTypes'] as List).single, xlsxMimeType);
    expect(call['subject'], 'Final-Report-NCs-2026-11-03.xlsx');
    expect([call['originX'], call['originY'], call['originWidth'], call['originHeight']], [10.0, 20.0, 150.0, 44.0]);
  });

  test('an earlier download is removed when a new one is made', () async {
    const sharer = SharePlusReportFileSharer();
    await sharer.shareXlsx(fileName: 'Final-Report-Audits-2026-11-02.xlsx', bytes: Uint8List.fromList([1]));
    final folder = Directory('${temp.path}${Platform.pathSeparator}final_report_exports');
    expect(folder.listSync().map((e) => e.path.split(Platform.pathSeparator).last), ['Final-Report-Audits-2026-11-02.xlsx']);
    await sharer.shareXlsx(fileName: 'Final-Report-Audits-2026-11-03.xlsx', bytes: Uint8List.fromList([2]));
    expect(folder.listSync().map((e) => e.path.split(Platform.pathSeparator).last), ['Final-Report-Audits-2026-11-03.xlsx']);
  });

  test('says what the person did with the sheet (Android cannot tell)', () async {
    const sharer = SharePlusReportFileSharer();
    // The plugin reports "the sheet was closed without choosing" as an empty answer.
    shareAnswer = '';
    expect(await sharer.shareXlsx(fileName: 'a.xlsx', bytes: Uint8List.fromList([1])), ReportShareOutcome.dismissed);
    shareAnswer = 'dev.fluttercommunity.plus/share/unavailable';
    expect(await sharer.shareXlsx(fileName: 'a.xlsx', bytes: Uint8List.fromList([1])), ReportShareOutcome.unknown);
  });
}
