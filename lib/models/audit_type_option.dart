/// A pickable Audit Type — the category an audit was created under
/// (server/models/AuditType.js). Audits store the type's NAME as a plain
/// trimmed string, not a ref (see models/Audit.js#auditType), and the
/// server's own `?auditType=` filter matches on that name too — so `name`
/// is the value that actually travels on the wire, and `id` is only ever
/// used as a list key.
class AuditTypeOption {
  final String id;
  final String name;
  // Instant Audits are built and scored live on one screen instead of
  // going through the Setup/Distribute pipeline — carried here so a
  // filter list can label or order them distinctly if it ever needs to,
  // and so this model doesn't have to be widened later to find out.
  final bool isInstant;

  const AuditTypeOption({
    required this.id,
    required this.name,
    this.isInstant = false,
  });

  factory AuditTypeOption.fromJson(Map<String, dynamic> json) {
    return AuditTypeOption(
      id: (json['_id'] ?? '').toString(),
      name: json['name']?.toString() ?? 'Untitled',
      isInstant: json['isInstant'] == true,
    );
  }
}
