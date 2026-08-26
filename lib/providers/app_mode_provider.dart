import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../core/storage/secure_storage.dart';

/// Which landing/tab set the user picked after login — Auditor
/// (Auditor Dashboard, Audits, NC Monitoring) or Auditee (Dashboard, NC).
///
/// This is NOT a real stored permission — there's no "Auditor"/"Auditee"
/// role field anywhere in the backend (see user_model.dart's roleType,
/// which is only "SuperAdmin"/"Employee"). A person is "the auditor" on
/// whichever audits list them in auditorIds and "the auditee" on whichever
/// NCs are raised against them — the same human can be both at once (see
/// nc_list_screen.dart's "Raised by me"/"Against me" split). So this is
/// purely a local UI preference for which subset of screens to show,
/// re-pickable any time from Profile → Switch Role.
enum AppMode { auditor, auditee }

class AppModeProvider extends ChangeNotifier {
  AppMode? mode;
  bool loaded = false;

  Future<void> bootstrap() async {
    final saved = await SecureStorage.instance.readAppMode();
    mode = saved == 'auditor' ? AppMode.auditor : saved == 'auditee' ? AppMode.auditee : null;
    loaded = true;
    notifyListeners();
  }

  Future<void> setMode(AppMode next) async {
    mode = next;
    notifyListeners();
    await SecureStorage.instance.saveAppMode(next == AppMode.auditor ? 'auditor' : 'auditee');
  }

  /// Back to the role picker — doesn't touch auth, just clears the local
  /// preference so _RootGate shows RolePickerScreen again.
  Future<void> reset() async {
    mode = null;
    notifyListeners();
    await SecureStorage.instance.clearAppMode();
  }
}

/// Shared "leave this mode" flow — clears the local mode so `_RootGate`
/// (see main.dart) shows `RolePickerScreen` again, then pops back to the
/// first route so nothing pushed on top (Profile, or an AppShell tab) is
/// left behind. Used by ProfileScreen's Switch Role action and by
/// AppShell's back-button handling (pressing back while on the Dashboard
/// tab).
Future<void> switchRole(BuildContext context) async {
  await context.read<AppModeProvider>().reset();
  if (context.mounted) {
    Navigator.of(context).popUntil((route) => route.isFirst);
  }
}
