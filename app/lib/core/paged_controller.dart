/// Infinite-scroll plumbing, written once.
///
/// Six screens in this app show the same thing: a filterable list that loads page
/// 1, appends page 2 as you scroll, survives a failed page without losing the
/// rows already on screen, and can be pulled to refresh. Each of those screens
/// implementing it separately is how you end up with six subtly different
/// off-by-one bugs at the page boundary.
///
/// The type parameter is the row; [PagedState] is what the screen renders.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network/api_result.dart';

/// Fetches one page. Page numbers are 1-based, matching §6's `meta.page`.
typedef PageFetcher<T> = Future<Paged<T>> Function(int page);

@immutable
class PagedState<T> {
  const PagedState({
    this.items = const [],
    this.meta = const PageMeta(page: 1, limit: 0, total: 0),
    this.status = PagedStatus.initial,
    this.error,
    this.loadingMore = false,
    this.refreshing = false,
  });

  final List<T> items;
  final PageMeta meta;
  final PagedStatus status;

  /// Set only when [status] is [PagedStatus.error] (the first page failed) or
  /// when a *subsequent* page failed while rows are already on screen.
  final Object? error;

  final bool loadingMore;
  final bool refreshing;

  /// [PagedStatus.initial] counts as an initial load, not as "nothing to draw".
  ///
  /// `PagedListView` branches on exactly three predicates before falling through
  /// to the list itself. `initial` used to miss all three — not loading, not
  /// errored, not ready — so a controller sitting in `initial` rendered the list
  /// branch with zero rows plus one footer, and that footer is a 4px spacer.
  /// The screen came out as a title bar above a completely blank body: no
  /// spinner, no message, nothing to tap, no way to recover. Treat it as loading,
  /// which is what it actually means.
  bool get isInitialLoad =>
      (status == PagedStatus.loading || status == PagedStatus.initial) &&
      items.isEmpty;
  bool get isFirstPageError => status == PagedStatus.error && items.isEmpty;
  bool get isEmpty => status == PagedStatus.ready && items.isEmpty;
  bool get hasMore => meta.hasMore;

  /// A page beyond the first failed. The rows already fetched stay visible and
  /// the screen shows a retry footer instead of throwing everything away.
  bool get hasTrailingError => error != null && items.isNotEmpty;

  PagedState<T> copyWith({
    List<T>? items,
    PageMeta? meta,
    PagedStatus? status,
    Object? error,
    bool clearError = false,
    bool? loadingMore,
    bool? refreshing,
  }) =>
      PagedState<T>(
        items: items ?? this.items,
        meta: meta ?? this.meta,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
        loadingMore: loadingMore ?? this.loadingMore,
        refreshing: refreshing ?? this.refreshing,
      );
}

enum PagedStatus { initial, loading, ready, error }

/// Drives a [PagedState]. Subclass it, or use it directly with a fetcher.
///
/// Guards against the two classic infinite-scroll faults: overlapping requests
/// (a fast scroll firing `loadMore` three times for the same page) and stale
/// responses (a refresh landing after a filter change and repopulating the list
/// with rows for the old filter). The generation counter handles the second.
class PagedController<T> extends StateNotifier<PagedState<T>> {
  PagedController(this._fetch, {bool autoLoad = true}) : super(PagedState<T>()) {
    if (autoLoad) load();
  }

  PageFetcher<T> _fetch;

  /// Incremented on every reset. A response tagged with an older generation is
  /// discarded rather than applied.
  int _generation = 0;
  bool _inFlight = false;

  /// When the most recent page load failed, so the same failing page is not
  /// refired on every scroll notification while a "Try again" button is visible.
  DateTime? _lastFailureAt;

  /// Swap the fetcher (a new search term or filter) and reload from page 1.
  void setFetcher(PageFetcher<T> fetcher) {
    _fetch = fetcher;
    reload();
  }

  Future<void> load() async {
    // Returning here must not leave the controller in [PagedStatus.initial].
    // `PagedListView` has no branch for `initial`: it falls past the loading,
    // error and empty cases into the list branch, which renders one footer, and
    // the footer for an empty non-loading list is a 4px spacer. The result is a
    // screen with a title bar and a completely blank body — no spinner, no
    // message, nothing to tap. Adopt the in-flight request's loading state so
    // the user sees a spinner instead.
    if (_inFlight) {
      if (state.status == PagedStatus.initial) {
        state = state.copyWith(status: PagedStatus.loading, clearError: true);
      }
      return;
    }
    final gen = ++_generation;
    _inFlight = true;
    state = state.copyWith(status: PagedStatus.loading, clearError: true);
    try {
      final page = await _fetch(1);
      if (!mounted || gen != _generation) return;
      state = PagedState<T>(
        items: page.items,
        meta: page.meta,
        status: PagedStatus.ready,
      );
    } catch (e) {
      if (!mounted || gen != _generation) return;
      state = state.copyWith(status: PagedStatus.error, error: e);
    } finally {
      if (gen == _generation) _inFlight = false;
    }
  }

