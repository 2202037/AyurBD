/// `/pharmacy/products` — the medicine catalogue.
///
/// Same shape as the doctor directory: one [PagedController] re-keyed by a query
/// object, debounced search, chips fed by a separate unpaginated endpoint. The
/// extras here are a sort menu and an in-stock toggle, both of which map onto
/// query params the server actually reads (`sort` is whitelisted server-side and
/// silently falls back, `in_stock` is compared to the literal string '1').
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/pharmacy_models.dart';
import '../data/pharmacy_repository.dart';
import 'cart_controller.dart';

@immutable
class ProductQuery {
  const ProductQuery({
    this.search = '',
    this.category,
    this.sort = ProductSort.relevance,
    this.inStockOnly = false,
  });

  final String search;
  final String? category;
  final ProductSort sort;
  final bool inStockOnly;

  ProductQuery copyWith({
    String? search,
    String? category,
    ProductSort? sort,
    bool? inStockOnly,
    bool clearCategory = false,
  }) =>
      ProductQuery(
        search: search ?? this.search,
        category: clearCategory ? null : (category ?? this.category),
        sort: sort ?? this.sort,
        inStockOnly: inStockOnly ?? this.inStockOnly,
      );

  /// An empty string would build `LIKE '%%'` across three columns — matches
  /// everything and still pays for the scan.
  String? get searchOrNull => search.trim().isEmpty ? null : search.trim();

  bool get isFiltered =>
      searchOrNull != null || category != null || inStockOnly || sort != ProductSort.relevance;
}

final productQueryProvider = StateProvider<ProductQuery>((ref) => const ProductQuery());

final productCategoriesProvider = FutureProvider<List<ProductCategory>>((ref) {
  return ref.watch(pharmacyRepositoryProvider).categories();
});

final productListProvider =
    StateNotifierProvider<PagedController<Product>, PagedState<Product>>((ref) {
  final repo = ref.watch(pharmacyRepositoryProvider);
  final q = ref.watch(productQueryProvider);

  return PagedController<Product>((page) => repo.products(
        page: page,
        search: q.searchOrNull,
        category: q.category,
        sort: q.sort,
        inStockOnly: q.inStockOnly,
      ));
});

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  late final TextEditingController _search =
      TextEditingController(text: ref.read(productQueryProvider).search);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final current = ref.read(productQueryProvider);
      if (current.search == value) return;
      ref.read(productQueryProvider.notifier).state = current.copyWith(search: value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(productListProvider);
    final controller = ref.read(productListProvider.notifier);
    final query = ref.watch(productQueryProvider);
    final notifier = ref.read(productQueryProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pharmacy'),
        actions: [
          PopupMenuButton<ProductSort>(
            tooltip: 'Sort',
            icon: const Icon(Icons.swap_vert),
            initialValue: query.sort,
            onSelected: (s) => notifier.state = query.copyWith(sort: s),
            itemBuilder: (context) => [
              for (final s in ProductSort.values)
                PopupMenuItem<ProductSort>(value: s, child: Text(s.label)),
            ],
          ),
          const CartButton(),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: (v) {
                _debounce?.cancel();
                notifier.state = query.copyWith(search: v);
              },
              decoration: InputDecoration(
                hintText: 'Medicine, brand or generic name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _debounce?.cancel();
                          _search.clear();
                          notifier.state = query.copyWith(search: '');
                        },
                      ),
              ),
            ),
          ),
          _CategoryChips(
            selected: query.category,
            inStockOnly: query.inStockOnly,
            onSelectCategory: (name) => notifier.state = name == null
                ? query.copyWith(clearCategory: true)
                : query.copyWith(category: name),
            onToggleStock: (on) => notifier.state = query.copyWith(inStockOnly: on),
          ),
          Expanded(
            child: PagedListView<Product>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: 'No medicines found',
              emptyMessage: query.isFiltered
                  ? 'Try a different search, or clear the category and stock filters.'
                  : 'The catalogue is empty. Pharmacies add products from their own dashboard.',
              emptyIcon: Icons.medication_outlined,
              itemBuilder: (context, product, _) => ProductCard(product: product),
            ),
          ),
        ],
      ),
    );
  }
}

