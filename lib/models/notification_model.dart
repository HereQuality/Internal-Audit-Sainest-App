class NotificationModel {
  final String id;
  final String title;
  final String message;
  final String type;
  final bool isRead;
  final DateTime? createdAt;
  // What this notification is about — an audit id for every "audit_*"
  // type, an NC id for every "nc_*" type (see server/services/notification
  // .service.js's callers in audit.controller.js/nc.controller.js). Lets
  // tapping a notification jump straight to the thing it's about instead
  // of just marking it read (see notifications_screen.dart).
  final String? referenceId;

  const NotificationModel({
    required this.id,
    required this.title,
    required this.message,
    required this.type,
    required this.isRead,
    this.createdAt,
    this.referenceId,
  });

  factory NotificationModel.fromJson(Map<String, dynamic> json) {
    final ref = json['referenceId'];
    return NotificationModel(
      id: (json['_id'] ?? json['id'] ?? '').toString(),
      title: json['title']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      type: json['type']?.toString() ?? 'general',
      isRead: json['isRead'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      referenceId: (ref is Map ? ref['_id'] : ref)?.toString(),
    );
  }

  NotificationModel markRead() => NotificationModel(
        id: id,
        title: title,
        message: message,
        type: type,
        isRead: true,
        createdAt: createdAt,
        referenceId: referenceId,
      );
}
