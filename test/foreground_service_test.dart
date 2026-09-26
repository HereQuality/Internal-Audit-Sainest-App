import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/notifications/background_entrypoints.dart';
import 'package:internal_audit_app/core/notifications/notification_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The tests play "another isolate" by writing to the platform store behind
// the SharedPreferences instance this isolate has already cached.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// The service isolate's view of the plugin: an event stream shaped like
/// AndroidServiceInstance's (a sync broadcast one, which silently drops
/// whatever is emitted while nobody listens — the reason a stop that arrives
/// too early is lost).
class _FakeService implements ServiceInstance {
  final _events = StreamController<Map<String, dynamic>?>.broadcast(sync: true);
  int stopCalls = 0;

  void emit(String method) => _events.add({'method': method, 'args': null});

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {}

  @override
  Stream<Map<String, dynamic>?> on(String method) =>
      _events.stream.where((event) => event?['method'] == method);

  @override
  Future<void> stopSelf() async => stopCalls++;
}

/// The app side of the plugin.
class _FakeBackgroundService implements FlutterBackgroundService {
  _FakeBackgroundService({this.running = false, this.beforeStart});

  bool running;
  int starts = 0;
  // Runs at the moment the service would come up.
  Future<void> Function()? beforeStart;

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> startService() async {
    await beforeStart?.call();
    starts++;
    running = true;
    return true;
  }

  @override
  Future<bool> configure({
    required IosConfiguration iosConfiguration,
    required AndroidConfiguration androidConfiguration,
  }) async => true;

  @override
  void invoke(String method, [Map<String, dynamic>? arg]) {}

  @override
  Stream<Map<String, dynamic>?> on(String method) => const Stream.empty();
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for the condition');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

const _tick = Duration(milliseconds: 15);
Future<void> _ticks(int n) => Future<void>.delayed(_tick * n);

// MainActivity.kt's answer to "which Android is this" (null: nobody answers).
void _androidSdkIs(Object? answer) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.hqepl.audit360/device'),
    answer == null
        ? null
        : (call) async {
            if (answer is Exception) throw answer;
            return call.method == 'sdkInt' ? answer : null;
          },
  );
}

