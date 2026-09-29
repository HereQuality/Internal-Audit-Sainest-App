import 'package:flutter/material.dart';

/// Caps a screen's main scrollable content at a comfortable reading width
/// on a tablet, instead of letting the flat EdgeInsets padding every screen
/// already uses stretch a Row of stat tiles / a filter bar / a list card
/// across the full 10-12" width the way it does today. Below [breakpoint]
/// this is a pure pass-through (no ConstrainedBox/Center at all), so it
/// does not touch a single phone-width layout — only a screen actually
/// wide enough to look stretched gets narrowed and centred.
///
/// Deliberately a THIN wrapper: it takes whatever scroll view (or, for a
/// loading/error/empty placeholder, whatever plain widget) a screen already
/// builds and wraps it whole, rather than reaching into that widget's own
/// Row/Expanded/Card structure — every call site below is a one-line wrap
/// of an existing subtree, never a restructuring of it.
///
/// For a plain ListView/Column-based screen this goes directly around that
/// scroll view. For a sliver-based CustomScrollView (both dashboards) it
/// goes around the WHOLE CustomScrollView, not its individual slivers —
/// wrapping each SliverToBoxAdapter's child separately would cap every
/// sliver's width independently, which is equivalent for centering but
/// would also require constraining N call sites instead of one, and would
/// leave a future sliver added to the list uncapped unless someone
/// remembered to wrap it too. Wrapping the CustomScrollView itself is also
/// safe for a scroll view anchored with a sliver `center` key (my_audits_
/// screen.dart's Today anchor): that anchoring is purely about vertical
/// scroll offset, and ConstrainedBox/Center here only ever affect the
/// cross axis (width), so the anchor and the reverse-growth past region
/// behave exactly as before, just inside a narrower, centred column.
class MaxWidthScroll extends StatelessWidget {
  final Widget child;

  /// Screen width below which this is a no-op pass-through.
  final double breakpoint;

  /// The width [child] is capped to once [breakpoint] is reached.
  final double maxWidth;

  const MaxWidthScroll({
    super.key,
    required this.child,
    this.breakpoint = 700,
    this.maxWidth = 720,
  });

  @override
  Widget build(BuildContext context) {
    // MediaQuery.sizeOf, not .of: this only ever needs the width, and
    // .sizeOf scopes the rebuild to a SIZE change instead of every
    // MediaQueryData field (keyboard inset, text scale, padding...).
    if (MediaQuery.sizeOf(context).width < breakpoint) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