  /// Pull-to-refresh: keeps the current rows visible while page 1 refetches, so
  /// the list does not blink to a spinner under the user's finger.
  Future<void> refresh() async {
    final gen = ++_generation;
    _inFlight = true;
    state = state.copyWith(refreshing: true, clearError: true);
    try {
      final page = await _fetch(1);
      if (!mounted || gen != _generation) return;
      state = PagedState<T>(
        items: page.items,
        meta: page.meta,
        status: PagedStatus.ready,
      );
    } catch (e) {
      if (!mounted || gen != _generation) return;
      // Refresh failure keeps the stale rows — they are still better than an
      // empty screen — and surfaces the error as a trailing message.
      state = state.copyWith(
        refreshing: false,
        error: e,
        status: state.items.isEmpty ? PagedStatus.error : PagedStatus.ready,
      );
    } finally {
      if (gen == _generation) {
        _inFlight = false;
        if (mounted && state.refreshing) state = state.copyWith(refreshing: false);
      }
    }
  }

  /// Hard reset — used by [setFetcher] and by screens changing a filter.
  Future<void> reload() {
    state = PagedState<T>();
    return load();
  }

  Future<void> loadMore() async {
    // `_inFlight` is read-then-set, so two loaders can both see false and both
    // fetch the same next page. The generation guard throws the loser away —
    // but if the winner's meta is applied verbatim, the list's meta advances
    // while its rows lag, and the next scroll fetches a page that was never
    // really reached. Guard both sides: refuse to re-enter, and only advance
    // meta when the response is a strictly-newer page.
    if (_inFlight || !state.hasMore || state.status != PagedStatus.ready) return;

    // A page that already failed must not be refired by scrolling. `status` stays
    // `ready` after a trailing error (the rows on screen are still good), so
    // without this every scroll notification near the bottom retries the same
    // failing request as fast as the server can reject it. The footer's explicit
    // "Try again" is the intended way back, so allow a retry only after a short
    // cooldown rather than on every frame of a scroll.
    if (state.error != null) {
      final last = _lastFailureAt;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(seconds: 3)) {
        return;
      }
    }

    final gen = _generation;
    _inFlight = true;
    state = state.copyWith(loadingMore: true, clearError: true);
    final nextPage = state.meta.page + 1;
    try {
      final next = await _fetch(nextPage);
      if (!mounted || gen != _generation) return;
      final newer = next.meta.page > state.meta.page;
      state = state.copyWith(
        items: newer ? [...state.items, ...next.items] : state.items,
        meta: newer ? next.meta : state.meta,
        loadingMore: false,
      );
    } catch (e) {
      if (!mounted || gen != _generation) return;
      _lastFailureAt = DateTime.now();
      state = state.copyWith(loadingMore: false, error: e);
    } finally {
      if (gen == _generation) _inFlight = false;
    }
  }

  /// Replace one row in place — e.g. after cancelling an appointment, which
  /// returns the updated row. Cheaper and less jarring than a full refetch.
  void replaceWhere(bool Function(T) test, T replacement) {
    final i = state.items.indexWhere(test);
    if (i < 0) return;
    final next = [...state.items];
    next[i] = replacement;
    state = state.copyWith(items: next);
  }

  void removeWhere(bool Function(T) test) {
    final next = state.items.where((e) => !test(e)).toList();
    if (next.length != state.items.length) state = state.copyWith(items: next);
  }
}

/// Calls [onLoadMore] when the list is scrolled near its end. Wrap a
/// [ListView]/[GridView] in this rather than hand-rolling a ScrollController in
/// every screen.
///
/// Only genuine scroll movement counts. `ScrollStartNotification`,
/// `OverscrollNotification` and `UserScrollNotification` are all
/// [ScrollNotification]s too, so listening for the base type called
/// [onLoadMore] several times per gesture. `_inFlight` in [PagedController]
/// already made the extra calls harmless, so this is tidiness rather than a
/// bugfix — do not read it as the cure for a frozen screen.
///
/// Layout-only changes are *not* the source of extra calls: a change in extents
/// with no movement arrives as `ScrollMetricsNotification`, which does not
/// extend [ScrollNotification] and so never reaches this listener.
///
/// The comment this replaces claimed the metrics-based approach also covered a
/// first page too short to fill the viewport. It never did: a list that cannot
/// scroll has no scroll activity to report, so no notification is dispatched at
/// all. Such a list simply stops at page 1 — see [PagedListView], which is why
/// the footer offers an explicit control instead of relying on scrolling.
class LoadMoreOnScroll extends StatelessWidget {
  const LoadMoreOnScroll({
    super.key,
    required this.child,
    required this.onLoadMore,
    this.threshold = 320,
  });

  final Widget child;
  final VoidCallback onLoadMore;

  /// Pixels from the bottom at which to start fetching.
  final double threshold;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis != Axis.vertical) return false;

        // Movement only. `ScrollUpdateNotification` means the offset actually
        // changed; `ScrollEndNotification` catches a fling that coasts to a stop
        // inside the threshold. Everything else — start, direction change, and
        // the user-overscroll family — either precedes movement or reports a
        // layout change, and acting on those is what turned one scroll into a
        // cascade of page requests.
        if (n is! ScrollUpdateNotification && n is! ScrollEndNotification) {
          return false;
        }

        // Nothing to scroll means no page 2 by this route. Guarding it keeps a
        // collapsed or empty list from reading as "already at the bottom".
        if (n.metrics.maxScrollExtent <= 0) return false;

        final remaining = n.metrics.maxScrollExtent - n.metrics.pixels;
        if (remaining <= threshold) onLoadMore();
        return false;
      },
      child: child,
    );
  }
}
