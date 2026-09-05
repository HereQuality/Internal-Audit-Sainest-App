import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/employee_option.dart';
import '../providers/auth_provider.dart';
import '../providers/filter_options_provider.dart';

// Only ever rendered as "September 2025" in the Month stepper — kept at
// file scope (not rebuilt per frame inside build) because DateFormat
// parses its pattern on construction, and the stepper rebuilds on every
// chevron tap. Not in Formatters because nothing else in the app shows a
// bare month; Formatters.date stays the one date format everywhere else.
final _monthLabel = DateFormat('MMMM yyyy');

/// widgets/filter_sheet.dart
/// ───────────────────────────────────────
/// The one filter surface for every audit-scoped screen (Dashboard,
/// Audits, Calendar) — the phone's answer to the web app's row of
/// TeamFilterPanel + LocationFilterSelect + audit-type select, folded into
/// a single bottom sheet because there is no room on a 360px screen for
/// three always-open pickers.
///
/// Nothing here touches a provider's filter state. The sheet hands back
/// what was picked and the CALLING screen applies it — to BOTH
/// AuditsProvider and DashboardProvider, exactly as ScopeToggle already
/// calls setTeamScope on both (see providers/audit_filter_scope.dart's own
/// class doc for why the two hold separate copies). That keeps the sheet
/// free of any "which providers exist on this screen" knowledge and makes
/// Cancel genuinely free: dismissing without Apply has changed nothing.
class AuditFilterSelection {
  /// The coarse Me/Team scope. Ignored server-side whenever [employees] is
  /// non-empty — see the precedence note on AuditFilterScope.employeeFilter
  /// — but still carried, so backing out of a specific-people pick lands
  /// on whichever end of the toggle the user was last on.
  final bool isTeam;

  /// Employee ids, empty for "no specific people".
  final List<String> employees;

  /// Location ids, empty for "everywhere I can see".
  final List<String> locations;

  /// Audit type NAMES, not ids — Audit.auditType stores the name and the
  /// server's `?auditType=` matches on it (models/audit_type_option.dart).
  final List<String> auditTypes;

  /// First-of-month, and non-null ONLY when the sheet was opened with a
  /// month (i.e. by the Calendar). Every other caller gets null and can
  /// ignore the field entirely rather than having to guard against a month
  /// it never asked to show.
  final DateTime? month;

  const AuditFilterSelection({
    required this.isTeam,
    required this.employees,
    required this.locations,
    required this.auditTypes,
    this.month,
  });
}

/// Opens the filter sheet seeded with the caller's current filter state.
///
/// Pass a non-null [month] to switch the Month section on; leave it null
/// (Dashboard, Audits) and the section is not built at all and the result's
/// `month` comes back null.
///
/// Returns null if dismissed without applying — back button, tap-outside
/// and drag-to-close all land there, so a null result means "leave every
/// filter exactly as it was", never "clear them".
Future<AuditFilterSelection?> showAuditFilterSheet(
  BuildContext context, {
  required bool isTeam,
  required List<String> employees,
  required List<String> locations,
  required List<String> auditTypes,
  DateTime? month,
}) {
  return showModalBottomSheet<AuditFilterSelection>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AuditFilterSheet(
      isTeam: isTeam,
      employees: employees,
      locations: locations,
      auditTypes: auditTypes,
      initialMonth: month,
    ),
  );
}

class _AuditFilterSheet extends StatefulWidget {
  final bool isTeam;
  final List<String> employees;
  final List<String> locations;
  final List<String> auditTypes;
  final DateTime? initialMonth;

  const _AuditFilterSheet({
    required this.isTeam,
    required this.employees,
    required this.locations,
    required this.auditTypes,
    this.initialMonth,
  });

  @override
  State<_AuditFilterSheet> createState() => _AuditFilterSheetState();
}

