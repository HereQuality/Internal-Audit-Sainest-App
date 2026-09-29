import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
///    buttons (Strong / Compliance / OFI / NC), a score that follows the
///    finding (see [scoreRuleFor]), an optional remark, and optional photo
///    evidence.
///  - read-only: just shows whatever was recorded.
///
/// Nothing the auditor does is left to a Save button — every edit saves
/// itself, and the card always knows whether it has anything the server
/// hasn't confirmed yet:
///  - a finding pick / finishing the NC-details popup saves right away;
///    remark and score typing save a short pause after the last keystroke
///    (_scheduleSave); a picked photo uploads immediately on its own.
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
/// `onSave`/`onUploadPhotos` return an error message on failure (null on
/// success) — same shape as AuditsProvider#scoreCheckpoint/
/// uploadCheckpointEvidence so this widget never needs to know about Dio/
/// HTTP directly.
typedef SaveCheckpoint = Future<String?> Function({
  // Null = no finding picked yet — a remark-only save (see _canSave/_payload).
  String? findingType,
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

/// How a finding constrains its score. Strong is fixed at the full max, NC
/// is fixed at 0, Compliance takes 0..max and OFI takes 0..max-1 (an OFI is
/// by definition a partial score). Whole numbers only — same as the web's
/// ParameterScoreCard.jsx, and the server's scoring never uses fractions.
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
    case 'Strong Compliance':
      return ScoreRule.fixed(maxScore);
    case 'NC':
      return const ScoreRule.fixed(0);
    case 'OFI':
      return ScoreRule.range(0, maxScore > 1 ? maxScore - 1 : 0);
    default: // Compliance
      return ScoreRule.range(0, maxScore);
  }
}

