import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/snackbar.dart';
import '../../models/nc_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/photo_viewer.dart';

/// The NC review thread — chat-style, same convention as the web app's NC
/// Management page (NCManagement.jsx#NCThreadModal). The original finding
/// on the left, then one right-aligned bubble per responseHistory entry
/// (NC1, NC2, ... one per reopen cycle) with the auditor's verdict as a
/// left-aligned bubble beneath it.
///
/// This same screen is reached from BOTH sides — the auditor (NC list's
/// "Raised by me") reviewing a response, AND the auditee (NC list's
/// "Against me") just checking on their own already-submitted response's
/// status once it's no longer "Raised" (see nc_list_screen.dart's
/// _AgainstMeList). Approve/Reject is the auditor's action only —
/// nc.controller.js#verifyNC/moveToVerification both 403 anyone but
/// nc.raisedByEmployeeId — so the action bar only renders for them; an
/// auditee viewing their own pending response sees the same thread
/// read-only instead of buttons that would just error.
class NcReviewScreen extends StatefulWidget {
  final NcModel nc;

  const NcReviewScreen({super.key, required this.nc});

  @override
  State<NcReviewScreen> createState() => _NcReviewScreenState();
}

class _NcReviewScreenState extends State<NcReviewScreen> {
  final _noteController = TextEditingController();
  bool _busy = false;

  /// The live version of widget.nc, resolved from NcProvider's own lists
  /// (already kept fresh by its socket listener — see nc_provider.dart) so
  /// this screen reflects a status change without needing to be popped and
  /// reopened. Falls back to widget.nc when it isn't in either loaded list
  /// yet (e.g. right after navigating here before any refetch).
  NcModel _resolveNc(NcProvider provider) {
    for (final list in [provider.raisedByMe, provider.raisedAgainstMe]) {
      for (final n in list) {
        if (n.id == widget.nc.id) return n;
      }
    }
    return widget.nc;
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  bool _awaitingReview(NcModel nc) =>
      nc.status == 'Response Submitted' || nc.status == 'Verification';

  bool _isRaiser(BuildContext context, NcModel nc) {
    final myId = context.read<AuthProvider>().user?.id;
    return myId != null && myId == nc.raisedBy.id;
  }

  Future<void> _handle(String action, NcModel nc) async {
    if (action == 'Reject' && _noteController.text.trim().isEmpty) {
      showErrorSnackBar(context, 'A remark is required when rejecting.');
      return;
    }
    setState(() => _busy = true);
    final ncProvider = context.read<NcProvider>();
    final error = await ncProvider.verify(
      ncId: nc.id,
      currentlyResponseSubmitted: nc.status == 'Response Submitted',
      action: action,
      note: _noteController.text.trim().isEmpty
          ? null
          : _noteController.text.trim(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      showErrorSnackBar(context, error);
      return;
    }
    // The socket-driven refetch in NcProvider only fires for the OTHER
    // party's notification — the raiser (acting here) never gets notified
    // of their own action, so this list needs an explicit refresh for
    // _resolveNc above to pick up the new status right away. Same reasoning
    // extends to the dashboard's NC/completed tallies, which this action
    // also moves but has no refresh path of its own for the actor.
    await Future.wait([
      ncProvider.fetchRaisedByMe(),
      context.read<DashboardProvider>().refreshAll(),
    ]);
    if (!mounted) return;
    showSuccessSnackBar(
      context,
      action == 'Accept' ? 'NC closed!' : 'Sent back to auditee.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final nc = _resolveNc(context.watch<NcProvider>());
    return Scaffold(
      appBar: AppBar(title: Text('${nc.ncId} — ${nc.title}')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              children: [
                _Bubble(
                  align: Alignment.centerLeft,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  title: 'Finding raised',
                  meta: Formatters.dateTime(nc.startDate),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        nc.description.isEmpty ? nc.title : nc.description,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Target date: ${Formatters.date(nc.targetDate)}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
                if (nc.responseHistory.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'Waiting for the auditee to respond.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  )
                else
                  for (final entry in nc.responseHistory) ...[
                    _Bubble(
                      align: Alignment.centerRight,
                      color: AppColors.blue.withValues(alpha: 0.08),
                      title: 'NC${entry.cycle} Response',
                      meta: Formatters.dateTime(entry.submittedAt),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _field('Correction', entry.correctionAction),
                          _field('Root Cause', entry.rootCause),
                          _field('Corrective Action', entry.correctiveAction),
                          _field('Preventive Action', entry.preventiveAction),
                          if (entry.photos.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            SizedBox(
                              height: 56,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: entry.photos.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (_, i) => GestureDetector(
                                  onTap: () => openPhotoViewer(
                                    context,
                                    images: entry.photos
                                        .map((u) => CachedNetworkImageProvider(u) as ImageProvider)
                                        .toList(),
                                    initialIndex: i,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: CachedNetworkImage(
                                      imageUrl: entry.photos[i],
                                      width: 56,
                                      height: 56,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (entry.verificationAction != null)
                      _Bubble(
                        align: Alignment.centerLeft,
                        color: entry.verificationAction == 'Accept'
                            ? AppColors.green.withValues(alpha: 0.08)
                            : AppColors.red.withValues(alpha: 0.08),
                        title: entry.verificationAction == 'Accept'
                            ? 'Approved & Closed'
                            : 'Rejected — NC${entry.cycle + 1} raised',
                        meta: Formatters.dateTime(entry.verifiedAt),
                        child: Text(entry.verificationNote ?? '—'),
                      ),
                  ],
              ],
            ),
          ),
          if (_awaitingReview(nc) && _isRaiser(context, nc))
            _buildActionBar(context, nc)
          else if (_awaitingReview(nc))
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Text(
                'Waiting for the auditor to review your response.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 12.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  Widget _field(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          Text(value),
        ],
      ),
    );
  }

  Widget _buildActionBar(BuildContext context, NcModel nc) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _noteController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Remark (required to reject)',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _handle('Reject', nc),
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text('Reject'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.red,
                    side: const BorderSide(color: AppColors.red),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _handle('Accept', nc),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Approve & Close'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.green,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Alignment align;
  final Color color;
  final String title;
  final String meta;
  final Widget child;

  const _Bubble({
    required this.align,
    required this.color,
    required this.title,
    required this.meta,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: align,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: align == Alignment.centerLeft
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
