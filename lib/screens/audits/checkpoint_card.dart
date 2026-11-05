import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/storage/pending_checkpoint_store.dart';
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
import '../../widgets/bold_text.dart';
import '../../widgets/status_badge.dart';
import 'nc_details_sheet.dart';

/// One leaf checkpoint — mirrors the web app's ParameterScoreCard.jsx:
///  - interactive (assigned auditor, audit still active): 4 finding
///    buttons (Strong / Compliance / OFI / NC) plus "Not applicable", a score
///    that follows the finding (see [scoreRuleFor]) — nothing is typed: Strong
///    and Compliance are the full max, NC is 0, and an OFI is picked from a row
///    of buttons 0..max-1 — an optional remark, and optional photo evidence.
///  - read-only: just shows whatever was recorded.
///
/// Nothing the auditor does is left to a Save button — every edit saves
/// itself, and the card always knows whether it has anything the server
/// hasn't confirmed yet:
///  - a finding pick / an OFI score pick / finishing the NC-details popup
///    saves right away; remark typing saves a short pause after the last
///    keystroke (_scheduleSave); a picked photo uploads immediately on its own.
///  - every request for this checkpoint (score saves AND photo uploads) goes
///    through one queue (_exclusive), and each score save reads the fields
///    at the moment it actually runs — so two saves can never race and a
///    slow, older request can never overwrite newer text with stale data.
///  - a failed save retries by itself with a growing delay (_scheduleRetry),
///    then falls back to a manual Retry; the card reports its state
///    ([CheckpointSyncState]) to the screen, which uses it for the
///    "changes not saved" back-guard and the top save indicator.
///  - the card flushes immediately when the app goes to the background
///    (WidgetsBindingObserver) and when it is removed from the tree (a
///    location-tab switch), and the screen can [CheckpointCardState.flush]
///    it before Submit/Final Submit.
///  - a remark typed BEFORE any finding is picked saves to the server on its
///    own too (findingType omitted — see _payload/_canSave), the same way a
///    photo already does independent of the finding; it is also kept as a
///    device draft (_writeDraft) purely as an offline fallback.
///  - "Not applicable" is the one thing that is NOT an autosave: a deliberate
///    tap, ALWAYS confirmed first (what would be cleared is named when
///    something is recorded), that sends its own request through the same
///    queue, clears what was typed / picked here and what the server holds,
///    and from then on nothing is sent for the checkpoint — no remark, no
///    score, no photo — until "Make applicable again" returns it blank (see
///    _markNotApplicable).
/// `onSave` returns an error message on failure (null on success) — same
/// shape as AuditsProvider#scoreCheckpoint so this widget never needs to
/// know about Dio/HTTP directly.
typedef SaveCheckpoint = Future<String?> Function({
  // Null = no finding picked yet — a remark-only save (see _canSave/_payload).
  String? findingType,
  double? score,
  required String remark,
  String? auditeeEmployeeId,
  DateTime? targetDate,
  String? severity,
});

/// Marks the checkpoint Not Applicable (true) or applicable again (false) — see AuditsProvider#setCheckpointNotApplicable.
/// Returns an error message on failure, null on success. Optional on the card: without it there is no such button.
typedef SetCheckpointNotApplicable = Future<String?> Function(bool notApplicable);

/// Uploads freshly-picked evidence photos right away — the server attaches
/// them to this checkpoint's photoUrls the moment each upload finishes, no
/// matter whether a finding/remark has been saved yet. Returns per-file,
/// not all-or-nothing (see UploadPhotosResult/AuditsProvider
/// .uploadCheckpointEvidence's own doc comments) — a batch can partially
/// succeed.
typedef UploadCheckpointPhotos = Future<UploadPhotosResult> Function({
  required List<File> photos,
  void Function(UploadPhase phase, double? fraction)? onProgress,
});

/// Removes one already-uploaded evidence photo — actually deletes it on
/// Cloudinary server-side (see AuditsProvider#deleteEvidencePhoto), not
/// just drops the URL locally. Returns an error message on failure, null
/// on success.
typedef DeleteEvidencePhoto = Future<String?> Function(String url);

/// Auditor: fix a mistake on an already-raised NC (see AuditsProvider#
/// updateNc) — reassign who it's against, its flag (`severity` on the
/// wire), or its due date. Only ever called with all three set together,
/// because the edit mode of the NC-details sheet (nc_details_sheet.dart,
/// opened by _openNcEditSheet below) collects them as one unit — the very
/// same sheet, and the very same three fields, the raise-time flow already
/// goes through. Returns an error message on failure, null on success.
typedef UpdateNc = Future<String?> Function({
  String? auditeeEmployeeId,
  String? severity,
  DateTime? targetDate,
});

/// Where a checkpoint stands with the server, as far as the screen's
/// back-guard and save indicator care:
///  - clean: everything the auditor did here is saved (or, for a remark
///    typed with no finding yet, kept as a draft on the device);
///  - saving: an edit/photo is waiting on, or in the middle of, a request;
///  - failed: the last attempt failed (it may still be retrying);
///  - incomplete: a finding was picked but what the server needs to accept
///    it (a score, NC details) is still missing, so nothing can be sent.
enum CheckpointSyncState { clean, saving, failed, incomplete }

/// How a finding constrains its score. Nothing is typed any more, so every
/// rule is either fixed or a short list of picks: Strong Compliance AND
/// Compliance are fixed at the full max, NC is fixed at 0, and OFI — the one
/// finding with a choice — takes a WHOLE number 0..max-1 (an OFI is by
/// definition a partial score; full marks belong to Compliance). Same as the
/// server's scoreParameter, which stores the full max for Strong/Compliance
/// whatever is sent. Always derived from the audit's own max (new audits are
/// 10, an older one may carry another), never a hard-coded 10.
class ScoreRule {
  final bool fixed;
  final double min;
  final double max;
  const ScoreRule.fixed(double value)
      : fixed = true,
        min = value,
        max = value;
  const ScoreRule.range(this.min, this.max) : fixed = false;

  /// Only meaningful when [fixed].
  double get fixedValue => min;
}

ScoreRule scoreRuleFor(String? findingType, double maxScore) {
  switch (findingType) {
    case 'OFI':
      return ScoreRule.range(0, maxScore > 1 ? maxScore - 1 : 0);
    case 'NC':
      return const ScoreRule.fixed(0);
    default: // Strong Compliance and Compliance: full marks
      return ScoreRule.fixed(maxScore);
  }
}

/// The scores an auditor can pick for an OFI: every whole number from 0 to
/// max-1 (0..9 when the max is 10, 0..2 for an older audit with a max of 3).
/// A max of 1 or less leaves just 0 — there is no room below it.
List<int> ofiScoreOptions(double maxScore) {
  final top = maxScore > 1 ? (maxScore - 1).floor() : 0;
  return [for (var v = 0; v <= top; v++) v];
}

// The OFI score a node already carries as a pick: its stored score when it is one of the buttons, else null.
int? _ofiScoreOf(ParameterNode node, double maxScore) {
  if (node.findingType != 'OFI' || node.score == null) return null;
  final v = node.score!.round();
  return ofiScoreOptions(maxScore).contains(v) ? v : null;
}

/// Whole number without a trailing ".0" (a Dart double prints "10.0").
String formatScore(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// Up to this many picks an OFI score is a row of buttons; an older audit with a
/// big max (a 100-point scale would be 100 buttons) falls back to a dropdown.
const int ofiButtonsLimit = 20;

const _findingLabels = {
  'Strong Compliance': 'Strong',
  'Compliance': 'Compliance',
  'OFI': 'OFI',
  'NC': 'NC',
};
// Not Applicable is deliberately NOT among _findingLabels / _findingIcons: those drive the four finding chips, and it is not a
// finding the auditor picks from them — it has its own button and panel (see _notApplicableButton / _buildNotApplicable).
String _findingLabel(String ft) => ft == notApplicableFinding ? 'N/A' : (_findingLabels[ft] ?? ft);
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

// No Flag badge widget exists yet anywhere in the app (checked
// lib/widgets/) — a plain colored label for the Major/Minor Flag (see
// nc_model.dart#flagOf) without building out a whole new widget for one
// label. Takes the already-normalised Flag, so a legacy "Observation" NC
// shows as Minor in Minor's colour.
Color _flagColor(String flag) => flag == 'Major' ? AppColors.red : AppColors.amber;

class CheckpointCard extends StatefulWidget {
  final ParameterNode node;
  final String serial;
  final bool readOnly;
  final double maxScore;
  final SaveCheckpoint onSave;
  final UploadCheckpointPhotos onUploadPhotos;
  final DeleteEvidencePhoto? onDeletePhoto;
  // "Not applicable" / "Make applicable again" (see the typedef). Null = the card offers neither.
  final SetCheckpointNotApplicable? onSetNotApplicable;
  // Who an NC raised off this checkpoint can be against: the audited
  // location's people, already minus the acting auditor (see
  // audit_detail_screen.dart#_ncAuditeeOptions) — this card never offers, or
  // defaults to, the auditor themselves.
  final List<EmployeeOption> employees;
  // Reports every change of [CheckpointSyncState] to the parent screen so
  // it can guard back-navigation and show one overall save indicator —
  // this card is otherwise a fully isolated State with no way for its
  // parent to know it's busy. Also called (with clean/saving/failed) after
  // the card has been removed from the tree, for a save it flushed on the
  // way out.
  final ValueChanged<CheckpointSyncState>? onSyncStateChanged;
  // Asked when the card is removed from the tree with unsaved edits: true
  // (the default) flushes them first — a location-tab switch must not eat
  // an edit — false drops them, which is what the screen's "Exit without
  // saving" choice means.
  final bool Function()? shouldFlushOnDispose;
  // Where a remark typed before any finding is picked is kept on this
  // device (see the class doc). Null turns the draft off.
  final String? draftKey;
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
    this.onSetNotApplicable,
    this.employees = const [],
    this.onSyncStateChanged,
    this.shouldFlushOnDispose,
    this.draftKey,
    this.linkedNc,
    this.currentEmployeeId,
    this.onUpdateNc,
  });

  @override
  State<CheckpointCard> createState() => CheckpointCardState();
}

