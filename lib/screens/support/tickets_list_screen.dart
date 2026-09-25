import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../models/ticket_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/tickets_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/status_badge.dart';
import 'create_ticket_screen.dart';
import 'ticket_detail_screen.dart';
import 'ticket_status_badge.dart';

class TicketsListScreen extends StatefulWidget {
  const TicketsListScreen({super.key});

  @override
  State<TicketsListScreen> createState() => _TicketsListScreenState();
}

class _TicketsListScreenState extends State<TicketsListScreen> {
  // Held from initState: dispose() can't safely look a provider up through
  // the (already deactivated) context.
  late final TicketsProvider _tickets;

  @override
  void initState() {
    super.initState();
    _tickets = context.read<TicketsProvider>();
    _tickets.watchTicketList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tickets.fetchTickets();
    });
  }

  @override
  void dispose() {
    _tickets.unwatchTicketList();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TicketsProvider>();
    final currentUserId = context.watch<AuthProvider>().user?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Support')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CreateTicketScreen()),
        ),
        icon: const Icon(Icons.add),
        label: const Text('New Ticket'),
      ),
      body: _buildBody(context, provider, currentUserId),
    );
  }

  Widget _buildBody(BuildContext context, TicketsProvider provider, String? currentUserId) {
    if (provider.isLoadingList && provider.tickets.isEmpty) {
      return const AppLoading();
    }
    if (provider.listError != null && provider.tickets.isEmpty) {
      return ErrorState(message: provider.listError!, onRetry: () => context.read<TicketsProvider>().fetchTickets());
    }
    if (provider.tickets.isEmpty) {
      return const EmptyState(
        icon: Icons.support_agent_outlined,
        title: 'No support tickets yet',
        subtitle: 'Raise a ticket and our support team will get back to you.',
      );
    }
    return RefreshIndicator(
      onRefresh: () => context.read<TicketsProvider>().fetchTickets(),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
        itemCount: provider.tickets.length,
        separatorBuilder: (context, index) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _TicketTile(ticket: provider.tickets[index], viewerId: currentUserId),
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  final TicketModel ticket;
  final String? viewerId;

  const _TicketTile({required this.ticket, required this.viewerId});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(TicketDetailScreen.route(ticket.id)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(ticket.ticketId, style: TextStyle(color: scheme.outline, fontSize: 12, fontWeight: FontWeight.w600)),
                  if (ticket.hasUnread) ...[
                    const SizedBox(width: 6),
                    Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.red, shape: BoxShape.circle)),
                  ],
                  const Spacer(),
                  TicketStatusBadge(ticket: ticket, viewerId: viewerId),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                ticket.subject,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                ticket.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  StatusBadge(label: ticket.priority, color: AppColors.forPriority(ticket.priority)),
                  const Spacer(),
                  Text(Formatters.relative(ticket.updatedAt ?? ticket.createdAt),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
