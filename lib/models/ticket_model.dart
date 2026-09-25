// System notes the server wrote before its top escalation tier was renamed
// "Developer" — old threads still carry the old wording in the database, so
// it's mapped when shown rather than rewritten server-side. Exact-match on
// purpose: a blanket "SuperAdmin" -> "Developer" replace would also rewrite
// a raiser's own words in a "Not resolved yet: <reason>" note.
const Map<String, String> _legacySystemNotes = {
  'Forwarded this ticket to SuperAdmin.': 'Forwarded this ticket to the Developer.',
};

class TicketMessage {
  final String id;
  final String senderId;
  // 'Employee' or 'User' — 'User' is a SuperAdmin account, which the ticket
  // flow calls the "Developer" (the top escalation tier). Not derivable
  // from senderId alone, since both collections use plain ObjectIds.
  final String senderModel;
  final String senderName;
  final String message;
  final List<String> attachments;
  final bool isRead;
  final bool isSystem;
  final DateTime? createdAt;

  const TicketMessage({
    required this.id,
    required this.senderId,
    this.senderModel = 'Employee',
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
      senderModel: json['senderModel']?.toString() ?? 'Employee',
      senderName: json['senderName']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      attachments: (json['attachments'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      isRead: json['isRead'] as bool? ?? false,
      isSystem: json['isSystem'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
    );
  }

  bool get isFromDeveloper => senderModel == 'User';

  String get displayMessage => isSystem ? (_legacySystemNotes[message] ?? message) : message;
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
  // Set by the server when a handler asks the raiser to confirm the fix,
  // cleared once they Accept/Reject — so it's only non-null while the
  // ticket sits in 'Confirmation'.
  final DateTime? confirmationRequestedAt;
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
    this.confirmationRequestedAt,
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
      confirmationRequestedAt: DateTime.tryParse(json['confirmationRequestedAt']?.toString() ?? ''),
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }

  /// This ticket plus one more chat message (a live `new_message` push).
  TicketModel withMessage(TicketMessage message) {
    return TicketModel(
      id: id,
      ticketId: ticketId,
      subject: subject,
      description: description,
      status: status,
      priority: priority,
      platform: platform,
      raisedById: raisedById,
      raisedByName: raisedByName,
      attachments: attachments,
      messages: [...messages, message],
      hasUnread: hasUnread,
      confirmationRequestedAt: confirmationRequestedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  // 'Resolved' is still in the server enum but no code path sets it any
  // more — a legacy ticket carrying it reads as Closed everywhere.
  bool get isClosed => status == 'Closed' || status == 'Resolved';

  bool get isAwaitingConfirmation => status == 'Confirmation';

  /// True when [viewerId] raised this ticket and it's waiting on their
  /// Accept / Not resolved — the only person who can answer it (the server
  /// rejects anyone else's verify).
  bool needsConfirmationFrom(String? viewerId) =>
      isAwaitingConfirmation && viewerId != null && viewerId.isNotEmpty && raisedById == viewerId;

  /// The status as [viewerId] should read it: the raiser is being asked to
  /// act ("Confirmation Needed"), everyone else is just waiting on them.
  String statusLabelFor(String? viewerId) {
    if (isClosed) return 'Closed';
    if (isAwaitingConfirmation) {
      return needsConfirmationFrom(viewerId) ? 'Confirmation Needed' : 'Waiting for Confirmation';
    }
    return status;
  }
}