class CheckpointCardState extends State<CheckpointCard> with WidgetsBindingObserver {
  // How long a pause in typing (the remark) before it autosaves — long
  // enough that a save fires once per pause, not once per keystroke/word,
  // but still short enough that leaving right after typing (the "not saved
  // yet" back-guard in audit_detail_screen.dart#_onBlockedPop always
  // flushes immediately regardless of this delay) is the rare case rather
  // than the norm.
  static const _debounceDelay = Duration(milliseconds: 2500);
  static const _maxAutoRetries = 3;

  String? _findingType;
  String? _auditeeEmployeeId;
  // Due date for a fresh NC — collected in the NC-details popup (see
  // _openNcDetailsPopup) alongside the auditee pick, same shape as the
  // web app's ParameterScoreCard.jsx once it grows the equivalent field.
  DateTime? _targetDate;
  // Flag (`severity` on the wire) for a fresh NC — the same Major/Minor
  // choice the NC-details popup collects; defaults to "Minor" so it's never
  // a second blocking field on top of the auditee pick and due date.
  String _severity = 'Minor';
  final _remarkController = TextEditingController();
  // The OFI score the auditor picked (a whole number 0..max-1), null until
  // they pick one. The only score that is a choice — see [scoreRuleFor].
  int? _ofiScore;
  // Programmatic text changes (defaults, restoring a draft, the NC popup's
  // remark) must not count as the auditor editing.
  bool _suppressEdits = false;
  // Last remark text seen — a controller also notifies on a bare cursor move
  // or selection change, which is not an edit.
  String _seenRemark = '';
  List<String> _existingPhotos = [];
  // Hosted URLs the server confirmed for photos uploaded from THIS card (see
  // _uploadPhotos), kept until the audit data this card is built from lists
  // them itself. The card used to show a confirmed photo only once the audit
  // had been fetched again — and when that fetch failed (a weak mobile
  // connection) the local thumbnail was already gone and the photo, though
  // safely saved, looked like it had vanished.
  final Set<String> _confirmedUrls = {};
  // Picked photos still uploading (or whose last upload attempt failed) —
  // NOT a "staged, not yet saved" queue the way it used to be. A pick
  // fires _uploadPhotos immediately (see _pickPhotos); an entry only
  // leaves this list once the server actually confirms it (which arrives
  // via didUpdateWidget's node.photoUrls resync, dropping it from here in
  // the same setState — see _uploadPhotos below).
  final List<File> _newPhotos = [];
  // Picked photos whose last failure a retry cannot fix (see UploadPhotosResult.permanentPaths): shown with the
  // reason, never re-sent on their own — not by the timer, not when the app goes to the background — only by the
  // person tapping Retry.
  final Set<String> _permanentPaths = {};
  final Set<String> _deletingPhotoUrls = {};

  // ── Not Applicable ────────────────────────────────────────────────────
  // The checkpoint is marked Not Applicable: left out of the score, nothing recorded on it. Set the moment the person
  // confirms (and put back if the server refuses), so the card never shows the old finding while the request is on its way.
  bool _notApplicable = false;
  // A mark / make-applicable request is in flight (see _markNotApplicable).
  bool _naBusy = false;
  // The "Mark as not applicable?" question is open: a second tap on the button while it is (or is about to be) must not open a
  // second one.
  bool _naAsking = false;
  // Photos whose upload was still waiting in the queue when the mark was made: skipped, not sent. If the server then
  // refuses the mark they go up after all (see _markNotApplicable).
  final Set<String> _skippedForNa = {};

  // ── Save machinery ────────────────────────────────────────────────────
  // Edits the server hasn't confirmed yet (finding / score / remark / NC
  // details). Stays true across failures so a retry resends everything.
  bool _dirty = false;
  bool _saving = false;
  bool _justSaved = false;
  // Bumped on every edit — a save snapshots it and only clears _dirty if
  // nothing changed underneath it while it was in flight; otherwise the
  // loop in _drain simply goes around again with the newer values.
  int _editVersion = 0;
  String? _error;
  int _retryAttempt = 0;
  Timer? _debounce;
  Timer? _retryTimer;
  // Tail of the per-checkpoint request queue — see _exclusive.
  Future<void> _tail = Future<void>.value();
  bool _disposed = false;
  CheckpointSyncState _lastReported = CheckpointSyncState.clean;
  ValueChanged<CheckpointSyncState>? _onSync;

  // Photo upload — its own in-flight/error state (see _uploadPhotos), but it
  // shares the request queue above with the score save so the two can never
  // hit the server for this checkpoint at the same time. Per-PATH, not one
  // flag for the whole card — a pick while an earlier one is still
  // uploading queues behind it (still serialized through _exclusive/_tail
  // below, never actually concurrent), but only that specific thumbnail
  // shows busy, and the Add button is never disabled.
  final Set<String> _uploadingPaths = {};
  bool get _uploadingPhotos => _uploadingPaths.isNotEmpty;
  String? _photoUploadError;
  int _photoRetryAttempt = 0;
  Timer? _photoRetryTimer;
  UploadPhase? _uploadPhase;
  double? _uploadFraction;

  // An update to an ALREADY-raised NC is in flight (see _saveNcEdit) —
  // all that's left on the card of what used to be a whole inline edit
  // form's worth of state (open flag, auditee, severity, date, error),
  // now that the form itself is just the NC-details sheet in edit mode.
  // Deliberately outside the autosave machinery below: this is a
  // deliberate correction the auditor opts into and confirms once in the
  // sheet, not something debounced typing ever fires.
  bool _ncEditSaving = false;

  @override
  void initState() {
    super.initState();
    _notApplicable = widget.node.isNotApplicable;
    // Not Applicable is not one of the findings the card edits: it carries no finding, score or remark of its own.
    _findingType = _notApplicable ? null : widget.node.findingType;
    _onSync = widget.onSyncStateChanged;
    _remarkController.text = _notApplicable ? '' : widget.node.remark ?? '';
    // Only an OFI carries a picked score; one stored outside 0..max-1 matches no
    // button, so it reads as "not picked" and is asked for again if it is edited.
    _ofiScore = _ofiScoreOf(widget.node, widget.maxScore);
    _existingPhotos = List.of(widget.node.photoUrls);
    _seenRemark = _remarkController.text;
    _remarkController.addListener(_onFieldEdited);
    if (!widget.readOnly) {
      WidgetsBinding.instance.addObserver(this);
      if (widget.node.findingType == null) _restoreDraft();
      // A photo taken with the camera (not gallery multi-select) only
      // finishes uploading after the auditor is back from that external
      // Camera activity — and launching it a second time for another shot
      // is exactly when Android is most likely to background or kill this
      // app to free memory. _newPhotos is in-memory only, so that wipes
      // out any photo whose upload hadn't confirmed yet. Recover it here
      // the same way _restoreDraft recovers an unsaved remark.
      // A Not Applicable checkpoint takes no photos: whatever this device still holds for it is forgotten, not resent.
      if (_notApplicable) {
        _forgetDrafts();
      } else {
        _restorePendingEdit();
        _restorePendingPhotos();
        _recoverLostPick();
      }
    }
    debugPrint('[photo-trace] $_logTag initState — existingPhotos=${_existingPhotos.length} readOnly=${widget.readOnly}');
  }

  // Short, greppable id for correlating this card's own log lines — TEMPORARY
  // instrumentation for tracking down the photo-disappears report; safe to
  // strip once that's confirmed fixed on a device.
  String get _logTag => 'node=${widget.node.id.substring(0, widget.node.id.length.clamp(0, 6))}';

  @override
  void didUpdateWidget(covariant CheckpointCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _onSync = widget.onSyncStateChanged;
    // Marked (or made applicable again) from somewhere else — another phone, the web: follow the server. Not while this
    // card's own request is in flight: that one sets the state itself when it lands.
    if (!widget.readOnly &&
        !_naBusy &&
        widget.node.isNotApplicable != oldWidget.node.isNotApplicable &&
        widget.node.isNotApplicable != _notApplicable) {
      _debounce?.cancel();
      _retryTimer?.cancel();
      _photoRetryTimer?.cancel();
      setState(() {
        if (widget.node.isNotApplicable) _clearLocalWork();
        _notApplicable = widget.node.isNotApplicable;
      });
      if (_notApplicable) _forgetDrafts();
      _report();
    }
    // Every save (scoreCheckpoint) refetches the whole audit tree and the
    // parent screen passes a fresh `node` down here under the SAME
    // ValueKey(node.id) — so Flutter reuses this State instead of running
    // initState() again, and _existingPhotos (set once, in initState)
    // never picked up the newly-uploaded photo's Cloudinary URL. Only
    // _existingPhotos is resynced here (never findingType/remark/score,
    // which stay debounced-editable) since it's pure server truth —
    // _newPhotos (locally-picked, not-yet-uploaded files) is untouched
    // either way.
    if (widget.node.photoUrls != oldWidget.node.photoUrls) {
      debugPrint('[photo-trace] $_logTag didUpdateWidget photoUrls ${oldWidget.node.photoUrls.length} -> ${widget.node.photoUrls.length}; newPhotos still pending=${_newPhotos.length}');
      // A confirmed photo the data has not caught up with yet stays on show:
      // only one the data lists itself stops being tracked here.
      _confirmedUrls.removeWhere(widget.node.photoUrls.contains);
      setState(() => _existingPhotos = [...widget.node.photoUrls, ..._confirmedUrls]);
    }
  }

