import 'package:flutter/material.dart';

import '../core/storage/secure_storage.dart';

/// The phone app's own dark/light setting — a local device preference,
/// deliberately independent of the web account's preferences.themeMode
/// (client/src/context/ThemeContext.jsx). They used to share that one
/// server field, so toggling dark mode on the web dashboard would flip
/// the phone app's theme too (and vice versa) the next time either
/// loaded — surprising on a shared device-vs-desktop workflow. Now each
/// platform just remembers its own choice locally (SecureStorage here,
/// localStorage on web) and never touches the other's.
class ThemeProvider extends ChangeNotifier {
  ThemeMode mode = ThemeMode.light;
  bool loaded = false;

  Future<void> bootstrap() async {
    final saved = await SecureStorage.instance.readThemeMode();
    mode = saved == 'dark' ? ThemeMode.dark : ThemeMode.light;
    loaded = true;
    notifyListeners();
  }

  Future<void> setDark(bool isDark) async {
    mode = isDark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    await SecureStorage.instance.saveThemeMode(isDark ? 'dark' : 'light');
  }
}
