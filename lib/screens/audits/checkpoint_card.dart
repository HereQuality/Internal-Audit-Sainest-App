import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/snackbar.dart';
import '../../models/audit_detail_model.dart';
import '../../models/employee_option.dart';
import '../../models/nc_model.dart';
import '../../models/upload_phase.dart';
import '../../widgets/nc_timeliness_badge.dart';
import '../../widgets/photo_picker_sheet.dart';
import '../../widgets/photo_viewer.dart';
import '../../widgets/status_badge.dart';
import 'nc_details_sheet.dart';

/// One leaf checkpoint — mirrors the web app's ParameterScoreCard.jsx:
///  - interactive (assigned auditor, audit still active): 4 finding
///    buttons (Strong Compliance / Compliance / OFI / NC), an OFI-only
///    score field, an optional remark, and optional photo evidence.
///    Autosaves — no separate Save button to remember to tap: a finding
///    pick or finishing the NC-details popup saves right away, remark/
///    score typing saves itself a short pause after the last keystroke
///    (see _onFieldEdited's debounce), and a picked photo uploads
///    immediately on its own, independent of whether a finding/remark has
///    even been filled in yet (see _pickPhotos/_uploadPhotos, mirroring
///    AuditsProvider.uploadCheckpointEvidence). The finding/remark/score
///    autosave fires once findingType alone is present (+ a numeric score
///    if OFI, + NC details for a fresh NC) — see _maybeAutoSave/
///    _isComplete — so a score typed on its own, or a remark typed/
///    edited/cleared on its own, each save right away instead of waiting
///    on the other field. Remark is NOT required to save from the phone
///    (only web's ParameterScoreCard.jsx still requires it — see
///    audit.controller.js#scoreParameter's isMobileRequest check).
///    _statusRow shows what's still missing, that it's saving, a brief
///    "Saved" confirmation, or — the one manual
///    action left — a Retry if an autosave attempt actually failed; a
///    failed photo upload gets its own, separate Retry right by the photo
///    strip instead, since the two save paths are now fully independent.
///  - read-only: just shows whatever was recorded.
/// `onSave`/`onUploadPhotos` return an error message on failure (null on
/// success) — same shape as AuditsProvider#scoreCheckpoint/
/// uploadCheckpointEvidence so this widget never needs to know about Dio/
/// HTTP directly.
typedef SaveCheckpoint = Future<String?> Function({
  required String findingType,
  double? score,
  required String remark,
  String? auditeeEmployeeId,
  DateTime? targetDate,
  String? severity,
});

/// Uploads freshly-picked evidence photos right away — the server attaches
/// them to this checkpoint's photoUrls the moment each upload finishes, no
/// matter whether a finding/remark has been saved yet (see
/// AuditsProvider.uploadCheckpointEvidence).
typedef UploadCheckpointPhotos = Future<String?> Function({
  required List<File> photos,
  void Function(UploadPhase phase, double? fraction)? onProgress,
});

/// Removes one already-uploaded evidence photo — actually deletes it on
/// Cloudinary server-side (see AuditsProvider#deleteEvidencePhoto), not
/// just drops the URL locally. Returns an error message on failure, null
/// on success.
typedef DeleteEvidencePhoto = Future<String?> Function(String url);

/// Auditor: fix a mistake on an already-raised NC (see AuditsProvider#
/// updateNc) — reassign who it's against, its severity/flag, or its due
/// date. Only ever called with all three set together (the edit form
/// below collects them as one unit, same as the raise-time NC-details
/// popup does). Returns an error message on failure, null on success.
typedef UpdateNc = Future<String?> Function({
  String? auditeeEmployeeId,
  String? severity,
  DateTime? targetDate,
});

// Same restriction as nc_details_sheet.dart's own _ncSeverities — no
// "Observation" here either, editing an NC's flag offers the same two
// choices raising one does.
const _ncEditSeverities = ['Major', 'Minor'];

const _findingLabels = {
  'Strong Compliance': 'Strong',
  'Compliance': 'Compliant',
  'OFI': 'OFI',
  'NC': 'Raise NC',
};
const _findingIcons = {
  'Strong Compliance': Icons.check_circle_outline,
  'Compliance': Icons.verified_outlined,
  'OFI': Icons.speed_outlined,
  'NC': Icons.warning_amber_outlined,
};
Color _findingColor(String ft) {
  switch (ft) {
    case 'Strong Compliance':
      return AppColors.green;
    case 'Compliance':
      return AppColors.blue;
    case 'OFI':
      return AppColors.amber;
    case 'NC':
      return AppColors.red;
    default:
      return AppColors.slate;
  }
}

