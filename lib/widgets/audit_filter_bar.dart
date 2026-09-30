import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/utils/place_cascade.dart';
import '../providers/audit_filter_scope.dart';
import '../providers/audits_provider.dart';
import '../providers/filter_options_provider.dart';
import 'filter_sheet.dart';
import 'scope_toggle.dart';

final _pillDate = DateFormat('d MMM');
final _pillDateYear = DateFormat('d MMM yyyy');

/// widgets/audit_filter_bar.dart
/// ─────────────────────────────
/// The filter control every list/dashboard screen shares: the Me / All
/// Members [ScopeToggle] on the left, the [FilterButton] that opens the
/// filter sheet on the right, and — whenever anything is narrowing the view —
/// one row of removable pills spelling out what (Team, Members, Location,
/// Department, Audit Type, Date range, Status, Include skipped, Flag), with
/// "Clear" pinned to its left so it is always one tap away however many pills
/// scroll.
///
/// It reads the shared filter state straight from AuditsProvider (all three
/// filter-holding providers are kept identical by [applyAuditFilterSelection])
/// and writes through it, so a screen only says WHICH sections it offers:
/// [showStatus] (audit lists), [showFlag] (NC lists), [showDateRange]. A
/// pill for a dimension the screen doesn't offer is not drawn and doesn't
/// count toward the badge (a Status pick made on the Audits tab must not show
/// as a mystery filter on the Dashboard, whose tiles ignore it — the same as
/// the web dashboard, where Status only narrows the table).
class AuditFilterBar extends StatelessWidget {
  final bool showStatus;
  final bool showFlag;
  final bool showDateRange;

  /// A caveat rendered under the pills, for a screen where some active
  /// filter does not narrow what is on show. Null = every pill really filters.
  final String? footnote;

  const AuditFilterBar({
    super.key,
    this.showStatus = false,
    this.showFlag = false,
    this.showDateRange = true,
    this.footnote,
  });

