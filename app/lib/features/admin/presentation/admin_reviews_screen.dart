/// §10.8 — the review moderation queue.
///
/// A review is invisible to the public until it is approved, so this queue is
/// the gate between someone writing a rating and it counting toward a provider's
/// average. Approving recomputes that average server-side.
///
/// Delete is separate from reject: rejecting keeps the row (the reviewer can see
/// their own submission was turned down) while delete removes it outright, which
/// is what spam warrants.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/admin_models.dart';
import '../data/admin_repository.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

/// `all` is a real value the endpoint understands as "no status clause", not a
/// null — which is why [adminReviewStatusProvider] is non-nullable.
const _statusFilters = <FilterOption>[
  (value: 'pending', label: 'Pending'),
  (value: 'approved', label: 'Approved'),
  (value: 'rejected', label: 'Rejected'),
  (value: 'all', label: 'All'),
];

/// The five reviewable targets the backend's `REVIEW_TARGETS` allows.
const _targetFilters = <FilterOption>[
  (value: null, label: 'Any type'),
  (value: 'doctor', label: 'Doctor'),
  (value: 'hospital', label: 'Hospital'),
  (value: 'clinic', label: 'Clinic'),
  (value: 'pharmacy', label: 'Pharmacy'),
  (value: 'product', label: 'Product'),
];

class AdminReviewsScreen extends ConsumerStatefulWidget {
  const AdminReviewsScreen({super.key});

  @override
  ConsumerState<AdminReviewsScreen> createState() => _AdminReviewsScreenState();
}

class _AdminReviewsScreenState extends ConsumerState<AdminReviewsScreen> {
  bool _busy = false;

  PagedController<AdminReview> get _controller =>
      ref.read(adminReviewsProvider.notifier);

  Future<void> _moderate(AdminReview r, ReviewModeration action) async {
    if (action == ReviewModeration.delete) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete this review?'),
          content: const Text(
            'The review is removed permanently. Reject it instead if the '
            'reviewer should be able to see it was turned down.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: AppTheme.destructive(ctx),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .moderateReview(reviewId: r.id, action: action);

      // Under the pending filter a decided review no longer belongs; a deleted
      // one never belongs anywhere.
      final filter = ref.read(adminReviewStatusProvider);
      if (action == ReviewModeration.delete || filter == 'pending') {
        _controller.removeWhere((row) => row.id == r.id);
      } else {
        await _controller.reload();
      }

      ref.invalidate(adminDashboardProvider);
      if (mounted) {
        showToast(
          context,
          switch (action) {
            ReviewModeration.approve => 'Review approved and now public.',
            ReviewModeration.reject => 'Review rejected.',
            ReviewModeration.delete => 'Review deleted.',
          },
        );
      }
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) {
        showToast(context, e.message, error: true);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminReviewsProvider);
    final status = ref.watch(adminReviewStatusProvider);
    final target = ref.watch(adminReviewTargetProvider);

    final bar = AdminFilterBar(
      options: _statusFilters,
      selected: status,
      // The chip strip is typed nullable but every option here carries a value,
      // so the fallback can never actually be taken.
      onSelected: (v) =>
          ref.read(adminReviewStatusProvider.notifier).state = v ?? 'all',
      trailing: DropdownButtonFormField<String?>(
        initialValue: target,
        decoration: const InputDecoration(
          labelText: 'Target',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: _targetFilters
            .map((f) => DropdownMenuItem(value: f.value, child: Text(f.label)))
            .toList(),
        onChanged: (v) => ref.read(adminReviewTargetProvider.notifier).state = v,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reviews'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving…',
        child: PagedListView<AdminReview>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: status == 'pending' ? 'Queue is clear' : 'No reviews',
          emptyIcon: Icons.rate_review_outlined,
          emptyMessage: status == 'pending'
              ? 'New reviews waiting on approval show up here.'
              : 'Nothing matches those filters.',
          itemBuilder: (context, r, _) => _ReviewCard(
            review: r,
            onModerate: (a) => _moderate(r, a),
          ),
        ),
      ),
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({required this.review, required this.onModerate});

  final AdminReview review;
  final ValueChanged<ReviewModeration> onModerate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = review;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.reviewerName ?? 'Anonymous',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${r.targetLabel} · ${r.dateLabel}',
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      ),
                    ],
                  ),
                ),
                _Stars(rating: r.rating),
              ],
            ),
            if (r.comment != null && r.comment!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(r.comment!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                StatusPill(status: r.status, dense: true),
                const Spacer(),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppSemantic.of(context).danger,
                  onPressed: () => onModerate(ReviewModeration.delete),
                ),
                if (r.status != 'rejected')
                  TextButton(
                    onPressed: () => onModerate(ReviewModeration.reject),
                    style: AppTheme.destructiveText(context),
                    child: const Text('Reject'),
                  ),
                if (r.status != 'approved') ...[
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: () => onModerate(ReviewModeration.approve),
                    style: AppTheme.rowAction,
                    child: const Text('Approve'),
                  ),
                ],
              ],
            ),
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
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating ? Icons.star : Icons.star_border,
            size: 16,
            color: AppSemantic.of(context).warning,
          ),
      ],
    );
  }
}
