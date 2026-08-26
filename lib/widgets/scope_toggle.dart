import 'package:flutter/material.dart';

/// "Me" (default — just the logged-in user's own audits/NCs) vs "Team"
/// (self + everyone in their downstream hierarchy — same "all" scope the
/// web app's TeamFilterPanel defaults to, see server/utils/
/// scopeEmployeeIds.js#resolveScopedEmployeeIds). A lightweight binary
/// version of that panel for the phone: no per-person picker, just the
/// two scopes a small screen has room for — "Me" is the default everywhere
/// on purpose, matching Team Filter's non-mobile counterpart being opt-in
/// to widen, not opt-in to narrow.
class ScopeToggle extends StatelessWidget {
  final bool isTeam;
  final ValueChanged<bool> onChanged;

  const ScopeToggle({super.key, required this.isTeam, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
          value: false,
          label: Text('Me'),
          icon: Icon(Icons.person_outline, size: 16),
        ),
        ButtonSegment(
          value: true,
          label: Text('Team'),
          icon: Icon(Icons.groups_outlined, size: 16),
        ),
      ],
      selected: {isTeam},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}
