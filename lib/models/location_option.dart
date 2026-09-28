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
  // A Sub Zone's parent Zone (id + name), as GET /locations/my-scope sends
  // them — lets the filter group Sub Zones under their Zone. Null for the rest.
  final String? parentZoneId;
  final String? parentZoneName;

  const LocationOption({
    required this.id,
    required this.name,
    this.code,
    required this.locationType,
    this.parentZoneId,
    this.parentZoneName,
  });

  String get display => (code != null && code!.isNotEmpty) ? '$name ($code)' : name;

  factory LocationOption.fromJson(Map<String, dynamic> json) {
    return LocationOption(
      id: (json['_id'] ?? '').toString(),
      name: json['name']?.toString() ?? 'Location',
      code: json['code']?.toString(),
      locationType: json['locationType']?.toString() ?? 'Area',
      parentZoneId: _refId(json['parentZoneId']),
      parentZoneName: json['parentZoneName']?.toString() ??
          (json['parentZoneId'] is Map ? (json['parentZoneId'] as Map)['name']?.toString() : null),
    );
  }
}

// The server may send a parent as a bare id or populated — accept either.
String? _refId(Object? ref) {
  final v = ref is Map ? ref['_id'] : ref;
  final s = v?.toString();
  return s == null || s.isEmpty ? null : s;
}
