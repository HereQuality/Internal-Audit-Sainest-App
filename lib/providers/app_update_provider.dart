import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/app_update_status.dart';

/// Force-update gate — see main.dart's `_RootGate`, which blocks with
/// UpdateRequiredScreen whenever [isForceUpdateRequired] is true, checked
/// BEFORE the auth switch (unlike MaintenanceProvider, this has to apply
/// even on the login screen: an old build may not be able to talk to a
/// changed API contract at all, so there's no "let them log in first"
/// grace period). No role bypass either — unlike maintenance mode, there's
/// no operational reason for a SuperAdmin to keep using an app build
/// that's been declared too old.
///
/// Live-updated via the same "app-update:update" socket push pattern as
/// MaintenanceProvider/AnnouncementProvider (see those files) — EXCEPT
/// while logged out, there's no socket to push through at all (it only
/// connects post-login), which is exactly when someone could be stuck on
/// this gate's own Update Required screen. main.dart's `_RootGate` also
/// re-checks on every app resume for that case; this short poll is just
/// the fallback for whenever neither of those fires (app left open and
/// foregrounded the whole time, no resume event).
class AppUpdateProvider extends ChangeNotifier {
  AppUpdateStatus status = AppUpdateStatus.empty;
  bool loaded = false;

  // Null until the platform channel resolves once at bootstrap — resolving
  // this on every check would be wasteful, and it can never change for the
  // life of the process anyway. Public (read-only) so UpdateRequiredScreen
  // can show "you have X, need Y" instead of just "update required" with
  // no context.
  String? _installedVersion;
  String? get installedVersion => _installedVersion;

  // Per-SESSION only, deliberately NOT persisted to disk — see
  // [isSoftUpdateAvailable]/[dismissSoftUpdate] below. This provider is
  // created once per app PROCESS (main.dart's root MultiProvider) and
  // lives for as long as the process does, so backgrounding the app (home
  // button, app switcher, screen lock) keeps this same instance and this
  // flag alive — dismiss sticks through that. A genuine cold start (swiped
  // away from recents, force-quit, device reboot) creates a brand new
  // instance with this back at false, so the nudge reappears on next open
  // if the update condition still holds. That's intentional: "not now"
  // should hold for the rest of THIS session, not forever.
  bool _softUpdateDismissed = false;

  Timer? _timer;
  static const _pollInterval = Duration(seconds: 30);

  Future<void> bootstrap() async {
    SocketService.instance.on('app-update:update', _onSocketUpdate);

    try {
      final info = await PackageInfo.fromPlatform();
      _installedVersion = info.version;
    } catch (_) {
      // Fail open — see refreshNow below, same reasoning: never let a
      // platform-channel hiccup lock everyone out.
      _installedVersion = null;
    }

    await refreshNow();
    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => refreshNow());
  }

  void _onSocketUpdate(dynamic payload) {
    if (payload is Map) {
      status = AppUpdateStatus.fromJson(Map<String, dynamic>.from(payload));
      loaded = true;
      notifyListeners();
    }
  }

  Future<void> refreshNow() async {
    try {
      final res = await DioClient.instance.dio.get(ApiConstants.appUpdateStatus);
      final data = res.data['data'];
      if (data is Map) {
        status = AppUpdateStatus.fromJson(Map<String, dynamic>.from(data));
      }
    } catch (_) {
      // A failed check must never itself block the app — keep whatever was
      // last known good (defaults to "not required" if this never
      // succeeds at all).
    } finally {
      loaded = true;
      notifyListeners();
    }
  }

  // Only the numeric dot-separated part matters — a plain string compare
  // would put "1.10.0" BELOW "1.9.0" (lexical '1' < '9'... wait, '1'<'9'
  // is true either way, the real trap is "1.2.0" vs "1.10.0": '2' > '1'
  // makes "1.2.0" sort ABOVE "1.10.0" as plain strings, exactly backwards).
  // Compares part-by-part as integers, treating a missing trailing part as
  // 0 (so "1.3" == "1.3.0").
  static int _compareVersions(String a, String b) {
    List<int> parts(String v) => v
        .split('+') // drop a build-number suffix if one sneaks in (e.g. "1.3.0+7")
        .first
        .split('.')
        .map((p) => int.tryParse(p.trim()) ?? 0)
        .toList();
    final pa = parts(a);
    final pb = parts(b);
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final na = i < pa.length ? pa[i] : 0;
      final nb = i < pb.length ? pb[i] : 0;
      if (na != nb) return na.compareTo(nb);
    }
    return 0;
  }

  // Desktop/web builds of this same Flutter project have no app-store
  // version to compare against — this gate only ever applies to Android/
  // iOS installs. One shared `minVersion` for both (see AppUpdateMode.js) —
  // no per-platform split, since Flutter ships a single version number to
  // both stores at once.
  bool get isForceUpdateRequired {
    if (!loaded || !status.isActive || _installedVersion == null) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    final minVersion = status.minVersion;
    if (minVersion.isEmpty) return false;
    return _compareVersions(_installedVersion!, minVersion) < 0;
  }

  // Separate, NON-blocking nudge (see SoftUpdateBanner/SoftUpdateOverlay) —
  // deliberately does NOT gate on `status.isActive` the way
  // isForceUpdateRequired does, since that switch only governs the
  // force-update block; a newer build being merely *available* is
  // independent of whether the old one has been declared unusable. Instead
  // this fires purely off `status.latestVersion` being ahead of what's
  // installed, and is dismissible for the rest of THIS app session only
  // (see [_softUpdateDismissed] above) — reappears on the next full app
  // relaunch if the update still hasn't been installed. Never blocks
  // navigation — unlike the force-update gate, nothing here ever replaces
  // the app's normal screens.
  bool get isSoftUpdateAvailable {
    if (!loaded || _installedVersion == null) return false;
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    if (_softUpdateDismissed) return false;
    final latestVersion = status.latestVersion;
    if (latestVersion.isEmpty) return false;
    return _compareVersions(_installedVersion!, latestVersion) < 0;
  }

  void dismissSoftUpdate() {
    _softUpdateDismissed = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
