import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import 'background_entrypoints.dart';
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
    final status = await Permission.notification.request();
    return status.isGranted;
  }
}
