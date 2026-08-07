/// Products, cart and orders.
///
/// §8 is strict that money is server-computed. So [CartSummary] holds no
/// arithmetic — it reads the numbers the API's `cart_payload()` already worked
/// out. If the app recomputed a subtotal it could disagree with the order that
/// actually gets written.
library;

import '../core/utils/formatters.dart';

/// The payment methods `pharmacy_checkout()` whitelists, verbatim:
/// `in:bKash,Nagad,Rocket,Credit/Debit Card,Bank Transfer,Cash`. Anything else is
/// a 400, so the checkout sheet builds its options from this enum rather than
/// strings.
///
/// These are the values of the live `payments.payment_method` enum, and the
/// **casing is part of the value** — 'bkash' is not 'bKash' and would be
/// rejected. The previous version of this enum used invented snake_case values
/// (`cash_on_delivery`, `manual`) that no column has ever accepted.
///
/// Deliberately kept separate from [PaymentMethod] in appointment_models.dart
/// even though the two lists currently match. They are two endpoints with two
/// independent whitelists; merging them would mean a change to one silently
/// starts sending unaccepted values to the other.
enum PaymentMethodOption {
  bkash('bKash', 'bKash', false),
  nagad('Nagad', 'Nagad', false),
  rocket('Rocket', 'Rocket', false),
  card('Credit/Debit Card', 'Credit / debit card', false),
  bankTransfer('Bank Transfer', 'Bank transfer', false),
  cash('Cash', 'Cash on delivery', true);

  const PaymentMethodOption(this.value, this.label, this.isOffline);

  final String value;
  final String label;

  /// Cash is collected by the rider, so no money has moved when the order is
  /// placed. Every order starts `payment_status = 'pending'` regardless — the
  /// admin panel marks it paid — but the confirmation copy should not imply a
  /// transfer the user never made.
  final bool isOffline;

  static PaymentMethodOption? fromValue(String? raw) {
    for (final m in values) {
      if (m.value == raw) return m;
    }
    return null;
  }
}

/// Mirrors `product_public()` in pharmacy.php.
///
/// Two fields are conditional there: `rating` appears only when the query
/// selected an `avg_rating` aggregate, and `is_active` is never emitted at all —
/// every product query already filters `is_active = 1`, so anything the app
/// receives is by definition active. [isActive] therefore defaults to true and
/// exists only so a future admin endpoint can set it.
class Product {
  const Product({
    required this.id,
    required this.name,
    required this.price,
    required this.stock,
    required this.inStock,
    this.genericName,
    this.category,
    this.image,
    this.description,
    this.unit,
    this.pharmacyId,
    this.pharmacyName,
    this.rating,
    this.isActive = true,
    this.requiresPrescription = false,
  });

  final int id;
  final String name;
  final double price;
  final int stock;

  /// The server's own `stock > 0` verdict. Preferred over recomputing from
  /// [stock] so the app and API never disagree about availability.
  final bool inStock;

  /// [ASSUMED] `pharmacy_products.generic_name` — e.g. "Paracetamol" under the
  /// brand name "Napa". Shown as a subtitle.
  final String? genericName;

  final String? category;
  final String? image;
  final String? description;

  /// [ASSUMED] e.g. "60 tablets", "100 ml".
  final String? unit;

  final int? pharmacyId;
  final String? pharmacyName;

  /// null when the endpoint did not aggregate ratings — which is different from
  /// a product rated 0. The UI hides the stars rather than showing an empty row.
  final double? rating;

  final bool isActive;

  /// [ASSUMED] `pharmacy_products.requires_prescription`.
  final bool requiresPrescription;

  factory Product.fromJson(Map<String, dynamic> json) {
    final stock = Fmt.toInt(json['stock']);
    return Product(
      id: Fmt.toInt(json['id']),
      name: Fmt.str(json['name'], 'Unnamed product'),
      price: Fmt.toDouble(json['price']),
      stock: stock,
      inStock: Fmt.toBool(json['in_stock'], stock > 0),
      genericName: _orNull(json['generic_name']),
      category: _orNull(json['category']),
      image: _orNull(json['image']),
      description: _orNull(json['description']),
      unit: _orNull(json['unit']),
      pharmacyId:
          Fmt.toInt(json['pharmacy_id']) == 0 ? null : Fmt.toInt(json['pharmacy_id']),
      pharmacyName: _orNull(json['pharmacy_name']),
      rating: json['rating'] == null ? null : Fmt.toDouble(json['rating']),
      isActive: Fmt.toBool(json['is_active'], true),
      requiresPrescription: Fmt.toBool(json['requires_prescription']),
    );
  }

