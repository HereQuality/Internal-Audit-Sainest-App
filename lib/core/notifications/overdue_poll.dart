import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../constants/api_constants.dart';
import '../utils/nc_timeliness.dart';
import 'local_notifications.dart';
import 'notification_navigation.dart';
import 'notification_prefs.dart';

/// Everything the background pipeline actually does, in one place — a
/// plain top-level function on purpose (see notification_prefs.dart): it's
/// called identically from the AndroidAlarmManager oneShot tick, the
/// flutter_background_service isolate's own start-up poll, and (for a
/// same-behavior manual "check now") the foreground app. No Provider,
/// no BuildContext, no DI — just http + SharedPreferences + the plugin.
///
/// Uses `package:http` rather than the app's Dio instance deliberately:
/// DioClient wires interceptors (auth header injection, 401 handling via
/// AuthProvider) that assume a running app with a ChangeNotifier tree —
/// none of that exists in a background isolate, so this reads the mirrored
/// token straight out of NotificationPrefs and sets the header itself.
Future<void> pollAndNotifyOverdueNcs() async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty)
    return; // logged out — nothing to poll for

  await LocalNotifications.init();

  final uri = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.ncsMine}');
  http.Response res;
  try {
    res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 25));
  } catch (_) {
    return; // offline/unreachable this tick — the next tick will retry.
  }
  if (res.statusCode != 200) return;

  Map<String, dynamic> body;
  try {
    body = jsonDecode(res.body) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  if (body['isOk'] != true) return;
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
  final newlyOverdue =
      <
        ({
          String ncId,
          String findingTitle,
          String? auditTitle,
          DateTime targetDate,
        })
      >[];

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
        targetDateRaw == null)
      continue;
    if (alreadyNotified.contains(ncId)) continue;

    final targetDate = DateTime.tryParse(targetDateRaw);
    if (targetDate == null || !now.isAfter(effectiveDeadline(targetDate)))
      continue; // not overdue yet — a bare due date is still on time through end of that day

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

  if (newlyOverdue.isEmpty) return;

  if (newlyOverdue.length == 1) {
    final one = newlyOverdue.first;
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
    final preview = newlyOverdue.take(3).map((n) => n.findingTitle).join(', ');
    final more = newlyOverdue.length > 3
        ? ' +${newlyOverdue.length - 3} more'
        : '';
    await LocalNotifications.showOverdueNc(
      // Fixed id (not per-NC) so a later poll's group replaces this same
      // tray entry instead of stacking a second group notification.
      id: 0x4f564552, // 'OVER' — arbitrary stable constant for the grouped slot
      title: '${newlyOverdue.length} non-conformities are overdue',
      body: '$preview$more',
      payload: encodeNotificationPayload(
        type: 'nc_local',
        referenceId: newlyOverdue.first.ncId,
      ),
    );
  }

  await NotificationPrefs.addNotifiedIds(
    newlyOverdue.map((n) => n.ncId).toList(),
  );
}
