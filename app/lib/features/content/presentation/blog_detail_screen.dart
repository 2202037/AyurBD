/// `/blog/{slug}` — a single article plus up to four related ones.
///
/// The list endpoint omits `content` from its SELECT, so [BlogPost.content] is
/// null on anything that arrived via [blogProvider] ([BlogPost.isSummaryOnly]).
/// This screen therefore always fetches by slug rather than accepting a
/// pre-loaded post as a constructor argument.
///
/// `content` is a plain `TEXT` column, not Markdown or HTML — the seed data is
/// prose paragraphs. It is rendered as text split on blank lines; running it
/// through a Markdown parser would invent formatting the CMS never promised, and
/// rendering it as HTML would be an injection surface.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../data/content_repository.dart';

final blogArticleProvider =
    FutureProvider.family<BlogArticle, String>((ref, slug) async {
  return ref.watch(contentRepositoryProvider).post(slug);
});

class BlogDetailScreen extends ConsumerWidget {
  const BlogDetailScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(blogArticleProvider(slug));

    return Scaffold(
      appBar: AppBar(
        title: Text(async.valueOrNull?.article.category ?? 'Article'),
      ),
      body: async.when(
        loading: () => const LoadingView(message: 'Loading article…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(blogArticleProvider(slug)),
        ),
        data: (data) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(blogArticleProvider(slug)),
          child: _Article(data: data),
        ),
      ),
    );
  }
}

class _Article extends StatelessWidget {
  const _Article({required this.data});

  final BlogArticle data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final post = data.article;

    // Blank-line-separated paragraphs. A single \n inside a paragraph is a soft
    // wrap in the source and is left to the text layout.
    final paragraphs = (post.content ?? post.excerpt ?? '')
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.gap, AppTheme.gap, AppTheme.gap, AppTheme.gap * 2),
      children: [
        if (post.image != null) ...[
          RemoteImage(
            path: post.image,
            height: 200,
            width: double.infinity,
            radius: AppTheme.radius,
            fallbackIcon: Icons.article_outlined,
          ),
          const SizedBox(height: AppTheme.gap),
        ],
        if (post.category != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              post.category!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Text(post.title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 10),
        Row(
          children: [
            AvatarCircle(name: post.authorName ?? 'AYUR', size: 32),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    post.authorName ?? 'AYUR',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    Fmt.dayFull(post.publishedAt),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.gap),
        Divider(height: 1, color: theme.dividerColor),
        const SizedBox(height: AppTheme.gap),
        if (paragraphs.isEmpty)
          Text(
            'This article has no body text yet.',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          )
        else
          for (final p in paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                p,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
              ),
            ),
        if (data.related.isNotEmpty) ...[
          const SizedBox(height: 8),
          Divider(height: 1, color: theme.dividerColor),
          const SizedBox(height: AppTheme.gap),
          const SectionHeader(title: 'Related articles'),
          for (final r in data.related) _RelatedRow(post: r),
        ],
      ],
    );
  }
}

class _RelatedRow extends StatelessWidget {
  const _RelatedRow({required this.post});

  final BlogPost post;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        // `pushReplacement` so a chain of related taps does not build a back
        // stack the user has to unwind one article at a time.
        onTap: () => context.pushReplacement(Routes.blogPost(post.slug)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              RemoteImage(
                path: post.image,
                width: 64,
                height: 64,
                fallbackIcon: Icons.article_outlined,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.title,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      Fmt.dayMonth(post.publishedAt),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}
