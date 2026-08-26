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

  const EmployeeOption({
    required this.id,
    required this.name,
    this.locationIds = const [],
  });

  factory EmployeeOption.fromJson(Map<String, dynamic> json) {
    return EmployeeOption(
      id: (json['_id'] ?? '').toString(),
      name: json['employeeName']?.toString() ?? 'Unnamed',
      locationIds: (json['locationIds'] as List? ?? [])
          .map((e) => (e is Map ? e['_id'] : e)?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList(),
    );
  }
}
