import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme/app_colors.dart';
import '../core/utils/formatters.dart';
import '../models/audit_model.dart';
import '../screens/audits/audit_detail_screen.dart';
import 'status_badge.dart';

/// widgets/audit_agenda.dart
/// ──────────────────────────
/// The bucketing rules and section widgets behind the Audits tab's
/// time-anchored agenda (screens/audits/my_audits_screen.dart).
///
/// The tab used to be a flat "newest scheduled date first" list of
/// collapsible date groups, which answered "what is the most recently
/// scheduled thing" — not the question an auditor actually opens this tab
/// with, which is "what do I have to do today, and what is about to land
/// on me". So the list is now anchored on TODAY: the next seven days are
/// broken out day by day (that's the window someone can actually act on),
/// everything further out is summarised a month at a time, and the past
/// sits ABOVE today, reachable by scrolling up rather than by scrolling
/// past it to reach today.
///
/// Everything above the widgets is a pure top-level function taking the
/// audit list plus an explicit `today`, deliberately: the bucket rules are
/// the whole point of this feature, and keeping them out of a State class
/// (and off `DateTime.now()`) means they can be read in one place and
/// exercised from a test with a fixed date instead of only at midnight.

/// A date with its time-of-day stripped, so two audits on the same
/// calendar day land in the same bucket regardless of the time component
/// the server happened to store (audits are scheduled by DAY in this
/// product; the time part is noise inherited from the ISO string).
DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// First-of-month, the canonical key for a month bucket.
DateTime monthOnly(DateTime d) => DateTime(d.year, d.month);

// Month ordinal, so "is this a LATER calendar month" is one integer
// comparison instead of a year-then-month pair of them (and so December →
// January of the next year compares correctly, which a bare month
// comparison would get wrong).
int _monthOrdinal(DateTime d) => d.year * 12 + d.month;

/// An audit nobody has wrapped up whose DUE date is already behind us —
/// the same rule the dashboard's own overdue mini-list uses
/// (widgets/today_audits_section.dart#_overdueAudits: `scheduledEndDate ??
/// scheduledDate`) and the server's own plan-bucket derivation
/// (server/utils/auditStatus.js#derivePlanBucket: `scheduledEndDate ||
/// scheduledDate`). There is no server-side plan-bucket endpoint backing
/// this on mobile, so every surface that judges overdue-ness has to derive
/// it client-side identically, or the same audit reads "overdue" on one
/// screen and "in progress, on schedule" on another.
///
/// This deliberately does NOT read the same field the BUCKETING below
/// groups by. Bucketing groups by `scheduledDate` (the period START) only
/// — see buildAuditAgenda's own comment on why a multi-day audit still
/// gets exactly one bucket instead of being spread across every day it
/// spans — so a still-live multi-day audit that started days ago can
/// legitimately sit in a past month's group. That's fine on its own; what
/// would NOT be fine is also painting it with a red "Overdue" pill while
/// it's still within its own end date, which is what reading
/// `scheduledDate` here instead of the due date used to do.
bool isAuditOverdue(AuditModel audit, DateTime today) {
  if (audit.status == 'Completed' || audit.status == 'Skipped') {
    return false;
  }
  final due = audit.scheduledEndDate ?? audit.scheduledDate;
  if (due == null) {
    return false;
  }
  return dayOnly(due).isBefore(dayOnly(today));
}

/// One calendar day's audits — the unit inside the seven-day window.
class AuditDayGroup {
  final DateTime day;
  final List<AuditModel> audits;

  const AuditDayGroup({required this.day, required this.audits});
}

/// One calendar month's audits — the unit for everything outside the
/// seven-day window, in both directions.
class AuditMonthGroup {
  final DateTime month;
  final List<AuditModel> audits;

  const AuditMonthGroup({required this.month, required this.audits});
}

