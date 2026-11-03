import 'report_sheet_spec.dart';

/// utils/report_filter_lines.dart
/// ────────────────────────────────
/// Turns a screen's filter state into the plain-words "Filters applied" lines of
/// an Excel download's Summary sheet, so a file opened next month still says WHICH
/// people / places / dates it covers. The Dart twin of the web app's
/// client/src/utils/reportFilters.js (describeFilters / describePeople /
/// labelsForIds): pure — the caller looks the ids up to names and hands the names
/// in.
///
/// Every list follows the app's filter convention: empty = All, a lone
/// [noneSelected] = nothing picked.

/// The "match nobody" pick — a Team with no members (AuditFilterScope.noneSentinel).
const noneSelected = '__none__';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "05 Oct 2026".
String formatPickedDay(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')} ${_months[day.month - 1]} ${day.year}';

/// "05 Oct 2026 to 09 Oct 2026", "From …", "Up to …", or [allText].
String describeDateRange(DateTime? from, DateTime? to, {String allText = 'All dates'}) {
  final a = from == null ? '' : formatPickedDay(from);
  final b = to == null ? '' : formatPickedDay(to);
  if (a.isNotEmpty && b.isNotEmpty) return a == b ? a : '$a to $b';
  if (a.isNotEmpty) return 'From $a';
  if (b.isNotEmpty) return 'Up to $b';
  return allText;
}

/// "A, B, C" — and "A, B, C and 4 more" once a list is longer than [max].
String namesText(List<String> names, {int max = 12}) {
  final list = names.where((n) => n.isNotEmpty).toList();
  if (list.length <= max) return list.join(', ');
  return '${list.take(max).join(', ')} and ${list.length - max} more';
}

/// A picked list in words: [] -> [allText], [noneSelected] -> "None selected", else the names.
String pickedText(List<String>? list, String allText) {
  if (list == null || list.isEmpty) return allText;
  if (list.length == 1 && list.first == noneSelected) return 'None selected';
  return namesText(list);
}

/// A picked id list as names. If the lookup cannot name every id (its list did not
/// load), says how many were picked instead of printing a shorter list that reads
/// like the whole pick.
List<String> labelsForIds(List<String> ids, Map<String, String> lookup, String noun) {
  if (ids.isEmpty) return const [];
  if (ids.length == 1 && ids.first == noneSelected) return const [noneSelected];
  final names = [for (final id in ids) ?lookup[id]];
  if (names.length < ids.length) return ['${ids.length} $noun${ids.length == 1 ? '' : 's'} selected'];
  return names;
}

/// Who the export covers. [employeeIds] is what the request carried (null = no
/// `employeeIds` at all = All Members), [names] the directory (id -> name).
String describePeople({
  required String? employeeIds,
  required Map<String, String> names,
  String? selfId,
}) {
  final raw = employeeIds?.trim() ?? '';
  if (raw.isEmpty) return 'All members';
  final ids = raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (ids.isEmpty || (ids.length == 1 && ids.first == noneSelected)) return 'No one';
  final list = [for (final id in ids) ?names[id]];
  if (ids.length == 1 && selfId != null && ids.first == selfId) {
    return list.isNotEmpty ? 'Only me (${list.first})' : 'Only me';
  }
  // A directory that has not told every name: say how many people rather than a half list.
  if (list.length < ids.length) return '${ids.length} ${ids.length == 1 ? 'person' : 'people'}';
  return namesText(list, max: 15);
}

/// The lines, in the order the filter bar shows them. Only what the tab actually
/// has is listed: a tab without a Team filter passes no [teams] / [people].
///
/// - [teams]       team names, [] = all teams, null = this tab has no Team filter
/// - [people]      who: "All members", "Only me (Asha)", or the names
/// - [locations]   location names, [] = all (null = no such filter)
/// - [departments] department names (shown only when picked)
/// - [auditTypes]  audit type names, [] = all
/// - [flags]       Major / Minor, [] = both (null = the tab has no Flag filter)
/// - [statuses]    status names, [] = all (null = the tab has no Status filter)
/// - [tiles]       the stat tiles that are lit (their labels), [] = none (null = no tiles)
/// - [dateText]    the date line, already worded
/// - [extra]       more lines, appended
List<ReportFilterLine> describeReportFilters({
  List<String>? teams,
  String? people,
  List<String>? locations,
  List<String> departments = const [],
  List<String>? auditTypes,
  List<String>? flags,
  List<String>? statuses,
  List<String>? tiles,
  String? dateText,
  String? search,
  List<ReportFilterLine> extra = const [],
}) {
  final lines = <ReportFilterLine>[];
  if (teams != null) lines.add(('Team', pickedText(teams, 'All teams')));
  if (people != null && people.isNotEmpty) lines.add(('Members', people));
  if (locations != null) {
    // Location and Department are ONE "where" filter: departments picked with no
    // location is NOT "All locations" — it is departments only.
    final departmentsOnly = locations.isEmpty && departments.isNotEmpty;
    lines.add(('Location', departmentsOnly ? 'None — departments only' : pickedText(locations, 'All locations')));
  }
  if (departments.isNotEmpty) lines.add(('Department', pickedText(departments, 'All departments')));
  if (auditTypes != null) lines.add(('Audit Type', pickedText(auditTypes, 'All audit types')));
  if (flags != null) lines.add(('Flag', pickedText(flags, 'Major and Minor')));
  if (statuses != null) lines.add(('Status', pickedText(statuses, 'All statuses')));
  if (tiles != null) lines.add(('Stat tile', tiles.isNotEmpty ? namesText(tiles) : 'None (everything)'));
  if (dateText != null && dateText.isNotEmpty) lines.add(('Date range', dateText));
  if (search != null && search.trim().isNotEmpty) lines.add(('Search', '"${search.trim()}"'));
  lines.addAll(extra);
  return lines;
}
