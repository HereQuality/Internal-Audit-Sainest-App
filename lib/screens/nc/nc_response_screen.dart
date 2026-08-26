import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/snackbar.dart';
import '../../models/nc_model.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/nc_provider.dart';
import '../../widgets/photo_picker_sheet.dart';
import '../../widgets/photo_viewer.dart';

/// Auditee: submit the 4-field corrective-action response — mirrors the
/// web app's Auditee.jsx RespondModal exactly (same field order, same
/// required-all-four rule, optional photo evidence). Shows the auditor's
/// last rejection remark up top if this is a resubmission
/// (nc.reopenCount > 0), same as the web modal.
class NcResponseScreen extends StatefulWidget {
  final NcModel nc;

  const NcResponseScreen({super.key, required this.nc});

  @override
  State<NcResponseScreen> createState() => _NcResponseScreenState();
}

const _fields = [
  ('correctionAction', 'Correction', 'What immediate action was taken to fix this?'),
  ('rootCause', 'Root Cause', 'Why did this happen in the first place?'),
  ('correctiveAction', 'Corrective Action', "What's being done to resolve this specific finding?"),
  ('preventiveAction', 'Preventive Action', 'What will stop this from recurring?'),
];

class _NcResponseScreenState extends State<NcResponseScreen> {
  final Map<String, TextEditingController> _controllers = {
    for (final f in _fields) f.$1: TextEditingController(),
  };
  // Evidence photos already on the NC (the last responseHistory cycle's
  // photos — non-empty only on a resubmission after a rejection) that the
  // auditee is keeping as-is, vs newly picked File[] for this submission.
  final List<String> _existingPhotos = [];
  final List<File> _photos = [];
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    // Pre-fill from the last submitted attempt (most recent responseHistory
    // cycle) so a resubmission after rejection edits what was already
    // written instead of retyping from a blank form — mirrors the web
    // app's Auditee.jsx RespondModal. Empty responseHistory (this NC has
    // never been responded to yet) leaves everything blank, unchanged.
    if (widget.nc.responseHistory.isNotEmpty) {
      final last = widget.nc.responseHistory.last;
      _controllers['correctionAction']!.text = last.correctionAction ?? '';
      _controllers['rootCause']!.text = last.rootCause ?? '';
      _controllers['correctiveAction']!.text = last.correctiveAction ?? '';
      _controllers['preventiveAction']!.text = last.preventiveAction ?? '';
      _existingPhotos.addAll(last.photos);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  int get _totalPhotoCount => _existingPhotos.length + _photos.length;

  Future<void> _pickPhotos() async {
    final picked = await pickEvidencePhotos(context);
    if (picked.isEmpty || !mounted) return;
    final remaining = 5 - _totalPhotoCount;
    if (remaining <= 0) return;
    setState(() => _photos.addAll(picked.take(remaining)));
  }

  Future<void> _submit() async {
    final missing = _fields.where((f) => _controllers[f.$1]!.text.trim().isEmpty).toList();
    if (missing.isNotEmpty) {
      showErrorSnackBar(context, 'All four fields are required.');
      return;
    }
    setState(() => _isSubmitting = true);
    final ncProvider = context.read<NcProvider>();
    final dashboardProvider = context.read<DashboardProvider>();
    final error = await ncProvider.respond(
          ncId: widget.nc.id,
          correctionAction: _controllers['correctionAction']!.text.trim(),
          rootCause: _controllers['rootCause']!.text.trim(),
          correctiveAction: _controllers['correctiveAction']!.text.trim(),
          preventiveAction: _controllers['preventiveAction']!.text.trim(),
          photos: _photos,
          keepPhotoUrls: _existingPhotos,
        );
    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (error != null) {
      showErrorSnackBar(context, error);
      return;
    }
    // respond() only refreshes activeNc — the socket-driven refetch in
    // NcProvider only fires for the OTHER party's notification (the
    // auditor who raised this NC), never the auditee acting here, so
    // raisedAgainstMe and the dashboard's NC tallies need an explicit
    // refresh to show "Response Submitted" right away (same pattern as
    // nc_review_screen.dart's _handle).
    await Future.wait([ncProvider.fetchAgainstMe(), dashboardProvider.refreshAll()]);
    if (!mounted) return;
    Navigator.of(context).pop();
    showSuccessSnackBar(context, 'Response submitted!');
  }

  Future<void> _confirmLeaveWhileSubmitting(BuildContext context) async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Still submitting'),
        content: const Text('Your response is still being submitted. Leaving now may lose it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Wait')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave anyway')),
        ],
      ),
    );
    if (leave == true && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_isSubmitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmLeaveWhileSubmitting(context);
      },
      child: Scaffold(
      appBar: AppBar(title: Text('Respond — ${widget.nc.ncId}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(widget.nc.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          if (widget.nc.description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(widget.nc.description, style: TextStyle(color: scheme.outline)),
          ],
          if (widget.nc.reopenCount > 0 && (widget.nc.verificationNote ?? '').isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: AppColors.red.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_outlined, size: 18, color: AppColors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Your previous response was rejected', style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(widget.nc.verificationNote!, style: TextStyle(color: AppColors.red)),
                        const SizedBox(height: 2),
                        Text(
                          "Your last answers are pre-filled below — edit what's needed and resubmit.",
                          style: TextStyle(color: AppColors.red, fontWeight: FontWeight.w400),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          for (final f in _fields) ...[
            Text.rich(TextSpan(children: [
              TextSpan(text: f.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: ' *', style: TextStyle(color: AppColors.red)),
            ])),
            const SizedBox(height: 2),
            Text(f.$3, style: TextStyle(color: scheme.outline, fontSize: 12)),
            const SizedBox(height: 6),
            TextField(controller: _controllers[f.$1], maxLines: 3, decoration: const InputDecoration()),
            const SizedBox(height: 12),
          ],
          const Text('Photo evidence (optional)', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ..._existingPhotos.asMap().entries.map((e) => Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: () => openPhotoViewer(
                          context,
                          images: [
                            ..._existingPhotos.map((u) => NetworkImage(u) as ImageProvider),
                            ..._photos.map((f) => FileImage(f) as ImageProvider),
                          ],
                          initialIndex: e.key,
                        ),
                        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(e.value, width: 64, height: 64, fit: BoxFit.cover)),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: InkWell(
                          onTap: () => setState(() => _existingPhotos.removeAt(e.key)),
                          child: const CircleAvatar(radius: 9, backgroundColor: Colors.black87, child: Icon(Icons.close, size: 12, color: Colors.white)),
                        ),
                      ),
                    ],
                  )),
              ..._photos.asMap().entries.map((e) => Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: () => openPhotoViewer(
                          context,
                          images: [
                            ..._existingPhotos.map((u) => NetworkImage(u) as ImageProvider),
                            ..._photos.map((f) => FileImage(f) as ImageProvider),
                          ],
                          initialIndex: _existingPhotos.length + e.key,
                        ),
                        child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(e.value, width: 64, height: 64, fit: BoxFit.cover)),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: InkWell(
                          onTap: () => setState(() => _photos.removeAt(e.key)),
                          child: const CircleAvatar(radius: 9, backgroundColor: Colors.black87, child: Icon(Icons.close, size: 12, color: Colors.white)),
                        ),
                      ),
                    ],
                  )),
              if (_totalPhotoCount < 5)
                InkWell(
                  onTap: _pickPhotos,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(border: Border.all(color: scheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.camera_alt_outlined, color: scheme.outline),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Submit Response'),
          ),
        ],
      ),
      ),
    );
  }
}