/// The whole tab's content, already bucketed and sorted. Built once per
/// build from the (status-filtered) provider list — cheap enough at the
/// size a single auditor's list ever reaches that memoising it would cost
/// more in staleness bugs than it saves in frames.
class AuditAgenda {
  /// The day the agenda was built around — every widget below takes this
  /// rather than calling DateTime.now() itself, so a list built just
  /// before midnight can't render a "Today" header for one day and
  /// overdue stripes computed against another.
  final DateTime today;

  /// today + 7 days: the last day still shown as its own day group.
  final DateTime horizon;

  /// Past audits grouped by month, OLDEST FIRST. The past region renders
  /// as a normal top-to-bottom Column whose bottom edge sits against
  /// Today, so oldest-first puts the oldest month at the visual top and
  /// the most recent month directly above Today — nearest in time is
  /// nearest on screen, in both directions away from the anchor.
  final List<AuditMonthGroup> pastMonths;

  final List<AuditModel> todayAudits;

  /// Tomorrow through today+7, one entry per day that actually has
  /// audits (empty days are simply absent — a week of empty headers
  /// would push the real content off screen for no information).
  final List<AuditDayGroup> nextSevenDays;

  /// Same calendar month as today but beyond the seven-day window.
  final List<AuditModel> restOfThisMonth;

  /// Every month after this one that has anything, earliest first.
  final List<AuditMonthGroup> laterMonths;

  /// scheduledDate == null — typically a Draft that was never scheduled.
  /// It has no place on a timeline, so it gets its own group pinned at
  /// the very bottom rather than being silently dropped.
  final List<AuditModel> undated;

  const AuditAgenda({
    required this.today,
    required this.horizon,
    required this.pastMonths,
    required this.todayAudits,
    required this.nextSevenDays,
    required this.restOfThisMonth,
    required this.laterMonths,
    required this.undated,
  });

  int get pastCount =>
      pastMonths.fold<int>(0, (sum, m) => sum + m.audits.length);

  /// How many of the past audits are still open — the number that earns
  /// the red pill on the collapsed past row. This is the one piece of
  /// information the past region must surface WITHOUT being expanded:
  /// "there are 12 old audits" is background noise, "3 of them are still
  /// not done" is the reason to scroll up at all.
  int get pastOverdueCount => pastMonths.fold<int>(
        0,
        (sum, m) => sum + m.audits.where((a) => isAuditOverdue(a, today)).length,
      );

  /// True when there is nothing at all to show — note Today itself is
  /// still rendered in that case (see AgendaTodaySection), so this is only
  /// useful for callers deciding whether to show a whole-screen empty
  /// state instead of the agenda.
  bool get isEmpty =>
      pastMonths.isEmpty &&
      todayAudits.isEmpty &&
      nextSevenDays.isEmpty &&
      restOfThisMonth.isEmpty &&
      laterMonths.isEmpty &&
      undated.isEmpty;
}

// Ascending by scheduled date, then title — a stable order so two audits
// on the same day don't swap places between rebuilds (the server's own
// sort only orders by date, leaving same-day ties to arrive in whatever
// order Mongo returned them, which can differ between two fetches).
int _byDateThenTitle(AuditModel a, AuditModel b) {
  final ad = a.scheduledDate;
  final bd = b.scheduledDate;
  if (ad != null && bd != null) {
    final cmp = ad.compareTo(bd);
    if (cmp != 0) {
      return cmp;
    }
  }
  return a.title.toLowerCase().compareTo(b.title.toLowerCase());
}