  Future<void> _openSheet(BuildContext context, AuditFilterScope scope) async {
    final result = await showAuditFilterSheet(
      context,
      initial: AuditFilterSelection.fromScope(scope),
      showStatus: showStatus,
      showFlag: showFlag,
      showDateRange: showDateRange,
    );
    if (result == null) return;
    // The sheet can outlive this widget — a socket-driven rebuild, an
    // AppMode switch or a logout can all tear the screen down while it is
    // open, and applying then would touch providers on behalf of a screen
    // that is gone.
    if (!context.mounted) return;
    await applyAuditFilterSelection(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final scope = context.watch<AuditsProvider>();
    // watch, not read: this cache fills in asynchronously the first time
    // the sheet is opened, and these pills turn its ids back into names.
    final options = context.watch<FilterOptionsProvider>();
    final current = AuditFilterSelection.fromScope(scope);

    Future<void> change(AuditFilterSelection next) =>
        applyAuditFilterSelection(context, next);

    // Team / Members re-worked for the place [next] carries (people outside the
    // picked place are set aside, and come back when the place goes) — the same
    // answer the filter sheet gives, so the pills, the request and the sheet
    // never disagree. Without the directory nothing can be resolved, so the
    // picks are left exactly as they were.
    AuditFilterSelection rewho(
      AuditFilterSelection next, {
      required List<String> teams,
      required List<String> members,
    }) {
      if (options.employees.isEmpty) return next;
      final selfId = scope.selfEmployeeId;
      final who = WhoCascade.resolve(
        directory: options.employees,
        locations: options.locations,
        teams: teams,
        members: members,
        locationIds: next.locations,
        departmentIds: next.departments,
        untouchedMembers: !next.isTeam && selfId != null ? [selfId] : const [],
      );
      return next.copyWith(
        teams: who.teams,
        employees: who.members,
        teamMembers: who.teamMembers,
        heldTeams: who.heldTeams,
        heldEmployees: who.heldMembers,
      );
    }

    List<String> withHeld(List<String> picked, List<String> held) => [
      ...picked,
      for (final x in held)
        if (!picked.contains(x)) x,
    ];

    final specificPeople =
        current.employees.isNotEmpty || current.teams.isNotEmpty;
    final pills = <Widget>[
      for (final id in current.teams)
        _FilterPill(
          icon: Icons.diversity_3_outlined,
          label: _lookup(options.teams.map((t) => (t.id, t.name)), id, 'Team'),
          onRemove: () {
            final remaining = [...current.teams]..remove(id);
            // Members cascade from Team: re-resolve them for the teams that are
            // left (an empty list with teams still picked would read as "a team
            // with nobody" and match nothing) — within the picked place, same
            // rule as the filter sheet's Apply.
            if (options.employees.isEmpty) {
              // Directory not loaded: keep the previous resolution.
              change(
                current.copyWith(
                  teams: remaining,
                  teamMembers: remaining.isEmpty ? const [] : current.teamMembers,
                  employees: const [],
                  heldEmployees: const [],
                ),
              );
              return;
            }
            change(
              rewho(
                current,
                teams: withHeld(remaining, current.heldTeams),
                members: const [],
              ),
            );
          },
        ),
      if (current.employees.isNotEmpty)
        _FilterPill(
          icon: Icons.person_outline,
          label: current.employees.length == 1
              ? _lookup(
                  options.employees.map((e) => (e.id, e.name)),
                  current.employees.first,
                  '1 member',
                )
              : '${current.employees.length} members',
          onRemove: () => change(
            current.copyWith(employees: const [], heldEmployees: const []),
          ),
        ),
      for (final id in current.locations)
        _FilterPill(
          icon: Icons.place_outlined,
          label: _lookup(options.locations.map((l) => (l.id, l.name)), id, 'Location'),
          // Employee selections are left alone when a location goes: the two
          // are independent params server-side, and silently dropping people
          // because their location was removed would be a second, invisible
          // edit to a filter the user did not ask to change. What the place had
          // SET ASIDE comes back (and a team's people are re-resolved for the
          // wider place), exactly as clearing it in the sheet does.
          onRemove: () => change(
            rewho(
              current.copyWith(locations: [...current.locations]..remove(id)),
              teams: withHeld(current.teams, current.heldTeams),
              members: withHeld(current.employees, current.heldEmployees),
            ),
          ),
        ),
      for (final id in current.departments)
        _FilterPill(
          icon: Icons.apartment_outlined,
          label: _lookup(options.departments.map((d) => (d.id, d.name)), id, 'Department'),
          onRemove: () => change(
            rewho(
              current.copyWith(
                departments: [...current.departments]..remove(id),
              ),
              teams: withHeld(current.teams, current.heldTeams),
              members: withHeld(current.employees, current.heldEmployees),
            ),
          ),
        ),
      for (final type in current.auditTypes)
        _FilterPill(
          label: type,
          onRemove: () =>
              change(current.copyWith(auditTypes: [...current.auditTypes]..remove(type))),
        ),
      if (showDateRange && (current.dateFrom != null || current.dateTo != null))
        _FilterPill(
          icon: Icons.event_outlined,
          label: _rangeLabel(current.dateFrom, current.dateTo),
          onRemove: () => change(current.copyWith(dateRange: (null, null))),
        ),
      if (showStatus)
        for (final s in current.statuses)
          _FilterPill(
            label: s,
            onRemove: () =>
                change(current.copyWith(statuses: [...current.statuses]..remove(s))),
          ),
      if (showStatus && current.includeSkipped)
        _FilterPill(
          label: 'Incl. skipped',
          onRemove: () => change(current.copyWith(includeSkipped: false)),
        ),
      if (showFlag)
        for (final f in current.flags)
          _FilterPill(
            icon: Icons.flag_outlined,
            label: f,
            onRemove: () =>
                change(current.copyWith(flags: [...current.flags]..remove(f))),
          ),
      // All Members with nothing more specific is a widening worth showing;
      // plain Me is the resting state and shows nothing.
      if (!specificPeople && current.isTeam)
        _FilterPill(
          icon: Icons.groups_outlined,
          label: 'All Members',
          onRemove: () => change(current.copyWith(isTeam: false)),
        ),
    ];

    final count = scope.activeFilterCountFor(
      status: showStatus,
      date: showDateRange,
      flag: showFlag,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          // Scope control hard left, Filters hard right, leftover width
          // absorbed as the gap between them. The left child is Flexible
          // and scrolls horizontally, so on a 360px phone the toggle gives
          // way instead of the row overflowing.
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ScopeToggle(
                    isTeam: current.isTeam,
                    // A specific Team/Members pick WINS over Me/All Members
                    // server-side, so neither segment may read as selected
                    // while one is in force.
                    specific: specificPeople,
                    onChanged: (isTeam) => change(
                      current.copyWith(
                        isTeam: isTeam,
                        teams: const [],
                        teamMembers: const [],
                        employees: const [],
                        heldTeams: const [],
                        heldEmployees: const [],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            FilterButton(
              activeCount: count,
              onTap: () => _openSheet(context, scope),
            ),
          ],
        ),
        // What is narrowing the numbers, spelled out — each pill removes just
        // its own dimension, so widening back out is one tap.
        //
        // Fixed-HEIGHT, horizontally-scrolling single row, deliberately NOT a
        // Wrap: a Wrap grows one line per overflowed pill and would shove the
        // page content down. "Clear" sits OUTSIDE the scrolling list so it is
        // always reachable.
        if (pills.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 30,
            child: Row(
              children: [
                TextButton(
                  onPressed: () => change(_clearedFor(current)),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Clear', style: TextStyle(fontSize: 12.5)),
                ),
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: pills,
                  ),
                ),
              ],
            ),
          ),
          if (footnote != null) ...[
            const SizedBox(height: 6),
            Text(
              footnote!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ],
      ],
    );
  }

