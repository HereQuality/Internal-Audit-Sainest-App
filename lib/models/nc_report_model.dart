import 'nc_model.dart';

/// The five buckets every NC falls into — the server's own split (server/utils/
/// ncScoring.js#ncBucketOf), sent on each Final Report row as `bucket` and
/// counted by the six NC tiles: Total NC = the five added up. The device only
/// names them; it never works a bucket out.
class NcBucket {
  NcBucket._();

  static const inProgress = 'inProgress';
  static const overdue = 'overdue';
  static const pendingApproval = 'pendingApproval';
  static const delayed = 'delayed';
  static const onTime = 'onTime';

  /// The tile order on the web's Auditee / Final Report pages and on the
  /// Auditee dashboard.
  static const all = [inProgress, overdue, pendingApproval, delayed, onTime];

  /// The tile's own label.
  static String label(String bucket) => switch (bucket) {
    inProgress => 'In Progress',
    overdue => 'Overdue',
    pendingApproval => 'Pending Approval',
    delayed => 'Delayed',
    onTime => 'On Time Completion',
    _ => bucket,
  };

  /// The short words on a row's own status pill.
  static String pill(String bucket) => switch (bucket) {
    onTime => 'On Time',
    _ => label(bucket),
  };
}

List<String> _strings(dynamic v) =>
    v is List ? [for (final e in v) e.toString()] : const <String>[];
