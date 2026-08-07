<?php
/**
 * Directory endpoints — §6 /directory/*
 *
 * All list endpoints share the same contract: optional `search`, optional
 * domain filter, plus page/limit. Payloads are joined so the app never needs a
 * follow-up request to render a list row (§6 "avoid N+1").
 *
 * NO DISTANCE SORTING. The live clinics/hospitals/pharmacies tables have no
 * latitude/longitude columns, so there is nothing to compute a distance from.
 * The Haversine helper that used to live here was removed rather than left to
 * reference columns that do not exist. Listings sort by rating, and `city` /
 * `area` are the geographic filters the real schema actually supports.
 *
 * Visibility rule for every public listing:
 *     status = 'active' AND verification_status = 'verified'
 * This mirrors the website's own moderation model — an unverified provider
 * must not become publicly visible just because a second client was added.
 */

declare(strict_types=1);

/**
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function doctor_public(array $r): array
{
    return [
        'id'               => (int) $r['id'],
        'user_id'          => isset($r['user_id']) ? (int) $r['user_id'] : null,
        'name'             => $r['doctor_name'] ?? $r['name'] ?? null,
        'email'            => $r['doctor_email'] ?? null,
        'phone'            => $r['doctor_phone'] ?? null,
        // Real column is `specialization`, exposed as `specialty` because that is
        // the key the app has always read. `qualifications` keeps the real
        // column name (plural) — it used to be flattened to a singular
        // `qualification`, which no longer matched the Dart model and arrived
        // null on every doctor.
        'specialty'        => $r['specialization'] ?? null,
        'qualifications'   => $r['qualifications'] ?? null,
        'medical_school'   => $r['medical_school'] ?? null,
        'graduation_year'  => isset($r['graduation_year']) && $r['graduation_year'] !== null
            ? (int) $r['graduation_year'] : null,
        'doctor_type'      => $r['doctor_type'] ?? null,
        'experience_years' => isset($r['experience_years']) ? (int) $r['experience_years'] : null,
        'bio'              => $r['bio'] ?? null,
        'consultation_fee' => (float) ($r['consultation_fee'] ?? 0),
        'rating'           => (float) ($r['rating'] ?? 0),
        'total_reviews'    => isset($r['total_reviews']) ? (int) $r['total_reviews'] : 0,
        'profile_image'    => $r['profile_image'] ?? null,
        // Workplace is free text in this schema — there is no clinic/hospital FK.
        'workplace'        => $r['hospital_clinic_name'] ?? null,
        'chamber_address'  => $r['chamber_address'] ?? null,
        'city'             => $r['city'] ?? null,
        'area'             => $r['area'] ?? null,
        // Availability columns are added by database/migration_v1.sql; the ??
        // defaults keep this endpoint working before the migration is run.
        'available_days'   => isset($r['available_days']) && $r['available_days'] !== null && $r['available_days'] !== ''
            ? array_values(array_filter(array_map('trim', explode(',', (string) $r['available_days']))))
            : [],
        'available_from'   => $r['available_from'] ?? null,
        'available_to'     => $r['available_to'] ?? null,
        'slot_minutes'     => isset($r['slot_minutes']) ? (int) $r['slot_minutes'] : 30,
    ];
}

/**
 * Shared shaper for clinics / hospitals / pharmacies — they render as the same
 * card in the app, so they expose the same keys.
 *
 * `hours` is synthesised from the real opening_time/closing_time pair (and
 * open_24_hours where the table has it) because the app renders one string.
 *
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function place_public(array $r): array
{
    $out = [
        'id'          => (int) $r['id'],
        'user_id'     => isset($r['user_id']) && $r['user_id'] !== null ? (int) $r['user_id'] : null,
        'name'        => $r['name'],
        'address'     => $r['address'] ?? null,
        'city'        => $r['city'] ?? null,
        'area'        => $r['area'] ?? null,
        'phone'       => $r['phone'] ?? null,
        'email'       => $r['email'] ?? null,
        'website'     => $r['website'] ?? null,
        'hours'       => place_hours($r),
        'description' => $r['description'] ?? null,
        'rating'      => (float) ($r['rating'] ?? 0),
        'total_reviews' => isset($r['total_reviews']) ? (int) $r['total_reviews'] : 0,
    ];

    // Type-specific extras, present only when the source table has them.
    // Keys on the left are what the app reads; values are the real columns.
    $extras = [
        'emergency_phone'    => 'emergency_phone',
        'beds_total'         => 'total_beds',
        'icu_beds'           => 'icu_beds',
        'is_24h'             => 'open_24_hours',
        'facilities'         => 'facilities',
        'departments'        => 'departments',
        'services'           => 'services',
        'specializations'    => 'specializations',
        'clinic_type'        => 'clinic_type',
        'hospital_type'      => 'hospital_type',
        'pharmacy_type'      => 'pharmacy_type',
        'delivery_available' => 'delivery_available',
        'delivery_radius_km' => 'delivery_radius_km',
        // Real enum('pending','verified','rejected') on all three tables. Sent
        // as-is rather than as a boolean so the app can distinguish "not checked
        // yet" from "checked and rejected". There is no `is_verified` column and
        // no `is_active` column — do not invent either.
        'verification_status' => 'verification_status',
    ];

    foreach ($extras as $key => $col) {
        if (array_key_exists($col, $r) && $r[$col] !== null) {
            $out[$key] = match ($key) {
                'is_24h', 'delivery_available' => (bool) $r[$col],
                'beds_total', 'icu_beds', 'delivery_radius_km' => (int) $r[$col],
                default => $r[$col],
            };
        }
    }

    if (isset($r['doctor_count'])) {
        $out['doctor_count'] = (int) $r['doctor_count'];
    }
    if (isset($r['product_count'])) {
        $out['product_count'] = (int) $r['product_count'];
    }

    return $out;
}

/** "10:00 AM – 8:00 PM", "Open 24 hours", or null when unset. */
function place_hours(array $r): ?string
{
    if (!empty($r['open_24_hours'])) {
        return 'Open 24 hours';
    }

    $from = $r['opening_time'] ?? null;
    $to   = $r['closing_time'] ?? null;
    if (!$from || !$to) {
        return null;
    }

    $fmt = static function (string $t): string {
        $d = DateTime::createFromFormat('H:i:s', $t) ?: DateTime::createFromFormat('H:i', $t);
        return $d ? $d->format('g:i A') : $t;
    };

    return $fmt($from) . ' – ' . $fmt($to);
}