// No SeverityBadge exists yet anywhere in the app (checked lib/widgets/)
// — a plain colored label mirrors server/utils/ncScoring.js's own
// Major/Minor/Observation severity scale (SEVERITY_WEIGHT: 3/1/0) without
// building out a whole new widget for one label.
Color _severityColor(String severity) {
  switch (severity) {
    case 'Major':
      return AppColors.red;
    case 'Observation':
      return AppColors.slate;
    case 'Minor':
    default:
      return AppColors.amber;
  }
}

class CheckpointCard extends StatefulWidget {
  final ParameterNode node;
  final String serial;
  final bool readOnly;
  final double maxScore;
  final SaveCheckpoint onSave;
  final UploadCheckpointPhotos onUploadPhotos;
  final DeleteEvidencePhoto? onDeletePhoto;
  final bool isSelfAudit;
  final List<EmployeeOption> employees;
  // Reports every _saving true/false transition to the parent screen so it
  // can block back-navigation while a save/upload is actually in flight
  // (see audit_detail_screen.dart's PopScope) — this card is otherwise a
  // fully isolated State with no way for its parent to know it's busy.
  final ValueChanged<bool>? onSavingChanged;
  // The full NC this checkpoint's finding raised, if any — resolved by the
  // caller via audit.ncsById[node.ncId] (models/audit_detail_model.dart),
  // itself sourced from the SAME GET /audits/:id response this whole card
  // already renders from (no extra API call). Null for a leaf with no NC,
  // or one whose NC hasn't loaded onto the audit yet.
  final NcModel? linkedNc;
  // The logged-in auditor's own id — compared against linkedNc.raisedBy.id
  // to decide whether the "Edit" affordance below shows at all (only the
  // person who raised it may fix a mistake on it, mirrors
  // nc.controller.js#updateNC's own check).
  final String? currentEmployeeId;
  final UpdateNc? onUpdateNc;

  const CheckpointCard({
    super.key,
    required this.node,
    required this.serial,
    required this.readOnly,
    required this.maxScore,
    required this.onSave,
    required this.onUploadPhotos,
    this.onDeletePhoto,
    this.isSelfAudit = false,
    this.employees = const [],
    this.onSavingChanged,
    this.linkedNc,
    this.currentEmployeeId,
    this.onUpdateNc,
  });

  @override
  State<CheckpointCard> createState() => _CheckpointCardState();
}

class _CheckpointCardState extends State<CheckpointCard> {
  String? _findingType;
  String? _auditeeEmployeeId;
  // Due date for a fresh NC — collected in the NC-details popup (see
  // _openNcDetailsPopup) alongside the auditee pick, same shape as the
  // web app's ParameterScoreCard.jsx once it grows the equivalent field.
  DateTime? _targetDate;
  // Severity for a fresh NC — same Major/Minor/Observation choice the
  // NC-details popup collects and the web app's ParameterScoreCard.jsx
  // already offers inline; defaults to "Minor" so it's never a second
  // blocking field on top of the auditee pick and due date.
  String _severity = 'Minor';
  final _remarkController = TextEditingController();
  final _scoreController = TextEditingController();
  List<String> _existingPhotos = [];
  // Picked photos still uploading (or whose last upload attempt failed) —
  // NOT a "staged, not yet saved" queue the way it used to be. A pick
  // fires _uploadPhotos immediately (see _pickPhotos); an entry only
  // leaves this list once the server actually confirms it (which arrives
  // via didUpdateWidget's node.photoUrls resync, dropping it from here in
  // the same setState — see _uploadPhotos below).
  final List<File> _newPhotos = [];
  final Set<String> _deletingPhotoUrls = {};
  // Finding/remark/score/NC-details save — fully independent of photo
  // upload below now (AuditsProvider.scoreCheckpoint no longer touches
  // photoUrls at all).
  bool _saving = false;
  bool _justSaved = false;
  // Bumped on every field edit (remark/score typing, finding pick, NC
  // details) — fields stay editable while a save is in flight, so _save()
  // snapshots this and only shows "Saved" if nothing changed underneath it
  // while it was in flight; otherwise the edit that arrived mid-save would
  // be silently unsaved but the checkmark would claim it wasn't.
  int _editVersion = 0;
  String? _error;
  // Photo upload — its own independent in-flight/error state (see
  // _uploadPhotos), since a photo can now upload while a finding/remark
  // save is separately in flight, or vice versa.
  bool _uploadingPhotos = false;
  String? _photoUploadError;
  UploadPhase? _uploadPhase;
  double? _uploadFraction;
  // Debounces remark/score typing so autosave fires a short pause after
  // the last keystroke instead of on every character — see
  // _onFieldEdited. Discrete actions (finding pick, photo add, NC details)
  // autosave immediately instead, no debounce needed.
  Timer? _debounce;

