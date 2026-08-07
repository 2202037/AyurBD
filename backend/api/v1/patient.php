<?php
/**
 * Patient endpoints — feature.md §5.1 (dashboard), §5.6 (my reviews) and
 * §5.9 (emergency assistance).
 *
 * The rest of the patient journey already exists: booking and payment live in
 * appointments.php, review submission and feedback in content.php, search and
 * discovery in directory.php.
 */

declare(strict_types=1);

// =====================================================================
// §5.1 Patient dashboard
// =====================================================================

/**
 * GET /patient/dashboard
 *
 * feature.md §5.1: appointment totals by status, upcoming appointments and
 * recent reviews. The quick-action buttons are a UI concern and live in the
 * Flutter screen, not here.
 */
function patient_dashboard(): void
{
    $user = require_auth();
    $uid  = (int) $user['id'];

    $stmt = db()->prepare(
        'SELECT status, COUNT(*) AS n FROM appointments WHERE patient_id = ? GROUP BY status'
    );
    $stmt->execute([$uid]);

    $byStatus = ['pending' => 0, 'confirmed' => 0, 'completed' => 0, 'cancelled' => 0];
    $total    = 0;
    foreach ($stmt->fetchAll() as $r) {
        $byStatus[$r['status']] = (int) $r['n'];
        $total += (int) $r['n'];
    }

    // "Upcoming" means still to happen AND not cancelled. A cancelled future
    // appointment is not something the patient needs to prepare for.
    $upcoming = db()->prepare(
        appointment_select_sql() .
        " WHERE a.patient_id = ? AND a.appointment_date >= CURDATE()
            AND a.status IN ('pending','confirmed')
          ORDER BY a.appointment_date ASC, a.appointment_time ASC LIMIT 5"
    );
    $upcoming->execute([$uid]);

    $reviews = db()->prepare(
        'SELECT r.* FROM reviews r WHERE r.user_id = ? ORDER BY r.id DESC LIMIT 5'
    );
    $reviews->execute([$uid]);

    $unpaid = db()->prepare(
        "SELECT COUNT(*) FROM appointments
          WHERE patient_id = ? AND payment_status = 'pending' AND status <> 'cancelled'"
    );
    $unpaid->execute([$uid]);

    $unread = db()->prepare(
        'SELECT COUNT(*) FROM notifications WHERE user_id = ? AND is_read = 0'
    );
    $unread->execute([$uid]);

    json_ok([
        'stats' => [
            'total_appointments'     => $total,
            'pending_appointments'   => $byStatus['pending'],
            'confirmed_appointments' => $byStatus['confirmed'],
            'completed_appointments' => $byStatus['completed'],
            'cancelled_appointments' => $byStatus['cancelled'],
            'pending_payments'       => (int) $unpaid->fetchColumn(),
            'unread_notifications'   => (int) $unread->fetchColumn(),
        ],
        'upcoming_appointments' => array_map('appointment_public', $upcoming->fetchAll()),
        'recent_reviews'        => array_map('patient_review_public', $reviews->fetchAll()),
    ]);
}

// =====================================================================
// §5.6 My reviews
// =====================================================================

/**
 * GET /patient/reviews?page&limit
 *
 * feature.md §5.6: the patient's own reviews with status, rating, comment,
 * and a note explaining a pending or rejected state.
 */
function patient_reviews(): void
{
    $user = require_auth();
    [$page, $limit, $offset] = paging();

    $count = db()->prepare('SELECT COUNT(*) FROM reviews WHERE user_id = ?');
    $count->execute([(int) $user['id']]);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT * FROM reviews WHERE user_id = ? ORDER BY id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute([(int) $user['id']]);

    $rows = $stmt->fetchAll();

    // Resolve each target's display name. Grouped by type so this is at most
    // four queries regardless of page size, rather than one per review.
    $names = patient_review_target_names($rows);

    $items = array_map(static function (array $r) use ($names): array {
        $out = patient_review_public($r);
        $key = $r['reviewable_type'] . '#' . $r['reviewable_id'];
        $out['target_name'] = $names[$key] ?? null;

        return $out;
    }, $rows);

    json_ok(['reviews' => $items], 'OK', meta_page($page, $limit, $total));
}

/**
 * Display names for the entities a set of reviews points at.
 *
 * @param array<int,array<string,mixed>> $rows
 * @return array<string,string>  "type#id" => name
 */