class _AuditFilterSheetState extends State<_AuditFilterSheet> {
  // The whole selection is local until Apply — the sheet is a draft of a
  // filter, not a live control. Sets rather than Lists because every
  // interaction here is a membership toggle; Dart's Set keeps insertion
  // order, so `toList()` at Apply time is still stable.
  late bool _isTeam;
  late final Set<String> _employees;
  late final Set<String> _locations;
  late final Set<String> _auditTypes;
  DateTime? _month;

  final TextEditingController _searchController = TextEditingController();
  String _personSearch = '';

  // The per-person list is the secondary, opt-in half of the People
  // section — collapsed unless the caller arrived with people already
  // picked, in which case hiding the very thing that is narrowing their
  // data would be actively misleading.
  late bool _peopleExpanded;

  // Used only to relabel the logged-in user's own row "Me" instead of
  // their name, matching the web TeamFilterPanel.jsx's `isSelf ? "Me"`.
  // The id is the same one main.dart's _RootGate feeds each provider as
  // selfEmployeeId, so it lines up with the ids in the employee list.
  String? _selfId;

  bool get _showMonth => widget.initialMonth != null;

  @override
  void initState() {
    super.initState();
    _isTeam = widget.isTeam;
    _employees = {...widget.employees};
    _locations = {...widget.locations};
    _auditTypes = {...widget.auditTypes};
    _month = _normaliseMonth(widget.initialMonth);
    _peopleExpanded = _employees.isNotEmpty;
    _selfId = context.read<AuthProvider>().user?.id;
    // load() is idempotent and coalesces concurrent callers, so firing it
    // on every open is free — but it flips isLoading and notifies
    // synchronously, which during this first build would be a
    // setState-during-build crash. Post-frame is the cheap fix; the
    // sections render their own loading line for the one frame (or the
    // one request) it takes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      context.read<FilterOptionsProvider>().load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static DateTime? _normaliseMonth(DateTime? value) {
    if (value == null) {
      return null;
    }
    return DateTime(value.year, value.month, 1);
  }

  /// Back to the resting default — Me, everywhere, every type, this month
  /// — WITHOUT closing the sheet, so "reset then pick two things" is one
  /// continuous gesture instead of reset-apply-reopen. Nothing is pushed
  /// to the providers until Apply, same as every other control here.
  void _reset() {
    setState(() {
      _isTeam = false;
      _employees.clear();
      _locations.clear();
      _auditTypes.clear();
      _searchController.clear();
      _personSearch = '';
      final now = DateTime.now();
      _month = _showMonth ? DateTime(now.year, now.month, 1) : null;
    });
  }

  /// Me / My team. Both CLEAR the specific-people pick: the two controls
  /// are one decision ("who am I looking at"), and leaving a stale person
  /// list behind would mean tapping "Me" visibly selected the chip while
  /// the query kept returning someone else's audits — the precedence rule
  /// on AuditFilterScope.employeeFilter says the list wins.
  void _pickScope(bool isTeam) {
    setState(() {
      _isTeam = isTeam;
      _employees.clear();
    });
  }

  void _togglePerson(String id, bool checked) {
    setState(() {
      if (checked) {
        _employees.add(id);
      } else {
        _employees.remove(id);
      }
    });
  }

  void _toggleLocation(FilterOptionsProvider options, String id, bool checked) {
    setState(() {
      if (checked) {
        _locations.add(id);
      } else {
        _locations.remove(id);
      }
      _reconcilePeople(options);
    });
  }

  /// Drops any picked person who is no longer offered under the current
  /// location selection. Without this, narrowing to a location the person
  /// isn't at leaves their id in `employeeFilter` with no row on screen
  /// showing it — an invisible filter that keeps silently narrowing every
  /// list and stat, and that the user has no control left to undo.
  ///
  /// Deliberately a no-op while the option list is still empty: employeesAt
  /// on an empty roster returns an empty list for ANY location set, so
  /// reconciling before the fetch lands would read as "none of these people
  /// exist" and wipe the very selection the caller passed in.
  void _reconcilePeople(FilterOptionsProvider options) {
    if (_employees.isEmpty || options.employees.isEmpty) {
      return;
    }
    final visible = options
        .employeesAt(_locations.toList())
        .map((e) => e.id)
        .toSet();
    _employees.removeWhere((id) => !visible.contains(id));
  }

