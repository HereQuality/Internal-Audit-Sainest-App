import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../models/announcement_status.dart';

/// Foreground-only poll for Announcement Mode (see
/// server/models/AnnouncementMode.js and the web app's
/// hooks/useAnnouncement.jsx counterpart this mirrors) — same
/// no-socket-listener reasoning as MaintenanceProvider, which this is a
/// near-duplicate of: SocketService only connects post-login, so wiring a
/// "announcement:update" listener here before that would silently never
/// attach.
class AnnouncementProvider extends ChangeNotifier {
  AnnouncementStatus status = AnnouncementStatus.empty;
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
