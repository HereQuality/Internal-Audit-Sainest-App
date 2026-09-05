import 'package:flutter/material.dart';

/// "Me" (just the logged-in user's own audits/NCs) vs "Team" (self +
/// everyone in their downstream hierarchy — the "all" scope
/// server/utils/scopeEmployeeIds.js#resolveScopedEmployeeIds falls back to
/// when no employeeIds param is sent at all).
///
/// "ME" IS THE DEFAULT everywhere this is used — every provider's own
/// isTeamScope starts false. Someone opening this app on a phone, usually
/// standing on the floor about to run an audit, is asking "what do I have
/// to do", not "what does my whole reporting line have to do"; Team is the
/// deliberate widening from there, one tap away.
///
/// This deliberately does NOT match the web app's TeamFilterPanel, whose
/// own default is "All". An earlier revision of this file changed mobile
/// TO Team specifically so the two platforms would agree, on the theory
/// that a same-account ATS/OTC score reading differently between web and
/// mobile was a bug. It isn't: the two surfaces answer different
/// questions, and the number differing is explained by a toggle sitting
/// right above it. Don't flip it back without saying why here.
///
/// This is the coarse control. The filter sheet (widgets/filter_sheet.dart)
/// is where a specific set of PEOPLE can be picked, and a non-empty pick
/// there overrides this toggle entirely — see AuditFilterScope.filterParams.
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
