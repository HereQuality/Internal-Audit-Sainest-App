import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_update_provider.dart';
import 'soft_update_banner.dart';

/// Anchors [SoftUpdateBanner] to the bottom of [child] whenever
/// AppUpdateProvider.isSoftUpdateAvailable is true. Deliberately separate
/// from MaintenanceAnnouncementHost (which only wraps the AUTHENTICATED
/// app content) and applied by main.dart's `_RootGate` around BOTH
/// LoginScreen and the authenticated content — a soft update nudge doesn't
/// need a session to be useful, unlike the maintenance/announcement popups,
/// and someone sitting on the login screen for days is exactly who'd
/// otherwise never see it. No role bypass either, same reasoning as
/// AppUpdateProvider.isForceUpdateRequired: a SuperAdmin's device can be on
/// an old build too.
class SoftUpdateOverlay extends StatelessWidget {
  final Widget child;
  const SoftUpdateOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final appUpdate = context.watch<AppUpdateProvider>();

    return Stack(
      children: [
        Positioned.fill(child: child),
        if (appUpdate.isSoftUpdateAvailable)
          Positioned(
            left: 0,
            right: 0,
            // 64 clears AppShell's own bottomNavigationBar — a Material 3
            // NavigationBar's fixed content height (see app_shell.dart's
            // `bottomNavigationBar`) — while sitting a bit closer to it
            // than a full 80 would. On screens with no bottom nav at all
            // (LoginScreen, RolePickerScreen) this just leaves a harmless
            // gap under the banner instead of overlapping anything.
            bottom: 64,
            child: const SafeArea(top: false, child: SoftUpdateBanner()),
          ),
      ],
    );
  }
}
