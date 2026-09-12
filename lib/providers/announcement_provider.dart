import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/announcement_status.dart';

/// Live-updated via the same "announcement:update" socket push the web
/// app uses (see server/controllers/announcement.controller.js's
/// `io.emit` and hooks/useAnnouncement.jsx) — near-duplicate of
/// MaintenanceProvider, see that file for why the fallback poll below can
/// now be long instead of short.
class AnnouncementProvider extends ChangeNotifier {
  AnnouncementStatus status = AnnouncementStatus.empty;
  bool loaded = false;

  Timer? _timer;
  static const _pollInterval = Duration(minutes: 5);

  Future<void> bootstrap() async {
    SocketService.instance.on('announcement:update', _onSocketUpdate);
    await refreshNow();
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => refreshNow());
  }

  void _onSocketUpdate(dynamic payload) {
    if (payload is Map) {
      status = AnnouncementStatus.fromJson(Map<String, dynamic>.from(payload));
      loaded = true;
      notifyListeners();
    }
  }

  Future<void> refreshNow() async {
    try {
      final res = await DioClient.instance.dio.get(ApiConstants.announcementStatus);
      final data = res.data['data'];
      if (data is Map) {
        status = AnnouncementStatus.fromJson(Map<String, dynamic>.from(data));
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
