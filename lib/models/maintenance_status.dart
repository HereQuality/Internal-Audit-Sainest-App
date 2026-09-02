/// Mirrors server/models/MaintenanceMode.js's serialized shape (GET
/// /maintenance/status) and the web app's hooks/useMaintenance.jsx.
class MaintenanceStatus {
  final bool isActive;
  final String message;
  final DateTime? scheduledAt;
  final DateTime? updatedAt;

  const MaintenanceStatus({
    required this.isActive,
    required this.message,
    this.scheduledAt,
    this.updatedAt,
  });

  static const empty = MaintenanceStatus(isActive: false, message: '');

  factory MaintenanceStatus.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) => value is String ? DateTime.tryParse(value) : null;
    return MaintenanceStatus(
      isActive: json['isActive'] == true,
      message: (json['message'] as String?) ?? '',
      scheduledAt: parseDate(json['scheduledAt']),
      updatedAt: parseDate(json['updatedAt']),
    );
  }
}
