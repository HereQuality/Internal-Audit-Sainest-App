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
/// Three things decide what a tick may SHOW (see [PollPlan]), and none of
/// them ever stops the bookkeeping (seen ids, last statuses, notified dates),
/// so a banner that was held back is never dumped later:
/// - the account's push switches ([refreshPushGate]): the master AND the
///   event's own topic;
/// - whether the server already announces the event: the server pushes audit
///   assigned and NC raised/approved/rejected/overdue itself, so while it can
///   push to this phone (NotificationPrefs.readFcmPushReady) the poll only
///   keeps its bookkeeping for them — a banner from here would be a second
///   one — and it is the fallback for a phone the server can't reach. Even
///   then, an event whose server banner this phone already drew (socket, FCM)
///   is skipped (NotificationPrefs.consumeServerEvent). "Audit starting" /
///   "Audit due" are different: no server job sends them, so the poll is
///   their only source;
/// - whether push was just switched back ON after a stretch OFF: the first
///   tick then only records what happened meanwhile ([PollPlan.catchUp]).
///
/// It fetches only the signed-in person's OWN items (`employeeIds=<self>`,
/// like the app's own screens): without the parameter the server answers with
/// the whole reporting hierarchy — a manager's team, a SuperAdmin's whole
/// organisation — and every one of those would read as "assigned to you".
Future<void> pollAndNotifyEvents() async {
  final token = await NotificationPrefs.readToken();
  if (token == null || token.isEmpty) {
    return; // logged out — nothing to poll for
  }
  final self = await pollSelfScope();
  if (self == null) return;

  await LocalNotifications.init();

  final gate = await refreshPushGate(token);
  final plan = await PollPlan.read(NotificationPrefs.pollEvents, gate);
  final audits = await _pollAudits(token, self, plan);
  final ncs = await _pollNcs(token, self, plan);
  // Only a tick that saw BOTH lists has recorded everything there was.
  if (plan.catchUp && audits && ncs) {
    await NotificationPrefs.clearPollSuspended(NotificationPrefs.pollEvents);
  }
}

/// The query that scopes a poll request to the signed-in person, or null when
/// there is no known person: falling back to the unscoped request would
/// silently widen it to the team / the organisation (see above), so a poll
/// without an id does not run. A SuperAdmin's id is a users-collection id no
/// audit or NC refers to, so their scoped lists are simply empty.
Future<Map<String, String>?> pollSelfScope() async {
  final userId = await NotificationPrefs.readUserId();
  if (userId == null || userId.isEmpty) return null;
  return {'employeeIds': userId};
}

/// What one poll tick may show, worked out once up front.
class PollPlan {
  const PollPlan({required this.gate, this.serverPushes = false, this.catchUp = false});

  /// The account's push switches, read once for the tick.
  final PushGate gate;

  /// The server can push to this phone (FCM registered, `pushReady`): it
  /// announces the events it pushes, so the poll only keeps its bookkeeping
  /// for them.
  final bool serverPushes;

  /// The first tick with push ON after a stretch OFF — nothing polled while
  /// it was off, so this tick only records.
  final bool catchUp;

  static Future<PollPlan> read(String poll, PushGate gate) async => PollPlan(
    gate: gate,
    serverPushes: await NotificationPrefs.readFcmPushReady(),
    catchUp: gate.enabled && await NotificationPrefs.readPollSuspended(poll),
  );

  /// A banner only this phone can produce (audit_reminder).
  bool showsLocal(String type) => !catchUp && gate.allows(type);

