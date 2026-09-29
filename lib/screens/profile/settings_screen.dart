import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/notification_bootstrap.dart';
import '../../core/notifications/notification_prefs.dart';
import '../../core/notifications/notification_scheduler.dart';
import '../../core/notifications/push_check.dart';
import '../../core/utils/snackbar.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/profile_provider.dart';
import '../../providers/theme_provider.dart';
import '../../widgets/max_width_scroll.dart';
import 'edit_profile_screen.dart';

/// iOS asks and reports through Firebase (the same source
/// NotificationBootstrap.requestPermissions uses there) because
/// permission_handler's iOS notification support only exists when a native
/// build flag is set; everywhere else it's permission_handler.
Future<PushPermission> _readPermission() async {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      final settings = await FirebaseMessaging.instance.getNotificationSettings();
      final status = settings.authorizationStatus;
      if (status == AuthorizationStatus.authorized ||
          status == AuthorizationStatus.provisional) {
        return PushPermission.granted;
      }
      return status == AuthorizationStatus.notDetermined
          ? PushPermission.notAsked
          : PushPermission.blocked;
    } catch (_) {
      // Firebase isn't set up on this build — fall through to the generic
      // check rather than showing nothing.
    }
  }
  final status = await Permission.notification.status;
  if (status.isGranted || status.isProvisional) return PushPermission.granted;
  if (status.isPermanentlyDenied) return PushPermission.blocked;
  // Android below 13 has no notification prompt at all: notifications turned
  // off in the system settings read as plain "denied" there, and request()
  // cannot show anything, so an "Allow" button would do nothing. Android 13+
  // also says "denied" for a permission it may still ask for (denied once) —
  // there the OS says whether a request can still put a dialog up. Every
  // login and every launch of the app shell has already asked by the time
  // this screen can open, so "denied and no dialog possible" means only the
  // system settings can change it.
  if (defaultTargetPlatform == TargetPlatform.android &&
      status.isDenied &&
      !await _canAskAgain()) {
    return PushPermission.blocked;
  }
  return PushPermission.notAsked;
}

