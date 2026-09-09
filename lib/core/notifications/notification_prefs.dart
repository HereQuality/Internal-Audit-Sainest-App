import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Plain, isolate-safe key/value access for everything the background poll
/// needs — no Provider/Riverpod/DI container reaches into a background
/// isolate (AndroidAlarmManager callbacks and the background_service
/// isolate both start with a bare Dart VM, nothing else registered), so
/// this is deliberately the ONLY way state crosses between the foreground
/// app and the background pipeline. SharedPreferences (not
/// flutter_secure_storage) on purpose: it's a plain-old platform channel
/// with no keychain/keystore session to re-establish, so it's the one
/// storage mechanism guaranteed to behave identically in a background
/// isolate with no prior Flutter engine warm-up.
///
/// AuthProvider mirrors the token here on login/logout (see
/// notification_scheduler.dart#onAuthChanged) — flutter_secure_storage
/// stays the source of truth for the foreground app, this is just a
/// same-value copy the background isolate can actually reach.
class NotificationPrefs {
  NotificationPrefs._();

  static const _tokenKey = 'bg_auth_token';
  static const _userIdKey = 'bg_user_id';
  static const _notifiedIdsKey = 'bg_notified_nc_ids';

  // ── Session-scoped dedup state for the event poll (event_poll.dart) ──
  // Same idea as _notifiedIdsKey above, one bucket per event type so a
  // toggle flipped off/on later doesn't resurrect stale state from another
  // type. Cleared only on an ACCOUNT CHANGE (see [setSession]), not on
  // every logout — a different account logging in on this device
  // shouldn't inherit "already seen" state that was never about them, but
  // the SAME person re-authenticating (a forced logout on token expiry is
  // common, not just an explicit Sign Out) should still see every
  // already-acknowledged reminder stay acknowledged, not re-fire as if it
  // were brand new.
  static const _seenAuditIdsKey = 'bg_seen_audit_ids';
  static const _auditBaselineSeededKey = 'bg_audit_baseline_seeded';
  static const _notifiedAuditDatesKey = 'bg_notified_audit_dates';
  static const _seenNcIdsKey = 'bg_seen_new_nc_ids';
  static const _ncBaselineSeededKey = 'bg_nc_baseline_seeded';
  static const _ncLastStatusKey = 'bg_nc_last_status';

  // ── Notification-type toggles (Settings screen) ───────────────────────
  // Plain user preferences, NOT session state — deliberately left out of
  // clearSession() below so a toggle choice survives logout/login on the
  // same device, same as ThemeProvider's dark-mode choice does.
  static const keyAuditAssigned = 'notif_audit_assigned';
  static const keyAuditStart = 'notif_audit_start';
  static const keyAuditEnd = 'notif_audit_end';
  static const keyNcRaised = 'notif_nc_raised';
  static const keyNcApproved = 'notif_nc_approved';
  static const keyNcRejected = 'notif_nc_rejected';

