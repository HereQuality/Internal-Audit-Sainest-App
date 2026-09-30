import 'package:flutter/material.dart';

/// How many columns a fixed-tile-width grid should use at the CURRENT
/// screen width — the one piece of tablet-readiness math every stat grid in
/// the app shares (dashboard_screen.dart's AuditStatsGrid,
/// auditee_dashboard_screen.dart's _AuditeeStatsGrid), so a wide tablet
/// actually spreads its tiles out
/// instead of the same fixed 2 columns just stretching wider and wider.
///
/// [tileWidth] is "how wide is one tile comfortable at" — dividing the
/// available width by it and flooring answers "how many of those fit",
/// then [min]/[max] clamp that so this NEVER drops below the phone layout
/// every grid already ships today (min: 2 — a ~375-430pt phone divided by
/// the 180 default floors to 2 either way, but the clamp is what GUARANTEES
/// it rather than relying on the arithmetic to keep landing there) and
/// never grows into an absurd number of skinny columns on a very wide
/// display (max: 5).
///
/// MediaQuery.sizeOf (not MediaQuery.of) — a caller only ever reads the
/// screen size here, and .sizeOf scopes the rebuild to just a SIZE change,
/// not every other MediaQueryData field (keyboard inset, text scale,
/// padding) the way .of would.
int responsiveColumnCount(
  BuildContext context, {
  double tileWidth = 180,
  int min = 2,
  int max = 5,
}) {
  final width = MediaQuery.sizeOf(context).width;
  // num.clamp (even int.clamp(int, int)) is statically typed to return
  // num, not int — .toInt() is what actually gets this back to the `int`
  // this function promises, not just a runtime coincidence.
  return (width / tileWidth).floor().clamp(min, max).toInt();
}