/// Buckets `audits` around `today`. The rules, in one place:
///
///   undated         scheduledDate == null              -> bottom group
///   past            day  <  today                      -> grouped by month
///   todayAudits     day  == today
///   nextSevenDays   today <  day <= horizon             -> grouped by day
///   restOfThisMonth day  >  horizon, same month as today
///   laterMonths     day  >  horizon, a later month      -> grouped by month
///
/// THE ONE NON-OBVIOUS EDGE: everything after the seven-day window is
/// selected by the single test `day > horizon`, never by "is it in a
/// later month". That is deliberate and must stay that way, because it is
/// what makes the case where the seven-day window SPILLS INTO NEXT MONTH
/// come out right. Run today = 28 Sep through it: horizon is 5 Oct, so
/// 29 Sep–5 Oct are already showing as their own day groups;
/// restOfThisMonth is then simply empty (there is no September day after
/// 5 Oct), and October's month bucket correctly starts at 6 Oct instead
/// of listing 1–5 Oct a second time under "October 2026". Had the month
/// buckets been picked by month instead, that first week of October would
/// appear twice, once per day and once in bulk.
AuditAgenda buildAuditAgenda(List<AuditModel> audits, DateTime today) {
  final day0 = dayOnly(today);
  // DateTime(y, m, d + 7) rather than day0.add(Duration(days: 7)): adding
  // a Duration adds exact elapsed time, so crossing a daylight-saving
  // boundary lands on 23:00 of the sixth day and quietly shrinks the
  // window by a day. The constructor normalises overflowing day numbers
  // (e.g. 28 Sep + 7 -> 5 Oct) on the calendar, which is what "seven days
  // out" means here.
  final horizon = DateTime(day0.year, day0.month, day0.day + 7);
  final todayOrdinal = _monthOrdinal(day0);

  final undated = <AuditModel>[];
  final todayAudits = <AuditModel>[];
  final restOfThisMonth = <AuditModel>[];
  final pastByMonth = <DateTime, List<AuditModel>>{};
  final byDay = <DateTime, List<AuditModel>>{};
  final laterByMonth = <DateTime, List<AuditModel>>{};

  for (final audit in audits) {
    final scheduled = audit.scheduledDate;
    // Bucketed on scheduledDate (the period START) only, never on
    // scheduledEndDate, even though a multi-day audit has one: it is the
    // same field the previous version of this screen grouped by and the
    // same field the server sorts /audits/mine by, so an audit sits on
    // the day the rest of the app already says it sits on. Spreading a
    // multi-day audit across every day it spans (which the dashboard's
    // Today section does do, for a different question) would put one
    // audit in several buckets and make the section counts stop adding
    // up to the list length.
    if (scheduled == null) {
      undated.add(audit);
      continue;
    }
    final day = dayOnly(scheduled);
    if (day.isBefore(day0)) {
      pastByMonth.putIfAbsent(monthOnly(day), () => []).add(audit);
    } else if (day == day0) {
      todayAudits.add(audit);
    } else if (!day.isAfter(horizon)) {
      byDay.putIfAbsent(day, () => []).add(audit);
    } else if (_monthOrdinal(day) == todayOrdinal) {
      restOfThisMonth.add(audit);
    } else {
      laterByMonth.putIfAbsent(monthOnly(day), () => []).add(audit);
    }
  }

  List<AuditMonthGroup> months(Map<DateTime, List<AuditModel>> source) {
    final keys = source.keys.toList()..sort();
    return [
      for (final key in keys)
        AuditMonthGroup(
          month: key,
          audits: source[key]!..sort(_byDateThenTitle),
        ),
    ];
  }

  final dayKeys = byDay.keys.toList()..sort();

  return AuditAgenda(
    today: day0,
    horizon: horizon,
    pastMonths: months(pastByMonth),
    todayAudits: todayAudits..sort(_byDateThenTitle),
    nextSevenDays: [
      for (final key in dayKeys)
        AuditDayGroup(day: key, audits: byDay[key]!..sort(_byDateThenTitle)),
    ],
    restOfThisMonth: restOfThisMonth..sort(_byDateThenTitle),
    laterMonths: months(laterByMonth),
    undated: undated
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
  );
}

/// One row in a month group: either a standalone audit
/// (`occurrences.length == 1`) or a whole recurring series collapsed into
/// a single expandable row.
class AgendaEntry {
  /// Ascending by scheduled date; never empty.
  final List<AuditModel> occurrences;

  const AgendaEntry(this.occurrences);

