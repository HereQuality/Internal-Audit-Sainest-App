import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../models/maintenance_status.dart';

/// Foreground-only poll for the site-wide maintenance kill-switch +
/// scheduled-maintenance announcement (see server/models/MaintenanceMode.js
/// and the web app's hooks/useMaintenance.jsx for the counterpart this
/// mirrors). A plain Timer.periodic is enough here — unlike the overdue-NC
/// background poll (core/notifications/), this only ever needs to matter
/// while the app is actually open in the foreground; see NOTIFICATIONS.md
/// for why that heavier AlarmManager/foreground-service pipeline exists
/// and why this one deliberately doesn't need any of it.
///
/// No socket push for this one (unlike the web app's instant
/// "maintenance:update" listener) — SocketService.instance.connect() only
/// happens once AuthProvider finishes logging in, and registering a
/// listener here before that connection exists would silently never
/// attach (SocketService.on is a no-op until `_socket` is non-null, with
/// no queueing). The poll interval below is short enough that this isn't
/// a meaningful gap.
class MaintenanceProvider extends ChangeNotifier {
  MaintenanceStatus status = MaintenanceStatus.empty;
  bool loaded = false;

  Timer? _timer;
  static const _pollInterval = Duration(seconds: 30);

  Future<void> bootstrap() async {
    await refreshNow();
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => refreshNow());
  }

  Future<void> refreshNow() async {
    try {
      final res = await DioClient.instance.dio.get(ApiConstants.maintenanceStatus);
      final data = res.data['data'];
      if (data is Map) {
        status = MaintenanceStatus.fromJson(Map<String, dynamic>.from(data));
      }
    } catch (_) {
      // Fail open — a network hiccup here must never itself block the
      // app; just keep serving whatever `status` was last known good.
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
