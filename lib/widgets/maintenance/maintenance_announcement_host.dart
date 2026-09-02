import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/maintenance_provider.dart';
import 'maintenance_announcement_dialog.dart';

/// Wraps the normal (non-blocked) authenticated app content and surfaces
/// the once-a-day scheduled-maintenance popup whenever the maintenance
/// doc changes (a poll comes back with a different `updatedAt`) —
/// independent of the hard block in main.dart's _RootGate, which replaces
/// this host entirely once isActive flips on for a non-SuperAdmin.
class MaintenanceAnnouncementHost extends StatefulWidget {
  final Widget child;
  const MaintenanceAnnouncementHost({super.key, required this.child});

  @override
  State<MaintenanceAnnouncementHost> createState() => _MaintenanceAnnouncementHostState();
}

class _MaintenanceAnnouncementHostState extends State<MaintenanceAnnouncementHost> {
  String? _lastCheckedVersion;

  @override
  Widget build(BuildContext context) {
    final maintenance = context.watch<MaintenanceProvider>();
    final status = maintenance.status;
    final version = status.updatedAt?.toIso8601String();

    if (maintenance.loaded && version != null && version != _lastCheckedVersion) {
      _lastCheckedVersion = version;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showMaintenanceAnnouncementIfNeeded(context, status);
      });
    }

    return widget.child;
  }
}
