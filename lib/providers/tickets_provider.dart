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

  Future<void> fetchTickets() async {
    isLoadingList = true;
    listError = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.tickets);
      tickets = (res.data['data'] as List? ?? [])
          .whereType<Map>()
          .map((e) => TicketModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } on DioException catch (e) {
      listError = extractErrorMessage(e, fallback: 'Could not load your tickets.');
    } finally {
      isLoadingList = false;
      notifyListeners();
    }
  }

  Future<String?> createTicket({
    required String subject,
    required String description,
    required String priority,
    List<File> attachments = const [],
  }) async {
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
      tickets = [created, ...tickets];
      notifyListeners();
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not create the ticket.');
    }
  }

  Future<void> fetchTicketDetail(String id) async {
    isLoadingDetail = true;
    detailError = null;
    notifyListeners();
    try {
      final res = await _dio.get(ApiConstants.ticketById(id));
      activeTicket = TicketModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      unawaited(_dio.patch(ApiConstants.ticketRead(id)).then((_) {}, onError: (_) {}));
    } on DioException catch (e) {
      detailError = extractErrorMessage(e, fallback: 'Could not load this ticket.');
    } finally {
      isLoadingDetail = false;
      notifyListeners();
    }
  }

  Future<String?> reply({required String ticketId, required String message, List<File> attachments = const []}) async {
    isSendingReply = true;
    notifyListeners();
    try {
      final form = FormData.fromMap({'message': message});
      for (final file in attachments) {
        form.files.add(MapEntry('attachments', await MultipartFile.fromFile(file.path, filename: file.path.split('/').last)));
      }
      final res = await _dio.post(ApiConstants.ticketReply(ticketId), data: form);
      activeTicket = TicketModel.fromJson(Map<String, dynamic>.from(res.data['data']));
      return null;
    } on DioException catch (e) {
      return extractErrorMessage(e, fallback: 'Could not send your reply.');
    } finally {
      isSendingReply = false;
      notifyListeners();
    }
  }

  void openTicketRoom(String ticketId) {
    if (_joinedTicketRoom == ticketId) return;
    if (_joinedTicketRoom != null) SocketService.instance.leaveTicket(_joinedTicketRoom!);
    _joinedTicketRoom = ticketId;
    SocketService.instance.joinTicket(ticketId);
    SocketService.instance.on('new_message', _onNewMessage);
    SocketService.instance.on('ticket_updated', _onTicketUpdated);
  }

  void closeTicketRoom() {
    if (_joinedTicketRoom != null) {
      SocketService.instance.leaveTicket(_joinedTicketRoom!);
      _joinedTicketRoom = null;
    }
    SocketService.instance.off('new_message', _onNewMessage);
    SocketService.instance.off('ticket_updated', _onTicketUpdated);
    activeTicket = null;
  }

  void _onNewMessage(dynamic data) {
    if (activeTicket == null || data is! Map) return;
    final message = TicketMessage.fromJson(Map<String, dynamic>.from(data));
    activeTicket = TicketModel(
      id: activeTicket!.id,
      ticketId: activeTicket!.ticketId,
      subject: activeTicket!.subject,
      description: activeTicket!.description,
      status: activeTicket!.status,
      priority: activeTicket!.priority,
      platform: activeTicket!.platform,
      raisedById: activeTicket!.raisedById,
      raisedByName: activeTicket!.raisedByName,
      attachments: activeTicket!.attachments,
      messages: [...activeTicket!.messages, message],
      hasUnread: activeTicket!.hasUnread,
      createdAt: activeTicket!.createdAt,
      updatedAt: activeTicket!.updatedAt,
    );
    notifyListeners();
  }

  void _onTicketUpdated(dynamic _) {
    if (activeTicket != null) fetchTicketDetail(activeTicket!.id);
    fetchTickets();
  }
}
