/// `/directory/{clinics|hospitals|pharmacies}/{id}` — one screen for all three.
///
/// `place_detail()` returns the place plus *either* its doctors (clinic,
/// hospital) *or* its products (pharmacy), and always its recent reviews. Rather
/// than branching on [PlaceKind], this screen simply renders whichever of those
/// lists came back non-empty — the server already decided which one applies, and
/// duplicating that decision here would be two places to keep in sync.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../../../models/directory_models.dart';
import '../../../models/pharmacy_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../patient/presentation/review_sheet.dart';
import '../data/directory_repository.dart';
import 'doctor_detail_screen.dart' show ReviewTile;
import 'doctors_screen.dart' show DoctorCard;
import 'places_screen.dart' show placeKindIcon;

/// Keyed by a `(kind, id)` record: ids are only unique *within* a kind, so
/// clinic 3 and hospital 3 must not share a cache entry. Records give value
/// equality for free, which is exactly what a family key needs.
typedef PlaceKey = ({PlaceKind kind, int id});

final placeDetailProvider =
    FutureProvider.autoDispose.family<PlaceDetail, PlaceKey>((ref, key) {
  return ref.watch(directoryRepositoryProvider).place(key.kind, key.id);
});

class PlaceDetailScreen extends ConsumerWidget {
  const PlaceDetailScreen({super.key, required this.kind, required this.id});

  final PlaceKind kind;
  final int id;

  /// [PlaceKind] and [ReviewTarget] happen to share these three spellings, but
  /// they are switched explicitly rather than matched by `name`: the review enum
  /// also carries `doctor` and `product`, and `content.php` accepts only the
  /// four values in the live `reviews.target_type` column. An exhaustive switch
  /// means adding a place kind is a compile error here rather than a 422 at
  /// runtime.
  ReviewTarget get _reviewTarget {
    switch (kind) {
      case PlaceKind.clinic:
        return ReviewTarget.clinic;
      case PlaceKind.hospital:
        return ReviewTarget.hospital;
      case PlaceKind.pharmacy:
        return ReviewTarget.pharmacy;
    }
  }

