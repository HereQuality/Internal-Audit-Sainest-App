import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_colors.dart';
import '../../providers/app_mode_provider.dart';
import '../../providers/auth_provider.dart';

/// Shown right after login (and whenever Profile → Switch Role is used) —
/// picks which restricted screen set to show. See AppModeProvider for why
/// this is a local UI choice, not a real permission.
class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = context.watch<AuthProvider>().user;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    user != null && user.name.isNotEmpty ? 'Hi, ${user.name}' : 'Welcome',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'How are you using the app right now?',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.outline),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  _RoleCard(
                    icon: Icons.fact_check_rounded,
                    title: 'Auditor',
                    subtitle: 'Auditor Dashboard, Audits and NC Monitoring',
                    color: AppColors.primary,
                    onTap: () => context.read<AppModeProvider>().setMode(AppMode.auditor),
                  ),
                  const SizedBox(height: 12),
                  _RoleCard(
                    icon: Icons.assignment_ind_rounded,
                    title: 'Auditee',
                    subtitle: 'Dashboard and the NCs raised against you',
                    color: AppColors.blue,
                    onTap: () => context.read<AppModeProvider>().setMode(AppMode.auditee),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'You can switch anytime from Profile.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 26),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 3),
                    Text(subtitle, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: scheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
