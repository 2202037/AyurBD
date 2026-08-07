<?php
/**
 * Pharmacy — §6 /pharmacy/*
 *
 * §8: "cart quantity/stock/totals must equal backend computation exactly — no
 * client-side price math shown as final." Every cart response therefore carries
 * a server-computed `summary` block, and the app renders that verbatim.
 *
 * §5: "stock re-checked at checkout" — checkout re-reads stock FOR UPDATE inside
 * the transaction, so a concurrent buyer cannot oversell.
 */

declare(strict_types=1);

/**
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function product_public(array $r): array
{
    $out = [
        'id'                    => (int) $r['id'],
        'pharmacy_id'           => isset($r['pharmacy_id']) && $r['pharmacy_id'] !== null ? (int) $r['pharmacy_id'] : null,
        'pharmacy_name'         => $r['pharmacy_name'] ?? null,
        'name'                  => $r['name'],
        'generic_name'          => $r['generic_name'] ?? null,
        'category'              => $r['category'] ?? null,
        'description'           => $r['description'] ?? null,
        'price'                 => (float) $r['price'],
        'stock'                 => (int) $r['stock'],
        'in_stock'              => (int) $r['stock'] > 0,
        'unit'                  => $r['unit'] ?? null,
        'image'                 => $r['image'] ?? null,
        // Outgoing key stays `requires_prescription` (the Dart model reads that);
        // the column it comes from is `prescription_required`. Likewise the
        // product's availability column is `status` enum('active','inactive'),
        // matching every other table in this database, not an is_active flag.
        'requires_prescription' => (bool) ($r['prescription_required'] ?? false),
    ];

    if (isset($r['avg_rating'])) {
        $out['rating'] = round((float) $r['avg_rating'], 2);
    }

    return $out;
}

/** GET /pharmacy/products?search&category&page&limit */
function pharmacy_products(): void
{
    [$page, $limit, $offset] = paging();

    $where  = ["p.status = 'active'"];
    $params = [];

    if ($search = q('search')) {
        $where[]  = '(p.name LIKE ? OR p.generic_name LIKE ? OR p.description LIKE ?)';
        $like     = '%' . $search . '%';
        $params[] = $like;
        $params[] = $like;
        $params[] = $like;
    }
    if ($category = q('category')) {
        $where[]  = 'p.category = ?';
        $params[] = $category;
    }
    if ($pharmacyId = q('pharmacy_id')) {
        if (ctype_digit($pharmacyId)) {
            $where[]  = 'p.pharmacy_id = ?';
            $params[] = (int) $pharmacyId;
        }
    }
    if (q('in_stock') === '1') {
        $where[] = 'p.stock > 0';
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM pharmacy_products p $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    // Sort whitelist — never interpolate user input into ORDER BY.
    $sortMap = [
        'price_asc'  => 'p.price ASC',
        'price_desc' => 'p.price DESC',
        'name'       => 'p.name ASC',
        'newest'     => 'p.id DESC',
    ];
    $orderBy = $sortMap[q('sort') ?? ''] ?? 'p.stock > 0 DESC, p.name ASC';

    $stmt = db()->prepare(
        "SELECT p.*, ph.name AS pharmacy_name
           FROM pharmacy_products p
           LEFT JOIN pharmacies ph ON ph.id = p.pharmacy_id
         $whereSql
         ORDER BY $orderBy
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['products' => array_map('product_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/** GET /pharmacy/products/{id} */
function pharmacy_product_detail(string $id): void
{
    // No product rating is selected, and that is not an omission. Product reviews
    // cannot exist: `reviews.reviewable_type` is
    // enum('doctor','hospital','clinic','pharmacy') with no 'product' value, so
    // the average this query used to compute was always NULL. See REVIEW_TARGETS
    // in content.php. product_public() omits `rating` when it is absent, so the
    // app shows no rating rather than a misleading 0.0.
    $stmt = db()->prepare(
        "SELECT p.*, ph.name AS pharmacy_name
           FROM pharmacy_products p
           LEFT JOIN pharmacies ph ON ph.id = p.pharmacy_id
          WHERE p.id = ? LIMIT 1"
    );
    $stmt->execute([(int) $id]);
    $row = $stmt->fetch();

    if (!$row) {
        json_error('Product not found.', 404);
    }

    json_ok(['product' => product_public($row)]);
}

/** GET /pharmacy/categories — filter chips for the catalog. */
function pharmacy_categories(): void
{
    $stmt = db()->query(
        "SELECT category, COUNT(*) AS product_count
           FROM pharmacy_products
          WHERE status = 'active' AND category IS NOT NULL AND category <> ''
          GROUP BY category ORDER BY product_count DESC"
    );

    json_ok(['categories' => array_map(static fn($r) => [
        'category'      => $r['category'],
        'product_count' => (int) $r['product_count'],
    ], $stmt->fetchAll())]);
}

/**
 * Build the canonical cart payload. Single source of truth for cart totals —
 * both /pharmacy/cart and every mutation return this exact shape (§8).
 *
 * @return array<string,mixed>
 */
function cart_payload(int $userId): array
{
    // LEFT JOIN on the product, matching `order_detail_payload()` further down.
    // An inner join made a cart row whose product was hard-deleted vanish from
    // `items` without ever setting the `unavailable` issue flag below — the
    // subtotal and the badge quietly changed and nothing said why. A missing
    // product now surfaces as an unavailable line the user can remove.
    $stmt = db()->prepare(
        'SELECT c.id AS cart_id, c.quantity, c.product_id,
                p.name, p.generic_name, p.price, p.stock, p.unit, p.image,
                p.category, p.prescription_required, p.status,
                ph.name AS pharmacy_name
           FROM cart c
           LEFT JOIN pharmacy_products p ON p.id = c.product_id
           LEFT JOIN pharmacies ph  ON ph.id = p.pharmacy_id
          WHERE c.user_id = ?
          ORDER BY c.created_at ASC'
    );
    $stmt->execute([$userId]);

    $items       = [];
    $subtotal    = 0.0;
    $totalItems  = 0;
    $hasIssue    = false;

    foreach ($stmt->fetchAll() as $r) {
        $qty  = (int) $r['quantity'];
        $unit = (float) $r['price'];
        // Server does the math. The app displays these numbers, never its own.
        $line = round($unit * $qty, 2);

        $issue = null;
        if ($r['status'] !== 'active') {
            $issue = 'unavailable';
        } elseif ((int) $r['stock'] <= 0) {
            $issue = 'out_of_stock';
        } elseif ($qty > (int) $r['stock']) {
            $issue = 'insufficient_stock';
        }
        if ($issue !== null) {
            $hasIssue = true;
        }

        $items[] = [
            'cart_id'               => (int) $r['cart_id'],
            'product_id'            => (int) $r['product_id'],
            'name'                  => $r['name'],
            'generic_name'          => $r['generic_name'],
            'category'              => $r['category'],
            'unit'                  => $r['unit'],
            'image'                 => $r['image'],
            'pharmacy_name'         => $r['pharmacy_name'],
            'unit_price'            => $unit,
            'quantity'              => $qty,
            'line_total'            => $line,
            'stock'                 => (int) $r['stock'],
            'requires_prescription' => (bool) $r['prescription_required'],
            'issue'                 => $issue,
        ];

        // Lines with problems are excluded from the payable subtotal.
        if ($issue === null) {
            $subtotal   += $line;
            $totalItems += $qty;
        }
    }

    // Flat delivery fee, waived above a threshold. Adjust to match the website's
    // actual rule — this is a placeholder, not a business decision from §6.
    $deliveryFee = ($subtotal > 0 && $subtotal < 500) ? 60.0 : 0.0;

    return [
        'items'   => $items,
        'summary' => [
            'item_count'     => count($items),
            'total_quantity' => $totalItems,
            'subtotal'       => round($subtotal, 2),
            'delivery_fee'   => $deliveryFee,
            'total'          => round($subtotal + $deliveryFee, 2),
            'currency'       => 'BDT',
            'has_issues'     => $hasIssue,
            'checkout_ready' => $subtotal > 0 && !$hasIssue,
        ],
    ];
}

/** GET /pharmacy/cart */
function pharmacy_cart_get(): void
{
    $user = require_auth();
    json_ok(cart_payload((int) $user['id']));
}

/** POST /pharmacy/cart/add {product_id,quantity} */
function pharmacy_cart_add(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'product_id' => 'required|int',
        'quantity'   => 'int|min:1|max:99',
    ]);
    $qty = (int) ($in['quantity'] ?? 1);

    $ps = db()->prepare('SELECT * FROM pharmacy_products WHERE id = ? LIMIT 1');
    $ps->execute([$in['product_id']]);
    $product = $ps->fetch();

    if (!$product || $product['status'] !== 'active') {
        json_error('Product not found.', 404);
    }

    // Existing line? Adding again increments rather than duplicating.
    $cs = db()->prepare('SELECT quantity FROM cart WHERE user_id = ? AND product_id = ? LIMIT 1');
    $cs->execute([$user['id'], $in['product_id']]);
    $existing = $cs->fetchColumn();
    $newQty   = ($existing === false ? 0 : (int) $existing) + $qty;

    if ($newQty > (int) $product['stock']) {
        json_error('Not enough stock available.', 409, [
            'quantity' => 'Only ' . (int) $product['stock'] . ' in stock.',
        ]);
    }

    // ON DUPLICATE KEY relies on uq_cart_user_product — atomic upsert.
    db()->prepare(
        'INSERT INTO cart (user_id, product_id, quantity) VALUES (?, ?, ?)
         ON DUPLICATE KEY UPDATE quantity = VALUES(quantity)'
    )->execute([$user['id'], $in['product_id'], $newQty]);

    json_ok(cart_payload((int) $user['id']), 'Added to cart.');
}

/** POST /pharmacy/cart/update {product_id,quantity} — quantity 0 removes. */
function pharmacy_cart_update(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'product_id' => 'required|int',
        'quantity'   => 'required|int|min:0|max:99',
    ]);
    $qty = (int) $in['quantity'];

    if ($qty === 0) {
        db()->prepare('DELETE FROM cart WHERE user_id = ? AND product_id = ?')
            ->execute([$user['id'], $in['product_id']]);

        json_ok(cart_payload((int) $user['id']), 'Item removed from cart.');
    }

    $ps = db()->prepare('SELECT stock, status FROM pharmacy_products WHERE id = ? LIMIT 1');
    $ps->execute([$in['product_id']]);
    $product = $ps->fetch();

    if (!$product || $product['status'] !== 'active') {
        json_error('Product not found.', 404);
    }
    if ($qty > (int) $product['stock']) {
        json_error('Not enough stock available.', 409, [
            'quantity' => 'Only ' . (int) $product['stock'] . ' in stock.',
        ]);
    }

    $stmt = db()->prepare('UPDATE cart SET quantity = ? WHERE user_id = ? AND product_id = ?');
    $stmt->execute([$qty, $user['id'], $in['product_id']]);

    if ($stmt->rowCount() === 0) {
        // Not in the cart yet — treat update as an add so the client stays simple.
        db()->prepare('INSERT IGNORE INTO cart (user_id, product_id, quantity) VALUES (?, ?, ?)')
            ->execute([$user['id'], $in['product_id'], $qty]);
    }

    json_ok(cart_payload((int) $user['id']), 'Cart updated.');
}

/** POST /pharmacy/cart/remove {product_id} */
function pharmacy_cart_remove(): void
{
    $user = require_auth();

    $in = validate(json_body(), ['product_id' => 'required|int']);

    db()->prepare('DELETE FROM cart WHERE user_id = ? AND product_id = ?')
        ->execute([$user['id'], $in['product_id']]);

    json_ok(cart_payload((int) $user['id']), 'Item removed from cart.');
}

/**
 * POST /pharmacy/checkout {payment_method,address} — §6 NEW
 * Creates orders + order_items, decrements stock, clears cart, all in one
 * transaction with a FOR UPDATE re-check (§5).
 */
function pharmacy_checkout(): void
{
    $user = require_auth();

    // payment_method values are the same enum the live `payments` table uses, so
    // the two payment paths in this app speak one vocabulary. Exact casing
    // matters: 'bKash', 'Credit/Debit Card'.
    //
    // delivery_name / delivery_phone / delivery_address are NOT NULL on `orders`,
    // so name and phone fall back to the account and are rejected if both are
    // blank — better a 422 than a 500 from the constraint.
    $in = validate(json_body(), [
        'payment_method' => 'required|in:bKash,Nagad,Rocket,Credit/Debit Card,Bank Transfer,Cash',
        'address'        => 'required|min:5|max:255',
        'phone'          => 'phone|max:20',
        'name'           => 'max:100',
        'city'           => 'max:50',
        'notes'          => 'max:500',
    ]);

    $deliveryName  = $in['name']  ?? ($user['name']  ?? '');
    $deliveryPhone = $in['phone'] ?? ($user['phone'] ?? '');

    if (trim((string) $deliveryPhone) === '') {
        json_error('A contact phone is required for delivery.', 422, [
            'phone' => 'Enter a phone number the rider can call.',
        ]);
    }
    if (trim((string) $deliveryName) === '') {
        json_error('A delivery name is required.', 422, [
            'name' => 'Enter the name for this delivery.',
        ]);
    }

    $pdo = db();
    $pdo->beginTransaction();

    try {
        // FOR UPDATE locks the product rows for the life of the transaction, so
        // a concurrent checkout of the same item waits instead of overselling.
        $stmt = $pdo->prepare(
            'SELECT c.product_id, c.quantity, p.name, p.price, p.stock, p.status,
                    p.pharmacy_id
               FROM cart c
               JOIN pharmacy_products p ON p.id = c.product_id
              WHERE c.user_id = ?
              FOR UPDATE'
        );
        $stmt->execute([$user['id']]);
        $rows = $stmt->fetchAll();

        if (empty($rows)) {
            $pdo->rollBack();
            json_error('Your cart is empty.', 422);
        }

        // Re-validate every line against the freshly locked stock.
        $errors   = [];
        $subtotal = 0.0;

        foreach ($rows as $r) {
            if ($r['status'] !== 'active') {
                $errors['product_' . $r['product_id']] = $r['name'] . ' is no longer available.';
                continue;
            }
            if ((int) $r['quantity'] > (int) $r['stock']) {
                $errors['product_' . $r['product_id']] =
                    $r['name'] . ': only ' . (int) $r['stock'] . ' left in stock.';
                continue;
            }
            $subtotal += (float) $r['price'] * (int) $r['quantity'];
        }

        if (!empty($errors)) {
            $pdo->rollBack();
            json_error('Some items are no longer available at the requested quantity.', 409, $errors);
        }

        $deliveryFee = ($subtotal > 0 && $subtotal < 500) ? 60.0 : 0.0;
        $total       = round($subtotal + $deliveryFee, 2);

        // An order belongs to one pharmacy. The cart can in principle hold items
        // from several, so the order records the first one rather than pretending
        // a single vendor; order_items keeps the true per-line products either
        // way. A per-pharmacy order split would be the fuller answer and is worth
        // doing if multi-vendor carts become common.
        $pharmacyId = null;
        foreach ($rows as $r) {
            if ($r['pharmacy_id'] !== null) {
                $pharmacyId = (int) $r['pharmacy_id'];
                break;
            }
        }

        // Insert the order, then derive the human-readable number from its id.
        // payment_status starts 'pending' — the enum is pending|paid|refunded and
        // has no 'unpaid'. Nothing here marks an order paid; that is a human
        // decision made in the admin panel, exactly as with appointments.
        $pdo->prepare(
            'INSERT INTO orders (user_id, pharmacy_id, order_number, subtotal,
                                 delivery_fee, total, payment_method, payment_status,
                                 status, delivery_name, delivery_phone,
                                 delivery_address, delivery_city, notes)
             VALUES (?, ?, ?, ?, ?, ?, ?, "pending", "pending", ?, ?, ?, ?, ?)'
        )->execute([
            $user['id'],
            $pharmacyId,
            'TMP-' . bin2hex(random_bytes(6)),   // replaced immediately below
            round($subtotal, 2),
            $deliveryFee,
            $total,
            $in['payment_method'],
            $deliveryName,
            $deliveryPhone,
            $in['address'],
            $in['city'] ?? null,
            $in['notes'] ?? null,
        ]);
        $orderId     = (int) $pdo->lastInsertId();
        $orderNumber = 'AYU-' . str_pad((string) $orderId, 6, '0', STR_PAD_LEFT);

        $pdo->prepare('UPDATE orders SET order_number = ? WHERE id = ?')
            ->execute([$orderNumber, $orderId]);

        // product_name and line_total are copied, not joined: an order is a
        // historical record and must not change if the product is later renamed,
        // repriced, or deleted.
        $itemStmt  = $pdo->prepare(
            'INSERT INTO order_items
                (order_id, product_id, product_name, unit_price, quantity, line_total)
             VALUES (?, ?, ?, ?, ?, ?)'
        );
        // Guarded decrement: the WHERE clause makes overselling impossible even
        // if the lock above were somehow bypassed.
        $stockStmt = $pdo->prepare(
            'UPDATE pharmacy_products SET stock = stock - ?
              WHERE id = ? AND stock >= ?'
        );

        foreach ($rows as $r) {
            $itemStmt->execute([
                $orderId,
                (int) $r['product_id'],
                $r['name'],
                (float) $r['price'],
                (int) $r['quantity'],
                round((float) $r['price'] * (int) $r['quantity'], 2),
            ]);

            $stockStmt->execute([
                (int) $r['quantity'],
                (int) $r['product_id'],
                (int) $r['quantity'],
            ]);

            if ($stockStmt->rowCount() === 0) {
                throw new RuntimeException('Stock changed during checkout for product ' . $r['product_id']);
            }
        }

        $pdo->prepare('DELETE FROM cart WHERE user_id = ?')->execute([$user['id']]);

        $pdo->prepare(
            'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
             VALUES (?, ?, ?, "order", "/pharmacy/orders", ?)'
        )->execute([
            $user['id'],
            'Order placed',
            'Order ' . $orderNumber . ' has been received and is being processed.',
            $orderId,
        ]);

        $pdo->commit();
    } catch (RuntimeException $e) {
        $pdo->rollBack();
        json_error('Stock changed while placing your order. Please review your cart.', 409);
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }

    audit((int) $user['id'], 'checkout', 'orders', $orderId, [
        'total'  => $total,
        'method' => $in['payment_method'],
    ]);

    json_ok(
        ['order' => order_detail_payload($orderId, (int) $user['id'], true)],
        'Order placed successfully.',
        null,
        201
    );
}

