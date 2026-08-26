import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/audit_model.dart';
import '../models/auditee_stats_model.dart';

class DashboardProvider extends ChangeNotifier {
  final Dio _dio = DioClient.instance.dio;

  // "Me" vs "Team" scope for the auditor stat tallies + ATS/OTC score below
  // (see widgets/scope_toggle.dart) — Me by default, i.e. an explicit
  // employeeIds=<selfId> query param; Team omits the param entirely so the
  // server falls back to its own default (self + downstream hierarchy, see
  // resolveScopedEmployeeIds). Remembered here (not just passed per-call)
  // so a live-refresh/pull-to-refresh triggered from elsewhere reuses
  // whatever the user last picked instead of silently reverting to Me.
  bool isTeamScope = false;
  String? _selfEmployeeId;
  Map<String, dynamic>? get _scopeParams => isTeamScope
      ? null
      : (_selfEmployeeId == null ? null : {'employeeIds': _selfEmployeeId});

  /// Call once the logged-in user's id is known (DashboardScreen's
  /// initState) — idempotent, safe to call on every build.
  void setSelfEmployeeId(String id) {
    _selfEmployeeId = id;
  }

  /// Flips the Me/Team toggle and refetches everything this scope affects.
  Future<void> setTeamScope(bool isTeam) {
    isTeamScope = isTeam;
    notifyListeners();
    return Future.wait([fetchStats(), fetchAtsSummary()]);
  }

  bool isLoading = false;
  String? errorMessage;
  AuditorStats stats = const AuditorStats();

  bool isLoadingAuditee = false;
  String? auditeeErrorMessage;
  AuditeeStats auditeeStats = const AuditeeStats();

  bool isLoadingAts = false;
  String? atsErrorMessage;
  // Reuses AuditeeStats — same GET /ncs/ats-summary response shape (score/
  // atsScore/otcScore + buckets), just scoped to the auditor's own team
  // (self + downstream hierarchy, resolveScopedEmployeeIds' default with no
  // employeeIds param — same "all" scope TeamFilterPanel defaults to on the
  // web app's AuditorDashboard.jsx) instead of the auditee themself.
  AuditeeStats atsSummary = const AuditeeStats();

  bool _listening = false;
  // Stored so stopListening removes exactly this closure — Notifications-
  // Provider/AuditsProvider/NcProvider also register their own
  // 'new_notification' handler, and socket_io_client's off(event) with no
  // handler removes EVERY listener for that event, not just the caller's own.
  void Function(dynamic data)? _onNewNotification;

  /// Wires a socket listener once, after login — mirrors AuditsProvider/
  /// NcProvider.startListening(). Unlike those, this screen previously had
  /// NO live-refresh path at all: fetchStats/fetchAuditeeStats/
  /// fetchAtsSummary only ever ran once on first visit (DashboardScreen's
  /// initState) or on a manual pull-to-refresh, so the stat tiles (Assigned/
  /// In Progress/NC Pending/Completed, ATS/OTC score, auditee tallies) sat
  /// stale until the app was reloaded — even though the underlying data had
  /// changed. Any `audit_*`/`nc_*` notification means one of these tallies
  /// may have moved, so just refetch all three; each is a cheap GET and
  /// mode-agnostic (same "always listen regardless of current AppMode" the
  /// other providers already do) rather than trying to guess which of the
  /// auditor/auditee tiles is currently on screen.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map) {
        final type = data['type']?.toString() ?? '';
        if (type.startsWith('audit_') || type.startsWith('nc_')) {
          refreshAll();
        }
      }
    };
    SocketService.instance.on('new_notification', _onNewNotification!);
  }

  void stopListening() {
    _listening = false;
    if (_onNewNotification != null) {
      SocketService.instance.off('new_notification', _onNewNotification);
      _onNewNotification = null;
    }
  }

  /// Refetches every stat source this provider owns — used by the socket
  /// listener above, and by screens right after an action they took
  /// themselves changes a status (complete/submit an audit, raise/respond/
  /// verify an NC): the socket-driven refetch only fires for the OTHER
  /// party's notification, never the actor's own, so those call sites need
  /// this to reflect their own change immediately instead of waiting on a
  /// manual pull-to-refresh. Each sub-fetch already catches its own
  /// DioException and records it on its own error field, so this never
  /// throws.
  Future<void> refreshAll() =>
      Future.wait([fetchStats(), fetchAuditeeStats(), fetchAtsSummary()]);

  Future<void> fetchStats() async {
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.auditorStats,
        queryParameters: _scopeParams,
      );
      stats = AuditorStats.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      errorMessage = extractErrorMessage(
        e,
        fallback: 'Could not load dashboard stats.',
      );
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Auditee-side tallies (Total/On Time/In Progress/Pending Approval/
  /// Overdue/Delayed NCs) — a separate stats source from fetchStats above,
  /// which is auditor-only data (assigned audits, in-progress audits) and
  /// means nothing to someone viewing the app as an auditee.
  Future<void> fetchAuditeeStats() async {
    isLoadingAuditee = true;
    auditeeErrorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.ncsAtsSummary);
      auditeeStats = AuditeeStats.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      auditeeErrorMessage = extractErrorMessage(
        e,
        fallback: 'Could not load your NC summary.',
      );
    } finally {
      isLoadingAuditee = false;
      notifyListeners();
    }
  }

  /// Auditor-side ATS/OTC score row (mirrors web's AuditorDashboard.jsx
  /// #loadStats -> getAtsSummary(scope)) — a secondary metric alongside the
  /// audit tallies from fetchStats above, so its own error is tracked
  /// separately and never blocks the main stats grid from rendering.
  Future<void> fetchAtsSummary() async {
    isLoadingAts = true;
    atsErrorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsAtsSummary,
        queryParameters: _scopeParams,
      );
      atsSummary = AuditeeStats.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      atsErrorMessage = extractErrorMessage(
        e,
        fallback: 'Could not load ATS/OTC score.',
      );
    } finally {
      isLoadingAts = false;
      notifyListeners();
    }
  }
}
