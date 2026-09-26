import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, mapEquals, visibleForTesting;
import 'package:flutter/widgets.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../core/notifications/fcm_service.dart';
import '../core/notifications/notification_prefs.dart';
import '../core/notifications/notification_scheduler.dart';
import '../core/storage/secure_storage.dart';
import '../models/user_model.dart';

/// [offline]: a saved session exists but the server couldn't be reached to
/// confirm it (no signal, a timeout, a 5xx during a deploy). The session is
/// KEPT — only the server saying 401/403 ends it — and confirmed again as
/// soon as the server answers; until then there is no [AuthProvider.user],
/// so the app shows a retry screen instead of a half-armed shell.
enum AuthStatus { unknown, authenticated, unauthenticated, offline }

class AuthProvider extends ChangeNotifier with WidgetsBindingObserver {
  AuthStatus status = AuthStatus.unknown;
  UserModel? user;
  bool isBusy = false;

  final Dio _dio = DioClient.instance.dio;

  // The session whose preferences request is on the wire, if any. Scoped to a
  // session (not a bare flag) so a request that outlived its account can't
  // make the next account's own refresh a no-op while it is still pending.
  int? _refreshingPreferencesFor;
  // The socket's first 'connect' of a session comes right after login/
  // bootstrap already loaded fresh preferences, so only the connects AFTER
  // it (a dropped connection coming back) are worth a refetch.
  bool _socketConnectedOnce = false;
  // Bumped when a session starts and when it ends. Work started for one
  // session (the notification setup, which awaits several requests) checks
  // it before acting on what it found, so a sign-out in between isn't undone.
  int _sessionId = 0;
  // The sign-out in progress, if any — shared, so the button, a 401 and a
  // blocked-account answer arriving together run the teardown once.
  Future<void>? _loggingOut;
  bool _restoring = false;
  Timer? _sessionRetryTimer;
  int _sessionRetryAttempt = 0;

  // How long to wait before asking the server again while [AuthStatus
  // .offline]; the last value repeats. Resume and the Retry button ask
  // immediately.
  @visibleForTesting
  static List<Duration> sessionRetryDelays = const [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

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
    _sessionRetryTimer?.cancel();
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
    if (state != AppLifecycleState.resumed) return;
    switch (status) {
      case AuthStatus.offline:
        unawaited(_restoreSession());
      case AuthStatus.unauthenticated:
        // A sign-out done without a network left its "unregister this
        // phone" request unsent; the login screen is the moment to send it.
        unawaited(FcmService.retryPendingUnregister());
      case AuthStatus.authenticated:
        refreshPreferences();
        // Catches a phone whose push registration failed at launch, or whose
        // notification permission was granted later in the system settings.
        unawaited(FcmService.ensureRegistered());
      case AuthStatus.unknown:
        break;
    }
  }

  Future<void> bootstrap() => _restoreSession();

