import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/audit_model.dart';
import '../../models/user_model.dart';
import '../constants/api_constants.dart';
import '../utils/formatters.dart';
import 'local_notifications.dart';
import 'notification_navigation.dart';
import 'notification_prefs.dart';

/// The "everything else" poll, alongside overdue_poll.dart's overdue-NC
/// check — new audit assignments, an assigned audit's start/end date
/// arriving, and NC raised/approved/rejected on the auditee side. Same
/// plain top-level function, no DI/BuildContext, package:http (not the
/// app's Dio instance) pattern as overdue_poll.dart — see its own doc
/// comment for why — called from the same background tick.
///
/// Everything below obeys the account's push switches (Settings > Push
/// Notifications and the per-topic Push column under "Choose what you get",
/// the same server-side preferences the web Settings page shares) — see
/// [refreshPushGate]. A banner is shown only when the master switch AND that
/// event's topic are on. With one off nothing is shown for it, but the
/// underlying dedup/seen-state bookkeeping still runs so turning it back on
/// later doesn't suddenly dump every event that happened while it was off.
Future<void> pollAndNotifyEvents() async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty)
    return; // logged out — nothing to poll for

  await LocalNotifications.init();

  final gate = await refreshPushGate(token);
  await _pollAudits(token, gate);
  await _pollNcs(token, gate);
}

/// The one guard every poll opens with: re-reads the account's push switches
/// (the master and every per-topic value) from the server and refreshes the
/// SharedPreferences mirror with them, so a change made on the web (or on
/// this phone) is obeyed by the very next tick even in a background isolate
/// that never hears the socket event. On any failure (offline, an expired
/// token, an older server without the endpoint or without the per-topic
/// map) the last mirrored values stand — a tick must never flip to a guess.
/// Returns what this tick may show.
Future<PushGate> refreshPushGate(String token) async {
  final body = await _getJson(ApiConstants.mePreferences, token);
  final data = body?['data'];
  if (data is Map) {
    final pushOn = data['pushNotifications'];
    if (pushOn is bool) await NotificationPrefs.setPushEnabled(pushOn);
    final types = data['pushNotificationTypes'];
    if (types is Map) {
      await NotificationPrefs.setPushTypes(UserPreferences.parseTypeMap(types));
    }
  }
  return NotificationPrefs.readPushGate();
}

Future<Map<String, dynamic>?> _getJson(String path, String token) async {
  final uri = Uri.parse('${ApiConstants.baseUrl}$path');
  http.Response res;
  try {
    res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 25));
  } catch (_) {
    return null; // offline/unreachable this tick — the next tick will retry.
  }
  if (res.statusCode != 200) return null;
  try {
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['isOk'] == true ? body : null;
  } catch (_) {
    return null;
  }
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// "`title` — `location` · starts/due `date`" — the same "title — due
/// `date`" idiom overdue_poll.dart's own showOverdueNc body already uses,
/// extended with location (when known) since a bare title alone doesn't
/// say WHERE — unlike every audit card in the app itself (audit_agenda
/// .dart's own location row) — and two audits can share a title (e.g. a
/// recurring "Monthly Check") at different sites.
String _eventBody(String title, String location, String verb, DateTime? date) {
  final when = date == null ? null : '$verb ${Formatters.date(date)}';
  final parts = [if (location.isNotEmpty) location, ?when];
  return parts.isEmpty ? title : '$title — ${parts.join(' · ')}';
}