  void _toggleAuditType(String name, bool checked) {
    setState(() {
      if (checked) {
        _auditTypes.add(name);
      } else {
        _auditTypes.remove(name);
      }
    });
  }

  void _stepMonth(int delta) {
    final current = _month;
    if (current == null) {
      return;
    }
    // DateTime normalises an out-of-range month itself — month 13 rolls
    // into next January, month 0 into last December — so stepping needs no
    // year carry of its own.
    setState(() => _month = DateTime(current.year, current.month + delta, 1));
  }

  void _thisMonth() {
    final now = DateTime.now();
    setState(() => _month = DateTime(now.year, now.month, 1));
  }

  void _apply() {
    Navigator.of(context).pop(
      AuditFilterSelection(
        isTeam: _isTeam,
        employees: _employees.toList(),
        locations: _locations.toList(),
        auditTypes: _auditTypes.toList(),
        // Null whenever the section wasn't shown — a caller that never
        // offered a month must not be handed one it would then have to
        // know to ignore.
        month: _showMonth ? _month : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final options = context.watch<FilterOptionsProvider>();
    final media = MediaQuery.of(context);

    // Height-bounded and internally scrollable, so the Apply button is
    // pinned and can never end up below the fold — the people list alone
    // can be dozens of rows on a manager's account. Capped at 85% of the
    // screen, but never taller than what's actually left once the keyboard
    // (the people search) and the status bar have taken their share;
    // taking the smaller of the two is what stops the sheet overflowing
    // while the search field is focused.
    final maxSheetHeight = math.min(
      media.size.height * 0.85,
      media.size.height - media.viewInsets.bottom - media.padding.top,
    );

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: scheme.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              _buildHeader(context),
              // Flexible, not Expanded: a sheet with three short sections
              // should wrap its content instead of stretching to 85% of
              // the screen with a band of empty surface above the footer.
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildPeopleSection(context, options),
                      const Divider(height: 28),
                      _buildLocationSection(context, options),
                      const Divider(height: 28),
                      _buildAuditTypeSection(context, options),
                      if (_showMonth) ...[
                        const Divider(height: 28),
                        _buildMonthSection(context),
                      ],
                    ],
                  ),
                ),
              ),
              _buildFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Filters',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(onPressed: _reset, child: const Text('Reset')),
        ],
      ),
    );
  }

  // ── People ────────────────────────────────────────────────────────────
  Widget _buildPeopleSection(
    BuildContext context,
    FilterOptionsProvider options,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // A specific-people pick outranks the coarse toggle, so while one is
    // active NEITHER chip may read as selected — showing "Me" highlighted
    // next to a list that is actually returning three other people is the
    // exact confusion the caption below spells out.
    final specific = _employees.isNotEmpty;
    // Live-narrowed by whatever locations are ticked in THIS sheet right
    // now (not by what the providers currently hold) — ticking a location
    // in the section below shortens this list on the same frame.
    final pickable = options.employeesAt(_locations.toList());
    final query = _personSearch.trim().toLowerCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('People'),
        const SizedBox(height: 8),
        // Wrap, not Row: "My team" plus a translated/longer label must be
        // free to fall onto a second line rather than overflow at 360px.
        // These keep Material's default (padded) tap target instead of the
        // shrinkWrap StatusFilterChipRow uses — that row is inside a fixed
        // 44px band, these sit in an open column where the full 48px
        // target is the accessible option.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Me'),
              selected: !specific && !_isTeam,
              onSelected: (_) => _pickScope(false),
            ),
            ChoiceChip(
              label: const Text('My team'),
              selected: !specific && _isTeam,
              onSelected: (_) => _pickScope(true),
            ),
          ],
        ),
        if (specific) ...[
          const SizedBox(height: 6),
          Text(
            'Showing the people picked below — tap Me or My team to go back.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.outline),
          ),
        ],
        const SizedBox(height: 4),
        // Hand-rolled rather than ExpandableSection: that widget hides
        // itself entirely at count 0 (by design, for the dashboard's
        // "Overdue (0)" panels), which here would mean the disclosure
        // disappears in precisely the state you need it — nobody picked
        // yet and you want to pick someone.
        InkWell(
          onTap: () => setState(() => _peopleExpanded = !_peopleExpanded),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.person_search_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Choose specific people',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (specific) ...[
                  _CountPill(count: _employees.length),
                  const SizedBox(width: 6),
                ],
                AnimatedRotation(
                  turns: _peopleExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_peopleExpanded) ...[
          TextField(
            controller: _searchController,
            textInputAction: TextInputAction.search,
            onChanged: (v) => setState(() => _personSearch = v),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search people',
              prefixIcon: const Icon(Icons.search, size: 18),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (options.isLoading && options.employees.isEmpty)
            const _LoadingLine('Loading people…')
          else
            _buildPeopleList(context, pickable, query),
        ],
      ],
    );
  }

  Widget _buildPeopleList(
    BuildContext context,
    List<EmployeeOption> pickable,
    String query,
  ) {
    // Matched against the displayed LABEL as well as the stored name: the
    // self row reads "Me", so typing "me" has to find yourself rather than
    // every colleague with those two letters in their name and not you.
    final matches = pickable.where((e) {
      if (query.isEmpty) {
        return true;
      }
      final name = e.name.toLowerCase();
      return name.contains(query) || (e.id == _selfId && 'me'.contains(query));
    }).toList();

    if (matches.isEmpty) {
      return _MutedLine(
        pickable.isEmpty
            ? 'No people available to filter by.'
            : 'No one matches that search.',
      );
    }
    return ConstrainedBox(
      // Capped and scrollable: a hierarchy can run to dozens of people and
      // this is only the second of four sections — an uncapped list would
      // push Location and Audit Type out of sight behind a long scroll.
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: matches.length,
        itemBuilder: (_, i) {
          final person = matches[i];
          final isSelf = person.id == _selfId;
          return CheckboxListTile(
            value: _employees.contains(person.id),
            onChanged: (v) => _togglePerson(person.id, v ?? false),
            title: Text(
              isSelf ? 'Me' : person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            // Left non-dense on purpose: ListTile's standard 56px row is
            // comfortably over the 44px minimum tap target, and the extra
            // pixels are worth it in a list people tick several rows of in
            // one pass.
            visualDensity: VisualDensity.standard,
          );
        },
      ),
    );
  }

  // ── Location ──────────────────────────────────────────────────────────
  Widget _buildLocationSection(
    BuildContext context,
    FilterOptionsProvider options,
  ) {
    // No search box here on purpose: this list is only the locations THIS
    // user is scoped to (GET /locations/my-scope), typically a handful,
    // and a second search field in the same sheet costs more attention
    // than it saves. The people list gets one because a hierarchy is the
    // list that actually gets long.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Location'),
        const SizedBox(height: 4),
        if (options.isLoading && options.locations.isEmpty)
          const _LoadingLine('Loading locations…')
        else if (options.locations.isEmpty)
          const _MutedLine('No locations available to filter by.')
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: options.locations.length,
              itemBuilder: (_, i) {
                final loc = options.locations[i];
                return CheckboxListTile(
                  value: _locations.contains(loc.id),
                  onChanged: (v) =>
                      _toggleLocation(options, loc.id, v ?? false),
                  // `display` already folds the code into the name
                  // ("Plant A (PA-01)") — one ellipsised line instead of a
                  // name/code Row that would overflow at 360px.
                  title: Text(
                    loc.display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.standard,
                );
              },
            ),
          ),
      ],
    );
  }

  // ── Audit type ────────────────────────────────────────────────────────
  Widget _buildAuditTypeSection(
    BuildContext context,
    FilterOptionsProvider options,
  ) {
    // Selection travels by NAME (the server matches Audit.auditType, a
    // plain string), so two types configured with the same name are one
    // and the same filter — deduped here rather than rendering two chips
    // that mysteriously toggle together. The source list is already
    // activeOnly (ApiConstants.auditTypes), so a retired type stops being
    // offered without anything here having to know about it.
    final names = <String>[];
    final seen = <String>{};
    for (final type in options.auditTypes) {
      if (type.name.isNotEmpty && seen.add(type.name)) {
        names.add(type.name);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Audit Type'),
        const SizedBox(height: 8),
        if (options.isLoading && options.auditTypes.isEmpty)
          const _LoadingLine('Loading audit types…')
        else if (names.isEmpty)
          const _MutedLine('No audit types available to filter by.')
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final name in names)
                FilterChip(
                  label: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  selected: _auditTypes.contains(name),
                  onSelected: (v) => _toggleAuditType(name, v),
                ),
            ],
          ),
      ],
    );
  }

  // ── Month (Calendar only) ─────────────────────────────────────────────
  Widget _buildMonthSection(BuildContext context) {
    final month = _month;
    if (month == null) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _SectionTitle('Month')),
            TextButton(onPressed: _thisMonth, child: const Text('This month')),
          ],
        ),
        // icon / label / icon — the label is the only flexible child, so
        // there is nothing here that can overflow however long the month
        // name gets.
        Row(
          children: [
            IconButton(
              onPressed: () => _stepMonth(-1),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous month',
            ),
            Expanded(
              child: Text(
                _monthLabel.format(month),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              onPressed: () => _stepMonth(1),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next month',
            ),
          ],
        ),
      ],
    );
  }

  // ── Footer ────────────────────────────────────────────────────────────
  Widget _buildFooter(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Outside the scroll view entirely — the one thing in this sheet that
    // must never need a scroll to reach. The hairline is what reads it as
    // a pinned bar once the body scrolls under it.
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: ElevatedButton(onPressed: _apply, child: const Text('Apply')),
        ),
      ),
    );
  }
}

