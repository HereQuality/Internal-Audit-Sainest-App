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
    } catch (e, st) {
      // A picked photo that can no longer be read, or an answer without the
      // updated profile: the person is told, and Save is released.
      debugPrint('ProfileProvider.updateProfile failed: $e\n$st');
      return 'Could not update your profile.';
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
    } catch (e, st) {
      debugPrint('ProfileProvider.changePassword failed: $e\n$st');
      return 'Could not change your password.';
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  /// Returns the server's own merged preferences on success (same
  /// isOk/data shape web's AuthContext#updatePreferences trusts wholesale
  /// rather than reconstructing the merge client-side — the server already
  /// did the real merge, see profile.controller.js#updateOwnPreferences),
  /// or an error message on failure. Only the fields actually being changed
  /// need to be passed — the server applies just those keys, so two devices
  /// changing different switches at the same time don't overwrite each
  /// other. The two per-topic maps follow the same rule: pass only the
  /// topics being changed, and ALWAYS both channels' values for each of
  /// them (audit_reminder has no email value). The server falls back to the
  /// old shared setting for a channel that was never set explicitly, and
  /// sending both is what ends that fallback for the topic.
  Future<Object?> updatePreferences({
    bool? themeMode,
    bool? showDashboardClock,
    bool? emailNotifications,
    bool? pushNotifications,
    Map<String, bool>? emailNotificationTypes,
    Map<String, bool>? pushNotificationTypes,
  }) async {
    try {
      final res = await _dio.put(
        ApiConstants.mePreferences,
        data: {
          if (themeMode != null) 'themeMode': themeMode ? 'dark' : 'light',
          'showDashboardClock': ?showDashboardClock,
          'emailNotifications': ?emailNotifications,
          'pushNotifications': ?pushNotifications,
          if (emailNotificationTypes != null && emailNotificationTypes.isNotEmpty)
            'emailNotificationTypes': emailNotificationTypes,
          if (pushNotificationTypes != null && pushNotificationTypes.isNotEmpty)
            'pushNotificationTypes': pushNotificationTypes,
        },
      );
      return UserPreferences.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update preferences.');
    } catch (e, st) {
      debugPrint('ProfileProvider.updatePreferences failed: $e\n$st');
      return 'Could not update preferences.';
    }
  }
}
