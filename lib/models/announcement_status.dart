/// Mirrors server/controllers/announcement.controller.js's `serialize()`
/// shape (GET /announcement/status) and the web app's
/// hooks/useAnnouncement.jsx.
class AnnouncementStatus {
  final bool isActive;
  final String message;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? updatedAt;
  final bool isLive;

  const AnnouncementStatus({
    required this.isActive,
    required this.message,
    this.startDate,
    this.endDate,
    this.updatedAt,
    required this.isLive,
  });

  static const empty = AnnouncementStatus(isActive: false, message: '', isLive: false);

  factory AnnouncementStatus.fromJson(Map<String, dynamic> json) {
    DateTime? parseDate(dynamic value) => value is String ? DateTime.tryParse(value) : null;
    return AnnouncementStatus(
      isActive: json['isActive'] == true,
      message: (json['message'] as String?) ?? '',
      startDate: parseDate(json['startDate']),
      endDate: parseDate(json['endDate']),
      updatedAt: parseDate(json['updatedAt']),
      isLive: json['isLive'] == true,
    );
  }
}
