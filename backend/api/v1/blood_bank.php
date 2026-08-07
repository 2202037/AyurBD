<?php
/**
 * Blood bank — §6 /blood_bank/*
 * §8: soonest-needed first, contact phone always present so the app can offer
 * one-tap call/SMS.
 *
 * THREE THINGS ABOUT THE LIVE SCHEMA THAT SHAPE THIS FILE.
 *
 * 1. Stock is stored WIDE, not tall. `blood_banks` has one row per bank with
 *    eight integer columns (blood_a_positive ... blood_o_negative). The app
 *    wants one row per (bank, group), so this file unpivots with UNION ALL.
 *    The database is not reshaped; the transformation is read-only.
 *
 * 2. There are no coordinates anywhere. `blood_banks` has city and address but
 *    no latitude/longitude, so /blood_bank/nearby cannot do distance. It is a
 *    city filter that returns the same shape, minus distance_km.
 *
 * 3. `blood_requests` has NO requester_id. The requester is captured as free
 *    text (requester_name, requester_phone) with no FK to users, so a request
 *    cannot be reliably tied back to an account — see blood_request_list().
 */

declare(strict_types=1);

const BLOOD_GROUPS = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

/**
 * Maps each blood group to its column on `blood_banks`, plus a stable index used
 * to build a unique synthetic row id. Order matches BLOOD_GROUPS.
 *
 * @return array<string,array{0:string,1:int}>
 */
function blood_group_columns(): array
{
    return [
        'A+'  => ['blood_a_positive',  1],
        'A-'  => ['blood_a_negative',  2],
        'B+'  => ['blood_b_positive',  3],
        'B-'  => ['blood_b_negative',  4],
        'AB+' => ['blood_ab_positive', 5],
        'AB-' => ['blood_ab_negative', 6],
        'O+'  => ['blood_o_positive',  7],
        'O-'  => ['blood_o_negative',  8],
    ];
}

/**
 * Builds the UNION ALL that turns one wide bank row into eight tall stock rows.
 *
 * The group list is filtered in PHP against blood_group_columns(), so the column
 * names interpolated below always come from that fixed internal map and never
 * from user input.
 *
 * `id` is synthetic: bank_id * 10 + group_index. The app uses it only as a list
 * key, and it stays stable across requests. It is NOT a database primary key and
 * must never be sent back as one.
 *
 * @param string[] $groups
 */
function blood_stock_union_sql(array $groups): string
{
    $map   = blood_group_columns();
    $parts = [];

    foreach ($groups as $g) {
        [$col, $idx] = $map[$g];
        $parts[] = "SELECT (b.id * 10 + $idx) AS id, b.id AS bank_id, b.name AS bank_name,
                           b.address, b.city, b.phone, b.email,
                           '$g' AS blood_group, b.$col AS units_available,
                           b.status, b.updated_at
                      FROM blood_banks b
                     WHERE b.status = 'active'";
    }

    return implode("\n UNION ALL \n", $parts);
}

/**
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function blood_stock_public(array $r): array
{
    $units = (int) $r['units_available'];

    return [
        'id'              => (int) $r['id'],
        'bank_id'         => (int) $r['bank_id'],
        'hospital_id'     => null,   // banks are their own table; no FK to hospitals
        'hospital_name'   => $r['bank_name'],
        'blood_group'     => $r['blood_group'],
        'units_available' => $units,
        // One free-text location for the card. The table does split address and
        // city, but the app renders a single line, so they are joined here.
        'location'        => trim(($r['address'] ?? '') . ', ' . ($r['city'] ?? ''), ', '),
        'city'            => $r['city'] ?? null,
        'contact_phone'   => $r['phone'] ?? null,
        // Derived, not stored: `blood_banks` has a bank-level active/inactive
        // status but no per-group flag. 'low' at 1-4 units is this API's
        // convention so the pill can warn before stock hits zero.
        'status'          => $units <= 0 ? 'unavailable' : ($units < 5 ? 'low' : 'available'),
        'latitude'        => null,
        'longitude'       => null,
        'updated_at'      => $r['updated_at'] ?? null,
    ];
}

/**
 * Shared list body for /inventory and /nearby.
 *
 * @param string|null $city when set, restricts to one city (the /nearby case)
 */
