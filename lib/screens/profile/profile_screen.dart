import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/formatters.dart';
import '../../providers/app_mode_provider.dart';
import '../../providers/auth_provider.dart';
import '../../widgets/avatar_circle.dart';
import '../support/tickets_list_screen.dart';
import 'edit_profile_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final scheme = Theme.of(context).colorScheme;

    if (user == null) return const Scaffold(body: SizedBox.shrink());

    // This screen used to be one of AppShell's own IndexedStack tabs (so
    // it inherited AppShell's Scaffold/AppBar for free) — now that it's
    // reached via Navigator.push from the app-bar icon instead, it needs
    // its own Scaffold. Without one, a pushed bare ListView renders
    // directly on the route's raw Material surface: no theme-correct
    // background fill (hence showing black regardless of light/dark
    // mode) and no back button.
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        children: [
          Center(
            child: Column(
              children: [
                AvatarCircle(
                  name: user.name,
                  imageUrl: user.profilePic,
                  radius: 44,
                ),
                const SizedBox(height: 14),
                Text(
                  user.name,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                if ((user.roleName ?? '').isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(user.roleName!, style: TextStyle(color: scheme.outline)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _InfoRow(
                    icon: Icons.badge_outlined,
                    label: 'Username',
                    value: user.username,
                  ),
                  _InfoRow(
                    icon: Icons.email_outlined,
                    label: 'Office Email',
                    value: user.email,
                  ),
                  _InfoRow(
                    icon: Icons.call_outlined,
                    label: 'Mobile',
                    value: user.mobileNumber,
                  ),
                  if (user.departments.isNotEmpty)
                    _InfoRow(
                      icon: Icons.apartment_outlined,
                      label: 'Departments',
                      value: user.departments.map((d) => d.name).join(', '),
                    ),
                  if (user.locations.isNotEmpty)
                    _InfoRow(
                      icon: Icons.location_on_outlined,
                      label: 'Locations',
                      value: user.locations.map((l) => l.name).join(', '),
                    ),
                  if (user.joiningDate != null)
                    _InfoRow(
                      icon: Icons.event_available_outlined,
                      label: 'Joined',
                      value: Formatters.date(user.joiningDate),
                    ),
                ],
              ),
            ),
          ),
          if (user.skills.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              'Skills',
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: user.skills
                  .map(
                    (skill) => Chip(
                      label: Text(skill),
                      backgroundColor: scheme.primaryContainer,
                      side: BorderSide.none,
                    ),
                  )
                  .toList(),
            ),
          ],
          const SizedBox(height: 24),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Edit Profile'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const EditProfileScreen(),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.settings_outlined),
                  title: const Text('Settings'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Reports'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReportsScreen()),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.support_agent_outlined),
                  title: const Text('Support'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const TicketsListScreen(),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.swap_horiz_outlined),
                  title: const Text('Switch Role'),
                  subtitle: const Text(
                    'Change between Auditor and Auditee view',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => switchRole(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(Icons.logout, color: scheme.error),
              title: Text(
                'Log Out',
                style: TextStyle(
                  color: scheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () => _confirmLogout(context),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You will need to sign in again to access your audits.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      // This screen is reached via Navigator.push, sitting on top of
      // _RootGate's single root route (main.dart) — popping back to that
      // root route BEFORE clearing auth state is what lets _RootGate's
      // already-updated LoginScreen actually become visible immediately.
      // Without this, ProfileScreen stays on top of the stack after
      // logout, its own null-guard (`user == null` above) renders a bare
      // blank Scaffold, and only a manual back press reveals the login
      // screen underneath. Grab both references before popping — both
      // Navigator.of(context) and context.read need a still-mounted
      // context, which won't be true once we've popped this route away.
      final navigator = Navigator.of(context);
      final auth = context.read<AuthProvider>();
      navigator.popUntil((route) => route.isFirst);
      await auth.logout();
    }
  }

}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.outline),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                Text(
                  value,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
