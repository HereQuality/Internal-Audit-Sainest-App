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

  group('a test aimed at this phone\'s own token', () {
    test('speaks for the one row the server answered with', () {
      final check = describePushTestResponse(
        _body(results: [
          {'platform': 'ios', 'ok': true, 'code': null},
        ]),
        platform: 'ios',
        thisPhoneOnly: true,
      );

      expect(check.ok, isTrue);
    });

    test('a row of another platform is not this phone', () {
      final check = describePushTestResponse(
        _body(results: [
          {'platform': 'android', 'ok': true, 'code': null},
        ]),
        platform: 'ios',
        thisPhoneOnly: true,
      );

      expect(check.ok, isFalse);
      expect(check.title, contains("isn't registered"));
    });

    test('no row at all means the server has no registration for this phone', () {
      final check = describePushTestResponse(_body(), platform: 'android', thisPhoneOnly: true);

      expect(check.ok, isFalse);
      expect(check.title, contains("isn't registered"));
    });

    test('a failed send is a failure', () {
      final check = describePushTestResponse(
        _body(results: [
          {'platform': 'android', 'ok': false, 'code': 'messaging/third-party-auth-error'},
        ]),
        platform: 'android',
        thisPhoneOnly: true,
      );

      expect(check.ok, isFalse);
      expect(check.lines.first, 'messaging/third-party-auth-error');
    });

    test('a server that ignored the token cannot let a second phone of this platform vouch', () {
      final results = [
        {'platform': 'android', 'ok': false, 'code': 'messaging/invalid-argument'},
        {'platform': 'android', 'ok': true, 'code': null},
      ];

      // Without the token the old rule stands (any phone of this platform)...
      expect(describePushTestResponse(_body(results: results), platform: 'android').ok, isTrue);
      // ...with it, one failure among several unattributable rows is a failure.
      final check = describePushTestResponse(
        _body(results: results),
        platform: 'android',
        thisPhoneOnly: true,
      );
      expect(check.ok, isFalse);
      expect(check.lines.first, contains('cannot say which one is this phone'));
      expect(check.lines, contains('messaging/invalid-argument'));
    });

    test('several phones that all got it are delivered whichever one is ours', () {
      final check = describePushTestResponse(
        _body(results: [
          {'platform': 'android', 'ok': true, 'code': null},
          {'platform': 'android', 'ok': true, 'code': null},
        ]),
        platform: 'android',
        thisPhoneOnly: true,
      );

      expect(check.ok, isTrue);
    });

    test('an older server\'s other-platform rows are still ignored', () {
      final check = describePushTestResponse(
        _body(results: [
          {'platform': 'ios', 'ok': false, 'code': 'messaging/third-party-auth-error'},
          {'platform': 'android', 'ok': true, 'code': null},
        ]),
        platform: 'android',
        thisPhoneOnly: true,
      );

      expect(check.ok, isTrue);
    });
  });

  group('pushTestDelivered', () {
    test('null when the answer says nothing about this phone', () {
      expect(pushTestDelivered(_body(), platform: 'ios', thisPhoneOnly: true), isNull);
      expect(
        pushTestDelivered(
          _body(results: [
            {'platform': 'android', 'ok': true, 'code': null},
          ]),
          platform: 'ios',
        ),
        isNull,
      );
      expect(pushTestDelivered({}, platform: 'ios'), isNull);
    });

    test('true or false for the row that speaks for this phone', () {
      bool? delivered(bool ok, {bool thisPhoneOnly = true}) => pushTestDelivered(
        _body(results: [
          {'platform': 'android', 'ok': ok, 'code': ok ? null : 'x'},
        ]),
        platform: 'android',
        thisPhoneOnly: thisPhoneOnly,
      );

      expect(delivered(true), isTrue);
      expect(delivered(false), isFalse);
      expect(delivered(false, thisPhoneOnly: false), isFalse);
    });
  });

  group('resolvePushBadge', () {
    PushBadge badge(PushPermission permission, PushRegistration registration) =>
        resolvePushBadge(permission: permission, registration: registration);

    test('active needs the permission AND a registered token AND a server that can send', () {
      expect(badge(PushPermission.granted, PushRegistration.registered), PushBadge.active);

      for (final registration in PushRegistration.values) {
        if (registration == PushRegistration.registered) continue;
        expect(
          badge(PushPermission.granted, registration),
          isNot(PushBadge.active),
          reason: registration.name,
        );
      }
      for (final permission in [PushPermission.notAsked, PushPermission.blocked]) {
        expect(
          badge(permission, PushRegistration.registered),
          isNot(PushBadge.active),
          reason: permission.name,
        );
      }
    });

    test('each granted-permission state has its own badge', () {
      expect(badge(PushPermission.granted, PushRegistration.notSetUp), PushBadge.notSetUp);
      expect(badge(PushPermission.granted, PushRegistration.registering), PushBadge.registering);
      expect(badge(PushPermission.granted, PushRegistration.cannotDeliver), PushBadge.cannotDeliver);
      expect(badge(PushPermission.granted, PushRegistration.notRegistered), PushBadge.notRegistered);
    });

    test('the permission is what the line reports first, whatever the registration', () {
      for (final registration in PushRegistration.values) {
        expect(badge(PushPermission.notAsked, registration), PushBadge.notAllowed);
        expect(badge(PushPermission.blocked, registration), PushBadge.blocked);
      }
    });
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
