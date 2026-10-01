import 'package:flutter/material.dart';

/// How close to the end of a list (in logical pixels) the next page is asked for.
const ncLoadMoreExtent = 300.0;

/// Whether [controller]'s list is scrolled to within [ncLoadMoreExtent] of its
/// end — also true for a list too short to scroll at all, which is what keeps a
/// tall screen loading pages until it is filled.
bool nearListEnd(ScrollController controller) {
  if (!controller.hasClients) return false;
  final position = controller.position;
  if (!position.hasContentDimensions) return false;
  return position.extentAfter < ncLoadMoreExtent;
}

/// "Showing 20 of 134 NCs" while more are left, "134 NCs" once all are loaded —
/// the server's own count, whatever has been loaded so far.
class NcCountLine extends StatelessWidget {
  final int loaded;
  final int? total;
  final bool hasMore;
  final String noun;
  final String nounOne;

  const NcCountLine({
    super.key,
    required this.loaded,
    required this.total,
    required this.hasMore,
    this.noun = 'NCs',
    this.nounOne = 'NC',
  });

  @override
  Widget build(BuildContext context) {
    final count = total ?? loaded;
    final text = hasMore && total != null
        ? 'Showing $loaded of $total $noun'
        : '$count ${count == 1 ? nounOne : noun}';
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.outline,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

/// The last row of a paged list: a small spinner while the next page loads (or is
/// about to — the scroll listener asks as the end comes near), a "Try again" when
/// that page failed, and for a list that does not load on scroll (a place's NCs
/// inside the location-wise view) a "Show N more" button.
class NcPageFooter extends StatelessWidget {
  final bool hasMore;
  final bool isLoadingMore;

  /// The failed page's message; non-null shows the retry row.
  final String? error;
  final VoidCallback onRetry;

  /// When set, an idle list with more left offers this button instead of waiting
  /// for the scroll.
  final VoidCallback? onLoadMore;

  /// How many are left, for the button's label (null: just "Show more").
  final int? remaining;

  const NcPageFooter({
    super.key,
    required this.hasMore,
    required this.isLoadingMore,
    required this.error,
    required this.onRetry,
    this.onLoadMore,
    this.remaining,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
            TextButton.icon(
              key: const ValueKey('nc-page-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (isLoadingMore || (hasMore && onLoadMore == null)) {
      return const Padding(
        key: ValueKey('nc-page-spinner'),
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (hasMore) {
      final left = remaining;
      return Center(
        child: TextButton(
          key: const ValueKey('nc-page-more'),
          onPressed: onLoadMore,
          child: Text(left != null && left > 0 ? 'Show $left more' : 'Show more'),
        ),
      );
    }
    return const SizedBox(height: 8);
  }
}