function patient_review_target_names(array $rows): array
{
    $byType = [];
    foreach ($rows as $r) {
        $type = (string) $r['reviewable_type'];
        $byType[$type][] = (int) $r['reviewable_id'];
    }

    $tables = [
        'doctor'   => 'doctors',
        'clinic'   => 'clinics',
        'hospital' => 'hospitals',
        'pharmacy' => 'pharmacies',
    ];

    $names = [];
    foreach ($byType as $type => $ids) {
        $table = $tables[$type] ?? null;
        if ($table === null || empty($ids)) {
            continue;
        }

        $ids = array_values(array_unique($ids));
        $ph  = implode(',', array_fill(0, count($ids), '?'));

        // A doctor's name lives on `users`; the other three have their own.
        $sql = $table === 'doctors'
            ? "SELECT d.id, u.name FROM doctors d JOIN users u ON u.id = d.user_id WHERE d.id IN ($ph)"
            : "SELECT id, name FROM `$table` WHERE id IN ($ph)";

        $stmt = db()->prepare($sql);
        $stmt->execute($ids);

        foreach ($stmt->fetchAll() as $row) {
            $names[$type . '#' . (int) $row['id']] = (string) $row['name'];
        }
    }

    return $names;
}

/**
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function patient_review_public(array $r): array
{
    $status = (string) ($r['status'] ?? 'pending');

    // The status note feature.md §5.6 asks for. Kept server-side so the app and
    // any other client explain moderation the same way.
    $note = match ($status) {
        'pending'  => 'Waiting for admin approval before it appears publicly.',
        'rejected' => 'This review was not approved and is not shown publicly.',
        'approved' => null,
        default    => null,
    };

    return [
        'id'              => (int) $r['id'],
        'reviewable_type' => $r['reviewable_type'],
        'reviewable_id'   => (int) $r['reviewable_id'],
        'rating'          => (int) $r['rating'],
        'comment'         => $r['comment'] ?? null,
        'status'          => $status,
        'status_note'     => $note,
        'created_at'      => $r['created_at'] ?? null,
    ];
}

// =====================================================================
// §5.9 Emergency assistance
// =====================================================================

/**
 * GET /emergency/hotlines
 *
 * Seeded by migration_v2.sql. Public: someone who needs 999 should not have
 * to sign in first.
 */
function emergency_hotlines(): void
{
    try {
        $stmt = db()->query(
            "SELECT id, name, phone, category, description
               FROM emergency_hotlines
              WHERE status = 'active'
              ORDER BY sort_order ASC, id ASC"
        );
        $rows = $stmt->fetchAll();
    } catch (Throwable $e) {
        // Before migration_v2.sql the table does not exist. An empty list is a
        // better answer than a 500 on the emergency screen.
        error_log('[ayur][emergency] ' . $e->getMessage());
        $rows = [];
    }

    json_ok(['hotlines' => array_map(static fn(array $r): array => [
        'id'          => (int) $r['id'],
        'name'        => $r['name'],
        'phone'       => $r['phone'],
        'category'    => $r['category'] ?? 'general',
        'description' => $r['description'] ?? null,
    ], $rows)]);
}

/**
 * POST /emergency/sms
 *   {sender_phone, recipient_phone, message, location?, latitude?, longitude?}
 *
 * feature.md §5.9. IMPORTANT: this RECORDS the request, it does not transmit
 * it — no SMS gateway is configured in this build, and pretending otherwise
 * would be dangerous on an emergency screen. The response says so plainly and
 * the row stays `queued` for whoever wires a provider up later.
 */
function emergency_sms_send(): void
{
    $user = current_user();   // optional auth — an emergency should not need login

    // 3 per 10 minutes. Tight enough to stop a runaway loop, loose enough that
    // a panicking user can retry.
    rate_limit('emergency-sms', 3, 600);

    $in = validate(json_body(), [
        'sender_phone'    => 'required|phone',
        'recipient_phone' => 'required|phone',
        'message'         => 'required|min:3|max:1000',
        'location'        => 'max:255',
        'latitude'        => 'numeric|min:-90|max:90',
        'longitude'       => 'numeric|min:-180|max:180',
    ]);

    try {
        $id = insert_row(db(), 'emergency_sms', [
            'user_id'         => $user['id'] ?? null,
            'sender_phone'    => $in['sender_phone'],
            'recipient_phone' => $in['recipient_phone'],
            'message'         => $in['message'],
            'location'        => $in['location'] ?? null,
            'latitude'        => $in['latitude'] ?? null,
            'longitude'       => $in['longitude'] ?? null,
            'status'          => 'queued',
        ]);
    } catch (Throwable $e) {
        error_log('[ayur][emergency] ' . $e->getMessage());
        json_error(
            'The emergency request could not be recorded. Please call the hotline directly.',
            503
        );
    }

    audit($user['id'] ?? null, 'create', 'emergency_sms', $id);

    json_ok(
        ['id' => $id, 'status' => 'queued', 'delivered' => false],
        'Your emergency request was recorded. No SMS gateway is connected in this '
        . 'build, so it has NOT been sent — please also call the hotline directly.',
        null,
        201
    );
}

