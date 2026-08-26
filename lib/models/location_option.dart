/// A pickable Location (Area/Zone/SubZone) — for the Instant Audit
/// builder's scope picker (see AuditsProvider.fetchAllLocations,
/// screens/audits/audit_detail_screen.dart). Mirrors the fields
/// GET /locations actually returns (server/models/Location.js) that this
/// picker needs; not the full location detail shape.
class LocationOption {
  final String id;
  final String name;
  final String? code;
  final String locationType; // "Area" | "Zone" | "SubZone"

  const LocationOption({required this.id, required this.name, this.code, required this.locationType});

  String get display => (code != null && code!.isNotEmpty) ? '$name ($code)' : name;

  factory LocationOption.fromJson(Map<String, dynamic> json) {
    return LocationOption(
      id: (json['_id'] ?? '').toString(),
      name: json['name']?.toString() ?? 'Location',
      code: json['code']?.toString(),
      locationType: json['locationType']?.toString() ?? 'Area',
    );
  }
}
