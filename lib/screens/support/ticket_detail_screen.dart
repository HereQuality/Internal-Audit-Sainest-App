import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/snackbar.dart';
import '../../models/ticket_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/tickets_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/status_badge.dart';

class TicketDetailScreen extends StatefulWidget {
  final String ticketId;

  const TicketDetailScreen({super.key, required this.ticketId});

  @override
  State<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends State<TicketDetailScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<File> _pendingAttachments = [];

  @override
  void initState() {
    super.initState();
    final provider = context.read<TicketsProvider>();
    provider.openTicketRoom(widget.ticketId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await provider.fetchTicketDetail(widget.ticketId);
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    context.read<TicketsProvider>().closeTicketRoom();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _pickAttachment() async {
    if (_pendingAttachments.length >= 5) {
      showErrorSnackBar(context, 'You can attach up to 5 images per message.');
      return;
    }
    final picked = await ImagePicker().pickMultiImage(imageQuality: 80);
    if (picked.isEmpty) return;
    setState(() {
      _pendingAttachments.addAll(picked.map((x) => File(x.path)).take(5 - _pendingAttachments.length));
    });
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;
    final attachments = List<File>.from(_pendingAttachments);
    _messageController.clear();
    setState(() => _pendingAttachments.clear());
    final error = await context.read<TicketsProvider>().reply(
          ticketId: widget.ticketId,
          message: text.isEmpty ? '(attachment)' : text,
          attachments: attachments,
        );
    if (!mounted) return;
    if (error != null) {
      showErrorSnackBar(context, error);
    } else {
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TicketsProvider>();
    final ticket = provider.activeTicket;
    final currentUserId = context.watch<AuthProvider>().user?.id;

    return Scaffold(
      appBar: AppBar(
        title: Text(ticket?.ticketId ?? 'Ticket'),
        actions: [
          if (ticket != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: StatusBadge(label: ticket.status, color: AppColors.forTicketStatus(ticket.status))),
            ),
        ],
      ),
      body: _buildBody(provider, ticket, currentUserId),
    );
  }

  Widget _buildBody(TicketsProvider provider, TicketModel? ticket, String? currentUserId) {
    if (provider.isLoadingDetail && ticket == null) return const AppLoading();
    if (provider.detailError != null && ticket == null) {
      return ErrorState(
        message: provider.detailError!,
        onRetry: () => provider.fetchTicketDetail(widget.ticketId),
      );
    }
    if (ticket == null) return const SizedBox.shrink();

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ticket.subject, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(
                children: [
                  StatusBadge(label: ticket.priority, color: AppColors.forPriority(ticket.priority)),
                  const SizedBox(width: 8),
                  Text('Raised by ${ticket.raisedByName}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: ticket.messages.length,
            itemBuilder: (context, index) => _MessageBubble(
              message: ticket.messages[index],
              isMine: ticket.messages[index].senderId == currentUserId,
            ),
          ),
        ),
        if (_pendingAttachments.isNotEmpty)
          SizedBox(
            height: 72,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _pendingAttachments.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, index) => Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(_pendingAttachments[index], width: 60, height: 60, fit: BoxFit.cover),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: InkWell(
                      onTap: () => setState(() => _pendingAttachments.removeAt(index)),
                      child: const CircleAvatar(
                        radius: 9,
                        backgroundColor: Colors.black54,
                        child: Icon(Icons.close, size: 12, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                IconButton(onPressed: _pickAttachment, icon: const Icon(Icons.attach_file)),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Type a message',
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: provider.isSendingReply ? null : _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final TicketMessage message;
  final bool isMine;

  const _MessageBubble({required this.message, required this.isMine});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (message.isSystem) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(999)),
          child: Text(message.message, style: TextStyle(fontSize: 12, color: scheme.outline)),
        ),
      );
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isMine ? scheme.primary : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isMine ? 14 : 2),
            bottomRight: Radius.circular(isMine ? 2 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMine)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(message.senderName,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.primary)),
              ),
            if (message.attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: message.attachments
                      .map((url) => ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            // CachedNetworkImage (not Image.network) — same as
                            // every other photo in the app: disk-caches so
                            // re-scrolling this thread (or a new message
                            // arriving and rebuilding the whole list) doesn't
                            // re-fetch every attachment over the network again.
                            child: CachedNetworkImage(imageUrl: url, width: 100, height: 100, fit: BoxFit.cover),
                          ))
                      .toList(),
                ),
              ),
            Text(
              message.message,
              style: TextStyle(color: isMine ? scheme.onPrimary : scheme.onSurface),
            ),
            const SizedBox(height: 4),
            Text(
              Formatters.relative(message.createdAt),
              style: TextStyle(
                fontSize: 10,
                color: isMine ? scheme.onPrimary.withValues(alpha: 0.7) : scheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
