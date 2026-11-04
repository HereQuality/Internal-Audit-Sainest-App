/// A SELF audit — the auditor carried the audit out without an auditee
/// representative because the auditee did not respond or was not available.
///
/// It is the other answer to the "select representative auditee" step
/// (screens/audits/select_representative_sheet.dart): instead of naming people
/// the auditor picks **Self**, says why (one of [SelfAuditReason]) and writes a
/// remark. The audit then has no representative, the report's Auditee reads
/// "Self", and the reason + remark sit under it. Server rules and storage:
/// server/utils/selfAudit.js; the web twin: client/src/utils/selfAudit.js (the
/// two reason labels are the same words in all three).
///
/// NCs are not affected: each still names the person at the audited place it is
/// raised against (the representative was never a default for that).
library;

/// What the Auditee field says for a self audit.
const String kSelfLabel = 'Self';

/// The server refuses a longer remark.
const int kSelfAuditRemarkMax = 1000;

enum SelfAuditReason {
  notResponding('not_responding', 'Auditee not responding'),
  notAvailable('not_available', 'Auditee not available');

  const SelfAuditReason(this.code, this.label);

  /// What is stored and sent.
  final String code;

  /// What every screen and export says.
  final String label;

  static SelfAuditReason? fromCode(String? code) {
    for (final r in values) {
      if (r.code == code) return r;
    }
    return null;
  }
}

/// The reason and remark a self audit is saved with.
class SelfAuditChoice {
  final SelfAuditReason reason;
  final String remark;

  const SelfAuditChoice({required this.reason, required this.remark});
}

/// What the representative step answered: the people named, or Self.
class RepresentativeChoice {
  /// Employee ids — empty for Self.
  final List<String> employeeIds;

  /// Set when the auditor chose Self.
  final SelfAuditChoice? self;

  const RepresentativeChoice.people(this.employeeIds) : self = null;

  const RepresentativeChoice.self(SelfAuditChoice this.self) : employeeIds = const [];

  bool get isSelf => self != null;
}

/// "Auditee not responding — Called twice, no answer": the reason, then the
/// auditor's remark (either may be missing).
String selfAuditNoteOf(String? reasonCode, String? remark) {
  final reason = SelfAuditReason.fromCode(reasonCode)?.label;
  final text = (remark ?? '').trim();
  return [
    ?reason,
    if (text.isNotEmpty) text,
  ].join(' — ');
}
