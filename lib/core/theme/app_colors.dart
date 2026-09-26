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

  /// [color] as SMALL TEXT / thin icons on the current theme's surfaces. The
  /// 500/600-level tokens above are tuned for light backgrounds: as 11-13px
  /// text on the dark theme's tinted pills and cards blue, red, slate and
  /// purple measure only 2.5-3.6:1 (WCAG AA wants 4.5:1). Lightened 30%
  /// toward white every one of them clears 4.6:1 there; the light theme gets
  /// the exact token back.
  static Color readable(BuildContext context, Color color) =>
      Theme.of(context).brightness == Brightness.dark
      ? Color.lerp(color, Colors.white, 0.3)!
      : color;

  // The lifecycle statuses' own tokens. The shared 500/600-level tokens above
  // are tuned for icons and fills: as 12px badge text on their own 12% tint
  // they measure 2.9:1 (green) / 2.8:1 (amber) on the light theme, and even
  // blue/red/slate only reach ~3.7-4.0 on the real light card. These eight
  // sit in the narrow lightness band where the badge text clears 4.5:1 on
  // BOTH themes — light as-is, dark after [readable]'s 30% lightening (a
  // darker token would pass light and fail dark, a lighter one the reverse) —
  // so the badges are AA-readable everywhere without a per-theme palette.
  // test/audit_status_test.dart holds them to that.
  static const _notStarted = Color(0xFF546173); // slate
  static const _inProgress = Color(0xFF1555E0); // blue
  static const _overdue = Color(0xFFAF352C); // red
  static const _delayed = Color(0xFFAA4109); // orange
  static const _onTime = Color(0xFF126E34); // green
  static const _ncResponse = Color(0xFF855800); // amber
  static const _ncVerification = Color(0xFF7632EC); // violet
  static const _totalClosed = Color(0xFF0C6E66); // teal

  // The unified audit-status vocabulary the server sends as `displayStatus`
  // (server/utils/auditLifecycleStatus.js), on the palette the status
  // contract suggests:
  //   Not Started slate · In Progress blue · Overdue red · Delayed Completed
  //   orange · On-Time Completed green · NC Response Pending amber ·
  //   NC Verification Pending violet · Total Closed teal.
  // 'Draft'/'Skipped' keep their old colours, and the legacy stored
  // 'Completed' (an older server that sends no displayStatus) keeps green.
  // 'On-Time Completed'/'Delayed Completed' are never a displayStatus — they
  // colour the timeliness pill, the dashboard tiles and the filter chips.
  // Anything else the server invents later falls to neutral slate and is
  // shown with its own text, rather than borrowing another status's colour.
  static Color forAuditStatus(String status) {
    switch (status) {
      case 'Draft':
        return slate;
      case 'Not Started':
        return _notStarted;
      case 'In Progress':
        return _inProgress;
      case 'Overdue':
        return _overdue;
      case 'Delayed Completed':
        return _delayed;
      case 'On-Time Completed':
        return _onTime;
      case 'NC Response Pending':
        return _ncResponse;
      case 'NC Verification Pending':
        return _ncVerification;
      case 'Total Closed':
        return _totalClosed;
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
