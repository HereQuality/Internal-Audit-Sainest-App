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

  /// Rows before the first loaded one (a paged list on page 3 of 20-row pages:
  /// 40) — the line then reads "Showing 41–60 of 134 NCs".
  final int offset;

  const NcCountLine({
    super.key,
    required this.loaded,
    required this.total,
    required this.hasMore,
    this.noun = 'NCs',
    this.nounOne = 'NC',
    this.offset = 0,
  });

  @override
  Widget build(BuildContext context) {
    final count = total ?? loaded;
    final text = offset > 0 && total != null
        ? 'Showing ${offset + 1}–${offset + loaded} of $total $noun'
        : hasMore && total != null
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

/// Prev / "Page X of Y" / Next for a list that shows one page at a time. Hidden
/// while everything fits one page. [busy] (a page on its way) greys both buttons
/// so a double tap cannot skip a page.
class NcPagerBar extends StatelessWidget {
  final int page;
  final int totalPages;
  final bool busy;
  final ValueChanged<int> onPage;

  const NcPagerBar({
    super.key,
    required this.page,
    required this.totalPages,
    required this.onPage,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('nc-page-prev'),
            onPressed: busy || page <= 1 ? null : () => onPage(page - 1),
            icon: const Icon(Icons.chevron_left, size: 20),
            label: const Text('Prev'),
          ),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                busy ? 'Loading…' : 'Page $page of $totalPages',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          OutlinedButton(
            key: const ValueKey('nc-page-next'),
            onPressed: busy || page >= totalPages ? null : () => onPage(page + 1),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [Text('Next'), Icon(Icons.chevron_right, size: 20)]),
          ),
        ],
      ),
    );
  }
}

/// The small twin of [NcPagerBar] for the top of a paged list, beside the count line:
/// ‹ 2/14 ›. Same pages, same [busy] rule; hidden while everything fits one page.
class NcPagerCompact extends StatelessWidget {
  final int page;
  final int totalPages;
  final bool busy;
  final ValueChanged<int> onPage;

  const NcPagerCompact({
    super.key,
    required this.page,
    required this.totalPages,
    required this.onPage,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (totalPages <= 1) return const SizedBox.shrink();
    final outline = Theme.of(context).colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const ValueKey('nc-page-prev-top'),
          tooltip: 'Previous page',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: busy || page <= 1 ? null : () => onPage(page - 1),
          icon: const Icon(Icons.chevron_left),
        ),
        Text(
          '$page/$totalPages',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: outline, fontWeight: FontWeight.w700),
        ),
        IconButton(
          key: const ValueKey('nc-page-next-top'),
          tooltip: 'Next page',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
          onPressed: busy || page >= totalPages ? null : () => onPage(page + 1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}
