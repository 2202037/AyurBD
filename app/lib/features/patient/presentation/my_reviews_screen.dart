/// §5.6 — the patient's own reviews.
///
/// Unlike the public review list, this one shows pending and rejected rows. The
/// server writes a `status_note` explaining why a review is not visible, so the
/// client never invents that wording — it just renders what moderation said.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/paged_controller.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/patient_models.dart';
import '../data/patient_repository.dart';

final _myReviewsProvider =
    StateNotifierProvider<PagedController<MyReview>, PagedState<MyReview>>(
        (ref) {
  final repo = ref.watch(patientRepositoryProvider);
  return PagedController<MyReview>((page) => repo.myReviews(page: page));
});

class MyReviewsScreen extends ConsumerWidget {
  const MyReviewsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(_myReviewsProvider);
    final controller = ref.read(_myReviewsProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('My reviews')),
      body: PagedListView<MyReview>(
        state: state,
        onRefresh: controller.refresh,
        onLoadMore: controller.loadMore,
        onRetry: controller.reload,
        emptyTitle: 'No reviews yet',
        emptyIcon: Icons.rate_review_outlined,
        emptyMessage:
            'After a completed appointment or order you can rate the doctor, '
            'clinic, hospital or pharmacy.',
        itemBuilder: (context, r, _) => _MyReviewCard(review: r),
      ),
    );
  }
}

class _MyReviewCard extends StatelessWidget {
  const _MyReviewCard({required this.review});

  final MyReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = review;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.displayTarget,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                StatusPill(status: r.status, label: r.statusLabel, dense: true),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                for (var i = 0; i < 5; i++)
                  Icon(
                    i < r.rating ? Icons.star : Icons.star_border,
                    size: 16,
                    color: AppSemantic.of(context).warning,
                  ),
                const SizedBox(width: 8),
                Text(
                  r.dateLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (r.comment != null) ...[
              const SizedBox(height: 8),
              Text(r.comment!, style: theme.textTheme.bodyMedium),
            ],
            // Only pending and rejected rows carry a note; an approved review is
            // simply live, and saying so would be noise.
            if (r.statusNote != null) ...[
              const SizedBox(height: 10),
              _Note(text: r.statusNote!, rejected: r.isRejected),
            ],
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text, required this.rejected});

  final String text;
  final bool rejected;

  @override
  Widget build(BuildContext context) {
    final color = rejected ? AppSemantic.of(context).danger : AppSemantic.of(context).warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            rejected ? Icons.block : Icons.hourglass_empty,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