  // Editing an ALREADY-raised NC's auditee/severity/due-date — separate
  // from _openNcDetailsPopup above, which only ever runs once, before
  // widget.node.ncId exists. This is the "fix a mistake after the fact"
  // path (see AuditsProvider#updateNc/_canEditNc below): its own save is
  // explicit (Save/Cancel), not autosaved, since it's a deliberate
  // correction the auditor opts into rather than routine scoring.
  bool _ncEditOpen = false;
  String? _ncEditAuditeeId;
  DateTime? _ncEditTargetDate;
  String _ncEditSeverity = 'Minor';
  bool _ncEditSaving = false;
  String? _ncEditError;

  @override
  void initState() {
    super.initState();
    _findingType = widget.node.findingType;
    _remarkController.text = widget.node.remark ?? '';
    // toStringAsFixed(0), not toString() — scores are always whole numbers
    // (see the digitsOnly input formatter below), but a Dart double's own
    // toString() always appends ".0" even for a whole value, so a
    // genuinely-already-scored "0" or "3" was showing as the confusing
    // "0.0"/"3.0" instead. A checkpoint that's never been scored still
    // starts blank either way — the server defaults score to null, not 0
    // (see server/models/Audit.js#AuditNodeSchema), so this only changes
    // how an existing score is FORMATTED, never fabricates one.
    _scoreController.text = widget.node.score != null ? widget.node.score!.toStringAsFixed(0) : '';
    _existingPhotos = List.of(widget.node.photoUrls);
    _remarkController.addListener(_onFieldEdited);
    _scoreController.addListener(_onFieldEdited);
  }

