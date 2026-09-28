import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/nc_model.dart';
import 'audit_filter_scope.dart';

/// Same two-sided access rule as the web app's NCManagement.jsx (auditor:
/// NCs I raised) and Auditee.jsx (auditee: NCs raised against me) — one
/// person can hold both, each list is independently scoped server-side.
class NcProvider extends ChangeNotifier with AuditFilterScope {
  final Dio _dio = DioClient.instance.dio;

  // The same shared filter state as AuditsProvider/DashboardProvider
  // (AuditFilterScope): Me / All Members, Team, Members, Location +
  // Department, Audit Type, Date range and Flag all narrow both NC lists
  // below. The NC endpoints AND the place with the person scope (an NC row
  // must be in the requester's own scope AND at the picked place), so the
  // location filter is safe to send here now. One state covers both lists
  // (not a separate one per side) since a single person can appear in both.
  // Defaults FALSE (Me) — see AuditsProvider's identical field for the
  // reasoning and for the _selfEmployeeId-must-be-set-first caveat.
  @override
  bool isTeamScope = false;
  String? _selfEmployeeId;
  @override
  String? get selfEmployeeId => _selfEmployeeId;

  void setSelfEmployeeId(String id) {
    _selfEmployeeId = id;
  }

  Future<void> setTeamScope(bool isTeam) {
    isTeamScope = isTeam;
    notifyListeners();
    return refetchForFilters();
  }

  @override
  Future<void> refetchForFilters() =>
      Future.wait([fetchRaisedByMe(), fetchAgainstMe()]);

  // Bumped on logout: a fetch already on the wire for the previous account
  // finds the number changed when it lands and drops its answer — its error
  // and its loading flag too — instead of putting that account's NCs back
  // after the reset or ending the next account's own loading state.
  int _epoch = 0;

  // Per-call sequence numbers: two quick filter changes put two requests on
  // the wire, and the older answer may land last — only the newest call of
  // each fetch may write its result, error or loading flag.
  int _raisedSeq = 0;
  int _mineSeq = 0;

  // NCs whose move-to-Verification already succeeded but whose verify did not
  // — a retry must go straight to verify (moving again is a 400).
  final Set<String> _movedToVerification = {};

  /// Back to the Me default and empty, without refetching — call on logout.
  /// See AuditFilterScope.resetForLogout's doc for why this matters on a
  /// shared device: every provider here is a single, process-lifetime
  /// instance, so without this the NEXT person to log in would inherit
  /// whichever scope the PREVIOUS account left this on — and see that
  /// account's NC lists until their own fetch lands. The self id goes too: a
  /// SuperAdmin never gets one set (main.dart's _RootGate), so it would
  /// otherwise keep filtering by the previous employee.
  @override
  void resetForLogout() {
    stopListening();
    _epoch++;
    _selfEmployeeId = null;
    raisedByMe = [];
    raisedAgainstMe = [];
    activeNc = null;
    _movedToVerification.clear();
    raisedError = null;
    mineError = null;
    isLoadingRaised = false;
    isLoadingMine = false;
    isLoadingDetail = false;
    // Filters back to the Me default (also notifies).
    super.resetForLogout();
  }

  bool isLoadingRaised = false;
  String? raisedError;
  List<NcModel> raisedByMe = [];

  bool isLoadingMine = false;
  String? mineError;
  List<NcModel> raisedAgainstMe = [];

  bool isLoadingDetail = false;
  NcModel? activeNc;

  bool _listening = false;
  // Stored so stopListening removes exactly this closure — Notifications
  // Provider and AuditsProvider also register their own 'new_notification'
  // handler, and socket_io_client's off(event) with no handler removes
  // EVERY listener for that event, not just the caller's own.
  void Function(dynamic data)? _onNewNotification;

