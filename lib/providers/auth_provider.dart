import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../core/notifications/notification_scheduler.dart';
import '../core/storage/secure_storage.dart';
import '../models/user_model.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthProvider extends ChangeNotifier {
  AuthStatus status = AuthStatus.unknown;
  UserModel? user;
  bool isBusy = false;

  final Dio _dio = DioClient.instance.dio;

  AuthProvider() {
    DioClient.instance.onUnauthorized = _forceLogout;
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
      unawaited(NotificationScheduler.onLoggedIn(token: token, userId: user!.id));
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
      unawaited(NotificationScheduler.onLoggedIn(token: token, userId: user!.id));
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Login failed. Please try again.');
    } finally {
      isBusy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
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
    await NotificationScheduler.onLoggedOut();
    user = null;
    status = AuthStatus.unauthenticated;
    notifyListeners();
  }

  void updateUser(UserModel updated) {
    user = updated;
    notifyListeners();
  }
}
