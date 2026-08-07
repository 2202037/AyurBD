/// §6–§9 — "reviews about me", shared by the doctor and the three place roles.
///
/// Pending rows are included on purpose: a provider should see what is about to
/// go public while there is still time to reply out of band. Only approved rows
/// count toward the public average, so each card says whether it is live — a
/// 1-star pending review otherwise looks like it has already done the damage.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/provider_models.dart';
import 'provider_controllers.dart';

const _filters = <({String? value, String label})>[
  (value: null, label: 'All'),
  (value: 'pending', label: 'Pending'),
  (value: 'approved', label: 'Published'),
  (value: 'rejected', label: 'Rejected'),
];

class ProviderReviewsScreen extends ConsumerWidget {
  const ProviderReviewsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(providerReviewsProvider);
    final filter = ref.watch(providerReviewStatusProvider);
    final controller = ref.read(providerReviewsProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reviews about me'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 8),
            child: Row(
              children: [
                for (final f in _filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.label),
                      selected: filter == f.value,
                      onSelected: (_) => ref
                          .read(providerReviewStatusProvider.notifier)
                          .state = f.value,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: PagedListView<ProviderReview>(
        state: state,
        onRefresh: controller.refresh,
        onLoadMore: controller.loadMore,
        onRetry: controller.reload,
        emptyTitle: 'No reviews yet',
        emptyIcon: Icons.reviews_outlined,
        emptyMessage: filter == null
            ? 'Patients you have seen can leave a review, and they will appear '
                'here — including any waiting on moderation.'
            : 'Nothing with that status.',
        itemBuilder: (context, r, _) => _ReviewCard(review: r),
      ),
    );
  }
}

/// A read-only card. There is no reply endpoint for a provider in this schema —
/// only an admin can respond to feedback — so offering a reply box here would be
/// a button that cannot do anything.
class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review});

  final ProviderReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = review;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AvatarCircle(
                  imagePath: r.reviewerImage,
                  name: r.reviewerName,
                  size: 40,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.reviewerName ?? 'Patient',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Row(
                        children: [
                          _Stars(rating: r.rating),
                          const SizedBox(width: 8),
                          Text(r.dateLabel,
                              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        ],
                      ),
                    ],
                  ),
                ),
                StatusPill(
                  status: r.status,
                  label: r.isApproved ? 'Published' : null,
                  dense: true,
                ),
              ],
            ),
            if (r.comment != null && r.comment!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(r.comment!, style: theme.textTheme.bodyMedium),
            ],
            // Spell out the moderation state, because "pending" alone does not
            // tell a provider whether patients can already see this.
            if (!r.affectsRating) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(
                    r.isPending
                        ? Icons.visibility_off_outlined
                        : Icons.block_outlined,
                    size: 14,
                    color: muted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      r.isPending
                          ? 'Not visible to patients yet and not counted in your '
                              'rating — an administrator is reviewing it.'
                          : 'Rejected by an administrator. It is not public and '
                              'does not affect your rating.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  const _Stars({required this.rating});

  final int rating;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating ? Icons.star_rounded : Icons.star_outline_rounded,
            size: 15,
            color: AppSemantic.of(context).warning,
          ),
      ],
    );
  }
}