  /// Wires a socket listener once, after login — mirrors
  /// NotificationsProvider.startListening(). Any `nc_*` event (raised,
  /// responded, approved, rejected) refetches both lists so a screen
  /// showing them reflects the change live, without a manual pull-to-refresh.
  void startListening() {
    if (_listening) return;
    _listening = true;
    _onNewNotification = (data) {
      if (data is Map && (data['type']?.toString() ?? '').startsWith('nc_')) {
        // A burst of notifications refetches once, not once each.
        _refreshTimer?.cancel();
        _refreshTimer = Timer(const Duration(milliseconds: 500), () {
          fetchRaisedByMe();
          fetchAgainstMe();
        });
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

  Future<void> fetchRaisedByMe() async {
    final epoch = _epoch;
    final seq = ++_raisedSeq;
    bool stale() => epoch != _epoch || seq != _raisedSeq;
    isLoadingRaised = true;
    raisedError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsRaised,
        queryParameters: ncFilterParams,
      );
      if (stale()) return;
      raisedByMe = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      if (!stale()) {
        raisedError = extractErrorMessage(
          e,
          fallback: 'Could not load raised NCs.',
        );
      }
    } catch (e, st) {
      // An answer the models cannot read must end the loading state and say so,
      // not escape as an unhandled error from a fire-and-forget refetch.
      debugPrint('NcProvider.fetchRaisedByMe: unreadable answer: $e\n$st');
      if (!stale()) raisedError = 'Could not load raised NCs.';
    } finally {
      if (!stale()) {
        isLoadingRaised = false;
        notifyListeners();
      }
    }
  }

  Future<void> fetchAgainstMe() async {
    final epoch = _epoch;
    final seq = ++_mineSeq;
    bool stale() => epoch != _epoch || seq != _mineSeq;
    isLoadingMine = true;
    mineError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsMine,
        queryParameters: ncFilterParams,
      );
      if (stale()) return;
      raisedAgainstMe = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      if (!stale()) {
        mineError = extractErrorMessage(e, fallback: 'Could not load your NCs.');
      }
    } catch (e, st) {
      debugPrint('NcProvider.fetchAgainstMe: unreadable answer: $e\n$st');
      if (!stale()) mineError = 'Could not load your NCs.';
    } finally {
      if (!stale()) {
        isLoadingMine = false;
        notifyListeners();
      }
    }
  }

  void setActive(NcModel nc) {
    activeNc = nc;
    notifyListeners();
  }

  /// GET /ncs/:id — resolves a single NC by id without needing it to
  /// already be sitting in raisedByMe/raisedAgainstMe. Used to turn a
  /// notification's referenceId (nc.controller.js's nc_raised/nc_approved/
  /// nc_rejected types) into a full NcModel to navigate to (see
  /// notifications_screen.dart). Returns null on failure — the caller
  /// falls back to just leaving the notification marked read — which is also
  /// what an answer that outlived its account gets: null, and no state written.
  Future<NcModel?> fetchById(String id) async {
    final epoch = _epoch;
    try {
      final res = await _dio.get(ApiConstants.ncDetail(id));
      if (epoch != _epoch) return null;
      final nc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      activeNc = nc;
      notifyListeners();
      return nc;
    } on DioException {
      return null;
    } catch (e, st) {
      debugPrint('NcProvider.fetchById: unreadable answer: $e\n$st');
      return null;
    }
  }

  void clearActive() {
    activeNc = null;
  }

  /// Auditee: submit the 4-field corrective-action response (+ optional
  /// photos) — server appends this as a new responseHistory entry
  /// (cycle = reopenCount+1), see nc.controller.js#respondToNC.
  Future<String?> respond({
    required String ncId,
    required String correctionAction,
    required String rootCause,
    required String correctiveAction,
    required String preventiveAction,
    List<File> photos = const [],
    List<String> keepPhotoUrls = const [],
  }) async {
    try {
      // Files are added to form.files below, not via fromMap — a Dart map
      // literal silently collapses duplicate 'photos' keys to the last
      // one, uploading only the last picked photo (see audits_provider.dart).
      // Same reasoning applies to keepPhotoUrls below.
      final form = FormData.fromMap({
        'correctionAction': correctionAction,
        'rootCause': rootCause,
        'correctiveAction': correctiveAction,
        'preventiveAction': preventiveAction,
      });
      for (final file in photos) {
        form.files.add(
          MapEntry(
            'photos',
            await MultipartFile.fromFile(
              file.path,
              filename: file.path.split('/').last,
            ),
          ),
        );
      }
      // Evidence photos carried over from a previous (rejected) attempt
      // that the auditee kept as-is rather than re-uploading — server only
      // honors URLs already on this NC (nc.controller.js#respondToNC).
      for (final url in keepPhotoUrls) {
        form.fields.add(MapEntry('keepPhotoUrls', url));
      }
      final res = await _dio.post(ApiConstants.ncRespond(ncId), data: form);
      activeNc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      notifyListeners();
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(
        e,
        fallback: 'Could not submit your response.',
      );
    } catch (e, st) {
      // A photo that can no longer be read, or a saved-but-unreadable answer:
      // the person still needs to hear the outcome, not be left on a spinner.
      debugPrint('NcProvider.respond failed: $e\n$st');
      return 'Could not submit your response.';
    }
  }

  /// Auditor: approve (closes + scores) or reject (mandatory remark, back
  /// to Raised) — moves a still-"Response Submitted" NC into Verification
  /// first if needed, same as the web review thread does.
  Future<String?> verify({
    required String ncId,
    required bool currentlyResponseSubmitted,
    required String action,
    String? note,
  }) async {
    if (action == 'Reject' && (note == null || note.trim().isEmpty)) {
      return 'A remark is required when rejecting.';
    }
    try {
      if (currentlyResponseSubmitted && !_movedToVerification.contains(ncId)) {
        await _dio.post(ApiConstants.ncMoveToVerification(ncId));
        _movedToVerification.add(ncId);
      }
      final res = await _dio.post(
        ApiConstants.ncVerify(ncId),
        data: {
          'action': action,
          if (note != null && note.trim().isNotEmpty)
            'verificationNote': note.trim(),
        },
      );
      _movedToVerification.remove(ncId);
      activeNc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      notifyListeners();
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update this NC.');
    } catch (e, st) {
      debugPrint('NcProvider.verify failed: $e\n$st');
      return 'Could not update this NC.';
    }
  }
}
