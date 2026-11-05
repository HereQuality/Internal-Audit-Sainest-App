import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A checkpoint edit (finding, score, remark, NC details) that the server has
/// NOT confirmed yet, kept on the device so it survives the app being killed.
///
/// Why: a scored checkpoint used to live only in memory while it waited to be
/// saved. With no signal the card retried a few times and then waited for a
/// manual Retry — and if the app was closed or killed in the meantime (swiped
/// away, out of memory, the phone restarted) the score and remark were simply
/// gone. Only a remark typed BEFORE any finding was picked had an on-device
/// copy. Now every unconfirmed edit does: it is written the moment it is made,
/// removed the moment the server confirms it, and put back (and sent) when the
/// checkpoint — or the audit — is opened again.
///
/// Stored per checkpoint under `<draftKey>:pending`. The draft key is
/// `checkpoint_draft:<auditId>:<locationId or empty>:<nodeId>`, so it already
/// says where the edit belongs (see [DraftKey]).
class PendingCheckpoint {
  PendingCheckpoint({
    required this.findingType,
    required this.score,
    required this.remark,
    required this.auditeeEmployeeId,
    required this.targetDate,
    required this.severity,
    required this.savedAt,
  });

  final String? findingType;
  final double? score;
  final String remark;
  final String? auditeeEmployeeId;

  /// A calendar day (an NC's due date): only year/month/day are kept, never a time of day or a timezone.
  final DateTime? targetDate;
  final String? severity;
  final DateTime savedAt;

  static const _version = 1;

  /// Older than this is not trusted any more (the audit has surely moved on).
  static const maxAge = Duration(days: 14);

  bool isStale([DateTime? now]) => (now ?? DateTime.now()).difference(savedAt) > maxAge;

  static String? _day(DateTime? d) =>
      d == null ? null : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {
        'v': _version,
        'findingType': findingType,
        'score': score,
        'remark': remark,
        'auditee': auditeeEmployeeId,
        'date': _day(targetDate),
        'severity': severity,
        'savedAt': savedAt.toUtc().toIso8601String(),
      };

  /// Null for anything that is not a well-formed v1 record (a corrupt or future-format value is ignored, never crashes).
  static PendingCheckpoint? fromJson(Object? raw) {
    if (raw is! Map || raw['v'] != _version) return null;
    final saved = DateTime.tryParse('${raw['savedAt']}');
    if (saved == null) return null;
    DateTime? date;
    final text = raw['date'];
    if (text is String && text.isNotEmpty) {
      final parts = text.split('-');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final d = int.tryParse(parts[2]);
        if (y != null && m != null && d != null) date = DateTime(y, m, d);
      }
    }
    final score = raw['score'];
    return PendingCheckpoint(
      findingType: raw['findingType'] as String?,
      score: score is num ? score.toDouble() : null,
      remark: (raw['remark'] as String?) ?? '',
      auditeeEmployeeId: raw['auditee'] as String?,
      targetDate: date,
      severity: raw['severity'] as String?,
      savedAt: saved,
    );
  }
}

class PendingCheckpointStore {
  PendingCheckpointStore._();

  static const _suffix = ':pending';

  /// `checkpoint_draft:<auditId>:<locationId or empty>:<nodeId>` -> the storage key of its pending edit.
  static String keyFor(String draftKey) => '$draftKey$_suffix';

  static Future<PendingCheckpoint?> read(String? draftKey) async {
    if (draftKey == null) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(keyFor(draftKey));
      if (text == null || text.isEmpty) return null;
      return PendingCheckpoint.fromJson(jsonDecode(text));
    } catch (_) {
      return null; // unreadable storage / corrupt value: just no pending edit
    }
  }

  static Future<void> write(String? draftKey, PendingCheckpoint pending) async {
    if (draftKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(keyFor(draftKey), jsonEncode(pending.toJson()));
    } catch (_) {
      // Best effort: this is a safety net, never a reason for a save to fail.
    }
  }

  static Future<void> clear(String? draftKey) async {
    if (draftKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(keyFor(draftKey));
    } catch (_) {}
  }

  /// Every pending edit of one audit (draft keys start `checkpoint_draft:<auditId>:`), oldest first.
  /// Stale or unreadable ones are dropped from storage as they are found.
  static Future<List<({String draftKey, PendingCheckpoint pending})>> forAudit(String auditId, {DateTime? now}) async {
    final found = <({String draftKey, PendingCheckpoint pending})>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = 'checkpoint_draft:$auditId:';
      for (final storageKey in prefs.getKeys().where((k) => k.startsWith(prefix) && k.endsWith(_suffix)).toList()) {
        final draftKey = storageKey.substring(0, storageKey.length - _suffix.length);
        PendingCheckpoint? pending;
        try {
          pending = PendingCheckpoint.fromJson(jsonDecode(prefs.getString(storageKey) ?? ''));
        } catch (_) {
          pending = null;
        }
        if (pending == null || pending.isStale(now)) {
          await prefs.remove(storageKey);
          continue;
        }
        found.add((draftKey: draftKey, pending: pending));
      }
    } catch (_) {}
    found.sort((a, b) => a.pending.savedAt.compareTo(b.pending.savedAt));
    return found;
  }

  /// Forgets every pending edit of one audit (the audit was completed or skipped: nothing can be sent any more).
  static Future<void> clearAudit(String auditId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = 'checkpoint_draft:$auditId:';
      for (final storageKey in prefs.getKeys().where((k) => k.startsWith(prefix) && k.endsWith(_suffix)).toList()) {
        await prefs.remove(storageKey);
      }
    } catch (_) {}
  }
}

/// Splits a checkpoint draft key (`checkpoint_draft:<auditId>:<locationId or empty>:<nodeId>`) back into its parts.
class DraftKey {
  DraftKey._(this.auditId, this.locationId, this.nodeId);

  final String auditId;

  /// Null for an audit that is not per-location.
  final String? locationId;
  final String nodeId;

  static DraftKey? parse(String key) {
    final parts = key.split(':');
    if (parts.length != 4 || parts[0] != 'checkpoint_draft' || parts[1].isEmpty || parts[3].isEmpty) return null;
    return DraftKey._(parts[1], parts[2].isEmpty ? null : parts[2], parts[3]);
  }
}
