import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/audit_model.dart';
import '../models/auditee_stats_model.dart';
import 'audit_filter_scope.dart';

class DashboardProvider extends ChangeNotifier with AuditFilterScope {
  final Dio _dio = DioClient.instance.dio;

  // "Me" vs "Team" scope for the auditor stat tallies + ATS/OTC score below
  // (see widgets/scope_toggle.dart) — Me sends an explicit
  // employeeIds=<selfId> to narrow down to just the caller; Team sends no
  // employeeIds param at all so the server falls back to its own default
  // (self + downstream hierarchy, see resolveScopedEmployeeIds). Remembered
  // here (not just passed per-call) so a live-refresh/pull-to-refresh
  // triggered from elsewhere reuses whatever the user last picked instead
  // of silently reverting to the default.
  //
  // Defaults FALSE (Me) — see AuditsProvider's identical field for the
  // reasoning and for the _selfEmployeeId-must-be-set-first caveat. This
  // now MATCHES the web app's own default (client/src/hooks/useSelfScope.js
  // — TeamFilterPanel opens on "just you" too), so a not-yet-toggled ATS/
  // OTC score reads the same on both platforms for the same account — a Full
  // Access account included, whose All Members default (AuditFilterScope.
  // defaultTeamScope, adopted by main.dart's _RootGate) the web has too.
  @override
  bool isTeamScope = false;
  String? _selfEmployeeId;
  @override
  String? get selfEmployeeId => _selfEmployeeId;

  /// Call once the logged-in user's id is known (DashboardScreen's
  /// initState) — idempotent, safe to call on every build.
  void setSelfEmployeeId(String id) {
    _selfEmployeeId = id;
  }

  /// Flips the Me/Team toggle and refetches everything this scope affects —
  /// both dashboards share this one flag (only one is ever mounted at a
  /// time per AppMode), so refetch whichever of stats/auditeeStats this
  /// scope actually feeds rather than guessing which screen called this.
  Future<void> setTeamScope(bool isTeam) {
    isTeamScope = isTeam;
    notifyListeners();
    return refetchForFilters();
  }

  @override
  Future<void> refetchForFilters() => refreshAll();

  bool isLoading = false;
  String? errorMessage;
  // Also carries this auditor's own ATS/OTC (auditAtsScore/auditOtcScore) —
  // same GET /audits/auditor-stats response the web app's
  // AuditorDashboard.jsx#loadStats reads for its Performance Scorecard, so
  // that scorecard and this one stay driven by the same source instead of
  // drifting apart under separate loading/error state.
  AuditorStats stats = const AuditorStats();

  bool isLoadingAuditee = false;
  String? auditeeErrorMessage;
  AuditeeStats auditeeStats = const AuditeeStats();

  // Bumped on logout — see resetForLogout. A fetch that started under an
  // earlier value writes nothing when it lands (answer, error or loading flag).
  int _epoch = 0;

  // Per-call sequence numbers — see AuditsProvider: only the newest call of
  // each fetch may write, so two quick filter changes can't leave the older
  // answer on screen.
  int _statsSeq = 0;
  int _auditeeSeq = 0;

  /// True once a stats answer has landed — lets the screen show its full-page
  /// loader only for the very first load, not on every refresh (which would
  /// rebuild the page and lose the scroll position).
  bool hasLoadedStats = false;

  /// Empties everything this provider holds and puts the filters back to
  /// their defaults — call on logout, without refetching. The stat tiles
  /// (assigned/in-progress counts, ATS/OTC score, auditee tallies) are the
  /// previous account's numbers; a shared phone's next login must not show
  /// them while its own fetch is in flight, and a fetch that was already on
  /// the wire for the previous account drops its answer ([_epoch]). The self
  /// id goes too: a SuperAdmin never gets one set (main.dart's _RootGate), so
  /// it would otherwise keep filtering by the previous employee.
  @override
  void resetForLogout() {
    stopListening();
    _epoch++;
    _selfEmployeeId = null;
    stats = const AuditorStats();
    hasLoadedStats = false;
    auditeeStats = const AuditeeStats();
    errorMessage = null;
    auditeeErrorMessage = null;
    isLoading = false;
    isLoadingAuditee = false;
    super.resetForLogout();
  }

