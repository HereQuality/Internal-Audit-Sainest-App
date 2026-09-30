/// A team an employee belongs to — just enough for the Team filter (id to
/// send/compare, name to show). Populated by GET /employees/my-hierarchy-scope
/// (`teamIds: [{ _id, teamName }]`), same as the web's useScopeFilter.
class TeamRef {
  final String id;
  final String name;

  const TeamRef({required this.id, required this.name});
}

/// Minimal employee shape for a picker — the "who is this NC against" and
/// "select representative auditee" dropdowns, populated from GET
/// /employees/by-location (everyone actually assigned to the audit's own
/// location(s)) — deliberately not scoped by manager-hierarchy or audit
/// type, see AuditsProvider.fetchLocationEmployees.
class EmployeeOption {
  final String id;
  final String name;
  // Which locations this employee belongs to — lets a per-location NC-raise
  // picker (checkpoint_card.dart's NC-details popup) narrow the dropdown
  // down to just the active location's members instead of the whole
  // hierarchy. Unpopulated ObjectId strings are enough since it's only
  // ever compared against another location's id, never displayed.
  final List<String> locationIds;
  // Teams the person belongs to (only when the endpoint populated them —
  // the hierarchy scope does, an unpopulated id has no name and is skipped).
  // Drives the Team filter and the muted "Team A, Team B" second line under
  // a name in the Members list, like the web's MemberFilterSelect.
  final List<TeamRef> teams;
  // false for a deactivated person: their audits stay on record, so the
  // filter still offers them, marked "(inactive)" and listed last.
  final bool isActive;
  // Audit types the person is qualified for (ids; empty = no restriction
  // recorded) — the reassign picker offers only people qualified for the
  // audit's type, like the web's.
  final List<String> auditTypeIds;

  const EmployeeOption({
    required this.id,
    required this.name,
    this.locationIds = const [],
    this.teams = const [],
    this.isActive = true,
    this.auditTypeIds = const [],
  });

  factory EmployeeOption.fromJson(Map<String, dynamic> json) {
    return EmployeeOption(
      id: (json['_id'] ?? '').toString(),
      name: json['employeeName']?.toString() ?? 'Unnamed',
      locationIds: (json['locationIds'] as List? ?? [])
          .map((e) => (e is Map ? e['_id'] : e)?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(),
      teams: (json['teamIds'] as List? ?? [])
          .whereType<Map>()
          .map(
            (t) => TeamRef(
              id: (t['_id'] ?? '').toString(),
              name: t['teamName']?.toString() ?? '',
            ),
          )
          .where((t) => t.id.isNotEmpty && t.name.isNotEmpty)
          .toList(),
      isActive: json['isActive'] != false,
      auditTypeIds: (json['auditTypeIds'] as List? ?? [])
          .map((e) => (e is Map ? e['_id'] : e)?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(),
    );
  }
}
