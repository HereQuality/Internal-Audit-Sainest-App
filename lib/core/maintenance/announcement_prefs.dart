import 'package:shared_preferences/shared_preferences.dart';

/// Device-local "have we already shown today's announcement popup" flag —
/// mirrors MaintenancePrefs' own convention (see its doc comment for why
/// this is deliberately NOT cleared on logout).
class AnnouncementPrefs {
  AnnouncementPrefs._();

  // Value shape: "<yyyy-MM-dd>|<announcement doc's updatedAt ISO string>" —
  // keying on both means a SuperAdmin editing the message mid-day makes
  // the popup resurface immediately even though "today" hasn't changed.
  static const _lastShownKey = 'announcement_popup_last_shown';

  static Future<String?> readLastShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastShownKey);
  }

  static Future<void> setLastShown(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastShownKey, value);
  }
}