/// Category chips plus the in-stock toggle, on one scrolling strip so the list
/// keeps as much vertical space as possible on a phone.
///
/// A category-fetch failure is silent by design: the chips are a convenience,
/// and an error banner above a catalogue that loaded fine would be noise.
class _CategoryChips extends ConsumerWidget {
  const _CategoryChips({
    required this.selected,
    required this.inStockOnly,
    required this.onSelectCategory,
    required this.onToggleStock,
  });

  final String? selected;
  final bool inStockOnly;
  final void Function(String?) onSelectCategory;
  final void Function(bool) onToggleStock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(productCategoriesProvider).maybeWhen(
          data: (items) => items,
          orElse: () => const <ProductCategory>[],
        );

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('In stock'),
              selected: inStockOnly,
              onSelected: onToggleStock,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('All'),
              selected: selected == null,
              onSelected: (_) => onSelectCategory(null),
            ),
          ),
          for (final c in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(c.productCount > 0 ? '${c.name} (${c.productCount})' : c.name),
                selected: selected == c.name,
                onSelected: (on) => onSelectCategory(on ? c.name : null),
              ),
            ),
        ],
      ),
    );
  }
}

/// One catalogue row. Shared with the pharmacy detail screen, which lists that
/// pharmacy's products in the same shape.
class ProductCard extends ConsumerWidget {
  const ProductCard({super.key, required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final p = product;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.productDetail(p.id)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RemoteImage(
                path: p.image,
                width: 72,
                height: 72,
                radius: AppTheme.radius - 2,
                fallbackIcon: Icons.medication_outlined,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (p.subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        p.subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        StatusPill(
                          status: p.stockStatus,
                          label: p.stockLabel,
                          dense: true,
                        ),
                        // `rating` is null when the endpoint did not aggregate
                        // it, which is not the same as a product rated zero —
                        // so the stars are hidden rather than showing "0.0".
                        if (p.hasRating)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star_rounded,
                                  size: 15, color: theme.colorScheme.tertiary),
                              const SizedBox(width: 2),
                              Text(Fmt.rating(p.rating),
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        if (p.requiresPrescription)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.description_outlined, size: 14, color: muted),
                              const SizedBox(width: 3),
                              Text('Rx', style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          p.priceLabel,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: theme.colorScheme.primary),
                        ),
                        const Spacer(),
                        AddToCartButton(product: p, compact: true),
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

/// The add button, shared by the card and the detail screen.
///
/// A 422 here is the server saying "only N in stock" — that is information the
/// user needs, so it is surfaced as the server worded it rather than swallowed.
class AddToCartButton extends ConsumerStatefulWidget {
  const AddToCartButton({
    super.key,
    required this.product,
    this.quantity = 1,
    this.compact = false,
  });

  final Product product;
  final int quantity;
  final bool compact;

  @override
  ConsumerState<AddToCartButton> createState() => _AddToCartButtonState();
}

class _AddToCartButtonState extends ConsumerState<AddToCartButton> {
  bool _busy = false;

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(cartControllerProvider.notifier)
          .add(widget.product.id, quantity: widget.quantity);
      if (!mounted) return;
      showToast(context, 'Added to cart.');
    } on ApiException catch (e) {
      if (!mounted) return;
      // A 401 is handled globally as a sign-out (§10) — no dialog here.
      showToast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // `isAvailable` folds in both stock and the is_active flag; the server would
    // refuse either way, but a dead-looking button explains why.
    final enabled = widget.product.isAvailable && !_busy;
    final child = _busy
        ? const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : Text(widget.product.isAvailable ? 'Add' : 'Unavailable');

    if (widget.compact) {
      return FilledButton.tonal(
        onPressed: enabled ? _add : null,
        style: FilledButton.styleFrom(
          // Bounded width: the compact variant is used inside a Row (the
          // product card price strip), which offers unbounded width.
          minimumSize: const Size(64, 40),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
        child: child,
      );
    }
    return FilledButton.icon(
      onPressed: enabled ? _add : null,
      icon: const Icon(Icons.add_shopping_cart_outlined, size: 18),
      label: child,
    );
  }
}

/// Cart icon with the live badge, for any app bar that wants it.
class CartButton extends ConsumerWidget {
  const CartButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(cartCountProvider);

    return IconButton(
      tooltip: 'Cart',
      onPressed: () => context.push(Routes.cart),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}