/// The trigger that opens [showAuditFilterSheet] — sized to sit in a
/// screen's header row beside a ScopeToggle, which is why it is an
/// outlined, shrink-wrapped 40px control rather than a full-height button.
/// [activeCount] comes straight from AuditFilterScope.activeFilterCount;
/// 0 means the resting state and shows no badge at all, so the badge only
/// ever appears when something really is narrowing the view.
class FilterButton extends StatelessWidget {
  final int activeCount;
  final VoidCallback onTap;

  const FilterButton({
    super.key,
    required this.activeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.tune_rounded, size: 18),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Filters'),
          if (activeCount > 0) ...[
            const SizedBox(width: 6),
            _CountPill(count: activeCount),
          ],
        ],
      ),
      style: OutlinedButton.styleFrom(
        // 40px floor with shrinkWrap: tall enough to stay a comfortable
        // tap target, short enough not to out-size the SegmentedButton it
        // sits next to. Material's default padded target would add 8px of
        // invisible height and push the header row out of line.
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The small primaryContainer count badge shared by the Filters button and
/// the "Choose specific people" disclosure — same pill ExpandableSection
/// puts on its section headers, so a count reads the same wherever it
/// appears.
class _CountPill extends StatelessWidget {
  final int count;

  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: scheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;

  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    );
  }
}

/// Per-section loading line rather than one spinner over the whole sheet:
/// FilterOptionsProvider fetches its three lists independently and lets any
/// one of them fail quietly, so a section still waiting must not hold the
/// other two hostage.
class _LoadingLine extends StatelessWidget {
  final String label;

  const _LoadingLine(this.label);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.outline,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

class _MutedLine extends StatelessWidget {
  final String text;

  const _MutedLine(this.text);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.outline),
      ),
    );
  }
}
