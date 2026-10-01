/// GET /audits/report as the server answers it, for the tests that serve the Final
/// Report's Audits list from a plain list of rows (audit.controller.js#listAudits in
/// report view): `status` is a comma-separated OR-list of display labels, `search`
/// narrows by title, `ids` is an explicit id set that bypasses the paging, and the
/// page is a page of GROUPS (a bundle, or a recurring series, is one) — `total`
/// counts groups, a page's rows are the full membership of its groups.
///
/// Rows carry `status` (stored), `displayStatus` and `timeliness` like the real
/// ones; the label rules are the server's (utils/auditLifecycleStatus.js#clauseFor):
///   Completed                              stored status Completed
///   On-Time Completed / Delayed Completed  stored Completed AND that timeliness
///   Skipped / Draft                        stored status
///   anything else (In Progress, Overdue, Not Started, Not Attempted, the NC stages)
///                                          the row's displayStatus
library;

bool reportRowMatchesStatus(Map<String, dynamic> row, String label) {
  final status = row['status'];
  switch (label) {
    case 'Completed':
      return status == 'Completed';
    case 'On-Time Completed':
    case 'Delayed Completed':
      return status == 'Completed' && row['timeliness'] == label;
    case 'Skipped':
    case 'Draft':
      return status == label;
    default:
      return row['displayStatus'] == label;
  }
}

String _groupKey(Map<String, dynamic> row) {
  final batch = row['scheduleBatchId'];
  if (batch != null) return 'b:$batch';
  final recurrence = row['recurrence'];
  final series = recurrence is Map ? recurrence['seriesId'] : null;
  return series != null ? 's:$series' : 'a:${row['_id']}';
}

/// The `data` object of the server's answer to a GET /audits/report with [query].
Map<String, dynamic> reportListData(List<Map<String, dynamic>> rows, Map<String, dynamic> query) {
  var matched = rows;
  final status = query['status'];
  if (status != null && '$status'.isNotEmpty) {
    final labels = '$status'.split(',').where((s) => s.isNotEmpty).toList();
    matched = [
      for (final r in matched)
        if (labels.any((l) => reportRowMatchesStatus(r, l))) r,
    ];
  }
  final search = '${query['search'] ?? ''}'.trim().toLowerCase();
  if (search.isNotEmpty) {
    matched = [
      for (final r in matched)
        if ('${r['title']}'.toLowerCase().contains(search)) r,
    ];
  }
  final ids = query['ids'];
  final wantedIds = ids == null ? <String>{} : '$ids'.split(',').where((s) => s.isNotEmpty).toSet();
  if (ids != null) {
    matched = [
      for (final r in matched)
        if (wantedIds.contains('${r['_id']}')) r,
    ];
  }

  final groups = <String, List<Map<String, dynamic>>>{};
  for (final r in matched) {
    groups.putIfAbsent(_groupKey(r), () => []).add(r);
  }
  final ordered = groups.values.toList();
  // An explicit id set is one page of everything it names, like the server's.
  final byIds = ids != null;
  final page = byIds ? 1 : (query['page'] as num?)?.toInt() ?? 1;
  final limit = byIds ? (wantedIds.isEmpty ? 1 : wantedIds.length) : (query['limit'] as num?)?.toInt() ?? 20;
  final slice = ordered.skip((page - 1) * limit).take(limit);
  return {
    'audits': [for (final g in slice) ...g],
    'total': ordered.length,
    'page': page,
    'limit': limit,
  };
}
