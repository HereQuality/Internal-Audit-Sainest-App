import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/snackbar.dart';
import '../../models/audit_detail_model.dart';
import '../../models/employee_option.dart';
import '../../models/location_option.dart';
import '../../providers/audits_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/dashboard_provider.dart';
import '../../widgets/app_loading.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/max_width_scroll.dart';
import 'audit_header_card.dart';
import 'checkpoint_card.dart';
import 'select_representative_sheet.dart';

/// The scoring workspace for one audit — "my portion", mirrors the web
/// app's AuditReportDetail.jsx. Walks the parameter tree (models/
/// audit_detail_model.dart#ParameterNode) recursively, same leaf-only
/// scoring convention as everywhere else (server/utils/scoring.js): only a
/// node with no children ever carries a finding.
///
/// Two bottom actions, matching the requested mobile flow:
///  - Submit: a soft "I'm done with this pass" confirmation — everything
///    is already saved checkpoint-by-checkpoint as you go (same as the web
///    workspace), so this just checks nothing required is missing yet.
///  - Final Submit: closes the audit out for good (PATCH /audits/:id/
///    complete — same endpoint & rules as the web "Submit Audit" button:
///    every checkpoint scored, every NC closed). Irreversible, so it's
///    behind a confirmation dialog and stays disabled until eligible.
class AuditDetailScreen extends StatefulWidget {
  final String auditId;

  const AuditDetailScreen({super.key, required this.auditId});

  @override
  State<AuditDetailScreen> createState() => _AuditDetailScreenState();
}

class _AuditDetailScreenState extends State<AuditDetailScreen> {
  String? _activeLocationId;
  bool _isFinalSubmitting = false;
  bool _isSubmitting = false;
  bool _settingRepresentative = false;
  // A Lead + Support audit is claimed by whoever starts it first — asked once,
  // on the very first load of this screen (see _load), never again on a
  // pull-to-refresh (promptRepresentative: false) of the SAME visit.
  bool _claimPromptShown = false;
  final Set<String> _removingCheckpointIds = {};
  // One GlobalKey per checkpoint, populated as the tree builds (see
  // _buildTree) — lets Final Submit jump straight to whichever checkpoint
  // is still unscored (see _scrollToFirstIncomplete) instead of just
  // sitting disabled with no way to tell what's actually blocking it.
  final Map<String, GlobalKey<CheckpointCardState>> _checkpointKeys = {};
  GlobalKey<CheckpointCardState> _keyFor(String nodeId) =>
      _checkpointKeys.putIfAbsent(nodeId, () => GlobalKey<CheckpointCardState>());
  // Per-group collapse flags, keyed by that group node's id — lifted up
  // from _GroupHeader (below) so _scrollToFirstIncomplete can force a
  // collapsed ancestor open before it scrolls: a collapsed group's child
  // subtree is fully unmounted, not just hidden, so the checkpoint inside
  // (and its GlobalKey above) wouldn't exist yet otherwise.
  final Map<String, bool> _groupCollapsed = {};
  // What each CheckpointCard below says about its own saved-ness, keyed by
  // node id — the cards are otherwise fully isolated State objects with no
  // shared knowledge of one another. Anything other than "clean" means the
  // auditor has something the server hasn't confirmed yet, which is what
  // gates the PopScope guard in build() below and drives the save
  // indicator in the AppBar.
  final Map<String, CheckpointSyncState> _syncStates = {};
  // Set by "Exit" in the unsaved-changes dialog: cards being torn down by
  // that pop must NOT flush what they were still holding (see
  // CheckpointCard.shouldFlushOnDispose).
  bool _discardOnExit = false;
  // Flips on the first save activity so a screen nobody has edited yet
  // doesn't open with an "All changes saved" chip.
  bool _sawSaveActivity = false;

  bool get _hasUnsaved => _syncStates.values.any((s) => s != CheckpointSyncState.clean);
  bool get _anyFailed => _syncStates.values.any((s) => s == CheckpointSyncState.failed);
  bool get _anySaving => _syncStates.values.any((s) => s == CheckpointSyncState.saving);

  // Instant Audit builder — see _buildInstantAuditBuilder below.
  final _newCheckpointController = TextEditingController();
  bool _addingCheckpoint = false;
  bool _updatingScope = false;

