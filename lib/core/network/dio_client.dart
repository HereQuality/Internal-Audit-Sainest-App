import 'package:dio/dio.dart';

import '../constants/api_constants.dart';
import '../storage/secure_storage.dart';

/// Centralized Dio instance, mirrors the web app's axios interceptor:
/// attaches the bearer token to every request and reacts to 401s.
class DioClient {
  DioClient._();
  static final DioClient instance = DioClient._();

  /// Set by AuthProvider on startup; invoked whenever a request comes back
  /// 401 so the app can clear state and drop back to the login screen.
  void Function()? onUnauthorized;

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
          final token = await SecureStorage.instance.readToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
          }
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode == 401) {
            await SecureStorage.instance.clear();
            onUnauthorized?.call();
          }
          handler.next(error);
        },
      ),
    );

    return dio;
  }
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