// =====================================================================
// §5.8 Nearby services
// =====================================================================

/**
 * GET /nearby?city&type&search&page&limit
 *
 * feature.md §5.8 "Search nearby healthcare services using location".
 *
 * This is a CITY/AREA text search, not a radius search. No table in this
 * database stores latitude or longitude (the README is explicit about it), so
 * a "2.3 km away" figure would be invented. The response carries no distance
 * field for that reason — see the same note on /blood_bank/nearby.
 */
function nearby_search(): void
{
    [$page, $limit, $offset] = paging();

    $type = q('type') ?? 'all';
    $allowed = ['all', 'doctor', 'hospital', 'clinic', 'pharmacy'];
    if (!in_array($type, $allowed, true)) {
        json_error('Invalid type.', 400, ['type' => 'Must be one of: ' . implode(', ', $allowed)]);
    }

    $city   = q('city');
    $search = q('search');

    // Each branch is a SELECT with an identical column list so they can be
    // UNIONed and paged as one result set.
    $parts  = [];
    $params = [];

    $wanted = $type === 'all' ? ['doctor', 'hospital', 'clinic', 'pharmacy'] : [$type];

    foreach ($wanted as $kind) {
        if ($kind === 'doctor') {
            $sql = "SELECT d.id, 'doctor' AS kind, u.name AS name, d.specialization AS subtitle,
                           d.chamber_address AS address, d.city, d.area, u.phone,
                           d.rating, d.total_reviews, u.profile_image AS image
                      FROM doctors d
                      JOIN users u ON u.id = d.user_id
                     WHERE d.status = 'active' AND d.verification_status = 'verified'";
            if ($city !== null) {
                $sql .= ' AND (d.city LIKE ? OR d.area LIKE ?)';
                $params[] = "%$city%";
                $params[] = "%$city%";
            }
            if ($search !== null) {
                $sql .= ' AND (u.name LIKE ? OR d.specialization LIKE ?)';
                $params[] = "%$search%";
                $params[] = "%$search%";
            }
        } else {
            $table = ['hospital' => 'hospitals', 'clinic' => 'clinics', 'pharmacy' => 'pharmacies'][$kind];
            // `$table` and `$kind` come from the fixed $allowed list above.
            $sub = $kind === 'pharmacy' ? 'pharmacy_type' : ($kind === 'clinic' ? 'clinic_type' : 'hospital_type');

            $sql = "SELECT t.id, '$kind' AS kind, t.name, t.$sub AS subtitle,
                           t.address, t.city, t.area, t.phone,
                           t.rating, t.total_reviews, NULL AS image
                      FROM `$table` t
                     WHERE t.status = 'active' AND t.verification_status = 'verified'";
            if ($city !== null) {
                $sql .= ' AND (t.city LIKE ? OR t.area LIKE ?)';
                $params[] = "%$city%";
                $params[] = "%$city%";
            }
            if ($search !== null) {
                $sql .= ' AND (t.name LIKE ? OR t.address LIKE ?)';
                $params[] = "%$search%";
                $params[] = "%$search%";
            }
        }

        $parts[] = $sql;
    }

    $union = '(' . implode(') UNION ALL (', $parts) . ')';

    $count = db()->prepare("SELECT COUNT(*) FROM ($union) AS t");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT * FROM ($union) AS t
          ORDER BY t.rating DESC, t.total_reviews DESC, t.name ASC
          LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn(array $r): array => [
        'id'            => (int) $r['id'],
        'kind'          => $r['kind'],
        'name'          => $r['name'],
        'subtitle'      => $r['subtitle'] ?? null,
        'address'       => $r['address'] ?? null,
        'city'          => $r['city'] ?? null,
        'area'          => $r['area'] ?? null,
        'phone'         => $r['phone'] ?? null,
        'rating'        => (float) ($r['rating'] ?? 0),
        'total_reviews' => (int) ($r['total_reviews'] ?? 0),
        'image'         => $r['image'] ?? null,
    ], $stmt->fetchAll());

    json_ok(['results' => $rows], 'OK', meta_page($page, $limit, $total));
}
