import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/announcement_provider.dart';
import '../../providers/maintenance_provider.dart';
import 'announcement_dialog.dart';
import 'maintenance_announcement_dialog.dart';

/// Wraps the normal (non-blocked) authenticated app content and surfaces
/// two once-a-day popups — the scheduled-maintenance heads-up and
/// Announcement Mode's own message — whenever their respective doc
/// changes (a poll comes back with a different `updatedAt`). Independent
/// of the hard block in main.dart's _RootGate, which replaces this host
/// entirely once isActive flips on for a non-SuperAdmin.
///
/// The two are SEQUENCED here rather than shown independently, mirroring
/// App.jsx's own reasoning: both are full-screen dialogs, so firing at
/// once would just have one cover the other. Maintenance takes priority
/// (it's the more operationally important one); the announcement dialog
/// only opens once the maintenance one has been awaited (dismissed, or
/// there was nothing to show in the first place).
class MaintenanceAnnouncementHost extends StatefulWidget {
  final Widget child;
  const MaintenanceAnnouncementHost({super.key, required this.child});

  @override
  State<MaintenanceAnnouncementHost> createState() => _MaintenanceAnnouncementHostState();
}

class _MaintenanceAnnouncementHostState extends State<MaintenanceAnnouncementHost> {
  String? _lastCheckedMaintenanceVersion;
  String? _lastCheckedAnnouncementVersion;
  bool _dialogQueueRunning = false;

  @override
  Widget build(BuildContext context) {
    final maintenance = context.watch<MaintenanceProvider>();
    final announcement = context.watch<AnnouncementProvider>();

    final maintenanceStatus = maintenance.status;
    final maintenanceVersion = maintenanceStatus.updatedAt?.toIso8601String();
    final maintenanceIsNew =
        maintenance.loaded && maintenanceVersion != null && maintenanceVersion != _lastCheckedMaintenanceVersion;

    final announcementStatus = announcement.status;
    final announcementVersion = announcementStatus.updatedAt?.toIso8601String();
    final announcementIsNew =
        announcement.loaded && announcementVersion != null && announcementVersion != _lastCheckedAnnouncementVersion;

    if (!_dialogQueueRunning && (maintenanceIsNew || announcementIsNew)) {
      _dialogQueueRunning = true;
      _lastCheckedMaintenanceVersion = maintenanceVersion;
      _lastCheckedAnnouncementVersion = announcementVersion;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (context.mounted) await showMaintenanceAnnouncementIfNeeded(context, maintenanceStatus);
        if (context.mounted) await showAnnouncementIfNeeded(context, announcementStatus);
        if (mounted) _dialogQueueRunning = false;
      });
    }

    return widget.child;
  }
}
