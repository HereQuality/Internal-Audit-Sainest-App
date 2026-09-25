import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../core/notifications/fcm_service.dart';
import '../core/notifications/local_notifications.dart';
import '../core/notifications/notification_navigation.dart';
import '../core/notifications/notification_prefs.dart';
import '../models/notification_model.dart';

class NotificationsProvider extends ChangeNotifier {
  final Dio _dio = DioClient.instance.dio;

  bool isLoading = false;
  String? errorMessage;
  List<NotificationModel> notifications = [];
  int unreadCount = 0;
  bool _listening = false;
  // Stored so stopListening can remove exactly these two closures — Audits-
  // Provider and NcProvider also register their own 'new_notification'
  // handler (see their startListening), and socket_io_client's off(event)
  // with no handler removes EVERY listener for that event, not just the
  // caller's own. Passing the same closure reference back to off() is what
  // makes stopListening scoped to this provider instead of silently
  // deafening the other two.
  void Function(dynamic data)? _onNewNotification;
  void Function(dynamic data)? _onRefreshUnreadCount;

  /// Wires socket listeners once, after login. Safe to call repeatedly.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map) {
        final map = Map<String, dynamic>.from(data);
        notifications = [NotificationModel.fromJson(map), ...notifications];
        unreadCount += 1;
        notifyListeners();
        unawaited(_showLiveBanner(map));
      }
    };
    _onRefreshUnreadCount = (_) => fetchUnreadCount();
    SocketService.instance.on('new_notification', _onNewNotification!);
    SocketService.instance.on('refresh_unread_count', _onRefreshUnreadCount!);
  }

  // Real-time heads-up, on top of the badge — otherwise the only OS-level
  // alert for this event would be up to 15 minutes later, via the
  // background poll (event_poll.dart). Two cases stay quiet: the account's
  // Push switch is off, or this notification's own topic is (server:
  // preferences.pushNotifications / pushNotificationTypes[type], mirrored
  // into SharedPreferences — a type outside the catalog answers to the
  // master alone), and iOS once FCM is registered — there iOS already draws
  // the server's alert push for this same event, also while the app is open,
  // so this would be a second banner.
  Future<void> _showLiveBanner(Map<String, dynamic> map) async {
    if (FcmService.pushShownNatively) return;
    try {
      if (!await NotificationPrefs.readPushAllowed(
        map['type']?.toString() ?? '',
      )) {
        return;
      }
      await LocalNotifications.showLive(
        // Same id an FCM banner for this notification gets (FcmService
        // derives it from the identical Mongo _id), so if both do show
        // they replace each other instead of stacking.
        id: FcmService.localNotificationId(notificationId: map['_id']?.toString()),
        title: map['title']?.toString() ?? 'Notification',
        body: map['message']?.toString() ?? '',
        payload: encodeNotificationPayload(
          type: map['type']?.toString() ?? '',
          referenceId: map['referenceId']?.toString(),
        ),
      );
    } catch (e, st) {
      debugPrint('NotificationsProvider: live banner failed: $e\n$st');
    }
  }

  void stopListening() {
    _listening = false;
    if (_onNewNotification != null) {
      SocketService.instance.off('new_notification', _onNewNotification);
      _onNewNotification = null;
    }
    if (_onRefreshUnreadCount != null) {
      SocketService.instance.off('refresh_unread_count', _onRefreshUnreadCount);
      _onRefreshUnreadCount = null;
    }
  }

  Future<void> fetchUnreadCount() async {
    try {
      final res = await _dio.get(ApiConstants.notificationsUnreadCount);
      // Unlike almost every other endpoint in this app, this one is NOT
      // wrapped in {isOk, data: ...} — server:
      // notification.controller.js#getUnreadNotificationCount responds
      // with {isOk, unreadCount} directly (same shape the web app's own
      // NotificationBell.jsx reads via res.data.unreadCount). Reading
      // res.data['data'] here (the old code) was always null, so the app
      // bar bell's badge count was silently stuck at 0 no matter how many
      // unread notifications actually existed.
      unreadCount = (res.data['unreadCount'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {
      // Non-critical — badge just won't update this cycle.
    }
  }

  Future<void> fetchNotifications() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.notifications);
      notifications = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NotificationModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      unreadCount = notifications.where((n) => !n.isRead).length;
    } on DioException catch (e) {
      errorMessage = extractErrorMessage(
        e,
        fallback: 'Could not load notifications.',
      );
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> markAsRead(String id) async {
    final index = notifications.indexWhere((n) => n.id == id);
    if (index == -1 || notifications[index].isRead) return;
    notifications[index] = notifications[index].markRead();
    unreadCount = (unreadCount - 1).clamp(0, 1 << 30);
    notifyListeners();
    try {
      await _dio.patch(ApiConstants.notificationRead(id));
    } catch (_) {
      // Best effort — a stale unread flag will self-correct on next fetch.
    }
  }

  Future<void> markAllAsRead() async {
    notifications = notifications.map((n) => n.markRead()).toList();
    unreadCount = 0;
    notifyListeners();
    try {
      await _dio.patch(ApiConstants.notificationsReadAll);
    } catch (_) {
      // Best effort.
    }
  }
}