  bool _listening = false;
  // Stored so stopListening removes exactly this closure — Notifications-
  // Provider/AuditsProvider/NcProvider also register their own
  // 'new_notification' handler, and socket_io_client's off(event) with no
  // handler removes EVERY listener for that event, not just the caller's own.
  void Function(dynamic data)? _onNewNotification;

  /// Wires a socket listener once, after login — mirrors AuditsProvider/
  /// NcProvider.startListening(). Unlike those, this screen previously had
  /// NO live-refresh path at all: fetchStats/fetchAuditeeStats only ever ran
  /// once on first visit (DashboardScreen's initState) or on a manual
  /// pull-to-refresh, so the stat tiles (Assigned/In Progress/NC Pending/
  /// Completed, ATS/OTC score, auditee tallies) sat stale until the app was
  /// reloaded — even though the underlying data had changed. Any
  /// `audit_*`/`nc_*` notification means one of these tallies may have
  /// moved, so just refetch both; each is a cheap GET and mode-agnostic
  /// (same "always listen regardless of current AppMode" the other
  /// providers already do) rather than trying to guess which of the
  /// auditor/auditee tiles is currently on screen.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map) {
        final type = data['type']?.toString() ?? '';
        if (type.startsWith('audit_') || type.startsWith('nc_')) {
          // A burst of notifications refetches once, not once each.
          _refreshTimer?.cancel();
          _refreshTimer = Timer(const Duration(milliseconds: 500), refreshAll);
        }
      }
    };
    SocketService.instance.on('new_notification', _onNewNotification!);
  }

  Timer? _refreshTimer;

  void stopListening() {
    _refreshTimer?.cancel();
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
      Future.wait([fetchStats(), fetchAuditeeStats()]);

  /// What GET /ncs/ats-summary takes: every shared filter plus the NC flag.
  /// The location facet used to be dropped here because that endpoint let a
  /// location REPLACE the employee scoping ("Me + Zone A" quietly became
  /// everyone's NCs in Zone A); the server now ANDs the place with the person
  /// scope (nc.controller.js#buildNcBaseQuery), so it is safe — and needed for
  /// the tiles to match the NC list — to send it.
  Map<String, dynamic>? get _ncSummaryParams => ncFilterParams;

  Future<void> fetchStats() async {
    final epoch = _epoch;
    final seq = ++_statsSeq;
    bool stale() => epoch != _epoch || seq != _statsSeq;
    isLoading = true;
    errorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.auditorStats,
        queryParameters: filterParams,
      );
      if (stale()) return;
      stats = AuditorStats.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
      hasLoadedStats = true;
    } on DioException catch (e) {
      if (!stale()) {
        errorMessage = extractErrorMessage(
          e,
          fallback: 'Could not load dashboard stats.',
        );
      }
    } catch (e, st) {
      debugPrint('DashboardProvider.fetchStats: unreadable answer: $e\n$st');
      if (!stale()) errorMessage = 'Could not load dashboard stats.';
    } finally {
      if (!stale()) {
        isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Auditee-side tallies (Total/On Time/In Progress/Pending Approval/
  /// Overdue/Delayed NCs) — a separate stats source from fetchStats above,
  /// which is auditor-only data (assigned audits, in-progress audits) and
  /// means nothing to someone viewing the app as an auditee.
  Future<void> fetchAuditeeStats() async {
    final epoch = _epoch;
    final seq = ++_auditeeSeq;
    bool stale() => epoch != _epoch || seq != _auditeeSeq;
    isLoadingAuditee = true;
    auditeeErrorMessage = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsAtsSummary,
        queryParameters: _ncSummaryParams,
      );
      if (stale()) return;
      auditeeStats = AuditeeStats.fromJson(
        Map<String, dynamic>.from(res.data['data']),
      );
    } on DioException catch (e) {
      if (!stale()) {
        auditeeErrorMessage = extractErrorMessage(
          e,
          fallback: 'Could not load your NC summary.',
        );
      }
    } catch (e, st) {
      debugPrint('DashboardProvider.fetchAuditeeStats: unreadable answer: $e\n$st');
      if (!stale()) auditeeErrorMessage = 'Could not load your NC summary.';
    } finally {
      if (!stale()) {
        isLoadingAuditee = false;
        notifyListeners();
      }
    }
  }
}
