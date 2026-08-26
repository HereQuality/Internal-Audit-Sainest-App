import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../models/user_model.dart';

class ProfileProvider extends ChangeNotifier {
  final Dio _dio = DioClient.instance.dio;

  bool isSaving = false;

  /// Returns the updated user on success, or a message string on failure.
  Future<Object> updateProfile({
    required String employeeName,
    required String mobileNumber,
    required String emailOffice,
    required String username,
    String? address,
    String? city,
    String? state,
    String? country,
    File? profilePicFile,
    bool removeProfilePic = false,
  }) async {
    isSaving = true;
    notifyListeners();
    try {
      final form = FormData.fromMap({
        'employeeName': employeeName,
        'mobileNumber': mobileNumber,
        'emailOffice': emailOffice,
        'username': username,
        'address': ?address,
        'city': ?city,
        'state': ?state,
        'country': ?country,
        if (removeProfilePic) 'removeProfilePic': 'true',
        if (profilePicFile != null)
          'profilePic': await MultipartFile.fromFile(
            profilePicFile.path,
            filename: profilePicFile.path.split('/').last,
          ),
      });
      final res = await _dio.put(ApiConstants.me, data: form);
      return UserModel.fromJson(Map<String, dynamic>.from(res.data['data']));
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update your profile.');
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<String?> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    isSaving = true;
    notifyListeners();
    try {
      await _dio.put(
        ApiConstants.mePassword,
        data: {'currentPassword': currentPassword, 'newPassword': newPassword},
      );
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not change your password.',
      );
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  /// Returns the server's own merged preferences on success (same
  /// isOk/data shape web's AuthContext#updatePreferences trusts wholesale
  /// rather than reconstructing the merge client-side — the server already
  /// did the real merge, see profile.controller.js#updateOwnPreferences),
  /// or an error message on failure. `emailNotificationTypes` only needs
  /// to carry the one (or few) key(s) actually being toggled — the server
  /// merges it into whatever the rest already were, it does not replace
  /// the whole map.
  Future<Object?> updatePreferences({
    bool? themeMode,
    bool? showDashboardClock,
    bool? emailNotifications,
    Map<String, bool>? emailNotificationTypes,
  }) async {
    try {
      final res = await _dio.put(
        ApiConstants.mePreferences,
        data: {
          if (themeMode != null) 'themeMode': themeMode ? 'dark' : 'light',
          'showDashboardClock': ?showDashboardClock,
          'emailNotifications': ?emailNotifications,
          'emailNotificationTypes': ?emailNotificationTypes,
        },
      );
      return UserPreferences.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update preferences.');
    }
  }
}