  /// All toggles default ON.
  static Future<bool> readToggle(String key) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(key) ?? true;
  }

  static Future<void> setToggle(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  // ── Overdue-NC background poll master switch (Settings screen) ────────
  // Defaults ON (product decision — phone reminders and email alerts are
  // both meant to be on-by-default, opt-out, same as
  // emailNotifications/emailNotificationTypes on the server). This one
  // starts a real Android foreground service (a persistent "Watching for
  // overdue NCs" notification, plus a second Flutter engine for
  // backgroundServiceOnStart to run in) — that was previously judged
  // unwanted enough to default OFF, but the current call is that the
  // reminder is worth the persistent notification for most users, who can
  // still turn it off here. Login only actually starts the service once
  // permission has been requested — see notification_scheduler.dart
  // #onLoggedIn — so a fresh install doesn't silently run a foreground
  // service with no visible notification.
  static const _bgPollingEnabledKey = 'notif_bg_polling_enabled';

  static Future<bool> readBackgroundPollingEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_bgPollingEnabledKey) ?? true;
  }

  static Future<void> setBackgroundPollingEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bgPollingEnabledKey, value);
  }

  /// Writes the new session — and, only when the account logging in is
  /// DIFFERENT from whoever was last signed in on this device, wipes every
  /// dedup set above first. Comparing against the OUTGOING userId (still
  /// on disk here since [clearSession] deliberately leaves it) is what
  /// lets a same-person re-login be told apart from an actual account
  /// switch; a first-ever login on this device (previousUserId null) has
  /// no dedup state to wipe either way.
  static Future<void> setSession({required String token, required String userId}) async {
    final prefs = await SharedPreferences.getInstance();
    final previousUserId = prefs.getString(_userIdKey);
    if (previousUserId != null && previousUserId != userId) {
      await prefs.remove(_notifiedIdsKey);
      await prefs.remove(_seenAuditIdsKey);
      await prefs.remove(_auditBaselineSeededKey);
      await prefs.remove(_notifiedAuditDatesKey);
      await prefs.remove(_seenNcIdsKey);
      await prefs.remove(_ncBaselineSeededKey);
      await prefs.remove(_ncLastStatusKey);
    }
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_userIdKey, userId);
  }

  /// Called on logout. Deliberately clears ONLY the token — a stopped
  /// background poll has nothing to authenticate with either way (see
  /// background_entrypoints.dart#stopBackgroundPolling) — and leaves
  /// userId and every dedup set above untouched, so the NEXT [setSession]
  /// can tell whether it's the same person logging back in (keep the
  /// dedup state) or a different account on this shared device (wipe it).
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  static Future<String?> readToken() async => (await SharedPreferences.getInstance()).getString(_tokenKey);

  static Future<String?> readUserId() async => (await SharedPreferences.getInstance()).getString(_userIdKey);

  /// NC ids already surfaced as a local notification — checked before
  /// showing one, so the foreground app's own socket-driven notification
  /// (NotificationsProvider) and this background poll never double-announce
  /// the same overdue NC to the user.
  static Future<Set<String>> readNotifiedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_notifiedIdsKey) ?? const []).toSet();
  }

  static Future<void> addNotifiedIds(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_notifiedIdsKey) ?? const []).toSet();
    current.addAll(ids);
    // Cap growth — only the most recent 500 ids are worth remembering;
    // an NC that old has long since been closed or re-surfaced anyway.
    final capped = current.length > 500 ? current.skip(current.length - 500).toSet() : current;
    await prefs.setStringList(_notifiedIdsKey, capped.toList());
  }

  // ── Audit-assigned dedup (event_poll.dart) ────────────────────────────

  /// Audit ids already observed in `/audits/mine` — used to detect a
  /// newly-assigned audit (an id that shows up that wasn't here before).
  static Future<Set<String>> readSeenAuditIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_seenAuditIdsKey) ?? const []).toSet();
  }

  static Future<void> addSeenAuditIds(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_seenAuditIdsKey) ?? const []).toSet();
    current.addAll(ids);
    final capped = current.length > 500 ? current.skip(current.length - 500).toSet() : current;
    await prefs.setStringList(_seenAuditIdsKey, capped.toList());
  }

  /// True once one full poll has run for this session — gates the very
  /// first poll from announcing every already-assigned audit as "new".
  static Future<bool> readAuditBaselineSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_auditBaselineSeededKey) ?? false;
  }

  static Future<void> setAuditBaselineSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_auditBaselineSeededKey, true);
  }

  // ── Audit start/end date reminder dedup ───────────────────────────────

  /// Keys of the form "<auditId>:start" / "<auditId>:end" already fired —
  /// one entry per audit per boundary, so a reminder doesn't re-fire on
  /// every poll for the rest of the audit's scheduled window.
  static Future<Set<String>> readNotifiedAuditDates() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_notifiedAuditDatesKey) ?? const []).toSet();
  }

  static Future<void> addNotifiedAuditDates(Iterable<String> keys) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_notifiedAuditDatesKey) ?? const []).toSet();
    current.addAll(keys);
    final capped = current.length > 500 ? current.skip(current.length - 500).toSet() : current;
    await prefs.setStringList(_notifiedAuditDatesKey, capped.toList());
  }

  // ── New-NC-raised dedup ────────────────────────────────────────────────

  /// NC ids already observed in `/ncs/mine` — separate from
  /// `_notifiedIdsKey` above (that one tracks "already alerted overdue",
  /// a different question from "already seen at all").
  static Future<Set<String>> readSeenNcIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_seenNcIdsKey) ?? const []).toSet();
  }

  static Future<void> addSeenNcIds(Iterable<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_seenNcIdsKey) ?? const []).toSet();
    current.addAll(ids);
    final capped = current.length > 500 ? current.skip(current.length - 500).toSet() : current;
    await prefs.setStringList(_seenNcIdsKey, capped.toList());
  }

  static Future<bool> readNcBaselineSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_ncBaselineSeededKey) ?? false;
  }

  static Future<void> setNcBaselineSeeded() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_ncBaselineSeededKey, true);
  }

  // ── NC approved/rejected transition dedup ─────────────────────────────

  /// Last-seen "status|reopenCount" per NC id — diffed each poll to catch
  /// a transition to Closed (approved) or a reopenCount bump (rejected)
  /// exactly once, the same way _notifiedIdsKey dedups the overdue alert.
  static Future<Map<String, String>> readNcLastStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_ncLastStatusKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> mergeNcLastStatus(Map<String, String> updates) async {
    if (updates.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final current = await readNcLastStatus();
    current.addAll(updates);
    // Same 500-entry cap spirit as the id sets above — trims oldest
    // (insertion-order) entries once it grows past what's worth keeping.
    final trimmed = current.length > 500
        ? Map<String, String>.fromEntries(current.entries.skip(current.length - 500))
        : current;
    await prefs.setString(_ncLastStatusKey, jsonEncode(trimmed));
  }
}