  // Cards report from async callbacks — but also from dispose(), i.e. in the
  // middle of this screen's own build/teardown, where setState would throw.
  void _onCheckpointSyncChanged(String nodeId, CheckpointSyncState state) {
    if (state == CheckpointSyncState.clean) {
      _syncStates.remove(nodeId);
    } else {
      _syncStates[nodeId] = state;
      _sawSaveActivity = true;
    }
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  // Pushes every mounted card's pending edits out now and waits for them.
  // False if any of them still failed — the caller must not go on to Submit
  // as if everything had been saved. (A card that's already gone flushed
  // itself in dispose(); its state stays in _syncStates until that ends.)
  Future<bool> _flushAll() async {
    final states = _checkpointKeys.values.map((k) => k.currentState).whereType<CheckpointCardState>().toList();
    // TEMPORARY — tracking down the photo-disappears report: how many of
    // this screen's checkpoint keys actually resolved to a live State right
    // now vs. going missing (currentState == null, e.g. scrolled out of a
    // lazy list and disposed) at the exact moment a flush was requested.
    debugPrint('[photo-trace] _flushAll: ${_checkpointKeys.length} keys total, ${states.length} resolved to a live card');
    final results = await Future.wait(states.map((c) => c.flush()));
    // Give a detached (already unmounted) card's last save a moment to land.
    for (var i = 0; i < 20 && _syncStates.values.any((s) => s == CheckpointSyncState.saving); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return results.every((ok) => ok) && !_anyFailed;
  }

  Future<bool> _ensureSavedBeforeSubmit() async {
    final ok = await _flushAll();
    if (!ok && mounted) {
      final incomplete = _syncStates.values.any((s) => s == CheckpointSyncState.incomplete);
      showErrorSnackBar(
        context,
        incomplete && !_anyFailed
            ? 'Some checkpoints still need a score or NC details before they can be saved. Complete them, then submit again.'
            : "Some changes couldn't be saved yet. Check your connection and use Retry on the checkpoint, then submit again.",
      );
    }
    return ok;
  }

  Future<void> _onBlockedPop() async {
    if (!_hasUnsaved) {
      // Only a submit in flight is holding the screen.
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Still submitting'),
          content: const Text('This audit is still being submitted. Leaving now may interrupt it.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Wait')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leave anyway')),
          ],
        ),
      );
      if (leave == true && mounted) Navigator.of(context).pop();
      return;
    }
    final exit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cloud_off_outlined),
        title: const Text('Your changes are not saved yet'),
        content: Text(
          _anyFailed
              ? "Some changes couldn't be saved. If you exit now they will be lost."
              : 'If you exit now, anything still waiting to be saved will be lost.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (exit == true) {
      _discardOnExit = true;
      Navigator.of(context).pop();
    } else {
      // Cancel: stay, and make sure saving carries on right now rather than
      // waiting out a debounce or a retry timer.
      _flushAll();
    }
  }

  // Kept from initState so dispose() below can reach the provider without a
  // context lookup — looking a provider up through a deactivated element in
  // dispose() is what Flutter's "Looking up a deactivated widget's ancestor
  // is unsafe" assertion fires on every time this screen is closed.
  late final AuditsProvider _auditsProvider;

  @override
  void initState() {
    super.initState();
    _auditsProvider = context.read<AuditsProvider>();
    // See AuditsProvider#beginActiveAuditReload's own header comment — this
    // screen's very first build must never read a previous audit's
    // leftover activeAudit (a real Navigator.pop()-timing race, not just
    // theoretical) or a false "not found" before _load()'s fetch (deferred
    // to addPostFrameCallback below) has even started.
    _auditsProvider.beginActiveAuditReload();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _auditsProvider.clearActiveAudit();
    _newCheckpointController.dispose();
    super.dispose();
  }

  // [promptRepresentative] is false for a pull-to-refresh: the sheet opens
  // when the screen does (a banner button brings it back), not on every pull.
  Future<void> _load({bool promptRepresentative = true}) async {
    final provider = context.read<AuditsProvider>();
    final myId = context.read<AuthProvider>().user?.id;
    await provider.fetchAuditDetail(widget.auditId);
    if (!mounted) return;
    final audit = provider.activeAudit;
    // Confirm BEFORE anything else: this is a shared (Lead + Support) audit
    // nobody has started yet, and scoring it will claim it for this person —
    // silently, server-side, on the very first checkpoint tap — and remove
    // every other auditor's ability to do it instead. Asking up front means
    // nobody claims one by accident just from opening it to look.
    if (promptRepresentative &&
        !_claimPromptShown &&
        audit != null &&
        audit.ownership.isSharedUnclaimed &&
        audit.ownership.canStart) {
      _claimPromptShown = true;
      final proceed = await _confirmClaim(audit);
      if (!mounted) return;
      if (!proceed) {
        Navigator.of(context).pop();
        return;
      }
    }
    if (audit != null &&
        audit.structureMode == 'per-location' &&
        audit.locationParameters.isNotEmpty) {
      setState(
        () => _activeLocationId ??= audit.locationParameters.first.locationId,
      );
    }
    // Needs the audit's own location ids, so it can only run after
    // fetchAuditDetail above resolves — populates auditeeCandidates with
    // this audit's own zone(s) real team, for both the "select
    // representative auditee" prompt below and the per-checkpoint "raise
    // NC against" picker. Always called (even with an empty list, which
    // clears it) rather than only when locationLabels is non-empty — this
    // provider field is a singleton shared across audit visits, so a
    // fresh Instant Audit with nothing tagged yet must not be left
    // showing a PREVIOUS audit's own zone members here.
    if (audit != null) {
      await provider.fetchLocationEmployees(
        audit.locationLabels.map((l) => l.id).toList(),
        // A department-scoped (CFT) audit has NO locations — without its
        // departments the picker's pool was empty and the step vanished.
        departmentIds: audit.departmentLabels.map((d) => d.id).toList(),
      );
    }
    // Only the Instant Audit builder needs the full location list — no
    // point fetching it for every other audit screen visit.
    if (audit != null && audit.isInstant && _isPrimaryAuditor(audit, myId)) {
      await provider.fetchAllLocations();
    }
    // Prompt for the mandatory "select representative auditee" gate as
    // soon as the screen opens, before the assigned auditor can start
    // scoring an audit that hasn't had one set yet. Runs last,
    // after auditeeCandidates is this audit's own zone(s) pool built
    // above. Dismissing this prompt doesn't skip the requirement — see
    // _needsRepresentative, which keeps the checklist read-only and
    // Submit/Final Submit hidden until a representative is actually set,
    // and _buildBody's banner offers a way back into this same prompt.
    if (promptRepresentative && audit != null && _needsRepresentative(audit, myId)) {
      await _promptForRepresentative(audit);
    }
  }

  Future<void> _promptForRepresentative(
    AuditDetailModel audit, {
    List<String> initiallySelected = const [],
  }) async {
    if (!mounted) return;
    final provider = context.read<AuditsProvider>();
    // The pool is empty when the lookup failed (or never ran): try once more
    // rather than silently doing nothing, and if there really is nobody, say
    // so — the banner button used to just not respond.
    if (provider.auditeeCandidates.isEmpty) {
      await provider.fetchLocationEmployees(
        audit.locationLabels.map((l) => l.id).toList(),
        departmentIds: audit.departmentLabels.map((d) => d.id).toList(),
      );
      if (!mounted) return;
      if (provider.auditeeCandidates.isEmpty) {
        showErrorSnackBar(
          context,
          'No members found for this audit\'s location. Pull to refresh and try again.',
        );
        return;
      }
    }
    final picked = await showSelectRepresentativeSheet(
      context,
      employees: provider.auditeeCandidates,
      initiallySelected: initiallySelected,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _settingRepresentative = true);
    String? error;
    try {
      error = await provider.setAuditRepresentative(audit.id, picked);
    } finally {
      if (mounted) setState(() => _settingRepresentative = false);
    }
    if (!mounted) return;
    if (error != null) {
      showErrorSnackBar(context, error);
      // A save failure (network, server validation) — retry the same
      // picker rather than silently dropping the selection. Backing out
      // of the sheet itself (picked == null, above) is a deliberate skip,
      // not an error, so that path does NOT re-prompt.
      await _promptForRepresentative(audit, initiallySelected: picked);
    }
  }

  Future<void> _addCheckpoint(
    BuildContext context,
    AuditDetailModel audit,
  ) async {
    final name = _newCheckpointController.text.trim();
    if (name.isEmpty || _addingCheckpoint) return;
    final perLocation = audit.structureMode == 'per-location';
    if (perLocation && _activeLocationId == null)
      return; // no location tagged/selected yet
    setState(() => _addingCheckpoint = true);
    final error = await context.read<AuditsProvider>().addInstantCheckpoint(
      audit.id,
      name,
      locationId: perLocation ? _activeLocationId : null,
    );
    if (!context.mounted) return;
    setState(() => _addingCheckpoint = false);
    if (error != null) {
      showErrorSnackBar(context, error);
    } else {
      _newCheckpointController.clear();
    }
  }

  Future<void> _removeCheckpoint(
    BuildContext context,
    AuditDetailModel audit,
    ParameterNode node,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove checkpoint?'),
        content: Text(
          '"${node.name}" will be removed from this audit\'s checklist.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    setState(() => _removingCheckpointIds.add(node.id));
    String? error;
    try {
      error = await context.read<AuditsProvider>().removeInstantCheckpoint(
        audit.id,
        node.id,
        locationId: audit.structureMode == 'per-location'
            ? _activeLocationId
            : null,
      );
    } finally {
      if (mounted) setState(() => _removingCheckpointIds.remove(node.id));
    }
    if (!context.mounted) return;
    if (error != null) showErrorSnackBar(context, error);
  }

  Future<void> _setInstantStructureMode(
    BuildContext context,
    AuditDetailModel audit,
    String mode,
  ) async {
    if (audit.structureMode == mode || _updatingScope) return;
    setState(() => _updatingScope = true);
    final error = await context
        .read<AuditsProvider>()
        .setInstantAuditStructureMode(audit.id, mode);
    if (!context.mounted) return;
    setState(() {
      _updatingScope = false;
      if (mode == 'per-location')
        _activeLocationId ??= audit.locationLabels.isNotEmpty
            ? audit.locationLabels.first.id
            : null;
    });
    if (error != null) showErrorSnackBar(context, error);
  }

  Future<void> _openLocationScopePicker(
    BuildContext context,
    AuditDetailModel audit,
  ) async {
    final provider = context.read<AuditsProvider>();
    final selected = {for (final l in audit.locationLabels) l.id};
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _LocationScopeSheet(
        allLocations: provider.allLocations,
        initiallySelected: selected,
      ),
    );
    if (result == null || !context.mounted) return;
    setState(() => _updatingScope = true);
    final error = await provider.updateInstantAuditScope(
      audit.id,
      result.toList(),
    );
    if (!context.mounted) return;
    // A newly-tagged location's own staff need to actually be in the NC
    // "raise against" picker too — without this, adding a location here
    // mid-setup wouldn't show its people until the whole screen reloaded
    // (see _load's own initial fetchLocationEmployees call, which only
    // ever runs once, on entry). Always called, even with an empty
    // `result` — untagging the last location must clear auditeeCandidates
    // too, not leave it showing the just-removed location's own members.
    await provider.fetchLocationEmployees(result.toList());
    if (!context.mounted) return;
    setState(() => _updatingScope = false);
    if (error != null) showErrorSnackBar(context, error);
  }

  bool _isPrimaryAuditor(AuditDetailModel audit, String? myId) =>
      myId != null && audit.auditorIds.contains(myId);

  // The hard gate this screen enforces: an audit's assigned auditor can't
  // score anything (or Submit/Final Submit) until at least one
  // representative auditee is set — see _buildBody's `interactive` and
  // `_buildActions` below, both of which fold this in. There's nothing to
  // gate once the audit is no longer active for scoring anyway.
  bool _needsRepresentative(AuditDetailModel audit, String? myId) =>
      audit.auditeeIds.isEmpty &&
      _isPrimaryAuditor(audit, myId) &&
      _isActiveForScoring(audit);

  // isDistributed/distributionMode/assignments are legacy — every new
  // audit's only assignment is auditorIds now (audit.controller.js no
  // longer has a separate "distribute" step), so this just checks status
  // + the scheduledDate gate. scheduledInFuture is server-computed
  // (audit.controller.js#isBeforeScheduledDate), same rule the web app's
  // AuditReportDetail.jsx now enforces.
  //
  // An Instant Audit stays "Draft" for its entire live build-and-score
  // life (server forces this on every save), so it gets its own rule
  // mirroring web's dedicated InstantAudit.jsx#notClosed exactly: active
  // unless Completed/Skipped, status otherwise unchecked (scheduledInFuture
  // is already always false for an Instant Audit server-side too).
  bool _isActiveForScoring(AuditDetailModel audit) {
    if (audit.isInstant)
      return audit.status != 'Completed' && audit.status != 'Skipped';
    return !audit.scheduledInFuture &&
        (audit.status == 'Not Started' || audit.status == 'In Progress');
  }

  List<ParameterNode> _activeTree(AuditDetailModel audit) {
    if (audit.structureMode == 'per-location') {
      for (final lp in audit.locationParameters) {
        if (lp.locationId == _activeLocationId) return lp.parameters;
      }
      return const [];
    }
    return audit.parameters;
  }

  // First unscored leaf, depth-first — same helper (and same reasoning) as
  // the web app's AuditReportDetail.jsx#findFirstIncompleteLeaf.
  ParameterNode? _findFirstIncompleteLeaf(List<ParameterNode> nodes) {
    for (final node in nodes) {
      if (node.isLeaf) {
        if (node.findingType == null) return node;
        continue;
      }
      final found = _findFirstIncompleteLeaf(node.children);
      if (found != null) return found;
    }
    return null;
  }

  // Every group node (not the leaf itself) on the path down to [targetId],
  // outermost first — null if [targetId] isn't under [nodes] at all. Used
  // by _scrollToFirstIncomplete to force-expand exactly the groups standing
  // between the target checkpoint and the tree root.
  List<ParameterNode>? _ancestorGroups(
    List<ParameterNode> nodes,
    String targetId,
  ) {
    for (final node in nodes) {
      if (node.isLeaf) {
        if (node.id == targetId) return const [];
        continue;
      }
      final found = _ancestorGroups(node.children, targetId);
      if (found != null) return [node, ...found];
    }
    return null;
  }

  // Final Submit, while something's still unscored, jumps straight to it
  // instead of just sitting disabled — switches location tab first if the
  // blocking checkpoint is on a different one, expands any collapsed
  // ancestor group it's nested under (see _GroupHeader below — a collapsed
  // group unmounts its children entirely, it doesn't just hide them), then
  // scrolls it into view.
  void _scrollToFirstIncomplete(AuditDetailModel audit) {
    ParameterNode? target;
    String? targetLocationId;
    List<ParameterNode> targetTree = audit.parameters;
    if (audit.structureMode == 'per-location') {
      for (final lp in audit.locationParameters) {
        final found = _findFirstIncompleteLeaf(lp.parameters);
        if (found != null) {
          target = found;
          targetLocationId = lp.locationId;
          targetTree = lp.parameters;
          break;
        }
      }
    } else {
      target = _findFirstIncompleteLeaf(audit.parameters);
    }
    if (target == null) {
      showErrorSnackBar(
        context,
        'Every checkpoint is scored — pull to refresh and try again.',
      );
      return;
    }
    final ancestorGroups = _ancestorGroups(targetTree, target.id) ?? const [];
    final switchingLocation =
        targetLocationId != null && targetLocationId != _activeLocationId;

    final key = _keyFor(target.id);
    void scrollToKey() {
      final ctx = key.currentContext;
      if (ctx == null) {
        // Expansion above should have made this checkpoint reachable —
        // if it still isn't, at least name the section to open by hand
        // instead of claiming (via the generic message below) that we
        // found and pointed to it.
        final sectionName = ancestorGroups.isNotEmpty
            ? ancestorGroups.last.name
            : null;
        showErrorSnackBar(
          context,
          sectionName != null
              ? 'Open "$sectionName" to find the checkpoint that still needs scoring.'
              : 'Could not jump to the checkpoint that still needs scoring — pull to refresh and try again.',
        );
        return;
      }
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOut,
        alignment: 0.3,
      );
      showErrorSnackBar(context, 'Score this checkpoint before submitting.');
    }

    if (switchingLocation || ancestorGroups.isNotEmpty) {
      setState(() {
        if (switchingLocation) _activeLocationId = targetLocationId;
        for (final group in ancestorGroups) {
          _groupCollapsed[group.id] = false;
        }
      });
      // Wait for the tab switch/group expansion to actually rebuild the
      // tree before the target checkpoint's context exists to scroll to.
      WidgetsBinding.instance.addPostFrameCallback((_) => scrollToKey());
    } else {
      scrollToKey();
    }
  }

  String _locationLabel(AuditDetailModel audit, String locationId) {
    for (final loc in audit.locationLabels) {
      if (loc.id == locationId) return loc.display;
    }
    return 'Location';
  }

  // The NC "raise against" pool: the audited location's people
  // (AuditsProvider.auditeeCandidates) minus the acting auditor themself —
  // an NC always goes to someone at the audited location, never back to
  // whoever is raising it (same as the web's ncAuditeeOptions in
  // AuditReportDetail.jsx). Every NC-raise picker on this screen is fed from
  // this; the representative picker (_promptForRepresentative) keeps the
  // full, unfiltered list. When it comes back empty the sheets say "No one
  // else is tagged to this audit's location." and block raising.
  List<EmployeeOption> _ncAuditeeOptions(
    List<EmployeeOption> all,
    String? myId,
  ) => myId == null ? all : all.where((e) => e.id != myId).toList();

  // The "raise NC against" pool (already minus the auditor, see
  // _ncAuditeeOptions), narrowed to just the active location's own members
  // for a per-location audit — the checkpoint being scored right now only
  // makes sense to raise against someone actually at that location, not
  // the auditor's whole hierarchy. Falls back to the audit's other tagged
  // locations' people when there's no location to filter by (whole-audit
  // mode) or nobody else there has a locationIds match yet.
  List<EmployeeOption> _employeesForNc(
    AuditDetailModel audit,
    List<EmployeeOption> all,
  ) {
    if (audit.structureMode != 'per-location' || _activeLocationId == null)
      return all;
    final filtered = all
        .where((e) => e.locationIds.contains(_activeLocationId))
        .toList();
    return filtered.isNotEmpty ? filtered : all;
  }

  Future<void> _handleSubmit(AuditDetailModel audit) async {
    final auditsProvider = context.read<AuditsProvider>();
    final dashboardProvider = context.read<DashboardProvider>();
    setState(() => _isSubmitting = true);
    try {
      // Whatever is still typing/uploading must land before the server
      // judges the audit.
      if (!await _ensureSavedBeforeSubmit() || !mounted) return;
      final error = await auditsProvider.mobileSubmitAudit(widget.auditId);
      if (!mounted) return;
      if (error != null) {
        showErrorSnackBar(context, error);
        return;
      }
      // mobileSubmitAudit only refreshes activeAudit above — the My Audits
      // list (kept alive across tab switches, see app_shell.dart's
      // _KeepAlivePage) and the dashboard's stat tiles are separate state
      // that would otherwise still show this audit's pre-submission state
      // until a manual pull-to-refresh, since no socket notification fires
      // for the actor's own action.
      await Future.wait([
        auditsProvider.fetchMyAudits(),
        dashboardProvider.refreshAll(),
      ]);
      if (!mounted) return;
      showSuccessSnackBar(
        context,
        'Progress submitted. You can keep editing here or on the web app.',
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // "Are you sure you want to perform this audit?" — the gate on a Lead +
  // Support audit nobody has started yet (see _load). Yes claims it for this
  // person the moment they score the first checkpoint (server: utils/
  // auditClaim.js#claimForMember) and removes every other auditor's ability
  // to do it instead — irreversible, so it is asked plainly before that
  // happens, not discovered afterwards.
  Future<bool> _confirmClaim(AuditDetailModel audit) async {
    final others = audit.auditorNames.where((n) => n.trim().isNotEmpty).toList();
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Perform this audit?'),
        content: Text(
          others.length > 1
              ? "This audit is shared between ${others.join(', ')}. Starting it now assigns it to you and removes it from the others — if it is later left overdue with nobody having started it, it falls to the Lead auditor instead."
              : 'Starting this audit now assigns it to you. Are you sure you want to perform this audit?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, perform it'),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  Future<void> _handleFinalSubmit(AuditDetailModel audit) async {
    // First alert: an optional closing remark — same
    // finalAuditorRemark field the web app's Instant Audit flow already
    // collects (audit.controller.js#completeAudit), just missing here
    // until now.
    final remarkController = TextEditingController();
    final proceeded = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Final Submit?'),
        // AlertDialog sizes its content to whatever's left of the screen
        // after title/actions/insets — on a short phone (or with a larger
        // system font size bumping the label/hint taller) that's just
        // barely less than this Column needed, overflowing "BOTTOM
        // OVERFLOWED BY 1.7 PIXELS" by a hair. Scrollable content instead
        // of a hard-clipped fixed Column fixes it regardless of screen
        // size or text scale, rather than chasing an exact pixel budget.
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Once submitted, this audit is closed and you will not be able to edit it again.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: remarkController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Final remark (optional)',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, Final Submit'),
          ),
        ],
      ),
    );
    final finalRemark = remarkController.text.trim();
    // Not straight away: the dialog's exit animation is still drawing the
    // TextField that owns this controller once showDialog has returned.
    Future<void>.delayed(
      const Duration(milliseconds: 500),
      remarkController.dispose,
    );
    if (proceeded != true) return;
    if (!mounted) return;

    // Second alert, per spec — an explicit "you cannot edit after this"
    // acknowledgement, separate from the first "are you sure".
    final acknowledged = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This cannot be undone'),
        content: const Text(
          'You will not be able to make any further changes to this audit after this. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (acknowledged != true) return;
    if (!mounted) return;

    setState(() => _isFinalSubmitting = true);
    final auditsProvider = context.read<AuditsProvider>();
    final dashboardProvider = context.read<DashboardProvider>();
    if (!await _ensureSavedBeforeSubmit()) {
      if (mounted) setState(() => _isFinalSubmitting = false);
      return;
    }
    if (!mounted) return;
    final error = await auditsProvider.completeAudit(
      widget.auditId,
      finalAuditorRemark: finalRemark,
    );
    if (!mounted) return;
    setState(() => _isFinalSubmitting = false);
    if (error != null) {
      showErrorSnackBar(context, error);
      return;
    }
    // Same reasoning as _handleSubmit above — completeAudit only refreshes
    // activeAudit, but this just moved the audit to "Completed", which the
    // My Audits list and the dashboard's Assigned/In Progress/Completed
    // tiles all need to reflect immediately, not after a reload.
    await Future.wait([
      auditsProvider.fetchMyAudits(),
      dashboardProvider.refreshAll(),
    ]);
    if (!mounted) return;
    showSuccessSnackBar(context, 'Audit closed.');
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AuditsProvider>();
    final audit = provider.activeAudit;
    final myId = context.watch<AuthProvider>().user?.id;

    return PopScope(
      canPop: !_hasUnsaved && !_isFinalSubmitting && !_isSubmitting,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _onBlockedPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(audit?.title ?? 'Audit'),
          actions: [
            if (audit != null) _buildSaveIndicator(context),
          ],
        ),
        body: provider.isLoadingDetail && audit == null
            ? const AppLoading()
            : provider.detailError != null && audit == null
            ? ErrorState(message: provider.detailError!, onRetry: _load)
            : audit == null
            ? const EmptyState(
                icon: Icons.assignment_outlined,
                title: 'Audit not found',
              )
            : _buildBody(
                context,
                audit,
                myId,
                _ncAuditeeOptions(provider.auditeeCandidates, myId),
              ),
      ),
    );
  }

  // One small, unobtrusive chip in the AppBar: Saving… / Saved / Failed –
  // retrying. Hidden until something has actually been edited.
  Widget _buildSaveIndicator(BuildContext context) {
    if (!_sawSaveActivity) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final IconData? icon;
    final String label;
    final Color color;
    if (_anyFailed) {
      icon = Icons.sync_problem_outlined;
      label = 'Failed – retrying';
      color = scheme.error;
    } else if (_anySaving) {
      icon = null;
      label = 'Saving…';
      color = scheme.outline;
    } else if (_hasUnsaved) {
      icon = Icons.edit_note_outlined;
      label = 'Not saved yet';
      color = AppColors.readable(context, AppColors.amber);
    } else {
      icon = Icons.check_circle_outline;
      label = 'Saved';
      color = AppColors.readable(context, AppColors.green);
    }
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Container(
            key: ValueKey(label),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon != null
                    ? Icon(icon, size: 14, color: color)
                    : SizedBox(height: 12, width: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color)),
                const SizedBox(width: 6),
                Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AuditDetailModel audit,
    String? myId,
    List<EmployeeOption> employees,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final isPrimary = _isPrimaryAuditor(audit, myId);
    final activeForScoring = _isActiveForScoring(audit);
    final needsRepresentative = _needsRepresentative(audit, myId);
    final interactive = isPrimary && activeForScoring && !needsRepresentative;
    final openNcCount = audit.openNcCount;
    final tree = _activeTree(audit);

    return RefreshIndicator(
      onRefresh: () => _load(promptRepresentative: false),
      // MaxWidthScroll wraps just this checkpoint-tree ListView — the
      // screen's other ListViews (the location-tab strip at ~1109, a
      // picker sheet's own list at ~1725) are short, single-purpose
      // scrollers, not "the main content", so they're left as is.
      child: MaxWidthScroll(
        child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          AuditHeaderCard(audit: audit),
          // Only shown when there's an actual scope description to read —
          // a "No scope description provided." placeholder line read as
          // clutter/debug text on every audit that simply doesn't have one
          // (most of them), so this is silent instead of filling that gap.
          if (audit.scope.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              audit.scope,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
          // The one other reason (besides "not open yet", below) the whole
          // tree renders read-only — without this, an audit that's
          // perfectly active for scoring just looks silently broken to
          // whoever opens it without being one of its auditors (e.g. a
          // planner/manager who can only ever VIEW it, see
          // audit.controller.js#getAuditDetails's own access comment).
          if (!isPrimary && !audit.scheduledInFuture) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.blue.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                "You're not an assigned auditor for this audit — showing read-only.",
                style: TextStyle(
                  color: AppColors.readable(context, AppColors.blue),
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
          if (audit.scheduledInFuture) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                audit.scheduledDate != null
                    ? 'Scheduled for ${audit.scheduledDate!.day}/${audit.scheduledDate!.month}/${audit.scheduledDate!.year} — check back then.'
                    : 'This audit isn\'t open for changes yet — check back later.',
                style: TextStyle(
                  color: AppColors.readable(context, AppColors.amber),
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          // Blocks scoring outright (see `interactive` above and
          // `_buildActions`' matching check) until at least one
          // representative is set — the auto-prompt in _load already fires
          // on entry, but this stays up as a way back into that same sheet
          // for anyone who dismissed it (or is revisiting the audit later).
          if (needsRepresentative) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select a representative auditee before you can start scoring this audit.',
                    style: TextStyle(
                      color: AppColors.readable(context, AppColors.red),
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.red,
                      ),
                      onPressed: _settingRepresentative
                          ? null
                          : () => _promptForRepresentative(audit),
                      child: _settingRepresentative
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Select representative'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (audit.auditeeNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Representative${audit.auditeeNames.length > 1 ? 's' : ''}: ${audit.auditeeNames.join(', ')}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Lets the auditor swap in a different representative
                  // later — setAuditRepresentative (server & provider)
                  // already fully replaces auditeeIds on every call, so
                  // this is just exposing that as a UI action instead of
                  // it only ever being reachable via the once-per-audit
                  // auto-prompt in _load.
                  if (isPrimary && activeForScoring)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        // 48x44 hit area — Size.zero made this a 44x17 target
                        // right next to the scoring controls.
                        minimumSize: const Size(48, 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: _settingRepresentative
                          ? null
                          : () => _promptForRepresentative(
                              audit,
                              initiallySelected: audit.auditeeIds,
                            ),
                      child: _settingRepresentative
                          ? const SizedBox(
                              height: 12.5,
                              width: 12.5,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text(
                              'Change',
                              style: TextStyle(fontSize: 12.5),
                            ),
                    ),
                ],
              ),
            ),
          if (audit.scoreResult.percentage != null)
            Text(
              'Score: ${audit.scoreResult.percentage!.round()}% (${audit.scoreResult.scoredCount}/${audit.scoreResult.leafCount})',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          if (openNcCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '$openNcCount NC${openNcCount == 1 ? '' : 's'} still open',
              style: TextStyle(
                color: AppColors.readable(context, AppColors.red),
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (audit.structureMode == 'per-location' &&
              audit.locationParameters.isNotEmpty)
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: audit.locationParameters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final lp = audit.locationParameters[i];
                  final selected = lp.locationId == _activeLocationId;
                  return ChoiceChip(
                    label: Text(_locationLabel(audit, lp.locationId)),
                    selected: selected,
                    onSelected: (_) =>
                        setState(() => _activeLocationId = lp.locationId),
                  );
                },
              ),
            ),
          if (audit.isInstant && isPrimary)
            _buildInstantAuditBuilder(context, audit),
          const SizedBox(height: 12),
          if (tree.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              // An Instant Audit with an empty tree isn't "nothing applies
              // here" — it means its location and checklist were never
              // actually built. The builder above covers the primary
              // auditor; anyone else (e.g. a planner just viewing) gets
              // this explanation instead of a dead-end-looking generic one.
              child: audit.isInstant && !isPrimary
                  ? const EmptyState(
                      icon: Icons.build_outlined,
                      title: 'This Instant Audit isn\'t set up yet',
                      subtitle:
                          'Its assigned auditor still needs to add a location and checklist.',
                    )
                  : audit.isInstant
                  ? const SizedBox.shrink() // builder above already explains it — no second empty state
                  : const EmptyState(
                      icon: Icons.checklist_outlined,
                      title: 'Nothing to score here',
                    ),
            )
          else
            _buildTree(
              context,
              audit,
              tree,
              interactive,
              myId,
              employees,
              depth: 0,
              serialPrefix: '',
            ),
        ],
        ),
      ),
    );
  }

  // The mobile equivalent of the web app's InstantAudit.jsx, extended with
  // a choice web's own version doesn't offer: one checklist SHARED across
  // every tagged location ("same"), or a SEPARATE checklist per tagged
  // location ("per-location") — same two modes every other audit type in
  // this app already supports (see AuditsProvider.setInstantAuditStructure
  // Mode). Stays visible above the checklist throughout building AND
  // scoring — you can keep adding checkpoints while already scoring the
  // ones you've added.
  Widget _buildInstantAuditBuilder(
    BuildContext context,
    AuditDetailModel audit,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final perLocation = audit.structureMode == 'per-location';
    // In per-location mode, new checkpoints go on whichever location chip
    // is currently active (the SAME chip row _buildBody renders above the
    // checklist for switching between locations) — nothing to add to
    // until at least one location is tagged.
    final canAddCheckpoint =
        !perLocation ||
        (audit.locationLabels.isNotEmpty && _activeLocationId != null);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.build_outlined, size: 16, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                'Instant Audit setup',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: scheme.outline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final loc in audit.locationLabels)
                InputChip(
                  label: Text(loc.display),
                  onDeleted: _updatingScope
                      ? null
                      : () => context
                            .read<AuditsProvider>()
                            .updateInstantAuditScope(
                              audit.id,
                              audit.locationLabels
                                  .where((l) => l.id != loc.id)
                                  .map((l) => l.id)
                                  .toList(),
                            ),
                ),
              ActionChip(
                avatar: _updatingScope
                    ? const SizedBox(
                        height: 14,
                        width: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add, size: 16),
                label: Text(
                  audit.locationLabels.isEmpty ? 'Add location' : 'Change',
                ),
                onPressed: _updatingScope
                    ? null
                    : () => _openLocationScopePicker(context, audit),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // "Same for every location" vs "different per location" — see
          // AuditsProvider.setInstantAuditStructureMode.
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'same',
                label: Text('Same checklist'),
                icon: Icon(Icons.checklist_outlined, size: 16),
              ),
              ButtonSegment(
                value: 'per-location',
                label: Text('Different per location'),
                icon: Icon(Icons.layers_outlined, size: 16),
              ),
            ],
            selected: {
              audit.structureMode == 'per-location' ? 'per-location' : 'same',
            },
            onSelectionChanged: _updatingScope
                ? null
                : (s) => _setInstantStructureMode(context, audit, s.first),
          ),
          if (perLocation && !canAddCheckpoint) ...[
            const SizedBox(height: 8),
            Text(
              'Tag a location above first, then pick it here to add its checklist.',
              style: TextStyle(color: scheme.outline, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newCheckpointController,
                  enabled: canAddCheckpoint,
                  decoration: InputDecoration(
                    hintText: perLocation && _activeLocationId != null
                        ? 'New checkpoint for ${_locationLabel(audit, _activeLocationId!)}'
                        : 'New checkpoint name',
                    isDense: true,
                  ),
                  onSubmitted: canAddCheckpoint
                      ? (_) => _addCheckpoint(context, audit)
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              _addingCheckpoint
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton.filled(
                      icon: const Icon(Icons.add),
                      onPressed: canAddCheckpoint
                          ? () => _addCheckpoint(context, audit)
                          : null,
                    ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTree(
    BuildContext context,
    AuditDetailModel audit,
    List<ParameterNode> nodes,
    bool wholeAuditInteractive,
    String? myId,
    List<EmployeeOption> employees, {
    required int depth,
    required String serialPrefix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < nodes.length; i++) ...[
          Builder(
            builder: (context) {
              final node = nodes[i];
              final serial = serialPrefix.isEmpty
                  ? '${i + 1}'
                  : '$serialPrefix.${i + 1}';
              // No more per-location/per-parameter distribution split — the
              // whole audit is interactive for its assigned auditor, full
              // stop, same as everywhere else in this screen.
              final readOnly = !wholeAuditInteractive;

              if (node.isLeaf) {
                // Isolates each checkpoint's own repaint (photo thumbnails,
                // text fields) from its siblings — without this, every card
                // in the tree repaints together whenever ANY one of them (or
                // an ancestor animation, e.g. the swipe-back transition
                // compositing this screen over the previous route) triggers
                // a frame, which is what made long checklists feel laggy.
                // Fixed when this card is built: its saves (including the one
                // its dispose() sends after a location-tab switch) must go to
                // the location it was typed in, not whichever is active by the
                // time they run.
                final cardLocationId = audit.structureMode == 'per-location'
                    ? _activeLocationId
                    : null;
                final checkpointCard = RepaintBoundary(
                  child: Padding(
                    padding: EdgeInsets.only(left: depth * 12, bottom: 10),
                    child: CheckpointCard(
                      key: _keyFor(node.id),
                      node: node,
                      serial: serial,
                      readOnly: readOnly,
                      onSyncStateChanged: (state) =>
                          _onCheckpointSyncChanged(node.id, state),
                      shouldFlushOnDispose: () => !_discardOnExit,
                      draftKey:
                          'checkpoint_draft:${audit.id}:${audit.structureMode == 'per-location' ? _activeLocationId : ''}:${node.id}',
                      // Mirrors server/utils/scoring.js#leafMax — every leaf
                      // shares the audit's own single maxScore, falling back to
                      // a legacy per-leaf weight (then 1) only for an audit
                      // saved before maxScore existed.
                      maxScore: (audit.maxScore != null && audit.maxScore! > 0)
                          ? audit.maxScore!
                          : (node.weight != null && node.weight! > 0)
                          ? node.weight!
                          : 1,
                      employees: _employeesForNc(audit, employees),
                      linkedNc: node.ncId != null
                          ? audit.ncsById[node.ncId]
                          : null,
                      // No success snackbar here (unlike the old manual-Save
                      // flow) — autosave fires far more often than a
                      // deliberate button tap did, and the inline "Saved"
                      // checkmark in _statusRow already covers per-card
                      // feedback; a toast on every keystroke-pause/finding
                      // pick/photo would just spam the screen.
                      onSave:
                          ({
                            findingType,
                            score,
                            required remark,
                            auditeeEmployeeId,
                            targetDate,
                            severity,
                          }) {
                            return _auditsProvider
                                .scoreCheckpoint(
                                  auditId: widget.auditId,
                                  nodeId: node.id,
                                  findingType: findingType,
                                  score: score,
                                  remark: remark,
                                  locationId:
                                      cardLocationId,
                                  auditeeEmployeeId: auditeeEmployeeId,
                                  targetDate: targetDate,
                                  severity: severity,
                                );
                          },
                      onUploadPhotos: ({required photos, onProgress}) {
                        return _auditsProvider
                            .uploadCheckpointEvidence(
                              auditId: widget.auditId,
                              nodeId: node.id,
                              photos: photos,
                              locationId: cardLocationId,
                              onProgress: onProgress,
                            );
                      },
                      onDeletePhoto: (url) =>
                          _auditsProvider.deleteEvidencePhoto(
                            auditId: widget.auditId,
                            nodeId: node.id,
                            url: url,
                            locationId: cardLocationId,
                          ),
                      currentEmployeeId: myId,
                      onUpdateNc:
                          node.ncId == null
                          ? null
                          : ({auditeeEmployeeId, severity, targetDate}) {
                              return _auditsProvider.updateNc(
                                auditId: widget.auditId,
                                ncId: node.ncId!,
                                auditeeEmployeeId: auditeeEmployeeId,
                                severity: severity,
                                targetDate: targetDate,
                              );
                            },
                    ),
                  ),
                );
                // Instant Audit checkpoints are manually added, so — same as
                // the web app's "Added by mistake?" link — an unscored one
                // can be removed again, not just for a mis-scored finding.
                if (!audit.isInstant ||
                    !wholeAuditInteractive ||
                    node.findingType != null) {
                  return checkpointCard;
                }
                final removingThisCheckpoint = _removingCheckpointIds.contains(
                  node.id,
                );
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    checkpointCard,
                    Positioned(
                      top: -4,
                      right: -4,
                      child: IconButton(
                        icon: removingThisCheckpoint
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppColors.red,
                                ),
                              )
                            : const Icon(Icons.close, size: 16),
                        tooltip: 'Remove checkpoint',
                        style: IconButton.styleFrom(
                          backgroundColor: AppColors.red.withValues(
                            alpha: 0.12,
                          ),
                          minimumSize: const Size(28, 28),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: removingThisCheckpoint
                            ? null
                            : () => _removeCheckpoint(context, audit, node),
                      ),
                    ),
                  ],
                );
              }

              return Padding(
                padding: EdgeInsets.only(left: depth * 12, bottom: 8),
                child: _GroupHeader(
                  title: '$serial. ${node.name}',
                  collapsed: _groupCollapsed[node.id] ?? false,
                  onToggle: () => setState(
                    () => _groupCollapsed[node.id] =
                        !(_groupCollapsed[node.id] ?? false),
                  ),
                  child: _buildTree(
                    context,
                    audit,
                    node.children,
                    wholeAuditInteractive,
                    myId,
                    employees,
                    depth: depth + 1,
                    serialPrefix: serial,
                  ),
                ),
              );
            },
          ),
        ],
        if (depth == 0) ...[
          const SizedBox(height: 20),
          _buildActions(context, audit),
        ],
      ],
    );
  }

  Widget _buildActions(BuildContext context, AuditDetailModel audit) {
    // An open NC no longer blocks Final Submit — see the identical
    // comment in server/controllers/audit.controller.js#completeAudit.
    final canFinalSubmit = audit.scoreResult.isFullyScored;
    final myId = context.read<AuthProvider>().user?.id;
    final isPrimary = _isPrimaryAuditor(audit, myId);
    if (!isPrimary ||
        !_isActiveForScoring(audit) ||
        _needsRepresentative(audit, myId))
      return const SizedBox.shrink();

    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _isSubmitting ? null : () => _handleSubmit(audit),
            child: _isSubmitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Submit'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: _isFinalSubmitting
                ? null
                : canFinalSubmit
                ? () => _handleFinalSubmit(audit)
                : () => _scrollToFirstIncomplete(audit),
            style: FilledButton.styleFrom(
              backgroundColor: canFinalSubmit
                  ? AppColors.green
                  : AppColors.green.withValues(alpha: 0.5),
            ),
            child: _isFinalSubmitting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Final Submit'),
          ),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final String title;
  final Widget child;
  // Collapse state lives in _AuditDetailScreenState (keyed by the group's
  // node id, see _groupCollapsed above) rather than here, so Final
  // Submit's _scrollToFirstIncomplete can force a collapsed ancestor open
  // — a group built and torn down entirely inside its own State wouldn't
  // be reachable from outside like that.
  final bool collapsed;
  final VoidCallback onToggle;

  const _GroupHeader({
    required this.title,
    required this.child,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Icon(
                  collapsed ? Icons.expand_more : Icons.expand_less,
                  color: scheme.outline,
                ),
              ],
            ),
          ),
        ),
        if (!collapsed)
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 8),
            child: child,
          ),
      ],
    );
  }
}

