import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';

/// Stands in for the network under DioClient: every request is recorded (with
/// the headers the interceptors gave it) and answered by [handler], or by a
/// 404 when none is set.
class FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = [];
  Future<ResponseBody> Function(RequestOptions options)? handler;

  Iterable<RequestOptions> where(String method, String path) =>
      requests.where((r) => r.method == method && r.path == path);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final h = handler;
    return h == null ? json(404, {'isOk': false}) : h(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody json(int status, Object body) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// What a phone with no signal looks like to Dio.
Never connectionError(RequestOptions options) =>
    throw DioException(requestOptions: options, type: DioExceptionType.connectionError, error: 'offline');

/// A socket.io client that never touches the network: records what was sent,
/// and lets a test play the server's part ([receive]).
class FakeSocket implements SocketHandle {
  final Map<String, List<void Function(dynamic)>> handlers = {};
  final List<(String, dynamic)> emitted = [];
  bool connectCalled = false;
  bool disposed = false;

  @override
  bool get connected => connectCalled && !disposed;

  @override
  void on(String event, void Function(dynamic data) handler) =>
      (handlers[event] ??= []).add(handler);

  @override
  void off(String event, [void Function(dynamic data)? handler]) {
    if (handler == null) {
      handlers.remove(event);
    } else {
      handlers[event]?.remove(handler);
    }
  }

  @override
  void emit(String event, [dynamic data]) => emitted.add((event, data));

  @override
  void connect() => connectCalled = true;

  // Like the real one: disposing drops every listener.
  @override
  void dispose() {
    disposed = true;
    handlers.clear();
  }

  void receive(String event, [dynamic data]) {
    for (final h in List.of(handlers[event] ?? const <void Function(dynamic)>[])) {
      h(data);
    }
  }

  int listenerCount(String event) => handlers[event]?.length ?? 0;
}

/// A [SocketService] wired to [FakeSocket]s; [sockets] collects every one it
/// creates, in order. The session token the fake reads for `join` is
/// [storedToken], unless [readToken] is given.
class FakeSockets {
  FakeSockets({this.readToken});

  final Future<String?> Function()? readToken;
  final List<FakeSocket> sockets = [];
  String? storedToken;

  late final SocketService service = SocketService.test(() {
    final s = FakeSocket();
    sockets.add(s);
    return s;
  }, readToken ?? () async => storedToken);
}

/// Lets queued microtasks and zero-delay timers run.
Future<void> settle([int rounds = 5]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Polls [condition] for up to [timeout] — for the few things that wait on a
/// real (short) timer.
Future<void> waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw StateError('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
