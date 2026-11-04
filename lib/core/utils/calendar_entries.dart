import '../../models/audit_model.dart';
import '../../models/nc_model.dart';
import 'audit_date_range.dart';
import 'audit_status.dart';

/// The three kinds of thing on the Calendar — each a LAYER the person can switch
/// off, the phone's twin of the web Calendar's `LAYERS` (client/src/pages/
/// Calendar.jsx):
///
///   mine      my own audits, whatever their status
///   location  every audit at one of MY places, whoever audits (the ones I am
///             the auditee of included)
///   nc        my own non-conformances, on the day raised and the day due
///
/// Listed in the order a day shows them: the audits first (they are what is
/// scheduled), the NCs after.
enum CalendarLayer {
  mine('My audits', 'Your own audits, whatever their status'),
  location('Audit at My Location', 'Every audit at your places, and who is coming to audit'),
  nc('My NCs', 'Non-conformances raised against you, on the day raised and the day due');

  const CalendarLayer(this.label, this.hint);

  final String label;
  final String hint;
}

/// What one item on a day is: an audit (once per day it is live), or one of an
/// NC's two dates — a closed NC keeps both, so the day it landed and the day it
/// is due are each visible.
enum CalendarEntryKind { audit, ncRaised, ncDue }

/// One thing on one day of the Calendar.
class CalendarEntry {
  final CalendarEntryKind kind;

  /// The local calendar day, time stripped.
  final DateTime day;
  final AuditModel? audit;
  final NcModel? nc;

  /// The layers it belongs to. An audit belongs to EVERY layer it fits — mine
  /// if I audit it, "at my location" if it happens at one of my places — so an
  /// audit I do at my own place counts (and can be switched on or off) under
  /// both, yet is plotted once. It is on screen while any of its layers is on.
  final Set<CalendarLayer> layers;

  /// Somebody else's audit at my place where I am the one being audited.
  final bool iAmAuditee;

  /// Which day of a multi-day audit this is (1-based), and how many days it
  /// spans — 1 of 1 for a single-day audit and for an NC.
  final int dayNumber;
  final int dayCount;

  const CalendarEntry({
    required this.kind,
    required this.day,
    required this.layers,
    this.audit,
    this.nc,
    this.iAmAuditee = false,
    this.dayNumber = 1,
    this.dayCount = 1,
  });

  bool get isAudit => kind == CalendarEntryKind.audit;
  bool get isNc => !isAudit;
  bool get isMine => layers.contains(CalendarLayer.mine);
  bool get atMyLocation => layers.contains(CalendarLayer.location);

  /// An audit that is NOT mine — somebody else auditing at my place, so "who is
  /// coming" is the question the card answers first.
  bool get isOthers => isAudit && !isMine;

  /// The audit's or NC's own id: every day of one audit shares it.
  String get recordId => isAudit ? audit!.id : nc!.id;

  /// Unique per plotted item (an NC has a raised and a due entry).
  String get id => isAudit ? '${audit!.id}@${calendarDayKey(day)}' : '${nc!.id}:${kind.name}';

  bool get isMultiDay => dayCount > 1;

  /// The status label an audit is drawn in (the server's displayStatus), '' for an NC.
  String get statusLabel => isAudit ? audit!.displayLabel : '';

  /// Whether any of its layers is switched on.
  bool shownIn(Set<CalendarLayer> on) => layers.any(on.contains);

  /// The layer it is listed under where it may appear only once (the order
  /// inside a day, the mark on a day cell): its first layer that is on.
  CalendarLayer primaryLayer(Set<CalendarLayer> on) {
    for (final layer in CalendarLayer.values) {
      if (layers.contains(layer) && on.contains(layer)) return layer;
    }
    return layers.first;
  }
}

/// `2026-11-03`, the key a day is looked up by.
String calendarDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Everything the Calendar plots, from the three lists it is given.
///
///  * [myAudits] — GET /audits/mine (this employee as auditor);
///  * [atMyLocation] — GET /audits/at-my-location (every audit at this
///    employee's places, whoever audits — mine included);
///  * [ncs] — GET /ncs/mine (NCs raised against this employee).
///
/// An audit is plotted ONCE per day, however many of the lists hold it: one in
/// both [myAudits] and [atMyLocation] is a single entry that belongs to both
/// layers (the web's `atMyLocationIds`). An audit lasting several days has an
/// entry on each of them (at most [maxAuditRangeDays]). An audit with no
/// scheduled date cannot be placed and is left out, as on the web. An NC is
/// plotted on the day it was raised and on its due date.
List<CalendarEntry> buildCalendarEntries({
  required List<AuditModel> myAudits,
  required List<AuditModel> atMyLocation,
  required List<NcModel> ncs,
  String? selfEmployeeId,
}) {
  final entries = <CalendarEntry>[];
  final locationIds = {for (final a in atMyLocation) a.id};
  final planted = <String>{};

  void addAudit(AuditModel a, Set<CalendarLayer> layers) {
    if (a.scheduledDate == null || !planted.add(a.id)) return;
    final days = daysInAuditRange(a);
    final iAmAuditee = selfEmployeeId != null && selfEmployeeId.isNotEmpty && a.auditeeIdList.contains(selfEmployeeId);
    for (var i = 0; i < days.length; i++) {
      entries.add(CalendarEntry(
        kind: CalendarEntryKind.audit,
        day: days[i],
        audit: a,
        layers: layers,
        iAmAuditee: iAmAuditee,
        dayNumber: i + 1,
        dayCount: days.length,
      ));
    }
  }

  for (final a in myAudits) {
    addAudit(a, {CalendarLayer.mine, if (locationIds.contains(a.id)) CalendarLayer.location});
  }
  for (final a in atMyLocation) {
    addAudit(a, {CalendarLayer.location});
  }

  final seenNcs = <String>{};
  for (final nc in ncs) {
    if (!seenNcs.add(nc.id)) continue;
    // The server stores UTC instants: bucket by the LOCAL day the person sees on
    // their own calendar (the same day Formatters prints), not by the UTC day.
    for (final (kind, at) in [
      (CalendarEntryKind.ncRaised, nc.startDate),
      (CalendarEntryKind.ncDue, nc.targetDate),
    ]) {
      if (at == null) continue;
      entries.add(CalendarEntry(
        kind: kind,
        day: dayOnly(at.toLocal()),
        nc: nc,
        layers: const {CalendarLayer.nc},
      ));
    }
  }
  return entries;
}

