import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_update_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/maintenance_provider.dart';
import '../../providers/nc_provider.dart';
import '../../screens/audits/audit_detail_screen.dart';
import '../../screens/nc/nc_response_screen.dart';
import '../../screens/nc/nc_review_screen.dart';
import '../../screens/support/ticket_detail_screen.dart';

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
// `type` only ever needs its audit_/nc_/ticket_ prefix checked below —
// event_poll.dart/overdue_poll.dart poll raw audit/NC state directly
// rather than a real server Notification doc, so they have no genuine
// `type` string to pass; 'audit_local'/'nc_local' satisfy the same prefix
// check those two client-only sources need without claiming to be one of
// the real server types. Ticket notifications are the opposite: they only
// ever come from the server (ticket_created/ticket_reply/ticket_status/
// ticket_forwarded), there is no local-poll counterpart.
//
// An FCM push also carries WHOSE notification it is (`recipientId`, an optional
// third part) so a tap can be refused when this phone is signed in as somebody
// else — a token left bound to an earlier account otherwise opens that
// account's audit under the current one ("someone else's audit"). Local
// banners never need it: they are only ever drawn for the signed-in person.
String encodeNotificationPayload({
  required String type,
  required String? referenceId,
  String? recipientId,
}) => recipientId == null || recipientId.isEmpty
    ? '$type|${referenceId ?? ''}'
    : '$type|${referenceId ?? ''}|$recipientId';

({String type, String? referenceId})? decodeNotificationPayload(
  String? payload,
) {
  if (payload == null || payload.isEmpty) return null;
  final i = payload.indexOf('|');
  if (i == -1) return null;
  final rest = payload.substring(i + 1);
  final j = rest.indexOf('|');
  final refId = j == -1 ? rest : rest.substring(0, j);
  return (
    type: payload.substring(0, i),
    referenceId: refId.isEmpty ? null : refId,
  );
}

/// The account an FCM payload was addressed to, or null when it names none
/// (a local banner, an older server).
String? notificationPayloadRecipient(String? payload) {
  if (payload == null) return null;
  final parts = payload.split('|');
  if (parts.length < 3 || parts[2].isEmpty) return null;
  return parts[2];
}

