import 'package:socket_io_client/socket_io_client.dart' as io;

import '../constants/api_constants.dart';

/// One socket connection for the whole app, created after login and torn
/// down on logout. Mirrors server/socket/index.js's two room kinds:
///   - personal room (joined via `join`, token) -> new_notification / refresh_unread_count
///   - ticket room, `"ticket_" + id` (joined via `join_ticket`) -> new_message / ticket_updated
class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  io.Socket? _socket;

  // Listeners registered while no socket exists yet — e.g. Maintenance/
  // AnnouncementProvider attach at app cold-start, before login, so
  // `connect()` hasn't run and `_socket` is still null. Previously `on()`
  // silently dropped those (a no-op), forcing those two providers to fall
  // back to polling alone. Kept (not consumed) across calls so it's
  // replayed on every `connect()` — i.e. every login, including a
  // re-login after logout on a kiosk device that's shared across shifts.
  final List<MapEntry<String, void Function(dynamic)>> _pending = [];

  bool get isConnected => _socket?.connected ?? false;

  void connect(String token) {
    if (_socket != null) return;
    _socket = io.io(
      ApiConstants.socketUrl,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .build(),
    );
    for (final entry in _pending) {
      _socket!.on(entry.key, entry.value);
    }
    _socket!.connect();
    _socket!.onConnect((_) => _socket!.emit('join', token));
  }

  void on(String event, void Function(dynamic data) handler) {
    if (_socket != null) {
      _socket!.on(event, handler);
    } else {
      _pending.add(MapEntry(event, handler));
    }
  }

  void off(String event, [void Function(dynamic data)? handler]) {
    _socket?.off(event, handler);
    _pending.removeWhere(
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
