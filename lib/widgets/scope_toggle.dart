import 'package:flutter/material.dart';

/// "Me" (just the logged-in user's own audits/NCs) vs "All Members" (self +
/// everyone in their downstream hierarchy — the "all" scope
/// server/utils/scopeEmployeeIds.js#resolveScopedEmployeeIds falls back to
/// when no employeeIds param is sent at all; the web's "All Members"). With a
/// Location picked, All Members shows every audit at that location whoever the
/// auditor is, while Me shows only my own there.
///
/// "ME" IS THE DEFAULT for every ordinary employee — every provider's own
/// isTeamScope starts false. Someone opening this app on a phone, usually
/// standing on the floor about to run an audit, is asking "what do I have
/// to do", not "what does my whole reporting line have to do"; Team is the
/// deliberate widening from there, one tap away.
///
/// The exception is an account whose Role has FULL ACCESS (and a SuperAdmin):
/// an oversight role for whom "just me" opens nearly empty. It opens on All
/// Members (AuditFilterScope.defaultTeamScope, set from the signed-in user by
/// main.dart's _RootGate), exactly as the web does (useSelfScope.js); Me is
/// still one tap away and is a real narrowing for them. The Calendar alone
/// keeps Me for everybody (it loads unpaginated data).
///
/// For everybody else this deliberately does NOT match the web app's
/// TeamFilterPanel, whose own default was once "All". An earlier revision of
/// this file changed mobile TO Team specifically so the two platforms would
/// agree, on the theory that a same-account ATS/OTC score reading differently
/// between web and mobile was a bug. It isn't: the two surfaces answer
/// different questions, and the number differing is explained by a toggle
/// sitting right above it. Don't flip it back without saying why here.
///
/// This is the coarse control. The filter sheet (widgets/filter_sheet.dart)
/// is where a specific set of PEOPLE can be picked, and a non-empty pick
/// there overrides this toggle entirely — see AuditFilterScope.filterParams.
class ScopeToggle extends StatelessWidget {
  final bool isTeam;
  final ValueChanged<bool> onChanged;

  /// True while a specific Team/Members pick is in force — it outranks both
  /// segments, so neither is drawn as selected; tapping one goes back to it.
  final bool specific;

  const ScopeToggle({
    super.key,
    required this.isTeam,
    required this.onChanged,
    this.specific = false,
  });

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
          label: Text('All Members'),
          icon: Icon(Icons.groups_outlined, size: 16),
        ),
      ],
      emptySelectionAllowed: true,
      selected: specific ? const <bool>{} : {isTeam},
      onSelectionChanged: (s) {
        // Tapping the already-selected segment yields an empty set — a no-op.
        if (s.isNotEmpty) onChanged(s.first);
      },
    );
  }
}
