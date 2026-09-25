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
import 'ticket_status_badge.dart';

class TicketDetailScreen extends StatefulWidget {
  /// The route name notification_navigation.dart looks for on top of the
  /// stack. TicketsProvider holds ONE active ticket/room, so a second
  /// detail screen stacked over this one would blank it when popped — a
  /// notification for another ticket replaces this route instead.
  static const routeName = 'ticket_detail';

  final String ticketId;

  const TicketDetailScreen({super.key, required this.ticketId});

  /// Every way of opening a ticket (the list, a notification tap) builds
  /// its route here, so each one is findable by [routeName] + its id.
  static Route<void> route(String ticketId) => MaterialPageRoute<void>(
        settings: RouteSettings(name: routeName, arguments: ticketId),
        builder: (_) => TicketDetailScreen(ticketId: ticketId),
      );

  @override
  State<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends State<TicketDetailScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final List<File> _pendingAttachments = [];
  // Held from initState: dispose() can't safely look a provider up through
  // the (already deactivated) context.
  late final TicketsProvider _tickets;

  @override
  void initState() {
    super.initState();
    _tickets = context.read<TicketsProvider>();
    _tickets.openTicketRoom(widget.ticketId);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _tickets.fetchTicketDetail(widget.ticketId);
      if (!mounted) return;
      _scrollToBottom();
    });
  }

  @override
  void dispose() {
    _tickets.closeTicketRoom(widget.ticketId);
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

  // Lives here rather than in the confirmation card: a successful verify
  // flips the status, which removes the card — its own State is gone
  // before it could show the result.
  Future<void> _verify(String action, {String? reason}) async {
    final error = await _tickets.verifyTicket(widget.ticketId, action, reason: reason);
    if (!mounted) return;
    if (error != null) {
      showErrorSnackBar(context, error);
      return;
    }
    showSuccessSnackBar(context, action == 'Accept' ? 'Ticket closed.' : 'Ticket reopened.');
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TicketsProvider>();
    // Only ever this screen's own ticket: the provider holds a single
    // active ticket, and while a notification tap swaps this screen for
    // another ticket's it briefly holds the other one.
    final ticket = provider.activeTicket?.id == widget.ticketId ? provider.activeTicket : null;
    final currentUserId = context.watch<AuthProvider>().user?.id;

    return Scaffold(
      appBar: AppBar(
        title: Text(ticket?.ticketId ?? 'Ticket'),
        actions: [
          if (ticket != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(child: TicketStatusBadge(ticket: ticket, viewerId: currentUserId)),
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

    return LayoutBuilder(
      builder: (context, constraints) => Column(
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
          if (ticket.needsConfirmationFrom(currentUserId))
            // No reply box while the raiser owes an answer (same as web).
            // Capped and scrollable so the reason field never overflows the
            // body once the keyboard is up.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.6),
              child: SingleChildScrollView(
                child: _ConfirmationCard(ticket: ticket, onVerify: _verify),
              ),
            )
          else if (ticket.isClosed)
            const _ClosedNotice()
          else ...[
            if (ticket.isAwaitingConfirmation) const _WaitingNotice(),
            ..._buildComposer(provider),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildComposer(TicketsProvider provider) {
    return [
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
                    // 8px padding: a 34px tap target instead of a bare 18px one.
                    customBorder: const CircleBorder(),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: CircleAvatar(
                        radius: 9,
                        backgroundColor: Colors.black54,
                        child: Icon(Icons.close, size: 12, color: Colors.white),
                      ),
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
    ];
  }
}

/// "Has your issue been resolved?" — the raiser's Accept / Not resolved
/// step, mirroring the web Support page's verify card. Only shown to the
/// person who raised the ticket, while it sits in 'Confirmation'.
class _ConfirmationCard extends StatefulWidget {
  final TicketModel ticket;
  final Future<void> Function(String action, {String? reason}) onVerify;

  const _ConfirmationCard({required this.ticket, required this.onVerify});

  @override
  State<_ConfirmationCard> createState() => _ConfirmationCardState();
}

class _ConfirmationCardState extends State<_ConfirmationCard> {
  static const _minReasonLength = 3;

  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  bool _rejecting = false;
  bool _busy = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit(String action) async {
    if (action == 'Reject' && !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    await widget.onVerify(action, reason: action == 'Reject' ? _reasonController.text.trim() : null);
    // A successful answer changes the ticket's status, which removes this
    // card — only a failed attempt is still here to be re-enabled.
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    const accent = TicketStatusBadge.actionColor;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withValues(alpha: 0.4)),
        ),
        child: _rejecting ? _buildReasonForm(context) : _buildQuestion(context),
      ),
    );
  }

  Widget _buildQuestion(BuildContext context) {
    const accent = TicketStatusBadge.actionColor;
    final theme = Theme.of(context);
    final requested = Formatters.relative(widget.ticket.confirmationRequestedAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.task_alt, color: accent, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Confirmation needed',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
            if (requested.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(requested, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Text('Has your issue been resolved?', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(
          'This ticket was marked as resolved. Please confirm the fix, or tell us what is still wrong.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: accent),
                onPressed: _busy ? null : () => _submit('Accept'),
                child: _busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Yes, close ticket'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => setState(() => _rejecting = true),
                child: const Text('Not resolved'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildReasonForm(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("What's still wrong?", style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          TextFormField(
            controller: _reasonController,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textCapitalization: TextCapitalization.sentences,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            decoration: const InputDecoration(hintText: 'Tell us what still needs fixing'),
            validator: (value) => (value ?? '').trim().length < _minReasonLength
                ? 'Please describe what is still wrong (at least $_minReasonLength characters).'
                : null,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : () => setState(() => _rejecting = false),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.red),
                  onPressed: _busy ? null : () => _submit('Reject'),
                  child: _busy
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Reopen ticket'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Shown to everyone but the raiser while a ticket waits for their answer —
/// only the raiser can accept or reject, so nobody else has anything to do.
class _WaitingNotice extends StatelessWidget {
  const _WaitingNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 16, color: scheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Waiting for the raiser to confirm', style: TextStyle(fontSize: 13, color: scheme.outline)),
          ),
        ],
      ),
    );
  }
}

/// Stands in for the reply box on a closed ticket — the server refuses
/// replies to it, so offering the box would only end in an error.
class _ClosedNotice extends StatelessWidget {
  const _ClosedNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        color: scheme.surfaceContainerLow,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 16, color: scheme.outline),
            const SizedBox(width: 8),
            Text('This ticket is closed.', style: TextStyle(fontSize: 13, color: scheme.outline)),
          ],
        ),
      ),
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
          child: Text(message.displayMessage, style: TextStyle(fontSize: 12, color: scheme.outline)),
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
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        message.senderName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.primary),
                      ),
                    ),
                    if (message.isFromDeveloper) ...[
                      const SizedBox(width: 6),
                      const _DeveloperBadge(),
                    ],
                  ],
                ),
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

/// Marks a reply from the top escalation tier (a SuperAdmin account) —
/// same "Developer" label the web thread shows next to that sender.
class _DeveloperBadge extends StatelessWidget {
  const _DeveloperBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(4)),
      child: Text('Developer', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: scheme.primary)),
    );
  }
}
