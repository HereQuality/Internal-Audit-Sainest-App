import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/maintenance/maintenance_prefs.dart';
import '../../models/maintenance_status.dart';

/// Shows the once-a-day scheduled-maintenance heads-up, if warranted.
/// "Once a day" is keyed on (today's local date + the maintenance doc's
/// own updatedAt) — editing the schedule makes it resurface immediately
/// even if already dismissed today, mirroring the web app's counterpart
/// (Components/Common/MaintenanceAnnouncementModal.jsx). Independent of
/// the hard block (MaintenanceBlockScreen) — this fires BEFORE the switch
/// is flipped, while the app is still fully usable.
Future<void> showMaintenanceAnnouncementIfNeeded(BuildContext context, MaintenanceStatus status) async {
  final scheduledAt = status.scheduledAt;
  final version = status.updatedAt?.toIso8601String();
  if (scheduledAt == null || version == null) return;

  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final key = '$today|$version';
  final lastShown = await MaintenancePrefs.readLastShown();
  if (lastShown == key) return;
  await MaintenancePrefs.setLastShown(key);

  if (!context.mounted) return;
  final local = scheduledAt.toLocal();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.calendar_month_outlined),
      title: const Text('Scheduled Maintenance'),
      content: Text(
        '${status.message.isNotEmpty ? status.message : "This system will undergo brief scheduled maintenance."}\n\n'
        'Starts: ${DateFormat('EEEE, d MMMM yyyy · h:mm a').format(local)}',
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Got it')),
      ],
    ),
  );
}
