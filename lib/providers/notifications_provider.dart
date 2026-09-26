import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../core/notifications/fcm_service.dart';
import '../core/notifications/local_notifications.dart';
import '../core/notifications/notification_prefs.dart';
import '../models/notification_model.dart';

class NotificationsProvider extends ChangeNotifier with WidgetsBindingObserver {
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
  void Function(dynamic data)? _onSocketConnect;
  // Bumped when the account signs out. A request that was already on the
  // wire for the previous account finds the number changed when it lands
  // and drops its answer, instead of putting that account's list or count
  // back into the provider the next account is looking at.
  int _epoch = 0;

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
    // An event emitted while this phone's socket was down is gone for good
    // (socket.io doesn't replay a room emit), and the FCM banner for it
    // never touches this provider — so on every (re)connect, and when the
    // app comes back to the foreground, what the badge and a loaded list
    // hold may be behind the server.
    _onSocketConnect = (_) => _catchUp();
    SocketService.instance.on('new_notification', _onNewNotification!);
    SocketService.instance.on('refresh_unread_count', _onRefreshUnreadCount!);
    SocketService.instance.on('connect', _onSocketConnect!);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _catchUp();
  }

  void _catchUp() {
    unawaited(fetchUnreadCount());
    // Only a list somebody already loaded: it is what would show stale rows.
    if (notifications.isNotEmpty) unawaited(fetchNotifications());
  }

  // Real-time heads-up, on top of the badge, for the moments FCM can't cover
  // on its own: it is what draws an event while the app is open on a phone
  // the server can't push to, and the fast path on Android (the data push
  // follows a second or two later and finds the ledger already claimed).
  // Quiet when the account's Push switch is off or this notification's own
  // topic is (server: preferences.pushNotifications /
  // pushNotificationTypes[type], mirrored into SharedPreferences — a type
  // outside the catalog answers to the master alone).
  //
  // iOS draws the server's alert push itself, also while the app is open, so
  // a second banner from here would double it. It does NOT assume that
  // happens just because a token is registered: it waits for FCM's own
  // foreground callback to say the OS drew this one
  // ([FcmService.awaitNativeAlert]) and only when none arrives draws its own
  // — a phone whose APNs setup is broken still gets a banner while the app is
  // open instead of nothing. With the app in the background iOS draws it
  // natively and no Dart code runs for it, so there is nothing to add and
  // this stays quiet (a banner from a socket that outlived the foreground
  // would repeat the OS's).
  Future<void> _showLiveBanner(Map<String, dynamic> map) async {
    try {
      final type = map['type']?.toString() ?? '';
      if (!await NotificationPrefs.readPushAllowed(type)) return;
      final notificationId = map['_id']?.toString();
      if (defaultTargetPlatform == TargetPlatform.iOS && await NotificationPrefs.readFcmPushReady()) {
        if (!_inForeground) return;
        if (await FcmService.awaitNativeAlert(notificationId)) return;
        if (!_inForeground) return;
      }
      await LocalNotifications.showServerBanner(
        notificationId: notificationId,
        type: type,
        referenceId: map['referenceId']?.toString(),
        title: map['title']?.toString() ?? 'Notification',
        body: map['message']?.toString() ?? '',
      );
    } catch (e, st) {
      debugPrint('NotificationsProvider: live banner failed: $e\n$st');
    }
  }

  bool get _inForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void stopListening() {
    _listening = false;
    WidgetsBinding.instance.removeObserver(this);
    if (_onSocketConnect != null) {
      SocketService.instance.off('connect', _onSocketConnect);
      _onSocketConnect = null;
    }
    if (_onNewNotification != null) {
      SocketService.instance.off('new_notification', _onNewNotification);
      _onNewNotification = null;
    }
    if (_onRefreshUnreadCount != null) {
      SocketService.instance.off('refresh_unread_count', _onRefreshUnreadCount);
      _onRefreshUnreadCount = null;
    }
  }

  /// Back to empty — call on logout. This provider is a single, process-
  /// lifetime instance (main.dart's root MultiProvider), so without this the
  /// NEXT person to sign in on the same phone would see the previous
  /// account's notification titles and unread count until their own first
  /// fetch lands (and, if that fails, for good: the screen only shows a
  /// loader or an error when the list is empty). Also stops listening, so
  /// the next sign-in's AppShell attaches to ITS socket.
  void resetForLogout() {
    stopListening();
    _epoch++;
    notifications = [];
    unreadCount = 0;
    errorMessage = null;
    isLoading = false;
    notifyListeners();
  }

  Future<void> fetchUnreadCount() async {
    final epoch = _epoch;
    try {
      final res = await _dio.get(ApiConstants.notificationsUnreadCount);
      if (epoch != _epoch) return;
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
    final epoch = _epoch;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.notifications);
      if (epoch != _epoch) return;
      notifications = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NotificationModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      unreadCount = notifications.where((n) => !n.isRead).length;
    } on DioException catch (e) {
      if (epoch == _epoch) {
        errorMessage = extractErrorMessage(
          e,
          fallback: 'Could not load notifications.',
        );
      }
    } finally {
      if (epoch == _epoch) {
        isLoading = false;
        notifyListeners();
      }
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
