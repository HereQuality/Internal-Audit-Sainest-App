/// Mirrors server/controllers/appUpdate.controller.js's `serialize()` shape
/// (GET /app-update/status) and the web app's hooks/useAppUpdate.jsx.
class AppUpdateStatus {
  final bool isActive;
  final String minVersion;
  final String message;
  final DateTime? updatedAt;

  // Plain "major.minor.patch" string, or "" meaning none configured — the
  // soft-update nudge's own target (see AppUpdateProvider.isSoftUpdateAvailable),
  // independent of `isActive`/`minVersion` which only govern the force-update
  // block.
  final String latestVersion;

  // Separate from `message` above — that one is the force-update block
  // screen's own copy. This is the non-blocking soft-update bar's message
  // (see SoftUpdateBanner), since one admin-typed line was never going to
  // read right on both a "you must update" block and a "hey, one's out"
  // nudge.
  final String softMessage;

  const AppUpdateStatus({
    required this.isActive,
    required this.minVersion,
    required this.message,
    required this.latestVersion,
    required this.softMessage,
    this.updatedAt,
  });

  static const empty = AppUpdateStatus(
    isActive: false,
    minVersion: '',
    message: '',
    latestVersion: '',
    softMessage: '',
  );

  factory AppUpdateStatus.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) => value is String ? DateTime.tryParse(value) : null;
    return AppUpdateStatus(
      isActive: json['isActive'] == true,
      minVersion: (json['minVersion'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
      latestVersion: (json['latestVersion'] as String?) ?? '',
      softMessage: (json['softMessage'] as String?) ?? '',
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}
