import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../storage/secure_storage.dart';

/// Centralized Dio instance, mirrors the web app's axios interceptor:
/// attaches the bearer token to every request and reacts to 401s (and to the
/// 403 a blocked account gets, see [isBlockedAccountResponse]).
class DioClient {
  DioClient._();
  static final DioClient instance = DioClient._();

  /// Set by AuthProvider on startup; invoked whenever a request that carried
  /// the CURRENT session's token comes back 401 — or 403 "Your account has been
  /// blocked." — so the app can tear the session down and drop back to the
  /// login screen. It is the handler that
  /// clears the stored token — the interceptor no longer does it first,
  /// because the teardown still needs that token (see [explicitBearer]).
  void Function()? onUnauthorized;

  static const _explicitAuthKey = 'explicitAuth';

  /// Options for a request that must go out with a bearer token the CALLER
  /// holds — the sign-out cleanup (FCM unregister) runs when the stored
  /// token is already gone or already expired, and it is not a signal about
  /// the session: the interceptors leave both the header and any 401 of such
  /// a request alone, so it can neither be stripped nor re-enter the logout
  /// it is part of.
  static Options explicitBearer(String token) => Options(
        headers: {'Authorization': 'Bearer $token'},
        extra: {_explicitAuthKey: true},
      );

  late final Dio dio = _build();

  Dio _build() {
    final dio = Dio(
      BaseOptions(
        baseUrl: ApiConstants.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        // Was 30s — a combined "whole batch" report (getBatchReport) returns
        // every zone's full parameter tree + NCs in one response, and a
        // single audit's own report can carry a deep checklist too; on a
        // slow mobile connection either could legitimately take longer than
        // 30s to fully arrive, which surfaced as "the report just fails to
        // download" (a receiveTimeout DioException) rather than a real
        // server error. 60s gives slow connections real headroom without
        // hanging forever — actual failures (bad connection entirely) still
        // hit connectTimeout well before this.
        receiveTimeout: const Duration(seconds: 60),
        // Multi-photo evidence uploads (up to 5 files) can legitimately
        // take a while to SEND on a slow mobile connection — there was no
        // ceiling on that phase at all before (only receiveTimeout, which
        // doesn't cover it).
        sendTimeout: const Duration(seconds: 60),
        // Tells the server this request came from the phone app, not a
        // browser — the one signal audit.controller.js#isMobileRequest has
        // for gating web-only editing until an audit's first mobile
        // Submit (see mobileSubmitAudit / awaitingMobileSubmission there).
        // Sent on every request, not just submit, so the server can also
        // trust it while actually scoring checkpoints from the phone.
        headers: {'X-Client-Platform': 'mobile'},
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.extra[_explicitAuthKey] == true) return handler.next(options);
          final token = await SecureStorage.instance.readToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          // Only a 401 for a request that carried the token STILL stored ends
          // the session. A 401 on a request that had none, or one that
          // carried a token that has since been cleared or replaced (a
          // sign-out already under way, or a different account signed in
          // while this request was in flight), says nothing about the
          // session that exists now — treating it as a logout signal
          // re-entered the teardown in a loop, and could sign the NEXT
          // account out. Requests sent with [explicitBearer] never count.
          //
          // The one 403 that counts is the blocked account's (see
          // [isBlockedAccountResponse]): the server answers a blocked person's
          // every request with it, so without this the phone would stay signed
          // in with everything failing until the next launch. Any other 403 is
          // one endpoint saying no to this person and says nothing about the
          // session.
          final sent = error.requestOptions.headers['Authorization'];
          final explicit = error.requestOptions.extra[_explicitAuthKey] == true;
          final endsSession = error.response?.statusCode == 401 || isBlockedAccountResponse(error.response);
          if (endsSession && sent != null && !explicit) {
            String? current;
            try {
              current = await SecureStorage.instance.readToken();
            } catch (_) {
              // Unreadable storage: nothing to compare against, leave it be.
            }
            if (current != null && sent == 'Bearer $current') {
              final logout = onUnauthorized;
              if (logout != null) {
                logout();
              } else {
                await SecureStorage.instance.clear();
              }
            }
          }
          handler.next(error);
        },
      ),
    );

    return dio;
  }
}

/// Whether [response] is the server's "this account is blocked" answer:
/// auth.middleware.js `protect` replies 403 with the message "Your account has
/// been blocked." to every request of a blocked account. The status alone is
/// not enough — the same code carries plenty of ordinary refusals (only the
/// auditor who raised an NC can verify it, a missing menu permission, a role
/// that may not use the route) that must leave the session alone — so the
/// server's own wording decides.
bool isBlockedAccountResponse(Response<dynamic>? response) {
  if (response?.statusCode != 403) return false;
  final data = response?.data;
  final message = data is Map ? data['message'] : null;
  return message is String && message.toLowerCase().contains('account has been blocked');
}

/// Pulls a human-readable message out of a DioException / server error body.
String extractErrorMessage(Object error, {String fallback = 'Something went wrong. Please try again.'}) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['message'] is String) return data['message'] as String;
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionError) {
      return 'Could not reach the server. Check your connection and try again.';
    }
  }
  return fallback;
}
