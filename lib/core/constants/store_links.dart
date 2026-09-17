import 'dart:io' show Platform;

/// Shared store-listing identifiers for this app, plus the one place that
/// turns them into an actual URL — used by both UpdateRequiredScreen's
/// full-screen force-update block and SoftUpdateBanner's non-blocking
/// nudge, so the two can never drift out of sync with each other (e.g. one
/// getting a package-id fix the other doesn't).
class StoreLinks {
  StoreLinks._();

  /// Android's Play Store package name (android/app/build.gradle.kts's own
  /// `applicationId`) — used to deep-link straight to this app's listing.
  static const androidPackageId = 'com.hqepl.audit360';

  /// Apple's numeric App Store id for this app (ios/Runner.xcodeproj's own
  /// `PRODUCT_BUNDLE_IDENTIFIER` is "com.hqepl.internalaudit", but Apple's
  /// store URL needs the numeric listing id, not the bundle id). From the
  /// live listing: https://apps.apple.com/in/app/q-audit360/id6809678429
  static const iosAppStoreId = '6809678429';

  /// Whether [appStoreUri] would actually return a link for this platform
  /// — lets a caller decide up front whether to show an "Update"/"Update
  /// Now" button at all versus a "no store link yet" fallback, without
  /// needing to build (and discard) the Uri just to check.
  static bool get hasStoreLink => Platform.isAndroid || (Platform.isIOS && iosAppStoreId.isNotEmpty);

  /// The Play Store / App Store listing URL for the current platform, or
  /// null when neither applies (desktop/web builds of this same Flutter
  /// project have no app-store listing to link to) or the iOS listing
  /// doesn't exist yet.
  static Uri? appStoreUri() {
    if (Platform.isAndroid) {
      return Uri.parse('https://play.google.com/store/apps/details?id=$androidPackageId');
    }
    if (Platform.isIOS && iosAppStoreId.isNotEmpty) {
      return Uri.parse('https://apps.apple.com/app/id$iosAppStoreId');
    }
    return null;
  }
}
