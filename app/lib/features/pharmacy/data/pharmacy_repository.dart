/// Catalogue, cart and orders — from Supabase.
///
/// Public surface is unchanged: `products()`, `product()`, `categories()`,
/// `cart()`, `addToCart()`, `updateQuantity()`, `removeFromCart()`,
/// `checkout()`, `orders()`, `order()`. Every cart mutation still returns the
/// whole cart, so the controller keeps replacing its state wholesale.
///
/// The one real design decision here is the cart payload.
///
/// `cart_payload()` in pharmacy.php did three things Postgrest cannot: it joined
/// the product for each line, computed `line_total`/`subtotal`/`delivery_fee`/
/// `total`, and flagged lines whose product had gone unavailable or short of
/// stock. §8 says money is server-computed, and that is still honoured: every
/// amount for an actual order is computed by the `place_order` SECURITY DEFINER
/// RPC inside one transaction, and the `orders`/`order_items` CHECK constraints
/// police the arithmetic. The totals in [Cart] are display figures for the
/// basket screen, computed in [_buildCart] from the prices and stock levels the
/// same query just read, so they cannot drift from the order that gets written
/// by more than the price of a concurrent edit.
///
/// The delivery-fee rule (free over ৳500, otherwise ৳60) is reproduced here in
/// [_deliveryFeeFor] because it lived in PHP, not in the database — and it is
/// reproduced identically inside `place_order()`, so the basket and the order
/// can never disagree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show
        CountOption,
        PostgrestFilterBuilder,
        PostgrestList,
        PostgrestTransformBuilder;

import '../../../core/constants/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_result.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/utils/formatters.dart';
import '../../../models/pharmacy_models.dart';

/// Unchanged. The values used to be an API whitelist; they are now mapped to
/// `order()` calls in [PharmacyRepository._applySort].
enum ProductSort {
  relevance(null, 'Default'),
  priceAsc('price_asc', 'Price: low to high'),
  priceDesc('price_desc', 'Price: high to low'),
  name('name', 'Name A–Z'),
  newest('newest', 'Newest first');

  const ProductSort(this.value, this.label);

  final String? value;
  final String label;
}

/// A category plus how many active products sit in it, for the filter chips.
class ProductCategory {
  const ProductCategory(this.name, this.productCount);

  final String name;
  final int productCount;
}

class PharmacyRepository {
  PharmacyRepository(this._sb);

  final SupabaseService _sb;

  /// Delivery is free over this much, matching pharmacy.php.
  static const double _freeDeliveryThreshold = 500;
  static const double _deliveryFee = 60;

  /// Product columns plus the pharmacy embed that supplies `pharmacy_name`.
  static const _productColumns =
      'id, pharmacy_id, name, generic_name, brand, category, description, '
      'image, price, mrp, unit, stock, prescription_required, status, '
      'created_at, pharmacies!left(name)';

