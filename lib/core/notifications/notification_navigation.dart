import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/nc_provider.dart';
import '../../screens/audits/audit_detail_screen.dart';
import '../../screens/nc/nc_response_screen.dart';
import '../../screens/nc/nc_review_screen.dart';

/// Global navigator access for code with no BuildContext of its own — a
/// local-notification tap (see local_notifications.dart's
/// onDidReceiveNotificationResponse) runs outside any widget tree, so it
/// can't reach Navigator.of(context) the normal way. Wired into
/// MaterialApp's own navigatorKey in main.dart; every other screen keeps
/// using its own ambient BuildContext as usual — this is only for that
/// one case.
final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

// One shared payload codec + routing rule for "what does tapping this
// notification open", used by BOTH the in-app notifications list
// (screens/notifications/notifications_screen.dart, which already has a
// real server Notification's own `type`/`referenceId`) and every local
// (OS-tray) notification call site (event_poll.dart, overdue_poll.dart,
// notifications_provider.dart's showLive) — so the same event always
// lands on the same screen regardless of which of the two paths the tap
// came through, instead of two independently-maintained routing rules
// drifting apart.
//
// `type` only ever needs its audit_/nc_ prefix checked below —
// event_poll.dart/overdue_poll.dart poll raw audit/NC state directly
// rather than a real server Notification doc, so they have no genuine
// `type` string to pass; 'audit_local'/'nc_local' satisfy the same prefix
// check those two client-only sources need without claiming to be one of
// the 11 real server types.
String encodeNotificationPayload({
  required String type,
  required String? referenceId,
}) => '$type|${referenceId ?? ''}';

({String type, String? referenceId})? decodeNotificationPayload(
  String? payload,
) {
  if (payload == null || payload.isEmpty) return null;
  final i = payload.indexOf('|');
  if (i == -1) return null;
  final refId = payload.substring(i + 1);
  return (
    type: payload.substring(0, i),
    referenceId: refId.isEmpty ? null : refId,
  );
}

// Where a tap on a notification actually goes — audit_* types carry an
// audit id and open straight into the scoring workspace; nc_* types carry
// an NC id, which needs a round-trip to GET /ncs/:id first (a
// notification only ever ships the bare id, not the full NcModel the NC
// screens need — see NcProvider#fetchById) before landing on whichever of
// Respond/Review fits its current status, same split nc_list_screen.dart's
// "against me" list already uses. Summary digests (morning_summary/
// evening_summary) and anything else unrecognized are a deliberate no-op
// — there's no single record to land on, same as the web app's own
// notificationRoute.js returning null for those two.
Future<void> openNotificationTarget(
  BuildContext context, {
  required String type,
  required String? referenceId,
}) async {
  if (referenceId == null || referenceId.isEmpty) return;
  if (type.startsWith('audit_')) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuditDetailScreen(auditId: referenceId),
      ),
    );
    return;
  }
  if (type.startsWith('nc_')) {
    final nc = await context.read<NcProvider>().fetchById(referenceId);
    if (!context.mounted || nc == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => nc.status == 'Raised'
            ? NcResponseScreen(nc: nc)
            : NcReviewScreen(nc: nc),
      ),
    );
  }
}

/// Entry point for a LOCAL (OS-tray) notification tap while the app
/// process is already alive (foreground or backgrounded-but-not-killed —
/// see local_notifications.dart's onDidReceiveNotificationResponse). Goes
/// through notificationNavigatorKey since this callback has no
/// BuildContext of its own. A no-op if the navigator isn't mounted yet
/// (shouldn't happen for this path — the process is already running by
/// definition — but cheap to guard) or the payload doesn't decode to
/// anything routable. The cold-start case (app was NOT running, launched
/// BY the tap) is handled separately — see main.dart, which can't use
/// this path since there's no authenticated app shell mounted yet at the
/// moment the tap actually happened.
void handleLocalNotificationTap(String? payload) {
  final decoded = decodeNotificationPayload(payload);
  if (decoded == null) return;
  final context = notificationNavigatorKey.currentContext;
  if (context == null) return;
  openNotificationTarget(
    context,
    type: decoded.type,
    referenceId: decoded.referenceId,
  );
}
