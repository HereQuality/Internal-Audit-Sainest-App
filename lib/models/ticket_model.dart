class TicketMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String message;
  final List<String> attachments;
  final bool isRead;
  final bool isSystem;
  final DateTime? createdAt;

  const TicketMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.message,
    this.attachments = const [],
    this.isRead = false,
    this.isSystem = false,
    this.createdAt,
  });

  factory TicketMessage.fromJson(Map<String, dynamic> json) {
    return TicketMessage(
      id: (json['_id'] ?? '').toString(),
      senderId: (json['senderId'] ?? '').toString(),
      senderName: json['senderName']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      attachments: (json['attachments'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      isRead: json['isRead'] as bool? ?? false,
      isSystem: json['isSystem'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
    );
  }
}

class TicketModel {
  final String id;
  final String ticketId;
  final String subject;
  final String description;
  final String status;
  final String priority;
  final String platform;
  final String raisedById;
  final String raisedByName;
  final List<String> attachments;
  final List<TicketMessage> messages;
  final bool hasUnread;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const TicketModel({
    required this.id,
    required this.ticketId,
    required this.subject,
    required this.description,
    required this.status,
    required this.priority,
    required this.platform,
    required this.raisedById,
    required this.raisedByName,
    this.attachments = const [],
    this.messages = const [],
    this.hasUnread = false,
    this.createdAt,
    this.updatedAt,
  });

  factory TicketModel.fromJson(Map<String, dynamic> json) {
    return TicketModel(
      id: (json['_id'] ?? '').toString(),
      ticketId: json['ticketId']?.toString() ?? '',
      subject: json['subject']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      status: json['status']?.toString() ?? 'Pending',
      priority: json['priority']?.toString() ?? 'Medium',
      platform: json['platform']?.toString() ?? 'App',
      raisedById: (json['raisedById'] ?? '').toString(),
      raisedByName: json['raisedByName']?.toString() ?? '',
      attachments: (json['attachments'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      messages: (json['messages'] as List?)
              ?.whereType<Map>()
              .map((e) => TicketMessage.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          const [],
      hasUnread: json['hasUnread'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }
}
