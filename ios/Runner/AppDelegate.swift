import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Claim the notification-center delegate before any plugin does.
    // FlutterAppDelegate fans willPresent / didReceive out to every plugin
    // registered as an application delegate — firebase_messaging (FCM
    // pushes) and flutter_local_notifications (local banners + taps). If
    // nothing is set, firebase_messaging installs itself as the delegate
    // instead and flutter_local_notifications never sees a foreground
    // presentation or a tap, so local banners are swallowed while the app
    // is open and tapping them does nothing.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Both plugins answer willPresent for a local notification —
  // firebase_messaging replies for every notification, and
  // flutter_local_notifications for its own — but UNUserNotificationCenter
  // expects its completion handler exactly once. First reply wins; both
  // resolve to banner + sound + badge here (see FcmService.init).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    var completed = false
    super.userNotificationCenter(center, willPresent: notification) { options in
      if completed { return }
      completed = true
      completionHandler(options)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