  /// A banner for an event the server ALSO pushes: shown only when the
  /// topic(s) allow it, this isn't a catch-up tick, and the server can't be
  /// relied on to have told the person.
  bool showsFallback({required bool topicOn}) => !catchUp && !serverPushes && topicOn;
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
  final body = await pollGetJson(ApiConstants.mePreferences, token);
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

/// One authenticated GET for a poll (package:http, see above). Null on any
/// failure — offline, a non-200, an unreadable body — so a tick that can't
/// read simply does nothing and the next one retries. A 401/403 is different
/// in kind: the mirrored session token itself was refused (it expired, or the
/// account was blocked), which no later tick can fix — that is recorded
/// (NotificationPrefs.markSessionRejected) so the Android foreground service
/// can stop instead of waking every 15 minutes to do nothing; the next login
/// brings a new token and needs no reset.
Future<Map<String, dynamic>?> pollGetJson(
  String path,
  String token, {
  Map<String, String>? query,
}) async {
  final base = Uri.parse('${ApiConstants.baseUrl}$path');
  final uri = query == null ? base : base.replace(queryParameters: query);
  http.Response res;
  try {
    res = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 25));
  } catch (_) {
    return null; // offline/unreachable this tick — the next tick will retry.
  }
  if (res.statusCode == 401 || res.statusCode == 403) {
    try {
      await NotificationPrefs.markSessionRejected(token);
    } catch (_) {}
    return null;
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

/// True once the list was read and everything in it recorded.
Future<bool> _pollAudits(String token, Map<String, String> self, PollPlan plan) async {
  final body = await pollGetJson(ApiConstants.myAudits, token, query: self);
  if (body == null) return false;
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
      plan.gate.allows(NotificationTypes.auditCreated) &&
      plan.gate.allows(NotificationTypes.auditReassigned);
  final announceReminders = plan.showsLocal(NotificationTypes.auditReminder);

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
      // Asked first, so the ledger entry is used up whichever way the banner
      // goes: a "new audit" the server's own banner already announced on this
      // phone (socket / FCM) is not announced again. Not on the very first
      // poll, which announces nothing and may list hundreds of audits.
      final serverTold =
          baselineSeeded &&
          await NotificationPrefs.consumeServerEvent(const [
            NotificationTypes.auditCreated,
            NotificationTypes.auditReassigned,
            NotificationTypes.auditSeriesCreated,
          ], id);
      if (baselineSeeded && plan.showsFallback(topicOn: announceAssigned) && !serverTold) {
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
    if (status == 'Completed' || status == 'Draft' || status == 'Skipped') {
      continue;
    }

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

  if (newSeenIds.isNotEmpty) {
    await NotificationPrefs.addSeenAuditIds(newSeenIds);
  }
  if (newNotifiedDates.isNotEmpty) {
    await NotificationPrefs.addNotifiedAuditDates(newNotifiedDates);
  }
  if (!baselineSeeded) await NotificationPrefs.setAuditBaselineSeeded();
  return true;
}

/// True once the list was read and everything in it recorded.
Future<bool> _pollNcs(String token, Map<String, String> self, PollPlan plan) async {
  final body = await pollGetJson(ApiConstants.ncsMine, token, query: self);
  if (body == null) return false;
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
      final serverTold =
          baselineSeeded && await NotificationPrefs.consumeServerEvent(const [NotificationTypes.ncRaised], id);
      if (baselineSeeded &&
          plan.showsFallback(topicOn: plan.gate.allows(NotificationTypes.ncRaised)) &&
          !serverTold) {
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
          final serverTold = await NotificationPrefs.consumeServerEvent(const [NotificationTypes.ncApproved], id);
          if (plan.showsFallback(topicOn: plan.gate.allows(NotificationTypes.ncApproved)) && !serverTold) {
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
          final serverTold = await NotificationPrefs.consumeServerEvent(const [NotificationTypes.ncRejected], id);
          if (plan.showsFallback(topicOn: plan.gate.allows(NotificationTypes.ncRejected)) && !serverTold) {
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
  if (statusUpdates.isNotEmpty) {
    await NotificationPrefs.mergeNcLastStatus(statusUpdates);
  }
  if (!baselineSeeded) await NotificationPrefs.setNcBaselineSeeded();
  return true;
}