  bool get isAvailable => inStock && isActive;
  bool get isLowStock => stock > 0 && stock <= 5;
  bool get hasRating => rating != null && rating! > 0;

  /// The add-to-cart stepper's ceiling: the server caps quantity at 99 and
  /// rejects anything above stock at checkout.
  int get maxQuantity => stock <= 0 ? 0 : (stock > 99 ? 99 : stock);

  String get stockLabel {
    if (!isActive) return 'Unavailable';
    if (!inStock) return 'Out of stock';
    if (isLowStock) return 'Only $stock left';
    return 'In stock';
  }

  String get stockStatus => isAvailable ? 'available' : 'unavailable';
  String get priceLabel => Fmt.money(price);

  /// "Paracetamol · 60 tablets" — whichever parts exist.
  String get subtitle =>
      [genericName, unit].where((s) => s != null && s.isNotEmpty).join(' · ');
}

/// One line in the cart. `lineTotal` and `issue` both come from the server.
///
/// Mirrors the item shaper inside `cart_payload()`. Note the price key is
/// `unit_price`, not `price` — the products endpoint uses `price`, the cart
/// renames it. Reading the wrong one silently yields ৳0 per line.
class CartLine {
  const CartLine({
    required this.cartId,
    required this.productId,
    required this.name,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
    this.genericName,
    this.category,
    this.image,
    this.pharmacyName,
    this.stock = 0,
    this.unit,
    this.requiresPrescription = false,
    this.issue,
  });

  /// `cart.id` — the row's own id. Distinct from [productId]; the mutation
  /// endpoints all key off `product_id`, so this is for widget keys only.
  final int cartId;

  final int productId;
  final String name;

  /// `unit_price` — today's product price, not a snapshot. The cart re-reads it
  /// on every fetch, so a price change is reflected before checkout.
  final double unitPrice;

  final int quantity;
  final double lineTotal;
  final String? genericName;
  final String? category;
  final String? image;
  final String? pharmacyName;
  final int stock;
  final String? unit;
  final bool requiresPrescription;

  /// null when fine; otherwise `unavailable` | `out_of_stock` |
  /// `insufficient_stock`. Lines with an issue are excluded from the payable
  /// subtotal by the server, so the UI must show them as blocked.
  final String? issue;

  factory CartLine.fromJson(Map<String, dynamic> json) => CartLine(
        cartId: Fmt.toInt(json['cart_id']),
        productId: Fmt.toInt(json['product_id']),
        name: Fmt.str(json['name'], 'Product'),
        unitPrice: Fmt.toDouble(json['unit_price']),
        quantity: Fmt.toInt(json['quantity'], 1),
        lineTotal: Fmt.toDouble(json['line_total']),
        genericName: _orNull(json['generic_name']),
        category: _orNull(json['category']),
        image: _orNull(json['image']),
        pharmacyName: _orNull(json['pharmacy_name']),
        stock: Fmt.toInt(json['stock']),
        unit: _orNull(json['unit']),
        requiresPrescription: Fmt.toBool(json['requires_prescription']),
        issue: _orNull(json['issue']),
      );

  bool get hasIssue => issue != null;

  /// The server caps quantity at 99; the stepper must also stop at stock, since
  /// exceeding it turns the line into an `insufficient_stock` issue and blocks
  /// the whole checkout.
  int get maxQuantity => stock <= 0 ? 0 : (stock > 99 ? 99 : stock);

  String get issueLabel {
    switch (issue) {
      case 'unavailable':
        return 'No longer sold — remove to continue';
      case 'out_of_stock':
        return 'Out of stock — remove to continue';
      case 'insufficient_stock':
        return 'Only $stock left — reduce the quantity';
      default:
        return '';
    }
  }

  String get unitPriceLabel => Fmt.money(unitPrice);
  String get lineTotalLabel => Fmt.money(lineTotal);
}

/// The `summary` block of `cart_payload()`. Read-only by design.
class CartSummary {
  const CartSummary({
    this.itemCount = 0,
    this.totalQuantity = 0,
    this.subtotal = 0,
    this.deliveryFee = 0,
    this.total = 0,
    this.currency = 'BDT',
    this.hasIssues = false,
    this.checkoutReady = false,
  });