/**
 * @return array<string,mixed>
 */
function order_detail_payload(int $orderId, int $userId, bool $bypassOwnerCheck = false): array
{
    $stmt = db()->prepare('SELECT * FROM orders WHERE id = ? LIMIT 1');
    $stmt->execute([$orderId]);
    $order = $stmt->fetch();

    if (!$order) {
        json_error('Order not found.', 404);
    }
    if (!$bypassOwnerCheck && (int) $order['user_id'] !== $userId) {
        json_error('You cannot view this order.', 403);
    }

    // LEFT JOIN, not JOIN. order_items.product_id is ON DELETE SET NULL, so a
    // discontinued product leaves the line intact with a null product_id — an
    // inner join would make that line vanish and the order would no longer add up
    // to its own total. The stored product_name is authoritative; the joined name
    // is only used to prefer the current spelling when the product still exists.
    $is = db()->prepare(
        'SELECT oi.*, p.name AS current_name, p.unit, p.image, p.category
           FROM order_items oi
           LEFT JOIN pharmacy_products p ON p.id = oi.product_id
          WHERE oi.order_id = ?
          ORDER BY oi.id ASC'
    );
    $is->execute([$orderId]);

    $items = array_map(static fn($r) => [
        'product_id' => $r['product_id'] === null ? null : (int) $r['product_id'],
        'name'       => $r['current_name'] ?? $r['product_name'],
        'unit'       => $r['unit'],
        'image'      => $r['image'],
        'category'   => $r['category'],
        'quantity'   => (int) $r['quantity'],
        'unit_price' => (float) $r['unit_price'],
        // Stored at checkout, not recomputed — the order must not change if the
        // product is repriced later.
        'line_total' => (float) $r['line_total'],
    ], $is->fetchAll());

    return [
        'id'             => (int) $order['id'],
        'order_number'   => $order['order_number'],
        'subtotal'       => (float) $order['subtotal'],
        'delivery_fee'   => (float) $order['delivery_fee'],
        'total'          => (float) $order['total'],
        // `total_amount` is a compatibility alias for the Dart model's existing
        // key. The column is `total`.
        'total_amount'   => (float) $order['total'],
        'payment_method' => $order['payment_method'],
        'payment_status' => $order['payment_status'],
        'status'         => $order['status'],
        'address'        => $order['delivery_address'],
        'delivery_name'  => $order['delivery_name'],
        'delivery_phone' => $order['delivery_phone'],
        'delivery_city'  => $order['delivery_city'],
        'notes'          => $order['notes'],
        'created_at'     => $order['created_at'],
        'items'          => $items,
        'item_count'     => count($items),
    ];
}

