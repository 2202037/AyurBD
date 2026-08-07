/// `/directory/doctors/{id}` — profile, schedule, reviews, and the booking CTA.
///
/// One request feeds the whole screen: the endpoint answers `{doctor, reviews}`,
/// so the reviews list needs no second round-trip. The booking button is pinned
/// to the bottom rather than living in the scroll body — it is the only reason
/// most users open this screen, and it should never be below the fold.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../../../models/directory_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/directory_repository.dart';

final doctorDetailProvider =
    FutureProvider.autoDispose.family<DoctorDetail, int>((ref, id) {
  return ref.watch(directoryRepositoryProvider).doctor(id);
});

class DoctorDetailScreen extends ConsumerWidget {
  const DoctorDetailScreen({super.key, required this.doctorId});

  final int doctorId;

  /// Doctor reviews must reference one of the patient's own appointments with
  /// this doctor (enforced by `guard_reviews_insert`), so this cannot open the
  /// review sheet directly — it has no appointment context. The patient is sent
  /// to My appointments instead, where each booking carries its own Review
  /// action. Signed-out users go to login first: `POST /reviews` requires auth
  /// and would answer 401, which the interceptor turns into a silent logout —
  /// the tap would appear to do nothing at all.
  Future<void> _writeReview(
    BuildContext context,
    WidgetRef ref,
    Doctor doctor,
  ) async {
    if (!ref.read(authControllerProvider).isAuthenticated) {
      context.push(Routes.login);
      return;
    }
    showToast(
      context,
      'Review this doctor from your appointment — tap Review on it in My appointments.',
    );
    context.push(Routes.appointments);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(doctorDetailProvider(doctorId));

    return Scaffold(
      appBar: AppBar(title: const Text('Doctor')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(doctorDetailProvider(doctorId)),
        ),
        data: (detail) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(doctorDetailProvider(doctorId));
            await ref.read(doctorDetailProvider(doctorId).future);
          },
          child: _Body(
            detail: detail,
            onWriteReview: () => _writeReview(context, ref, detail.doctor),
          ),
        ),
      ),
      bottomNavigationBar: async.maybeWhen(
        data: (detail) => _BookBar(doctor: detail.doctor),
        // No bar while loading or on error: an enabled "Book" button over an
        // unknown doctor would push a booking screen that cannot name its target.
        orElse: () => null,
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.detail, required this.onWriteReview});

  final DoctorDetail detail;

  /// Passed in rather than resolved here: this widget has no `ref`, and the
  /// sign-in check plus provider invalidation both belong to the screen.
  final VoidCallback onWriteReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = detail.doctor;

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppTheme.gap, AppTheme.gap, AppTheme.gap, 32),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        _ProfileHeader(doctor: d),
        const SizedBox(height: 16),
        _StatRow(doctor: d),
        const SizedBox(height: 20),
        if (d.bio != null && d.bio!.isNotEmpty) ...[
          const SectionHeader(title: 'About'),
          Text(d.bio!, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 20),
        ],
        const SectionHeader(title: 'Chamber & schedule'),
        _ScheduleCard(doctor: d),
        const SizedBox(height: 20),
        SectionHeader(
          title: detail.reviews.isEmpty
              ? 'Reviews'
              : 'Reviews (${d.reviewCount > 0 ? d.reviewCount : detail.reviews.length})',
          // The header action carries the write affordance when there are
          // already reviews; the empty state carries its own button instead, so
          // the invitation is not duplicated on the same screen.
          actionLabel: detail.reviews.isEmpty ? null : 'Write a review',
          onAction: detail.reviews.isEmpty ? null : onWriteReview,
        ),
        if (detail.reviews.isEmpty)
          EmptyView(
            message: 'No reviews yet. Be the first after your visit.',
            icon: Icons.rate_review_outlined,
            actionLabel: 'Write a review',
            onAction: onWriteReview,
          )
        else
          for (final r in detail.reviews)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: ReviewTile(review: r),
            ),
      ],
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.doctor});

  final Doctor doctor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RemoteImage(
          path: doctor.image,
          width: 96,
          height: 112,
          radius: AppTheme.radius,
          fallbackIcon: Icons.person_outline,
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(doctor.name, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(
                doctor.specialty,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              if (doctor.qualifications != null) ...[
                const SizedBox(height: 4),
                Text(doctor.qualifications!, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  // Derived from whether a schedule exists, not from a stored
                  // flag — see Doctor.isAvailable.
                  StatusPill(
                    status: doctor.isAvailable ? 'active' : 'inactive',
                    label: doctor.isAvailable ? 'Accepting patients' : 'Schedule not set',
                    dense: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Rating / experience / fee, as three equal columns.
class _StatRow extends StatelessWidget {
  const _StatRow({required this.doctor});

  final Doctor doctor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        children: [
          _Stat(
            label: doctor.reviewCount == 1 ? '1 review' : '${doctor.reviewCount} reviews',
            value: Fmt.rating(doctor.rating),
          ),
          const _Divider(),
          _Stat(label: 'Experience', value: '${doctor.experienceYears} yrs'),
          const _Divider(),
          _Stat(label: 'Consultation', value: doctor.feeLabel),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(label, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 30,
        child: VerticalDivider(
          width: 1,
          color: Theme.of(context).dividerColor,
        ),
      );
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.doctor});

  final Doctor doctor;

  @override
  Widget build(BuildContext context) {
    final hours = doctor.hoursLabel;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          children: [
            // `workplace` is free text (`doctors.hospital_clinic_name`), not a
            // link to a clinic row — there is no FK to follow, so this is a
            // label rather than a tappable destination.
            _Line(
              icon: Icons.local_hospital_outlined,
              label: doctor.workplace ?? 'Independent practice',
            ),
            if (doctor.chamberAddress != null || doctor.area != null || doctor.city != null)
              _Line(
                icon: Icons.place_outlined,
                label: [doctor.chamberAddress, doctor.area, doctor.city]
                    .where((e) => e != null && e.isNotEmpty)
                    .join(', '),
              ),
            _Line(icon: Icons.event_available_outlined, label: doctor.daysLabel),
            if (hours.isNotEmpty) _Line(icon: Icons.schedule_outlined, label: hours),
            _Line(
              icon: Icons.timelapse_outlined,
              label: '${doctor.slotMinutes}-minute slots',
            ),
            if (doctor.phone != null)
              _Line(icon: Icons.phone_outlined, label: doctor.phone!),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Pinned booking bar. Shows the fee next to the button so the price is visible
/// at the moment of commitment, not two screens earlier.
class _BookBar extends StatelessWidget {
  const _BookBar({required this.doctor});

  final Doctor doctor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(AppTheme.gap, 8, AppTheme.gap, 12),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Consultation', style: theme.textTheme.bodySmall),
              Text(
                doctor.feeLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: FilledButton.icon(
              onPressed: doctor.isAvailable
                  ? () => context.push(Routes.book(doctor.id))
                  : null,
              icon: const Icon(Icons.event_available),
              label: Text(doctor.isAvailable ? 'Book appointment' : 'Not available'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared with the place detail screen.
class ReviewTile extends StatelessWidget {
  const ReviewTile({super.key, required this.review});

  final Review review;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AvatarCircle(imagePath: review.userImage, name: review.userName, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        review.userName ?? 'Patient',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(review.dateLabel, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                _Stars(rating: review.rating),
              ],
            ),
            if (review.comment != null && review.comment!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(review.comment!, style: theme.textTheme.bodyMedium),
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
    final color = Theme.of(context).colorScheme.tertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(
            i <= rating ? Icons.star_rounded : Icons.star_border_rounded,
            size: 15,
            color: color,
          ),
      ],
    );
  }
}
