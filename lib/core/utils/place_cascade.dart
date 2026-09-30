import '../../models/employee_option.dart';
import '../../models/location_option.dart';

/// core/utils/place_cascade.dart
/// ─────────────────────────────
/// The two-way link between the Location filter and the Team / Members filters
/// (a port of the web's client/src/utils/placeCascade.js, plus the resolver the
/// filter sheet and filter bar share):
///   - pick a Location (or Department) -> only the people who belong to it are
///     offered under Members and Team ([placeMembers]);
///   - pick people (or teams) -> only the places those people belong to are
///     offered under Location ([placesOfPeople]).
///
/// A person "belongs" to a place through Employee.locationIds / departmentIds
/// (what GET /employees/my-hierarchy-scope carries). Places nest: a Zone
/// contains its Sub Zones (Location.parentZoneId), so picking a Zone brings in
/// the people of its Sub Zones, and a person of a Sub Zone brings in that Zone
/// (the row it sits under) so the two stay reachable together.
///
/// Pure functions — no provider, no widget; the sheet decides when they apply.

/// The web's "match nobody" list entry — never a real place.
const String kPlaceNoneSentinel = '__none__';

/// Location ids + department ids, as two sets.
typedef PlaceSet = ({Set<String> locations, Set<String> departments});

List<String> _ids(Iterable<String>? list) => [
  for (final x in list ?? const <String>[])
    if (x.isNotEmpty && x != kPlaceNoneSentinel) x,
];

/// True when the facet names at least one real place (not All, not "nobody").
bool hasPlacePick({
  Iterable<String>? locationIds,
  Iterable<String>? departmentIds,
}) => _ids(locationIds).length + _ids(departmentIds).length > 0;

Map<String, List<String>> _childrenByZone(List<LocationOption> locations) {
  final map = <String, List<String>>{};
  for (final l in locations) {
    final parent = l.parentZoneId;
    if (parent == null || parent.isEmpty) continue;
    map.putIfAbsent(parent, () => []).add(l.id);
  }
  return map;
}

/// The picked places plus, for every picked Zone, its Sub Zones.
PlaceSet expandPlaces({
  Iterable<String>? locationIds,
  Iterable<String>? departmentIds,
  List<LocationOption> locations = const [],
}) {
  final kids = _childrenByZone(locations);
  final loc = <String>{};
  for (final id in _ids(locationIds)) {
    loc.add(id);
    loc.addAll(kids[id] ?? const []);
  }
  return (locations: loc, departments: _ids(departmentIds).toSet());
}

/// Directory rows that belong to any of the (expanded) places. A person with no
/// place on their record belongs to none of them.
List<EmployeeOption> placeMembers(
  List<EmployeeOption> directory, {
  Iterable<String>? locationIds,
  Iterable<String>? departmentIds,
  List<LocationOption> locations = const [],
}) {
  final want = expandPlaces(
    locationIds: locationIds,
    departmentIds: departmentIds,
    locations: locations,
  );
  return [
    for (final m in directory)
      if (_ids(m.locationIds).any(want.locations.contains) ||
          _ids(m.departmentIds).any(want.departments.contains))
        m,
  ];
}

/// The places these people belong to: their own places, the Zone above each of
/// their Sub Zones and the Sub Zones under each of their Zones — so a Zone and
/// its Sub Zones stay reachable together in the Location list.
PlaceSet placesOfPeople(
  Iterable<EmployeeOption> people,
  List<LocationOption> locations,
) {
  final byId = {for (final l in locations) l.id: l};
  final kids = _childrenByZone(locations);
  final loc = <String>{};
  final dep = <String>{};
  for (final p in people) {
    dep.addAll(_ids(p.departmentIds));
    for (final id in _ids(p.locationIds)) {
      loc.add(id);
      final parent = byId[id]?.parentZoneId;
      if (parent != null && parent.isNotEmpty) loc.add(parent);
      loc.addAll(kids[id] ?? const []);
    }
  }
  return (locations: loc, departments: dep);
}

/// What the Who filters (Team, Members) really mean once the picked place
/// narrows them — the one answer the filter sheet, the filter bar's pills and
/// the request scope all read, so what is shown and what is sent never differ.
///
/// Picks that fall outside the place are SET ASIDE while it applies
/// ([heldTeams], [heldMembers]) but never dropped from the saved selection:
/// the caller keeps them and feeds them back in, so clearing the place brings
/// them back.
class WhoCascade {
  /// The people the picked place leaves in play (the whole directory when no
  /// place is picked, or when the cascade cannot apply yet).
  final List<EmployeeOption> pool;