Future<bool> _canAskAgain() async {
  try {
    return await Permission.notification.shouldShowRequestRationale;
  } catch (_) {
    // No activity to ask about (or the plugin failed): keep offering "Allow".
    return true;
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  // Null until the first OS read lands, so the status line never renders a
  // guessed state.
  PushPermission? _permission;
  // Where this phone's registration with the server stands (token accepted,
  // server able to send...) — read off FcmService, null until the first read.
  PushRegistration? _registration;
  // True while the status line's "Try again" is waiting for its attempt.
  bool _retrying = false;
  // FcmService has no change notifications (it is written to from many places
  // and outside a widget's control), so the line looks again every few
  // seconds while this screen is open. Each look is a couple of in-memory
  // reads and rebuilds only when the answer changed.
  Timer? _pushTimer;
  // Set while a switch change is in flight so the switch shows where it's
  // headed (and is locked) instead of looking dead until the server
  // answers; dropped again the moment the outcome is known.
  bool? _pendingPush;
  bool? _pendingEmail;
  // Per-topic values a request is still carrying, shown in place of the
  // stored ones so a tapped switch moves at once instead of waiting for the
  // server. An entry is dropped as soon as its request settles: on success
  // the stored value now says the same, on failure it is the rollback.
  final Map<String, bool> _pendingEmailTypes = {};
  final Map<String, bool> _pendingPushTypes = {};
  // Every save on this screen goes through this one queue. Each response
  // carries the FULL merged preferences, so two requests overlapping would
  // let the older response (which predates the newer change) put the newer
  // change back to its old value on screen; one at a time keeps every
  // response a superset of the ones before it.
  Future<void> _saveQueue = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermission().then((_) {
      // Opening Settings also nudges a registration that ran out of retries
      // (the login-time attempt met a flaky connection) instead of leaving
      // "not registered" up until the next resume. A no-op once registered.
      if (_permission == PushPermission.granted) unawaited(_retryRegistration());
    });
    _refreshPush();
    _pushTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshPush());
    // A 'preferences_updated' socket event can be missed (a half-open
    // connection looks alive on a phone) — catch up on opening, so this
    // screen never shows switches that disagree with the web's.
    context.read<AuthProvider>().refreshPreferences();
  }

  @override
  void dispose() {
    _pushTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The OS Settings screen (opened by "Open settings") is the only place a
  // blocked permission can change — re-check on resume so the status line
  // reflects whatever the user just did there instead of staying stuck.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }

  Future<void> _onResumed() async {
    final wasDenied =
        _permission == PushPermission.notAsked ||
        _permission == PushPermission.blocked;
    await _refreshPermission();
    // Allowed from the OS settings while this screen was open: finish the
    // device setup the login-time attempt couldn't (token + polling)
    // instead of waiting for the next login.
    if (mounted && wasDenied && _permission == PushPermission.granted) {
      await _finishDeviceSetup();
    }
    await _refreshPush();
  }

  Future<void> _refreshPermission() async {
    final next = await _readPermission();
    if (!mounted) return;
    setState(() => _permission = next);
  }

  Future<void> _refreshPush() async {
    var next = FcmService.registrationState;
    // A test push the server could not deliver to this phone is remembered
    // beside the registration (the polls read it too); "Active" under a
    // dialog that just said otherwise would be the same lie as before.
    if (next == PushRegistration.registered && !await NotificationPrefs.readFcmPushReady()) {
      next = PushRegistration.cannotDeliver;
    }
    if (!mounted || next == _registration) return;
    setState(() => _registration = next);
  }

  // Registers this phone with the server and starts/stops the Android
  // polling fallback to match the account's current push switch. Both are
  // idempotent, so overlapping with the login-time attempt is harmless.
  Future<void> _finishDeviceSetup() async {
    await FcmService.registerToken();
    if (!mounted) return;
    final pushOn =
        context.read<AuthProvider>().user?.preferences.pushNotifications ??
        true;
    await NotificationScheduler.onPushPreferenceChanged(pushOn);
  }

  // Shared by every server-backed switch below. Trusts the server's own
  // returned (already-merged) preferences rather than reconstructing the
  // merge here — same reasoning as the web dashboard's AuthContext
  // #updatePreferences. The result is applied even if this screen was left
  // while the request was in flight (the server already saved it). Returns
  // whether the change was saved.
  Future<bool> _savePreference({
    bool? showDashboardClock,
    bool? emailNotifications,
    bool? pushNotifications,
    Map<String, bool>? emailNotificationTypes,
    Map<String, bool>? pushNotificationTypes,
  }) {
    final auth = context.read<AuthProvider>();
    final profile = context.read<ProfileProvider>();

    Future<bool> send() async {
      final result = await profile.updatePreferences(
        showDashboardClock: showDashboardClock,
        emailNotifications: emailNotifications,
        pushNotifications: pushNotifications,
        emailNotificationTypes: emailNotificationTypes,
        pushNotificationTypes: pushNotificationTypes,
      );
      if (result is UserPreferences) {
        auth.applyPreferences(result);
        return true;
      }
      if (result is String && mounted) showErrorSnackBar(context, result);
      return false;
    }

    final saved = _saveQueue.then((_) => send());
    // A save that throws (a malformed response) must not wedge the queue and
    // take every later save down with it.
    _saveQueue = saved.then((_) {}, onError: (_) {});
    return saved;
  }

  // The account-level switch is saved FIRST and on its own — it must not
  // depend on this phone's OS permission (a person can turn push on here
  // while the OS still blocks it, and it then simply starts working on the
  // web and the moment the OS allows it). A failed device step only
  // changes the status line below the switch; it never flips the switch
  // back.
  Future<void> _setPush(bool on) async {
    setState(() => _pendingPush = on);
    bool saved = false;
    try {
      saved = await _savePreference(pushNotifications: on);
    } finally {
      // The switch is settled either way (saved: the account value now
      // says so; failed: back to what it was) — the OS prompt and token
      // registration below can take a while and must not keep it locked.
      if (mounted) setState(() => _pendingPush = null);
    }
    if (!saved || !mounted) return;
    if (on) await _requestPermissionAndSetUp();
    await _refreshPermission();
    await _refreshPush();
  }

  Future<void> _setEmail(bool on) async {
    setState(() => _pendingEmail = on);
    try {
      await _savePreference(emailNotifications: on);
    } finally {
      if (mounted) setState(() => _pendingEmail = null);
    }
  }

  bool _emailValue(UserPreferences? prefs, String key) =>
      _pendingEmailTypes[key] ?? prefs?.emailTypeOn(key) ?? true;

  bool _pushValue(UserPreferences? prefs, String key) =>
      _pendingPushTypes[key] ?? prefs?.pushTypeOn(key) ?? true;

  // One topic's switch, or a group's "all on / all off" (a whole column at
  // once). Both of a topic's channel values always travel together, the
  // untouched one included: the server keeps honouring the old shared
  // setting for a channel that was never set explicitly, and sending both is
  // what ends that for the topic. Saved optimistically — the switch moves
  // now, and snaps back (with the error snackbar _savePreference shows) if
  // the server refuses.
  Future<void> _changeTopics(
    Iterable<NotificationTopic> topics, {
    bool? email,
    bool? push,
  }) async {
    final prefs = context.read<AuthProvider>().user?.preferences;
    final emailValues = <String, bool>{};
    final pushValues = <String, bool>{};
    var changes = false;
    for (final topic in topics) {
      for (final key in topic.keys) {
        final emailNow = _emailValue(prefs, key);
        final pushNow = _pushValue(prefs, key);
        if (topic.emailApplies) {
          emailValues[key] = email ?? emailNow;
          if (email != null && email != emailNow) changes = true;
        }
        pushValues[key] = push ?? pushNow;
        if (push != null && push != pushNow) changes = true;
      }
    }
    if (!changes) return;

    setState(() {
      _pendingEmailTypes.addAll(emailValues);
      _pendingPushTypes.addAll(pushValues);
    });
    try {
      await _savePreference(
        emailNotificationTypes: emailValues,
        pushNotificationTypes: pushValues,
      );
    } finally {
      if (mounted) {
        setState(() {
          _settle(_pendingEmailTypes, emailValues);
          _settle(_pendingPushTypes, pushValues);
        });
      }
    }
  }

  // Drops what a finished request was carrying — but not a key a LATER,
  // still-queued request has since claimed with a different value.
  void _settle(Map<String, bool> pending, Map<String, bool> sent) {
    sent.forEach((key, value) {
      if (pending[key] == value) pending.remove(key);
    });
  }

  // Asks the OS (a no-op when already granted, and unable to re-prompt once
  // permanently denied — that's what "Open settings" is for), then
  // finishes the device setup if it said yes.
  Future<void> _requestPermissionAndSetUp() async {
    try {
      if (await NotificationBootstrap.requestPermissions()) {
        await _finishDeviceSetup();
      }
    } catch (e, st) {
      debugPrint('Settings: enabling push on this phone failed: $e\n$st');
    }
  }

  Future<void> _allowOnThisPhone() async {
    await _requestPermissionAndSetUp();
    await _refreshPermission();
    await _refreshPush();
  }

  // The status line's "Try again" (and the nudge on opening): the same thing a
  // resume does, on demand.
  Future<void> _retryRegistration() async {
    if (_retrying || !mounted) return;
    setState(() => _retrying = true);
    try {
      await FcmService.ensureRegistered();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
    await _refreshPush();
  }

  // Coming back from the OS settings re-checks via _onResumed.
  Future<void> _openSystemSettings() => openAppSettings();

  // "Try again" shows as an attempt under way the moment it is tapped, before
  // FcmService has started one.
  PushBadge _badge(PushPermission permission, PushRegistration registration) {
    final badge = resolvePushBadge(permission: permission, registration: registration);
    return _retrying && badge == PushBadge.notRegistered ? PushBadge.registering : badge;
  }

  bool _testingPush = false;

  // Sends a real push to THIS phone and says plainly what happened — the one
  // tap that tells "no token", "not registered", "server can't reach this
  // phone's Firebase project", "Apple key missing" and "delivered" apart.
  Future<void> _sendTestPush() async {
    if (_testingPush) return;
    setState(() => _testingPush = true);
    final PushCheck check = await FcmService.runPushCheck();
    if (!mounted) return;
    setState(() => _testingPush = false);
    // The check may have (re)registered the phone or found it undeliverable:
    // the status line behind the dialog follows.
    unawaited(_refreshPush());
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(
          check.ok ? Icons.check_circle_outline : Icons.error_outline,
          color: check.ok
              ? Theme.of(dialogContext).colorScheme.primary
              : Theme.of(dialogContext).colorScheme.error,
        ),
        title: Text(check.title),
        content: SingleChildScrollView(
          child: SelectableText(check.lines.join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Under the Push switch, only while it's on (with it off, the phone's
  // permission is irrelevant and "Active" would be a lie). One line for the
  // whole chain a push travels — OS permission, this phone's token on the
  // server, a server able to send — so "Active" is only said when all of it
  // holds. The server's own problem text (Firebase project ids, env-var names)
  // stays in the test dialog; the line only points there.
  Widget _statusLine(BuildContext context, PushBadge badge) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, text, hint, actionLabel, onAction) = switch (badge) {
      PushBadge.active => (
        Icons.check_circle_outline,
        scheme.primary,
        'Active on this phone',
        null,
        null,
        null,
      ),
      PushBadge.notAllowed => (
        Icons.info_outline,
        scheme.outline,
        'Not allowed on this phone yet',
        null,
        'Allow',
        _allowOnThisPhone,
      ),
      PushBadge.blocked => (
        Icons.block,
        scheme.error,
        'Blocked in system settings',
        null,
        'Open settings',
        _openSystemSettings,
      ),
      PushBadge.registering => (
        Icons.sync,
        scheme.outline,
        'Registering this phone for push…',
        'It keeps retrying by itself.',
        null,
        null,
      ),
      PushBadge.notRegistered => (
        Icons.sync_problem,
        scheme.error,
        "This phone isn't registered for push yet",
        'Check the connection, then try again.',
        'Try again',
        _retryRegistration,
      ),
      PushBadge.cannotDeliver => (
        Icons.error_outline,
        scheme.error,
        "Registered, but the server can't send to this phone",
        'Tap "Send a test notification" for the reason.',
        null,
        null,
      ),
      PushBadge.notSetUp => (
        Icons.info_outline,
        scheme.outline,
        "Phone push isn't available in this build",
        null,
        null,
        null,
      ),
    };
    // 72 = the SwitchListTile's own leading icon + gap, so the line lines up
    // under its title.
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 8, 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(fontSize: 12, color: color)),
                if (hint != null)
                  Text(
                    hint,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
              ],
            ),
          ),
          if (actionLabel != null)
            TextButton(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }

  // Under the status line, once notifications are allowed on this phone.
  Widget _testPushRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(64, 0, 8, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _testingPush ? null : _sendTestPush,
          icon: _testingPush
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined, size: 18),
          label: Text(_testingPush ? 'Sending…' : 'Send a test notification'),
        ),
      ),
    );
  }

  // Why a whole column is greyed out, right under the section title — once
  // per master that is off rather than repeated in every group.
  Widget _masterOffHint(BuildContext context, String text) {
    final color = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title, {String? caption}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 2),
            Text(
              caption,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final prefs = auth.user?.preferences;
    final hasEmailOnFile = (auth.user?.email ?? '').trim().isNotEmpty;
    final pushOn = _pendingPush ?? prefs?.pushNotifications ?? true;
    final emailOn = _pendingEmail ?? prefs?.emailNotifications ?? true;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: MaxWidthScroll(
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // The account's push switch — the SAME server-side preference as
          // the web Settings page's Push switch, so flipping it there or
          // here changes it for both, and it covers every notification type
          // (including support tickets), on the phone and in the browser.
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: Icon(
                    pushOn
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                  ),
                  title: const Text('Push Notifications'),
                  subtitle: const Text(
                    'Alerts on your phone and in your browser, including support tickets.',
                  ),
                  value: pushOn,
                  onChanged: _pendingPush == null ? _setPush : null,
                ),
                if (pushOn && _permission != null && _registration != null)
                  _statusLine(context, _badge(_permission!, _registration!)),
                if (pushOn && _permission == PushPermission.granted)
                  _testPushRow(context),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Same server-side preferences.emailNotifications field as the web
          // dashboard's Settings > Notifications switch — toggling it here
          // or there both change the one thing: whether this account also
          // gets an email alongside its in-app notifications (which stay
          // always-on regardless, same as web). Always toggleable, even with
          // no address on file, same as web — the caption below says what's
          // missing.
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.mail_outline),
              title: const Text('Email Notifications'),
              subtitle: Text(
                hasEmailOnFile
                    ? 'Also send these as an email, to the address on your Profile.'
                    : 'No email on file — add one on your Profile to actually receive these.',
              ),
              value: emailOn,
              onChanged: _pendingEmail == null ? _setEmail : null,
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
          // The two switches above are the masters; each topic below has its
          // own Email and Push switch that only counts while its master is
          // on. A master that is off greys its column out (the stored
          // values stay visible, they just can't be edited) and the hint
          // says why.
          _sectionTitle(
            context,
            'Choose what you get',
            caption:
                'Pick email, push or both for each topic. Everything always '
                'shows up in your in-app notifications.',
          ),
          if (!pushOn)
            _masterOffHint(
              context,
              'Turn on Push notifications above to choose.',
            ),
          if (!emailOn)
            _masterOffHint(
              context,
              'Turn on Email notifications above to choose.',
            ),
          for (final group in kNotificationGroups) ...[
            _TopicGroupCard(
              group: group,
              topics: [
                for (final topic in kNotificationTopics)
                  if (topic.group == group) topic,
              ],
              emailEnabled: emailOn,
              pushEnabled: pushOn,
              emailValue: (key) => _emailValue(prefs, key),
              pushValue: (key) => _pushValue(prefs, key),
              onTopic: (topic, {email, push}) =>
                  _changeTopics([topic], email: email, push: push),
              onGroup: (topics, {email, push}) =>
                  _changeTopics(topics, email: email, push: push),
            ),
            const SizedBox(height: 12),
          ],
          _sectionTitle(context, 'Display'),
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
        ],
        ),
      ),
    );
  }
}

