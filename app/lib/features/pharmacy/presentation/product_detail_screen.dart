/// `/pharmacy/products/{id}` — one medicine.
///
/// The detail endpoint is the only product query that aggregates `avg_rating`,
/// so this is the one screen where `Product.rating` is reliably non-null. It
/// still guards with `hasRating`, because a product nobody has reviewed comes
/// back with `avg_rating` NULL and `product_public()` then omits the key.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/pharmacy_models.dart';
import '../data/pharmacy_repository.dart';
import 'products_screen.dart';

final productDetailProvider = FutureProvider.family<Product, int>((ref, id) {
  return ref.watch(pharmacyRepositoryProvider).product(id);
});

class ProductDetailScreen extends ConsumerStatefulWidget {
  const ProductDetailScreen({super.key, required this.productId});

  final int productId;

  @override
  ConsumerState<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends ConsumerState<ProductDetailScreen> {
  int _quantity = 1;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(productDetailProvider(widget.productId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product'),
        actions: const [CartButton()],
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(productDetailProvider(widget.productId)),
        ),
        data: (p) => _Body(
          product: p,
          quantity: _quantity,
          // The stepper is clamped to the server's own ceiling: stock, or 99,
          // whichever is lower. Going past it turns the cart line into an
          // `insufficient_stock` issue that blocks the whole checkout.
          onQuantity: (q) => setState(() => _quantity = q.clamp(1, p.maxQuantity.clamp(1, 99))),
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.product,
    required this.quantity,
    required this.onQuantity,
  });

  final Product product;
  final int quantity;
  final void Function(int) onQuantity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final p = product;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, AppTheme.gap, AppTheme.gap, 24),
            children: [
              Center(
                child: RemoteImage(
                  path: p.image,
                  width: 200,
                  height: 200,
                  radius: AppTheme.radius,
                  fit: BoxFit.contain,
                  fallbackIcon: Icons.medication_outlined,
                ),
              ),
              const SizedBox(height: AppTheme.gap),
              Text(p.name, style: theme.textTheme.headlineSmall),
              if (p.subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(p.subtitle, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    p.priceLabel,
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(color: theme.colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  StatusPill(status: p.stockStatus, label: p.stockLabel),
                  if (p.hasRating) ...[
                    const SizedBox(width: 12),
                    Icon(Icons.star_rounded, size: 18, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 2),
                    Text(Fmt.rating(p.rating), style: theme.textTheme.titleSmall),
                  ],
                ],
              ),
              if (p.requiresPrescription) ...[
                const SizedBox(height: AppTheme.gap),
                _Banner(
                  icon: Icons.description_outlined,
                  color: theme.colorScheme.tertiary,
                  // The API does not collect a prescription upload in this
                  // build, so this is advisory — say that rather than implying
                  // the app will verify anything.
                  message: 'Prescription medicine. The pharmacy will ask to see a '
                      'valid prescription before handing this over.',
                ),
              ],
              if (p.description != null) ...[
                const SizedBox(height: AppTheme.gap),
                Text('About this product', style: theme.textTheme.titleSmall),
                const SizedBox(height: 6),
                Text(p.description!, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: AppTheme.gap),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      if (p.pharmacyName != null)
                        _Row(
                          icon: Icons.storefront_outlined,
                          label: 'Sold by',
                          value: p.pharmacyName!,
                        ),
                      if (p.category != null)
                        _Row(
                          icon: Icons.category_outlined,
                          label: 'Category',
                          value: p.category!,
                        ),
                      if (p.unit != null)
                        _Row(icon: Icons.inventory_2_outlined, label: 'Pack', value: p.unit!),
                      _Row(
                        icon: Icons.warehouse_outlined,
                        label: 'Stock',
                        value: p.inStock ? '${p.stock} available' : 'None left',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _BuyBar(product: p, quantity: quantity, onQuantity: onQuantity),
      ],
    );
  }
}

/// Quantity stepper plus the add button, pinned above the system inset so it is
/// reachable one-handed on a tall phone.
class _BuyBar extends StatelessWidget {
  const _BuyBar({
    required this.product,
    required this.quantity,
    required this.onQuantity,
  });

  final Product product;
  final int quantity;
  final void Function(int) onQuantity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = product.maxQuantity;
    final enabled = product.isAvailable;

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(AppTheme.gap, 10, AppTheme.gap, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          children: [
            QuantityStepper(
              value: quantity,
              min: 1,
              max: max < 1 ? 1 : max,
              enabled: enabled,
              onChanged: onQuantity,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: AddToCartButton(product: product, quantity: quantity),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared with the cart screen, which steps quantities the same way.
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.enabled = true,
  });

  final int value;
  final int min;
  final int max;
  final bool enabled;
  final void Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: enabled && value > min ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 28,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: enabled && value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.message, required this.color});

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: muted),
          const SizedBox(width: 10),
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
