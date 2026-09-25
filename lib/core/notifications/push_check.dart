/// What "Send a test notification" (Settings) tells the person: did a real
/// push leave the server for THIS phone, and if not, what to fix. Kept free
/// of Firebase/Flutter so the wording can be unit-tested; the plumbing that
/// gathers the phone's own state lives in FcmService.runPushCheck.
class PushCheck {
  const PushCheck({required this.ok, required this.title, required this.lines});

  final bool ok;
  final String title;
  final List<String> lines;
}

/// Turns the answer of `POST /device-tokens/test` into a [PushCheck].
///
/// [body] is the whole response: `{ isOk, message, data: { sent, failed,
/// results: [{ platform, ok, code, hint? }], serverProjects } }`. [platform]
/// is this phone's ('ios' | 'android') — the same account can have other
/// phones registered, and their results say nothing about this one.
/// [localLines] are facts read off the phone itself (permission, Apple push
/// token, Firebase project) and are appended so one screenshot carries the
/// whole picture.
PushCheck describePushTestResponse(
  Map<String, dynamic> body, {
  required String platform,
  List<String> localLines = const [],
}) {
  final data = body['data'] is Map
      ? Map<String, dynamic>.from(body['data'] as Map)
      : <String, dynamic>{};
  final results = (data['results'] is List ? data['results'] as List : const [])
      .whereType<Map>()
      .map((r) => Map<String, dynamic>.from(r))
      .toList();
  final mine = results.where((r) => r['platform'] == platform).toList();
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

  if (mine.any((r) => r['ok'] == true)) {
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

  final reasons = <String>{};
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
