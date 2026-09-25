import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'background_entrypoints.dart';
import 'fcm_service.dart';
import 'local_notifications.dart';

/// Everything that has to happen once, at app start, before the overdue-NC
/// pipeline can do anything — call from main() before runApp(). Does NOT
/// start polling by itself; that's tied to being logged in (see
/// notification_scheduler.dart), not to the app merely having launched.
class NotificationBootstrap {
  NotificationBootstrap._();

  static Future<void> init() async {
    await LocalNotifications.init();
    if (Platform.isAndroid) {
      await configureBackgroundService();
    }
  }

  /// Runtime notification permission prompt — call from a real screen
  /// (e.g. right after login, or from a Settings toggle), never blind
  /// from main(), so there's a moment of user context for why the app is
  /// asking. Returns whether it was granted, so the caller can show a
  /// real "reminders won't show" notice instead of silently hoping.
  static Future<bool> requestPermissions() async {
    // iOS asks through Firebase Messaging rather than permission_handler:
    // its notification support there only exists when a native build define
    // is set (ios/Podfile), and without it request() never shows the OS
    // prompt and just answers "permanently denied" — which used to leave an
    // iPhone never asked, never registered for push. The FCM route also
    // makes the plugin register with APNs as soon as it's granted. Falls
    // back to permission_handler only where Firebase itself didn't come up,
    // so the local reminders can still ask.
    if (Platform.isIOS && FcmService.isReady) return FcmService.requestIosPermission();
    final status = await Permission.notification.request();
    return status.isGranted;
  }
}
