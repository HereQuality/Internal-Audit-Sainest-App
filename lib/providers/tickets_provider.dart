import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../core/constants/api_constants.dart';
import '../core/network/dio_client.dart';
import '../core/network/socket_service.dart';
import '../models/ticket_model.dart';

class TicketsProvider extends ChangeNotifier {
  final Dio _dio = DioClient.instance.dio;

  bool isLoadingList = false;
  String? listError;
  List<TicketModel> tickets = [];

  bool isLoadingDetail = false;
  String? detailError;
  TicketModel? activeTicket;
  bool isSendingReply = false;

  String? _joinedTicketRoom;
  bool _watchingList = false;
  bool _listeningForUpdates = false;

  // Bumped by every detail fetch, and whenever the open ticket changes or
  // closes — a response that comes back after any of those is stale and is
  // dropped, so a slow reply for ticket A can never overwrite ticket B (or
  // resurrect a ticket whose screen is already gone).
  int _detailSeq = 0;

  // Bumped on logout — see resetForLogout. Every request below remembers the
  // value it started under and, once it has changed, writes nothing when it
  // lands (answer, error or loading flag): the next account may already have a
  // request of its own on the wire.
  int _epoch = 0;

  /// Back to empty — call on logout, without refetching. This provider is one
  /// process-lifetime instance, so without it the next person to sign in on
  /// the same phone would open onto the previous account's support tickets,
  /// and a request already on the wire for that account would put them back.
  /// Socket rooms and listeners are left to the screens that own them (their
  /// dispose closes them), so those can still detach cleanly afterwards.
  void resetForLogout() {
    _epoch++;
    _detailSeq++;
    tickets = [];
    activeTicket = null;
    listError = null;
    detailError = null;
    isLoadingList = false;
    isLoadingDetail = false;
    isSendingReply = false;
    notifyListeners();
  }

