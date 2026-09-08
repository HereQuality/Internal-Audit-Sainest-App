import '../models/audit_detail_model.dart';

/// utils/report_sections.dart
/// ─────────────────────────────
/// Dart port of client/src/Components/AuditReport/AuditReportShared.jsx's
/// buildLocationSections/leafMax/leafWeightage/sumAchievedMax — used by the
/// mobile Reports screen's PDF builder so it agrees with the web report's
/// own numbers. See that file's own
/// header comments for the full rationale (sum-then-divide, never average
/// pre-calculated percentages; Weightage mode scales both achieved and max
/// by each leaf's independent Weightage so achieved/max stays proportional
/// — matches the web's own corrected formula).
class ReportSection {
  final String label;
  final List<ParameterNode> tree;

  const ReportSection({required this.label, required this.tree});
}

List<ReportSection> buildReportSections(AuditDetailModel audit) {
  if (audit.structureMode == 'per-location' &&
      (audit.locationParameters.isNotEmpty || audit.departmentParameters.isNotEmpty)) {
    return [
      ...audit.locationParameters.map((lp) {
        final loc = audit.locationLabels.where((l) => l.id == lp.locationId);
        final label = loc.isNotEmpty ? loc.first.display : 'Location';
        return ReportSection(label: label, tree: lp.parameters);
      }),
      // CFT audits' department-scoped sections — mirrors
      // AuditReportShared.jsx#buildLocationSections' departmentLabel branch.
      ...audit.departmentParameters.map((dp) {
        final dept = audit.departmentLabels.where((d) => d.id == dp.departmentId);
        final label = dept.isNotEmpty ? dept.first.display : 'Department';
        return ReportSection(label: label, tree: dp.parameters);
      }),
    ];
  }
  return [ReportSection(label: audit.title, tree: audit.parameters)];
}

List<ParameterNode> collectScoredLeaves(List<ParameterNode> nodes) {
  final out = <ParameterNode>[];
  for (final n in nodes) {
    if (n.isLeaf) {
      if (n.findingType != null) out.add(n);
    } else {
      out.addAll(collectScoredLeaves(n.children));
    }
  }
  return out;
}

double leafMax(ParameterNode node, double? auditMaxScore) {
  if (auditMaxScore != null && auditMaxScore > 0) return auditMaxScore;
  final w = node.weight;
  return (w != null && w > 0) ? w : 1;
}

double leafWeightage(ParameterNode node, double? auditMaxScore) {
  final wt = node.weightage;
  return (wt != null && wt > 0) ? wt : leafMax(node, auditMaxScore);
}

class AchievedMax {
  final double achieved;
  final double max;
  const AchievedMax(this.achieved, this.max);
}

// Unrounded achieved/max — the same per-leaf formula sumAchievedMax below
// uses, without its final rounding step. Exists so a caller that needs to
// combine several leaf groups (e.g. every top-level node's own leaves, or
// every section's leaves) into ONE grand total can sum the RAW
// contributions first and round exactly once at the end, instead of
// summing several already-rounded sub-totals — rounding isn't
// distributive over addition, so "sum of rounded parts" and "round of
// the summed whole" can legitimately land on different numbers. Matches
// the web's own AuditReportShared.jsx#sumAchievedMax, which callers
// achieve the same "round once" property with simply by calling it ONCE
// over a combined leaf list rather than once per group.
AchievedMax rawAchievedMax(List<ParameterNode> leaves, String scoringSystem, double? auditMaxScore) {
  double achieved = 0, max = 0;
  for (final l in leaves) {
    final m = leafMax(l, auditMaxScore);
    final raw = l.findingType == 'NC'
        ? 0.0
        : (l.findingType == 'Strong Compliance' || l.findingType == 'Compliance')
            ? m
            : (l.score ?? 0);
    if (scoringSystem == 'weightage') {
      final capped = raw.clamp(0, m).toDouble();
      final wt = leafWeightage(l, auditMaxScore);
      achieved += capped * wt;
      max += m * wt;
    } else {
      achieved += raw;
      max += m;
    }
  }
  return AchievedMax(achieved, max);
}

// Whole numbers only, matching server/utils/scoring.js#roundScore and its
// web mirror (AuditReportShared.jsx#sumAchievedMax) — rounds the final
// summed totals only, never per-leaf mid-sum. Callers that need to
// combine MULTIPLE sumAchievedMax-shaped totals into one grand total
// (a report's overall %, a table's FINAL SCORE row) should use
// [rawAchievedMax] for each part instead and round once after summing —
// see its own doc comment for why.
AchievedMax sumAchievedMax(List<ParameterNode> leaves, String scoringSystem, double? auditMaxScore) {
  final raw = rawAchievedMax(leaves, scoringSystem, auditMaxScore);
  return AchievedMax(raw.achieved.roundToDouble(), raw.max.roundToDouble());
}

int? percentageOf(AchievedMax am) => am.max > 0 ? (am.achieved / am.max * 100).round() : null;
