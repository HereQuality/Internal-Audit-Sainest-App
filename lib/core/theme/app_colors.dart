import 'package:flutter/material.dart';

/// Shared brand + status colors, kept consistent with the web app's
/// dashboard cards and status badges.
class AppColors {
  AppColors._();

  static const primary = Color(0xFF4F46E5); // indigo-600
  static const primaryDark = Color(0xFF6366F1); // indigo-500 (dark mode)

  static const amber = Color(0xFFD97706); // amber-600
  static const red = Color(0xFFDC2626); // red-600
  static const green = Color(0xFF16A34A); // green-600
  static const blue = Color(0xFF2563EB); // blue-600
  static const slate = Color(0xFF64748B); // slate-500

  // Matches web's Components/Common/AuditStatusBadge.jsx#AUDIT_STATUS_COLORS
  // — 'Draft'/'Not Started'/'In Progress'/'Completed'/'Skipped' are the
  // only stored+derived statuses an audit ever actually has (see server/
  // utils/auditStatus.js#deriveAuditStatus); everything else (e.g. legacy
  // 'Scheduled') falls back to slate rather than silently reusing blue.
  static Color forAuditStatus(String status) {
    switch (status) {
      case 'Draft':
        return slate;
      case 'Not Started':
        return blue;
      case 'In Progress':
        return const Color(0xFF0EA5E9); // sky-500, matches web's "In Progress"
      case 'Completed':
        return green;
      case 'Skipped':
        return red;
      default:
        return slate;
    }
  }

  static Color forNcStatus(String status) {
    switch (status) {
      case 'Raised':
        return red;
      case 'Response Submitted':
        return amber;
      case 'Verification':
        return blue;
      case 'Closed':
        return green;
      default:
        return slate;
    }
  }

  static Color forTicketStatus(String status) {
    switch (status) {
      case 'Pending':
        return red;
      case 'In Progress':
        return amber;
      case 'Confirmation':
        return blue;
      case 'Resolved':
      case 'Closed':
        return green;
      default:
        return slate;
    }
  }

  static Color forPriority(String priority) {
    switch (priority) {
      case 'High':
        return red;
      case 'Medium':
        return amber;
      case 'Low':
      default:
        return green;
    }
  }
}
