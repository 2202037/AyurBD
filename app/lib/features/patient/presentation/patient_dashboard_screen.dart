/// §5.1 — the patient landing dashboard.
///
/// Called from the home tab's quick-action grid. Shows appointment stats,
/// upcoming bookings, and recent reviews — three boxes that answer "what needs
/// my attention right now?" without scrolling. Each box navigates to its full
/// list, so this is a jump-off point rather than a destination.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/appointment_models.dart';
import '../../../models/patient_models.dart';
import '../data/patient_repository.dart';

final _dashboardProvider = FutureProvider.autoDispose<PatientDashboard>((ref) {
  return ref.watch(patientRepositoryProvider).dashboard();
});

class PatientDashboardScreen extends ConsumerWidget {
  const PatientDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_dashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: async.when(
        loading: () => const LoadingView(message: 'Loading your overview…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(_dashboardProvider),
        ),
        data: (dash) => RefreshIndicator(
          onRefresh: () => ref.refresh(_dashboardProvider.future),
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.gap),
            children: [
              _StatsCard(stats: dash.stats),
              const SizedBox(height: AppTheme.gap),
              _UpcomingBox(
                appointments: dash.upcoming,
                onSeeAll: () => context.go(Routes.appointments),
              ),
              const SizedBox(height: AppTheme.gap),
              _ReviewsBox(
                reviews: dash.recentReviews,
                onSeeAll: () => context.push(Routes.myReviews),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});

  final PatientStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your appointments',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (stats.needsAttention) ...[
              const SizedBox(height: 8),
              _AttentionBanner(
                message:
                    '${stats.pendingPayments} appointment${stats.pendingPayments == 1 ? '' : 's'} '
                    'waiting for payment.',
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: [
                _Stat('Total', stats.total, AppColors.primary),
                _Stat('Pending', stats.pending, AppColors.warning),
                _Stat('Confirmed', stats.confirmed, AppColors.success),
                _Stat('Completed', stats.completed, AppColors.primary),
                _Stat('Cancelled', stats.cancelled, AppColors.danger),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "You have something waiting" strip inside the stats card.
///
/// Pulled out of [_StatsCard] so the warning colour can be resolved against the
/// active theme — the light-mode amber is far too dark to read on the dark
/// surface, and it is used here as both an icon and small bold text.
class _AttentionBanner extends StatelessWidget {
  const _AttentionBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = AppSemantic.of(context);
    final tone = sem.warning;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: sem.tintAlpha),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tone.withValues(alpha: sem.tintBorderAlpha)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 18, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: tone,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.color);

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Painted as a large number, so it needs the brightness-matched variant.
    final tone = AppSemantic.of(context).resolve(color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: theme.textTheme.titleLarge?.copyWith(
            color: tone,
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _UpcomingBox extends StatelessWidget {
  const _UpcomingBox({required this.appointments, required this.onSeeAll});

  final List<Appointment> appointments;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Upcoming',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: onSeeAll,
                  child: const Text('See all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (appointments.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'No upcoming appointments.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              for (final a in appointments.take(3)) ...[
                _AppointmentRow(appointment: a),
                if (a != appointments.take(3).last) const Divider(height: 16),
              ],
          ],
        ),
      ),
    );
  }
}

class _AppointmentRow extends StatelessWidget {
  const _AppointmentRow({required this.appointment});

  final Appointment appointment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = appointment;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                a.doctorName,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                a.whenLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        StatusPill(status: a.status, dense: true),
      ],
    );
  }
}

class _ReviewsBox extends StatelessWidget {
  const _ReviewsBox({required this.reviews, required this.onSeeAll});

  final List<MyReview> reviews;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent reviews',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: onSeeAll,
                  child: const Text('See all'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (reviews.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text(
                    'You have not written any reviews yet.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              for (final r in reviews.take(3)) ...[
                _ReviewRow(review: r),
                if (r != reviews.take(3).last) const Divider(height: 16),
              ],
          ],
        ),
      ),
    );
  }
}

class _ReviewRow extends StatelessWidget {
  const _ReviewRow({required this.review});

  final MyReview review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                review.displayTarget,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  for (var i = 0; i < 5; i++)
                    Icon(
                      i < review.rating ? Icons.star : Icons.star_border,
                      size: 14,
                      color: AppSemantic.of(context).warning,
                    ),
                  const SizedBox(width: 6),
                  Text(
                    review.dateLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        StatusPill(status: review.status, dense: true),
      ],
    );
  }
}