  /// Signed-out users go to login first: `POST /reviews` requires auth, and the
  /// 401 would be swallowed as a logout, making the tap look inert.
  Future<void> _writeReview(
    BuildContext context,
    WidgetRef ref,
    Place place,
  ) async {
    if (!ref.read(authControllerProvider).isAuthenticated) {
      context.push(Routes.login);
      return;
    }
    final done = await showReviewSheet(
      context,
      target: _reviewTarget,
      targetId: id,
      targetName: place.name,
    );
    // See doctor_detail_screen: a ConsumerWidget has no `mounted`, and using a
    // WidgetRef after the element is disposed throws.
    if (done == true && context.mounted) {
      ref.invalidate(placeDetailProvider((kind: kind, id: id)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (kind: kind, id: id);
    final async = ref.watch(placeDetailProvider(key));

    return Scaffold(
      appBar: AppBar(title: Text(kind.label)),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(placeDetailProvider(key)),
        ),
        data: (detail) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(placeDetailProvider(key));
            await ref.read(placeDetailProvider(key).future);
          },
          child: _Body(
            detail: detail,
            onWriteReview: () => _writeReview(context, ref, detail.place),
          ),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.detail, required this.onWriteReview});

  final PlaceDetail detail;

  /// Supplied by the screen, which owns the `ref` needed for the sign-in check
  /// and the post-submit invalidation.
  final VoidCallback onWriteReview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = detail.place;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.gap, AppTheme.gap, AppTheme.gap, 32),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        _Header(place: p),
        const SizedBox(height: 16),
        _ContactCard(place: p),
        if (p.services.isNotEmpty) ...[
          const SizedBox(height: 20),
          const SectionHeader(title: 'Services'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in p.services)
                Chip(
                  label: Text(s),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
        if (p.about != null && p.about!.isNotEmpty) ...[
          const SizedBox(height: 20),
          const SectionHeader(title: 'About'),
          Text(p.about!, style: theme.textTheme.bodyMedium),
        ],
        if (detail.doctors.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionHeader(
            title: 'Doctors (${detail.doctors.length})',
            actionLabel: 'See all',
            onAction: () => context.go(Routes.doctors),
          ),
          for (final d in detail.doctors)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: DoctorCard(doctor: d),
            ),
        ],
        if (detail.products.isNotEmpty) ...[
          const SizedBox(height: 20),
          SectionHeader(
            title: 'Products',
            actionLabel: 'Shop all',
            onAction: () => context.go(Routes.shop),
          ),
          for (final item in detail.products)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ProductRow(product: item),
            ),
        ],
        const SizedBox(height: 20),
        SectionHeader(
          title: detail.reviews.isEmpty
              ? 'Reviews'
              : 'Reviews (${p.reviewCount > 0 ? p.reviewCount : detail.reviews.length})',
          // Only one invitation per screen: the header action when there are
          // reviews to head, the empty state's own button when there are none.
          actionLabel: detail.reviews.isEmpty ? null : 'Write a review',
          onAction: detail.reviews.isEmpty ? null : onWriteReview,
        ),
        if (detail.reviews.isEmpty)
          EmptyView(
            message: 'No reviews yet. Share your experience.',
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

class _Header extends StatelessWidget {
  const _Header({required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Deliberately not a RemoteImage. None of clinics / hospitals /
        // pharmacies stores a photo, so there is no path to load and the
        // widget could only ever render its fallback.
        Container(
          height: 120,
          width: double.infinity,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          child: Icon(
            placeKindIcon(place.kind),
            size: 48,
            color: theme.colorScheme.primary.withValues(alpha: 0.75),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(place.name, style: theme.textTheme.headlineSmall),
            ),
            if (place.isVerified) ...[
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Icon(Icons.verified,
                    size: 20, color: theme.colorScheme.primary),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star_rounded,
                    size: 17, color: theme.colorScheme.tertiary),
                const SizedBox(width: 3),
                Text(
                  place.reviewCount > 0
                      ? '${Fmt.rating(place.rating)} (${place.reviewCount})'
                      : Fmt.rating(place.rating),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
            // No distance chip — nothing in this database has coordinates. No
            // blood-bank chip either: blood stock lives in its own table and is
            // not linked to a hospital row. And there is no `is_active` column,
            // so "Closed" cannot be shown; `is_24h` is the one real opening
            // signal the pharmacy/hospital tables carry.
            if (place.is24h)
              const StatusPill(
                  status: 'available', label: 'Open 24h', dense: true),
          ],
        ),
      ],
    );
  }
}

/// Address, hours and the two things a user actually wants to *do* from a
/// directory listing: call, or find the way there.
class _ContactCard extends StatelessWidget {
  const _ContactCard({required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final hasPhone = place.phone != null && place.phone!.isNotEmpty;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Line(icon: Icons.place_outlined, label: place.locationLabel),
            if (place.openingHours != null && place.openingHours!.isNotEmpty)
              _Line(icon: Icons.schedule_outlined, label: place.openingHours!),
            if (hasPhone)
              _Line(icon: Icons.phone_outlined, label: place.phone!),
            if (place.email != null && place.email!.isNotEmpty)
              _Line(icon: Icons.mail_outline, label: place.email!),
            if (place.doctorCount > 0)
              _Line(
                icon: Icons.medical_services_outlined,
                label: '${place.doctorCount} doctor'
                    '${place.doctorCount == 1 ? '' : 's'} listed',
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (hasPhone) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _open(context, Uri(scheme: 'tel', path: place.phone)),
                      icon: const Icon(Icons.call_outlined, size: 18),
                      label: const Text('Call'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  // Hands off to whatever maps app the device has. The build
                  // ships without google_maps_flutter, so an in-app map would
                  // be a plugin dependency for a one-tap action.
                  //
                  // Searched by name + address text, not by coordinates: no
                  // table in this database stores latitude/longitude. A text
                  // search also needs no Maps API key, which keeps the build
                  // runnable out of the box.
                  child: OutlinedButton.icon(
                    onPressed: () => _open(
                      context,
                      Uri.parse(
                        'https://www.google.com/maps/search/?api=1&query='
                        '${Uri.encodeComponent(place.mapQuery)}',
                      ),
                    ),
                    icon: const Icon(Icons.directions_outlined, size: 18),
                    label: const Text('Directions'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, Uri uri) async {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    // An emulator with no dialer or browser is the common case here, and a
    // silent no-op looks like a broken button.
    if (!ok && context.mounted) {
      showToast(context, 'No app available to handle that.', error: true);
    }
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

/// A pharmacy's products, in the compact row shape this screen needs. The shop
/// grid in `products_screen` is a different shape for a different context, so
/// they deliberately do not share a widget.
class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = product.subtitle;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.productDetail(product.id)),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              RemoteImage(
                path: product.image,
                width: 56,
                height: 56,
                radius: AppTheme.radius - 4,
                fallbackIcon: Icons.medication_outlined,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      product.priceLabel,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusPill(
                status: product.stockStatus,
                label: product.stockLabel,
                dense: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
