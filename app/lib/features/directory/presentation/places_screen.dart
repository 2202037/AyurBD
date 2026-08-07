/// `/directory/clinics`, `/hospitals`, `/pharmacies` — one screen, three kinds.
///
/// `place_list()` shapes all three identically, so triplicating this file would
/// triplicate every future fix. [PlaceKind] is the only thing that varies, and it
/// is a route parameter rather than three separate widgets.
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
import '../../../models/directory_models.dart';
import '../data/directory_repository.dart';

/// Search term, keyed by kind. Three directories keep three independent search
/// boxes — coming back to clinics should not inherit whatever you typed while
/// browsing pharmacies.
final placeSearchProvider =
    StateProvider.family<String, PlaceKind>((ref, kind) => '');

final placeListProvider = StateNotifierProvider.family<PagedController<Place>,
    PagedState<Place>, PlaceKind>((ref, kind) {
  final repo = ref.watch(directoryRepositoryProvider);
  final search = ref.watch(placeSearchProvider(kind)).trim();
  return PagedController<Place>((page) => repo.places(
        kind,
        page: page,
        search: search.isEmpty ? null : search,
      ));
});

class PlacesScreen extends ConsumerStatefulWidget {
  const PlacesScreen({super.key, required this.kind});

  final PlaceKind kind;

  @override
  ConsumerState<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends ConsumerState<PlacesScreen> {
  late final TextEditingController _search =
      TextEditingController(text: ref.read(placeSearchProvider(widget.kind)));
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      ref.read(placeSearchProvider(widget.kind).notifier).state = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final state = ref.watch(placeListProvider(kind));
    final controller = ref.read(placeListProvider(kind).notifier);
    final search = ref.watch(placeSearchProvider(kind));

    return Scaffold(
      appBar: AppBar(title: Text(kind.plural)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 8),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: (v) {
                _debounce?.cancel();
                ref.read(placeSearchProvider(kind).notifier).state = v;
              },
              decoration: InputDecoration(
                hintText: 'Search ${kind.plural.toLowerCase()} by name or area',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _debounce?.cancel();
                          _search.clear();
                          ref.read(placeSearchProvider(kind).notifier).state = '';
                        },
                      ),
              ),
            ),
          ),
          Expanded(
            child: PagedListView<Place>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              padding: const EdgeInsets.fromLTRB(AppTheme.gap, 4, AppTheme.gap, 32),
              emptyTitle: 'No ${kind.plural.toLowerCase()} found',
              emptyMessage: search.isEmpty
                  ? 'Nothing listed in this directory yet.'
                  : 'No match for "$search". Try a shorter search.',
              emptyIcon: placeKindIcon(kind),
              itemBuilder: (context, place, _) => PlaceCard(place: place),
            ),
          ),
        ],
      ),
    );
  }
}

/// Public because the detail screen shows the same icon: with no photo column on
/// any of the three tables, the typed icon *is* the visual identity of a place,
/// and two copies of this switch would be two places to drift.
///
/// It lives here rather than on [PlaceKind] because `models/` deliberately does
/// not import Flutter — an `IconData` getter would drag the widget layer into
/// the model layer.
IconData placeKindIcon(PlaceKind kind) {
  switch (kind) {
    case PlaceKind.clinic:
      return Icons.local_hospital_outlined;
    case PlaceKind.hospital:
      return Icons.apartment_outlined;
    case PlaceKind.pharmacy:
      return Icons.local_pharmacy_outlined;
  }
}

/// One directory row. Also used by the home screen's nearby lists.
class PlaceCard extends StatelessWidget {
  const PlaceCard({super.key, required this.place});

  final Place place;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.placeDetail(place.kind, place.id)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // No photo: clinics, hospitals and pharmacies have no image
              // column in this database, so the tile is a typed icon rather
              // than a broken RemoteImage that could only ever show a fallback.
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppTheme.radius - 2),
                ),
                child: Icon(
                  placeKindIcon(place.kind),
                  size: 30,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            place.name,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (place.isVerified)
                          Icon(
                            Icons.verified,
                            size: 17,
                            color: theme.colorScheme.primary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      place.locationLabel,
                      style: theme.textTheme.bodySmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.star_rounded,
                              size: 15,
                              color: theme.colorScheme.tertiary,
                            ),
                            const SizedBox(width: 3),
                            Text(Fmt.rating(place.rating), style: theme.textTheme.bodySmall),
                          ],
                        ),
                        if (place.doctorCount > 0)
                          Text(
                            '${place.doctorCount} doctor${place.doctorCount == 1 ? '' : 's'}',
                            style: theme.textTheme.bodySmall,
                          ),
                        if (place.productCount > 0)
                          Text(
                            '${place.productCount} product${place.productCount == 1 ? '' : 's'}',
                            style: theme.textTheme.bodySmall,
                          ),
                        // No distance chip: nothing in this database has
                        // coordinates, so there is no distance to show. No
                        // blood-bank chip either — blood stock lives in its own
                        // table and is not linked to a hospital row.
                        if (place.is24h)
                          const StatusPill(
                            status: 'available',
                            label: 'Open 24h',
                            dense: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
