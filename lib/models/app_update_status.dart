/// Mirrors server/controllers/appUpdate.controller.js's `serialize()` shape
/// (GET /app-update/status) and the web app's hooks/useAppUpdate.jsx.
class AppUpdateStatus {
  final bool isActive;
  final String minVersion;
  final String message;
  final DateTime? updatedAt;

  const AppUpdateStatus({
    required this.isActive,
    required this.minVersion,
    required this.message,
    this.updatedAt,
  });

  static const empty = AppUpdateStatus(
    isActive: false,
    minVersion: '',
    message: '',
  );

  factory AppUpdateStatus.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) => value is String ? DateTime.tryParse(value) : null;
    return AppUpdateStatus(
      isActive: json['isActive'] == true,
      minVersion: (json['minVersion'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}
