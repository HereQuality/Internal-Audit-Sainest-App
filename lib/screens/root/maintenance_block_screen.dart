import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/maintenance_provider.dart';
import '../../widgets/maintenance/maintenance_runner_game.dart';

/// Full-screen, unavoidable block shown in place of the ENTIRE app (see
/// main.dart's _RootGate) whenever maintenance mode is active and the
/// signed-in user isn't SuperAdmin. Styled to echo LoginScreen's own
/// gradient-card look so it reads as an intentional app state, not a
/// crash/error screen. `_RootGate` also forces the navigator back to this
/// root route the moment maintenance kicks in, so someone several screens
/// deep (an audit detail, an NC response) can't just stay there.
class MaintenanceBlockScreen extends StatefulWidget {
  const MaintenanceBlockScreen({super.key});

  @override
  State<MaintenanceBlockScreen> createState() => _MaintenanceBlockScreenState();
}

class _MaintenanceBlockScreenState extends State<MaintenanceBlockScreen> {
  bool _checking = false;
  bool _showGame = false;

  Future<void> _checkAgain() async {
    setState(() => _checking = true);
    await context.read<MaintenanceProvider>().refreshNow();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = context.watch<MaintenanceProvider>().status;
    final scheduled = status.scheduledAt?.toLocal();

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.amber.withValues(alpha: 0.12), scheme.surface],
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
                          color: AppColors.amber.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.engineering_outlined, size: 44, color: AppColors.amber),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      "We're making things better",
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      status.message.isNotEmpty
                          ? status.message
                          : "This system is temporarily undergoing scheduled maintenance. Thanks for your patience — we'll be back shortly.",
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.outline),
                      textAlign: TextAlign.center,
                    ),
                    if (scheduled != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              'EXPECTED BACK',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.outline, letterSpacing: 0.6),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              DateFormat('EEEE, d MMMM yyyy').format(scheduled),
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                              textAlign: TextAlign.center,
                            ),
                            Text(
                              DateFormat('h:mm a').format(scheduled),
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _checking ? null : _checkAgain,
                            icon: _checking
                                ? const SizedBox(
                                    height: 16,
                                    width: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.refresh, size: 18),
                            label: const Text('Check again'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => setState(() => _showGame = !_showGame),
                            icon: const Icon(Icons.sports_esports_outlined, size: 18),
                            label: Text(_showGame ? 'Hide game' : 'Play'),
                          ),
                        ),
                      ],
                    ),
                    if (_showGame) ...[
                      const SizedBox(height: 18),
                      const MaintenanceRunnerGame(),
                    ],
                    const SizedBox(height: 20),
                    Center(
                      child: TextButton.icon(
                        onPressed: () => context.read<AuthProvider>().logout(),
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text('Sign out'),
                      ),
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