/** GET /pharmacy/orders */
function pharmacy_orders(): void
{
    $user = require_auth();
    [$page, $limit, $offset] = paging();

    $where  = ['o.user_id = ?'];
    $params = [$user['id']];

    if ($status = q('status')) {
        // Whitelisted: an unrecognised value would otherwise return an empty list
        // that looks like "no orders" rather than a bad filter.
        $allowed = ['pending', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled'];
        if (!in_array($status, $allowed, true)) {
            json_error('Invalid status filter.', 400, [
                'status' => 'Must be one of: ' . implode(', ', $allowed),
            ]);
        }
        $where[]  = 'o.status = ?';
        $params[] = $status;
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM orders o $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    $stmt = db()->prepare(
        "SELECT o.*,
                (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = o.id) AS item_count
           FROM orders o
         $whereSql
         ORDER BY o.created_at DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $orders = array_map(static fn($r) => [
        'id'             => (int) $r['id'],
        'order_number'   => $r['order_number'],
        'subtotal'       => (float) $r['subtotal'],
        'delivery_fee'   => (float) $r['delivery_fee'],
        'total'          => (float) $r['total'],
        'total_amount'   => (float) $r['total'],   // compatibility alias
        'payment_method' => $r['payment_method'],
        'payment_status' => $r['payment_status'],
        'status'         => $r['status'],
        'address'        => $r['delivery_address'],
        'created_at'     => $r['created_at'],
        'item_count'     => (int) $r['item_count'],
    ], $stmt->fetchAll());

    json_ok(['orders' => $orders], 'OK', meta_page($page, $limit, $total));
}

/** GET /pharmacy/orders/{id} */
function pharmacy_order_detail(string $id): void
{
    $user = require_auth();

    json_ok([
        'order' => order_detail_payload((int) $id, (int) $user['id'], $user['role'] === 'admin'),
    ]);
}
