/// The rendering half of [PagedController].
///
/// [PagedState] has five visually distinct situations — first load, first-page
/// failure, empty result, rows, rows plus a failed next page — and getting one of
/// them wrong is the usual reason a list screen looks broken offline. Deciding
/// between them once here keeps the six list screens down to a row builder.
library;

import 'package:flutter/material.dart';

import '../constants/app_theme.dart';
import '../paged_controller.dart';
import 'state_views.dart';

class PagedListView<T> extends StatelessWidget {
  const PagedListView({
    super.key,
    required this.state,
    required this.itemBuilder,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onRetry,
    this.emptyMessage = 'Nothing to show yet.',
    this.emptyTitle,
    this.emptyIcon = Icons.inbox_outlined,
    this.padding = const EdgeInsets.fromLTRB(
      AppTheme.gap,
      AppTheme.gap,
      AppTheme.gap,
      AppTheme.gap * 2,
    ),
    this.gap = 12,
  });

  final PagedState<T> state;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final Future<void> Function() onRefresh;
  final VoidCallback onLoadMore;
  final VoidCallback onRetry;

  final String emptyMessage;
  final String? emptyTitle;
  final IconData emptyIcon;
  final EdgeInsets padding;

  /// Vertical space between rows.
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (state.isInitialLoad) return const LoadingView();
    if (state.isFirstPageError) {
      return ErrorView(error: state.error!, onRetry: onRetry);
    }

    // Even the empty state sits inside the RefreshIndicator: "no results" is very
    // often a stale answer, and the pull gesture is the obvious way to retry it.
    if (state.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          padding: padding,
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.12),
            EmptyView(message: emptyMessage, title: emptyTitle, icon: emptyIcon),
          ],
        ),
      );
    }

    // One extra slot for the footer — spinner, retry row, or nothing.
    final count = state.items.length + 1;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: LoadMoreOnScroll(
        onLoadMore: onLoadMore,
        child: ListView.separated(
          padding: padding,
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: count,
          separatorBuilder: (_, i) => SizedBox(height: i == count - 2 ? 0 : gap),
          itemBuilder: (context, i) {
            // The footer's retry is `onLoadMore`, not `onRetry`: the failure was a
            // later page, and a full reload would discard the rows on screen.
            if (i == state.items.length) return _Footer(state: state, onRetry: onLoadMore);
            return itemBuilder(context, state.items[i], i);
          },
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.state, required this.onRetry});

  final PagedState<dynamic> state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (state.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }

    if (state.hasTrailingError) {
      final theme = Theme.of(context);
      return Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Column(
          children: [
            Text(
              'Could not load more.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(64, 40),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      );
    }

    // End of the list: a quiet full stop, so the last row does not look cut off.
    if (!state.hasMore && state.items.length > 6) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Center(
          child: Text(
            '${state.meta.total} result${state.meta.total == 1 ? '' : 's'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      );
    }

    return const SizedBox(height: 4);
  }
}