/// The entries that are on screen under [on], grouped by day, each day in the
/// order the layers are listed (audits first, NCs last) and then by what is most
/// pressing: audits by their schedule, NCs due before NCs raised.
Map<DateTime, List<CalendarEntry>> entriesByDay(List<CalendarEntry> entries, Set<CalendarLayer> on) {
  final map = <DateTime, List<CalendarEntry>>{};
  for (final e in entries) {
    if (!e.shownIn(on)) continue;
    map.putIfAbsent(e.day, () => []).add(e);
  }
  for (final list in map.values) {
    list.sort((a, b) {
      final byLayer = a.primaryLayer(on).index.compareTo(b.primaryLayer(on).index);
      if (byLayer != 0) return byLayer;
      if (a.isAudit && b.isAudit) {
        final byDate = (a.audit!.scheduledDate ?? a.day).compareTo(b.audit!.scheduledDate ?? b.day);
        if (byDate != 0) return byDate;
        return a.audit!.title.toLowerCase().compareTo(b.audit!.title.toLowerCase());
      }
      final byKind = a.kind.index.compareTo(b.kind.index);
      if (byKind != 0) return -byKind; // due before raised
      return a.nc!.title.toLowerCase().compareTo(b.nc!.title.toLowerCase());
    });
  }
  return map;
}

/// What each layer holds in the month on screen (not the grid's neighbouring
/// days) — the numbers on the layer chips. Counted per audit / per NC, not per
/// day an audit is live: a five-day audit is one audit.
class CalendarMonthCounts {
  final int mine;
  final int location;
  final int nc;
  final int ncRaised;
  final int ncDue;

  const CalendarMonthCounts({this.mine = 0, this.location = 0, this.nc = 0, this.ncRaised = 0, this.ncDue = 0});

  int of(CalendarLayer layer) => switch (layer) {
        CalendarLayer.mine => mine,
        CalendarLayer.location => location,
        CalendarLayer.nc => nc,
      };

  factory CalendarMonthCounts.of(List<CalendarEntry> entries, DateTime month) {
    final audits = {for (final l in CalendarLayer.values) l: <String>{}};
    final ncs = <String>{};
    var raised = 0;
    var due = 0;
    for (final e in entries) {
      if (e.day.year != month.year || e.day.month != month.month) continue;
      if (e.isAudit) {
        for (final l in e.layers) {
          audits[l]!.add(e.recordId);
        }
      } else {
        ncs.add(e.recordId);
        if (e.kind == CalendarEntryKind.ncRaised) {
          raised++;
        } else {
          due++;
        }
      }
    }
    return CalendarMonthCounts(
      mine: audits[CalendarLayer.mine]!.length,
      location: audits[CalendarLayer.location]!.length,
      nc: ncs.length,
      ncRaised: raised,
      ncDue: due,
    );
  }
}

/// How pressing a status is when a day cell can draw only one colour for a
/// layer: the worst one wins.
const _urgency = [
  AuditStatus.overdue,
  AuditStatus.ncResponsePending,
  AuditStatus.ncVerificationPending,
  AuditStatus.inProgress,
  AuditStatus.notStarted,
  AuditStatus.draft,
  AuditStatus.notAttempted,
  AuditStatus.skipped,
  AuditStatus.totalClosed,
];

/// The most pressing status among [entries]' audits, or null when there are none.
String? mostUrgentStatus(Iterable<CalendarEntry> entries) {
  String? best;
  var bestRank = 1 << 30;
  for (final e in entries) {
    if (!e.isAudit) continue;
    final label = e.statusLabel;
    final rank = _urgency.indexOf(label);
    final effective = rank < 0 ? _urgency.length : rank;
    if (effective < bestRank) {
      best = label;
      bestRank = effective;
    }
  }
  return best;
}

/// "10 Nov 2026" for one day, "10 – 14 Nov 2026" within a month,
/// "28 Oct – 3 Nov 2026" within a year, both years in full across years.
String calendarRangeLabel(DateTime start, [DateTime? end]) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  String d(DateTime x) => '${x.day} ${months[x.month - 1]}';
  final s = dayOnly(start);
  final e = end == null ? s : dayOnly(end);
  if (!e.isAfter(s)) return '${d(s)} ${s.year}';
  if (s.year != e.year) return '${d(s)} ${s.year} – ${d(e)} ${e.year}';
  if (s.month != e.month) return '${d(s)} – ${d(e)} ${e.year}';
  return '${s.day} – ${d(e)} ${e.year}';
}