  /// Clear, but only the dimensions this screen offers — a Status pick made
  /// elsewhere is not this bar's to wipe (and not on show here).
  AuditFilterSelection _clearedFor(AuditFilterSelection current) {
    return AuditFilterSelection(
      statuses: showStatus ? const [] : current.statuses,
      includeSkipped: showStatus ? false : current.includeSkipped,
      flags: showFlag ? const [] : current.flags,
      dateFrom: showDateRange ? null : current.dateFrom,
      dateTo: showDateRange ? null : current.dateTo,
    );
  }

  static String _lookup(
    Iterable<(String, String)> pairs,
    String id,
    String fallback,
  ) {
    // Falls back to a generic word rather than showing the raw ObjectId: an
    // unresolved id means the cache was dropped, and a hex string on a pill
    // reads as a bug to the user.
    for (final (key, name) in pairs) {
      if (key == id && name.isNotEmpty) return name;
    }
    return fallback;
  }

  static String _rangeLabel(DateTime? from, DateTime? to) {
    if (from != null && to != null) {
      final sameYear = from.year == to.year;
      return '${sameYear ? _pillDate.format(from) : _pillDateYear.format(from)} – ${_pillDateYear.format(to)}';
    }
    if (from != null) return 'From ${_pillDateYear.format(from)}';
    return 'Until ${_pillDateYear.format(to!)}';
  }
}

/// One active filter as a small, self-themed pill — a plain Material/InkWell,
/// not an InputChip: a Chip widget carries fixed overhead (avatar slot,
/// delete-icon spacing) that made even one active filter read heavy, and the
/// pills must stay one compact row. The X removes; the label itself is inert.
class _FilterPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onRemove;

  const _FilterPill({required this.label, required this.onRemove, this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onRemove,
          borderRadius: BorderRadius.circular(999),
          child: Semantics(
            button: true,
            label: 'Remove filter $label',
            child: Padding(
              padding: const EdgeInsets.only(left: 10, right: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 12, color: scheme.onPrimaryContainer),
                    const SizedBox(width: 4),
                  ],
                  // A long name must not push this pill (and the whole
                  // scrollable row) arbitrarily wide.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 13,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
