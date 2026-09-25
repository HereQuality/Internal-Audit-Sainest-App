import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/store_links.dart';
import '../../core/theme/app_colors.dart';
import '../../providers/app_update_provider.dart';

/// Non-blocking "a newer build is out" nudge — the counterpart to
/// UpdateRequiredScreen that does NOT take over the screen or stop
/// navigation. MaintenanceAnnouncementHost anchors this to the bottom of
/// the screen whenever AppUpdateProvider.isSoftUpdateAvailable is true, and
/// it stays up until the person taps "Update" or "Dismiss" — no
/// auto-timeout, unlike a SnackBar, since the whole point is that it keeps
/// nudging until acted on. Styled as a light surfaceContainerLow card with
/// a soft shadow rather than UpdateRequiredScreen's primary-tinted,
/// full-bleed look — this is a suggestion, not a block, and shouldn't read
/// as alarming.
class SoftUpdateBanner extends StatefulWidget {
  const SoftUpdateBanner({super.key});

  @override
  State<SoftUpdateBanner> createState() => _SoftUpdateBannerState();
}

class _SoftUpdateBannerState extends State<SoftUpdateBanner> {
  bool _opening = false;

  Future<void> _openStore() async {
    final uri = StoreLinks.appStoreUri();
    if (uri == null) return;

    setState(() => _opening = true);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Same reasoning as UpdateRequiredScreen._openStore: nothing more
      // useful to do here — worst case the button just doesn't do
      // anything and the banner is still safely sitting there to retry.
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = context.watch<AppUpdateProvider>();
    final status = provider.status;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Material(
        color: scheme.surfaceContainerLow,
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.system_update_alt, size: 16, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  status.softMessage.isNotEmpty
                      ? status.softMessage
                      : 'Update available — v${status.latestVersion} is out',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                  // 3, not 2: the Dismiss/Update buttons leave this column only
                  // ~150px on a phone, so an admin-typed message was cut off after
                  // about 45 characters.
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => provider.dismissSoftUpdate(),
                child: const Text('Dismiss'),
              ),
              if (_opening)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              else
                TextButton(
                  onPressed: StoreLinks.hasStoreLink ? _openStore : null,
                  child: const Text('Update'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
