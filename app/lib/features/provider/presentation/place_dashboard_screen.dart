/// §7–9 — the landing screen for a hospital, clinic or pharmacy.
///
/// One screen for all three roles rather than three near-identical ones: the
/// backend picks the table from the caller's JWT and answers with a `type`
/// discriminator, so the only thing that varies is which stat tiles apply. That
/// choice is made from the data ([PlaceStats.totalProducts] is non-null only for
/// a pharmacy, [PlaceStats.linkedDoctors] only for a hospital or clinic) rather
/// than from the role, so a tile can never claim "0 products" at a hospital.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/directory_models.dart';
import '../../../models/provider_models.dart';
import 'provider_controllers.dart';
import 'widgets/stat_grid.dart';
import 'widgets/verification_banner.dart';
import 'widgets/workspace_actions.dart';

class PlaceDashboardScreen extends ConsumerWidget {
  const PlaceDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(placeDashboardProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(async.valueOrNull?.kind.label ?? 'My workspace'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none_rounded),
            onPressed: () => context.push(Routes.notifications),
          ),
          IconButton(
            tooltip: 'Edit profile',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push(Routes.placeProfile),
          ),
          const WorkspaceActions(),
        ],
      ),
      body: async.when(
        loading: () => const LoadingView(message: 'Loading your dashboard…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(placeDashboardProvider),
        ),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(placeDashboardProvider),
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.gap),
            children: [
              _Header(dash: d),
              VerificationBanner(
                status: d.verification,
                accountStatus: d.accountStatus,
                onEditProfile: () => context.push(Routes.placeProfile),
              ),
              Padding(
                padding: const EdgeInsets.only(top: AppTheme.gap),
                child: StatGrid(tiles: _tiles(context, ref, d)),
              ),
              DashboardSection(
                title: 'Manage',
                child: Column(
                  children: [
                    _Action(
                      icon: Icons.storefront_outlined,
                      title: 'Profile and details',
                      subtitle: _profileSubtitle(d.kind),
                      onTap: () => context.push(Routes.placeProfile),
                    ),
                    _Action(
                      icon: Icons.reviews_outlined,
                      title: 'Reviews about us',
                      subtitle: d.stats.pendingReviews > 0
                          ? '${d.stats.pendingReviews} awaiting moderation'
                          : 'See what patients have written',
                      highlight: d.stats.pendingReviews > 0,
                      onTap: () {
                        ref.read(providerReviewStatusProvider.notifier).state =
                            null;
                        context.push(Routes.placeReviews);
                      },
                    ),
                  ],
                ),
              ),
              // What a patient sees when they open the listing. Shown last
              // because it is a mirror, not a control — and it is the quickest
              // way for an owner to notice a field they never filled in.
              DashboardSection(
                title: 'How patients see you',
                child: _PublicPreview(place: d.profile, kind: d.kind),
              ),
              const SizedBox(height: AppTheme.gap),
            ],
          ),
        ),
      ),
    );
  }

  String _profileSubtitle(PlaceKind kind) => switch (kind) {
        PlaceKind.hospital => 'Beds, departments, emergency contact',
        PlaceKind.clinic => 'Services, specialisations, hours',
        PlaceKind.pharmacy => 'Delivery, licences, opening hours',
      };

  /// Built from what the stats actually contain, not from [PlaceDashboard.kind]
  /// — see the class comment.
  List<StatTile> _tiles(BuildContext context, WidgetRef ref, PlaceDashboard d) {
    final s = d.stats;
    return [
      if (s.linkedDoctors != null)
        stat(
          'Doctors listing us',
          s.linkedDoctors!,
          icon: Icons.medical_services_outlined,
        ),
      if (s.totalProducts != null)
        stat(
          'Products',
          s.totalProducts!,
          icon: Icons.inventory_2_outlined,
        ),
      if (s.totalOrders != null)
        stat('Orders', s.totalOrders!, icon: Icons.receipt_long_outlined),
      if (s.totalRevenue != null)
        stat(
          'Revenue',
          Fmt.money(s.totalRevenue),
          icon: Icons.payments_outlined,
          color: AppColors.success,
        ),
      stat(
        'Rating',
        s.totalReviews == 0 ? '—' : s.ratingLabel,
        icon: Icons.star_outline_rounded,
        onTap: () {
          ref.read(providerReviewStatusProvider.notifier).state = null;
          context.push(Routes.placeReviews);
        },
      ),
      stat(
        'Reviews',
        s.totalReviews,
        icon: Icons.reviews_outlined,
        onTap: () {
          ref.read(providerReviewStatusProvider.notifier).state = null;
          context.push(Routes.placeReviews);
        },
      ),
      // Pending reviews are not yet public, so this is the one number here the
      // owner may want to act on — it is what patients are about to read.
      stat(
        'Awaiting moderation',
        s.pendingReviews,
        icon: Icons.hourglass_top_outlined,
        color: s.pendingReviews > 0 ? AppColors.warning : null,
        onTap: () {
          ref.read(providerReviewStatusProvider.notifier).state = 'pending';
          context.push(Routes.placeReviews);
        },
      ),
    ];
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.dash});

  final PlaceDashboard dash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = dash.profile;
    final place = [p?.area, p?.city].whereType<String>().where((s) => s.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p?.name ?? dash.ownerName ?? dash.kind.label,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (place.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(place.join(', '), style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(
            status: dash.verification.name,
            label: dash.kind.label,
            dense: true,
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? AppSemantic.of(context).warning : theme.colorScheme.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: theme.textTheme.bodyLarge),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Mirrors the public listing. Missing fields are shown as an explicit gap
/// rather than being hidden, because the point of this block is to make an
/// unfilled field visible to the owner.
class _PublicPreview extends StatelessWidget {
  const _PublicPreview({required this.place, required this.kind});

  final Place? place;
  final PlaceKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = place;
    if (p == null) {
      return const EmptyView(
        icon: Icons.storefront_outlined,
        title: 'Profile not set up',
        message: 'Fill in your details so patients can find you.',
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(label: 'Address', value: p.address),
            _Row(label: 'Phone', value: p.phone),
            _Row(label: 'Email', value: p.email),
            _Row(label: 'Website', value: p.website),
            // `hours` is composed server-side from the opening/closing pair, so
            // this reads back what the form's two time fields produced.
            _Row(label: 'Hours', value: p.openingHours),
            if (kind == PlaceKind.hospital) ...[
              _Row(label: 'Emergency', value: p.emergencyPhone),
              _Row(label: 'Beds', value: p.bedsTotal?.toString()),
              _Row(label: 'ICU beds', value: p.icuBeds?.toString()),
            ],
            if (kind == PlaceKind.pharmacy)
              _Row(
                label: 'Delivery',
                value: p.deliveryAvailable ? 'Available' : 'Not offered',
              ),
            _Row(
              label: switch (kind) {
                PlaceKind.hospital => 'Facilities',
                PlaceKind.clinic => 'Services',
                PlaceKind.pharmacy => 'Services',
              },
              value: p.services.isEmpty ? null : p.services.join(', '),
            ),
            if (p.about != null && p.about!.isNotEmpty) ...[
              const Divider(height: 20),
              Text(p.about!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final missing = value == null || value!.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: Text(
              missing ? 'Not added' : value!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: missing ? AppSemantic.of(context).warning : null,
                fontStyle: missing ? FontStyle.italic : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
