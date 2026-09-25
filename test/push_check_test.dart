import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/notifications/push_check.dart';

/// The wording behind Settings > "Send a test notification": what the person
/// is told for each way a push can fail to reach this phone.
Map<String, dynamic> _body({
  List<Map<String, dynamic>> results = const [],
  List<String> serverProjects = const ['proj-server'],
}) => {
  'isOk': true,
  'data': {
    'sent': results.where((r) => r['ok'] == true).length,
    'failed': results.where((r) => r['ok'] != true).length,
    'results': results,
    'serverProjects': serverProjects,
  },
};

void main() {
  const local = ['Permission on this phone: authorized'];

  test('no registration for this platform: says to allow and reopen', () {
    // Another phone (android) is registered; that says nothing about this iPhone.
    final check = describePushTestResponse(
      _body(results: [
        {'platform': 'android', 'ok': true, 'code': null},
      ]),
      platform: 'ios',
      localLines: local,
    );

    expect(check.ok, isFalse);
    expect(check.title, contains("isn't registered"));
    expect(check.lines.join('\n'), contains('Allow notifications'));
    expect(check.lines, contains(local.first));
  });

  test('an empty result list is also "not registered"', () {
    final check = describePushTestResponse(_body(), platform: 'ios');

    expect(check.ok, isFalse);
    expect(check.title, contains("isn't registered"));
  });

  test('a send that Firebase accepted is reported as sent, with the DND advice', () {
    final check = describePushTestResponse(
      _body(results: [
        {'platform': 'ios', 'ok': true, 'code': null},
      ]),
      platform: 'ios',
      localLines: local,
    );

    expect(check.ok, isTrue);
    expect(check.title, 'Test notification sent');
    expect(check.lines.first, contains('Do Not Disturb'));
    expect(check.lines.join('\n'), contains('proj-server'));
  });

  test("another phone's failure does not fail this phone's check", () {
    final check = describePushTestResponse(
      _body(results: [
        {'platform': 'ios', 'ok': true, 'code': null},
        {'platform': 'android', 'ok': false, 'code': 'messaging/third-party-auth-error'},
      ]),
      platform: 'ios',
    );

    expect(check.ok, isTrue);
  });

  test('shows the server hint next to the error code (wrong Firebase project)', () {
    final check = describePushTestResponse(
      _body(results: [
        {
          'platform': 'ios',
          'ok': false,
          'code': 'push/project-not-configured',
          'hint': 'this phone\'s app is registered to Firebase project "a" but the server only has b',
        },
      ]),
      platform: 'ios',
    );

    expect(check.ok, isFalse);
    expect(check.lines.first, startsWith('push/project-not-configured: '));
    expect(check.lines.first, contains('Firebase project "a"'));
  });

  test('a stale registration is explained without jargon', () {
    final check = describePushTestResponse(
      _body(results: [
        {'platform': 'ios', 'ok': false, 'code': 'messaging/registration-token-not-registered'},
      ]),
      platform: 'ios',
    );

    expect(check.ok, isFalse);
    expect(check.lines.first, contains('stale'));
    expect(check.lines.first, contains('reopen'));
  });

  test('an unknown error code is shown as is rather than hidden', () {
    final check = describePushTestResponse(
      _body(results: [
        {'platform': 'ios', 'ok': false, 'code': 'messaging/internal-error'},
      ]),
      platform: 'ios',
    );

    expect(check.lines.first, 'messaging/internal-error');
  });

  test('tolerates a malformed body', () {
    expect(describePushTestResponse({}, platform: 'ios').ok, isFalse);
    expect(describePushTestResponse({'data': 'x'}, platform: 'ios').ok, isFalse);
    expect(
      describePushTestResponse({
        'data': {'results': 'nope'},
      }, platform: 'ios').ok,
      isFalse,
    );
  });
}