/// Multi-select location picker for the Instant Audit builder's scope tags
/// — mirrors the web app's LocationScopePicker (search-to-add/remove
/// chips), simplified to Locations only (mobile has no Department model
/// yet, unlike web which also allows tagging a Department). Returns the
/// new full selection on "Done", or null if dismissed without confirming.
class _LocationScopeSheet extends StatefulWidget {
  final List<LocationOption> allLocations;
  final Set<String> initiallySelected;

  const _LocationScopeSheet({
    required this.allLocations,
    required this.initiallySelected,
  });

  @override
  State<_LocationScopeSheet> createState() => _LocationScopeSheetState();
}

class _LocationScopeSheetState extends State<_LocationScopeSheet> {
  final Set<String> _selected = {};
  String _search = '';

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initiallySelected);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filtered = widget.allLocations
        .where((l) => l.display.toLowerCase().contains(_search.toLowerCase()))
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: DraggableScrollableSheet(
          initialChildSize: 0.7,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Location(s)',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, _selected),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search Area / Zone / SubZone',
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: widget.allLocations.isEmpty
                    ? const Center(child: Text('No locations found.'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final loc = filtered[i];
                          final checked = _selected.contains(loc.id);
                          return CheckboxListTile(
                            value: checked,
                            title: Text(loc.display),
                            subtitle: Text(loc.locationType),
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(loc.id);
                              } else {
                                _selected.remove(loc.id);
                              }
                            }),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