  Future<void> fetchTickets() async {
    final epoch = _epoch;
    isLoadingList = true;
    listError = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.tickets);
      if (epoch != _epoch) return;
      tickets = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => TicketModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      if (epoch == _epoch) {
        listError = extractErrorMessage(e, fallback: 'Could not load your tickets.');
      }
    } catch (e, st) {
      debugPrint('TicketsProvider.fetchTickets: unreadable answer: $e\n$st');
      if (epoch == _epoch) listError = 'Could not load your tickets.';
    } finally {
      if (epoch == _epoch) {
        isLoadingList = false;
        notifyListeners();
      }
    }
  }

  Future<String?> createTicket({
    required String subject,
    required String description,
    required String priority,
    List<File> attachments = const [],
  }) async {
    final epoch = _epoch;
    try {
      // Files go in via form.files below, not fromMap — a Dart map
      // literal silently collapses duplicate 'attachments' keys to the
      // last one, uploading only the last picked file (see audits_provider.dart).
      final form = FormData.fromMap({
        'subject': subject,
        'description': description,
        'priority': priority,
        'platform': 'App',
      });
      for (final file in attachments) {
        form.files.add(MapEntry('attachments', await MultipartFile.fromFile(file.path, filename: file.path.split('/').last)));
      }
      final res = await _dio.post(ApiConstants.tickets, data: form);
      final created = TicketModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      // Created on the server all the same; it just isn't this account's list.
      if (epoch == _epoch) {
        tickets = [created, ...tickets];
        notifyListeners();
      }
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not create the ticket.');
    } catch (e, st) {
      // An attachment that can no longer be read, or an answer without the new
      // ticket: the screen must get a message back or its Submit stays locked.
      debugPrint('TicketsProvider.createTicket failed: $e\n$st');
      return 'Could not create the ticket.';
    }
  }

  Future<void> fetchTicketDetail(String id) async {
    final seq = ++_detailSeq;
    isLoadingDetail = true;
    detailError = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.ticketById(id));
      if (seq != _detailSeq) return;
      activeTicket = TicketModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      unawaited(_dio.patch(ApiConstants.ticketRead(id)).then((_) {}, onError: (_) {}));
    } on DioException catch (e) {
      if (seq == _detailSeq) detailError = extractErrorMessage(e, fallback: 'Could not load this ticket.');
    } catch (e, st) {
      debugPrint('TicketsProvider.fetchTicketDetail: unreadable answer: $e\n$st');
      if (seq == _detailSeq) detailError = 'Could not load this ticket.';
    } finally {
      if (seq == _detailSeq) {
        isLoadingDetail = false;
        notifyListeners();
      }
    }
  }

  Future<String?> reply({required String ticketId, required String message, List<File> attachments = const []}) async {
    final epoch = _epoch;
    isSendingReply = true;
    notifyListeners();
    try {
      final form = FormData.fromMap({'message': message});
      for (final file in attachments) {
        form.files.add(MapEntry('attachments', await MultipartFile.fromFile(file.path, filename: file.path.split('/').last)));
      }
      final res = await _dio.post(ApiConstants.ticketReply(ticketId), data: form);
      if (epoch == _epoch && _joinedTicketRoom == ticketId) {
        activeTicket = TicketModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      }
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not send your reply.');
    } catch (e, st) {
      debugPrint('TicketsProvider.reply failed: $e\n$st');
      return 'Could not send your reply.';
    } finally {
      if (epoch == _epoch) {
        isSendingReply = false;
        notifyListeners();
      }
    }
  }

  /// The raiser's answer to a "please confirm" request: [action] is
  /// 'Accept' (closes the ticket) or 'Reject' (back to In Progress, with
  /// the [reason] the raiser gave). Returns null on success — by then both
  /// the open ticket and the list have been refreshed — else an error
  /// message, same contract as [reply].
  Future<String?> verifyTicket(String id, String action, {String? reason}) async {
    final epoch = _epoch;
    try {
      await _dio.post(
        ApiConstants.ticketVerify(id),
        data: {'action': action, 'reason': ?reason},
      );
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not update this ticket.');
    } catch (e, st) {
      debugPrint('TicketsProvider.verifyTicket failed: $e\n$st');
      return 'Could not update this ticket.';
    }
    // The account that asked has since left: refreshing now would fetch for
    // whoever signed in next.
    if (epoch != _epoch) return null;
    // Both fetches swallow their own network errors, so a refresh that
    // fails never reads as a failed verify — the server's ticket_updated
    // broadcast refreshes both screens again anyway.
    await Future.wait([fetchTicketDetail(id), fetchTickets()]);
    return null;
  }

  void openTicketRoom(String ticketId) {
    if (_joinedTicketRoom == ticketId) return;
    _detailSeq++;
    final previous = _joinedTicketRoom;
    if (previous != null) {
      // Another ticket's screen is taking over the room (a notification tap
      // replacing the one on screen). Its message handler is already
      // registered, and the new screen must not start on the old thread —
      // a live message for this room would otherwise land on it.
      SocketService.instance.leaveTicket(previous);
      activeTicket = null;
    } else {
      SocketService.instance.on('new_message', _onNewMessage);
    }
    _joinedTicketRoom = ticketId;
    SocketService.instance.joinTicket(ticketId);
    _syncUpdatesListener();
  }

  void closeTicketRoom(String ticketId) {
    // A screen replaced by another ticket's is disposed AFTER the new one
    // opened its room — by then the room is no longer this screen's to close.
    if (_joinedTicketRoom != ticketId) return;
    SocketService.instance.leaveTicket(ticketId);
    _joinedTicketRoom = null;
    SocketService.instance.off('new_message', _onNewMessage);
    _syncUpdatesListener();
    _detailSeq++;
    isLoadingDetail = false;
    activeTicket = null;
  }

  /// The Support list is on screen: refetch it whenever the server says a
  /// ticket changed, so a "please confirm" arriving while it's open shows
  /// up without a pull-to-refresh.
  void watchTicketList() {
    if (_watchingList) return;
    _watchingList = true;
    SocketService.instance.on('refresh_unread_count', _onTicketsNudged);
    _syncUpdatesListener();
  }

  void unwatchTicketList() {
    if (!_watchingList) return;
    _watchingList = false;
    SocketService.instance.off('refresh_unread_count', _onTicketsNudged);
    _syncUpdatesListener();
  }

  // 'ticket_updated' is wanted while either the list or a ticket room is
  // open — one shared registration, so the two can never double-register
  // (and double-fire) the same handler.
  void _syncUpdatesListener() {
    final wanted = _watchingList || _joinedTicketRoom != null;
    if (wanted == _listeningForUpdates) return;
    _listeningForUpdates = wanted;
    if (wanted) {
      SocketService.instance.on('ticket_updated', _onTicketUpdated);
    } else {
      SocketService.instance.off('ticket_updated', _onTicketUpdated);
    }
  }

  void _onNewMessage(dynamic data) {
    final current = activeTicket;
    if (current == null || data is! Map) return;
    final message = TicketMessage.fromJson(Map<String, dynamic>.from(data));
    // The sender's own reply also comes back in the POST response —
    // whichever of the two lands second must not append it again.
    if (message.id.isNotEmpty && current.messages.any((m) => m.id == message.id)) return;
    activeTicket = current.withMessage(message);
    notifyListeners();
  }

  void _onTicketUpdated(dynamic _) {
    final open = activeTicket;
    if (open != null) fetchTicketDetail(open.id);
    _refreshListFromSocket();
  }

  void _onTicketsNudged(dynamic _) => _refreshListFromSocket();

  // One server change fires several of these events back to back (e.g. a
  // verify emits both ticket_updated and refresh_unread_count); a fetch
  // already in flight started after the change was saved, so it is fresh.
  void _refreshListFromSocket() {
    if (!isLoadingList) fetchTickets();
  }
}
