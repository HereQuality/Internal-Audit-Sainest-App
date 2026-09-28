import 'package:flutter/foundation.dart';

import '../widgets/audit_agenda.dart' show AgendaExpansion;

/// What one list screen should look like when you come back to it: the
/// search text, its own tab/chip pick and the scroll offset.
class ListScreenMemory {
  String search = '';
  String chip = 'All';
  int tab = 0;
  double scroll = 0;

  /// The second scroll position of a two-tab screen (NC: "raised by me" vs
  /// "against me"), keyed by tab index.
  final Map<int, double> tabScroll = {};

  /// Anything else a screen wants back (Final Report: the picked view, the
  /// group-by-location switch, the one expanded card).
  final Map<String, Object?> extra = {};
}

/// Provider-held UI state that must SURVIVE navigation (open an audit, press
/// Back, and the list is exactly as you left it — same expanded section, same
/// scroll position, same search/tab) and be WIPED on logout.
///
/// A screen's own State already survives a push/pop and a tab swipe (AppShell
/// keeps every tab alive), but not a remount — AppShell re-creates the Audits
/// / NC tab under a fresh key on a dashboard tile jump, and a role switch
/// rebuilds the shell. Holding the state here, in a process-lifetime provider,
/// covers those too, and gives logout one place to clear it so the next
/// account never inherits the previous one's expanded groups or search text
/// (see main.dart's logout block, which calls [resetForLogout]).
///
/// The FILTERS themselves are not stored here: they live on the filter-holding
/// providers (AuditFilterScope), which the shared bar/sheet already keep in
/// step across screens.
class ListViewMemory extends ChangeNotifier {
  /// Which agenda groups are open — one at a time (accordion), see
  /// [AgendaExpansion].
  AgendaExpansion agendaExpansion = AgendaExpansion();

  final Map<String, ListScreenMemory> _screens = {};

  /// The remembered state of the screen called [id] (created on first use).
  ListScreenMemory screen(String id) =>
      _screens.putIfAbsent(id, ListScreenMemory.new);

  /// Forget one screen's state (a deliberate fresh start, e.g. arriving via
  /// a dashboard tile that pre-applies its own filter).
  void forget(String id) => _screens.remove(id);

  /// Back to a blank slate — call on logout. Doesn't notify: nothing listens
  /// to this provider, it is read once by a screen as it is created.
  void resetForLogout() {
    agendaExpansion = AgendaExpansion();
    _screens.clear();
  }
}