void _grantNotificationPermission(bool granted) {
  // permission_handler asks the OS through this channel; 1 = granted.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async => call.method == 'checkPermissionStatus' ? (granted ? 1 : 0) : null,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'bg_auth_token': 'tok'});
    _grantNotificationPermission(true);
    _androidSdkIs(null);
  });

  group('the service is only ever wanted while someone is signed in with push on', () {
    test('signed in, master push on (the default): wanted', () async {
      expect(await serviceShouldRun(), isTrue);
    });

    test('nobody signed in: not wanted, even though the master mirror defaults to on', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await serviceShouldRun(), isFalse);
      SharedPreferences.setMockInitialValues({'bg_auth_token': ''});
      expect(await serviceShouldRun(), isFalse);
    });

    test('master push off: not wanted', () async {
      await NotificationPrefs.setPushEnabled(false);
      expect(await serviceShouldRun(), isFalse);
    });

    test('a logout the app made after this isolate read the token is seen', () async {
      expect(await serviceShouldRun(), isTrue);
      await SharedPreferencesStorePlatform.instance.remove('flutter.bg_auth_token');
      expect(await serviceShouldRun(), isFalse);
    });
  });

  group('NotificationPrefs cross-isolate reads', () {
    test('readToken sees a login written by another isolate, not the one cached at first read', () async {
      expect(await NotificationPrefs.readToken(), 'tok');
      // The app signs in as somebody else while the service isolate lives on.
      await SharedPreferencesStorePlatform.instance.setValue('String', 'flutter.bg_auth_token', 'other-account');
      expect(await NotificationPrefs.readToken(), 'other-account');
    });

    test('readToken sees a logout written by another isolate', () async {
      expect(await NotificationPrefs.readToken(), 'tok');
      await SharedPreferencesStorePlatform.instance.remove('flutter.bg_auth_token');
      expect(await NotificationPrefs.readToken(), isNull);
    });

    test('the foreground stamp round-trips and is read fresh', () async {
      expect(await NotificationPrefs.readAppForegroundedAt(), isNull);
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await NotificationPrefs.markAppForegrounded(at);
      expect(await NotificationPrefs.readAppForegroundedAt(), at);

      final later = at.add(const Duration(hours: 1));
      await SharedPreferencesStorePlatform.instance.setValue(
        'Int',
        'flutter.bg_app_foregrounded_at',
        later.millisecondsSinceEpoch,
      );
      expect(await NotificationPrefs.readAppForegroundedAt(), later);
    });

    test('a logout keeps the stamp — it is about the app, not the account', () async {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await NotificationPrefs.markAppForegrounded(at);
      await NotificationPrefs.clearSession();
      expect(await NotificationPrefs.readAppForegroundedAt(), at);
    });
  });

  group('starting the service', () {
    test('starts it for a signed-in account with push on, and stamps the foreground', () async {
      final service = _FakeBackgroundService();
      expect(await startServiceIfEligible(service), isTrue);
      expect(service.starts, 1);
      expect(await NotificationPrefs.readAppForegroundedAt(), isNotNull);
    });

    test('does nothing when nobody is signed in (a start that raced a logout)', () async {
      SharedPreferences.setMockInitialValues({});
      final service = _FakeBackgroundService();
      expect(await startServiceIfEligible(service), isFalse);
      expect(service.starts, 0);
    });

    test('does nothing while the master push switch is off', () async {
      await NotificationPrefs.setPushEnabled(false);
      final service = _FakeBackgroundService();
      expect(await startServiceIfEligible(service), isFalse);
      expect(service.starts, 0);
    });

    test('an already-running service is not started again', () async {
      final service = _FakeBackgroundService(running: true);
      expect(await startServiceIfEligible(service), isTrue);
      expect(service.starts, 0);
    });

    test('leaves the Android release for the service\'s isolate, before the service comes up', () async {
      _androidSdkIs(34);
      int? seenByService;
      final service = _FakeBackgroundService(beforeStart: () async => seenByService = await NotificationPrefs.readAndroidSdk());
      expect(await startServiceIfEligible(service), isTrue);
      expect(seenByService, 34);
    });

    test('a platform channel that fails or does not answer never keeps the service from starting', () async {
      for (final answer in [null, PlatformException(code: 'boom')]) {
        _androidSdkIs(answer);
        final service = _FakeBackgroundService();
        expect(await startServiceIfEligible(service), isTrue);
        expect(service.starts, 1);
        expect(await NotificationPrefs.readAndroidSdk(), isNull);
      }
    });

    test('recordAndroidSdk keeps what the OS said, and nothing when it said nothing', () async {
      _androidSdkIs(36);
      await recordAndroidSdk();
      expect(await NotificationPrefs.readAndroidSdk(), 36);

      SharedPreferences.setMockInitialValues({});
      _androidSdkIs(null);
      await recordAndroidSdk();
      expect(await NotificationPrefs.readAndroidSdk(), isNull);
    });

    test('a logout keeps it — it is about the phone, not the account', () async {
      await NotificationPrefs.setAndroidSdk(34);
      await NotificationPrefs.clearSession();
      expect(await NotificationPrefs.readAndroidSdk(), 34);
    });
  });

  group('coming back to the foreground', () {
    test('records the moment, and restarts a service that stopped itself', () async {
      final service = _FakeBackgroundService();
      await handleAppResumed(service);
      expect(service.starts, 1);
      expect(await NotificationPrefs.readAppForegroundedAt(), isNotNull);
    });

    test('a running service is left alone but still gets the new stamp', () async {
      final service = _FakeBackgroundService(running: true);
      await handleAppResumed(service);
      expect(service.starts, 0);
      expect(await NotificationPrefs.readAppForegroundedAt(), isNotNull);
    });

    test('does not start a service for a signed-out phone', () async {
      SharedPreferences.setMockInitialValues({});
      final service = _FakeBackgroundService();
      await handleAppResumed(service);
      expect(service.starts, 0);
    });

    test('does not start a service while push is off', () async {
      await NotificationPrefs.setPushEnabled(false);
      final service = _FakeBackgroundService();
      await handleAppResumed(service);
      expect(service.starts, 0);
    });

    test('does not start a service without the notification permission', () async {
      _grantNotificationPermission(false);
      final service = _FakeBackgroundService();
      await handleAppResumed(service);
      expect(service.starts, 0);
    });
  });

  group('the service run loop', () {
    late _FakeService service;
    late int polls;

    setUp(() {
      service = _FakeService();
      polls = 0;
      // Whatever a test leaves ticking must not outlive it.
      addTearDown(() => service.emit('stopService'));
    });

    test('a stop sent while the first poll is still running is not lost', () async {
      await runPollingService(
        service,
        interval: _tick,
        readForegroundedAt: () async => null,
        poll: () async {
          polls++;
          // The UI logs out / switches push off while the first poll runs —
          // no listener existed yet in the old ordering, so this vanished.
          service.emit('stopService');
          return true;
        },
      );
      expect(service.stopCalls, 1);
      await _ticks(4);
      expect(polls, 1, reason: 'no timer may start after a stop');
    });

    test('a stop sent later ends the service and its timer', () async {
      await runPollingService(
        service,
        interval: _tick,
        readForegroundedAt: () async => null,
        poll: () async {
          polls++;
          return true;
        },
      );
      await _until(() => polls >= 3);
      service.emit('stopService');
      expect(service.stopCalls, 1);
      final atStop = polls;
      await _ticks(4);
      expect(polls, atStop);
    });

    test('a first poll that finds nobody signed in / push off stops at once, without ticking', () async {
      await runPollingService(
        service,
        interval: _tick,
        readForegroundedAt: () async => null,
        poll: () async {
          polls++;
          return false;
        },
      );
      expect(service.stopCalls, 1);
      await _ticks(4);
      expect(polls, 1);
    });

    test('a later tick that finds nobody signed in stops and cancels the timer', () async {
      await runPollingService(
        service,
        interval: _tick,
        readForegroundedAt: () async => null,
        poll: () async {
          polls++;
          return polls < 3;
        },
      );
      await _until(() => service.stopCalls == 1);
      await _ticks(4);
      expect(polls, 3);
      expect(service.stopCalls, 1);
    });

    test('a first poll that throws does not abort the loop before its timer exists', () async {
      final printed = debugPrint; // the failure is logged; keep the test output clean
      debugPrint = (String? message, {int? wrapWidth}) {};
      addTearDown(() => debugPrint = printed);
      await runPollingService(
        service,
        interval: _tick,
        readForegroundedAt: () async => null,
        poll: () async {
          polls++;
          if (polls == 1) throw StateError('network down');
          return true;
        },
      );
      await _until(() => polls >= 3);
      expect(service.stopCalls, 0);
    });

    group('Android 15+ dataSync runtime budget', () {
      const budget = Duration(hours: 5);
      final start = DateTime(2026, 9, 26, 8);
      late DateTime clock;
      DateTime? stamp;

      setUp(() {
        clock = start;
        stamp = start;
      });

      // [sdk]: the Android API level the UI isolate recorded; null = not recorded (yet).
      Future<void> run({int? spendBudgetOnPoll, void Function()? onPoll, int? sdk, bool sdkUnreadable = false}) => runPollingService(
        service,
        interval: _tick,
        maxRuntime: budget,
        now: () => clock,
        readAndroidSdk: () async => sdkUnreadable ? throw StateError('prefs gone') : sdk,
        readForegroundedAt: () async => stamp,
        poll: () async {
          polls++;
          if (polls == spendBudgetOnPoll) clock = start.add(budget);
          onPoll?.call();
          return true;
        },
      );

      test('stops itself once the budget is spent, before the OS would kill the process', () async {
        await run(spendBudgetOnPoll: 3);
        await _until(() => service.stopCalls == 1);
        await _ticks(4);
        expect(polls, 3, reason: 'the tick that finds the budget spent must not poll again');
        expect(service.stopCalls, 1);
      });

      test('keeps running while the budget is not spent', () async {
        await run();
        clock = start.add(budget - const Duration(minutes: 1));
        await _until(() => polls >= 4);
        expect(service.stopCalls, 0);
      });

      test('the budget counts from the last time the app was in the foreground, not from service start', () async {
        // Poll 3 spends the budget from the start, but the app came back to the
        // foreground at exactly that moment: the OS clock restarted, so must ours.
        await run(
          spendBudgetOnPoll: 3,
          onPoll: () {
            if (polls == 3) stamp = clock;
          },
        );
        await _until(() => polls >= 6);
        expect(service.stopCalls, 0);
      });

      test('Android 14 and older have no such timeout: the service is not stopped for the budget', () async {
        for (final sdk in [33, 34]) {
          service = _FakeService();
          polls = 0;
          clock = start;
          await run(spendBudgetOnPoll: 3, sdk: sdk);
          await _until(() => polls >= 6);
          expect(service.stopCalls, 0, reason: 'API $sdk stopped at the budget');
          service.emit('stopService');
          await _ticks(2);
        }
      });

      test('Android 15 and newer keep the cap', () async {
        for (final sdk in [35, 36]) {
          service = _FakeService();
          polls = 0;
          clock = start;
          await run(spendBudgetOnPoll: 3, sdk: sdk);
          await _until(() => service.stopCalls == 1);
          expect(polls, 3, reason: 'API $sdk');
        }
      });

      test('a release nobody recorded, or that cannot be read, keeps the cap (the safe side)', () async {
        await run(spendBudgetOnPoll: 3);
        await _until(() => service.stopCalls == 1);
        expect(polls, 3);

        service = _FakeService();
        polls = 0;
        clock = start;
        await run(spendBudgetOnPoll: 3, sdkUnreadable: true);
        await _until(() => service.stopCalls == 1);
        expect(polls, 3);
      });

      test('with no stamp it counts from the service start', () async {
        stamp = null;
        await run(spendBudgetOnPoll: 3);
        await _until(() => service.stopCalls == 1);
        expect(polls, 3);
      });

      test('a stamp from the future (clock moved back) cannot keep the service alive', () async {
        stamp = start.add(const Duration(days: 1));
        await run(spendBudgetOnPoll: 3);
        await _until(() => service.stopCalls == 1);
        expect(polls, 3);
      });
    });
  });

  group('configuration', () {
    test('the plugin is never allowed to start the service on its own, at boot or otherwise', () {
      final config = buildAndroidServiceConfiguration();
      expect(config.autoStart, isFalse);
      expect(config.autoStartOnBoot, isFalse);
      expect(config.isForegroundMode, isTrue);
    });

    test('the manifest declares the same foreground service type the plugin is asked for', () {
      final config = buildAndroidServiceConfiguration();
      expect(config.foregroundServiceTypes, [AndroidForegroundType.dataSync]);
      expect(_manifest(), contains('android:foregroundServiceType="dataSync"'));
    });

    test('the manifest removes the plugin BootReceiver (no start on boot or app update)', () {
      // Matches <receiver ... BootReceiver ... tools:node="remove" ... /> in any attribute order.
      final removed = RegExp(
        r'<receiver\b(?=[^>]*android:name="id\.flutter\.flutter_background_service\.BootReceiver")(?=[^>]*tools:node="remove")[^>]*>',
      );
      expect(removed.hasMatch(_manifest()), isTrue);
    });
  });
}

String _manifest() => File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
