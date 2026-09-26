import 'package:intl/intl.dart';

import '../constants/api_constants.dart';
import '../utils/nc_timeliness.dart';
import 'event_poll.dart' show PollPlan, pollGetJson, pollSelfScope, refreshPushGate;
import 'local_notifications.dart';
import 'notification_navigation.dart';
import 'notification_prefs.dart';

/// The overdue-NC half of the phone's local poll: `GET /ncs/mine`, diffed
/// against what has already been handled. A plain top-level function on
/// purpose (see notification_prefs.dart): it's called identically from the
/// foreground service's tick and from the foreground app right after a
/// login. No Provider, no BuildContext, no DI — just http + SharedPreferences
/// + the plugin.
///
/// Uses `package:http` rather than the app's Dio instance deliberately:
/// DioClient wires interceptors (auth header injection, 401 handling via
/// AuthProvider) that assume a running app with a ChangeNotifier tree —
/// none of that exists in a background isolate, so this reads the mirrored
/// token straight out of NotificationPrefs and sets the header itself.
///
/// Like event_poll.dart it is only a FALLBACK for the server's own
/// `nc_overdue` push (utils/overdueNotifier.js): while the server can push to
/// this phone it just records the NCs as handled, and an NC whose server
/// banner this phone already drew is skipped. It also opens with the
/// account's push-switch guard ([refreshPushGate]) — with the master Push
/// switch or the "NC overdue" topic off nothing is shown, but overdue NCs are
/// still recorded as handled so turning it back on later doesn't dump every
/// NC that went overdue in the meantime (after a stretch with the MASTER off
/// the first tick back on is a silent catch-up, see [PollPlan.catchUp]). Only
/// the signed-in person's own NCs are fetched (`employeeIds=<self>`), never
/// their team's or the organisation's.
Future<void> pollAndNotifyOverdueNcs() async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty) {
    return; // logged out — nothing to poll for
  }
  final self = await pollSelfScope();
  if (self == null) return;

  await LocalNotifications.init();

  final gate = await refreshPushGate(token);
  final plan = await PollPlan.read(NotificationPrefs.pollOverdue, gate);

  // null: offline/unreachable/refused this tick — the next tick will retry.
  final body = await pollGetJson(ApiConstants.ncsMine, token, query: self);
  if (body == null) return;
  final ncs = (body['data'] as List? ?? []).whereType<Map>().toList();

  final now = DateTime.now();
  final alreadyNotified = await NotificationPrefs.readNotifiedIds();
  // Collected first, notified once at the end as a single consolidated
  // heads-up — this used to fire one separate notification PER newly-
  // overdue NC, so anyone with several items cross their deadline in the
  // same poll window got a burst of pings instead of one readable
  // summary. The per-NC "already notified" dedup below still applies, so
  // an item already surfaced in an earlier poll never re-appears in a
  // later one's group either.
  final newlyOverdue = <_Overdue>[];

  for (final raw in ncs) {
    final nc = Map<String, dynamic>.from(raw);
    final status = nc['status']?.toString();
    // The Mongo _id, NOT the human-readable `ncId` display code (e.g.
    // "NC-3") — this doubles as the tap-to-navigate referenceId below
    // (see notification_navigation.dart's openNotificationTarget), which
    // calls GET /ncs/:id; passing the display code there 500s (a Mongoose
    // CastError) and the tap silently no-ops. `nc['ncId']` kept only as a
    // defensive fallback for the unexpected case _id is somehow missing.
    final ncId = nc['_id']?.toString() ?? nc['ncId']?.toString();
    final targetDateRaw = nc['targetDate']?.toString();
    if (status == null ||
        status == 'Closed' ||
        ncId == null ||
        targetDateRaw == null) {
      continue;
    }
    if (alreadyNotified.contains(ncId)) continue;

    final targetDate = DateTime.tryParse(targetDateRaw);
    if (targetDate == null || !now.isAfter(effectiveDeadline(targetDate))) {
      continue; // not overdue yet — a bare due date is still on time through end of that day
    }

    final auditTitle =
        (nc['auditId'] is Map ? (nc['auditId'] as Map)['title'] : null)
            ?.toString();
    final findingTitle = nc['title']?.toString() ?? 'Non-Conformance';
    newlyOverdue.add((
      ncId: ncId,
      findingTitle: findingTitle,
      auditTitle: auditTitle,
      targetDate: targetDate,
    ));
  }

  await _announceOverdue(newlyOverdue, plan);
  // A tick that read the list has recorded everything in it: the catch-up
  // after a stretch with push off (see PollPlan.catchUp) is done.
  if (plan.catchUp) await NotificationPrefs.clearPollSuspended(NotificationPrefs.pollOverdue);
}

typedef _Overdue = ({String ncId, String findingTitle, String? auditTitle, DateTime targetDate});

// Announces what is left of [newlyOverdue] and records all of it as handled.
Future<void> _announceOverdue(List<_Overdue> newlyOverdue, PollPlan plan) async {
  if (newlyOverdue.isEmpty) return;

  // The server's own "overdue" banner for an NC that was already drawn on this
  // phone (socket / FCM) counts as the announcement: handled, not new.
  final fresh = <_Overdue>[];
  for (final n in newlyOverdue) {
    if (!await NotificationPrefs.consumeServerEvent(const [NotificationTypes.ncOverdue], n.ncId)) {
      fresh.add(n);
    }
  }
  final handled = newlyOverdue.map((n) => n.ncId).toList();

  // Recorded as handled even when nothing is shown (topic off, the server is
  // announcing it, a catch-up tick), so it never comes back as "new".
  if (fresh.isEmpty || !plan.showsFallback(topicOn: plan.gate.allows(NotificationTypes.ncOverdue))) {
    await NotificationPrefs.addNotifiedIds(handled);
    return;
  }

  if (fresh.length == 1) {
    final one = fresh.first;
    final dueDate = DateFormat('d MMM').format(one.targetDate);
    final auditAndDue = one.auditTitle != null
        ? '${one.auditTitle} — due $dueDate'
        : 'due $dueDate';
    await LocalNotifications.showOverdueNc(
      // Stable per-NC notification id so a re-poll before the user acts on
      // it updates the same tray entry instead of stacking duplicates —
      // hashCode is fine here, this never needs to be reversed.
      id: one.ncId.hashCode & 0x7fffffff,
      title: '${one.findingTitle} is overdue',
      body: auditAndDue,
      payload: encodeNotificationPayload(
        type: 'nc_local',
        referenceId: one.ncId,
      ),
    );
  } else {
    final preview = fresh.take(3).map((n) => n.findingTitle).join(', ');
    final more = fresh.length > 3 ? ' +${fresh.length - 3} more' : '';
    await LocalNotifications.showOverdueNc(
      // Fixed id (not per-NC) so a later poll's group replaces this same
      // tray entry instead of stacking a second group notification.
      id: 0x4f564552, // 'OVER' — arbitrary stable constant for the grouped slot
      title: '${fresh.length} non-conformities are overdue',
      body: '$preview$more',
      payload: encodeNotificationPayload(
        type: 'nc_local',
        referenceId: fresh.first.ncId,
      ),
    );
  }

  await NotificationPrefs.addNotifiedIds(handled);
}