  @override
  void didUpdateWidget(covariant CheckpointCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Every save (scoreCheckpoint) refetches the whole audit tree and the
    // parent screen passes a fresh `node` down here under the SAME
    // ValueKey(node.id) — so Flutter reuses this State instead of running
    // initState() again, and _existingPhotos (set once, in initState)
    // never picked up the newly-uploaded photo's Cloudinary URL. Net
    // effect: the photo genuinely saved server-side, but visually
    // vanished from the card — _newPhotos correctly dropped the local
    // File once it was sent, and nothing ever added the server URL in
    // its place. Only _existingPhotos is resynced here (never
    // findingType/remark/score, which stay debounced-editable) since it's
    // pure server truth — _newPhotos (locally-picked, not-yet-uploaded
    // files) is untouched either way.
    if (widget.node.photoUrls != oldWidget.node.photoUrls) {
      setState(() => _existingPhotos = List.of(widget.node.photoUrls));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _remarkController.dispose();
    _scoreController.dispose();
    super.dispose();
  }

  // A fresh NC finding (this checkpoint doesn't already have one raised)
  // on a non-self-audit needs an explicit "who is this against" pick —
  // mirrors ParameterScoreCard.jsx's identical condition. Self Audit
  // always resolves to the auditor themselves server-side, no picker.
  bool get _needsAuditeePick => _findingType == 'NC' && widget.node.ncId == null && !widget.isSelfAudit;

  // A fresh NC (not yet raised) always needs its own popup filled in —
  // auditee pick (non-self-audit only) + a due date — before it can save,
  // regardless of who it's against.
  bool get _needsNcDetails => _findingType == 'NC' && widget.node.ncId == null;

  // What's still needed before this checkpoint can save at all — mirrors
  // audit.controller.js#scoreParameter's own validation for a mobile
  // caller (findingType always; a numeric score additionally for OFI; an
  // auditee pick + due date for a fresh NC) so the hint text here never
  // promises a save the server would actually reject. Remark is
  // deliberately NOT required here — the server only makes it mandatory
  // for web callers; on the phone a finding pick, a score, or a remark
  // typed on its own should each save right away instead of waiting on
  // whichever of the three hasn't been filled in yet.
  String? get _missingFieldHint {
    if (_findingType == null) return null; // nothing picked yet — no nag before they've started
    if (_findingType == 'OFI' && double.tryParse(_scoreController.text.trim()) == null) return 'Enter a score to save';
    if (_needsAuditeePick && _auditeeEmployeeId == null) return 'Pick who this NC is against';
    if (_needsNcDetails && _targetDate == null) return 'Set a due date for this NC';
    return null;
  }

  bool get _isComplete => _findingType != null && _missingFieldHint == null;

  // Only the raising auditor, and only while the NC is still sitting in
  // "Raised" (before the auditee has submitted a response) — same two
  // checks nc.controller.js#updateNC itself enforces server-side, mirrored
  // here purely so the "Edit" button doesn't show promising an action the
  // server would then reject.
  bool get _isNcRaiser =>
      widget.linkedNc != null &&
      widget.currentEmployeeId != null &&
      widget.linkedNc!.raisedBy.id == widget.currentEmployeeId;

  bool get _canEditNc =>
      widget.onUpdateNc != null &&
      _isNcRaiser &&
      widget.linkedNc!.status == 'Raised';

  void _openNcEditForm() {
    final nc = widget.linkedNc;
    if (nc == null) return;
    setState(() {
      _ncEditAuditeeId = nc.auditee.id.isNotEmpty ? nc.auditee.id : null;
      _ncEditSeverity = _ncEditSeverities.contains(nc.severity)
          ? nc.severity
          : 'Minor';
      _ncEditTargetDate = nc.targetDate;
      _ncEditError = null;
      _ncEditOpen = true;
    });
  }

  Future<void> _pickNcEditDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _ncEditTargetDate ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _ncEditTargetDate = picked);
  }

  Future<void> _saveNcEdit() async {
    if (!widget.isSelfAudit && _ncEditAuditeeId == null) {
      setState(() => _ncEditError = 'Pick who this NC is against');
      return;
    }
    if (_ncEditTargetDate == null) {
      setState(() => _ncEditError = 'Set a due date');
      return;
    }
    setState(() {
      _ncEditSaving = true;
      _ncEditError = null;
    });
    final error = await widget.onUpdateNc!(
      auditeeEmployeeId: widget.isSelfAudit ? null : _ncEditAuditeeId,
      severity: _ncEditSeverity,
      targetDate: _ncEditTargetDate,
    );
    if (!mounted) return;
    setState(() {
      _ncEditSaving = false;
      if (error == null) {
        _ncEditOpen = false;
      } else {
        _ncEditError = error;
      }
    });
  }

  // Autosaves once this checkpoint is actually complete (see _isComplete) —
  // a no-op otherwise (e.g. a finding was just picked but the remark's
  // still empty), so every call site below can fire this unconditionally
  // right after its own edit instead of separately checking readiness.
  // Cancels any pending debounce first — an immediate trigger (finding
  // pick, photo, NC details) firing this makes a still-queued debounced
  // save from earlier remark typing redundant; without this it would fire
  // moments later and resend the exact same fields a second time.
  void _maybeAutoSave() {
    _debounce?.cancel();
    if (!mounted || _saving || !_isComplete) return;
    _save();
  }

  // Every remark/score keystroke goes through here — refreshes the hint
  // text, clears any stale "Saved" state, and (re)starts the debounce
  // timer so autosave fires a short pause after the last keystroke rather
  // than mid-word on every character.
  void _onFieldEdited() {
    setState(() {
      _justSaved = false;
      _editVersion++;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), _maybeAutoSave);
  }

  void _selectFinding(String ft) {
    setState(() {
      _findingType = ft;
      _justSaved = false;
      _editVersion++;
    });
    // A fresh NC needs its own popup (auditee pick + due date) filled in
    // before it can be saved — open it right away instead of leaving the
    // auditor to hunt for a now-visible-but-easy-to-miss inline control.
    if (ft == 'NC' && widget.node.ncId == null) {
      _openNcDetailsPopup();
    } else {
      _maybeAutoSave();
    }
  }

  // Opens the NC-details popup (auditee pick, restricted to the current
  // location's members where one applies — see audit_detail_screen.dart's
  // employee filtering — due date, and remark). Reusable both from the
  // initial "NC" pick above and from the "Set/edit NC details" button
  // shown while details are still missing or being revised.
  Future<void> _openNcDetailsPopup() async {
    final result = await showNcDetailsSheet(
      context,
      employees: widget.employees,
      isSelfAudit: widget.isSelfAudit,
      initialAuditeeId: _auditeeEmployeeId,
      initialTargetDate: _targetDate,
      initialRemark: _remarkController.text,
      initialSeverity: _severity,
    );
    if (result == null || !mounted) return;
    setState(() {
      _auditeeEmployeeId = result.auditeeEmployeeId;
      _targetDate = result.targetDate;
      _remarkController.text = result.remark;
      _severity = result.severity;
      _justSaved = false;
      _editVersion++;
    });
    _maybeAutoSave();
  }

  // An already-uploaded photo is removed immediately (not deferred to the
  // checkpoint's own autosave) — it calls straight through to Cloudinary
  // deletion server-side, so leaving the screen right after tapping
  // remove never leaves the file orphaned in storage.
  Future<void> _removeExistingPhoto(String url) async {
    if (widget.onDeletePhoto == null) {
      setState(() => _existingPhotos.remove(url));
      return;
    }
    setState(() => _deletingPhotoUrls.add(url));
    final error = await widget.onDeletePhoto!(url);
    if (!mounted) return;
    setState(() {
      _deletingPhotoUrls.remove(url);
      if (error == null) _existingPhotos.remove(url);
    });
    if (error != null) showErrorSnackBar(context, error);
  }

  Future<void> _pickPhotos() async {
    final picked = await pickEvidencePhotos(context);
    if (picked.isEmpty || !mounted) return;
    setState(() => _newPhotos.addAll(picked));
    await _uploadPhotos(picked);
  }

  // Uploads immediately — independent of the finding/remark save below,
  // and of whether this checkpoint is even complete yet (see the class
  // doc comment). `photos` is exactly the set this attempt is sending, so
  // a Retry after a failure (see the photo-strip error row) can pass the
  // same still-pending `_newPhotos` back in without resending anything
  // that separately succeeded in the meantime.
  Future<void> _uploadPhotos(List<File> photos) async {
    if (!mounted) return;
    setState(() {
      _uploadingPhotos = true;
      _photoUploadError = null;
    });
    widget.onSavingChanged?.call(true);
    final error = await widget.onUploadPhotos(
      photos: photos,
      onProgress: (phase, fraction) {
        if (!mounted) return;
        setState(() {
          _uploadPhase = phase;
          _uploadFraction = fraction;
        });
      },
    );
    // Reported unconditionally, ahead of the `mounted` guard below — this
    // card can be unmounted mid-upload (e.g. a location-filter toggle
    // removes it from the tree while its request is still in flight) and
    // the parent's active-save count must still come back down, or the
    // back-navigation guard would stay locked forever over a card that no
    // longer exists.
    widget.onSavingChanged?.call(false);
    if (!mounted) return;
    setState(() {
      _uploadingPhotos = false;
      _uploadPhase = null;
      _uploadFraction = null;
      _photoUploadError = error;
      // On success the server already attached these to photoUrls and
      // refetched the audit — didUpdateWidget's node.photoUrls resync
      // picks them up as _existingPhotos, so drop them here rather than
      // showing every photo twice. Left in _newPhotos on failure so
      // Retry has exactly what to resend.
      if (error == null) photos.forEach(_newPhotos.remove);
    });
  }

  Future<void> _save() async {
    if (!_isComplete || _saving) return;
    double? score;
    if (_findingType == 'OFI') {
      score = double.tryParse(_scoreController.text.trim());
    }
    final savedVersion = _editVersion;
    setState(() {
      _error = null;
      _saving = true;
    });
    widget.onSavingChanged?.call(true);
    final error = await widget.onSave(
      findingType: _findingType!,
      score: score,
      remark: _remarkController.text.trim(),
      auditeeEmployeeId: _needsAuditeePick ? _auditeeEmployeeId : null,
      targetDate: _needsNcDetails ? _targetDate : null,
      severity: _needsNcDetails ? _severity : null,
    );
    // Reported unconditionally, ahead of the `mounted` guard below — this
    // card can be unmounted mid-save (e.g. a location-filter toggle removes
    // it from the tree while its request is still in flight) and the
    // parent's active-save count must still come back down, or the
    // back-navigation guard would stay locked forever over a card that no
    // longer exists.
    widget.onSavingChanged?.call(false);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
      // Only claim "Saved" if nothing changed while this request was in
      // flight — an edit made mid-save bumps _editVersion, and that edit
      // wasn't included in what was just sent.
      _justSaved = error == null && _editVersion == savedVersion;
    });
    // An edit landed while this save was in flight (see the doc comment on
    // _editVersion) — with no Save button left for the auditor to press
    // themselves, this has to follow up on its own so that edit doesn't
    // just sit there silently unsaved.
    if (error == null && _editVersion != savedVersion) _maybeAutoSave();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Read-only cards are tinted by their finding — same green/blue/amber/
    // red-at-a-glance treatment as the web app's ParameterScoreCard.jsx,
    // instead of every finding looking identical until you read the pill.
    final tone = widget.readOnly && widget.node.findingType != null ? _findingColor(widget.node.findingType!) : null;
    return Card(
      margin: EdgeInsets.zero,
      color: tone?.withValues(alpha: 0.08),
      shape: tone != null
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: tone.withValues(alpha: 0.35)))
          : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(color: AppColors.blue, borderRadius: BorderRadius.circular(6)),
                  child: Text(widget.serial, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(widget.node.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                if (widget.readOnly && widget.node.findingType != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: _findingColor(widget.node.findingType!).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                    child: Text(_findingLabels[widget.node.findingType] ?? widget.node.findingType!,
                        style: TextStyle(color: _findingColor(widget.node.findingType!), fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (widget.readOnly) _buildReadOnly(scheme) else _buildEditable(scheme),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnly(ColorScheme scheme) {
    // Previously rendered nothing at all here — indistinguishable from a
    // broken/empty card. An unscored leaf in a read-only tree is a normal,
    // expected state (the assigned auditor just hasn't gotten to it yet),
    // so it says so instead of looking blank.
    if (widget.node.findingType == null) {
      return Text('Not yet scored', style: TextStyle(color: scheme.outline, fontSize: 12.5, fontStyle: FontStyle.italic));
    }
    final tone = _findingColor(widget.node.findingType!);
    // Only OFI's score is actually auditor-entered — Strong Compliance/
    // Compliance always resolve to full marks and NC always to zero (see
    // server/controllers/audit.controller.js#scoreParameter), so showing
    // "Score: X / Y" for those reads as redundant with the finding badge
    // itself rather than telling the reader anything new.
    final blocks = <Widget>[
      if (widget.node.findingType == 'OFI')
        Text(
          // toStringAsFixed(0), not toString() / raw interpolation — see the
          // initState comment above: scores are always whole numbers, but a
          // Dart double's own toString() appends ".0" even for a whole
          // value, so a genuinely-scored "3" was showing as "3.0" here.
          'Score: ${widget.node.score != null ? widget.node.score!.toStringAsFixed(0) : '—'}${widget.maxScore > 0 ? ' / ${widget.maxScore.toStringAsFixed(0)}' : ''}',
          style: TextStyle(color: scheme.outline, fontSize: 12.5),
        ),
      if ((widget.node.remark ?? '').isNotEmpty)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            // Was a hardcoded Colors.white — washed out to a barely
            // visible pale patch in dark mode. surface (theme-aware)
            // keeps the same "lighter than the card" contrast in both.
            color: scheme.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
            border: Border(left: BorderSide(color: tone, width: 3)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.chat_bubble_outline, size: 13, color: tone),
            const SizedBox(width: 6),
            Expanded(child: Text(widget.node.remark!, style: TextStyle(color: scheme.onSurface, fontSize: 12.5))),
          ]),
        ),
      if (widget.node.photoUrls.isNotEmpty) _photoStrip(widget.node.photoUrls),
      if (widget.linkedNc != null) _linkedNcBlock(scheme, widget.linkedNc!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      // A gap only BETWEEN blocks that actually rendered — with the score
      // line now sometimes skipped above, a fixed gap ahead of whichever
      // block happens to be first would otherwise leave stray top padding.
      children: [
        for (int i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          blocks[i],
        ],
      ],
    );
  }

  // Who this NC is against, its own lifecycle status, due date, and a live
  // On-Time/Delayed/Overdue verdict (core/utils/nc_timeliness.dart) — the
  // detail a bare "NC" finding pill used to leave completely invisible
  // here, even though scoring_workspace already had the full NC document
  // on hand (see checkpoint_card.dart's linkedNc doc comment above).
  Widget _linkedNcBlock(ColorScheme scheme, NcModel nc) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline, size: 13, color: scheme.outline),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Against ${nc.auditee.name}',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurface),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Due ${Formatters.date(nc.targetDate)}', style: TextStyle(fontSize: 12, color: scheme.outline)),
              NcTimelinessBadge(startDate: nc.startDate, targetDate: nc.targetDate, completionDate: nc.completionDate),
              Text(nc.severity, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _severityColor(nc.severity))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEditable(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _findingLabels.keys.map((ft) {
            final active = _findingType == ft;
            final color = _findingColor(ft);
            return ChoiceChip(
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_findingIcons[ft], size: 15, color: active ? color : scheme.outline),
                const SizedBox(width: 4),
                Text(_findingLabels[ft]!),
              ]),
              selected: active,
              onSelected: (_) => _selectFinding(ft),
              selectedColor: color.withValues(alpha: 0.14),
              labelStyle: TextStyle(color: active ? color : scheme.onSurface, fontWeight: FontWeight.w600),
              side: BorderSide(color: active ? color : scheme.outlineVariant),
            );
          }).toList(),
        ),
        if (_findingType == 'OFI') ...[
          const SizedBox(height: 10),
          SizedBox(
            width: 140,
            child: TextField(
              controller: _scoreController,
              keyboardType: TextInputType.number,
              // Whole numbers only — no decimal point, no exponent/sign
              // characters a bare TextInputType.number keyboard can still
              // let through on some IMEs.
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(labelText: 'Score (max ${(widget.maxScore - 1).toStringAsFixed(0)})'),
              // Hard-clamp to strictly BELOW this checkpoint's own max as they
              // type — an OFI is by definition a partial score (full marks
              // belong to Strong Compliance/Compliance instead), same rule the
              // server enforces, but letting the field visibly show the
              // impossible max first is confusing.
              onChanged: (value) {
                final n = double.tryParse(value);
                if (n != null && n >= widget.maxScore) {
                  final clamped = (widget.maxScore - 1).toStringAsFixed(0);
                  _scoreController.value = TextEditingValue(text: clamped, selection: TextSelection.collapsed(offset: clamped.length));
                }
              },
            ),
          ),
        ],
        // Fresh NC — auditee pick (skipped for Self Audit) + due date are
        // both collected together in one popup (see nc_details_sheet.dart)
        // instead of an inline dropdown, so the due date has somewhere to
        // live too.
        if (_needsNcDetails) ...[
          const SizedBox(height: 10),
          _ncDetailsSummary(scheme) ?? OutlinedButton.icon(
            onPressed: _openNcDetailsPopup,
            icon: const Icon(Icons.assignment_outlined, size: 17),
            label: Text(widget.isSelfAudit ? 'Set NC due date' : 'Set NC auditee & due date'),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _remarkController,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Add remark or observations...', prefixIcon: Icon(Icons.chat_bubble_outline)),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ..._existingPhotos.asMap().entries.map((e) => _removablePhoto(
                  child: GestureDetector(
                    onTap: () => openPhotoViewer(
                      context,
                      images: _existingPhotos.map((u) => CachedNetworkImageProvider(u) as ImageProvider).toList(),
                      initialIndex: e.key,
                    ),
                    child: _thumb(CachedNetworkImage(imageUrl: e.value, width: 56, height: 56, fit: BoxFit.cover)),
                  ),
                  busy: _deletingPhotoUrls.contains(e.value),
                  onRemove: () => _removeExistingPhoto(e.value),
                )),
            // A picked photo uploads the moment it's picked (see
            // _pickPhotos/_uploadPhotos) — busy (spinner, no remove) for
            // as long as that upload is in flight, same convention as an
            // already-uploaded photo's own delete-in-flight state above.
            ..._newPhotos.asMap().entries.map((e) => _removablePhoto(
                  child: GestureDetector(
                    onTap: () => openPhotoViewer(
                      context,
                      images: _newPhotos.map((f) => FileImage(f) as ImageProvider).toList(),
                      initialIndex: e.key,
                    ),
                    child: _thumb(Image.file(e.value, width: 56, height: 56, fit: BoxFit.cover)),
                  ),
                  busy: _uploadingPhotos,
                  onRemove: () => setState(() => _newPhotos.remove(e.value)),
                )),
            // Disabled while a batch is already uploading — _uploadingPhotos
            // is one flag for the whole card (see its own doc comment), not
            // per-file, so a second pick starting before the first batch's
            // upload finishes would stomp it and leave the busy overlay on
            // the in-flight batch's own thumbnails out of sync.
            InkWell(
              onTap: _uploadingPhotos ? null : _pickPhotos,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.camera_alt_outlined, color: _uploadingPhotos ? scheme.outline.withValues(alpha: 0.4) : scheme.outline),
              ),
            ),
          ],
        ),
        // Photo upload's own status — fully independent of the finding/
        // remark save below it, since the two can now be in flight at the
        // same time (see the class doc comment).
        if (_uploadingPhotos) ...[
          const SizedBox(height: 6),
          _photoUploadStatus(scheme),
        ] else if (_photoUploadError != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text(_photoUploadError!, style: TextStyle(color: scheme.error, fontSize: 12.5))),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => _uploadPhotos(List.of(_newPhotos)),
                icon: const Icon(Icons.refresh, size: 15),
                label: const Text('Retry'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ],
        if (_findingType == 'NC' && widget.node.ncId != null && widget.linkedNc != null) ...[
          const SizedBox(height: 10),
          _linkedNcEditableBlock(scheme, widget.linkedNc!),
        ],
        const SizedBox(height: 10),
        _statusRow(scheme),
      ],
    );
  }

  Widget _photoUploadStatus(ColorScheme scheme) {
    final label = switch (_uploadPhase) {
      UploadPhase.uploading => 'Uploading photo ${((_uploadFraction ?? 0) * 100).toStringAsFixed(0)}%…',
      UploadPhase.processing => 'Processing photo…',
      null => 'Uploading photo…',
    };
    return Row(children: [
      SizedBox(height: 13, width: 13, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline)),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: scheme.outline, fontSize: 12.5)),
    ]);
  }

  // Saving (spinner), a brief "Saved" confirmation right after success, a
  // muted hint for whatever's still missing (findingType, remark, OFI
  // score, NC details) before autosave has anything to send, or — the one
  // case that still needs a manual tap — a save that actually failed,
  // alongside Retry.
  Widget _statusRow(ColorScheme scheme) {
    if (_saving) {
      return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        SizedBox(height: 13, width: 13, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline)),
        const SizedBox(width: 6),
        Text('Saving…', style: TextStyle(color: scheme.outline, fontSize: 12.5)),
      ]);
    }
    if (_justSaved) {
      return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        Icon(Icons.check_circle, size: 14, color: AppColors.green),
        const SizedBox(width: 4),
        Text('Saved', style: TextStyle(color: AppColors.green, fontSize: 12.5, fontWeight: FontWeight.w600)),
      ]);
    }
    if (_error != null) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Expanded(child: Text(_error!, style: TextStyle(color: scheme.error, fontSize: 12.5))),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.refresh, size: 15),
            label: const Text('Retry'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      );
    }
    final hint = _missingFieldHint;
    if (hint != null) {
      return Align(
        alignment: Alignment.centerRight,
        child: Text(hint, style: TextStyle(color: scheme.outline, fontSize: 12.5)),
      );
    }
    return const SizedBox.shrink();
  }

  // Once the NC-details popup has been filled in, show what was picked
  // (with a way to reopen and change it) instead of the "set details"
  // button — null while anything's still missing, so the button above
  // stays in place until then.
  Widget? _ncDetailsSummary(ColorScheme scheme) {
    if (_needsAuditeePick && _auditeeEmployeeId == null) return null;
    if (_targetDate == null) return null;
    final auditeeName = widget.isSelfAudit
        ? 'you'
        : widget.employees.firstWhere(
            (e) => e.id == _auditeeEmployeeId,
            orElse: () => const EmployeeOption(id: '', name: 'Unknown'),
          ).name;
    return InkWell(
      onTap: _openNcDetailsPopup,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.red.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.red.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            const Icon(Icons.assignment_outlined, size: 15, color: AppColors.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Against $auditeeName  •  Due ${Formatters.date(_targetDate)}  •  $_severity',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: scheme.onSurface),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.edit_outlined, size: 15, color: scheme.outline),
          ],
        ),
      ),
    );
  }

  // The already-raised NC's current auditee/due-date/severity, plus an
  // "Edit" affordance when this auditor is allowed to fix a mistake on it
  // (see _canEditNc) — the interactive-card equivalent of _linkedNcBlock's
  // read-only NC thread, shown right here instead since a still-in-
  // progress audit's checkpoint never renders that read-only branch at
  // all.
  Widget _linkedNcEditableBlock(ColorScheme scheme, NcModel nc) {
    if (!_ncEditOpen) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Row(
          children: [
            StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.isSelfAudit ? 'You' : nc.auditee.name}  •  Due ${Formatters.date(nc.targetDate)}  •  ${nc.severity}',
                style: TextStyle(fontSize: 12.5, color: scheme.onSurface),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_canEditNc)
              TextButton.icon(
                onPressed: _openNcEditForm,
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text('Edit'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.isSelfAudit) ...[
            DropdownButtonFormField<String>(
              initialValue: widget.employees.any((e) => e.id == _ncEditAuditeeId) ? _ncEditAuditeeId : null,
              decoration: const InputDecoration(labelText: 'Raise NC against', isDense: true),
              isExpanded: true,
              items: widget.employees
                  .map((e) => DropdownMenuItem(value: e.id, child: Text(e.name, overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: (v) => setState(() => _ncEditAuditeeId = v),
            ),
            const SizedBox(height: 8),
          ],
          DropdownButtonFormField<String>(
            initialValue: _ncEditSeverity,
            decoration: const InputDecoration(labelText: 'Flag', isDense: true),
            items: _ncEditSeverities.map((s) => DropdownMenuItem(value: s, child: Text(s))).toList(),
            onChanged: (v) => setState(() => _ncEditSeverity = v ?? _ncEditSeverity),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickNcEditDate,
            borderRadius: BorderRadius.circular(8),
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Due Date', isDense: true),
              child: Text(_ncEditTargetDate == null ? 'Select a date' : Formatters.date(_ncEditTargetDate)),
            ),
          ),
          if (_ncEditError != null) ...[
            const SizedBox(height: 6),
            Text(_ncEditError!, style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _ncEditSaving ? null : () => setState(() => _ncEditOpen = false),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 4),
              ElevatedButton(
                onPressed: _ncEditSaving ? null : _saveNcEdit,
                child: _ncEditSaving
                    ? const SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _thumb(Widget child) => ClipRRect(borderRadius: BorderRadius.circular(8), child: child);

  // A thumbnail with a small "x" badge in the corner to remove it — a
  // spinner takes its place while an already-uploaded photo's delete
  // request is in flight (see _removeExistingPhoto).
  Widget _removablePhoto({required Widget child, required VoidCallback onRemove, bool busy = false}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Opacity(opacity: busy ? 0.4 : 1, child: child),
        Positioned(
          top: -6,
          right: -6,
          child: busy
              ? const SizedBox(width: 18, height: 18, child: Padding(padding: EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2)))
              : InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 12, color: Colors.white),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _photoStrip(List<String> urls) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: urls.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => openPhotoViewer(
            context,
            images: urls.map((u) => CachedNetworkImageProvider(u) as ImageProvider).toList(),
            initialIndex: i,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(imageUrl: urls[i], width: 56, height: 56, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}
