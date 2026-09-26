import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';

import 'support/session_fakes.dart';

/// The socket is disposed on logout and a NEW one is built on the next login.
/// Real-time handlers (badge, list refresh, socket banner) have to be on every
/// one of them, and the server-side room join has to prove the CURRENT
/// session, not the one the very first connect captured.
void main() {
  late FakeSockets fake;
  late SocketService service;

  setUp(() {
    fake = FakeSockets()..storedToken = 'jwt-1';
    service = fake.service;
  });

  test('a handler registered AFTER connect (the providers do) is on the next login\'s socket too', () {
    service.connect('jwt-1');
    var events = 0;
    service.on('new_notification', (_) => events++);

    fake.sockets[0].receive('new_notification');
    expect(events, 1);

    // Logout, then login again in the same process.
    service.disconnect();
    service.connect('jwt-2');
    expect(fake.sockets, hasLength(2));
    fake.sockets[1].receive('new_notification');

    expect(events, 2, reason: 'the handler went deaf after the first re-login');
  });

  test('a handler registered before any socket exists is still replayed on every connect', () {
    var events = 0;
    service.on('maintenance:update', (_) => events++);

    for (var i = 0; i < 3; i++) {
      service.connect('jwt');
      fake.sockets.last.receive('maintenance:update');
      service.disconnect();
    }
    expect(events, 3);
  });

  test('off() removes a handler from the live socket and from future ones', () {
    void handler(dynamic _) => fail('removed handler ran');
    service.connect('jwt');
    service.on('e', handler);
    service.off('e', handler);
    fake.sockets[0].receive('e');

    service.disconnect();
    service.connect('jwt');
    fake.sockets[1].receive('e');
    expect(fake.sockets[1].listenerCount('e'), 0);
  });

  test('off(event, handler) leaves other handlers of the same event alone', () {
    var kept = 0;
    void gone(dynamic _) {}
    service.connect('jwt');
    service.on('new_notification', gone);
    service.on('new_notification', (_) => kept++);
    service.off('new_notification', gone);

    service.disconnect();
    service.connect('jwt');
    fake.sockets[1].receive('new_notification');
    expect(kept, 1);
  });

  test('registering the same handler twice does not double-fire it', () {
    var events = 0;
    void handler(dynamic _) => events++;
    service.connect('jwt');
    service.on('e', handler);
    service.on('e', handler);
    fake.sockets[0].receive('e');
    expect(events, 1);

    service.disconnect();
    service.connect('jwt');
    fake.sockets[1].receive('e');
    expect(events, 2);
  });

  test('join goes out on connect and on every automatic reconnect, with the CURRENT token', () async {
    service.connect('captured-at-login');
    final socket = fake.sockets[0];
    expect(socket.connectCalled, isTrue);

    socket.receive('connect');
    await settle();
    expect(socket.emitted, [('join', 'jwt-1')]);

    // Backgrounded for a day; the session token was replaced meanwhile.
    fake.storedToken = 'jwt-2';
    socket.receive('connect');
    await settle();
    expect(socket.emitted.last, ('join', 'jwt-2'),
        reason: 'a reconnect joined with the token captured at connect time');
  });

  test('no join once the session is gone', () async {
    service.connect('captured');
    fake.storedToken = null; // signed out; the socket has not been disposed yet
    fake.sockets[0].receive('connect');
    await settle();
    expect(fake.sockets[0].emitted, isEmpty);
  });

  test('a storage read that fails falls back to the connect-time token', () async {
    final failing = SocketService.test(() {
      final s = FakeSocket();
      fake.sockets.add(s);
      return s;
    }, () async => throw StateError('keychain locked'));
    failing.connect('captured');
    fake.sockets[0].receive('connect');
    await settle();
    expect(fake.sockets[0].emitted, [('join', 'captured')]);
  });

  test('a join still reading the token when its socket was replaced is dropped', () async {
    service.connect('jwt');
    final old = fake.sockets[0];
    old.receive('connect'); // read pending
    service.disconnect();
    service.connect('jwt');
    await settle();
    expect(old.emitted, isEmpty);
  });

  test('ticket room calls go to the live socket only', () {
    service.joinTicket('nope'); // no socket: must not throw
    service.connect('jwt');
    service.joinTicket('t1');
    service.leaveTicket('t1');
    expect(fake.sockets[0].emitted, [('join_ticket', 't1'), ('leave_ticket', 't1')]);
  });

  test('isConnected follows the live socket', () {
    expect(service.isConnected, isFalse);
    service.connect('jwt');
    expect(service.isConnected, isTrue);
    service.disconnect();
    expect(service.isConnected, isFalse);
  });
}