/**
 * GET /directory/doctors?specialty&search&city&max_fee&page&limit
 * Joined: name, specialization, fee, rating, image (§6).
 */
function directory_doctors(): void
{
    [$page, $limit, $offset] = paging();

    $where  = ["d.status = 'active'", "d.verification_status = 'verified'"];
    $params = [];

    if ($specialty = q('specialty')) {
        $where[]  = 'd.specialization = ?';
        $params[] = $specialty;
    }
    if ($search = q('search')) {
        $where[]  = '(u.name LIKE ? OR d.specialization LIKE ? OR d.hospital_clinic_name LIKE ?)';
        $like     = '%' . $search . '%';
        $params[] = $like;
        $params[] = $like;
        $params[] = $like;
    }
    if ($city = q('city')) {
        $where[]  = 'd.city = ?';
        $params[] = $city;
    }
    if ($maxFee = q('max_fee')) {
        if (is_numeric($maxFee)) {
            $where[]  = 'd.consultation_fee <= ?';
            $params[] = (float) $maxFee;
        }
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    // COUNT runs on the same joins/filters so total matches the rows returned.
    $cs = db()->prepare("SELECT COUNT(*) FROM doctors d JOIN users u ON u.id = d.user_id $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    $stmt = db()->prepare(
        "SELECT d.*, u.name AS doctor_name, u.email AS doctor_email,
                u.phone AS doctor_phone, u.profile_image
           FROM doctors d
           JOIN users u ON u.id = d.user_id
         $whereSql
         ORDER BY d.rating DESC, d.id DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['doctors' => array_map('doctor_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/** GET /directory/doctors/{id} — detail + recent reviews. */
function directory_doctor_detail(string $id): void
{
    $stmt = db()->prepare(
        'SELECT d.*, u.name AS doctor_name, u.email AS doctor_email,
                u.phone AS doctor_phone, u.profile_image
           FROM doctors d
           JOIN users u ON u.id = d.user_id
          WHERE d.id = ? LIMIT 1'
    );
    $stmt->execute([(int) $id]);
    $row = $stmt->fetch();

    if (!$row) {
        json_error('Doctor not found.', 404);
    }

    // reviews is polymorphic: reviewable_type + reviewable_id, moderated via
    // status = 'approved'.
    // `r.id` and `reviewer_image` are selected because `Review.fromJson` reads
    // them. Without the id every embedded review parsed as id 0, so all ten
    // rows shared one identity — fatal if they are ever used as widget keys.
    // LEFT JOIN because `reviews.user_id` can be null once an account is
    // removed: the review still counts toward the cached rating average, so an
    // inner join hid rows while their stars stayed in the total.
    $rv = db()->prepare(
        "SELECT r.id, r.rating, r.comment, r.created_at,
                u.name AS reviewer_name, u.profile_image AS reviewer_image
           FROM reviews r LEFT JOIN users u ON u.id = r.user_id
          WHERE r.reviewable_type = 'doctor' AND r.reviewable_id = ? AND r.status = 'approved'
          ORDER BY r.created_at DESC LIMIT 10"
    );
    $rv->execute([(int) $id]);

    json_ok([
        'doctor'  => doctor_public($row),
        'reviews' => $rv->fetchAll(),
    ]);
}

/**
 * Shared list implementation for clinics / hospitals / pharmacies.
 * Table and the extra select columns are chosen from a fixed internal map —
 * never from user input.
 */
function place_list(string $table, string $key, array $extraCols = [], string $countSub = ''): void
{
    [$page, $limit, $offset] = paging();

    $where  = ["p.status = 'active'", "p.verification_status = 'verified'"];
    $params = [];

    if ($search = q('search')) {
        $where[]  = '(p.name LIKE ? OR p.address LIKE ? OR p.city LIKE ? OR p.area LIKE ?)';
        $like     = '%' . $search . '%';
        $params[] = $like;
        $params[] = $like;
        $params[] = $like;
        $params[] = $like;
    }
    if ($city = q('city')) {
        $where[]  = 'p.city = ?';
        $params[] = $city;
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM $table p $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    $cols = 'p.*' . ($extraCols ? ', ' . implode(', ', $extraCols) : '');

    $stmt = db()->prepare(
        "SELECT $cols $countSub FROM $table p
         $whereSql ORDER BY p.rating DESC, p.id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        [$key => array_map('place_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/**
 * GET /directory/clinics
 * No doctor_count subquery: `doctors` has no clinic_id in this schema, the
 * workplace is free text. Counting on a LIKE against a name would be wrong
 * often enough to be misleading, so the field is simply not sent.
 */
function directory_clinics(): void
{
    place_list('clinics', 'clinics');
}

/** GET /directory/hospitals */
function directory_hospitals(): void
{
    place_list('hospitals', 'hospitals');
}

/** GET /directory/pharmacies */
function directory_pharmacies(): void
{
    place_list(
        'pharmacies',
        'pharmacies',
        [],
        ", (SELECT COUNT(*) FROM pharmacy_products pp
             WHERE pp.pharmacy_id = p.id AND pp.status = 'active') AS product_count"
    );
}

/** Shared detail handler: place row + its products (pharmacy) + its reviews. */
function place_detail(string $table, string $key, string $reviewType, string $id): void
{
    $stmt = db()->prepare("SELECT * FROM $table WHERE id = ? LIMIT 1");
    $stmt->execute([(int) $id]);
    $row = $stmt->fetch();

    if (!$row) {
        json_error(ucfirst($reviewType) . ' not found.', 404);
    }

    $data = [$key => place_public($row)];

    // No doctor list for clinics/hospitals: see directory_clinics() above —
    // there is no FK from doctors to either table.

    if ($reviewType === 'pharmacy') {
        $ps = db()->prepare(
            "SELECT * FROM pharmacy_products
              WHERE pharmacy_id = ? AND status = 'active'
              ORDER BY name LIMIT 50"
        );
        $ps->execute([(int) $id]);
        $data['products'] = array_map('product_public', $ps->fetchAll());
    }

    // Same shape as the doctor branch above, and for the same reasons: select
    // `r.id` so rows are distinguishable, and LEFT JOIN so a review outlives
    // the account that wrote it rather than vanishing while still counted.
    $rv = db()->prepare(
        "SELECT r.id, r.rating, r.comment, r.created_at,
                u.name AS reviewer_name, u.profile_image AS reviewer_image
           FROM reviews r LEFT JOIN users u ON u.id = r.user_id
          WHERE r.reviewable_type = ? AND r.reviewable_id = ? AND r.status = 'approved'
          ORDER BY r.created_at DESC LIMIT 10"
    );
    $rv->execute([$reviewType, (int) $id]);
    $data['reviews'] = $rv->fetchAll();

    json_ok($data);
}

function directory_clinic_detail(string $id): void   { place_detail('clinics', 'clinic', 'clinic', $id); }
function directory_hospital_detail(string $id): void { place_detail('hospitals', 'hospital', 'hospital', $id); }
function directory_pharmacy_detail(string $id): void { place_detail('pharmacies', 'pharmacy', 'pharmacy', $id); }

/** GET /directory/specialties — powers the filter chips on the doctor list. */
function directory_specialties(): void
{
    $stmt = db()->query(
        "SELECT d.specialization, COUNT(*) AS doctor_count
           FROM doctors d
          WHERE d.status = 'active' AND d.verification_status = 'verified'
            AND d.specialization IS NOT NULL AND d.specialization <> ''
          GROUP BY d.specialization
          ORDER BY doctor_count DESC, d.specialization ASC"
    );

    $rows = array_map(static fn($r) => [
        'specialty'    => $r['specialization'],
        'doctor_count' => (int) $r['doctor_count'],
    ], $stmt->fetchAll());

    json_ok(['specialties' => $rows]);
}
