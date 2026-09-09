import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/audit_model.dart';
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
/// Each of the 6 notification types below is independently toggle-able
/// from the Settings screen (NotificationPrefs.keyAuditAssigned etc,
/// readToggle default ON) — a toggle being off just skips emitting that
/// one type, the underlying dedup/seen-state bookkeeping still runs so
/// flipping it back on later doesn't suddenly dump every event that
/// happened while it was off.
Future<void> pollAndNotifyEvents() async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty)
    return; // logged out — nothing to poll for

  await LocalNotifications.init();

  await _pollAudits(token);
  await _pollNcs(token);
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

Future<void> _pollAudits(String token) async {
  final body = await _getJson(ApiConstants.myAudits, token);
  if (body == null) return;
  final audits = (body['data'] as List? ?? []).whereType<Map>().toList();

  final assignedOn = await NotificationPrefs.readToggle(
    NotificationPrefs.keyAuditAssigned,
  );
  final startOn = await NotificationPrefs.readToggle(
    NotificationPrefs.keyAuditStart,
  );
  final endOn = await NotificationPrefs.readToggle(
    NotificationPrefs.keyAuditEnd,
  );

  // Gates the very first poll ever on this device from announcing every
  // already-assigned audit as "new" — same idea for the date reminders
  // below, so a fresh install doesn't immediately fire a start/end
  // reminder for every audit already sitting mid-window.
  final baselineSeeded = await NotificationPrefs.readAuditBaselineSeeded();
  final seenIds = await NotificationPrefs.readSeenAuditIds();
  final notifiedDates = await NotificationPrefs.readNotifiedAuditDates();
  final today = _dayOnly(DateTime.now());

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
      if (baselineSeeded && assignedOn) {
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
    // qualifies, regardless of baselineSeeded/the toggle — otherwise a
    // key that was skipped while baselineSeeded was still false (or while
    // the toggle was off) never gets recorded, and the very next poll
    // treats every already-qualifying audit as newly-due all at once
    // (the backlog-dump bug this comment used to have).
    if (scheduledDate != null && !today.isBefore(_dayOnly(scheduledDate))) {
      final key = '$id:start';
      if (!notifiedDates.contains(key)) {
        if (baselineSeeded && startOn) {
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
        if (baselineSeeded && endOn) {
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

Future<void> _pollNcs(String token) async {
  final body = await _getJson(ApiConstants.ncsMine, token);
  if (body == null) return;
  final ncs = (body['data'] as List? ?? []).whereType<Map>().toList();

  final raisedOn = await NotificationPrefs.readToggle(
    NotificationPrefs.keyNcRaised,
  );
  final approvedOn = await NotificationPrefs.readToggle(
    NotificationPrefs.keyNcApproved,
  );
  final rejectedOn = await NotificationPrefs.readToggle(
    NotificationPrefs.keyNcRejected,
  );

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
      if (baselineSeeded && raisedOn) {
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
        if (status == 'Closed' && approvedOn) {
          await LocalNotifications.showNcApproved(
            id: 'approved:$id'.hashCode & 0x7fffffff,
            title: 'NC response approved',
            body: title,
            payload: encodeNotificationPayload(
              type: 'nc_local',
              referenceId: id,
            ),
          );
        } else if (reopenCount > prevReopen && rejectedOn) {
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
    statusUpdates[id] = key;
  }

  if (newSeenIds.isNotEmpty) await NotificationPrefs.addSeenNcIds(newSeenIds);
  if (statusUpdates.isNotEmpty)
    await NotificationPrefs.mergeNcLastStatus(statusUpdates);
  if (!baselineSeeded) await NotificationPrefs.setNcBaselineSeeded();
}
