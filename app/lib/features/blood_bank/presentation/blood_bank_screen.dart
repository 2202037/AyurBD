/// `/blood_bank` — hospital stock plus the public donor request board.
///
/// Two tabs on one screen because they answer the same question from opposite
/// ends: who *has* blood, and who *needs* it. Both are filtered by the same
/// group chips, which is why that filter sits above the tab bar rather than
/// inside either tab.
///
/// There is no map and no distance here, for two separate reasons. Keyed map
/// integrations are out of scope for this build (`geolocator` is deliberately
/// not a dependency), and more fundamentally the live `blood_banks` table stores
/// city and address but no latitude/longitude — so `/blood_bank/nearby` is a
/// city filter, not a radius search, and there is no `distance_km` to sort on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/blood_models.dart';
import '../data/blood_repository.dart';

/// Cities offered by the "near me" filter — plain names, because there is
/// nothing to measure a distance against and the server does a city match.
const List<String> kBloodCities = [
  'Dhaka',
  'Chattogram',
  'Khulna',
  'Rajshahi',
  'Sylhet',
  'Barishal',
  'Rangpur',
  'Mymensingh',
];

/// What the stock tab is currently asking for. `city == null` means "everywhere",
/// which goes to `/blood_bank/inventory`; a city switches to `/blood_bank/nearby`.
@immutable
class StockQuery {
  const StockQuery({
    this.bloodGroup,
    this.city,
    this.inStockOnly = true,
  });

  final String? bloodGroup;
  final String? city;
  final bool inStockOnly;

  StockQuery copyWith({
    String? bloodGroup,
    String? city,
    bool? inStockOnly,
    bool clearGroup = false,
    bool clearCity = false,
  }) =>
      StockQuery(
        bloodGroup: clearGroup ? null : (bloodGroup ?? this.bloodGroup),
        city: clearCity ? null : (city ?? this.city),
        inStockOnly: inStockOnly ?? this.inStockOnly,
      );
}

/// The request board's own filters.
///
/// There is no urgency chip any more: `blood_requests` has no urgency column, so
/// the old filter sent a key the server dropped and appeared to work while doing
/// nothing. Requests are ordered soonest-needed first instead, and `status` is
/// whitelisted server-side (400 on anything unrecognised).
@immutable
class RequestQuery {
  const RequestQuery({this.bloodGroup, this.city, this.mine = false});

  final String? bloodGroup;
  final String? city;

  /// `mine=1` requires auth and returns every status; the public board is
  /// forced to `status = 'active'` by the server.
  final bool mine;

  RequestQuery copyWith({
    String? bloodGroup,
    String? city,
    bool? mine,
    bool clearGroup = false,
    bool clearCity = false,
  }) =>
      RequestQuery(
        bloodGroup: clearGroup ? null : (bloodGroup ?? this.bloodGroup),
        city: clearCity ? null : (city ?? this.city),
        mine: mine ?? this.mine,
      );
}

final stockQueryProvider = StateProvider<StockQuery>((ref) => const StockQuery());
final requestQueryProvider = StateProvider<RequestQuery>((ref) => const RequestQuery());

/// Watching the query provider means a filter change disposes and rebuilds the
/// controller, which resets pagination for free.
final bloodStockProvider =
    StateNotifierProvider<PagedController<BloodStock>, PagedState<BloodStock>>((ref) {
  final repo = ref.watch(bloodRepositoryProvider);
  final q = ref.watch(stockQueryProvider);

  if (q.city != null) {
    return PagedController<BloodStock>((page) async {
      final res = await repo.nearby(
        city: q.city!,
        bloodGroup: q.bloodGroup,
        page: page,
      );
      return res.page;
    });
  }

  return PagedController<BloodStock>((page) => repo.inventory(
        page: page,
        bloodGroup: q.bloodGroup,
        inStockOnly: q.inStockOnly,
      ));
});

final bloodRequestsProvider =
    StateNotifierProvider<PagedController<BloodRequest>, PagedState<BloodRequest>>((ref) {
  final repo = ref.watch(bloodRepositoryProvider);
  final q = ref.watch(requestQueryProvider);

  return PagedController<BloodRequest>((page) => repo.requests(
        page: page,
        bloodGroup: q.bloodGroup,
        city: q.city,
        mine: q.mine,
      ));
});

class BloodBankScreen extends ConsumerStatefulWidget {
  const BloodBankScreen({super.key});

  @override
  ConsumerState<BloodBankScreen> createState() => _BloodBankScreenState();
}

class _BloodBankScreenState extends ConsumerState<BloodBankScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// The group filter is shared by both tabs, so setting it has to touch both
  /// queries — otherwise switching tabs would silently change what you filtered.
  void _setGroup(String? group) {
    ref.read(stockQueryProvider.notifier).update(
          (q) => group == null ? q.copyWith(clearGroup: true) : q.copyWith(bloodGroup: group),
        );
    ref.read(requestQueryProvider.notifier).update(
          (q) => group == null ? q.copyWith(clearGroup: true) : q.copyWith(bloodGroup: group),
        );
  }

  @override
  Widget build(BuildContext context) {
    final group = ref.watch(stockQueryProvider).bloodGroup;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blood bank'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(100),
          child: Column(
            children: [
              _GroupChips(selected: group, onSelect: _setGroup),
              TabBar(
                controller: _tabs,
                tabs: const [
                  Tab(text: 'Available stock'),
                  Tab(text: 'Requests'),
                ],
              ),
            ],
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_StockTab(), _RequestsTab()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(Routes.bloodRequest),
        icon: const Icon(Icons.add),
        label: const Text('Request blood'),
      ),
    );
  }
}

