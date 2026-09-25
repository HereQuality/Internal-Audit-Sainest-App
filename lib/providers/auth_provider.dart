import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../core/notifications/fcm_service.dart';
import '../core/notifications/notification_prefs.dart';
import '../core/notifications/notification_scheduler.dart';
import '../core/storage/secure_storage.dart';
import '../models/user_model.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthStatus status = AuthStatus.unknown;
  UserModel? user;
  bool isBusy = false;

  final Dio _dio = DioClient.instance.dio;

  bool _refreshingPreferences = false;
  // The socket's first 'connect' of a session comes right after login/
  // bootstrap already loaded fresh preferences, so only the connects AFTER
  // it (a dropped connection coming back) are worth a refetch.
  bool _socketConnectedOnce = false;

  AuthProvider() {
    DioClient.instance.onUnauthorized = _forceLogout;
    WidgetsBinding.instance.addObserver(this);
    // Registered while no socket exists yet, so SocketService parks them
    // and replays both on every connect() — i.e. on every login, not just
    // the first one after launch.
    SocketService.instance.on('preferences_updated', _onPreferencesUpdated);
    SocketService.instance.on('connect', _onSocketConnect);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SocketService.instance.off('preferences_updated', _onPreferencesUpdated);
    SocketService.instance.off('connect', _onSocketConnect);
    super.dispose();
  }

  // A change made on the web while this app sat in the background reaches
  // the phone through the socket only if the connection survived — coming
  // back to the foreground is the moment to catch up on one that didn't.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      refreshPreferences();
      // Catches a phone whose push registration failed at launch, or whose
      // notification permission was granted later in the system settings.
      if (status == AuthStatus.authenticated) unawaited(FcmService.ensureRegistered());
    }
  }

  Future<void> bootstrap() async {
    try {
      final token = await SecureStorage.instance.readToken();
      if (token == null || token.isEmpty) {
        status = AuthStatus.unauthenticated;
        notifyListeners();
        return;
      }
      final res = await _dio.get(ApiConstants.me);
      user = UserModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      status = AuthStatus.authenticated;
      SocketService.instance.connect(token);
      unawaited(_startNotifications(token, user!.id));
    } catch (_) {
      try {
        await SecureStorage.instance.clear();
      } catch (_) {
        // Storage itself is unavailable — nothing more we can do; fall through logged out.
      }
      status = AuthStatus.unauthenticated;
    }
    notifyListeners();
  }

  Future<String?> login({required String username, required String password}) async {
    isBusy = true;
    notifyListeners();
    try {
      final res = await _dio.post(ApiConstants.login, data: {
        'username': username,
        'password': password,
      });
      final token = res.data['token'] as String;
      await SecureStorage.instance.saveToken(token);
      user = UserModel.fromJson(Map<String, dynamic>.from(res.data['data']['user']));
      status = AuthStatus.authenticated;
      SocketService.instance.connect(token);
      unawaited(_startNotifications(token, user!.id));
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Login failed. Please try again.');
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    // Before anything clears the stored token: DELETE /device-tokens/register
    // is authenticated, and once _forceLogout has wiped the token (its own
    // unregister, via NotificationScheduler.onLoggedOut, is the best-effort
    // one for the forced/expired path) the server 401s it and this phone
    // keeps receiving the signed-out account's pushes.
    await FcmService.unregisterToken();
    try {
      await _dio.post(ApiConstants.logout);
    } catch (_) {
      // Best-effort — proceed to clear local state regardless.
    }
    await _forceLogout();
  }

  Future<void> _forceLogout() async {
    await SecureStorage.instance.clear();
    SocketService.instance.disconnect();
    _socketConnectedOnce = false;
    await NotificationScheduler.onLoggedOut();
    user = null;
    status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  void updateUser(UserModel updated) {
    // The only caller is the profile edit, whose PUT /auth/me answer carries
    // the STORED notification preferences — without the "effective" values
    // GET /auth/me/preferences computes (a topic switched off under the old
    // shared gate reads as on again there). The preferences held here came
    // from that effective source and a profile edit never changes them, so
    // they must survive it; otherwise Settings shows a topic as on that
    // isn't, and the next toggle would quietly end the opt-out.
    final held = user;
    user = held == null ? updated : updated.copyWith(preferences: held.preferences);
    notifyListeners();
  }

  /// Takes a server-confirmed preferences object (a PUT response, a GET,
  /// or a 'preferences_updated' event's payload merged into what's already
  /// here) as the new truth. The notification pipeline follows it: when the
  /// master push switch changed, the SharedPreferences mirror the background
  /// paths read and the Android polling fallback; when the per-topic push
  /// values changed, their own mirror.
  void applyPreferences(UserPreferences next) {
    final current = user;
    if (current == null) return;
    final pushChanged =
        next.pushNotifications != current.preferences.pushNotifications;
    final pushTypesChanged = !mapEquals(
      next.pushNotificationTypes,
      current.preferences.pushNotificationTypes,
    );
    user = current.copyWith(preferences: next);
    notifyListeners();
    if (pushChanged) {
      unawaited(NotificationScheduler.onPushPreferenceChanged(next.pushNotifications));
    }
    if (pushTypesChanged) {
      unawaited(NotificationScheduler.onPushTypesChanged(next.pushNotificationTypes));
    }
  }

  /// Re-reads the account's preferences from the server — the catch-up for
  /// a 'preferences_updated' event this phone was not connected to hear.
  /// Best-effort: on any failure the values already held stand.
  Future<void> refreshPreferences() async {
    if (user == null || _refreshingPreferences) return;
    _refreshingPreferences = true;
    try {
      final res = await _dio.get(ApiConstants.mePreferences);
      applyPreferences(
        UserPreferences.fromJson(Map<String, dynamic>.from(res.data['data'])),
      );
    } catch (_) {
      // Offline, or a server that predates the endpoint — the next resume
      // or reconnect tries again.
    } finally {
      _refreshingPreferences = false;
    }
  }

  // Another portal (or another device) changed the account's switches. The
  // event carries the two masters and both per-topic maps in full; they are
  // merged into what's held (UserPreferences.mergedWithEvent) instead of
  // replacing the whole preferences object.
  void _onPreferencesUpdated(dynamic data) {
    final current = user;
    if (current == null || data is! Map) return;
    applyPreferences(current.preferences.mergedWithEvent(data));
  }

  void _onSocketConnect(dynamic _) {
    if (_socketConnectedOnce) refreshPreferences();
    _socketConnectedOnce = true;
  }

  /// Everything notification-related that follows a sign-in (a fresh login,
  /// or bootstrap finding a saved token), in the order the pieces depend on
  /// each other. Never throws — reminders are a nice-to-have and must not
  /// affect login itself.
  Future<void> _startNotifications(String token, String userId) async {
    try {
      await _carryOverLegacyPushOptOut();
      // The login/me payload carries the stored preferences; the endpoint
      // below answers with the EFFECTIVE per-topic values (a topic switched
      // off under the old shared email setting keeps that opt-out for push),
      // which is what the mirror has to hold. Best-effort: on a failure the
      // payload's values stand until the first poll or resume refetch.
      await refreshPreferences();
      // Logged out while the requests above were in flight — don't re-arm a
      // session that no longer exists.
      final current = user;
      if (current == null) return;
      // The mirrors must be right BEFORE onLoggedIn: the master decides
      // whether the background polling starts at all, and the first poll it
      // fires reads both.
      await NotificationPrefs.setPushEnabled(current.preferences.pushNotifications);
      await NotificationPrefs.setPushTypes(current.preferences.pushNotificationTypes);
      await NotificationScheduler.onLoggedIn(token: token, userId: userId);
    } catch (e, st) {
      debugPrint('AuthProvider._startNotifications failed: $e\n$st');
    }
  }

  /// One-time: a device whose old phone-only "Notifications" switch was
  /// explicitly OFF carries that choice over to the account as push OFF
  /// (which the web Settings page then shows too). Server first — if the
  /// request fails (offline), the marker stays and this simply retries on
  /// the next launch rather than silently turning push back on.
  Future<void> _carryOverLegacyPushOptOut() async {
    try {
      if (await NotificationPrefs.readLegacyPushOptOut()) {
        final res = await _dio.put(
          ApiConstants.mePreferences,
          data: {'pushNotifications': false},
        );
        applyPreferences(
          UserPreferences.fromJson(Map<String, dynamic>.from(res.data['data'])),
        );
      }
      await NotificationPrefs.finishLegacyMigration();
    } catch (e, st) {
      debugPrint('AuthProvider: legacy push opt-out carry-over deferred: $e\n$st');
    }
  }
}