/// Width of the Email and Push columns — the group header's shortcut menus
/// and every row's switches share it, which is what lines them up.
const double _channelColumnWidth = 64;

typedef _TopicChange =
    void Function(NotificationTopic topic, {bool? email, bool? push});
typedef _GroupChange =
    void Function(List<NotificationTopic> topics, {bool? email, bool? push});

/// One group of topics as a card: a header with the two channel columns'
/// "all on / all off" shortcuts, then a row per topic.
class _TopicGroupCard extends StatelessWidget {
  const _TopicGroupCard({
    required this.group,
    required this.topics,
    required this.emailEnabled,
    required this.pushEnabled,
    required this.emailValue,
    required this.pushValue,
    required this.onTopic,
    required this.onGroup,
  });

  final String group;
  final List<NotificationTopic> topics;
  // Whether the account's master switch for that channel is on — off greys
  // the whole column out and locks it.
  final bool emailEnabled;
  final bool pushEnabled;
  final bool Function(String key) emailValue;
  final bool Function(String key) pushValue;
  final _TopicChange onTopic;
  final _GroupChange onGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _ChannelMenu(
                  label: 'Email',
                  group: group,
                  enabled: emailEnabled,
                  onSelected: (on) => onGroup(topics, email: on),
                ),
                _ChannelMenu(
                  label: 'Push',
                  group: group,
                  enabled: pushEnabled,
                  onSelected: (on) => onGroup(topics, push: on),
                ),
              ],
            ),
          ),
          for (final topic in topics) ...[
            const Divider(height: 1),
            _TopicRow(
              topic: topic,
              // A combined row (topic.keys has more than one) reads as ON
              // only while EVERY one of its real keys is — same rule the
              // web app's Settings.jsx uses for its own combined row.
              emailOn: topic.keys.every(emailValue),
              pushOn: topic.keys.every(pushValue),
              emailEnabled: emailEnabled,
              pushEnabled: pushEnabled,
              onEmail: (on) => onTopic(topic, email: on),
              onPush: (on) => onTopic(topic, push: on),
            ),
          ],
        ],
      ),
    );
  }
}

