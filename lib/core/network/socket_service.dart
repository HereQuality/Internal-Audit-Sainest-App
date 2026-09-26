import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../constants/api_constants.dart';
import '../storage/secure_storage.dart';

/// The slice of a socket.io client SocketService actually uses — an
/// interface only so a test can stand in for the network. Production always
/// gets [_IoSocketHandle].
abstract class SocketHandle {
  bool get connected;
  void on(String event, void Function(dynamic data) handler);
  void off(String event, [void Function(dynamic data)? handler]);
  void emit(String event, [dynamic data]);
  void connect();
  void dispose();
}

class _IoSocketHandle implements SocketHandle {
  _IoSocketHandle(this._socket);
  final io.Socket _socket;

  @override
  bool get connected => _socket.connected;
  @override
  void on(String event, void Function(dynamic data) handler) => _socket.on(event, handler);
  @override
  void off(String event, [void Function(dynamic data)? handler]) => _socket.off(event, handler);
  @override
  void emit(String event, [dynamic data]) => _socket.emit(event, data);
  @override
  void connect() => _socket.connect();
  @override
  void dispose() => _socket.dispose();
}

SocketHandle _createIoSocket() => _IoSocketHandle(
      io.io(
        ApiConstants.socketUrl,
        io.OptionBuilder().setTransports(['websocket']).disableAutoConnect().build(),
      ),
    );

/// One socket connection for the whole app, created after login and torn
/// down on logout. Mirrors server/socket/index.js's two room kinds:
///   - personal room (joined via `join`, token) -> new_notification / refresh_unread_count
///   - ticket room, `"ticket_" + id` (joined via `join_ticket`) -> new_message / ticket_updated
class SocketService {
  SocketService._()
      : _factory = _createIoSocket,
        _readToken = SecureStorage.instance.readToken;

  @visibleForTesting
  SocketService.test(this._factory, this._readToken);

  static SocketService _instance = SocketService._();
  static SocketService get instance => _instance;

  /// Swaps the process-wide service for one built with [SocketService.test],
  /// so the providers under test talk to a fake socket instead of the network.
  @visibleForTesting
  static set debugInstance(SocketService service) => _instance = service;

  final SocketHandle Function() _factory;
  final Future<String?> Function() _readToken;

  SocketHandle? _socket;

  // EVERY listener registered through [on], whether or not a socket existed
  // at that moment, replayed onto each socket `connect()` creates — i.e. on
  // every login, including a re-login after logout on a kiosk device that's
  // shared across shifts. Disposing the socket on logout clears the
  // listeners that were attached to it, so a handler that only ever went to
  // the live socket (the providers' startListening() runs AFTER connect())
  // silently went deaf for the rest of the process after the first re-login:
  // no badge bump, no list refresh, no socket banner. Screen-scoped handlers
  // (ticket room, evidence upload) stay in here only until their own off().
  final List<MapEntry<String, void Function(dynamic)>> _handlers = [];

  bool get isConnected => _socket?.connected ?? false;

  void connect(String token) {
    if (_socket != null) return;
    final socket = _factory();
    _socket = socket;
    // The join goes first so it is on the wire before any reconnect
    // catch-up handler (a REST refetch) below gets a chance to run.
    socket.on('connect', (_) => unawaited(_join(socket, token)));
    for (final entry in _handlers) {
      socket.on(entry.key, entry.value);
    }
    socket.connect();
  }

  // Runs on the first connect AND on every automatic reconnect (the server
  // forgets the room with the old connection). Uses the CURRENT session's
  // JWT, not the one captured at connect(): after a long background stretch
  // the captured one may have expired, and the server's `join` silently
  // ignores an invalid token — the socket would look connected while every
  // real-time event went nowhere. [fallback] only covers a storage read
  // that fails (e.g. the keychain is locked while the phone is).
  Future<void> _join(SocketHandle socket, String fallback) async {
    String? token;
    try {
      token = await _readToken();
    } catch (e) {
      debugPrint('SocketService: could not read the session token for join, using the connect-time one: $e');
      token = fallback;
    }
    // Signed out (token gone) or this socket was replaced/disposed while the
    // read was pending — there is no session to join for.
    if (token == null || token.isEmpty || !identical(_socket, socket)) return;
    socket.emit('join', token);
  }

  void on(String event, void Function(dynamic data) handler) {
    final known = _handlers.any((e) => e.key == event && e.value == handler);
    if (known) return;
    _handlers.add(MapEntry(event, handler));
    _socket?.on(event, handler);
  }

  void off(String event, [void Function(dynamic data)? handler]) {
    _socket?.off(event, handler);
    _handlers.removeWhere(
      (entry) => entry.key == event && (handler == null || entry.value == handler),
    );
  }

  void joinTicket(String ticketId) => _socket?.emit('join_ticket', ticketId);

  void leaveTicket(String ticketId) => _socket?.emit('leave_ticket', ticketId);

  void disconnect() {
    _socket?.dispose();
    _socket = null;
  }
}