  @override
  void dispose() {
    // If newPhotos/uploadingPaths is non-empty here, this card's State is
    // being torn down (list rebuild, tab switch, navigation) while a photo
    // was still pending — the persisted draft (_photoDraftKey) is what's
    // supposed to carry it through to the next initState/_restorePendingPhotos.
    debugPrint('[photo-trace] $_logTag dispose — newPhotos=${_newPhotos.length} uploadingPaths=${_uploadingPaths.length}');
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _retryTimer?.cancel();
    _photoRetryTimer?.cancel();
    var report = CheckpointSyncState.clean;
    if (_dirty && !widget.readOnly && !_notApplicable && (widget.shouldFlushOnDispose?.call() ?? true)) {
      if (_canSave) {
        // Removed from the tree with an edit still on its way (a location-tab
        // switch, a collapsed group): send the latest values anyway, a few
        // tries, queued behind whatever is already in flight.
        report = CheckpointSyncState.saving;
        unawaited(_persistPendingEdit()); // kept on the device until the detached save below is confirmed
        _detachedSave(_payload(), widget.onSave, _onSync, widget.draftKey);
      } else if (_findingType == null) {
        _persistDraft(widget.draftKey, _remarkController.text);
      }
    }
    // Reported straight away, ahead of the queued save above finishing —
    // the parent must never keep counting a card that no longer exists as
    // "busy" forever (a detached save reports again when it's done).
    if (report != _lastReported) _onSync?.call(report);
    _remarkController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Anything but resumed: the OS may kill a backgrounded app at any time,
    // so push out whatever is still waiting on the debounce right now.
    if (state != AppLifecycleState.resumed) flush();
  }

  // ── Derived state ─────────────────────────────────────────────────────

  ScoreRule get _rule => scoreRuleFor(_findingType, widget.maxScore);

  // A fresh NC (not yet raised) always needs its own popup filled in — an
  // explicit "who is this against" pick (never defaulted to the auditor;
  // mirrors ParameterScoreCard.jsx's identical condition) + a due date —
  // before it can save.
  bool get _needsNcDetails => _findingType == 'NC' && widget.node.ncId == null;

  // What's still needed before this checkpoint can save at all — mirrors
  // audit.controller.js#scoreParameter's own validation for a mobile
  // caller (findingType always; a picked score for an OFI — Strong,
  // Compliance and NC need none; an auditee pick + due date for a fresh NC)
  // so the hint text here never promises a save the server would actually
  // reject. Remark is deliberately NOT required here — the server only makes
  // it mandatory for web callers.
  String? get _missingFieldHint {
    if (_findingType == null) return null; // nothing picked yet — no nag before they've started
    if (_findingType == 'OFI' && _ofiScore == null) return 'Pick a score to save';
    if (_needsNcDetails && _auditeeEmployeeId == null) {
      return widget.employees.isEmpty ? "No one else is tagged to this audit's location." : 'Pick who this NC is against';
    }
    if (_needsNcDetails && _targetDate == null) return 'Set a due date for this NC';
    return null;
  }

  bool get _isComplete => _findingType != null && _missingFieldHint == null;

  // A finding is picked (and it is not Not Applicable) but there is no remark yet: Final Submit will want one.
  bool get _remarkRequiredHint => _findingType != null && !_notApplicable && _remarkController.text.trim().isEmpty;

  // Whether a save can actually go out right now: either a real finding is
  // complete, or nothing's picked yet but there's a remark to save on its
  // own (mirrors _uploadPhotos, which already saves independent of the
  // finding). Does NOT count as "complete" for Submit purposes — _isComplete
  // above still requires a real finding.
  // Never while the checkpoint is Not Applicable: nothing is recorded on it, and the server refuses a remark for it.
  bool get _canSave => !_notApplicable && (_isComplete || (_findingType == null && _remarkController.text.trim().isNotEmpty));

  CheckpointSyncState get _syncState {
    if (widget.readOnly) return CheckpointSyncState.clean;
    if (_error != null || _photoUploadError != null) return CheckpointSyncState.failed;
    if (_saving || _uploadingPhotos || _naBusy) return CheckpointSyncState.saving;
    if (_dirty) {
      if (_canSave) return CheckpointSyncState.saving;
      if (_findingType == null) return CheckpointSyncState.clean; // nothing typed yet to send
      return CheckpointSyncState.incomplete;
    }
    return CheckpointSyncState.clean;
  }

  void _report() {
    final s = _syncState;
    if (s == _lastReported) return;
    _lastReported = s;
    _onSync?.call(s);
  }