  final int itemCount;
  final int totalQuantity;
  final double subtotal;
  final double deliveryFee;
  final double total;
  final String currency;
  final bool hasIssues;

  /// The server's verdict on whether checkout can proceed. The Place Order
  /// button follows this rather than deciding for itself.
  final bool checkoutReady;

  factory CartSummary.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CartSummary();
    return CartSummary(
      itemCount: Fmt.toInt(json['item_count']),
      totalQuantity: Fmt.toInt(json['total_quantity']),
      subtotal: Fmt.toDouble(json['subtotal']),
      deliveryFee: Fmt.toDouble(json['delivery_fee']),
      total: Fmt.toDouble(json['total']),
      currency: Fmt.str(json['currency'], 'BDT'),
      hasIssues: Fmt.toBool(json['has_issues']),
      checkoutReady: Fmt.toBool(json['checkout_ready']),
    );
  }

  String get subtotalLabel => Fmt.money(subtotal);
  String get deliveryLabel => deliveryFee <= 0 ? 'Free' : Fmt.money(deliveryFee);
  String get totalLabel => Fmt.money(total);
}

class Cart {
  const Cart({this.lines = const [], this.summary = const CartSummary()});

  final List<CartLine> lines;
  final CartSummary summary;

  factory Cart.fromJson(Map<String, dynamic> json) {
    final raw = json['items'] ?? json['lines'] ?? json['cart'];
    final lines = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => CartLine.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
            .toList()
        : <CartLine>[];
    return Cart(
      lines: lines,
      summary: CartSummary.fromJson(
        json['summary'] is Map
            ? (json['summary'] as Map).map((k, v) => MapEntry(k.toString(), v))
            : null,
      ),
    );
  }

  bool get isEmpty => lines.isEmpty;
  int get badgeCount => summary.totalQuantity;
}

/// One row of `order_items`, joined to the product for display.
///
/// There is no `id` on these — the shaper projects `product_id` only, so
/// `product_id` is the list key. Two lines for the same product cannot occur
/// (the cart merges them), so it is safe as a key.
class OrderLine {
  const OrderLine({
    required this.productId,
    required this.name,
    required this.unitPrice,
    required this.quantity,
    required this.lineTotal,
    this.unit,
    this.image,
    this.category,
  });

  final int productId;
  final String name;

  /// `order_items.unit_price` — the price as charged at order time, which may
  /// differ from today's `pharmacy_products.price`. Never re-read from the
  /// product for a historical order.
  final double unitPrice;

  final int quantity;

  /// Server-computed as `unit_price * quantity`, rounded to 2dp.
  final double lineTotal;

  final String? unit;
  final String? image;
  final String? category;

  factory OrderLine.fromJson(Map<String, dynamic> json) => OrderLine(
        productId: Fmt.toInt(json['product_id']),
        name: Fmt.str(json['name'], 'Product'),
        unitPrice: Fmt.toDouble(json['unit_price']),
        quantity: Fmt.toInt(json['quantity'], 1),
        lineTotal: Fmt.toDouble(json['line_total']),
        unit: _orNull(json['unit']),
        image: _orNull(json['image']),
        category: _orNull(json['category']),
      );

  String get unitPriceLabel => Fmt.money(unitPrice);
  String get lineTotalLabel => Fmt.money(lineTotal);
}

/// Mirrors `order_detail_payload()` and the row shaper in `pharmacy_orders()`.
/// The list rows carry the money breakdown too; only `items`, the delivery
/// contact and `notes` are detail-only.
///
/// The earlier version of this doc said `orders` had a single `total_amount` and
/// no subtotal, phone or notes column. That is no longer true: the table created
/// by `database/migration_v1.sql` has `subtotal`, `delivery_fee` and `total`, so
/// an order screen can re-show the same breakdown the cart showed. The API still
/// emits `total_amount` as an alias of `total`, and [fromJson] reads either.
class Order {
  const Order({
    required this.id,
    required this.orderNumber,
    required this.status,
    required this.total,
    this.subtotal = 0,
    this.deliveryFee = 0,
    this.paymentStatus = 'pending',
    this.paymentMethod,
    this.address,
    this.deliveryName,
    this.deliveryPhone,
    this.deliveryCity,
    this.notes,
    this.itemCount = 0,
    this.lines = const [],
    this.createdAt,
  });

  final int id;

  /// `AYU-000123`, generated server-side from the insert id.
  final String orderNumber;