function blood_stock_list_body(?string $city): void
{
    [$page, $limit, $offset] = paging();

    $groups = BLOOD_GROUPS;
    if ($group = q('blood_group')) {
        if (!in_array($group, BLOOD_GROUPS, true)) {
            json_error('Invalid blood group.', 400, [
                'blood_group' => 'Must be one of: ' . implode(', ', BLOOD_GROUPS),
            ]);
        }
        $groups = [$group];
    }

    $union  = blood_stock_union_sql($groups);
    $where  = [];
    $params = [];

    if ($loc = ($city ?? q('location'))) {
        $where[]  = '(t.city LIKE ? OR t.bank_name LIKE ? OR t.address LIKE ?)';
        $like     = '%' . $loc . '%';
        $params[] = $like;
        $params[] = $like;
        $params[] = $like;
    }
    if (q('available_only') === '1') {
        $where[] = 't.units_available > 0';
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM ($union) AS t $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    $stmt = db()->prepare(
        "SELECT t.* FROM ($union) AS t
         $whereSql
         ORDER BY t.units_available DESC, t.bank_name ASC, t.blood_group ASC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['inventory' => array_map('blood_stock_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/** GET /blood_bank/inventory?blood_group&location&available_only */
function blood_inventory_list(): void
{
    blood_stock_list_body(null);
}

/**
 * GET /blood_bank/nearby?city&blood_group — §6 NEW
 *
 * NOT distance-based, and the response says so. `blood_banks` stores no
 * coordinates, so there is nothing to measure from; sorting by a fabricated
 * distance would be worse than admitting there is none. This filters by city,
 * which is the granularity the data actually supports.
 */
function blood_nearby(): void
{
    $city = q('city') ?? q('location');
    if ($city === null || trim($city) === '') {
        json_error('A city is required.', 400, [
            'city' => 'Enter a city to see blood banks there.',
        ]);
    }

    blood_stock_list_body(trim($city));
}

/** GET /blood_bank/donors?blood_group&city — registered volunteer donors. */
function blood_donors_list(): void
{
    [$page, $limit, $offset] = paging();

    // Only donors who have said they are available. A donor who opted out is not
    // shown at all, rather than shown greyed out.
    $where  = ['d.is_available = 1'];
    $params = [];

    if ($group = q('blood_group')) {
        if (!in_array($group, BLOOD_GROUPS, true)) {
            json_error('Invalid blood group.', 400, ['blood_group' => 'Unknown group.']);
        }
        $where[]  = 'd.blood_group = ?';
        $params[] = $group;
    }
    if ($city = q('city')) {
        $where[]  = '(d.city LIKE ? OR d.area LIKE ?)';
        $params[] = '%' . $city . '%';
        $params[] = '%' . $city . '%';
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM blood_donors d $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    $stmt = db()->prepare(
        "SELECT d.* FROM blood_donors d
         $whereSql
         ORDER BY d.last_donation_date IS NULL DESC, d.last_donation_date ASC, d.id DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn($d) => [
        'id'                 => (int) $d['id'],
        'name'               => $d['name'],
        'blood_group'        => $d['blood_group'],
        'phone'              => $d['phone'],
        'city'               => $d['city'],
        'area'               => $d['area'] ?? null,
        'last_donation_date' => $d['last_donation_date'],
        'is_available'       => (bool) $d['is_available'],
    ], $stmt->fetchAll());

    json_ok(['donors' => $rows], 'OK', meta_page($page, $limit, $total));
}

/**
 * POST /blood_bank/donor — register the caller as a donor.
 * {name?,phone,blood_group,city,area?,last_donation_date?}
 */
function blood_donor_register(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'name'               => 'max:100',
        'phone'              => 'required|phone|max:20',
        'blood_group'        => 'required|in:' . implode(',', BLOOD_GROUPS),
        'city'               => 'required|max:50',
        'area'               => 'max:100',
        'address'            => 'max:500',
        'last_donation_date' => 'date',
    ]);

    $pdo = db();

    // One donor record per account. The table has no unique key on user_id, so
    // this is a check-then-write; re-registering updates the existing row rather
    // than stacking duplicates on the public list.
    $ex = $pdo->prepare('SELECT id FROM blood_donors WHERE user_id = ? LIMIT 1');
    $ex->execute([$user['id']]);
    $existing = $ex->fetchColumn();

    $name = $in['name'] ?? $user['name'];

    if ($existing !== false) {
        $pdo->prepare(
            'UPDATE blood_donors
                SET name = ?, phone = ?, email = ?, blood_group = ?, city = ?,
                    area = ?, address = ?, last_donation_date = ?, is_available = 1
              WHERE id = ?'
        )->execute([
            $name,
            $in['phone'],
            $user['email'] ?? null,
            $in['blood_group'],
            $in['city'],
            $in['area'] ?? null,
            $in['address'] ?? null,
            $in['last_donation_date'] ?? null,
            (int) $existing,
        ]);
        $id = (int) $existing;
    } else {
        $pdo->prepare(
            'INSERT INTO blood_donors
                (user_id, name, phone, email, blood_group, city, area, address,
                 last_donation_date, is_available)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)'
        )->execute([
            $user['id'],
            $name,
            $in['phone'],
            $user['email'] ?? null,
            $in['blood_group'],
            $in['city'],
            $in['area'] ?? null,
            $in['address'] ?? null,
            $in['last_donation_date'] ?? null,
        ]);
        $id = (int) $pdo->lastInsertId();
    }

    // No audit() call: blood_donors already has after_insert / after_update
    // triggers writing full row diffs into the site's own audit_log.

    json_ok(['donor_id' => $id], 'You are registered as a donor.', null, 201);
}

/**
 * POST /blood_bank/request
 * {patient_name,blood_group,units_needed,hospital_name,city,needed_by,reason?,
 *  requester_name?,contact_phone}
 */
function blood_request_create(): void
{
    $user = require_auth();

    // These mirror the live NOT NULL columns. patient_name, hospital_name, city
    // and needed_by are all required by the table, so they are required here too
    // rather than being discovered as a 500 at insert time.
    $in = validate(json_body(), [
        'patient_name'   => 'required|min:2|max:100',
        'blood_group'    => 'required|in:' . implode(',', BLOOD_GROUPS),
        'units_needed'   => 'required|int|min:1|max:20',
        'hospital_name'  => 'required|max:255',
        'city'           => 'required|max:50',
        'needed_by'      => 'required|date',
        'contact_phone'  => 'required|phone|max:20',
        'requester_name' => 'max:100',
        'reason'         => 'max:500',
    ]);

    // There is no urgency column on `blood_requests`. The old version of this
    // file invented one; requests are ordered by needed_by instead, which is
    // real data rather than a self-reported priority.

    $stmt = db()->prepare(
        'INSERT INTO blood_requests
            (requester_name, requester_phone, patient_name, blood_group,
             units_needed, hospital_name, city, needed_by, reason, status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, "active")'
    );
    $stmt->execute([
        $in['requester_name'] ?? $user['name'],
        $in['contact_phone'],
        $in['patient_name'],
        $in['blood_group'],
        $in['units_needed'],
        $in['hospital_name'],
        $in['city'],
        $in['needed_by'],
        $in['reason'] ?? null,
    ]);
    $id = (int) db()->lastInsertId();

    // blood_requests has an after_insert trigger that records this in audit_log.

    $fetch = db()->prepare('SELECT * FROM blood_requests WHERE id = ?');
    $fetch->execute([$id]);

    json_ok(
        ['request' => blood_request_public($fetch->fetch())],
        'Blood request submitted.',
        null,
        201
    );
}

/**
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function blood_request_public(array $r): array
{
    return [
        'id'             => (int) $r['id'],
        'requester_id'   => null,   // no such column; requester is free text
        'requester_name' => $r['requester_name'],
        'patient_name'   => $r['patient_name'],
        'blood_group'    => $r['blood_group'],
        'units_needed'   => (int) $r['units_needed'],
        'hospital_name'  => $r['hospital_name'],
        'city'           => $r['city'],
        'contact_phone'  => $r['requester_phone'],
        // Outgoing key stays `note` for the app; the column is `reason`.
        'note'           => $r['reason'] ?? null,
        'reason'         => $r['reason'] ?? null,
        'status'         => $r['status'],   // active | fulfilled | cancelled
        'needed_by'      => $r['needed_by'],
        'created_at'     => $r['created_at'],
    ];
}

/**
 * GET /blood_bank/requests?mine=1&blood_group&city&status
 * Public board by default.
 */
function blood_request_list(): void
{
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if (q('mine') === '1') {
        $user = require_auth();

        // `mine` IS APPROXIMATE, and deliberately narrow. `blood_requests` has no
        // requester_id, so the only thing linking a row to an account is the
        // phone number typed into the form. Matching on name would be far looser
        // and could expose a stranger's request to anyone sharing their name.
        //
        // A user with no phone on file therefore sees an empty list rather than
        // a guess. If "my requests" needs to be exact, the fix is a requester_id
        // column on blood_requests, which the website's form would have to fill.
        $phone = trim((string) ($user['phone'] ?? ''));
        if ($phone === '') {
            json_ok(['requests' => []], 'OK', meta_page($page, $limit, 0));
        }
        $where[]  = 'br.requester_phone = ?';
        $params[] = $phone;
    } else {
        // Public board shows only live requests. The enum is
        // active|fulfilled|cancelled — there is no 'open'.
        $where[] = "br.status = 'active'";
    }

    if ($group = q('blood_group')) {
        if (!in_array($group, BLOOD_GROUPS, true)) {
            json_error('Invalid blood group.', 400, ['blood_group' => 'Unknown group.']);
        }
        $where[]  = 'br.blood_group = ?';
        $params[] = $group;
    }
    if ($city = q('city')) {
        $where[]  = 'br.city LIKE ?';
        $params[] = '%' . $city . '%';
    }
    if ($status = q('status')) {
        if (!in_array($status, ['active', 'fulfilled', 'cancelled'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'br.status = ?';
        $params[] = $status;
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $cs = db()->prepare("SELECT COUNT(*) FROM blood_requests br $whereSql");
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    // Soonest needed first — the honest stand-in for the urgency field the table
    // does not have. Past-dated requests sort last, not first.
    $stmt = db()->prepare(
        "SELECT br.* FROM blood_requests br
         $whereSql
         ORDER BY (br.needed_by < CURDATE()) ASC, br.needed_by ASC, br.created_at DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['requests' => array_map('blood_request_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}
