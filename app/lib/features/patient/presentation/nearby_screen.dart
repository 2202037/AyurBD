/// §5.8 — nearby healthcare services.
///
/// "Nearby" is a city/area text search, not a radius search: no table in this
/// schema stores latitude or longitude. The screen says so once, in a banner,
/// because a user who expects "2.3 km away" and gets an alphabetical list will
/// otherwise assume the location detection is broken.
///
/// All four provider kinds come back in one list, so the type filter is what
/// makes it usable.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/directory_models.dart';
import '../../../models/patient_models.dart';
import '../../admin/presentation/widgets/admin_filter_bar.dart';
import '../data/patient_repository.dart';

/// `all` rather than null: the endpoint takes a literal `all`, and anything
/// outside the five accepted values is a 400.
final nearbyTypeProvider = StateProvider<String>((ref) => 'all');
final nearbyCityProvider = StateProvider<String?>((ref) => null);
final nearbySearchProvider = StateProvider<String?>((ref) => null);

const _typeFilters = <FilterOption>[
  (value: 'all', label: 'All'),
  (value: 'doctor', label: 'Doctors'),
  (value: 'hospital', label: 'Hospitals'),
  (value: 'clinic', label: 'Clinics'),
  (value: 'pharmacy', label: 'Pharmacies'),
];

final nearbyProvider =
    StateNotifierProvider<PagedController<NearbyResult>, PagedState<NearbyResult>>(
        (ref) {
  final type = ref.watch(nearbyTypeProvider);
  final city = ref.watch(nearbyCityProvider);
  final search = ref.watch(nearbySearchProvider);
  final repo = ref.watch(patientRepositoryProvider);
  return PagedController<NearbyResult>(
    (page) => repo.nearby(page: page, type: type, city: city, search: search),
  );
});

class NearbyScreen extends ConsumerWidget {
  const NearbyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(nearbyProvider);
    final controller = ref.read(nearbyProvider.notifier);
    final type = ref.watch(nearbyTypeProvider);

    final bar = AdminFilterBar(
      searchHint: 'Search by name',
      onSearch: (v) => ref.read(nearbySearchProvider.notifier).state = v,
      options: _typeFilters,
      selected: type,
      // Every option here carries a value, so the fallback is unreachable — it
      // exists only because the chip strip is typed nullable.
      onSelected: (v) => ref.read(nearbyTypeProvider.notifier).state = v ?? 'all',
      trailing: _CityField(
        onChanged: (v) => ref.read(nearbyCityProvider.notifier).state = v,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby services'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: Column(
        children: [
          const _TextSearchNotice(),
          Expanded(
            child: PagedListView<NearbyResult>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: 'Nothing found',
              emptyIcon: Icons.location_off_outlined,
              emptyMessage: 'Try a different city or clear the filters.',
              itemBuilder: (context, r, _) => _NearbyCard(result: r),
            ),
          ),
        ],
      ),
    );
  }
}

/// Says once why there are no distances, so the absence does not read as a bug.
class _TextSearchNotice extends StatelessWidget {
  const _TextSearchNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Results are matched by city and area, not by GPS distance.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Its own widget so the debounce timer and controller are disposed together —
/// the same reason [DebouncedSearchField] is stateful.
class _CityField extends StatelessWidget {
  const _CityField({required this.onChanged});

  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DebouncedSearchField(
      hintText: 'City (e.g. Dhaka)',
      onChanged: onChanged,
    );
  }
}

class _NearbyCard extends StatelessWidget {
  const _NearbyCard({required this.result});

  final NearbyResult result;

  /// Maps the wire `kind` onto the detail route. A doctor has its own screen;
  /// the other three share the place detail screen keyed by [PlaceKind].
  void _open(BuildContext context) {
    final r = result;
    switch (r.kind) {
      case 'doctor':
        context.push(Routes.doctorDetail(r.id));
      case 'hospital':
        context.push(Routes.placeDetail(PlaceKind.hospital, r.id));
      case 'clinic':
        context.push(Routes.placeDetail(PlaceKind.clinic, r.id));
      case 'pharmacy':
        context.push(Routes.placeDetail(PlaceKind.pharmacy, r.id));
      default:
        showToast(context, 'No detail page for ${r.kindLabel}.', error: true);
    }
  }

  IconData get _icon => switch (result.kind) {
        'doctor' => Icons.medical_services_outlined,
        'hospital' => Icons.local_hospital_outlined,
        'clinic' => Icons.medical_information_outlined,
        'pharmacy' => Icons.local_pharmacy_outlined,
        _ => Icons.place_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = result;
    final muted = theme.colorScheme.onSurfaceVariant;
    final where = r.locationLabel;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              r.image != null
                  ? RemoteImage(path: r.image, width: 48, height: 48, radius: 8)
                  : Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Icon(_icon, color: theme.colorScheme.primary),
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [r.kindLabel, r.subtitle]
                          .whereType<String>()
                          .where((s) => s.isNotEmpty)
                          .join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (where.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.place_outlined, size: 13, color: muted),
                          const SizedBox(width: 3),
                          Expanded(
                            child: Text(
                              where,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: muted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Icon(Icons.star_rounded, size: 15, color: theme.colorScheme.tertiary),
                      const SizedBox(width: 2),
                      Text(
                        Fmt.rating(r.rating),
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                  Text(
                    '${r.reviewCount}',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