  /// pending | confirmed | processing | shipped | delivered | cancelled
  final String status;

  /// `orders.total` — the whole charge, already inclusive of delivery.
  final double total;

  /// `orders.subtotal` — goods only, before delivery.
  final double subtotal;

  /// `orders.delivery_fee`. Zero is a real value (free over ৳500), not a gap.
  final double deliveryFee;

  /// pending | paid | refunded — the live enum. There is no 'unpaid' and no
  /// 'failed'. Every order starts 'pending'; only the admin panel marks it paid,
  /// so the app must never treat placing an order as payment received.
  final String paymentStatus;

  /// One of [PaymentMethodOption]'s wire values.
  final String? paymentMethod;

  /// `orders.delivery_address`, sent as `address`. NOT NULL server-side.
  final String? address;

  /// `delivery_name` / `delivery_phone` are NOT NULL columns, filled from the
  /// form or the account. Detail rows only — the list shaper omits them.
  final String? deliveryName;
  final String? deliveryPhone;
  final String? deliveryCity;

  /// `orders.notes` — delivery instructions. Detail rows only.
  final String? notes;

  /// Present on both list and detail rows. On list rows it is the only clue to
  /// the order's size, since `lines` arrives empty there.
  final int itemCount;

  /// Populated by `/pharmacy/orders/{id}` only; always empty on list rows.
  final List<OrderLine> lines;

  final String? createdAt;

  factory Order.fromJson(Map<String, dynamic> json) {
    final raw = json['items'];
    final lines = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => OrderLine.fromJson(e.map((k, v) => MapEntry(k.toString(), v))))
            .toList()
        : <OrderLine>[];
    return Order(
      id: Fmt.toInt(json['id']),
      orderNumber: Fmt.str(json['order_number'], '—'),
      status: Fmt.str(json['status'], 'pending'),
      // `total` is the column; `total_amount` is the API's alias for it. Read
      // both so neither shape can produce a ৳0 order.
      total: Fmt.toDouble(json['total'] ?? json['total_amount']),
      subtotal: Fmt.toDouble(json['subtotal']),
      deliveryFee: Fmt.toDouble(json['delivery_fee']),
      paymentStatus: Fmt.str(json['payment_status'], 'pending'),
      paymentMethod: _orNull(json['payment_method']),
      address: _orNull(json['address'] ?? json['delivery_address']),
      deliveryName: _orNull(json['delivery_name']),
      deliveryPhone: _orNull(json['delivery_phone']),
      deliveryCity: _orNull(json['delivery_city']),
      notes: _orNull(json['notes']),
      itemCount: Fmt.toInt(json['item_count'], lines.length),
      lines: lines,
      createdAt: _orNull(json['created_at']),
    );
  }

  /// True on list rows, where the API omits `items` by design. Detail screens
  /// use this to know they must fetch rather than render an empty basket.
  bool get isSummaryOnly => lines.isEmpty && itemCount > 0;

  bool get isPaid => paymentStatus == 'paid';
  bool get isRefunded => paymentStatus == 'refunded';
  bool get isCancelled => status == 'cancelled';

  /// What the payment pill should say. 'pending' is deliberately not shown as
  /// "unpaid": for cash on delivery nothing is owed yet, and for a transfer the
  /// money may already have been sent and be awaiting a human check.
  String get paymentLabel {
    if (isPaid) return 'Paid';
    if (isRefunded) return 'Refunded';
    final m = PaymentMethodOption.fromValue(paymentMethod);
    return m != null && m.isOffline ? 'Pay on delivery' : 'Awaiting confirmation';
  }

  /// The human name for [paymentMethod], falling back to the raw value so an
  /// unrecognised method from the real backend still renders something.
  String get paymentMethodLabel =>
      PaymentMethodOption.fromValue(paymentMethod)?.label ??
      (paymentMethod == null ? 'Not set' : paymentMethod!);

  String get itemCountLabel => '$itemCount item${itemCount == 1 ? '' : 's'}';
  String get totalLabel => Fmt.money(total);
  String get subtotalLabel => Fmt.money(subtotal);
  String get deliveryFeeLabel => deliveryFee <= 0 ? 'Free' : Fmt.money(deliveryFee);
  String get placedLabel => Fmt.dateTime(createdAt);
}

String? _orNull(Object? v) {
  final s = Fmt.str(v);
  return s.isEmpty ? null : s;
}
