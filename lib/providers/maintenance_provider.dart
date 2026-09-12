import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/maintenance_status.dart';

/// Live-updated via the same "maintenance:update" socket push the web app
/// uses (see server/controllers/maintenance.controller.js's `io.emit` and
/// the web app's hooks/useMaintenance.jsx counterpart this mirrors).
/// SocketService now queues a listener registered before login and
/// replays it once connect() actually creates the socket, so this no
/// longer needs a short poll to cover that ordering gap — Timer.periodic
/// below is just the same fallback role the web hook's refetchInterval
/// plays for a visitor whose socket isn't connected (offline tablet,
/// dropped connection, pre-login screen with no push yet at all).
class MaintenanceProvider extends ChangeNotifier {
  MaintenanceStatus status = MaintenanceStatus.empty;
  bool loaded = false;

  Timer? _timer;
  static const _pollInterval = Duration(minutes: 5);

  Future<void> bootstrap() async {
    SocketService.instance.on('maintenance:update', _onSocketUpdate);
    await refreshNow();
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => refreshNow());
  }

  void _onSocketUpdate(dynamic payload) {
    if (payload is Map) {
      status = MaintenanceStatus.fromJson(Map<String, dynamic>.from(payload));
      loaded = true;
      notifyListeners();
    }
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