/// A column header that doubles as that column's "all on / all off" shortcut
/// for the group.
class _ChannelMenu extends StatelessWidget {
  const _ChannelMenu({
    required this.label,
    required this.group,
    required this.enabled,
    required this.onSelected,
  });

  final String label;
  final String group;
  final bool enabled;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = enabled
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: 0.38);
    return SizedBox(
      width: _channelColumnWidth,
      child: PopupMenuButton<bool>(
        enabled: enabled,
        tooltip: '$label for every topic in $group',
        padding: EdgeInsets.zero,
        onSelected: onSelected,
        itemBuilder: (_) => const [
          PopupMenuItem(value: true, child: Text('All on')),
          PopupMenuItem(value: false, child: Text('All off')),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 18, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One topic: its name and a line on when it fires, then the Email and Push
/// switches. A topic with no email (the on-phone audit reminders) shows a
/// dash in the Email column instead of a switch that could do nothing.
class _TopicRow extends StatelessWidget {
  const _TopicRow({
    required this.topic,
    required this.emailOn,
    required this.pushOn,
    required this.emailEnabled,
    required this.pushEnabled,
    required this.onEmail,
    required this.onPush,
  });

  final NotificationTopic topic;
  final bool emailOn;
  final bool pushOn;
  final bool emailEnabled;
  final bool pushEnabled;
  final ValueChanged<bool> onEmail;
  final ValueChanged<bool> onPush;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(topic.label, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    topic.description,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: _channelColumnWidth,
            child: Center(
              child: topic.emailApplies
                  ? Semantics(
                      label: '${topic.label}, email',
                      child: Switch(
                        value: emailOn,
                        onChanged: emailEnabled ? onEmail : null,
                      ),
                    )
                  : Semantics(
                      label: '${topic.label} has no email',
                      excludeSemantics: true,
                      child: Text(
                        '—',
                        style: TextStyle(color: theme.colorScheme.outline),
                      ),
                    ),
            ),
          ),
          SizedBox(
            width: _channelColumnWidth,
            child: Center(
              child: Semantics(
                label: '${topic.label}, push',
                child: Switch(
                  value: pushOn,
                  onChanged: pushEnabled ? onPush : null,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
