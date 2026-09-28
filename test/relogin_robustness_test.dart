import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/core/notifications/fcm_service.dart';
import 'package:internal_audit_app/core/notifications/notification_scheduler.dart';
import 'package:internal_audit_app/core/storage/secure_storage.dart';
import 'package:internal_audit_app/providers/app_mode_provider.dart';
import 'package:internal_audit_app/providers/auth_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:internal_audit_app/providers/notifications_provider.dart';
import 'package:internal_audit_app/providers/profile_provider.dart';
import 'package:internal_audit_app/providers/tickets_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// Second-login and robustness regressions: what a sign-out leaves behind on a
/// shared phone, a login answer the app cannot read, a notification delivered
/// twice, and provider calls that must always hand the screen a message.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late FakeSockets sockets;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    NotificationScheduler.clearTray = () async {};
    FcmService.debugReset();
    adapter = FakeAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    sockets = FakeSockets(readToken: SecureStorage.instance.readToken);
    SocketService.debugInstance = sockets.service;
  });

  tearDown(() async {
    await settle(20);
    DioClient.instance.onUnauthorized = null;
    FcmService.debugReset();
  });

  group('login', () {
    test('an answer the app cannot read is reported, and no token is left saved', () async {
      adapter.handler = (o) async => json(200, {'token': 'jwt-A', 'data': {'user': 'not-a-map'}});
      final auth = AuthProvider();
      addTearDown(auth.dispose);

      final error = await auth.login(username: 'A', password: 'x');

      expect(error, isNotNull);
      expect(auth.status, isNot(AuthStatus.authenticated));
      expect(auth.isBusy, isFalse);
      expect(await SecureStorage.instance.readToken(), isNull, reason: 'a half-finished login was saved');
    });

    test('a second tap while the first login is on the wire does not start another', () async {
      final gate = Completer<void>();
      adapter.handler = (o) async {
        if (o.path == ApiConstants.login) {
          await gate.future;
          return json(200, {
            'token': 'jwt-A',
            'data': {'user': {'_id': 'u1', 'roleType': 'Employee'}},
          });
        }
        return json(200, {'isOk': true, 'data': {}});
      };
      final auth = AuthProvider();
      addTearDown(auth.dispose);

      final first = auth.login(username: 'A', password: 'x');
      await settle();
      expect(await auth.login(username: 'A', password: 'x'), isNull);
      gate.complete();
      expect(await first, isNull);

      expect(adapter.where('POST', ApiConstants.login), hasLength(1));
    });
  });

  group('sign-out', () {
    test('keeps the phone\'s theme choice but drops the session and the role', () async {
      FlutterSecureStorage.setMockInitialValues({
        'auth_token': 'jwt-A',
        'app_mode': 'auditor',
        'theme_mode': 'dark',
      });

      await SecureStorage.instance.clear();

      expect(await SecureStorage.instance.readToken(), isNull);
      expect(await SecureStorage.instance.readAppMode(), isNull);
      expect(await SecureStorage.instance.readThemeMode(), 'dark');
    });

    test('the next account is asked for its role instead of inheriting the previous one', () async {
      final mode = AppModeProvider();
      await mode.setMode(AppMode.auditor);
      var notified = 0;
      mode.addListener(() => notified++);

      mode.resetForLogout();

      expect(mode.mode, isNull);
      expect(notified, 1);
      mode.resetForLogout(); // already empty: nothing to announce
      expect(notified, 1);
    });

    test('the listeners of every provider are detached with the session', () {
      SocketService.instance.connect('jwt-A');
      final ncs = NcProvider()..startListening();
      expect(sockets.sockets.single.listenerCount('new_notification'), 1);

      ncs.resetForLogout();

      expect(sockets.sockets.single.listenerCount('new_notification'), 0);
    });
  });

  group('a notification delivered twice', () {
    Map<String, dynamic> event(String id) =>
        {'_id': id, 'title': 't', 'message': 'm', 'type': 'general', 'isRead': false};

    test('is listed and counted once', () {
      SocketService.instance.connect('jwt-A');
      final provider = NotificationsProvider()..startListening();
      addTearDown(provider.resetForLogout);

      sockets.sockets.single.receive('new_notification', event('n1'));
      sockets.sockets.single.receive('new_notification', event('n1'));
      sockets.sockets.single.receive('new_notification', event('n2'));

      expect(provider.notifications.map((n) => n.id), ['n2', 'n1']);
      expect(provider.unreadCount, 2);
    });

    test('one already in a refetched list is not added again by the live event', () async {
      adapter.handler = (o) async => json(200, {'data': [event('n1')]});
      SocketService.instance.connect('jwt-A');
      final provider = NotificationsProvider()..startListening();
      addTearDown(provider.resetForLogout);
      await provider.fetchNotifications();
      expect(provider.unreadCount, 1);

      sockets.sockets.single.receive('new_notification', event('n1'));

      expect(provider.notifications, hasLength(1));
      expect(provider.unreadCount, 1);
    });

    test('listeners are registered once however often listening is started', () {
      SocketService.instance.connect('jwt-A');
      final provider = NotificationsProvider()
        ..startListening()
        ..startListening();
      addTearDown(provider.resetForLogout);

      expect(sockets.sockets.single.listenerCount('new_notification'), 1);
    });
  });

  group('providers always answer the screen', () {
    // A 200 whose body is not what the models expect.
    setUp(() => adapter.handler = (o) async => json(200, {'data': 'garbage'}));

    test('createTicket', () async {
      expect(
        await TicketsProvider().createTicket(subject: 's', description: 'd', priority: 'Low'),
        'Could not create the ticket.',
      );
    });

    test('a ticket reply releases the send state', () async {
      final tickets = TicketsProvider()..openTicketRoom('t1');
      addTearDown(() => tickets.closeTicketRoom('t1'));
      expect(await tickets.reply(ticketId: 't1', message: 'hi'), 'Could not send your reply.');
      expect(tickets.isSendingReply, isFalse);
    });

    test('a ticket list ends its loading state with an error', () async {
      final tickets = TicketsProvider();
      await tickets.fetchTickets();
      expect(tickets.isLoadingList, isFalse);
    });

    test('updateProfile releases Save', () async {
      final profile = ProfileProvider();
      final result = await profile.updateProfile(
        employeeName: 'n',
        mobileNumber: 'm',
        emailOffice: 'e',
        username: 'u',
      );
      expect(result, isA<String>());
      expect(profile.isSaving, isFalse);
    });

    test('NC lists and actions', () async {
      final ncs = NcProvider();
      await ncs.fetchRaisedByMe();
      await ncs.fetchAgainstMe();
      expect(ncs.raisedError, isNotNull);
      expect(ncs.mineError, isNotNull);
      expect(ncs.isLoadingRaised, isFalse);
      expect(ncs.isLoadingMine, isFalse);
      expect(await ncs.fetchById('nc1'), isNull);
      expect(
        await ncs.respond(
          ncId: 'nc1',
          correctionAction: 'a',
          rootCause: 'b',
          correctiveAction: 'c',
          preventiveAction: 'd',
        ),
        'Could not submit your response.',
      );
      expect(
        await ncs.verify(ncId: 'nc1', currentlyResponseSubmitted: false, action: 'Accept'),
        'Could not update this NC.',
      );
    });
  });
}
