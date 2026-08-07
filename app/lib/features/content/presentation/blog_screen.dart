/// `/blog` — the article list.
///
/// `blog_list()` reads exactly two filters, `search` and `category`, and its
/// `search` LIKEs `title` and `excerpt` only (not `content`, which the list query
/// deliberately omits from the SELECT). So a search for a word that appears only
/// deep inside an article returns nothing — that is the server's behaviour, and
/// the hint text says so rather than leaving the user to wonder.
///
/// There is no `/blog/categories` endpoint, so the category chips are derived
/// from the categories present in the loaded pages. That is honest about what is
/// known: a category whose articles are all on page 3 has no chip until page 3
/// loads.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../data/content_repository.dart';

@immutable
class BlogQuery {
  const BlogQuery({this.search = '', this.category});

  final String search;
  final String? category;

  /// Blank search is sent as null. `LIKE '%%'` matches everything but still pays
  /// for two comparisons per row.
  String? get searchOrNull => search.trim().isEmpty ? null : search.trim();

  BlogQuery copyWith({String? search, String? category, bool clearCategory = false}) =>
      BlogQuery(
        search: search ?? this.search,
        category: clearCategory ? null : (category ?? this.category),
      );

  @override
  bool operator ==(Object other) =>
      other is BlogQuery && other.search == search && other.category == category;

  @override
  int get hashCode => Object.hash(search, category);
}

final blogQueryProvider = StateProvider<BlogQuery>((ref) => const BlogQuery());

final blogProvider =
    StateNotifierProvider<PagedController<BlogPost>, PagedState<BlogPost>>((ref) {
  final repo = ref.watch(contentRepositoryProvider);
  final query = ref.watch(blogQueryProvider);

  return PagedController<BlogPost>((page) => repo.blog(
        page: page,
        search: query.searchOrNull,
        category: query.category,
      ));
});

class BlogScreen extends ConsumerStatefulWidget {
  const BlogScreen({super.key});

  @override
  ConsumerState<BlogScreen> createState() => _BlogScreenState();
}

class _BlogScreenState extends ConsumerState<BlogScreen> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _apply(value));
  }

  void _apply(String value) {
    _debounce?.cancel();
    final notifier = ref.read(blogQueryProvider.notifier);
    if (notifier.state.search == value) return;
    notifier.state = notifier.state.copyWith(search: value);
  }

  void _selectCategory(String? category) {
    final notifier = ref.read(blogQueryProvider.notifier);
    notifier.state = category == null
        ? notifier.state.copyWith(clearCategory: true)
        : notifier.state.copyWith(category: category);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(blogProvider);
    final controller = ref.read(blogProvider.notifier);
    final query = ref.watch(blogQueryProvider);

    // Categories seen so far, plus whichever one is selected — otherwise
    // selecting a category can filter its own chip off the strip.
    final categories = <String>{
      for (final p in state.items)
        if (p.category != null && p.category!.isNotEmpty) p.category!,
      if (query.category != null) query.category!,
    }.toList()
      ..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Health Articles')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 10, AppTheme.gap, 0),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: _apply,
              decoration: InputDecoration(
                hintText: 'Search titles and summaries',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear search',
                        onPressed: () {
                          _search.clear();
                          _apply('');
                        },
                      ),
              ),
            ),
          ),
          if (categories.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
                children: [
                  for (final c in categories)
                    Padding(
                      padding: const EdgeInsets.only(right: 8, top: 8),
                      child: FilterChip(
                        label: Text(c),
                        selected: query.category == c,
                        // Tapping the selected chip clears it. A filter you
                        // cannot undo without hunting for an "All" chip is a trap.
                        onSelected: (on) => _selectCategory(on ? c : null),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: PagedListView<BlogPost>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: 'No articles found',
              emptyIcon: Icons.article_outlined,
              emptyMessage: query.searchOrNull == null
                  ? 'Articles published by the AYUR team will appear here.'
                  : 'Nothing matched that search. Only titles and summaries are searched.',
              itemBuilder: (context, post, _) => _BlogCard(post: post),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlogCard extends StatelessWidget {
  const _BlogCard({required this.post});

  final BlogPost post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.blogPost(post.slug)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (post.image != null)
              RemoteImage(
                path: post.image,
                height: 160,
                width: double.infinity,
                radius: 0,
                fallbackIcon: Icons.article_outlined,
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (post.category != null) ...[
                    Text(
                      post.category!.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        letterSpacing: 0.6,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    post.title,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (post.excerpt != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      post.excerpt!,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.person_outline, size: 14, color: muted),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          post.authorName ?? 'AYUR',
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.schedule_outlined, size: 14, color: muted),
                      const SizedBox(width: 4),
                      Text(
                        Fmt.dayMonth(post.publishedAt),
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
