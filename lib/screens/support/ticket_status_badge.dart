import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../models/ticket_model.dart';
import '../../widgets/status_badge.dart';

/// A ticket's status as [viewerId] should read it (see
/// TicketModel#statusLabelFor) — shared by the list tile and the detail
/// header so the two can never word or colour the same ticket differently.
class TicketStatusBadge extends StatelessWidget {
  /// Same purple as the web Support page's "Has your issue been resolved?"
  /// card, so the badge and the card it points at read as one thing.
  static const actionColor = Color(0xFF7C3AED);

  final TicketModel ticket;
  final String? viewerId;

  const TicketStatusBadge({super.key, required this.ticket, required this.viewerId});

  @override
  Widget build(BuildContext context) {
    final label = ticket.statusLabelFor(viewerId);
    if (!ticket.needsConfirmationFrom(viewerId)) {
      return StatusBadge(label: label, color: AppColors.forTicketStatus(ticket.status));
    }
    // The raiser has something to DO here — a solid pill stands out from
    // the tinted, informational badges around it.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: actionColor, borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}
