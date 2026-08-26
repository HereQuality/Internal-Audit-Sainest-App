import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/notifications/background_entrypoints.dart';
import '../../core/notifications/event_poll.dart';
import '../../core/notifications/notification_bootstrap.dart';
import '../../core/notifications/notification_prefs.dart';
import '../../core/notifications/overdue_poll.dart';
import '../../core/utils/snackbar.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/profile_provider.dart';
import '../../providers/theme_provider.dart';
import 'edit_profile_screen.dart';

// One row per independently-toggleable notification type — each backed by
// its own NotificationPrefs key (readToggle default ON), diffed/emitted by
// core/notifications/event_poll.dart's background poll. Ordered to match
// the order they were asked for: assignment, then the two date reminders,
// then the three NC lifecycle events.
const _notificationTypes = [
  (
    key: NotificationPrefs.keyAuditAssigned,
    label: 'Audit Assigned',
    subtitle: 'A new audit is assigned to you',
    icon: Icons.assignment_ind_outlined,
  ),
  (
    key: NotificationPrefs.keyAuditStart,
    label: 'Audit Start Date',
    subtitle: 'An assigned audit\'s start date arrives',
    icon: Icons.play_circle_outline,
  ),
  (
    key: NotificationPrefs.keyAuditEnd,
    label: 'Audit Due Date',
    subtitle: 'An assigned audit\'s due date arrives',
    icon: Icons.event_busy_outlined,
  ),
  (
    key: NotificationPrefs.keyNcRaised,
    label: 'NC Raised',
    subtitle: 'A new NC is raised against you',
    icon: Icons.report_gmailerrorred_outlined,
  ),
  (
    key: NotificationPrefs.keyNcApproved,
    label: 'NC Approved',
    subtitle: 'Your NC response is approved',
    icon: Icons.check_circle_outline,
  ),
  (
    key: NotificationPrefs.keyNcRejected,
    label: 'NC Rejected',
    subtitle: 'Your NC response is rejected',
    icon: Icons.cancel_outlined,
  ),
];