  AuditModel get lead => occurrences.first;

  bool get isSeries => occurrences.length > 1;

  /// "Monthly series · 4 occurrences". `frequency` is a free-text field
  /// server-side, so fall back to a generic word rather than rendering
  /// "null series".
  String get seriesLabel =>
      '${lead.frequency ?? 'Recurring'} series · ${occurrences.length} occurrences';

  /// The span the collapsed row stands in for, so the user can tell what
  /// dates are hiding inside it without expanding.
  String get dateSpan {
    final first = Formatters.date(occurrences.first.scheduledDate);
    final last = Formatters.date(occurrences.last.scheduledDate);
    return first == last ? first : '$first – $last';
  }

  /// "2 Not Started, 1 Completed" — a collapsed series has no single
  /// status to show a badge for, so the badge column becomes a tally.
  /// Same substitution the web app makes (pages/AuditorDashboard.jsx#
  /// seriesStatusSummary).
  String get statusSummary {
    final counts = <String, int>{};
    for (final o in occurrences) {
      counts[o.status] = (counts[o.status] ?? 0) + 1;
    }
    return counts.entries.map((e) => '${e.value} ${e.key}').join(', ');
  }
}

/// Collapses same-series occurrences within ONE month bucket into single
/// rows, leaving everything else as its own row. Mirrors what the web
/// app's AuditorDashboard.jsx does with `seriesGroups` /
/// `renderSeriesHeaderRow`: group on `recurrence.seriesId` — the real
/// link between occurrences of one Frequency Audit — never on the
/// frequency label, so two unrelated "Weekly" series can't collapse into
/// each other.
///
/// Called for month buckets only. Inside a day group the individual
/// occurrence IS the thing being acted on that day, so collapsing there
/// would hide the one card the auditor came to tap; over a whole month,
/// twelve near-identical "Weekly Hygiene Check" cards are noise and the
/// series is the useful unit.
///
/// A series with a single occurrence in this bucket renders as a normal
/// card — a group row standing in for exactly one audit is strictly worse
/// than the audit (an extra tap for less information).
List<AgendaEntry> collapseRecurringSeries(List<AuditModel> audits) {
  final bySeries = <String, List<AuditModel>>{};
  for (final a in audits) {
    if (a.isRecurring) {
      bySeries.putIfAbsent(a.seriesId!, () => []).add(a);
    }
  }
  final entries = <AgendaEntry>[];
  final emitted = <String>{};
  // Walks the already-sorted list so a series row lands at the position
  // of its FIRST occurrence, keeping the month group in date order
  // whether or not any series is involved.
  for (final a in audits) {
    final sid = a.seriesId;
    final members = sid == null ? null : bySeries[sid];
    if (members == null || members.length <= 1) {
      entries.add(AgendaEntry([a]));
      continue;
    }
    if (emitted.add(sid!)) {
      entries.add(AgendaEntry(members));
    }
  }
  return entries;
}

// ── Group keys ──────────────────────────────────────────────────────────
// Expansion state is held as sets of these strings in MyAuditsScreen's
// State (see AgendaExpansion) rather than as DateTime keys, so the sets
// stay printable/diffable when something goes wrong and can never be
// missed by a stray UTC-vs-local DateTime that compares unequal despite
// naming the same day.

String agendaDayKey(DateTime day) => 'day:${day.year}-${day.month}-${day.day}';

String agendaMonthKey(DateTime month) => 'month:${month.year}-${month.month}';

String agendaSeriesKey(String groupKey, String seriesId) =>
    '$groupKey/series:$seriesId';

