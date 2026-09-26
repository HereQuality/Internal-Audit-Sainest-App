// What the Push status line and "Send a test notification" (Settings) tell the
// person: is push really working on THIS phone, and if not, what to fix. Kept
// free of Firebase/Flutter so the wording and the decisions can be
// unit-tested; the plumbing that gathers the phone's own state lives in
// FcmService (registrationState, runPushCheck).

/// What the OS currently says about this app posting notifications.
enum PushPermission { granted, notAsked, blocked }

/// What this phone knows about its own push registration.
enum PushRegistration {
  /// No working Firebase configuration in this build.
  notSetUp,

  /// An attempt is on the wire, or waiting for its next backoff retry.
  registering,

  /// The server holds this phone's token and says it can send to it.
  registered,

  /// The server holds the token but cannot send to it (it has no credentials
  /// for this app's Firebase project), or a test push to it just failed.
  cannotDeliver,

  /// The server has no token from this phone and nothing is pending: the
  /// attempts and their backoff ran out (the next resume or reconnect tries
  /// again).
  notRegistered,
}

/// The one thing the status line under the Push switch says.
enum PushBadge {
  active,
  notAllowed,
  blocked,
  registering,
  notRegistered,
  cannotDeliver,
  notSetUp,
}

/// "Active" needs the OS permission AND a registered token AND a server that
/// can send — the permission alone used to be enough, so a phone that could
/// never receive anything read as working. The permission comes first: it is
/// the one problem the person can fix from that very line.
PushBadge resolvePushBadge({
  required PushPermission permission,
  required PushRegistration registration,
}) {
  switch (permission) {
    case PushPermission.notAsked:
      return PushBadge.notAllowed;
    case PushPermission.blocked:
      return PushBadge.blocked;
    case PushPermission.granted:
      break;
  }
  return switch (registration) {
    PushRegistration.notSetUp => PushBadge.notSetUp,
    PushRegistration.registering => PushBadge.registering,
    PushRegistration.registered => PushBadge.active,
    PushRegistration.cannotDeliver => PushBadge.cannotDeliver,
    PushRegistration.notRegistered => PushBadge.notRegistered,
  };
}

class PushCheck {
  const PushCheck({required this.ok, required this.title, required this.lines});

  final bool ok;
  final String title;
  final List<String> lines;
}

List<Map<String, dynamic>> _resultsOf(Map<String, dynamic> body) {
  final data = body['data'] is Map ? body['data'] as Map : const {};
  return (data['results'] is List ? data['results'] as List : const [])
      .whereType<Map>()
      .map((r) => Map<String, dynamic>.from(r))
      .toList();
}

/// The results in a test answer that speak for THIS phone: the rows of this
/// phone's platform. When the request named this phone's token
/// ([thisPhoneOnly]) a current server answers for that one row alone, so at
/// most one row is left. A server that predates the field answers for every
/// phone of the account instead, and when that leaves several phones of this
/// platform nothing in the answer says which one is this phone ([ambiguous]).
({List<Map<String, dynamic>> mine, bool ambiguous}) _resultsForThisPhone(
  List<Map<String, dynamic>> results, {
  required String platform,
  required bool thisPhoneOnly,
}) {
  final mine = results.where((r) => r['platform'] == platform).toList();
  return (mine: mine, ambiguous: thisPhoneOnly && mine.length > 1);
}

/// Whether Firebase accepted the test push for this phone: true or false, or
/// null when the answer says nothing about it (no result for this phone).
/// Several phones and no way to tell which is ours ([_resultsForThisPhone])
/// only count as delivered when every one of them was.
bool? pushTestDelivered(
  Map<String, dynamic> body, {
  required String platform,
  bool thisPhoneOnly = false,
}) {
  final found = _resultsForThisPhone(
    _resultsOf(body),
    platform: platform,
    thisPhoneOnly: thisPhoneOnly,
  );
  if (found.mine.isEmpty) return null;
  return found.ambiguous
      ? found.mine.every((r) => r['ok'] == true)
      : found.mine.any((r) => r['ok'] == true);
}

/// Turns the answer of `POST /device-tokens/test` into a [PushCheck].
///
/// [body] is the whole response: `{ isOk, message, data: { sent, failed,
/// results: [{ tokenId, platform, ok, code, hint? }], serverProjects } }`.
/// [platform] is this phone's ('ios' | 'android'). [thisPhoneOnly] says the
/// request carried this phone's own FCM token, so the server sent to that
/// token only and `results` is empty when the token isn't registered to the
/// account; without it the same account's other phones answer too and only
/// the platform tells them apart (older builds and servers).
/// [localLines] are facts read off the phone itself (permission, Apple push
/// token, Firebase project) and are appended so one screenshot carries the
/// whole picture.
PushCheck describePushTestResponse(
  Map<String, dynamic> body, {
  required String platform,
  bool thisPhoneOnly = false,
  List<String> localLines = const [],
}) {
  final data = body['data'] is Map
      ? Map<String, dynamic>.from(body['data'] as Map)
      : <String, dynamic>{};
  final found = _resultsForThisPhone(
    _resultsOf(body),
    platform: platform,
    thisPhoneOnly: thisPhoneOnly,
  );
  final mine = found.mine;
  final projects = data['serverProjects'] is List
      ? (data['serverProjects'] as List).map((e) => '$e').toList()
      : const <String>[];
  final serverLine = projects.isEmpty
      ? null
      : 'Server can send for Firebase project: ${projects.join(', ')}';
  final extra = [?serverLine, ...localLines];

  if (mine.isEmpty) {
    return PushCheck(
      ok: false,
      title: "This phone isn't registered for push",
      lines: [
        "The server has no push registration for this phone. Allow notifications "
            "for this app, then close and reopen it (or log out and in).",
        ...extra,
      ],
    );
  }

  if (pushTestDelivered(body, platform: platform, thisPhoneOnly: thisPhoneOnly) == true) {
    return PushCheck(
      ok: true,
      title: 'Test notification sent',
      lines: [
        'It should appear on this phone within a few seconds. If it does not, '
            'check Focus / Do Not Disturb and this app\'s notification '
            'settings in the phone\'s Settings.',
        ...extra,
      ],
    );
  }

  final reasons = <String>{
    if (found.ambiguous)
      'The server answered for several phones on this account and cannot say '
          'which one is this phone, so a failure below may belong to another one.',
  };
  for (final r in mine) {
    final code = '${r['code'] ?? 'unknown'}';
    final hint = r['hint'];
    reasons.add(
      hint is String && hint.isNotEmpty
          ? '$code: $hint'
          : code == 'messaging/registration-token-not-registered'
          ? 'This phone\'s registration had gone stale and was removed. '
                'Close and reopen the app, then try again.'
          : code,
    );
  }
  return PushCheck(
    ok: false,
    title: "The server couldn't deliver the test",
    lines: [...reasons, ...extra],
  );
}