// Server-side email toggles — mirrors the web dashboard's Settings page
// EMAIL_NOTIFICATION_TYPES list (client/src/pages/Settings.jsx) key-for-
// key, same order. Each key matches the `type` argument createNotification
// /notifyAssignees is called with (audit.controller.js / nc.controller.js
// / scheduledNotifications.js) and a key in server/models/Employee.js's
// preferences.emailNotificationTypes schema — distinct from
// _notificationTypes above, which are phone-local (no server field at
// all).
const _emailNotificationTypes = [
  (
    key: 'audit_created',
    label: 'New Audit Assigned',
    subtitle: "You're assigned as auditor/auditee on a new one-time audit.",
    icon: Icons.assignment_ind_outlined,
  ),
  (
    key: 'audit_series_created',
    label: 'New Recurring Series Assigned',
    subtitle: "You're assigned to a new recurring audit series.",
    icon: Icons.repeat,
  ),
  (
    key: 'audit_reassigned',
    label: 'Reassignments',
    subtitle: "You're added to or removed from an audit.",
    icon: Icons.swap_horiz,
  ),
  (
    key: 'audit_skipped',
    label: 'Audit Skipped',
    subtitle:
        'One of your audits is skipped (e.g. a company holiday or weekly off).',
    icon: Icons.event_busy_outlined,
  ),
  (
    key: 'audit_completed',
    label: 'Audit Completed',
    subtitle: 'One of your audits is marked Completed.',
    icon: Icons.task_alt_outlined,
  ),
  (
    key: 'nc_raised',
    label: 'New NC Raised',
    subtitle: 'A Non-Conformance is raised against you.',
    icon: Icons.report_gmailerrorred_outlined,
  ),
  (
    key: 'nc_responded',
    label: 'NC Response Submitted',
    subtitle:
        'Someone responds to a Non-Conformance you raised, awaiting your review.',
    icon: Icons.reply_outlined,
  ),
  (
    key: 'nc_approved',
    label: 'NC Response Approved',
    subtitle: 'Your NC response is accepted and the NC is closed.',
    icon: Icons.check_circle_outline,
  ),
  (
    key: 'nc_rejected',
    label: 'NC Response Rejected',
    subtitle: 'Your NC response is sent back for another attempt.',
    icon: Icons.cancel_outlined,
  ),
  (
    key: 'morning_summary',
    label: 'Morning Summary',
    subtitle:
        "9 AM digest — what's on your plate today and tomorrow, plus anything still overdue. Only sent on days you have something to show.",
    icon: Icons.wb_sunny_outlined,
  ),
  (
    key: 'evening_summary',
    label: 'Evening Summary',
    subtitle:
        '6 PM wrap-up — audits completed and NC responses actioned today. Only sent on days you had activity.',
    icon: Icons.nightlight_outlined,
  ),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  // null while the very first check is still in flight — the switch stays
  // disabled until then so it never renders a guessed on/off value.
  PermissionStatus? _notifStatus;
  bool _bgPollingEnabled = false;
  bool _busy = false;
  // key -> on/off, loaded once; null while still loading (per-type rows
  // stay disabled until then, same reasoning as _notifStatus above).
  Map<String, bool>? _typeToggles;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshNotifStatus();
    NotificationPrefs.readBackgroundPollingEnabled().then((v) {
      if (mounted) setState(() => _bgPollingEnabled = v);
    });
    _loadTypeToggles();
  }

  Future<void> _loadTypeToggles() async {
    final entries = await Future.wait(
      _notificationTypes.map(
        (t) async => MapEntry(t.key, await NotificationPrefs.readToggle(t.key)),
      ),
    );
    if (!mounted) return;
    setState(() => _typeToggles = Map.fromEntries(entries));
  }

  Future<void> _setTypeToggle(String key, bool value) async {
    setState(() => _typeToggles = {...?_typeToggles, key: value});
    await NotificationPrefs.setToggle(key, value);
  }

  // Shared by Dashboard Clock, Email Notifications, and the per-type email
  // toggles below — all server-side preferences.* fields, unlike the
  // local-only NotificationPrefs toggles above. Trusts the server's own
  // returned (already-merged) preferences rather than reconstructing the
  // merge here — same reasoning as the web dashboard's AuthContext
  // #updatePreferences — so a per-type toggle call (which only ever sends
  // the ONE key just flipped) can't accidentally clobber the others in
  // AuthProvider's cached copy.
  Future<void> _savePreference({
    bool? showDashboardClock,
    bool? emailNotifications,
    Map<String, bool>? emailNotificationTypes,
  }) async {
    final result = await context.read<ProfileProvider>().updatePreferences(
      showDashboardClock: showDashboardClock,
      emailNotifications: emailNotifications,
      emailNotificationTypes: emailNotificationTypes,
    );
    if (!mounted) return;
    if (result is String) {
      showErrorSnackBar(context, result);
      return;
    }
    final auth = context.read<AuthProvider>();
    final user = auth.user;
    if (user != null && result is UserPreferences) {
      auth.updateUser(user.copyWith(preferences: result));
    }
  }

  Future<void> _setEmailNotificationType(String key, bool value) =>
      _savePreference(emailNotificationTypes: {key: value});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The OS Settings screen (opened when permission is permanently denied)
  // is the only place that can change once permanently denied — re-check
  // on resume so the switch reflects whatever the user just did there
  // instead of staying stuck on its old value.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshNotifStatus();
  }

  Future<void> _refreshNotifStatus() async {
    final status = await Permission.notification.status;
    if (!mounted) return;
    setState(() => _notifStatus = status);
  }

  // Real on/off, not just an OS-permission passthrough: ON requests the
  // permission (if needed) and actually starts the overdue-NC background
  // poll — the Android foreground service behind the permanent "Watching
  // for overdue NCs" notification (see NOTIFICATIONS.md). OFF stops that
  // service right here, live, instead of only pointing at system settings
  // — this used to start unconditionally on every login with no way to
  // turn it back off short of denying notifications entirely.
  Future<void> _toggleNotifications(bool wantOn) async {
    // permission_handler can't re-prompt once permanently denied — only
    // the OS Settings screen can flip it back, whichever way the switch
    // was dragged.
    if (_notifStatus?.isPermanentlyDenied ?? false) {
      await openAppSettings();
      await _refreshNotifStatus();
      return;
    }
    setState(() => _busy = true);
    try {
      if (wantOn) {
        final granted = await NotificationBootstrap.requestPermissions();
        if (!mounted) return;
        if (!granted) {
          showErrorSnackBar(
            context,
            'Notifications are blocked for this app. Enable them from system settings to get overdue-NC reminders.',
          );
          await _refreshNotifStatus();
          return;
        }
        await NotificationPrefs.setBackgroundPollingEnabled(true);
        try {
          await startBackgroundPolling();
          await pollAndNotifyOverdueNcs();
          await pollAndNotifyEvents();
        } catch (e, st) {
          debugPrint('Failed to start notification polling: $e\n$st');
        }
      } else {
        await NotificationPrefs.setBackgroundPollingEnabled(false);
        try {
          await stopBackgroundPolling();
        } catch (e, st) {
          debugPrint('Failed to stop overdue-NC polling: $e\n$st');
        }
      }
      if (!mounted) return;
      setState(() => _bgPollingEnabled = wantOn);
      await _refreshNotifStatus();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final prefs = auth.user?.preferences;
    final hasEmailOnFile = (auth.user?.email ?? '').trim().isNotEmpty;
    // Same combined condition the Email Notifications switch's own
    // displayed `value` below already uses — the per-type list is only
    // meaningful once there's actually an address AND the master switch
    // is on, so it stays hidden rather than showing controls that
    // currently do nothing.
    final emailNotificationsEffectivelyOn =
        hasEmailOnFile && (prefs?.emailNotifications ?? true);
    final notifStatus = _notifStatus;
    final notifGranted = notifStatus?.isGranted ?? false;
    final remindersOn = notifGranted && _bgPollingEnabled;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: SwitchListTile(
              secondary: Icon(
                remindersOn
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: const Text('Notifications'),
              subtitle: Text(
                notifStatus == null
                    ? 'Checking permission…'
                    : notifStatus.isPermanentlyDenied
                    ? 'Blocked — tap to open system settings and allow notifications.'
                    : remindersOn
                    ? 'On — powers every notification type below.'
                    : 'Off — turn on to enable any notification type below.',
              ),
              value: remindersOn,
              onChanged: (notifStatus == null || _busy)
                  ? null
                  : _toggleNotifications,
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Text(
                        'NOTIFICATION TYPES',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                for (final t in _notificationTypes)
                  SwitchListTile(
                    dense: true,
                    secondary: Icon(t.icon, size: 20),
                    title: Text(t.label),
                    subtitle: Text(
                      t.subtitle,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    value: remindersOn && (_typeToggles?[t.key] ?? true),
                    onChanged: (_typeToggles == null || !remindersOn)
                        ? null
                        : (value) => _setTypeToggle(t.key, value),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.dark_mode_outlined),
              title: const Text('Dark Mode'),
              subtitle: const Text('Switch between light and dark theme'),
              // Local-only, on purpose — see ThemeProvider's own comment.
              // Does NOT call ProfileProvider.updatePreferences anymore:
              // that field is the web dashboard's own theme setting, and
              // this used to overwrite it (and get overwritten by it).
              value: context.watch<ThemeProvider>().mode == ThemeMode.dark,
              onChanged: (value) =>
                  context.read<ThemeProvider>().setDark(value),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.access_time_outlined),
              title: const Text('Dashboard Clock'),
              subtitle: const Text('Show a real-time clock on your dashboard'),
              value: prefs?.showDashboardClock ?? true,
              onChanged: (value) => _savePreference(showDashboardClock: value),
            ),
          ),
          const SizedBox(height: 12),
          // Same server-side preferences.emailNotifications field as the web
          // dashboard's Settings > Notifications switch — toggling it here
          // or there both change the one thing: whether this account also
          // gets an email alongside its in-app notifications (which stay
          // always-on regardless, same as web). Distinct from the
          // "Notifications" switch up top, which only controls whether THIS
          // phone fires its own local reminders.
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.mail_outline),
              title: const Text('Email Notifications'),
              subtitle: Text(
                hasEmailOnFile
                    ? 'Also send these as an email, to the address on your Profile.'
                    : 'No email on file — add one on your Profile to actually receive these.',
              ),
              value: hasEmailOnFile && (prefs?.emailNotifications ?? true),
              onChanged: !hasEmailOnFile
                  ? null
                  : (value) => _savePreference(emailNotifications: value),
            ),
          ),
          if (!hasEmailOnFile)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EditProfileScreen()),
                ),
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('Add an email on your Profile'),
              ),
            ),
          if (emailNotificationsEffectivelyOn) ...[
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Row(
                      children: [
                        Text(
                          'EMAIL NOTIFICATION TYPES',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      'Pick which of these you actually want as email — turning one off here only stops its email, the in-app notification still fires.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                  for (final t in _emailNotificationTypes)
                    SwitchListTile(
                      dense: true,
                      secondary: Icon(t.icon, size: 20),
                      title: Text(t.label),
                      subtitle: Text(
                        t.subtitle,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      value: prefs?.emailNotificationTypes[t.key] ?? true,
                      onChanged: (value) =>
                          _setEmailNotificationType(t.key, value),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