  /// The Team / Members picks still valid under the place.
  final List<String> teams;
  final List<String> members;

  /// The picks the place set aside (not offered, not applied, not forgotten).
  final List<String> heldTeams;
  final List<String> heldMembers;

  /// Everyone in [teams] (within [pool]) — what a Team means to the server
  /// when no specific Members are picked. Empty when no team is picked.
  final List<String> teamMembers;

  /// The places the picked people / teams belong to — null when the people
  /// filter is untouched (Me / All Members) and so leaves the Location list
  /// alone.
  final PlaceSet? placeRestriction;

  /// Whether a place narrowed anything (the pool is not the whole directory).
  final bool placeApplies;

  const WhoCascade({
    required this.pool,
    required this.teams,
    required this.members,
    required this.heldTeams,
    required this.heldMembers,
    required this.teamMembers,
    required this.placeRestriction,
    required this.placeApplies,
  });

  /// [directory] is the hierarchy scope (with Team / place ids); [locations] the
  /// location scope (for Zone -> Sub Zone). [teams] / [members] are the FULL
  /// saved picks (held ones included), [locationIds] / [departmentIds] the
  /// picked place.
  ///
  /// [untouchedMembers]: a Members pick equal to this list (with no team
  /// picked) is the untouched default (Me), so it does not narrow Locations.
  ///
  /// The cascade waits for the directory: with it empty (not loaded, or failed)
  /// nothing is narrowed and nothing is set aside, exactly as if no place were
  /// picked.
  factory WhoCascade.resolve({
    required List<EmployeeOption> directory,
    required List<LocationOption> locations,
    required List<String> teams,
    required List<String> members,
    List<String> locationIds = const [],
    List<String> departmentIds = const [],
    List<String> untouchedMembers = const [],
  }) {
    final ready = directory.isNotEmpty;
    final placeApplies =
        ready &&
        hasPlacePick(locationIds: locationIds, departmentIds: departmentIds);
    final pool = placeApplies
        ? placeMembers(
            directory,
            locationIds: locationIds,
            departmentIds: departmentIds,
            locations: locations,
          )
        : directory;

    // A team stays valid while at least one person of the pool is in it.
    final poolTeamIds = {
      for (final e in pool)
        for (final t in e.teams) t.id,
    };
    final poolIds = {for (final e in pool) e.id};
    final effTeams = placeApplies
        ? [for (final t in teams) if (poolTeamIds.contains(t)) t]
        : List<String>.of(teams);
    final effMembers = placeApplies
        ? [for (final m in members) if (poolIds.contains(m)) m]
        : List<String>.of(members);

    final teamSet = effTeams.toSet();
    final teamMembers = effTeams.isEmpty
        ? const <String>[]
        : [
            for (final e in pool)
              if (e.teams.any((t) => teamSet.contains(t.id))) e.id,
          ];

    // Only a deliberate Team / Members pick narrows the Location list.
    final memberSet = effMembers.toSet();
    final untouched = untouchedMembers.toSet();
    final membersExplicit =
        effMembers.isNotEmpty &&
        !(effTeams.isEmpty &&
            memberSet.length == untouched.length &&
            memberSet.containsAll(untouched));
    final peopleExplicit = effTeams.isNotEmpty || membersExplicit;

    PlaceSet? restriction;
    if (ready && peopleExplicit) {
      final people = effMembers.isNotEmpty
          ? [
              for (final e in directory)
                if (memberSet.contains(e.id)) e,
            ]
          : [
              for (final e in directory)
                if (e.teams.any((t) => teamSet.contains(t.id))) e,
            ];
      restriction = placesOfPeople(people, locations);
    }

    return WhoCascade(
      pool: pool,
      teams: effTeams,
      members: effMembers,
      heldTeams: [for (final t in teams) if (!effTeams.contains(t)) t],
      heldMembers: [for (final m in members) if (!effMembers.contains(m)) m],
      teamMembers: teamMembers,
      placeRestriction: restriction,
      placeApplies: placeApplies,
    );
  }
}