// Where a tap on a notification actually goes — audit_* types carry an
// audit id and open straight into the scoring workspace; nc_* types carry
// an NC id, which needs a round-trip to GET /ncs/:id first (a
// notification only ever ships the bare id, not the full NcModel the NC
// screens need — see NcProvider#fetchById) before landing on whichever of
// Respond/Review fits its current status, same split nc_list_screen.dart's
// "against me" list already uses; ticket_* types carry the ticket's Mongo
// id and open its chat thread, which fetches itself (TicketDetailScreen).
// Every way a notification can be tapped — the in-app list, an OS-tray
// (local) notification, an FCM tap, a cold start — lands here, so a ticket
// notification opens the same screen whichever of them delivered it.
// Summary digests (morning_summary/
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
  if (type.startsWith('ticket_')) {
    _openTicket(context, referenceId);
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

// TicketsProvider holds a single active ticket + socket room, so two ticket
// screens stacked on each other would fight over it — popping the top one
// closes the room and blanks the one beneath. A tap for a DIFFERENT ticket
// while one is already on top therefore replaces that screen instead of
// stacking on it, and a tap for the very ticket already on screen (the
// thread is live, nothing to reload) does nothing.
void _openTicket(BuildContext context, String ticketId) {
  final navigator = Navigator.of(context);
  // popUntil that returns true straight away pops nothing — it's just the
  // public way to read the top route's name/arguments.
  Route<dynamic>? top;
  navigator.popUntil((route) {
    top = route;
    return true;
  });
  final ticketOnTop = top?.settings.name == TicketDetailScreen.routeName;
  if (ticketOnTop && top?.settings.arguments == ticketId) return;
  final route = TicketDetailScreen.route(ticketId);
  if (ticketOnTop) {
    navigator.pushReplacement(route);
  } else {
    navigator.push(route);
  }
}

/// Whether a tap can be acted on right now: signed in, not on the
/// force-update screen, not blocked by maintenance. Anything else has a gate
/// on screen, and a record pushed over it is a way past it (or, over the
/// login screen, a fetch that can only fail).
bool notificationTapsAllowed({
  required AuthStatus status,
  required bool forceUpdateRequired,
  required bool maintenanceBlocked,
}) => status == AuthStatus.authenticated && !forceUpdateRequired && !maintenanceBlocked;

bool _tapsAllowedNow(BuildContext context) {
  final auth = context.read<AuthProvider>();
  final isSuperAdmin = auth.user?.roleType == 'SuperAdmin';
  return notificationTapsAllowed(
    status: auth.status,
    forceUpdateRequired: context.read<AppUpdateProvider>().isForceUpdateRequired,
    // Same rule as main.dart's _RootGate: SuperAdmin bypasses maintenance.
    maintenanceBlocked: context.read<MaintenanceProvider>().status.isActive && !isSuperAdmin,
  );
}

// The one tap waiting for the app to be able to act on it — the cold-start
// tap (there is no signed-in shell yet at the moment it happens) or a warm
// tap that landed on a login / force-update / maintenance screen. main.dart's
// _RootGate takes it once the gates are clear. A newer tap replaces it.
String? _heldTapPayload;

void holdNotificationTap(String? payload) => _heldTapPayload = payload;

/// Hands out the held tap (once), or null.
String? takeHeldNotificationTap() {
  final payload = _heldTapPayload;
  _heldTapPayload = null;
  return payload;
}

/// Forgets the held tap — on logout: it belongs to the account that left.
void clearHeldNotificationTap() => _heldTapPayload = null;

/// The payload of the notification whose tap LAUNCHED the app, from the two
/// places it can come from: flutter_local_notifications (a local banner — the
/// Android data-push renderer, the pollers, the socket fallback) and FCM's
/// getInitialMessage (an iOS alert push drawn by the OS). Each is read on its
/// own, with its own timeout and its own try/catch: a platform-channel reply
/// that hangs or throws on one must not cost the other (an iOS push tap is
/// never a local-notification launch, so losing the FCM read means losing the
/// tap). Neither may block runApp() for long.
Future<String?> resolveLaunchPayload({
  required Future<String?> Function() local,
  required Future<String?> Function() fcm,
  Duration timeout = const Duration(seconds: 3),
}) async {
  Future<String?> read(Future<String?> Function() source, String name) async {
    try {
      return await source().timeout(timeout);
    } catch (e, st) {
      debugPrint('Reading the $name launch payload failed, continuing without it: $e\n$st');
      return null;
    }
  }

  final results = await Future.wait([read(local, 'local-notification'), read(fcm, 'FCM')]);
  return results[0] ?? results[1];
}

/// Entry point for a notification tap while the app process is already alive
/// (foreground or backgrounded-but-not-killed — local_notifications.dart's
/// onDidReceiveNotificationResponse, and FCM's onMessageOpenedApp). Goes
/// through notificationNavigatorKey since this callback has no BuildContext
/// of its own. A tap the app can't act on yet — not signed in, the update or
/// maintenance screen up, no navigator mounted — is HELD and applied once
/// main.dart's _RootGate has cleared those gates, never pushed over them.
/// Does nothing if the payload doesn't decode to anything routable. The
/// cold-start case (app was NOT running, launched BY the tap) is read once
/// before runApp (see [resolveLaunchPayload]) and held the same way.
void handleLocalNotificationTap(String? payload) {
  final decoded = decodeNotificationPayload(payload);
  if (decoded == null) return;
  final context = notificationNavigatorKey.currentContext;
  if (context == null || !_tapsAllowedNow(context)) {
    holdNotificationTap(payload);
    return;
  }
  // Addressed to a different account than the one signed in now: a push that
  // reached this phone through a token an earlier account left behind. Opening
  // its record would show the current person somebody else's audit / NC.
  final recipient = notificationPayloadRecipient(payload);
  final me = context.read<AuthProvider>().user?.id;
  if (recipient != null && me != null && recipient != me) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('That notification was for a different account.')));
    return;
  }
  openNotificationTarget(
    context,
    type: decoded.type,
    referenceId: decoded.referenceId,
  );
}
