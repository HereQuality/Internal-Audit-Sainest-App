import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/nc_model.dart';

/// Same two-sided access rule as the web app's NCManagement.jsx (auditor:
/// NCs I raised) and Auditee.jsx (auditee: NCs raised against me) — one
/// person can hold both, each list is independently scoped server-side.
class NcProvider extends ChangeNotifier {
  final Dio _dio = DioClient.instance.dio;

  // "Me" vs "Team" scope for fetchRaisedByMe/fetchAgainstMe below — see
  // widgets/scope_toggle.dart / AuditsProvider/DashboardProvider's identical
  // pattern. Independent of those: neither list is shared with any other
  // screen, so this doesn't need to live anywhere but here. One toggle
  // covers both lists (not a separate one per side) since a single person
  // can appear in both. Defaults true (Team) — matches the web app's
  // TeamFilterPanel, whose own default is "All", not just-yourself.
  bool isTeamScope = true;
  String? _selfEmployeeId;
  Map<String, dynamic>? get _scopeParams => isTeamScope
      ? null
      : (_selfEmployeeId == null ? null : {'employeeIds': _selfEmployeeId});

  void setSelfEmployeeId(String id) {
    _selfEmployeeId = id;
  }

  Future<void> setTeamScope(bool isTeam) {
    isTeamScope = isTeam;
    notifyListeners();
    return Future.wait([fetchRaisedByMe(), fetchAgainstMe()]);
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
        fetchRaisedByMe();
        fetchAgainstMe();
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

  Future<void> fetchRaisedByMe() async {
    isLoadingRaised = true;
    raisedError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsRaised,
        queryParameters: _scopeParams,
      );
      raisedByMe = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      raisedError = extractErrorMessage(
        e,
        fallback: 'Could not load raised NCs.',
      );
    } finally {
      isLoadingRaised = false;
      notifyListeners();
    }
  }

  Future<void> fetchAgainstMe() async {
    isLoadingMine = true;
    mineError = null;
    notifyListeners();
    try {
      final res = await _dio.get(
        ApiConstants.ncsMine,
        queryParameters: _scopeParams,
      );
      raisedAgainstMe = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => NcModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      mineError = extractErrorMessage(e, fallback: 'Could not load your NCs.');
    } finally {
      isLoadingMine = false;
      notifyListeners();
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
  /// falls back to just leaving the notification marked read.
  Future<NcModel?> fetchById(String id) async {
    try {
      final res = await _dio.get(ApiConstants.ncDetail(id));
      final nc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      activeNc = nc;
      notifyListeners();
      return nc;
    } on DioException {
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
      if (currentlyResponseSubmitted) {
        await _dio.post(ApiConstants.ncMoveToVerification(ncId));
      }
      final res = await _dio.post(
        ApiConstants.ncVerify(ncId),
        data: {
          'action': action,
          if (note != null && note.trim().isNotEmpty)
            'verificationNote': note.trim(),
        },
      );
      activeNc = NcModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      notifyListeners();
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update this NC.');
    }
  }
}
