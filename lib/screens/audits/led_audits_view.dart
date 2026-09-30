import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/snackbar.dart';
import '../../models/audit_model.dart';
import '../../providers/audits_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/audit_filter_bar.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/max_width_scroll.dart';
import '../../widgets/status_badge.dart';
import 'reassign_auditor_sheet.dart';

/// screens/audits/led_audits_view.dart
/// ────────────────────────────────────
/// The Audits tab's "My locations" view — only ever mounted for a place leader
/// (a Zone, Sub Zone, Area or Department they lead): every audit still to be
/// done at those places, whoever it is assigned to, so an auditor who can't
/// make it can be swapped out by their leader from the phone. The counterpart
/// of the web Auditor Dashboard's "Audits at places I lead"
/// (LedAuditsSection.jsx).
///
/// Each row carries the server's own verdict (`canReassign`, and the reason it
/// gives when false), so the button and the endpoint can never disagree — an
/// overdue, finished, Cross Functional Team or unclaimed shared audit shows
/// the reason instead of a live button. The list refreshes itself on any
/// audit_ notification (AuditsProvider.startListening), so a reassignment by
/// someone else shows up without a pull.
class LedAuditsView extends StatefulWidget {
  const LedAuditsView({super.key});

  @override
  State<LedAuditsView> createState() => _LedAuditsViewState();
}

class _LedAuditsViewState extends State<LedAuditsView> {
  AuditsProvider? _provider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = _provider = context.read<AuditsProvider>();
      provider.ledAuditsInUse = true;
      provider.fetchLedAudits();
    });
  }

  @override
  void dispose() {
    // No context.read here (the tree is being torn down).
    _provider?.ledAuditsInUse = false;
    super.dispose();
  }

  Future<void> _reassign(AuditModel audit) async {
    final message = await showReassignAuditorSheet(context, audit);
    if (message != null && mounted) showSuccessSnackBar(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AuditsProvider>();
    final audits = provider.ledAudits;
    final loading = provider.isLoadingLedAudits && audits.isEmpty;
    final failed = provider.ledAuditsError != null && audits.isEmpty;

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: AuditFilterBar(
            footnote:
                "Audits still to be done at the places you lead, whoever the auditor is. Team and Members don't apply here.",
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: provider.fetchLedAudits,
            child: MaxWidthScroll(
              child: loading
                  ? _scrollable(context, const AppLoading())
                  : failed
                  ? _scrollable(
                      context,
                      ErrorState(
                        message: provider.ledAuditsError ?? '',
                        onRetry: provider.fetchLedAudits,
                      ),
                    )
                  : audits.isEmpty
                  ? _scrollable(
                      context,
                      const EmptyState(
                        icon: Icons.location_city_outlined,
                        title: 'Nothing to reassign',
                        subtitle:
                            'No open audits at the places you lead match your filters.',
                      ),
                    )
                  : ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: audits.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, i) => _LedAuditCard(
                        audit: audits[i],
                        onReassign: () => _reassign(audits[i]),
                      ),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  // Keeps pull-to-refresh working on a screen with nothing to scroll.
  Widget _scrollable(BuildContext context, Widget child) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: [SizedBox(height: MediaQuery.of(context).size.height * 0.5, child: child)],
  );
}

class _LedAuditCard extends StatelessWidget {
  final AuditModel audit;
  final VoidCallback onReassign;

  const _LedAuditCard({required this.audit, required this.onReassign});

  String get _period {
    final start = audit.scheduledDate;
    final end = audit.scheduledEndDate;
    if (start == null) return '—';
    if (end == null || Formatters.date(end) == Formatters.date(start)) {
      return Formatters.date(start);
    }
    return '${Formatters.date(start)} – ${Formatters.date(end)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final auditors = audit.auditors.isEmpty
        ? 'No auditor'
        : audit.auditors.map((a) => a.name).join(', ');

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    audit.title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                StatusBadge(
                  label: audit.displayLabel,
                  color: AppColors.forAuditStatus(audit.displayLabel),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (audit.location.isNotEmpty)
              _Line(icon: Icons.place_outlined, text: audit.location, style: muted),
            _Line(icon: Icons.event_outlined, text: _period, style: muted),
            _Line(
              icon: Icons.person_outline,
              text: audit.auditors.length > 1 ? 'Auditors: $auditors' : 'Auditor: $auditors',
              style: muted,
            ),
            if (audit.isRecurring)
              _Line(
                icon: Icons.repeat,
                text: '${audit.frequency ?? 'Recurring'} series',
                style: muted,
              ),
            const SizedBox(height: 10),
            if (audit.canReassign)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onReassign,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('Reassign auditor'),
                ),
              )
            else
              Text(
                audit.reassignBlockedReason ?? 'This audit can no longer be reassigned.',
                style: muted,
              ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final String text;
  final TextStyle? style;

  const _Line({required this.icon, required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: style?.color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