/// Which agenda groups the user has opened or closed.
///
/// Lives in MyAuditsScreen's State object, not in each section widget:
/// AppShell keeps the Audits tab alive across tab swipes
/// (screens/root/app_shell.dart#_KeepAlivePage), and this is exactly the
/// kind of state that keep-alive is for — coming back to the tab and
/// finding every group the user opened slammed shut again would make the
/// whole PageView feel like it reloads on every swipe.
///
/// Everything defaults CLOSED except Today itself — Today isn't part of
/// this class at all (AgendaTodaySection always renders every one of
/// today's audits inline, with no collapse toggle of its own), so a set
/// that starts empty is already a correct fresh state for every group
/// this class DOES track: every day in the seven-day window, every month
/// (past or future), and the past region as a whole all open collapsed,
/// storing only which ones the user has explicitly opened.
class AgendaExpansion {
  final Set<String> expandedDays = <String>{};
  final Set<String> expandedMonths = <String>{};
  final Set<String> expandedSeries = <String>{};

  /// The past region stays shut until asked for — see AgendaPastRegion.
  bool pastExpanded = false;

  bool isDayExpanded(String key) => expandedDays.contains(key);

  bool isMonthExpanded(String key) => expandedMonths.contains(key);

  bool isSeriesExpanded(String key) => expandedSeries.contains(key);

  void toggleDay(String key) {
    if (!expandedDays.remove(key)) {
      expandedDays.add(key);
    }
  }

  void toggleMonth(String key) {
    if (!expandedMonths.remove(key)) {
      expandedMonths.add(key);
    }
  }

  void toggleSeries(String key) {
    if (!expandedSeries.remove(key)) {
      expandedSeries.add(key);
    }
  }
}

final DateFormat _dayHeaderFormat = DateFormat('EEE d MMM');
final DateFormat _monthHeaderFormat = DateFormat('MMMM yyyy');

/// 'Today' / 'Tomorrow' / 'Thu 11 Sep' — the relative words only for the
/// two days a person actually thinks about in relative terms; anything
/// further out is easier to place by its real weekday and date.
String agendaDayLabel(DateTime day, DateTime today) {
  final diff = dayOnly(day).difference(dayOnly(today)).inDays;
  if (diff == 0) {
    return 'Today';
  }
  if (diff == 1) {
    return 'Tomorrow';
  }
  return _dayHeaderFormat.format(day);
}

String agendaMonthLabel(DateTime month) => _monthHeaderFormat.format(month);

// ── Section widgets ─────────────────────────────────────────────────────

/// The collapsible group header, visually unchanged from the one this
/// agenda replaced (rounded 10, surfaceContainerHighest at half alpha
/// when shut / primaryContainer at 0.35 when open, event icon, count
/// pill, chevron) — the rest of the screen changed enough that keeping
/// the header's look identical is what makes it still read as the same
/// Audits tab.
class AgendaSectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool expanded;
  final VoidCallback onTap;
  final IconData icon;

  const AgendaSectionHeader({
    super.key,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    this.icon = Icons.event_outlined,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: expanded
              ? scheme.primaryContainer.withValues(alpha: 0.35)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: scheme.outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            _CountPill(count: count),
            const SizedBox(width: 6),
            Icon(
              expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

class _CountPill extends StatelessWidget {
  final int count;

  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: scheme.outline,
        ),
      ),
    );
  }
}

/// The anchor. Deliberately louder than every other header — a filled
/// primary-container bar with the weekday spelled out ("Today · Thu
/// 4 Sep") — because the entire layout is built around this one row being
/// where the eye lands on first paint. A header that looked like all the
/// others would leave the user with no way to tell, at a glance, whether
/// what they are looking at is today or some month in the middle.
///
/// ALWAYS rendered and ALWAYS expanded, including on a day with nothing
/// scheduled, where it shows a quiet "Nothing scheduled today." instead.
/// Hiding it on an empty day would move the anchor to whatever section
/// happened to be next, i.e. the screen would open somewhere different
/// depending on the data — the exact thing this rebuild set out to fix.
class AgendaTodaySection extends StatelessWidget {
  final DateTime today;
  final List<AuditModel> audits;