/// The eight groups from [kBloodGroups], with "All" pinned first. The server
/// answers 400 on any value outside that list, so the chips are the only way to
/// set this filter — there is no free-text box.
class _GroupChips extends StatelessWidget {
  const _GroupChips({required this.selected, required this.onSelect});

  final String? selected;
  final void Function(String?) onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
            child: ChoiceChip(
              label: const Text('All groups'),
              selected: selected == null,
              onSelected: (_) => onSelect(null),
            ),
          ),
          for (final g in kBloodGroups)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 6, bottom: 6),
              child: ChoiceChip(
                label: Text(g),
                selected: selected == g,
                // Tapping the active chip clears it, so the filter is always
                // reversible without hunting for "All".
                onSelected: (on) => onSelect(on ? g : null),
              ),
            ),
        ],
      ),
    );
  }
}

class _StockTab extends ConsumerWidget {
  const _StockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(stockQueryProvider);
    final state = ref.watch(bloodStockProvider);
    final controller = ref.read(bloodStockProvider.notifier);
    final nearby = q.city != null;

    return Column(
      children: [
        _StockControls(query: q),
        Expanded(
          child: PagedListView<BloodStock>(
            state: state,
            onRefresh: controller.refresh,
            onLoadMore: controller.loadMore,
            onRetry: controller.reload,
            emptyTitle: 'No stock found',
            emptyMessage: nearby
                ? 'No blood bank in ${q.city!} has this on record. '
                    'Try another city, or search everywhere.'
                : 'Nothing matches this filter yet. Blood banks update their '
                    'stock from their own dashboard.',
            emptyIcon: Icons.water_drop_outlined,
            itemBuilder: (context, stock, _) => _StockCard(stock: stock),
          ),
        ),
      ],
    );
  }
}

/// City + in-stock toggle. There is no radius control: the data has no
/// coordinates, so "within N km" was never something the server could answer.
class _StockControls extends ConsumerWidget {
  const _StockControls({required this.query});

