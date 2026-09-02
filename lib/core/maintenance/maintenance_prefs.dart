import 'package:shared_preferences/shared_preferences.dart';

/// Device-local "have we already shown today's scheduled-maintenance
/// popup" flag — mirrors core/notifications/notification_prefs.dart's
/// static-class, per-call-instance convention. Deliberately NOT cleared
/// on logout (same reasoning as NotificationPrefs' toggle keys, see its
/// own comment): this is a per-day/per-device nudge, not session state —
/// a different account logging in on the same device shouldn't see the
/// same popup twice in one day either.
class MaintenancePrefs {
  MaintenancePrefs._();

  // Value shape: "<yyyy-MM-dd>|<maintenance doc's updatedAt ISO string>" —
  // keying on both means an admin editing the schedule mid-day makes the
  // popup resurface immediately even though "today" hasn't changed.
  static const _lastShownKey = 'maintenance_popup_last_shown';

  static Future<String?> readLastShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastShownKey);
  }

  static Future<void> setLastShown(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastShownKey, value);
  }
}