int _int0(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// One place's NC tallies — the SERVER's `byLocation` row of GET /ncs/report/
/// stats (utils/reportNcBreakdown.js): total = inProgress + overdue +
/// pendingApproval + delayed + onTime, over the whole filtered set.
class NcLocationStats {
  final String key;
  final String label;
  final int total;
  final int inProgress;
  final int overdue;
  final int pendingApproval;
  final int delayed;
  final int onTime;
  final List<String> locationIds;
  final List<String> departmentIds;

  /// The NCs counted here — which loaded rows belong under this header.
  final List<String> ncIds;

  const NcLocationStats({
    required this.key,
    required this.label,
    this.total = 0,
    this.inProgress = 0,
    this.overdue = 0,
    this.pendingApproval = 0,
    this.delayed = 0,
    this.onTime = 0,
    this.locationIds = const [],
    this.departmentIds = const [],
    this.ncIds = const [],
  });

  int countFor(String bucket) => switch (bucket) {
    NcBucket.inProgress => inProgress,
    NcBucket.overdue => overdue,
    NcBucket.pendingApproval => pendingApproval,
    NcBucket.delayed => delayed,
    NcBucket.onTime => onTime,
    _ => 0,
  };

  static NcLocationStats? tryParse(dynamic data) {
    if (data is! Map) return null;
    final label = (data['label'] ?? data['key'] ?? '').toString();
    return NcLocationStats(
      key: (data['key'] ?? label).toString(),
      label: label,
      total: _int0(data['total']),
      inProgress: _int0(data['inProgress']),
      overdue: _int0(data['overdue']),
      pendingApproval: _int0(data['pendingApproval']),
      delayed: _int0(data['delayed']),
      onTime: _int0(data['onTime']),
      locationIds: _strings(data['locationIds']),
      departmentIds: _strings(data['departmentIds']),
      ncIds: _strings(data['ncIds']),
    );
  }
}

/// The six NC tiles — Total NC, In Progress, Overdue, Pending Approval,
/// Delayed, On Time Completion — with the NC ids behind each (what a tap on a
/// tile narrows the list to). Read from GET /ncs/report/stats (the Final
/// Report's NCs tab) and GET /ncs/raised/stats (NC Monitoring), which send the
/// same five buckets; the old raised-stats fields (`awaitingApproval`,
/// `closed`) are still read so an older answer keeps working.
class NcTileStats {
  final int total;
  final int inProgress;
  final int overdue;
  final int pendingApproval;
  final int delayed;
  final int onTime;

  /// Whether the answer carried the five buckets at all — an older server
  /// answering /ncs/raised/stats with only its old four fields does not, and
  /// six tiles of zeros next to a real Total would mislead.
  final bool hasBuckets;

  final Map<String, List<String>> idsByBucket;

  /// Cumulative scores over the same NCs (/ncs/report/stats only).
  final double? atsScore;
  final double? otcScore;

  /// One row per place, A-Z with "No location" last (/ncs/report/stats only).
  final List<NcLocationStats> byLocation;

  /// Old /ncs/raised/stats fields, kept readable.
  final int awaitingApproval;
  final int closed;

  const NcTileStats({
    this.total = 0,
    this.inProgress = 0,
    this.overdue = 0,
    this.pendingApproval = 0,
    this.delayed = 0,
    this.onTime = 0,
    this.hasBuckets = true,
    this.idsByBucket = const {},
    this.atsScore,
    this.otcScore,
    this.byLocation = const [],
    this.awaitingApproval = 0,
    this.closed = 0,
  });

  int countFor(String bucket) => switch (bucket) {
    NcBucket.inProgress => inProgress,
    NcBucket.overdue => overdue,
    NcBucket.pendingApproval => pendingApproval,
    NcBucket.delayed => delayed,
    NcBucket.onTime => onTime,
    _ => total,
  };

  List<String> idsFor(String bucket) => idsByBucket[bucket] ?? const [];

  /// [this] with another response's place breakdown — the narrowed one the
  /// server sends for `onlyIds` (a tile is active), while every tile keeps the
  /// whole filtered set's numbers.
  NcTileStats withByLocation(List<NcLocationStats> rows) => NcTileStats(
    total: total,
    inProgress: inProgress,
    overdue: overdue,
    pendingApproval: pendingApproval,
    delayed: delayed,
    onTime: onTime,
    hasBuckets: hasBuckets,
    idsByBucket: idsByBucket,
    atsScore: atsScore,
    otcScore: otcScore,
    byLocation: rows,
    awaitingApproval: awaitingApproval,
    closed: closed,
  );

  /// Null for anything that isn't the server's `data` object.
  static NcTileStats? tryParse(dynamic data) {
    if (data is! Map) return null;
    double? dbl(dynamic v) => v is num ? v.toDouble() : null;
    return NcTileStats(
      total: _int0(data['total']),
      inProgress: _int0(data['inProgress']),
      overdue: _int0(data['overdue']),
      pendingApproval: _int0(data['pendingApproval']),
      delayed: _int0(data['delayed']),
      onTime: _int0(data['onTime']),
      hasBuckets: data.containsKey('inProgress') && data.containsKey('onTime'),
      idsByBucket: {
        for (final b in NcBucket.all) b: _strings(data['${b}Ids']),
      },
      atsScore: dbl(data['atsScore']),
      otcScore: dbl(data['otcScore']),
      byLocation: [
        if (data['byLocation'] is List)
          for (final e in data['byLocation'] as List)
            ?NcLocationStats.tryParse(e),
      ],
      awaitingApproval: _int0(data['awaitingApproval']),
      closed: _int0(data['closed']),
    );
  }
}

/// One line of the Repeated NCs tab: the same checkpoint wording raised again
/// at the same place (server: GET /ncs/repeats, utils/ncRepeat.js — only
/// capitals / extra spaces / trailing punctuation are ignored; a different
/// spelling, extra words or another place is a different group).
class RepeatGroup {
  final String key;
  final String title;
  final String? locationName;
  final String? departmentName;

  /// Times raised, and how many of those are not closed yet.
  final int count;
  final int openCount;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final String? latestStatus;

  /// The NCs behind the row, newest first — opened through /ncs/repeats/rows.
  final List<String> ncIds;

  const RepeatGroup({
    required this.key,
    required this.title,
    this.locationName,
    this.departmentName,
    this.count = 0,
    this.openCount = 0,
    this.firstDate,
    this.lastDate,
    this.latestStatus,
    this.ncIds = const [],
  });

  /// "Plant A · Maintenance", or null when the row has no place name.
  String? get place {
    final parts = [locationName, departmentName].where((s) => (s ?? '').isNotEmpty);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static RepeatGroup? tryParse(dynamic data) {
    if (data is! Map) return null;
    return RepeatGroup(
      key: (data['key'] ?? '').toString(),
      title: (data['title'] ?? '').toString(),
      locationName: data['locationName']?.toString(),
      departmentName: data['departmentName']?.toString(),
      count: _int0(data['count']),
      openCount: _int0(data['openCount']),
      firstDate: DateTime.tryParse(data['firstDate']?.toString() ?? ''),
      lastDate: DateTime.tryParse(data['lastDate']?.toString() ?? ''),
      latestStatus: data['latestStatus']?.toString(),
      ncIds: _strings(data['ncIds']),
    );
  }
}

/// The NCs of ONE audit, shown as one bundle on the Final Report's NCs tab (an
/// audit often raises several — to one person or to different people — and they
/// read as one thing, not scattered rows). A group of one is just a plain NC.
///
/// Everything summarised here is read off the rows as the server sent them: the
/// stage counts come from each row's own `bucket`, the place from its
/// `placeLabel` — nothing is worked out again on the device.
class NcAuditGroup {
  /// `audit:<audit key>`, or `nc:<nc id>` for an NC that names no audit at all (it
  /// stays a single card).
  final String key;
  final List<NcModel> ncs;

  const NcAuditGroup(this.key, this.ncs);

  /// Two or more NCs: drawn as one expandable card.
  bool get isBundle => ncs.length > 1;

  String get auditTitle => ncs.first.auditTitle;

  /// The audit no longer exists — the card reads "Audit deleted".
  bool get auditDeleted => ncs.first.auditDeleted;

  /// The audit is one zone-document of a multi-zone bundle.
  bool get isMultiZoneAudit => ncs.any((n) => n.auditBatchId != null);

  /// What every NC of the group shares for [of], or null when they differ (the
  /// card then says "Multiple").
  String? common(String? Function(NcModel nc) of) {
    final first = of(ncs.first);
    return ncs.every((n) => of(n) == first) ? first : null;
  }

  DateTime? _earliest(DateTime? Function(NcModel nc) of) {
    DateTime? best;
    for (final n in ncs) {
      final d = of(n);
      if (d != null && (best == null || d.isBefore(best))) best = d;
    }
    return best;
  }

  DateTime? get earliestRaised => _earliest((n) => n.startDate);
  DateTime? get earliestTarget => _earliest((n) => n.targetDate);

  int countBucket(String bucket) => ncs.where((n) => n.bucket == bucket).length;
  int countFlag(String flag) => ncs.where((n) => n.severity == flag).length;
}

/// Groups [ncs] by audit, in order of first appearance (the server's newest
/// first). The audit is named by the NC's `auditKey` (it survives the audit being
/// deleted), else its populated audit id; an NC that names neither stays a group
/// of its own. The server's groupBy=audit paging uses the same key, so a page
/// never splits an audit.
List<NcAuditGroup> groupNcsByAudit(List<NcModel> ncs) {
  final order = <String>[];
  final byKey = <String, List<NcModel>>{};
  for (final nc in ncs) {
    final audit = nc.auditKey ?? (nc.auditId.isEmpty ? null : nc.auditId);
    final key = audit == null ? 'nc:${nc.id}' : 'audit:$audit';
    if (!byKey.containsKey(key)) order.add(key);
    byKey.putIfAbsent(key, () => []).add(nc);
  }
  return [for (final key in order) NcAuditGroup(key, byKey[key]!)];
}
