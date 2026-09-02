import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/maintenance/announcement_prefs.dart';
import '../../models/announcement_status.dart';

/// Shows the once-a-day Announcement Mode heads-up, if warranted. "Once a
/// day" is keyed on (today's local date + the announcement doc's own
/// updatedAt) — editing the message resurfaces it immediately even if
/// already dismissed today, mirroring the web app's counterpart
/// (Components/Common/AnnouncementModal.jsx). Independent of the
/// maintenance popups — see maintenance_announcement_host.dart for how the
/// two are sequenced so they never show stacked on top of each other.
Future<void> showAnnouncementIfNeeded(BuildContext context, AnnouncementStatus status) async {
  if (!status.isLive || status.message.isEmpty) return;

  final version = status.updatedAt?.toIso8601String();
  if (version == null) return;

  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final key = '$today|$version';
  final lastShown = await AnnouncementPrefs.readLastShown();
  if (lastShown == key) return;
  await AnnouncementPrefs.setLastShown(key);

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.campaign_outlined),
      title: const Text('Announcement'),
      content: Text(status.message),
      actions: [
        FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Got it')),
      ],
    ),
  );
}