Future<void> _pollAudits(String token, PushGate gate) async {
  final body = await _getJson(ApiConstants.myAudits, token);
  if (body == null) return;
  final audits = (body['data'] as List? ?? []).whereType<Map>().toList();

  // Gates the very first poll ever on this device from announcing every
  // already-assigned audit as "new" — same idea for the date reminders
  // below, so a fresh install doesn't immediately fire a start/end
  // reminder for every audit already sitting mid-window.
  final baselineSeeded = await NotificationPrefs.readAuditBaselineSeeded();
  final seenIds = await NotificationPrefs.readSeenAuditIds();
  final notifiedDates = await NotificationPrefs.readNotifiedAuditDates();
  final today = _dayOnly(DateTime.now());

  // An audit that newly shows up in /audits/mine is either brand new
  // (audit_created) or one this person was just reassigned to
  // (audit_reassigned) — the list can't say which, so the banner needs BOTH
  // topics on. With either off the server's own push, which does know which
  // it is and follows the exact switch, stays the only alert.
  final announceAssigned =
      gate.allows(NotificationTypes.auditCreated) &&
      gate.allows(NotificationTypes.auditReassigned);
  final announceReminders = gate.allows(NotificationTypes.auditReminder);

  final newSeenIds = <String>[];
  final newNotifiedDates = <String>[];

  for (final raw in audits) {
    final audit = Map<String, dynamic>.from(raw);
    final id = audit['_id']?.toString();
    if (id == null) continue;
    final title = audit['title']?.toString() ?? 'Audit';
    // Only .location is used from this — see AuditModel.fromJson's own
    // null-safe field-by-field parsing, so a partial/odd payload shape
    // just degrades to an empty string rather than throwing mid-poll.
    final location = AuditModel.fromJson(audit).location;
    final scheduledDate = DateTime.tryParse(
      audit['scheduledDate']?.toString() ?? '',
    );
    final endDate = DateTime.tryParse(
      audit['scheduledEndDate']?.toString() ?? '',
    );

    if (!seenIds.contains(id)) {
      newSeenIds.add(id);
      if (baselineSeeded && announceAssigned) {
        await LocalNotifications.showAuditAssigned(
          id: 'assigned:$id'.hashCode & 0x7fffffff,
          title: 'New audit assigned',
          body: _eventBody(title, location, 'starts', scheduledDate),
          payload: encodeNotificationPayload(
            type: 'audit_local',
            referenceId: id,
          ),
        );
      }
    }

    final status = audit['status']?.toString();
    if (status == 'Completed' || status == 'Draft' || status == 'Skipped')
      continue;

    // Dedup bookkeeping (newNotifiedDates) always runs once a date
    // qualifies, regardless of baselineSeeded/the push switches — otherwise
    // a key that was skipped while baselineSeeded was still false (or while
    // push was off) never gets recorded, and the very next poll
    // treats every already-qualifying audit as newly-due all at once
    // (the backlog-dump bug this comment used to have).
    if (scheduledDate != null && !today.isBefore(_dayOnly(scheduledDate))) {
      final key = '$id:start';
      if (!notifiedDates.contains(key)) {
        if (baselineSeeded && announceReminders) {
          await LocalNotifications.showAuditDateReminder(
            id: key.hashCode & 0x7fffffff,
            title: 'Audit starting',
            body: _eventBody(title, location, 'starts', scheduledDate),
            payload: encodeNotificationPayload(
              type: 'audit_local',
              referenceId: id,
            ),
          );
        }
        newNotifiedDates.add(key);
      }
    }
    if (endDate != null && !today.isBefore(_dayOnly(endDate))) {
      final key = '$id:end';
      if (!notifiedDates.contains(key)) {
        if (baselineSeeded && announceReminders) {
          await LocalNotifications.showAuditDateReminder(
            id: key.hashCode & 0x7fffffff,
            title: 'Audit due',
            body: _eventBody(title, location, 'due', endDate),
            payload: encodeNotificationPayload(
              type: 'audit_local',
              referenceId: id,
            ),
          );
        }
        newNotifiedDates.add(key);
      }
    }
  }

  if (newSeenIds.isNotEmpty)
    await NotificationPrefs.addSeenAuditIds(newSeenIds);
  if (newNotifiedDates.isNotEmpty)
    await NotificationPrefs.addNotifiedAuditDates(newNotifiedDates);
  if (!baselineSeeded) await NotificationPrefs.setAuditBaselineSeeded();
}

Future<void> _pollNcs(String token, PushGate gate) async {
  final body = await _getJson(ApiConstants.ncsMine, token);
  if (body == null) return;
  final ncs = (body['data'] as List? ?? []).whereType<Map>().toList();

  final baselineSeeded = await NotificationPrefs.readNcBaselineSeeded();
  final seenIds = await NotificationPrefs.readSeenNcIds();
  final lastStatus = await NotificationPrefs.readNcLastStatus();

  final newSeenIds = <String>[];
  final statusUpdates = <String, String>{};

  for (final raw in ncs) {
    final nc = Map<String, dynamic>.from(raw);
    final id = nc['_id']?.toString();
    if (id == null) continue;
    final title = nc['title']?.toString() ?? 'Non-Conformance';
    final status = nc['status']?.toString() ?? '';
    final reopenCount = (nc['reopenCount'] as num?)?.toInt() ?? 0;
    final key = '$status|$reopenCount';

    if (!seenIds.contains(id)) {
      newSeenIds.add(id);
      if (baselineSeeded && gate.allows(NotificationTypes.ncRaised)) {
        await LocalNotifications.showNewNc(
          id: 'raised:$id'.hashCode & 0x7fffffff,
          title: 'New NC raised against you',
          body: title,
          payload: encodeNotificationPayload(type: 'nc_local', referenceId: id),
        );
      }
    } else {
      // Diffed against this NC's own last-seen "status|reopenCount" —
      // Closed is an approval, a reopenCount bump is a rejection (back to
      // Raised for another attempt). Never fires on the very first poll
      // that ever sees this id (prev is null then, nothing to diff yet).
      final prev = lastStatus[id];
      if (prev != null && prev != key) {
        final prevReopen = int.tryParse(prev.split('|').last) ?? 0;
        // Nested rather than `status == 'Closed' && allowed`: an NC that was
        // rejected AND finally approved between two ticks is an approval,
        // and must stay quiet with approvals off instead of falling through
        // to a "rejected" banner.
        if (status == 'Closed') {
          if (gate.allows(NotificationTypes.ncApproved)) {
            await LocalNotifications.showNcApproved(
              id: 'approved:$id'.hashCode & 0x7fffffff,
              title: 'NC response approved',
              body: title,
              payload: encodeNotificationPayload(
                type: 'nc_local',
                referenceId: id,
              ),
            );
          }
        } else if (reopenCount > prevReopen) {
          if (gate.allows(NotificationTypes.ncRejected)) {
            await LocalNotifications.showNcRejected(
              id: 'rejected:$id'.hashCode & 0x7fffffff,
              title: 'NC response rejected',
              body: title,
              payload: encodeNotificationPayload(
                type: 'nc_local',
                referenceId: id,
              ),
            );
          }
        }
      }
    }
    statusUpdates[id] = key;
  }

  if (newSeenIds.isNotEmpty) await NotificationPrefs.addSeenNcIds(newSeenIds);
  if (statusUpdates.isNotEmpty)
    await NotificationPrefs.mergeNcLastStatus(statusUpdates);
  if (!baselineSeeded) await NotificationPrefs.setNcBaselineSeeded();
}