/// Whole number without a trailing ".0" (a Dart double prints "10.0").
String formatScore(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

/// Inline error for a typed score, or null when it is acceptable. An empty
/// box is reported too — callers decide whether to show it yet.
String? validateScoreText(String text, ScoreRule rule) {
  if (rule.fixed) return null;
  final t = text.trim();
  if (t.isEmpty) return 'Enter a score';
  final n = int.tryParse(t);
  if (n == null) return 'Whole numbers only';
  if (n < rule.min || n > rule.max) return 'Must be ${formatScore(rule.min)}–${formatScore(rule.max)}';
  return null;
}

const _findingLabels = {
  'Strong Compliance': 'Strong',
  'Compliance': 'Compliance',
  'OFI': 'OFI',
  'NC': 'NC',
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
  static const _debounceDelay = Duration(milliseconds: 900);
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
  final _scoreController = TextEditingController();
  // True once the score box has been typed in / focused — an untouched empty
  // box shows a neutral hint instead of a red "Enter a score".
  bool _scoreTouched = false;
  // Programmatic text changes (defaults, restoring a draft, the NC popup's
  // remark) must not count as the auditor editing.
  bool _suppressEdits = false;
  // Last text seen in each field — a controller also notifies on a bare
  // cursor move or selection change, which is not an edit.
  String _seenRemark = '';
  String _seenScore = '';
  List<String> _existingPhotos = [];
  // Picked photos still uploading (or whose last upload attempt failed) —
  // NOT a "staged, not yet saved" queue the way it used to be. A pick
  // fires _uploadPhotos immediately (see _pickPhotos); an entry only
  // leaves this list once the server actually confirms it (which arrives
  // via didUpdateWidget's node.photoUrls resync, dropping it from here in
  // the same setState — see _uploadPhotos below).
  final List<File> _newPhotos = [];
  final Set<String> _deletingPhotoUrls = {};

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
  // hit the server for this checkpoint at the same time.
  bool _uploadingPhotos = false;
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
    _findingType = widget.node.findingType;
    _onSync = widget.onSyncStateChanged;
    _remarkController.text = widget.node.remark ?? '';
    // Whole numbers only (see ScoreRule) — formatScore, not toString(), so a
    // genuinely-already-scored "3" doesn't show as "3.0". A checkpoint that's
    // never been scored still starts blank — the server defaults score to
    // null, not 0 (server/models/Audit.js#AuditNodeSchema).
    _scoreController.text = widget.node.score != null ? formatScore(widget.node.score!) : '';
    _existingPhotos = List.of(widget.node.photoUrls);
    _seenRemark = _remarkController.text;
    _seenScore = _scoreController.text;
    _remarkController.addListener(_onFieldEdited);
    _scoreController.addListener(_onFieldEdited);
    if (!widget.readOnly) {
      WidgetsBinding.instance.addObserver(this);
      if (widget.node.findingType == null) _restoreDraft();
    }
  }

  @override
  void didUpdateWidget(covariant CheckpointCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _onSync = widget.onSyncStateChanged;
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
      setState(() => _existingPhotos = List.of(widget.node.photoUrls));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _retryTimer?.cancel();
    _photoRetryTimer?.cancel();
    var report = CheckpointSyncState.clean;
    if (_dirty && !widget.readOnly && (widget.shouldFlushOnDispose?.call() ?? true)) {
      if (_canSave) {
        // Removed from the tree with an edit still on its way (a location-tab
        // switch, a collapsed group): send the latest values anyway, a few
        // tries, queued behind whatever is already in flight.
        report = CheckpointSyncState.saving;
        _detachedSave(_payload(), widget.onSave, _onSync);
      } else if (_findingType == null) {
        _persistDraft(widget.draftKey, _remarkController.text);
      }
    }
    // Reported straight away, ahead of the queued save above finishing —
    // the parent must never keep counting a card that no longer exists as
    // "busy" forever (a detached save reports again when it's done).
    if (report != _lastReported) _onSync?.call(report);
    _remarkController.dispose();
    _scoreController.dispose();
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

  String? get _scoreError => validateScoreText(_scoreController.text, _rule);

  // What's still needed before this checkpoint can save at all — mirrors
  // audit.controller.js#scoreParameter's own validation for a mobile
  // caller (findingType always; a numeric in-range score for Compliance/OFI;
  // an auditee pick + due date for a fresh NC) so the hint text here never
  // promises a save the server would actually reject. Remark is
  // deliberately NOT required here — the server only makes it mandatory
  // for web callers.
  String? get _missingFieldHint {
    if (_findingType == null) return null; // nothing picked yet — no nag before they've started
    if (_scoreError != null) return _scoreError == 'Enter a score' ? 'Enter a score to save' : _scoreError;
    if (_needsNcDetails && _auditeeEmployeeId == null) {
      return widget.employees.isEmpty ? "No one else is tagged to this audit's location." : 'Pick who this NC is against';
    }
    if (_needsNcDetails && _targetDate == null) return 'Set a due date for this NC';
    return null;
  }

  bool get _isComplete => _findingType != null && _missingFieldHint == null;

  // Whether a save can actually go out right now: either a real finding is
  // complete, or nothing's picked yet but there's a remark to save on its
  // own (mirrors _uploadPhotos, which already saves independent of the
  // finding). Does NOT count as "complete" for Submit purposes — _isComplete
  // above still requires a real finding.
  bool get _canSave => _isComplete || (_findingType == null && _remarkController.text.trim().isNotEmpty);

  CheckpointSyncState get _syncState {
    if (widget.readOnly) return CheckpointSyncState.clean;
    if (_error != null || _photoUploadError != null) return CheckpointSyncState.failed;
    if (_saving || _uploadingPhotos) return CheckpointSyncState.saving;
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
    final rule = _rule;
    final typed = double.tryParse(_scoreController.text.trim());
    // Strong / NC are fixed by the finding; Compliance / OFI carry what was
    // typed (already validated by _isComplete). NC always sends a score —
    // the server rejects an NC save without one.
    final score = rule.fixed ? rule.fixedValue : (typed ?? rule.max);
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
            if (p.findingType == null) _persistDraft(widget.draftKey, p.remark);
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
      if (n.findingType == null) return;
      final score = n.score != null ? formatScore(n.score!) : '';
      if (n.findingType == _findingType && score == _scoreController.text) return;
      _suppressEdits = true;
      setState(() {
        _findingType = n.findingType;
        _scoreController.text = score;
        _seenScore = score;
      });
      _suppressEdits = false;
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
    if (_photoUploadError != null && _newPhotos.isNotEmpty && !_uploadingPhotos) {
      _photoRetryAttempt = 0;
      unawaited(_uploadPhotos(List.of(_newPhotos)));
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

  // Every remark/score keystroke goes through here.
  void _onFieldEdited() {
    final changed = _remarkController.text != _seenRemark || _scoreController.text != _seenScore;
    _seenRemark = _remarkController.text;
    _seenScore = _scoreController.text;
    if (!changed || _suppressEdits || _disposed) return;
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

  // Score box defaults for a freshly picked finding: Strong/NC are fixed
  // (shown, not typed), Compliance starts at full marks (the usual answer —
  // one tap to save), OFI keeps a valid typed value or starts blank (there's
  // no sensible default for a partial score).
  void _applyScoreDefaults(String ft) {
    final rule = scoreRuleFor(ft, widget.maxScore);
    final current = int.tryParse(_scoreController.text.trim());
    String next;
    if (rule.fixed) {
      next = formatScore(rule.fixedValue);
    } else if (current != null && current >= rule.min && current <= rule.max) {
      next = _scoreController.text.trim();
    } else {
      next = ft == 'Compliance' ? formatScore(rule.max) : '';
    }
    _suppressEdits = true;
    _scoreController.text = next;
    _suppressEdits = false;
    _scoreTouched = false;
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
      setState(() => _existingPhotos.remove(url));
      return;
    }
    setState(() => _deletingPhotoUrls.add(url));
    // Behind any save/upload already queued for this checkpoint.
    final delete = widget.onDeletePhoto!;
    final error = await _exclusive(() => delete(url));
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
    _photoRetryAttempt = 0;
    await _uploadPhotos(picked);
  }

  // Uploads immediately — independent of the finding/remark save, and of
  // whether this checkpoint is even complete yet (see the class doc
  // comment), but queued behind any request already running for it.
  // `photos` is exactly the set this attempt is sending, so a Retry after a
  // failure can pass the same still-pending `_newPhotos` back in without
  // resending anything that separately succeeded in the meantime.
  Future<void> _uploadPhotos(List<File> photos) {
    if (!mounted) return Future.value();
    _photoRetryTimer?.cancel();
    setState(() {
      _uploadingPhotos = true;
      _photoUploadError = null;
    });
    _report();
    final upload = widget.onUploadPhotos;
    return _exclusive(() async {
      final error = await upload(
        photos: photos,
        onProgress: (phase, fraction) {
          if (!mounted) return;
          setState(() {
            _uploadPhase = phase;
            _uploadFraction = fraction;
          });
        },
      );
      if (_disposed) return;
      _update(() {
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
      _report();
      if (error != null && _photoRetryAttempt < 2) {
        final delay = Duration(seconds: 4 << _photoRetryAttempt);
        _photoRetryAttempt++;
        _photoRetryTimer = Timer(delay, () {
          if (!_disposed && _newPhotos.isNotEmpty && !_uploadingPhotos) _uploadPhotos(List.of(_newPhotos));
        });
      } else if (error == null) {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _findingLabels.keys.map((ft) {
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
          }).toList(),
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
                onPressed: () {
                  _photoRetryAttempt = 0;
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
    } else if (_missingFieldHint != null && _scoreError == null) {
      content = Text(_missingFieldHint!, textAlign: TextAlign.end, style: small);
    } else {
      return const SizedBox.shrink();
    }
    return Align(alignment: Alignment.centerRight, child: content);
  }

  // The score follows the finding: Strong is fixed at the full max, NC is
  // fixed at 0 (it's the state that raises the NC), Compliance takes
  // 0..max and OFI 0..max-1 (see scoreRuleFor). A fixed score is shown, not
  // typed, so there's nothing to get wrong; a typed one is validated inline
  // and is simply not sent until it's in range.
  Widget _scoreSection(ColorScheme scheme) {
    final rule = _rule;
    final max = formatScore(widget.maxScore);
    if (rule.fixed) {
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
    final error = _scoreTouched || _scoreController.text.isNotEmpty ? _scoreError : null;
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: 190,
        child: Focus(
          onFocusChange: (focused) {
            if (!focused && !_scoreTouched) setState(() => _scoreTouched = true);
          },
          child: TextField(
            controller: _scoreController,
            keyboardType: TextInputType.number,
            // Whole numbers only — no decimal point, no exponent/sign
            // characters a bare TextInputType.number keyboard can still let
            // through on some IMEs. Range is checked live (errorText) rather
            // than silently rewriting what was typed.
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
            decoration: InputDecoration(
              labelText: 'Score',
              suffixText: '/ $max',
              helperText: 'Allowed ${formatScore(rule.min)}–${formatScore(rule.max)}',
              errorText: error,
              prefixIcon: const Icon(Icons.pin_outlined, size: 20),
            ),
          ),
        ),
      ),
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