  // setState only while mounted — the save loop can outlive the widget.
  void _update(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    } else {
      fn();
    }
  }

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

  // ── Request queue ─────────────────────────────────────────────────────

  // Runs [task] only after everything queued before it has finished —
  // score saves and photo uploads for this checkpoint never overlap.
  Future<T> _exclusive<T>(Future<T> Function() task) {
    final run = _tail.then((_) => task());
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  // What the next save carries: the fields as they are RIGHT NOW (read when
  // the save actually runs, not when it was scheduled).
  ({String? findingType, double? score, String remark, String? auditee, DateTime? date, String? severity}) _payload() {
    if (_findingType == null) {
      // Nothing picked yet — just the remark, same shape a photo's own
      // independent save already uses.
      return (findingType: null, score: null, remark: _remarkController.text.trim(), auditee: null, date: null, severity: null);
    }
    // Strong Compliance and Compliance send NO score — the server stores the
    // full max itself and ignores anything sent. NC sends 0 (the server
    // rejects an NC save without a numeric score), OFI the pick (a save never
    // goes out without one — see _missingFieldHint).
    final double? score = switch (_findingType) {
      'NC' => 0,
      'OFI' => _ofiScore?.toDouble(),
      _ => null,
    };
    return (
      findingType: _findingType,
      score: score,
      remark: _remarkController.text.trim(),
      auditee: _needsNcDetails ? _auditeeEmployeeId : null,
      date: _needsNcDetails ? _targetDate : null,
      severity: _needsNcDetails ? _severity : null,
    );
  }

  // Sends everything pending, one request at a time, until what's on screen
  // is what the server has.
  Future<void> _drain() => _exclusive(() async {
        var rounds = 0;
        while (_dirty && !_disposed && _canSave && rounds++ < 20) {
          final version = _editVersion;
          final p = _payload();
          final save = widget.onSave;
          final nodeBefore = widget.node;
          _update(() {
            _saving = true;
            _error = null;
          });
          _report();
          final error = await save(
            findingType: p.findingType,
            score: p.score,
            remark: p.remark,
            auditeeEmployeeId: p.auditee,
            targetDate: p.date,
            severity: p.severity,
          );
          // Removed mid-request: dispose already queued a final save with the
          // latest values, nothing more to do here.
          if (_disposed) return;
          if (error != null) {
            // A remark-only save that failed (offline, most likely) keeps a
            // local copy too — the automatic retry below will still resend
            // it to the server; this is just a safety net against losing it
            // if the app is killed before that succeeds.
            if (p.findingType == null) {
              _persistDraft(widget.draftKey, p.remark);
            } else {
              unawaited(_persistPendingEdit()); // a scored checkpoint keeps its own on-device copy too
            }
            _update(() {
              _saving = false;
              _error = error;
            });
            _report();
            _scheduleRetry();
            return;
          }
          _retryAttempt = 0;
          final unchanged = _editVersion == version;
          _update(() {
            _saving = false;
            if (unchanged) {
              _dirty = false;
              _justSaved = true;
            }
          });
          _report();
          // Now on the server — the on-device draft (if any) is obsolete.
          if (unchanged) {
            _persistDraft(widget.draftKey, '');
            unawaited(PendingCheckpointStore.clear(widget.draftKey));
            _resyncAfterSave(nodeBefore);
          }
        }
      });

  // The save refetches the audit and the parent hands this card the fresh
  // node one frame later — so, once that has landed, show what the server
  // actually stored (it may have clamped/derived the score), never what was
  // typed. Skipped when no new node arrived (the refetch failed: the old one
  // is not the server's answer) or when the auditor has already typed on.
  void _resyncAfterSave(ParameterNode nodeBefore) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dirty || _saving || identical(widget.node, nodeBefore)) return;
      final n = widget.node;
      if (n.findingType == null || n.isNotApplicable) return;
      final ofi = _ofiScoreOf(n, widget.maxScore);
      if (n.findingType == _findingType && ofi == _ofiScore) return;
      setState(() {
        _findingType = n.findingType;
        _ofiScore = ofi;
      });
    });
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    if (_disposed || _retryAttempt >= _maxAutoRetries) return;
    final delay = Duration(seconds: 3 << _retryAttempt);
    _retryAttempt++;
    _retryTimer = Timer(delay, () {
      if (!_disposed) _drain();
    });
    // The failed row switches from "Retry" to "retrying…".
    if (mounted) setState(() {});
  }

  // The last chance for an edit made on a card that's already gone.
  void _detachedSave(
    ({String? findingType, double? score, String remark, String? auditee, DateTime? date, String? severity}) p,
    SaveCheckpoint save,
    ValueChanged<CheckpointSyncState>? report,
    String? draftKey,
  ) {
    _exclusive(() async {
      String? error;
      for (var attempt = 0; attempt < 3; attempt++) {
        error = await save(
          findingType: p.findingType,
          score: p.score,
          remark: p.remark,
          auditeeEmployeeId: p.auditee,
          targetDate: p.date,
          severity: p.severity,
        );
        if (error == null) break;
        await Future<void>.delayed(Duration(seconds: 3 * (attempt + 1)));
      }
      // Confirmed: the on-device copy is obsolete. Not confirmed after the tries: it stays, and is sent the next time
      // this checkpoint or audit is opened.
      if (error == null) await PendingCheckpointStore.clear(draftKey);
      // Clean either way: the card is gone, so nothing will ever retry — a
      // lingering "failed" would keep the screen's save chip and back-guard
      // stuck for good.
      report?.call(CheckpointSyncState.clean);
    });
  }

  /// Sends everything pending right now (skipping the debounce and any retry
  /// wait) and resolves once this checkpoint's queue is empty. False if the
  /// last attempt failed — the caller (Submit / Final Submit) must not carry
  /// on as if it were saved.
  Future<bool> flush() async {
    if (widget.readOnly || _disposed) return true;
    _debounce?.cancel();
    _retryTimer?.cancel();
    _photoRetryTimer?.cancel();
    // Only the true "nothing picked yet" gap needs the on-device fallback — a
    // finding that IS picked but still incomplete (e.g. OFI with no score
    // typed) has nothing useful to persist here; _canSave would also be
    // false for it, but writing a draft in that case serves no purpose.
    if (_findingType == null && _dirty) await _writeDraft();
    _retryAttempt = 0;
    final resendable = _newPhotos.where((f) => !_permanentPaths.contains(f.path)).toList();
    if (_photoUploadError != null && resendable.isNotEmpty && !_uploadingPhotos) {
      _photoRetryAttempt = 0;
      unawaited(_uploadPhotos(resendable));
    }
    await _drain();
    await _tail;
    // "Incomplete" (finding picked, score / NC details still missing) is not
    // saved either — Submit must not go on as if it were.
    final s = _syncState;
    return s != CheckpointSyncState.failed && s != CheckpointSyncState.incomplete;
  }

  // Marks an edit and (re)starts the save: immediately for a discrete action
  // (finding pick, NC details), after a short pause for typing.
  void _scheduleSave({bool immediate = false}) {
    _debounce?.cancel();
    _retryTimer?.cancel();
    _retryAttempt = 0;
    // The moment an edit is made it also goes on the device, so it is not lost if the app is closed or killed before
    // the server confirms it (no signal, a slow connection...). Removed again once the server has it.
    unawaited(_persistPendingEdit());
    if (immediate) {
      _drain();
    } else {
      _debounce = Timer(_debounceDelay, _onDebounceFired);
    }
  }

  void _onDebounceFired() {
    if (_disposed) return;
    // A remark with no finding yet now saves to the server on its own (see
    // _canSave's own doc) — _drain handles that case too, so it is always the
    // right call here; the on-device draft (_writeDraft) is written only as
    // an offline fallback, from _drain itself once a save actually fails.
    _drain();
    _report();
  }

  // Every remark keystroke goes through here.
  void _onFieldEdited() {
    final changed = _remarkController.text != _seenRemark;
    _seenRemark = _remarkController.text;
    if (!changed || _suppressEdits || _disposed || _notApplicable) return;
    setState(() {
      _justSaved = false;
      _dirty = true;
      _error = null;
      _editVersion++;
    });
    _scheduleSave();
    _report();
  }

  // ── On-device draft (remark typed before any finding) ────────────────

  Future<void> _restoreDraft() async {
    final key = widget.draftKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(key);
      if (saved == null || saved.isEmpty || !mounted) return;
      // The auditor already started typing while this loaded — theirs wins.
      if (_remarkController.text.isNotEmpty || _findingType != null) return;
      _suppressEdits = true;
      _remarkController.text = saved;
      _suppressEdits = false;
      setState(() {});
    } catch (_) {
      // No storage available — just no draft.
    }
  }

  Future<void> _writeDraft() => _persistDraft(widget.draftKey, _remarkController.text);

  // ── On-device copy of an unconfirmed edit (finding / score / remark / NC details) ──
  // See core/storage/pending_checkpoint_store.dart for the why. A remark typed before any finding keeps using the
  // draft above; once a finding is picked, the whole edit is kept here.

  Future<void> _persistPendingEdit() async {
    if (widget.draftKey == null || widget.readOnly || _notApplicable || _findingType == null) return;
    final p = _payload();
    await PendingCheckpointStore.write(
      widget.draftKey,
      PendingCheckpoint(
        findingType: p.findingType,
        score: p.score,
        remark: p.remark,
        auditeeEmployeeId: p.auditee,
        targetDate: p.date,
        severity: p.severity,
        savedAt: DateTime.now(),
      ),
    );
  }

  // The checkpoint was opened again after an edit that never reached the server (the app was closed or killed, or
  // there was no signal): put the person's edit back on the card and send it.
  Future<void> _restorePendingEdit() async {
    final pending = await PendingCheckpointStore.read(widget.draftKey);
    if (pending == null) return;
    if (!mounted || _disposed || widget.readOnly || _notApplicable) return;
    if (pending.findingType == null || pending.isStale()) {
      await PendingCheckpointStore.clear(widget.draftKey);
      return;
    }
    // Already editing since this opened: what they are doing now wins.
    if (_dirty) return;
    // What the server holds is already this: nothing to resend. (A fresh NC always carries details the server's
    // checkpoint data does not show back, so it is always resent.)
    final sameAsServer = pending.findingType == _findingType &&
        (pending.findingType != 'OFI' || pending.score?.round() == _ofiScore) &&
        pending.remark.trim() == _remarkController.text.trim() &&
        !(pending.findingType == 'NC' && widget.node.ncId == null);
    if (sameAsServer) {
      await PendingCheckpointStore.clear(widget.draftKey);
      return;
    }
    _suppressEdits = true;
    _remarkController.text = pending.remark;
    _suppressEdits = false;
    setState(() {
      _findingType = pending.findingType;
      _ofiScore = pending.findingType == 'OFI' ? pending.score?.round() : null;
      _auditeeEmployeeId = pending.auditeeEmployeeId;
      _targetDate = pending.targetDate;
      _severity = pending.severity ?? 'Minor';
      _seenRemark = pending.remark;
      _justSaved = false;
      _error = null;
      _dirty = true;
      _editVersion++;
    });
    _report();
    _scheduleSave(immediate: true);
  }

  // ── On-device draft (photo picked but not yet confirmed uploaded) ────
  // Same safety net as the remark draft above, for _newPhotos — see the
  // initState comment for why this specifically matters for a camera shot.
  String? get _photoDraftKey => widget.draftKey == null ? null : '${widget.draftKey}:photos';

  Future<void> _persistPendingPhotos() async {
    final key = _photoDraftKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_newPhotos.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, jsonEncode(_newPhotos.map((f) => f.path).toList()));
      }
    } catch (_) {
      // Best effort — same as _persistDraft.
    }
  }

  // Drops [gone]'s paths from the persisted draft — used once their upload
  // is actually confirmed, so a later restore never re-sends something
  // already attached server-side. Storage I/O only, safe to call after
  // this card's own State is disposed.
  Future<void> _removePersistedPhotos(List<File> gone) async {
    final key = _photoDraftKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(key);
      if (saved == null || saved.isEmpty) return;
      final gonePaths = gone.map((f) => f.path).toSet();
      final remaining = (jsonDecode(saved) as List).cast<String>().where((p) => !gonePaths.contains(p)).toList();
      debugPrint('[photo-trace] $_logTag _removePersistedPhotos dropping ${gonePaths.length} confirmed, ${remaining.length} still pending in draft');
      if (remaining.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, jsonEncode(remaining));
      }
    } catch (_) {
      // Best effort.
    }
  }

  // A photo Android took away from the app while the camera was open (the app
  // was killed for memory) — handed back by image_picker only to whoever asks,
  // and only THIS checkpoint if it is the one that was waiting (see
  // recoverLostEvidencePhotos). Goes through the same path as a fresh pick.
  Future<void> _recoverLostPick() async {
    final key = widget.draftKey;
    if (key == null) return;
    final lost = await recoverLostEvidencePhotos(key);
    debugPrint('[photo-trace] $_logTag _recoverLostPick found ${lost.length} file(s), mounted=$mounted');
    if (lost.isEmpty || !mounted) return;
    setState(() => _newPhotos.addAll(lost));
    await _persistPendingPhotos();
    _photoRetryAttempt = 0;
    await _uploadPhotos(lost);
  }

  Future<void> _restorePendingPhotos() async {
    final key = _photoDraftKey;
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(key);
      if (saved == null || saved.isEmpty || !mounted) return;
      final paths = (jsonDecode(saved) as List).cast<String>();
      // The file itself lives in the OS's own cache dir, not in Dart
      // memory — it survives the process death that wiped _newPhotos, but
      // a very old draft's file may have since been cleared by the OS.
      final files = paths.map(File.new).where((f) => f.existsSync()).toList();
      debugPrint('[photo-trace] $_logTag _restorePendingPhotos found ${paths.length} in draft, ${files.length} still exist on disk');
      if (files.isEmpty) {
        await prefs.remove(key);
        return;
      }
      setState(() => _newPhotos.addAll(files));
      _photoRetryAttempt = 0;
      await _uploadPhotos(files);
    } catch (_) {
      // Malformed/unreadable draft — nothing to recover.
    }
  }

  Future<void> _persistDraft(String? key, String text) async {
    if (key == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (text.trim().isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, text);
      }
    } catch (_) {
      // Best effort — the draft is a safety net, never a failure.
    }
  }

  // ── Not Applicable ────────────────────────────────────────────────────

  String get _ncName => (widget.linkedNc?.ncId ?? '').isNotEmpty ? widget.linkedNc!.ncId : 'The NC';

  // What marking would clear, in words ("finding, score, remark and 2 photos") — '' when nothing is recorded here.
  String get _recordedWords {
    final photos = _existingPhotos.length + _newPhotos.length;
    final parts = [
      if (_findingType != null) ...['finding', 'score'],
      if (_remarkController.text.trim().isNotEmpty) 'remark',
      if (photos > 0) '$photos ${photos == 1 ? 'photo' : 'photos'}',
    ];
    if (parts.length < 2) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }

  // The tap on "Not applicable": ALWAYS asked first, never marked at once — it leaves the checkpoint out of the score. The
  // question says what is cleared (and the photos deleted) when something is recorded, and that an NC raised on it is
  // withdrawn (the server only does that while nobody has responded to it, and says so itself otherwise). One question at a
  // time: a second tap meanwhile does nothing.
  Future<void> _onNotApplicableTap() async {
    if (_naAsking || _naBusy || _notApplicable || widget.onSetNotApplicable == null) return;
    final recorded = _recordedWords;
    final text = [
      'It will be left out of the score.',
      if (recorded.isNotEmpty) 'The $recorded recorded on it will be cleared.',
      if (widget.node.ncId != null) '$_ncName raised on it will be withdrawn, unless the auditee has already responded to it.',
    ].join(' ');
    _naAsking = true;
    final bool? confirmed;
    try {
      confirmed = await showDialog<bool>(context: context, builder: (_) => _NotApplicableDialog(text: text));
    } finally {
      _naAsking = false;
    }
    if (confirmed != true || !mounted) return;
    await _markNotApplicable();
  }

  // Sends the mark through the request queue, behind anything already on its way. Everything waiting to be sent from here
  // (typing, a retry, a queued photo) is held back — the server is about to clear the checkpoint, and refuses a remark or a
  // photo for it. What is typed / picked is only given up once the server has said yes: a refusal (an NC that already has a
  // response, a closed audit) puts the checkpoint back as it was, what was waiting goes out after all, and the server's own
  // sentence is shown.
  Future<void> _markNotApplicable() async {
    final set = widget.onSetNotApplicable;
    if (set == null || _naBusy) return;
    _debounce?.cancel();
    _retryTimer?.cancel();
    _photoRetryTimer?.cancel();
    setState(() {
      _notApplicable = true;
      _naBusy = true;
      _justSaved = false;
    });
    _report();
    final error = await _exclusive(() => set(true));
    if (_disposed) return;
    if (error != null) {
      final resend = _newPhotos.where((f) => _skippedForNa.contains(f.path)).toList();
      _skippedForNa.clear();
      _update(() {
        _notApplicable = false;
        _naBusy = false;
      });
      _report();
      if (_dirty) _scheduleSave(immediate: true);
      if (resend.isNotEmpty) {
        _photoRetryAttempt = 0;
        unawaited(_uploadPhotos(resend));
      }
      if (mounted) showErrorSnackBar(context, error);
      return;
    }
    _update(() {
      _clearLocalWork();
      _naBusy = false;
    });
    _forgetDrafts();
    _report();
  }

  // "Make applicable again": the checkpoint comes back BLANK — the server cleared it when it was marked — and has to be
  // filled in afresh. Nothing to confirm: nothing is lost.
  Future<void> _makeApplicableAgain() async {
    final set = widget.onSetNotApplicable;
    if (set == null || _naBusy) return;
    setState(() => _naBusy = true);
    _report();
    final error = await _exclusive(() => set(false));
    if (_disposed) return;
    if (error != null) {
      _update(() => _naBusy = false);
      _report();
      if (mounted) showErrorSnackBar(context, error);
      return;
    }
    _update(() {
      _clearLocalWork();
      _notApplicable = false;
      _naBusy = false;
    });
    _report();
  }

  // Back to a blank checkpoint, in memory: finding, OFI pick, remark, NC details, photos (and the queue of picked ones).
  void _clearLocalWork() {
    _suppressEdits = true;
    _remarkController.clear();
    _suppressEdits = false;
    _seenRemark = '';
    _findingType = null;
    _ofiScore = null;
    _auditeeEmployeeId = null;
    _targetDate = null;
    _severity = 'Minor';
    _existingPhotos = [];
    _confirmedUrls.clear();
    _newPhotos.clear();
    _permanentPaths.clear();
    _skippedForNa.clear();
    _deletingPhotoUrls.clear();
    _dirty = false;
    _error = null;
    _retryAttempt = 0;
    _photoUploadError = null;
    _photoRetryAttempt = 0;
    _justSaved = false;
    _editVersion++;
  }

  // The same, on this device: the remark draft and the picked-photo draft would otherwise come back on the next open.
  void _forgetDrafts() {
    unawaited(_persistDraft(widget.draftKey, ''));
    unawaited(PendingCheckpointStore.clear(widget.draftKey));
    unawaited(_persistPendingPhotos());
  }

  // ── NC edit / details ─────────────────────────────────────────────────

  // Opens the NC-details sheet in EDIT mode (nc_details_sheet.dart),
  // seeded with what this NC currently carries, and pushes whatever comes
  // back straight at updateNc.
  Future<void> _openNcEditSheet() async {
    final nc = widget.linkedNc;
    if (nc == null || widget.onUpdateNc == null) {
      return;
    }
    final result = await showNcDetailsSheet(
      context,
      mode: NcSheetMode.edit,
      employees: widget.employees,
      // A populated auditee always has an id; the empty-string fallback in
      // NcPersonRef.fromJson (models/nc_model.dart) is what a missing or
      // unpopulated ref decodes to, and handing that over would just match
      // no dropdown item — null leaves the picker genuinely blank and its
      // own validator to insist on a real pick.
      initialAuditeeId: nc.auditee.id.isNotEmpty ? nc.auditee.id : null,
      // See showNcDetailsSheet's own doc on this param — lets the sheet
      // keep showing (and re-submitting) the NC's real auditee even when
      // that person has fallen out of `widget.employees` since the NC was
      // raised (a per-location audit whose active zone tab has since
      // changed — audit_detail_screen.dart#_employeesForNc narrows that
      // list to the CURRENTLY active location only).
      initialAuditeeName: nc.auditee.name,
      initialTargetDate: nc.targetDate,
      // Passed through untouched and handed straight back (see
      // NcDetailsResult.remark) — edit mode doesn't render the Remark
      // field at all, since nc.controller.js#updateNC only ever accepts
      // auditee/severity/targetDate and the checkpoint's own remark field
      // right behind this sheet stays where that gets changed.
      initialRemark: _remarkController.text,
      // A legacy NC can still carry "Observation", which that sheet's
      // dropdown has no item for (a DropdownButtonFormField whose value
      // matches none of its items throws) — flagOf reads it as 'Minor',
      // the same way the server and web do.
      initialSeverity: flagOf(nc.severity),
    );
    if (result == null || !mounted) {
      return;
    }
    await _saveNcEdit(result);
  }

  // The sheet has already popped by the time this runs, so a failure has
  // nowhere inline left to land — it goes to the app's snackbar helper
  // (core/utils/snackbar.dart) instead of the old in-form error line. The
  // panel keeps showing the NC's pre-edit values either way: new ones only
  // ever reach this card once updateNc's own fetchAuditDetail refetch
  // pushes a fresh linkedNc down from the parent screen.
  Future<void> _saveNcEdit(NcDetailsResult details) async {
    setState(() => _ncEditSaving = true);
    final error = await widget.onUpdateNc!(
      auditeeEmployeeId: details.auditeeEmployeeId,
      severity: details.severity,
      targetDate: details.targetDate,
    );
    if (!mounted) {
      return;
    }
    setState(() => _ncEditSaving = false);
    if (error != null) {
      showErrorSnackBar(context, error);
    }
  }

  // What a freshly picked finding does to the OFI pick: only an OFI has one, and it starts blank — the auditor picks the
  // actual score themselves rather than it being silently pre-filled — so any other finding drops a leftover pick.
  void _applyScoreDefaults(String ft) {
    if (ft != 'OFI') _ofiScore = null;
  }

  void _selectFinding(String ft) {
    setState(() {
      _findingType = ft;
      _applyScoreDefaults(ft);
      _justSaved = false;
      _dirty = true;
      _error = null;
      _editVersion++;
    });
    _report();
    // A fresh NC needs its own popup (auditee pick + due date) filled in
    // before it can be saved — open it right away instead of leaving the
    // auditor to hunt for a now-visible-but-easy-to-miss inline control.
    if (ft == 'NC' && widget.node.ncId == null) {
      _openNcDetailsPopup();
    } else {
      _scheduleSave(immediate: true);
    }
  }

  // The auditor taps one of the OFI score buttons (or the dropdown): saved at once, like a finding pick — a tap is a discrete
  // action, nothing to wait out the way typing is. A quick second tap just queues behind the first (every save reads the
  // pick at the moment it runs, see _payload/_drain).
  void _pickOfiScore(int value) {
    if (_notApplicable || _findingType != 'OFI' || _ofiScore == value) return;
    setState(() {
      _ofiScore = value;
      _justSaved = false;
      _dirty = true;
      _error = null;
      _editVersion++;
    });
    _report();
    _scheduleSave(immediate: true);
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
      initialAuditeeId: _auditeeEmployeeId,
      initialTargetDate: _targetDate,
      initialRemark: _remarkController.text,
      initialSeverity: _severity,
    );
    if (result == null || !mounted) return;
    _suppressEdits = true;
    _remarkController.text = result.remark;
    _suppressEdits = false;
    setState(() {
      _auditeeEmployeeId = result.auditeeEmployeeId;
      _targetDate = result.targetDate;
      _severity = result.severity;
      _justSaved = false;
      _dirty = true;
      _error = null;
      _editVersion++;
    });
    _report();
    _scheduleSave(immediate: true);
  }

  // An already-uploaded photo is removed immediately (not deferred to the
  // checkpoint's own autosave) — it calls straight through to Cloudinary
  // deletion server-side, so leaving the screen right after tapping
  // remove never leaves the file orphaned in storage.
  Future<void> _removeExistingPhoto(String url) async {
    if (widget.onDeletePhoto == null) {
      setState(() {
        _existingPhotos.remove(url);
        _confirmedUrls.remove(url);
      });
      return;
    }
    setState(() => _deletingPhotoUrls.add(url));
    // Behind any save/upload already queued for this checkpoint.
    final delete = widget.onDeletePhoto!;
    final error = await _exclusive(() => delete(url));
    if (!mounted) return;
    setState(() {
      _deletingPhotoUrls.remove(url);
      if (error == null) {
        _existingPhotos.remove(url);
        _confirmedUrls.remove(url);
      }
    });
    if (error != null) showErrorSnackBar(context, error);
  }

  Future<void> _pickPhotos() async {
    final picked = await pickEvidencePhotos(context, recoveryKey: widget.draftKey);
    debugPrint('[photo-trace] $_logTag _pickPhotos returned ${picked.length} file(s), mounted=$mounted');
    if (picked.isEmpty || !mounted) return;
    setState(() => _newPhotos.addAll(picked));
    // On disk before the upload even starts — if the OS kills this app
    // while it's still showing the camera for the NEXT shot, this photo
    // survives to be picked back up by _restorePendingPhotos.
    await _persistPendingPhotos();
    _photoRetryAttempt = 0;
    await _uploadPhotos(picked);
  }

  // Uploads immediately — independent of the finding/remark save, and of
  // whether this checkpoint is even complete yet (see the class doc
  // comment), but queued behind any request already running for it.
  // `photos` is exactly the set this attempt is sending, so a Retry after a
  // failure can pass the same still-pending `_newPhotos` back in without
  // resending anything that separately succeeded in the meantime — and a
  // batch that PARTIALLY fails (see UploadPhotosResult) only re-sends
  // whichever of `photos` actually failed, never the ones already confirmed.
  Future<void> _uploadPhotos(List<File> photos) {
    if (!mounted) {
      debugPrint('[photo-trace] $_logTag _uploadPhotos called while UNMOUNTED for ${photos.length} file(s) — dropped, never even queued');
      return Future.value();
    }
    debugPrint('[photo-trace] $_logTag _uploadPhotos queuing ${photos.length} file(s): ${photos.map((f) => f.path.split('/').last).join(', ')}');
    _photoRetryTimer?.cancel();
    setState(() {
      _uploadingPaths.addAll(photos.map((f) => f.path));
      _photoUploadError = null;
    });
    _report();
    final upload = widget.onUploadPhotos;
    return _exclusive(() async {
      // Marked Not Applicable since this was queued: the checkpoint takes no photos now. Kept aside — if the server
      // refuses the mark they are sent after all (see _markNotApplicable); once it accepts, they are dropped with the rest.
      if (_notApplicable) {
        _skippedForNa.addAll(photos.map((f) => f.path));
        _update(() => _uploadingPaths.removeAll(photos.map((f) => f.path)));
        _report();
        return;
      }
      debugPrint('[photo-trace] $_logTag _uploadPhotos ACTUALLY SENDING ${photos.length} file(s) now (queue reached them)');
      final result = await upload(
        photos: photos,
        onProgress: (phase, fraction) {
          if (!mounted) return;
          setState(() {
            _uploadPhase = phase;
            _uploadFraction = fraction;
          });
        },
      );
      final failed = photos.where((f) => result.failedPaths.contains(f.path)).toList();
      final succeeded = photos.where((f) => !result.failedPaths.contains(f.path)).toList();
      debugPrint('[photo-trace] $_logTag _uploadPhotos result: ${succeeded.length} succeeded, ${failed.length} failed (error=${result.error}), disposed=$_disposed');
      // Independent of _disposed below — the persisted draft is plain
      // storage I/O, not widget state, and must drop each confirmed photo
      // even if this card is gone by the time its upload finishes (e.g.
      // the auditor already left this checkpoint), or the next restore
      // would re-upload it as a duplicate.
      if (succeeded.isNotEmpty) await _removePersistedPhotos(succeeded);
      if (_disposed) return;
      _update(() {
        _uploadingPaths.removeAll(photos.map((f) => f.path));
        _uploadPhase = null;
        _uploadFraction = null;
        // Marked Not Applicable while this was on its way: the server's answer is no news to show.
        _photoUploadError = _notApplicable ? null : result.error;
        // On success the server already attached these to photoUrls — each
        // confirmed photo is shown from the URL the server answered with
        // RIGHT HERE (and tracked in _confirmedUrls), not only once the
        // refetched audit reaches didUpdateWidget: that refetch can fail on
        // a weak connection, and a thumbnail dropped here with nothing put
        // in its place looked exactly like a vanished photo. When the data
        // does arrive, didUpdateWidget's node.photoUrls resync lists the
        // same URL, which drops it from _confirmedUrls — never shown twice.
        // Left in _newPhotos on failure so Retry has exactly what to resend
        // — but only the ones that actually failed; a partially-successful
        // batch's confirmed photos drop out here too.
        for (final f in succeeded) {
          final url = result.uploadedUrls[f.path];
          if (url != null && !_existingPhotos.contains(url)) {
            _existingPhotos.add(url);
            _confirmedUrls.add(url);
          }
        }
        succeeded.forEach(_newPhotos.remove);
        for (final f in succeeded) {
          _permanentPaths.remove(f.path);
        }
        for (final f in failed) {
          if (result.permanentPaths.contains(f.path)) {
            _permanentPaths.add(f.path);
          } else {
            _permanentPaths.remove(f.path);
          }
        }
      });
      _report();
      // Only a failure that could go differently next time is tried again by itself (a dropped connection, a server
      // hiccup) — a refused file or a job the server gave up on would just fail the same way, again and again.
      final retryable = failed.where((f) => !result.permanentPaths.contains(f.path)).toList();
      if (_notApplicable) return;
      if (retryable.isNotEmpty && _photoRetryAttempt < 2) {
        final delay = Duration(seconds: 4 << _photoRetryAttempt);
        _photoRetryAttempt++;
        _photoRetryTimer = Timer(delay, () {
          if (!_disposed && retryable.every(_newPhotos.contains) && !_uploadingPhotos) _uploadPhotos(retryable);
        });
      } else if (failed.isEmpty) {
        _photoRetryAttempt = 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Read-only cards are tinted by their finding — same green/blue/amber/
    // red-at-a-glance treatment as the web app's ParameterScoreCard.jsx,
    // instead of every finding looking identical until you read the pill.
    final tone = widget.readOnly && widget.node.findingType != null
        ? _findingColor(widget.node.findingType!)
        // An interactive Not Applicable card is muted the same way, so it reads as set aside at a glance down a checklist.
        : (_notApplicable ? AppColors.slate : null);
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
                Expanded(child: BoldText(widget.node.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                if (widget.readOnly && widget.node.findingType != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: _findingColor(widget.node.findingType!).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
                    child: Text(_findingLabel(widget.node.findingType!),
                        style: TextStyle(color: AppColors.readable(context, _findingColor(widget.node.findingType!)), fontSize: 11, fontWeight: FontWeight.w700)),
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
    // Not Applicable: nothing was recorded on it — it says so, calmly, and keeps showing the NC it may still carry.
    if (widget.node.isNotApplicable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.do_not_disturb_on_outlined, size: 16, color: AppColors.readable(context, AppColors.slate)),
            const SizedBox(width: 6),
            Expanded(child: Text('Not applicable — left out of the score.', style: TextStyle(color: scheme.outline, fontSize: 12.5))),
          ]),
          if (widget.linkedNc != null) ...[
            const SizedBox(height: 8),
            _linkedNcBlock(scheme, widget.linkedNc!),
          ],
        ],
      );
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
  // Shares its layout with the two interactive panels below (see
  // _ncPanelShell) so an NC reads the same whether you're looking at a
  // finished audit or still scoring one — only the tint differs.
  Widget _linkedNcBlock(ColorScheme scheme, NcModel nc) {
    return _ncPanelShell(
      // Neutral rather than the NC red the interactive panels use: a
      // read-only card that carries an NC finding is ALREADY tinted red
      // end to end (see build()'s `tone`), so a red panel inside it would
      // dissolve into its own background. This one has to read as lighter
      // than its card, not redder.
      background: scheme.surface.withValues(alpha: 0.6),
      border: scheme.outlineVariant.withValues(alpha: 0.6),
      header: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
          NcTimelinessBadge(startDate: nc.startDate, targetDate: nc.targetDate, completionDate: nc.completionDate),
        ],
      ),
      facts: _ncFacts(
        scheme,
        auditee: nc.auditee.name,
        targetDate: nc.targetDate,
        severity: nc.severity,
        closed: nc.status == 'Closed',
      ),
    );
  }

  // ── The shared NC panel ─────────────────────────────────────────────
  // One tinted block, a badge/action header, then the facts on their own
  // labelled lines. Both interactive summaries below used to be a single
  // Row that jammed the auditee's name, the due date AND the flag into
  // one Expanded Text, with a badge on one side of it and a button on the
  // other. On a 360dp phone that Text is left roughly 150dp once the
  // card's padding and the panel's own are taken out — so the name
  // ellipsised away to almost nothing and the due date and flag, the two
  // facts an auditor actually acts on, were routinely clipped out of
  // existence entirely. That is the "all the things are collapsed" this
  // rework is answering.
  Widget _ncPanelShell({
    required Widget header,
    required List<Widget> facts,
    required Color background,
    required Color border,
    VoidCallback? onTap,
  }) {
    final panel = Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [header, ...facts],
      ),
    );
    if (onTap == null) {
      return panel;
    }
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(10), child: panel);
  }

  // The three lines every NC panel shows, in the same order everywhere so
  // the eye can go straight to the one it wants without re-reading the
  // labels each time.
  List<Widget> _ncFacts(
    ColorScheme scheme, {
    required String auditee,
    required DateTime? targetDate,
    required String severity,
    required bool closed,
  }) {
    final overdue = _isDueOverdue(targetDate, closed: closed);
    // `severity` is the stored value; what's shown is always its Flag, so a
    // legacy "Observation" (or missing) NC reads as Minor here too.
    final flag = flagOf(severity);
    return [
      _ncFactRow(scheme, Icons.person_outline, 'Against', auditee),
      _ncFactRow(
        scheme,
        Icons.event_outlined,
        'Due',
        Formatters.date(targetDate),
        // An overdue date is the single most actionable thing on this
        // panel and used to render in exactly the same muted grey as
        // everything else around it. scheme.error, not a hardcoded red, so
        // it stays legible against the dark theme's own surfaces too.
        valueColor: overdue ? scheme.error : null,
      ),
      _ncFactRow(scheme, Icons.flag_outlined, 'Flag', flag, valueColor: AppColors.readable(context, _flagColor(flag))),
    ];
  }

  Widget _ncFactRow(ColorScheme scheme, IconData icon, String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: scheme.outline),
          const SizedBox(width: 6),
          // A fixed-width label column rather than a flex split: "Against"
          // is the longest label there is, so anything proportional would
          // hand the value column less room than it needs on exactly the
          // narrow screens this rework exists for, and the three values
          // would no longer line up under each other.
          SizedBox(
            width: 52,
            child: Text(label, style: TextStyle(fontSize: 12, color: scheme.outline)),
          ),
          Expanded(
            child: Text(
              value,
              // Two lines before it gives up — a genuine "Firstname
              // Middlename Lastname" wraps onto a second line instead of
              // being ellipsised away, which is the entire point here.
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: valueColor ?? scheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }

  // Date-only comparison, deliberately: targetDate arrives as a midnight
  // UTC instant (server/models/NonConformance.js), so comparing instants
  // would flag an NC that's due TODAY as overdue from the moment the local
  // day began. A Closed NC is never overdue — it's already done, whenever
  // that happened; NcTimelinessBadge is what reports whether it landed
  // late.
  bool _isDueOverdue(DateTime? due, {required bool closed}) {
    if (due == null || closed) {
      return false;
    }
    final local = due.toLocal();
    final now = DateTime.now();
    return DateTime(local.year, local.month, local.day).isBefore(DateTime(now.year, now.month, now.day));
  }

  // The edit affordance itself. A full, labelled button with the DEFAULT
  // tap target (MaterialTapTargetSize.padded → 48dp) — what it replaces
  // set minimumSize: Size.zero and tapTargetSize: shrinkWrap over 6x2
  // padding, i.e. a target barely 20dp tall, well under the 44dp minimum,
  // on the single control the auditor was complaining they were reaching
  // for. Swapped for a spinner while an update is in flight so a second
  // tap can't fire updateNc twice over the same NC.
  Widget _ncEditAction(ColorScheme scheme, VoidCallback onTap) {
    if (_ncEditSaving) {
      // Pinned to the button's own 48dp tap-target height so the panel
      // doesn't visibly shrink and snap back around the swap — the whole
      // block sits mid-scroll in a list of checkpoints, and a height jump
      // there moves everything below it under the auditor's thumb.
      return SizedBox(
        height: 48,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(height: 13, width: 13, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline)),
              const SizedBox(width: 6),
              Text('Saving…', style: TextStyle(color: scheme.outline, fontSize: 12.5)),
            ],
          ),
        ),
      );
    }
    return TextButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.edit_outlined, size: 16),
      label: const Text('Edit'),
    );
  }

  Widget _buildEditable(ColorScheme scheme) {
    if (_notApplicable) return _buildNotApplicable(scheme);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          // The four findings, then "Not applicable" in the same flow: on a phone the chips already take two lines and it
          // fits on the second beside NC, so a checklist grows by nothing — and it is styled apart (no outline, a soft grey
          // fill), so it never reads as a fifth finding.
          children: [..._findingLabels.keys.map((ft) {
            final active = _findingType == ft;
            final color = _findingColor(ft);
            // Text/icon in the theme-readable shade (the raw token is ~3:1 on the
            // dark theme); the fill and border keep the exact brand colour.
            final textColor = AppColors.readable(context, color);
            return ChoiceChip(
              label: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_findingIcons[ft], size: 15, color: active ? textColor : scheme.outline),
                const SizedBox(width: 4),
                Text(_findingLabels[ft]!),
              ]),
              selected: active,
              onSelected: (_) => _selectFinding(ft),
              selectedColor: color.withValues(alpha: 0.14),
              labelStyle: TextStyle(color: active ? textColor : scheme.onSurface, fontWeight: FontWeight.w600),
              side: BorderSide(color: active ? color : scheme.outlineVariant),
            );
          }), if (widget.onSetNotApplicable != null) _notApplicableButton()],
        ),
        if (_findingType != null) ...[
          const SizedBox(height: 10),
          _scoreSection(scheme),
        ],
        // Fresh NC — auditee pick + due date are
        // both collected together in one popup (see nc_details_sheet.dart)
        // instead of an inline dropdown, so the due date has somewhere to
        // live too.
        if (_needsNcDetails) ...[
          const SizedBox(height: 10),
          _ncDetailsSummary(scheme) ?? OutlinedButton.icon(
            onPressed: _openNcDetailsPopup,
            icon: const Icon(Icons.assignment_outlined, size: 17),
            label: const Text('Set NC auditee & due date'),
          ),
        ],
        const SizedBox(height: 10),
        TextField(
          controller: _remarkController,
          minLines: 3,
          maxLines: 8,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Add remark or observations...',
            prefixIcon: const Icon(Icons.chat_bubble_outline),
            // The remark is not needed to SAVE a checkpoint, but the audit's Final Submit asks for one on every checkpoint that
            // applies — say so once a finding is picked and the box is still empty (a quiet line, gone as soon as they type).
            helperText: _remarkRequiredHint ? 'Required to submit the audit' : null,
            helperStyle: TextStyle(color: scheme.error),
          ),
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
            // _pickPhotos/_uploadPhotos) — busy (spinner, no remove) for as
            // long as THAT SPECIFIC photo's own upload is in flight
            // (_uploadingPaths, per-path — see its own doc comment), same
            // convention as an already-uploaded photo's own delete-in-
            // flight state above. Picking another photo while this one is
            // still going is fine — queued behind it, never actually
            // concurrent (see _uploadPhotos/_exclusive).
            ..._newPhotos.asMap().entries.map((e) => _removablePhoto(
                  child: GestureDetector(
                    onTap: () => openPhotoViewer(
                      context,
                      images: _newPhotos.map((f) => FileImage(f) as ImageProvider).toList(),
                      initialIndex: e.key,
                    ),
                    child: _thumb(Image.file(e.value, width: 56, height: 56, fit: BoxFit.cover)),
                  ),
                  busy: _uploadingPaths.contains(e.value.path),
                  onRemove: () {
                    debugPrint('[photo-trace] $_logTag USER TAPPED X on ${e.value.path.split('/').last}');
                    setState(() {
                      _newPhotos.remove(e.value);
                      _permanentPaths.remove(e.value.path);
                    });
                    _removePersistedPhotos([e.value]);
                  },
                )),
            // Never disabled — an upload already in flight just means the
            // next pick queues behind it (_exclusive), so the auditor can
            // keep snapping photos back-to-back instead of waiting each one
            // out before the button responds again.
            InkWell(
              onTap: _pickPhotos,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant, style: BorderStyle.solid),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.camera_alt_outlined, color: scheme.outline),
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
                onPressed: () {
                  _photoRetryAttempt = 0;
                  _permanentPaths.clear(); // the person asked
                  _uploadPhotos(List.of(_newPhotos));
                },
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
    // More than one queued (another pick while an earlier one is still
    // going) — say so, since only one is actually transmitting right now
    // (_uploadPhase/_uploadFraction) while the rest wait their turn.
    final queuedSuffix = _uploadingPaths.length > 1 ? ' (${_uploadingPaths.length} photos)' : '';
    final label = switch (_uploadPhase) {
      UploadPhase.uploading => 'Uploading photo ${((_uploadFraction ?? 0) * 100).toStringAsFixed(0)}%…$queuedSuffix',
      UploadPhase.processing => 'Processing photo…$queuedSuffix',
      null => 'Uploading photo…$queuedSuffix',
    };
    return Row(children: [
      SizedBox(height: 13, width: 13, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline)),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: scheme.outline, fontSize: 12.5)),
    ]);
  }

  // The card's one small save indicator, right-aligned under everything:
  // Saving… (spinner), a brief "Saved" confirmation, a failure that is being
  // retried automatically — or, once those retries are used up, the error
  // with a manual Retry — the on-device draft note for a remark typed before
  // any finding, or a muted hint for whatever's still missing before there
  // is anything to send. Wraps instead of clipping at large text sizes.
  Widget _statusRow(ColorScheme scheme) {
    final small = TextStyle(color: scheme.outline, fontSize: 12.5);
    Widget line(Widget icon, String text, {Color? color, FontWeight? weight}) => Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            icon,
            Text(text, style: small.copyWith(color: color, fontWeight: weight)),
          ],
        );
    Widget spinner() => SizedBox(height: 13, width: 13, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline));

    Widget content;
    if (_error != null) {
      final retrying = _retryTimer?.isActive ?? false;
      content = Row(
        children: [
          Expanded(
            child: Text(
              retrying ? 'Couldn\'t save — retrying…' : _error!,
              style: TextStyle(color: scheme.error, fontSize: 12.5),
            ),
          ),
          if (!retrying) ...[
            const SizedBox(width: 8),
            // Default tap target — a save that actually failed is the one
            // thing on this card the auditor MUST be able to hit.
            TextButton.icon(
              onPressed: () {
                _retryAttempt = 0;
                _drain();
              },
              icon: const Icon(Icons.refresh, size: 15),
              label: const Text('Retry'),
            ),
          ],
        ],
      );
    } else if (_syncState == CheckpointSyncState.saving && !_uploadingPhotos) {
      content = line(spinner(), 'Saving…');
    } else if (_justSaved && !_dirty) {
      content = line(const Icon(Icons.check_circle, size: 14, color: AppColors.green), 'Saved',
          color: AppColors.readable(context, AppColors.green), weight: FontWeight.w600);
    } else if (_missingFieldHint != null) {
      content = Text(_missingFieldHint!, textAlign: TextAlign.end, style: small);
    } else {
      return const SizedBox.shrink();
    }
    return Align(alignment: Alignment.centerRight, child: content);
  }

  // The score follows the finding and is never typed: Strong and Compliance are fixed at the full max, NC at 0 (it's the
  // state that raises the NC) — shown, so there is nothing to get wrong — and an OFI is picked from 0..max-1 (see
  // scoreRuleFor / ofiScoreOptions).
  Widget _scoreSection(ColorScheme scheme) {
    final rule = _rule;
    final max = formatScore(widget.maxScore);
    if (!rule.fixed) return _ofiPicker(scheme, max);
    final tone = _findingColor(_findingType!);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 2,
        children: [
          Icon(Icons.lock_outline, size: 15, color: AppColors.readable(context, tone)),
          Text('Score', style: TextStyle(color: scheme.outline, fontSize: 12.5)),
          Text('${formatScore(rule.fixedValue)} / $max',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: AppColors.readable(context, tone))),
          Text(_findingType == 'NC' ? 'fixed for an NC' : 'full marks', style: TextStyle(color: scheme.outline, fontSize: 12)),
        ],
      ),
    );
  }

  // The OFI score: one tappable button per whole number 0..max-1, wrapping onto rows, the picked one filled. Required — nothing
  // saves until one is picked (see _missingFieldHint). Past [ofiButtonsLimit] picks (an older audit on a big scale) a row of
  // buttons would swamp the card, so it is a dropdown there instead.
  Widget _ofiPicker(ColorScheme scheme, String max) {
    final options = ofiScoreOptions(widget.maxScore);
    final tone = _findingColor('OFI');
    final readable = AppColors.readable(context, tone);
    final picked = _ofiScore;
    return Container(
      key: const ValueKey('ofi-picker'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 2,
            children: [
              Icon(Icons.touch_app_outlined, size: 15, color: readable),
              Text('Score', style: TextStyle(color: scheme.outline, fontSize: 12.5)),
              if (picked != null)
                Text('$picked / $max', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: readable))
              else
                Text('Pick 0–${options.last} (out of $max)', style: TextStyle(color: scheme.outline, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          if (options.length <= ofiButtonsLimit)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [for (final v in options) _ofiButton(scheme, v, selected: v == picked, tone: tone)],
            )
          else
            DropdownButtonFormField<int>(
              key: const ValueKey('ofi-dropdown'),
              initialValue: picked,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'Score', helperText: 'Pick 0–${options.last} (out of $max)'),
              items: [for (final v in options) DropdownMenuItem(value: v, child: Text('$v'))],
              onChanged: (v) {
                if (v != null) _pickOfiScore(v);
              },
            ),
        ],
      ),
    );
  }

  // One score button: 48dp square (the comfortable touch size), a plain outlined chip when not picked, the OFI amber fill when it is.
  Widget _ofiButton(ColorScheme scheme, int value, {required bool selected, required Color tone}) {
    final readable = AppColors.readable(context, tone);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Score $value',
      excludeSemantics: true,
      onTap: () => _pickOfiScore(value),
      child: Material(
        key: ValueKey('ofi-$value'),
        color: selected ? tone.withValues(alpha: 0.22) : scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? tone : scheme.outlineVariant, width: selected ? 2 : 1),
        ),
        child: InkWell(
          onTap: () => _pickOfiScore(value),
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Text(
                '$value',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: selected ? readable : scheme.onSurface),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // "Not applicable" — set apart from the four finding chips: a soft grey pill with its own icon, never a colour that reads as a
  // verdict, the same height as a chip with the usual 48dp touch target so a thumb finds it. Goes through _onNotApplicableTap
  // (confirmed first, always).
  Widget _notApplicableButton() {
    return TextButton.icon(
      key: const ValueKey('na-button'),
      onPressed: _naBusy ? null : _onNotApplicableTap,
      icon: const Icon(Icons.do_not_disturb_on_outlined, size: 17),
      label: const Text('Not applicable'),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.readable(context, AppColors.slate),
        backgroundColor: AppColors.slate.withValues(alpha: 0.10),
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.padded,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
  }

  // The checkpoint while it is Not Applicable: a calm panel in place of the chips, score, remark and photos (none of which
  // apply), and the way back.
  Widget _buildNotApplicable(ColorScheme scheme) {
    const tone = AppColors.slate;
    final readable = AppColors.readable(context, tone);
    return Column(
      key: const ValueKey('na-panel'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: tone.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.do_not_disturb_on_outlined, size: 20, color: readable),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Not applicable', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: readable)),
                    const SizedBox(height: 2),
                    Text('Left out of the score. Nothing needs to be filled in here.', style: TextStyle(color: scheme.outline, fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('na-undo'),
              onPressed: _naBusy ? null : _makeApplicableAgain,
              icon: _naBusy
                  ? SizedBox(height: 14, width: 14, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.outline))
                  : const Icon(Icons.undo, size: 18),
              label: Text(_naBusy ? 'Saving…' : 'Make applicable again'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            ),
            Text("You'll fill in the finding again.", style: TextStyle(color: scheme.outline, fontSize: 12.5)),
          ],
        ),
      ],
    );
  }

  // Once the NC-details popup has been filled in, show what was picked
  // (with a way to reopen and change it) instead of the "set details"
  // button — null while anything's still missing, so the button above
  // stays in place until then.
  Widget? _ncDetailsSummary(ColorScheme scheme) {
    if (_auditeeEmployeeId == null) {
      return null;
    }
    if (_targetDate == null) {
      return null;
    }
    final auditeeName = widget.employees.firstWhere(
      (e) => e.id == _auditeeEmployeeId,
      orElse: () => const EmployeeOption(id: '', name: 'Unknown'),
    ).name;
    return _ncPanelShell(
      // The whole panel stays tappable — that's how this summary has
      // always reopened the details popup — AND now carries its own
      // labelled Edit button. The tap target alone was undiscoverable: a
      // tinted block whose only hint was a bare 15px pencil glyph with no
      // label reads as decoration, not as something you can press.
      onTap: _openNcDetailsPopup,
      background: AppColors.red.withValues(alpha: 0.06),
      border: AppColors.red.withValues(alpha: 0.25),
      header: Row(
        children: [
          Icon(Icons.assignment_late_outlined, size: 15, color: AppColors.readable(context, AppColors.red)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'NC details',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: AppColors.readable(context, AppColors.red)),
            ),
          ),
          TextButton.icon(
            onPressed: _openNcDetailsPopup,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit'),
          ),
        ],
      ),
      // The NC itself doesn't exist yet (it's created by the autosave this
      // panel's own details unblock — see _needsNcDetails), so there's no
      // status to badge and nothing is closed: `closed: false` is a
      // statement of fact here, not a default.
      facts: _ncFacts(
        scheme,
        auditee: auditeeName,
        targetDate: _targetDate,
        severity: _severity,
        closed: false,
      ),
    );
  }

  // The already-raised NC's current auditee/due-date/flag, plus an
  // "Edit" affordance when this auditor is allowed to fix a mistake on it
  // (see _canEditNc) — the interactive-card equivalent of _linkedNcBlock's
  // read-only NC panel, shown right here instead since a still-in-
  // progress audit's checkpoint never renders that read-only branch at
  // all. Tapping Edit opens the NC-details sheet in edit mode
  // (_openNcEditSheet); it used to unfold an inline form in place, which
  // is what pushed every checkpoint below this one down the page.
  Widget _linkedNcEditableBlock(ColorScheme scheme, NcModel nc) {
    return _ncPanelShell(
      // Tinted with the NC red — unlike the read-only panel above, an
      // interactive card has no finding tint of its own, so this is what
      // makes the block read as one unit instead of loose text stranded
      // between the photo strip and the status row.
      background: AppColors.red.withValues(alpha: 0.06),
      border: AppColors.red.withValues(alpha: 0.25),
      header: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusBadge(label: nc.status, color: AppColors.forNcStatus(nc.status)),
                NcTimelinessBadge(startDate: nc.startDate, targetDate: nc.targetDate, completionDate: nc.completionDate),
              ],
            ),
          ),
          // _ncEditSaving is checked alongside _canEditNc so the in-flight
          // spinner can't vanish mid-save: the update's own refetch can
          // land a fresh linkedNc (a status that's moved on, say) that
          // makes _canEditNc false while this very save is still settling.
          if (_canEditNc || _ncEditSaving) _ncEditAction(scheme, _openNcEditSheet),
        ],
      ),
      facts: _ncFacts(
        scheme,
        auditee: nc.auditee.name,
        targetDate: nc.targetDate,
        severity: nc.severity,
        closed: nc.status == 'Closed',
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
        // Inside the corner (was -6/-6): a button hanging half outside the
        // Stack's bounds only receives taps on its inner 12x12, and the 8px
        // padding brings the live target to 34x34.
        Positioned(
          top: 0,
          right: 0,
          child: busy
              ? const SizedBox(width: 34, height: 34, child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
              : InkWell(
                  onTap: onRemove,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(color: Colors.black87, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 12, color: Colors.white),
                    ),
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

/// The question asked before a checkpoint is marked Not Applicable — what is lost, in words. Pops true to go ahead, false (or
/// nothing) to leave it as it is.
class _NotApplicableDialog extends StatelessWidget {
  final String text;

  const _NotApplicableDialog({required this.text});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mark as not applicable?'),
      content: Text(text, key: const ValueKey('na-confirm-text')),
      actions: [
        TextButton(
          key: const ValueKey('na-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('na-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Mark not applicable'),
        ),
      ],
    );
  }
}