  Future<Paged<Product>> products({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? search,
    String? category,
    int? pharmacyId,
    ProductSort sort = ProductSort.relevance,
    bool inStockOnly = false,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);

      var query = _sb
          .db('pharmacy_products')
          .select(_productColumns)
          .eq('status', 'active');

      if (category != null && category.trim().isNotEmpty) {
        query = query.eq('category', category.trim());
      }
      if (pharmacyId != null) query = query.eq('pharmacy_id', pharmacyId);
      if (inStockOnly) query = query.gt('stock', 0);

      if (search != null && search.trim().isNotEmpty) {
        // Mirrors the PHP's three-column LIKE. A comma or parenthesis in the
        // term would split the `or` filter list into extra filters, so it is
        // neutralised first.
        final term = _escapeOr(search.trim());
        query = query.or(
          'name.ilike.%$term%,'
          'generic_name.ilike.%$term%,'
          'brand.ilike.%$term%',
        );
      }

      final res = await _applySort(query, sort)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) => Product.fromJson(_shapeProduct(r))).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  Future<Product> product(int id) async {
    return SupabaseService.guard(() async {
      final row = await _sb
          .db('pharmacy_products')
          .select(_productColumns)
          .eq('id', id)
          .maybeSingle();

      if (row == null) {
        throw ApiException(message: 'Product not found.', statusCode: 404);
      }
      return Product.fromJson(_shapeProduct(row));
    });
  }

  /// The filter chips.
  ///
  /// Postgrest cannot GROUP BY, so the counts are tallied here. Only `category`
  /// is selected and the rows are tiny, but this does read every active product's
  /// category — acceptable for a chip row, and the alternative is a view, which
  /// would mean changing the database.
  Future<List<ProductCategory>> categories() async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('pharmacy_products')
          .select('category')
          .eq('status', 'active')
          .not('category', 'is', null);

      final counts = <String, int>{};
      for (final r in rows) {
        final name = Fmt.str(r['category']);
        if (name.isEmpty) continue;
        counts[name] = (counts[name] ?? 0) + 1;
      }

      final out = counts.entries
          .map((e) => ProductCategory(e.key, e.value))
          .toList()
        ..sort((a, b) {
          final byCount = b.productCount.compareTo(a.productCount);
          return byCount != 0 ? byCount : a.name.compareTo(b.name);
        });

      return out;
    });
  }

  // -- cart ----------------------------------------------------------------

  Future<Cart> cart() async => SupabaseService.guard(() => _readCart());

  /// Adding a product already in the cart *increases* the quantity, as the PHP
  /// did. An upsert on `uq_cart_user_product` would overwrite it instead, which
  /// would silently lose the quantity already there.
  Future<Cart> addToCart({required int productId, int quantity = 1}) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      final wanted = quantity < 1 ? 1 : quantity;

      final existing = await _sb
          .db('cart')
          .select('id, quantity')
          .eq('user_id', userId)
          .eq('product_id', productId)
          .maybeSingle();

      if (existing == null) {
        await _sb.db('cart').insert({
          'user_id': userId,
          'product_id': productId,
          'quantity': _capQuantity(wanted),
        });
      } else {
        await _sb
            .db('cart')
            .update({
              'quantity': _capQuantity(Fmt.toInt(existing['quantity'], 1) + wanted),
            })
            .eq('id', existing['id']);
      }

      return _readCart();
    });
  }

  /// A quantity of 0 or less removes the line, matching `cart_update()`.
  /// `cart_quantity_check` would reject 0 outright, so it must not be written.
  Future<Cart> updateQuantity({
    required int productId,
    required int quantity,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();

      if (quantity <= 0) {
        await _sb
            .db('cart')
            .delete()
            .eq('user_id', userId)
            .eq('product_id', productId);
      } else {
        await _sb
            .db('cart')
            .update({'quantity': _capQuantity(quantity)})
            .eq('user_id', userId)
            .eq('product_id', productId);
      }

      return _readCart();
    });
  }

  Future<Cart> removeFromCart(int productId) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      await _sb
          .db('cart')
          .delete()
          .eq('user_id', userId)
          .eq('product_id', productId);
      return _readCart();
    });
  }

  // -- orders --------------------------------------------------------------

  /// Writes the order, its line items, decrements stock and empties the cart —
  /// all in one server-side transaction via the `place_order` RPC.
  ///
  /// Every amount is computed inside the RPC from `pharmacy_products.price`,
  /// never from anything the caller passed — §8. The client supplies only the
  /// delivery details and the payment choice; even the delivery fee comes back
  /// from the server, so the basket figure and the written figure cannot
  /// disagree. A line whose product went unavailable or short of stock aborts
  /// the checkout server-side, so the existing "reload the cart and show the
  /// message" handling still applies.
  ///
  /// `delivery_name`/`delivery_phone` are NOT NULL, so the account's name and
  /// phone are used when [name] or [phone] is omitted, and a 422 is raised if
  /// that still leaves either blank — better than a constraint violation the
  /// user cannot act on.
  ///
  /// ### [idempotencyKey]
  ///
  /// A value stable across retries of *the same* checkout attempt — mint it once
  /// when the screen opens, keep it while the user retries, replace it only once
  /// an order actually exists. `place_order()` stores it on the order under a
  /// unique-per-user index, so a second call with the same key returns the order
  /// the first call created instead of charging the basket twice. This is what
  /// makes a double tap, a dropped response, or a resumed app safe; it is not a
  /// nicety, because the first call may well have committed before the network
  /// gave up on us.
  Future<Order> checkout({
    required String address,
    required PaymentMethodOption paymentMethod,
    String? phone,
    String? name,
    String? city,
    String? notes,
    String? idempotencyKey,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      final key = _clean(idempotencyKey);

      // Refuse before writing anything if any line is no longer fulfillable.
      // The RPC would refuse too (P0001, "insufficient stock"), but this gives
      // the caller the same pre-flight message it always had.
      final lines = await _cartRows(userId);
      if (lines.isEmpty) {
        // An empty cart is ambiguous when a key is in play: either nothing was
        // ever added, or a previous attempt succeeded, emptied the cart, and
        // lost its reply on the way back. Only the server can tell those apart
        // — it holds the key — so hand it the call and let it either replay the
        // order or say the cart is empty. Deciding here would turn a completed
        // order into a dead end.
        if (key == null) {
          throw ApiException(
            message: 'Your cart is empty.',
            statusCode: 422,
            code: 'CART_EMPTY',
          );
        }
      } else {
        for (final line in lines) {
          final issue = _issueFor(line);
          if (issue != null) {
            throw ApiException(
              message: '${Fmt.str(line.name, 'A product')} is no longer '
                  'available in that quantity. Please review your cart.',
              statusCode: 409,
              code: 'OUT_OF_STOCK',
            );
          }
        }
      }

      final profile = await _sb
          .db('users')
          .select('name, phone, city')
          .eq('id', userId)
          .maybeSingle();

      final deliveryName = _firstNonEmpty([name, profile?['name']]);
      final deliveryPhone = _firstNonEmpty([phone, profile?['phone']]);

      if (deliveryName.isEmpty || deliveryPhone.isEmpty) {
        throw ApiException(
          message: 'A delivery name and phone number are required.',
          statusCode: 422,
          errors: {
            if (deliveryName.isEmpty) 'name': 'Please enter a name.',
            if (deliveryPhone.isEmpty) 'phone': 'Please enter a phone number.',
          },
        );
      }

      final cityValue = _firstNonEmptyOrNull([city, profile?['city']]);

      // place_order() is SECURITY DEFINER: it re-reads the cart, recomputes
      // subtotal from the products table, decrements stock atomically
      // (WHERE stock >= quantity makes a short line abort, not go negative),
      // snapshots the line items, empties the cart, and returns the row.
      //
      // It is also the ONLY way an order may be created — `guard_orders_insert`
      // rejects any other INSERT into `orders`. That rule is deliberate and is
      // not to be worked around here.
      final created = await _sb.rpc<Map<String, dynamic>>(
        'place_order',
        params: {
          'p_delivery_name': deliveryName,
          'p_delivery_phone': deliveryPhone,
          'p_delivery_address': address.trim(),
          if (cityValue != null) 'p_delivery_city': cityValue,
          'p_payment_method': paymentMethod.value,
          if (notes != null && notes.trim().isNotEmpty) 'p_notes': notes.trim(),
          if (key != null) 'p_idempotency_key': key,
        },
      );

      // The RPC row carries the money columns but no embeds; fetch the detail
      // (line items, product unit/image) through the same path the screens use.
      return _order(Fmt.toInt(created['id']));
    });
  }

  Future<Paged<Order>> orders({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    String? status,
  }) async {
    return SupabaseService.guard(() async {
      final userId = _requireUser();
      final range = PageRange(page, limit);

      var query = _sb
          .db('orders')
          .select('id, order_number, status, subtotal, delivery_fee, total, '
              'payment_status, payment_method, delivery_address, delivery_name, '
              'delivery_phone, delivery_city, notes, created_at, '
              'order_items(id)')
          .eq('user_id', userId);

      if (status != null && status.trim().isNotEmpty) {
        query = query.eq('status', status.trim());
      }

      final res = await query
          .order('created_at', ascending: false)
          .range(range.from, range.to)
          .count(CountOption.exact);

      return Paged(
        items: res.data.map((r) {
          final items = r['order_items'];
          return Order.fromJson({
            ...r,
            // List rows carry the count but no lines, as before. `items` is
            // removed so Order.isSummaryOnly stays true and the detail screen
            // still knows to fetch.
            'order_items': null,
            'items': null,
            'item_count': items is List ? items.length : 0,
          });
        }).toList(),
        meta: PageMeta(page: page, limit: limit, total: res.count),
      );
    });
  }

  /// List rows carry `item_count` but no `items`; this is the only place the
  /// line items arrive.
  Future<Order> order(int id) async => SupabaseService.guard(() => _order(id));

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<Order> _order(int id) async {
    final userId = _requireUser();

    final row = await _sb
        .db('orders')
        .select('id, order_number, status, subtotal, delivery_fee, total, '
            'payment_status, payment_method, delivery_address, delivery_name, '
            'delivery_phone, delivery_city, notes, created_at, '
            'order_items(product_id, product_name, unit_price, quantity, '
            'line_total, pharmacy_products!left(unit, image, category))')
        .eq('id', id)
        .eq('user_id', userId)
        .maybeSingle();

    if (row == null) {
      throw ApiException(message: 'Order not found.', statusCode: 404);
    }

    final rawItems = row['order_items'];
    final items = rawItems is List
        ? rawItems.whereType<Map>().map((e) {
            final product = e['pharmacy_products'] as Map<String, dynamic>?;
            return {
              'product_id': e['product_id'],
              // OrderLine reads `name`; the column is `product_name`, and it is
              // the name as charged, not today's product name.
              'name': e['product_name'],
              'unit_price': e['unit_price'],
              'quantity': e['quantity'],
              'line_total': e['line_total'],
              'unit': product?['unit'],
              'image': _sb.storageHelper.productImage(product?['image'] as String?),
              'category': product?['category'],
            };
          }).toList()
        : const [];

    return Order.fromJson({
      ...row,
      'items': items,
      'item_count': items.length,
    });
  }

  /// One cart line joined to its product, before any display shaping.
  ///
  /// A separate type rather than a `Map` because [checkout] and [_buildCart]
  /// both need the same figures and getting `unit_price` from the wrong place is
  /// exactly how a cart total and an order total start to disagree.
  Future<List<_CartRow>> _cartRows(String userId) async {
    final rows = await _sb
        .db('cart')
        .select('id, product_id, quantity, created_at, '
            'pharmacy_products!left(id, name, generic_name, category, image, '
            'price, unit, stock, prescription_required, status, pharmacy_id, '
            'pharmacies!left(name))')
        .eq('user_id', userId)
        .order('created_at', ascending: true);

    return rows.map((r) {
      final p = r['pharmacy_products'] as Map<String, dynamic>?;
      final pharmacy = p?['pharmacies'] as Map<String, dynamic>?;
      final quantity = Fmt.toInt(r['quantity'], 1);
      final unitPrice = Fmt.toDouble(p?['price']);

      return _CartRow(
        cartId: Fmt.toInt(r['id']),
        productId: Fmt.toInt(r['product_id']),
        name: Fmt.str(p?['name'], 'Product'),
        genericName: Fmt.str(p?['generic_name']),
        category: Fmt.str(p?['category']),
        image: _sb.storageHelper.productImage(p?['image'] as String?),
        unit: Fmt.str(p?['unit']),
        pharmacyId: p?['pharmacy_id'] == null ? null : Fmt.toInt(p?['pharmacy_id']),
        pharmacyName: Fmt.str(pharmacy?['name']),
        unitPrice: unitPrice,
        quantity: quantity,
        lineTotal: _round(unitPrice * quantity),
        stock: Fmt.toInt(p?['stock']),
        requiresPrescription: Fmt.toBool(p?['prescription_required']),
        // A null embed means the product row is gone or invisible.
        isActive: p != null && Fmt.str(p['status'], 'active') == 'active',
        exists: p != null,
      );
    }).toList();
  }

  Future<Cart> _readCart() async {
    final userId = _requireUser();
    return _buildCart(await _cartRows(userId));
  }

  /// Reproduces `cart_payload()`: the lines, their issue flags, and the summary.
  ///
  /// Lines with an issue are excluded from the subtotal, exactly as the PHP did,
  /// so the total the user sees is what they would actually be charged once the
  /// blocked lines are removed.
  Cart _buildCart(List<_CartRow> rows) {
    final lines = <Map<String, dynamic>>[];
    var payableSubtotal = 0.0;
    var totalQuantity = 0;
    var hasIssues = false;

    for (final r in rows) {
      final issue = _issueFor(r);
      if (issue != null) {
        hasIssues = true;
      } else {
        payableSubtotal += r.lineTotal;
        totalQuantity += r.quantity;
      }

      lines.add({
        'cart_id': r.cartId,
        'product_id': r.productId,
        'name': r.name,
        'unit_price': r.unitPrice,
        'quantity': r.quantity,
        'line_total': r.lineTotal,
        'generic_name': r.genericName,
        'category': r.category,
        'image': r.image,
        'pharmacy_name': r.pharmacyName,
        'stock': r.stock,
        'unit': r.unit,
        'requires_prescription': r.requiresPrescription,
        'issue': issue,
      });
    }

    final subtotal = _round(payableSubtotal);
    final delivery = rows.isEmpty ? 0.0 : _deliveryFeeFor(subtotal);

    return Cart.fromJson({
      'items': lines,
      'summary': {
        'item_count': rows.length,
        'total_quantity': totalQuantity,
        'subtotal': subtotal,
        'delivery_fee': delivery,
        'total': _round(subtotal + delivery),
        'currency': AppConfig.currencyCode,
        'has_issues': hasIssues,
        // The Place Order button follows this rather than deciding for itself.
        'checkout_ready': rows.isNotEmpty && !hasIssues,
      },
    });
  }

  /// null when the line is fine; otherwise the same three values the PHP used,
  /// which [CartLine.issueLabel] already has wording for.
  static String? _issueFor(_CartRow r) {
    if (!r.exists || !r.isActive) return 'unavailable';
    if (r.stock <= 0) return 'out_of_stock';
    if (r.quantity > r.stock) return 'insufficient_stock';
    return null;
  }

  static double _deliveryFeeFor(double subtotal) =>
      subtotal >= _freeDeliveryThreshold || subtotal <= 0 ? 0 : _deliveryFee;

  /// Applies the sort the UI asked for.
  ///
  /// The default is in-stock first then name, which is what the PHP's
  /// `ORDER BY (stock > 0) DESC, name ASC` did. Postgrest cannot order by an
  /// expression, so `stock` descending is used as the nearest equivalent — it
  /// puts every in-stock product ahead of every out-of-stock one, which is the
  /// property that mattered.
  static PostgrestTransformBuilder<PostgrestList> _applySort(
    PostgrestFilterBuilder<PostgrestList> query,
    ProductSort sort,
  ) {
    switch (sort) {
      case ProductSort.priceAsc:
        return query.order('price', ascending: true);
      case ProductSort.priceDesc:
        return query.order('price', ascending: false);
      case ProductSort.name:
        return query.order('name', ascending: true);
      case ProductSort.newest:
        return query.order('created_at', ascending: false);
      case ProductSort.relevance:
        return query
            .order('stock', ascending: false)
            .order('name', ascending: true);
    }
  }

  Map<String, dynamic> _shapeProduct(Map<String, dynamic> r) {
    final pharmacy = r['pharmacies'] as Map<String, dynamic>?;
    final stock = Fmt.toInt(r['stock']);
    return {
      ...r,
      'image': _sb.storageHelper.productImage(r['image'] as String?),
      'pharmacy_name': pharmacy?['name'],
      // The model reads these output names; the columns are spelled differently.
      'in_stock': stock > 0,
      'is_active': Fmt.str(r['status'], 'active') == 'active',
      'requires_prescription': r['prescription_required'],
    };
  }

  /// The server capped quantity at 99 and so does this, so a stepper bug cannot
  /// write a 10,000-unit line.
  static int _capQuantity(int q) {
    if (q < 1) return 1;
    return q > 99 ? 99 : q;
  }

  static double _round(double v) => (v * 100).roundToDouble() / 100;

  static String _firstNonEmpty(List<Object?> candidates) {
    for (final c in candidates) {
      final s = Fmt.str(c);
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  static String? _firstNonEmptyOrNull(List<Object?> candidates) {
    final s = _firstNonEmpty(candidates);
    return s.isEmpty ? null : s;
  }

  /// Trimmed, or null when there is nothing left. Used for the idempotency key
  /// so that an empty string never reaches the RPC: `place_order()` treats a
  /// non-null key as "look this up first", and '' would collide with every
  /// other blank key the same user ever sent.
  static String? _clean(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  String _requireUser() {
    final id = _sb.currentUserId;
    if (id == null || id.isEmpty) {
      throw ApiException(
        message: 'Please sign in to continue.',
        statusCode: 401,
      );
    }
    return id;
  }

  static String _escapeOr(String term) =>
      term.replaceAll(RegExp(r'[,()]'), ' ').replaceAll('*', '');
}

/// One cart line joined to its product. Internal to this file.
class _CartRow {
  const _CartRow({
    required this.cartId,
    required this.productId,
    required this.name,
    required this.genericName,
    required this.category,
    required this.image,
    required this.unit,
    required this.pharmacyId,
    required this.pharmacyName,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
    required this.stock,
    required this.requiresPrescription,
    required this.isActive,
    required this.exists,
  });

  final int cartId;
  final int productId;
  final String name;
  final String genericName;
  final String category;
  final String image;
  final String unit;
  final int? pharmacyId;
  final String pharmacyName;
  final double unitPrice;
  final int quantity;
  final double lineTotal;
  final int stock;
  final bool requiresPrescription;
  final bool isActive;

  /// False when the product row is gone or hidden by RLS — the embed is null.
  final bool exists;
}

final pharmacyRepositoryProvider = Provider<PharmacyRepository>(
  (ref) => PharmacyRepository(ref.watch(supabaseServiceProvider)),
);