  /// The Retry button of the offline screen.
  Future<void> retrySession() async {
    if (status != AuthStatus.offline || _restoring || _loggingOut != null) return;
    isBusy = true;
    notifyListeners();
    try {
      await _restoreSession();
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  // Finds out whether the saved session still stands. Only the server
  // answering 401/403 (expired, deleted, blocked) ends it; not being able to
  // reach the server says nothing about the session, so the token, the FCM
  // registration and the notification mirrors all stay as they are and the
  // question is asked again later.
  //
  // A sign-out owns the session from the moment it starts: the offline screen
  // keeps `status == offline` for the whole teardown, so a retry timer or a
  // resume can start this in the middle of it, and an answer that lands
  // afterwards would set the account it is signing out up again (socket,
  // polling, FCM registration). Nothing below acts once [_sessionId] has moved
  // on from what this started with.
  Future<void> _restoreSession() async {
    if (_restoring || _loggingOut != null) return;
    _restoring = true;
    final session = _sessionId;
    _sessionRetryTimer?.cancel();
    _sessionRetryTimer = null;
    try {
      final String? token;
      try {
        token = await SecureStorage.instance.readToken();
      } catch (_) {
        // Storage itself is unreadable (e.g. a keystore that no longer
        // opens): nothing to restore, and wiping it is the recovery.
        if (session != _sessionId) return;
        await _clearStorageQuietly();
        status = AuthStatus.unauthenticated;
        return;
      }
      if (session != _sessionId) return;
      if (token == null || token.isEmpty) {
        status = AuthStatus.unauthenticated;
        unawaited(FcmService.retryPendingUnregister());
        return;
      }
      try {
        final res = await _dio.get(ApiConstants.me);
        if (session != _sessionId) return;
        _onSessionEstablished(
          token,
          UserModel.fromJson(Map<String, dynamic>.from(res.data['data'])),
        );
      } on DioException catch (e) {
        // Its answer says nothing about whoever is signed in now, so a 401/403
        // that outlived its session must not sign them out either. A teardown
        // still running is waited for, so callers see the signed-out end state.
        if (session != _sessionId) {
          await _loggingOut;
          return;
        }
        final code = e.response?.statusCode;
        if (code == 401 || code == 403) {
          // 401 already started the teardown (DioClient); a blocked account
          // (403) is only seen here. Same teardown, run once.
          await _forceLogout();
        } else {
          status = AuthStatus.offline;
          _scheduleSessionRetry();
        }
      } catch (e, st) {
        // A 200 whose body UserModel can't read is the server's problem,
        // not proof the session is bad.
        if (session != _sessionId) {
          await _loggingOut;
          return;
        }
        debugPrint('AuthProvider: /auth/me answered with something unreadable: $e\n$st');
        status = AuthStatus.offline;
        _scheduleSessionRetry();
      }
    } finally {
      _restoring = false;
      notifyListeners();
    }
  }

  void _scheduleSessionRetry() {
    final delays = sessionRetryDelays;
    final delay = delays[_sessionRetryAttempt < delays.length ? _sessionRetryAttempt : delays.length - 1];
    _sessionRetryAttempt++;
    _sessionRetryTimer?.cancel();
    _sessionRetryTimer = Timer(delay, () {
      _sessionRetryTimer = null;
      unawaited(_restoreSession());
    });
  }

  Future<void> _clearStorageQuietly() async {
    try {
      await SecureStorage.instance.clear();
    } catch (_) {
      // Storage itself is unavailable — nothing more we can do; fall through logged out.
    }
  }

  /// The one place a session begins (login, or bootstrap finding a saved
  /// token the server still accepts).
  void _onSessionEstablished(String token, UserModel signedIn) {
    _sessionId++;
    _sessionRetryAttempt = 0;
    user = signedIn;
    status = AuthStatus.authenticated;
    // Before anything awaits: the previous sign-out stopped push registration
    // and this must lift it even if the notification setup below fails early.
    FcmService.onSessionStarted();
    SocketService.instance.connect(token);
    unawaited(_startNotifications(token, signedIn.id, _sessionId));
  }

  Future<String?> login({required String username, required String password}) async {
    isBusy = true;
    notifyListeners();
    try {
      // A sign-out still tearing the previous session down (it clears the
      // stored token and the FCM registration) must finish first, or it would
      // wipe what this login is about to set up.
      final leaving = _loggingOut;
      if (leaving != null) await leaving;
      final res = await _dio.post(ApiConstants.login, data: {
        'username': username,
        'password': password,
      });
      final token = res.data['token'] as String;
      await SecureStorage.instance.saveToken(token);
      _onSessionEstablished(
        token,
        UserModel.fromJson(Map<String, dynamic>.from(res.data['data']['user'])),
      );
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Login failed. Please try again.');
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  /// The Log out button (and "Sign out" on the offline / maintenance
  /// screens). Also tells the server, best-effort.
  Future<void> logout() => _forceLogout(notifyServer: true);

  /// Every way a session ends — the button, a 401 from any request, a
  /// blocked account, a saved session the server no longer accepts — runs
  /// this once.
  Future<void> _forceLogout({bool notifyServer = false}) =>
      _loggingOut ??= _endSession(notifyServer: notifyServer).whenComplete(() => _loggingOut = null);

  Future<void> _endSession({required bool notifyServer}) async {
    try {
      _sessionId++;
      _sessionRetryTimer?.cancel();
      _sessionRetryTimer = null;
      // Read BEFORE anything clears it: the FCM unregister below has to
      // prove who is signing out, and by the time a 401 has been handled the
      // stored token is expired (or, for a blocked account, still valid but
      // about to go) — the server accepts either for that one request, so
      // it is sent explicitly rather than through the interceptor.
      String? jwt;
      try {
        jwt = await SecureStorage.instance.readToken();
      } catch (_) {}
      // No more live events (banners, badge bumps) for the account leaving.
      SocketService.instance.disconnect();
      _socketConnectedOnce = false;
      await NotificationScheduler.onLoggedOut(jwt: jwt);
      if (notifyServer && jwt != null && jwt.isNotEmpty) unawaited(_tellServerLoggedOut(jwt));
      await _clearStorageQuietly();
    } catch (e, st) {
      // Whatever went wrong, the UI still has to leave the session.
      debugPrint('AuthProvider: sign-out teardown failed: $e\n$st');
    }
    user = null;
    status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  Future<void> _tellServerLoggedOut(String jwt) async {
    try {
      await _dio
          .post(ApiConstants.logout, options: DioClient.explicitBearer(jwt))
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // Best-effort — the session is over locally regardless.
    }
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
    final session = _sessionId;
    if (user == null || _loggingOut != null || _refreshingPreferencesFor == session) return;
    _refreshingPreferencesFor = session;
    try {
      final res = await _dio.get(ApiConstants.mePreferences);
      // Signed out (or into another account) while this was on the wire: it is
      // the previous account's answer, and applying it would hand its switches
      // to the account signed in now — and to both SharedPreferences mirrors.
      if (session != _sessionId) return;
      applyPreferences(
        UserPreferences.fromJson(Map<String, dynamic>.from(res.data['data'])),
      );
    } catch (_) {
      // Offline, or a server that predates the endpoint — the next resume
      // or reconnect tries again.
    } finally {
      if (_refreshingPreferencesFor == session) _refreshingPreferencesFor = null;
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
    // A (re)connect is the "network is back" signal a push registration that
    // failed while offline was waiting for. Idempotent, and a no-op while a
    // registration is running or the phone is already registered.
    if (status == AuthStatus.authenticated) unawaited(FcmService.ensureRegistered());
  }

  /// Everything notification-related that follows a sign-in (a fresh login,
  /// or bootstrap finding a saved token), in the order the pieces depend on
  /// each other. Never throws — reminders are a nice-to-have and must not
  /// affect login itself.
  Future<void> _startNotifications(String token, String userId, int sessionId) async {
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
      if (current == null || sessionId != _sessionId) return;
      // The mirrors must be right BEFORE onLoggedIn: the master decides
      // whether the background polling starts at all, and the first poll it
      // fires reads both.
      await NotificationPrefs.setPushEnabled(current.preferences.pushNotifications);
      await NotificationPrefs.setPushTypes(current.preferences.pushNotificationTypes);
      if (sessionId != _sessionId) return;
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
