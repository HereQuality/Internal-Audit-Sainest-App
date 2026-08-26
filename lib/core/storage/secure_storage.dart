import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper around flutter_secure_storage for the JWT and cached
/// role/theme hints that need to survive app restarts.
class SecureStorage {
  SecureStorage._();
  static final SecureStorage instance = SecureStorage._();

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _tokenKey = 'auth_token';
  static const _appModeKey = 'app_mode';
  static const _themeModeKey = 'theme_mode';

  Future<void> saveToken(String token) => _storage.write(key: _tokenKey, value: token);

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  /// "auditor" | "auditee" — which landing/tab set the user picked after
  /// login (see AppModeProvider). Not a real permission, just a local UI
  /// preference, since the same person can legitimately be both.
  Future<void> saveAppMode(String mode) => _storage.write(key: _appModeKey, value: mode);

  Future<String?> readAppMode() => _storage.read(key: _appModeKey);

  Future<void> clearAppMode() => _storage.delete(key: _appModeKey);

  /// "dark" | "light" — the phone's own theme choice, deliberately never
  /// synced with the web account's preferences.themeMode (see
  /// ThemeProvider): each platform gets its own, so switching the theme
  /// on one doesn't flip the other next time it loads.
  Future<void> saveThemeMode(String mode) => _storage.write(key: _themeModeKey, value: mode);

  Future<String?> readThemeMode() => _storage.read(key: _themeModeKey);

  Future<void> clear() => _storage.deleteAll();
}