  /// True when Today AND every forward-looking bucket (next 7 days, rest
  /// of this month, later months, undated) are all empty while the PAST
  /// region is not — i.e. every audit currently on screen is hidden above
  /// the fold in the collapsed "Past audits" row. Without this, filtering
  /// (a status chip, or a dashboard tile jump straight to "Completed")
  /// down to a list that happens to be entirely past-dated renders as a
  /// screen that just says "Nothing scheduled today." with nothing else
  /// visible at all — indistinguishable from a genuinely empty list, even
  /// though the data the user came here to see is one scroll-up away.
  final bool hasHiddenPastContent;

  /// Expands the past region and scrolls up to it. Only meaningful (and
  /// only rendered) alongside [hasHiddenPastContent].
  final VoidCallback? onViewPast;

  const AgendaTodaySection({
    super.key,
    required this.today,
    required this.audits,
    this.hasHiddenPastContent = false,
    this.onViewPast,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.today_rounded, size: 18,
                  color: scheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Today · ${_dayHeaderFormat.format(today)}',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: scheme.onPrimaryContainer,
                      ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '${audits.length}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (audits.isEmpty && hasHiddenPastContent)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: InkWell(
              onTap: onViewPast,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_upward_rounded,
                      size: 15, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    'Nothing scheduled today — past audits above',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
            ),
          )
        else if (audits.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(
              'Nothing scheduled today.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          )
        else
          for (final audit in audits) ...[
            RepaintBoundary(
              child: AgendaAuditCard(
                audit: audit,
                today: today,
                showDate: false,
              ),
            ),
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

/// One day inside the seven-day window. Its cards start COLLAPSED —
/// Today (rendered separately, see AgendaTodaySection, always expanded)
/// is the only section that opens by default; every OTHER day here is a
/// scannable header (label + count) first, tapped open only for the day
/// actually being planned around right now.
class AgendaDaySection extends StatelessWidget {
  final AuditDayGroup group;
  final DateTime today;
  final bool expanded;
  final VoidCallback onToggle;

  const AgendaDaySection({
    super.key,
    required this.group,
    required this.today,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AgendaSectionHeader(
          label: agendaDayLabel(group.day, today),
          count: group.audits.length,
          expanded: expanded,
          onTap: onToggle,
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          for (final audit in group.audits) ...[
            // Inside a single-day group the card's own date would repeat
            // the header it is sitting under, so that slot shows the
            // auditor / audit type instead (see AgendaAuditCard).
            RepaintBoundary(
              child: AgendaAuditCard(
                audit: audit,
                today: today,
                showDate: false,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 4),
      ],
    );
  }
}

/// A month bucket — past, "rest of this month", or a later month. Starts
/// COLLAPSED: a month is a summary, not a to-do list, and a hundred cards
/// unrolled between Today and next month would bury the part of the
/// screen that matters. Recurring series inside it collapse further, into
/// one row per series.
class AgendaMonthSection extends StatelessWidget {
  final String label;
  final String groupKey;
  final List<AuditModel> audits;
  final DateTime today;
  final AgendaExpansion expansion;

  /// Called after `expansion` has been mutated, so the owning State can
  /// setState — the expansion object itself is not a Listenable, it is
  /// plain state living in MyAuditsScreen.
  final VoidCallback onChanged;

  const AgendaMonthSection({
    super.key,
    required this.label,
    required this.groupKey,
    required this.audits,
    required this.today,
    required this.expansion,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final expanded = expansion.isMonthExpanded(groupKey);
    final entries =
        expanded ? collapseRecurringSeries(audits) : const <AgendaEntry>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AgendaSectionHeader(
          label: label,
          // The COUNT stays the audit count, not the collapsed-row count:
          // "September 2026 · 12" has to mean twelve audits, or the
          // section headers stop adding up to the list the user is
          // filtering.
          count: audits.length,
          expanded: expanded,
          onTap: () {
            expansion.toggleMonth(groupKey);
            onChanged();
          },
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          for (final entry in entries) ...[
            if (entry.isSeries)
              AgendaSeriesGroup(
                entry: entry,
                today: today,
                groupKey: groupKey,
                expansion: expansion,
                onChanged: onChanged,
              )
            else
              RepaintBoundary(
                child: AgendaAuditCard(audit: entry.lead, today: today),
              ),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 4),
      ],
    );
  }
}

/// The collapsed stand-in for a whole recurring series inside one month:
/// the series title, `"<Frequency> series · N occurrences"`, the span its
/// occurrences cover and a per-status tally, expanding to the real cards.
///
/// Like the web app's `renderSeriesHeaderRow`, this row deliberately
/// carries no action of its own and never navigates: there is no single
/// occurrence a tap could unambiguously open, so the only thing it does
/// is reveal the occurrences that do.
class AgendaSeriesGroup extends StatelessWidget {
  final AgendaEntry entry;
  final DateTime today;
  final String groupKey;
  final AgendaExpansion expansion;
  final VoidCallback onChanged;

  const AgendaSeriesGroup({
    super.key,
    required this.entry,
    required this.today,
    required this.groupKey,
    required this.expansion,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final key = agendaSeriesKey(groupKey, entry.lead.seriesId!);
    final expanded = expansion.isSeriesExpanded(key);
    // Any still-open occurrence whose date has passed makes the whole
    // collapsed row worth flagging — otherwise an overdue audit could
    // hide inside a series row that looks perfectly calm.
    final overdue = entry.occurrences.any((a) => isAuditOverdue(a, today));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              expansion.toggleSeries(key);
              onChanged();
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.repeat_rounded,
                          size: 16, color: scheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.lead.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (overdue) ...[
                        const SizedBox(width: 6),
                        const _OverduePill(),
                      ],
                      const SizedBox(width: 6),
                      Icon(
                        expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: scheme.outline,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.seriesLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.date_range_outlined,
                          size: 14, color: scheme.outline),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          entry.dateSpan,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.outline),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.statusSummary,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.outline, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          // Indented so an expanded series still reads as belonging to
          // the row above it rather than as a fresh top-level list, same
          // as the web table's indented occurrence rows.
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final audit in entry.occurrences) ...[
                  RepaintBoundary(
                    child: AgendaAuditCard(audit: audit, today: today),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _OverduePill extends StatelessWidget {
  const _OverduePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'Overdue',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.red,
        ),
      ),
    );
  }
}

/// The agenda's audit card — the previous screen's card, kept
/// deliberately familiar, plus the three things the agenda needs it to
/// carry: the audit type, an overdue marking, and a date slot that turns
/// into something more useful when the date is already in the header
/// above it.
class AgendaAuditCard extends StatelessWidget {
  final AuditModel audit;
  final DateTime today;

  /// False inside a single-day group, where repeating the group's own
  /// date on every card is wasted space; the slot then shows the auditor
  /// (or the audit type) instead.
  final bool showDate;

  const AgendaAuditCard({
    super.key,
    required this.audit,
    required this.today,
    this.showDate = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final overdue = isAuditOverdue(audit, today);
    // The right-hand meta slot: the date when it adds something, else
    // whichever of auditor / audit type this audit actually has. Never
    // blank-but-present — an empty slot with an icon reads as a loading
    // failure.
    final String? trailingMeta = showDate
        ? Formatters.date(audit.scheduledDate)
        : (audit.auditorNames.isNotEmpty
            ? audit.auditorNames.join(', ')
            : audit.auditType);
    final IconData trailingIcon = showDate
        ? Icons.event_outlined
        : (audit.auditorNames.isNotEmpty
            ? Icons.person_outline
            : Icons.category_outlined);

    return Card(
      // Overdue gets a red-tinted border rather than a red fill: the card
      // still has to read as a normal card in a list of them, it just has
      // to be findable at a glance while triaging. The Overdue pill next
      // to the status badge carries the same signal for anyone who can't
      // rely on colour alone.
      shape: overdue
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: AppColors.red.withValues(alpha: 0.55)),
            )
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AuditDetailScreen(auditId: audit.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      audit.title,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusBadge(
                    label: audit.status,
                    color: AppColors.forAuditStatus(audit.status),
                  ),
                ],
              ),
              if (audit.scope.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  audit.scope,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.outline),
                ),
              ],
              if (audit.auditType != null || overdue) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // A muted chip, not a coloured badge: the type is
                    // context for scanning a busy day, it must not
                    // compete with the status badge that tells the
                    // auditor whether there is anything left to do.
                    if (audit.auditType != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest
                              .withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          audit.auditType!,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (overdue) const _OverduePill(),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.place_outlined, size: 15, color: scheme.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      audit.location.isNotEmpty
                          ? audit.location
                          : 'No location set',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                audit.location.isNotEmpty ? null : scheme.outline,
                            fontWeight: audit.location.isNotEmpty
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                    ),
                  ),
                  if (trailingMeta != null) ...[
                    const SizedBox(width: 8),
                    Icon(trailingIcon, size: 14, color: scheme.outline),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(
                        trailingMeta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Past audits · N" — the toggle for everything before today. ALWAYS
/// visible, pinned above the scrollable agenda entirely (a sibling of the
/// CustomScrollView in my_audits_screen.dart's own Column, not one of its
/// slivers) rather than living inside the reverse-growth region it
/// controls.
///
/// It used to be the LAST child of that region's own Column, sitting
/// directly above Today at scroll offset ~0 — which sounds identical to
/// "pinned above the agenda" but is not: with `center: _todayKey` (see
/// AgendaPastRegion's own doc below), the CustomScrollView's resting
/// scroll position on first paint is offset 0, i.e. the TOP of Today's own
/// box — and the past region, sitting in the sliver BEFORE that centre,
/// lays out at NEGATIVE offsets. Its own summary row was therefore already
/// scrolled just off the top of the viewport on first paint, same as
/// everything else in that region — nothing told a user who had not
/// already scrolled up once that six overdue audits were sitting one flick
/// away. A row that is not part of the scroll view at all can't have this
/// problem: it is simply always there, first thing under the status chips,
/// before the user has done anything.
class AgendaPastBar extends StatelessWidget {
  final AuditAgenda agenda;
  final bool expanded;
  final VoidCallback onTap;

  const AgendaPastBar({
    super.key,
    required this.agenda,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (agenda.pastMonths.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final overdue = agenda.pastOverdueCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                size: 18,
                color: scheme.outline,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Past audits · ${agenda.pastCount}',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (overdue > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$overdue overdue',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.red,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Everything before today, living in the sliver ABOVE the centre key —
/// i.e. at negative scroll offsets, reached by scrolling up (or, now,
/// jumped to directly — see my_audits_screen.dart's _togglePast, which
/// AgendaPastBar's own tap runs through instead of touching
/// AgendaExpansion directly).
///
/// Renders NOTHING while collapsed — the toggle row that used to double as
/// this region's always-shown collapsed state moved out to AgendaPastBar
/// above, so this class only ever has one job left: the actual past month
/// sections, and only once AgendaExpansion says to show them. Because a
/// reverse-region sliver is anchored by its BOTTOM edge, this still grows
/// upward into more negative scroll offsets as it appears — Today does not
/// move — which is exactly why _togglePast scrolls up to meet it rather
/// than leaving that to be discovered.
class AgendaPastRegion extends StatelessWidget {
  final AuditAgenda agenda;
  final AgendaExpansion expansion;
  final VoidCallback onChanged;

  const AgendaPastRegion({
    super.key,
    required this.agenda,
    required this.expansion,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (!expansion.pastExpanded || agenda.pastMonths.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final month in agenda.pastMonths)
          AgendaMonthSection(
            label: agendaMonthLabel(month.month),
            groupKey: agendaMonthKey(month.month),
            audits: month.audits,
            today: agenda.today,
            expansion: expansion,
            onChanged: onChanged,
          ),
      ],
    );
  }
}
