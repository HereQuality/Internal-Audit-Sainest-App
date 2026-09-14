import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/app_update_provider.dart';

/// Android's Play Store package name (android/app/build.gradle.kts's own
/// `applicationId`) — used to deep-link straight to this app's listing.
const _androidPackageId = 'com.hqepl.audit360';

/// Apple's numeric App Store id for this app (ios/Runner.xcodeproj's own
/// `PRODUCT_BUNDLE_IDENTIFIER` is "com.hqepl.internalaudit", but Apple's
/// store URL needs the numeric listing id, not the bundle id, and that
/// only exists once the app has actually been submitted/published). Fill
/// this in once the iOS listing exists — see the fallback below for what
/// happens while it's still blank.
const _iosAppStoreId = '';

/// Full-screen, unavoidable block shown in place of the ENTIRE app (see
/// main.dart's _RootGate) whenever AppUpdateProvider.isForceUpdateRequired
/// is true — checked before login even resolves, unlike
/// MaintenanceBlockScreen. Styled to echo LoginScreen's own gradient-card
/// look, same as MaintenanceBlockScreen, so it reads as an intentional app
/// state, not a crash/error screen.
class UpdateRequiredScreen extends StatefulWidget {
  const UpdateRequiredScreen({super.key});

  @override
  State<UpdateRequiredScreen> createState() => _UpdateRequiredScreenState();
}

class _UpdateRequiredScreenState extends State<UpdateRequiredScreen> {
  bool _checking = false;
  bool _opening = false;

  Future<void> _checkAgain() async {
    setState(() => _checking = true);
    await context.read<AppUpdateProvider>().refreshNow();
    if (mounted) setState(() => _checking = false);
  }

  Future<void> _openStore() async {
    final Uri? uri;
    if (Platform.isAndroid) {
      uri = Uri.parse('https://play.google.com/store/apps/details?id=$_androidPackageId');
    } else if (Platform.isIOS && _iosAppStoreId.isNotEmpty) {
      uri = Uri.parse('https://apps.apple.com/app/id$_iosAppStoreId');
    } else {
      uri = null;
    }

    if (uri == null) return;

    setState(() => _opening = true);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Nothing more useful to do here — worst case the button just
      // doesn't do anything and the user is still safely on this screen,
      // not stuck mid-navigation somewhere.
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = context.watch<AppUpdateProvider>();
    final status = provider.status;
    final canOpenStore = Platform.isAndroid || (Platform.isIOS && _iosAppStoreId.isNotEmpty);
    final installedVersion = provider.installedVersion;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.primary.withValues(alpha: 0.12), scheme.surface],
            stops: const [0.0, 0.45],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.system_update_alt, size: 44, color: AppColors.primary),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Update Required',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      status.message.isNotEmpty
                          ? status.message
                          : "A required update is available. Please update to keep using the app.",
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.outline),
                      textAlign: TextAlign.center,
                    ),
                    // Concrete "you have X, need Y" — same reasoning as
                    // MaintenanceBlockScreen's own "EXPECTED BACK" box:
                    // seeing the actual numbers is what makes someone
                    // trust the block is real and knows exactly what
                    // updating will fix, instead of a vague "something's
                    // wrong, tap the button and hope."
                    if (installedVersion != null && status.minVersion.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _VersionColumn(label: 'YOUR VERSION', value: installedVersion, color: scheme.outline),
                            Icon(Icons.arrow_forward, size: 18, color: scheme.outlineVariant),
                            _VersionColumn(label: 'REQUIRED', value: '${status.minVersion}+', color: AppColors.primary),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (canOpenStore)
                      ElevatedButton.icon(
                        onPressed: _opening ? null : _openStore,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        icon: _opening
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.system_update, size: 20),
                        label: const Text('Update Now'),
                      )
                    else
                      // No store link configured for this platform yet
                      // (see _iosAppStoreId above) — still tell the person
                      // something actionable instead of a dead-looking
                      // screen with only "Check again" on it.
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Please update via your usual app source (Play Store / App Store / the link your admin shared).',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _checking ? null : _checkAgain,
                      icon: _checking
                          ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.refresh, size: 18),
                      label: Text(_checking ? 'Checking...' : "I've already updated — check again"),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VersionColumn extends StatelessWidget {
  const _VersionColumn({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline, letterSpacing: 0.6),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: color),
        ),
      ],
    );
  }
}