  final StockQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifier = ref.read(stockQueryProvider.notifier);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<String?>(
            initialValue: query.city,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'City',
              prefixIcon: Icon(Icons.location_city_outlined),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Anywhere in Bangladesh'),
              ),
              for (final c in kBloodCities)
                DropdownMenuItem<String?>(value: c, child: Text(c)),
            ],
            onChanged: (city) => notifier.update(
              (q) => city == null ? q.copyWith(clearCity: true) : q.copyWith(city: city),
            ),
          ),
          Row(
            children: [
              Checkbox(
                value: query.inStockOnly,
                onChanged: (v) =>
                    notifier.update((q) => q.copyWith(inStockOnly: v ?? false)),
              ),
              Expanded(
                child: Text('Hide banks with no units left',
                    style: theme.textTheme.bodyMedium),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StockCard extends StatelessWidget {
  const _StockCard({required this.stock});

  final BloodStock stock;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final s = stock;

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
                _GroupBadge(group: s.bloodGroup),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.hospitalName ?? 'Blood bank',
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (s.location != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          s.location!,
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // `availabilityStatus` never says "available" on a zero-unit row,
                // even if the hospital's own flag still claims it does.
                StatusPill(status: s.availabilityStatus, dense: true),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  s.inStock ? Icons.water_drop : Icons.water_drop_outlined,
                  size: 15,
                  color: s.inStock ? theme.colorScheme.primary : muted,
                ),
                const SizedBox(width: 5),
                Text(
                  s.unitsLabel,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: s.inStock ? theme.colorScheme.primary : muted,
                  ),
                ),
                const Spacer(),
                if (s.updatedAt != null)
                  Text(
                    Fmt.relative(s.updatedAt),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
              ],
            ),
            if (s.contactPhone != null) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => dialPhone(context, s.contactPhone!),
                      icon: const Icon(Icons.call_outlined, size: 18),
                      label: Text('Call ${s.contactPhone}'),
                    ),
                  ),
                  // Search by name and place rather than by coordinate, since the
                  // table has none. This hands off to whatever maps app the
                  // device already has, so it needs no API key. Hidden when
                  // there is nothing to search for, rather than opening a blank
                  // map.
                  if (s.mapQuery.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    IconButton.outlined(
                      tooltip: 'Find on map',
                      onPressed: () => openUri(
                        context,
                        Uri.parse(
                          'https://www.google.com/maps/search/?api=1&query='
                          '${Uri.encodeComponent(s.mapQuery)}',
                        ),
                      ),
                      icon: const Icon(Icons.map_outlined, size: 18),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The blood group set in a circle — the one thing the eye should find first on
/// a board full of otherwise similar rows.
class _GroupBadge extends StatelessWidget {
  const _GroupBadge({required this.group, this.urgent = false});

  final String group;
  final bool urgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = urgent ? theme.colorScheme.error : theme.colorScheme.primary;

    return Container(
      width: 46,
      height: 46,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Text(
        group,
        style: theme.textTheme.titleSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Shared by both tabs. §8 asks for one-tap call on every contact number.
Future<void> dialPhone(BuildContext context, String phone) =>
    openUri(context, Uri(scheme: 'tel', path: phone.trim()));

Future<void> openUri(BuildContext context, Uri uri) async {
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  // An emulator with no dialer is the common case, and a silent no-op looks
  // like a broken button.
  if (!ok && context.mounted) {
    showToast(context, 'No app available to handle that.', error: true);
  }
}

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(requestQueryProvider);
    final state = ref.watch(bloodRequestsProvider);
    final controller = ref.read(bloodRequestsProvider.notifier);
    final notifier = ref.read(requestQueryProvider.notifier);

    return Column(
      children: [
        SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 8, bottom: 4),
                child: FilterChip(
                  label: const Text('My requests'),
                  avatar: const Icon(Icons.person_outline, size: 18),
                  selected: q.mine,
                  onSelected: (on) => notifier.update((s) => s.copyWith(mine: on)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 8, bottom: 4),
                child: ChoiceChip(
                  label: const Text('Any city'),
                  selected: q.city == null,
                  onSelected: (_) => notifier.update((s) => s.copyWith(clearCity: true)),
                ),
              ),
              // City, not urgency: `blood_requests` has no urgency column, and a
              // filter that sends a key the server drops looks like it works
              // while doing nothing. City is a real column and a real filter.
              for (final c in kBloodCities)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 8, bottom: 4),
                  child: ChoiceChip(
                    label: Text(c),
                    selected: q.city == c,
                    onSelected: (on) => notifier.update(
                      (s) => on ? s.copyWith(city: c) : s.copyWith(clearCity: true),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (!q.mine)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 4),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  // The public board is restricted to open requests server-side,
                  // so there is deliberately no status filter on this tab.
                  child: Text(
                    'Showing active requests only, soonest needed first.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: PagedListView<BloodRequest>(
            state: state,
            onRefresh: controller.refresh,
            onLoadMore: controller.loadMore,
            onRetry: controller.reload,
            emptyTitle: q.mine ? 'You have no requests' : 'No active requests',
            emptyMessage: q.mine
                // `blood_requests` has no requester_id, so the server matches
                // "mine" on the phone number saved on the account. Say so, or an
                // empty list looks like data loss.
                ? 'Requests posted with your account phone number appear here, '
                    'whatever their status.'
                : 'Nobody is asking for this right now — which is good news.',
            emptyIcon: Icons.volunteer_activism_outlined,
            itemBuilder: (context, req, _) => _RequestCard(request: req, mine: q.mine),
          ),
        ),
      ],
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.mine});

  final BloodRequest request;

  /// On the "my requests" tab every status shows up, so the status pill earns
  /// its place there; on the public board every row is `active` by definition.
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final r = request;
    // Urgency is derived from the deadline, not self-reported: the table has no
    // urgency column, so "needed today" is the only honest signal available.
    final days = r.daysUntilNeeded;
    final place = [r.hospitalName, r.city]
        .where((s) => s != null && s.isNotEmpty)
        .join(', ');

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
                _GroupBadge(
                  group: r.bloodGroup,
                  urgent: days != null && days <= 1 && !r.isOverdue,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.unitsLabel, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        'For ${r.patientName}',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        place.isEmpty ? 'Location not specified' : place,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    StatusPill(
                      status: r.urgencyStatus,
                      label: r.neededByLabel,
                      dense: true,
                    ),
                    if (mine) ...[
                      const SizedBox(height: 4),
                      StatusPill(status: r.status, dense: true),
                    ],
                  ],
                ),
              ],
            ),
            if (r.note != null) ...[
              const SizedBox(height: 10),
              Text(
                r.note!,
                style: theme.textTheme.bodyMedium,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                if (r.neededBy != null)
                  _Meta(icon: Icons.event_outlined, text: 'By ${Fmt.dayMonth(r.neededBy)}'),
                if (r.requesterName != null)
                  _Meta(icon: Icons.person_outline, text: r.requesterName!),
                if (r.createdAt != null)
                  _Meta(icon: Icons.schedule_outlined, text: Fmt.relative(r.createdAt)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              // `contactPhone` is non-nullable on this model — the API requires
              // it on create — so the button never needs a fallback.
              child: FilledButton.tonalIcon(
                onPressed: () => dialPhone(context, r.contactPhone),
                icon: const Icon(Icons.call_outlined, size: 18),
                label: Text(mine ? 'Call ${r.contactPhone}' : 'Call the requester'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: muted),
        const SizedBox(width: 4),
        Text(text, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
      ],
    );
  }
}
