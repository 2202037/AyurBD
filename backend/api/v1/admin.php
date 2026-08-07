<?php
/**
 * Admin endpoints — feature.md §10.
 *
 * Every handler starts with require_role(['admin']). There is no read-only
 * admin tier in this schema, so the guard is uniform.
 *
 * A note on what feature.md calls "mostly read-only" for hospitals, clinics
 * and pharmacies (§10.4–10.6): that describes the state of the old PHP pages,
 * not a requirement. Since doctors (§10.3) get verify/reject/toggle, the same
 * moderation is provided for the other three — an admin who can verify a
 * doctor but not a hospital cannot actually run the verification-based
 * onboarding the platform is built around (§1).
 */

declare(strict_types=1);

/** Moderatable provider tables, by the {type} path segment. */
const ADMIN_PROVIDER_TABLES = [
    'doctors'    => 'doctors',
    'hospitals'  => 'hospitals',
    'clinics'    => 'clinics',
    'pharmacies' => 'pharmacies',
];

// =====================================================================
// §10.1 Dashboard
// =====================================================================

/** GET /admin/dashboard */
function admin_dashboard(): void
{
    require_role(['admin']);
    $pdo = db();

    $scalar = static function (string $sql, array $p = []) use ($pdo) {
        $s = $pdo->prepare($sql);
        $s->execute($p);

        return $s->fetchColumn();
    };

    // Counted separately from `users` because a provider row can exist for a
    // user whose role was later changed, and the directory count is the one
    // that matches what the public sees.
    $counts = [
        'total_patients'    => (int) $scalar("SELECT COUNT(*) FROM users WHERE role = 'patient'"),
        'total_users'       => (int) $scalar('SELECT COUNT(*) FROM users'),
        'total_doctors'     => (int) $scalar('SELECT COUNT(*) FROM doctors'),
        'total_hospitals'   => (int) $scalar('SELECT COUNT(*) FROM hospitals'),
        'total_clinics'     => (int) $scalar('SELECT COUNT(*) FROM clinics'),
        'total_pharmacies'  => (int) $scalar('SELECT COUNT(*) FROM pharmacies'),
        'total_blood_banks' => (int) $scalar('SELECT COUNT(*) FROM blood_banks'),
        'total_appointments' => (int) $scalar('SELECT COUNT(*) FROM appointments'),
        // Verified payments only — the same rule as the doctor dashboard.
        'total_revenue'     => (float) $scalar(
            "SELECT COALESCE(SUM(amount), 0) FROM payments WHERE payment_status = 'verified'"
        ),
    ];

    $pending = [
        'doctors'    => (int) $scalar("SELECT COUNT(*) FROM doctors WHERE verification_status = 'pending'"),
        'hospitals'  => (int) $scalar("SELECT COUNT(*) FROM hospitals WHERE verification_status = 'pending'"),
        'clinics'    => (int) $scalar("SELECT COUNT(*) FROM clinics WHERE verification_status = 'pending'"),
        'pharmacies' => (int) $scalar("SELECT COUNT(*) FROM pharmacies WHERE verification_status = 'pending'"),
    ];
    $counts['pending_verifications'] = array_sum($pending);
    $counts['pending_reviews']  = (int) $scalar("SELECT COUNT(*) FROM reviews WHERE status = 'pending'");
    $counts['pending_feedback'] = (int) $scalar("SELECT COUNT(*) FROM feedback WHERE status = 'pending'");
    $counts['pending_payments'] = (int) $scalar("SELECT COUNT(*) FROM payments WHERE payment_status = 'pending'");

    // Two audit tables exist and they mean different things — see the comment
    // in helpers/auth.php. Both are surfaced rather than silently picking one.
    $counts['audit_logs'] = (int) $scalar('SELECT COUNT(*) FROM app_audit_log');
    try {
        $counts['db_audit_logs'] = (int) $scalar('SELECT COUNT(*) FROM audit_log');
    } catch (Throwable $e) {
        // The trigger-written table is not in every dump. Absent is not an error.
        $counts['db_audit_logs'] = 0;
    }

    $recent = $pdo->query(
        'SELECT l.id, l.action, l.entity, l.entity_id, l.created_at, u.name AS user_name
           FROM app_audit_log l
           LEFT JOIN users u ON u.id = l.user_id
          ORDER BY l.id DESC LIMIT 10'
    );

    json_ok([
        'counts'                => $counts,
        'pending_verifications' => $pending,
        'recent_activity'       => $recent->fetchAll(),
    ]);
}

// =====================================================================
// §10.2 User management
// =====================================================================

/** GET /admin/users?role&search&page&limit */
function admin_users(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($role = q('role')) {
        if (!in_array($role, ['patient', 'doctor', 'clinic', 'pharmacy', 'hospital', 'admin'], true)) {
            json_error('Invalid role filter.', 400, ['role' => 'Unknown role.']);
        }
        $where[]  = 'role = ?';
        $params[] = $role;
    }
    if ($search = q('search')) {
        $where[]  = '(name LIKE ? OR email LIKE ? OR phone LIKE ?)';
        $like     = '%' . $search . '%';
        $params   = array_merge($params, [$like, $like, $like]);
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM users $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT * FROM users $whereSql ORDER BY id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['users' => array_map('user_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/**
 * POST /admin/users/delete  {user_id}
 *
 * feature.md §10.2, including "Prevent deleting the current admin account".
 *
 * CSRF is not replicated: this API authenticates with a Bearer token read
 * from secure storage, which a browser never attaches automatically, so
 * there is no cross-site request to forge. The CSRF token in the PHP site
 * defended a cookie session; a token here would be ceremony.
 */
function admin_user_delete(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), ['user_id' => 'required|int']);
    $targetId = (int) $in['user_id'];

    if ($targetId === (int) $admin['id']) {
        json_error('You cannot delete the account you are signed in with.', 422);
    }

    $stmt = db()->prepare('SELECT id, name, email, role FROM users WHERE id = ? LIMIT 1');
    $stmt->execute([$targetId]);
    $target = $stmt->fetch();

    if (!$target) {
        json_error('User not found.', 404);
    }

    // Refuse to delete the last admin — otherwise the panel locks everyone out
    // and only a direct SQL edit can recover it.
    if ($target['role'] === 'admin') {
        $others = db()->prepare("SELECT COUNT(*) FROM users WHERE role = 'admin' AND id <> ?");
        $others->execute([$targetId]);
        if ((int) $others->fetchColumn() === 0) {
            json_error('This is the only administrator account. Create another before deleting it.', 422);
        }
    }

    // Deliberately a plain DELETE, matching feature.md §10.2. Whether the
    // user's appointments and reviews go with them is decided by the foreign
    // keys already on the live database, not re-specified here — this API must
    // not impose a cascade the website does not have.
    db()->prepare('DELETE FROM users WHERE id = ?')->execute([$targetId]);

    audit((int) $admin['id'], 'delete', 'users', $targetId, [
        'email' => $target['email'],
        'role'  => $target['role'],
    ]);

    json_ok(null, 'User deleted.');
}

// =====================================================================
// §10.3–10.6 Provider moderation
// =====================================================================

/**
 * GET /admin/providers/{type}?verification&status&search&page&limit
 * {type} = doctors | hospitals | clinics | pharmacies
 */
function admin_providers(string $type): void
{
    require_role(['admin']);

    $table = ADMIN_PROVIDER_TABLES[$type] ?? null;
    if ($table === null) {
        json_error('Unknown provider type.', 404);
    }

    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($v = q('verification')) {
        if (!in_array($v, ['pending', 'verified', 'rejected'], true)) {
            json_error('Invalid verification filter.', 400, ['verification' => 'Unknown value.']);
        }
        $where[]  = 't.verification_status = ?';
        $params[] = $v;
    }
    if ($s = q('status')) {
        if (!in_array($s, ['active', 'inactive', 'pending'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown value.']);
        }
        $where[]  = 't.status = ?';
        $params[] = $s;
    }
    if ($search = q('search')) {
        $like = '%' . $search . '%';
        if ($table === 'doctors') {
            $where[] = '(u.name LIKE ? OR t.specialization LIKE ? OR t.bmdc_number LIKE ?)';
        } else {
            $where[] = '(t.name LIKE ? OR t.city LIKE ? OR t.license_number LIKE ?)';
        }
        $params = array_merge($params, [$like, $like, $like]);
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    // Doctors carry their display name on `users`; the other three have it on
    // their own row. The join is always present so the owning account's
    // contact details are available either way.
    $join = 'LEFT JOIN users u ON u.id = t.user_id';

    $count = db()->prepare("SELECT COUNT(*) FROM `$table` t $join $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $select = $table === 'doctors'
        ? 't.*, u.name AS doctor_name, u.email AS doctor_email, u.phone AS doctor_phone, u.profile_image'
        : 't.*, u.email AS owner_email, u.name AS owner_name';

    $stmt = db()->prepare(
        "SELECT $select FROM `$table` t $join $whereSql
         ORDER BY t.id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows  = $stmt->fetchAll();
    $shape = $table === 'doctors' ? 'doctor_public' : 'place_public';

    $items = array_map(static function (array $r) use ($shape): array {
        $out = $shape($r);
        // Moderation needs these regardless of what the public shaper exposes.
        $out['status']              = $r['status'] ?? null;
        $out['verification_status'] = $r['verification_status'] ?? null;
        $out['license_number']      = $r['license_number'] ?? null;
        $out['license_document']    = $r['license_document'] ?? null;
        $out['bmdc_number']         = $r['bmdc_number'] ?? null;
        $out['bmdc_certificate']    = $r['bmdc_certificate'] ?? null;
        $out['created_at']          = $r['created_at'] ?? null;

        return $out;
    }, $rows);

    json_ok([$type => $items], 'OK', meta_page($page, $limit, $total));
}

/**
 * POST /admin/providers/{type}/moderate
 *   {id, action: verify|reject|activate|deactivate}
 *
 * feature.md §10.3 for doctors, extended to the other three (see the file
 * header for why).
 */
function admin_provider_moderate(string $type): void
{
    $admin = require_role(['admin']);

    $table = ADMIN_PROVIDER_TABLES[$type] ?? null;
    if ($table === null) {
        json_error('Unknown provider type.', 404);
    }

    $in = validate(json_body(), [
        'id'     => 'required|int',
        'action' => 'required|in:verify,reject,activate,deactivate',
        'reason' => 'max:255',
    ]);

    $stmt = db()->prepare("SELECT * FROM `$table` WHERE id = ? LIMIT 1");
    $stmt->execute([(int) $in['id']]);
    $row = $stmt->fetch();

    if (!$row) {
        json_error('Record not found.', 404);
    }

    // Verifying also activates: a verified provider that stays inactive is
    // invisible to the public directory, which gates on both columns, and an
    // admin who clicked "verify" did not mean "still hidden".
    $changes = match ($in['action']) {
        'verify'     => ['verification_status' => 'verified', 'status' => 'active'],
        'reject'     => ['verification_status' => 'rejected', 'status' => 'inactive'],
        'activate'   => ['status' => 'active'],
        'deactivate' => ['status' => 'inactive'],
    };

    update_row(db(), $table, $changes, 'id', (int) $in['id']);

    // Tell the provider. Their user_id may be null in older rows.
    if (!empty($row['user_id'])) {
        $titles = [
            'verify'     => ['Account verified', 'Your account has been verified and is now listed publicly.'],
            'reject'     => ['Verification rejected', 'Your verification was not approved.'],
            'activate'   => ['Account activated', 'Your account is active again.'],
            'deactivate' => ['Account deactivated', 'Your account has been deactivated.'],
        ];
        [$title, $body] = $titles[$in['action']];
        if (!empty($in['reason'])) {
            $body .= ' Reason: ' . $in['reason'];
        }

        db()->prepare(
            'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
             VALUES (?, ?, ?, "system", "/dashboard", ?)'
        )->execute([(int) $row['user_id'], $title, $body, (int) $in['id']]);
    }

    audit((int) $admin['id'], $in['action'], $table, (int) $in['id'],
        array_filter(['reason' => $in['reason'] ?? null]));

    json_ok(null, 'Updated.');
}

// =====================================================================
// §10.7 Appointment oversight
// =====================================================================

/** GET /admin/appointments?status&date&search&page&limit */
function admin_appointments(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($status = q('status')) {
        if (!in_array($status, ['pending', 'confirmed', 'completed', 'cancelled'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'a.status = ?';
        $params[] = $status;
    }
    if ($date = q('date')) {
        $where[]  = 'a.appointment_date = ?';
        $params[] = $date;
    }
    if ($search = q('search')) {
        $where[] = '(pu.name LIKE ? OR u.name LIKE ?)';
        $like    = '%' . $search . '%';
        $params  = array_merge($params, [$like, $like]);
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    // The count has to repeat the joins because the filters reference them, and
    // they must be LEFT for the same reason `appointment_select_sql()` uses LEFT:
    // an INNER JOIN here would count a different set of rows than the list
    // returns, so `meta.total` would promise pages that come back empty.
    $count = db()->prepare(
        "SELECT COUNT(*)
           FROM appointments a
           LEFT JOIN doctors d ON d.id = a.doctor_id
           LEFT JOIN users u   ON u.id = d.user_id
           LEFT JOIN users pu  ON pu.id = a.patient_id
         $whereSql"
    );
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        appointment_select_sql() . " $whereSql
         ORDER BY a.appointment_date DESC, a.appointment_time DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['appointments' => array_map('appointment_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

// =====================================================================
// §10.8 Review moderation
// =====================================================================

/** GET /admin/reviews?status&type&page&limit */
function admin_reviews(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($status = q('status')) {
        if (!in_array($status, ['pending', 'approved', 'rejected'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'r.status = ?';
        $params[] = $status;
    }
    if ($type = q('type')) {
        if (!in_array($type, REVIEW_TARGETS, true)) {
            json_error('Invalid type filter.', 400, ['type' => 'Unknown target type.']);
        }
        $where[]  = 'r.reviewable_type = ?';
        $params[] = $type;
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM reviews r $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT r.*, u.name AS reviewer_name, u.email AS reviewer_email
           FROM reviews r
           LEFT JOIN users u ON u.id = r.user_id
         $whereSql
         ORDER BY r.id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn(array $r): array => [
        'id'              => (int) $r['id'],
        'user_id'         => isset($r['user_id']) ? (int) $r['user_id'] : null,
        'reviewable_type' => $r['reviewable_type'],
        'reviewable_id'   => (int) $r['reviewable_id'],
        'rating'          => (int) $r['rating'],
        'comment'         => $r['comment'] ?? null,
        'status'          => $r['status'],
        'created_at'      => $r['created_at'] ?? null,
        'reviewer_name'   => $r['reviewer_name'] ?? null,
        'reviewer_email'  => $r['reviewer_email'] ?? null,
    ], $stmt->fetchAll());

    json_ok(['reviews' => $rows], 'OK', meta_page($page, $limit, $total));
}

/**
 * POST /admin/reviews/moderate  {review_id, action: approve|reject|delete}
 *
 * feature.md §10.8, including "Recalculate ratings and total review counts
 * after approval". The recalculation runs after every action, not just
 * approval — un-approving or deleting an approved review has to move the
 * average back down, and only recomputing on approve would leave the cached
 * rating permanently too high.
 */
function admin_review_moderate(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), [
        'review_id' => 'required|int',
        'action'    => 'required|in:approve,reject,delete',
    ]);

    $stmt = db()->prepare('SELECT * FROM reviews WHERE id = ? LIMIT 1');
    $stmt->execute([(int) $in['review_id']]);
    $review = $stmt->fetch();

    if (!$review) {
        json_error('Review not found.', 404);
    }

    $type = (string) $review['reviewable_type'];
    $id   = (int) $review['reviewable_id'];

    if ($in['action'] === 'delete') {
        db()->prepare('DELETE FROM reviews WHERE id = ?')->execute([(int) $review['id']]);
    } else {
        db()->prepare('UPDATE reviews SET status = ? WHERE id = ?')->execute([
            $in['action'] === 'approve' ? 'approved' : 'rejected',
            (int) $review['id'],
        ]);
    }

    admin_recalculate_rating($type, $id);

    audit((int) $admin['id'], $in['action'], 'reviews', (int) $review['id'], [
        'target' => "$type#$id",
    ]);

    json_ok(null, 'Review ' . $in['action'] . 'd.');
}

/**
 * Recompute the cached rating / total_reviews on the reviewed entity from
 * APPROVED reviews only.
 *
 * The table is chosen from a fixed map, never from the argument directly.
 */
function admin_recalculate_rating(string $type, int $id): void
{
    $map = [
        'doctor'   => 'doctors',
        'clinic'   => 'clinics',
        'hospital' => 'hospitals',
        'pharmacy' => 'pharmacies',
    ];
    $table = $map[$type] ?? null;
    if ($table === null) {
        return;
    }

    // COALESCE because AVG() over zero approved reviews is NULL and `rating`
    // is NOT NULL DEFAULT 0.00.
    db()->prepare(
        "UPDATE `$table` SET
            rating = COALESCE((
                SELECT ROUND(AVG(r.rating), 2) FROM reviews r
                 WHERE r.reviewable_type = ? AND r.reviewable_id = ?
                   AND r.status = 'approved'
            ), 0),
            total_reviews = (
                SELECT COUNT(*) FROM reviews r
                 WHERE r.reviewable_type = ? AND r.reviewable_id = ?
                   AND r.status = 'approved'
            )
          WHERE id = ?"
    )->execute([$type, $id, $type, $id, $id]);
}

// =====================================================================
// §10.9 Feedback moderation
// =====================================================================

/** GET /admin/feedback?status&type&priority&page&limit */
function admin_feedback(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($status = q('status')) {
        $where[]  = 'f.status = ?';
        $params[] = $status;
    }
    if ($type = q('type')) {
        $where[]  = 'f.feedback_type = ?';
        $params[] = $type;
    }
    if (($priority = q('priority')) && table_has_column('feedback', 'priority')) {
        $where[]  = 'f.priority = ?';
        $params[] = $priority;
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM feedback f $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT f.* FROM feedback f $whereSql ORDER BY f.id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn(array $r): array => [
        'id'             => (int) $r['id'],
        'user_id'        => isset($r['user_id']) ? (int) $r['user_id'] : null,
        'name'           => $r['name'] ?? null,
        'email'          => $r['email'] ?? null,
        'phone'          => $r['phone'] ?? null,
        'feedback_type'  => $r['feedback_type'] ?? 'general',
        'subject'        => $r['subject'] ?? null,
        'message'        => $r['message'] ?? null,
        'status'         => $r['status'] ?? 'pending',
        // migration_v2.sql columns; ?? keeps this working before it is run.
        'priority'       => $r['priority'] ?? 'medium',
        'admin_response' => $r['admin_response'] ?? null,
        'responded_at'   => $r['responded_at'] ?? null,
        'created_at'     => $r['created_at'] ?? null,
    ], $stmt->fetchAll());

    json_ok(['feedback' => $rows], 'OK', meta_page($page, $limit, $total));
}

/**
 * POST /admin/feedback/update
 *   {feedback_id, status?, priority?, response?, delete?}
 *
 * feature.md §10.9: in-progress / resolve / close / delete / priority /
 * respond, all in one endpoint because the admin UI does them from one row.
 */
function admin_feedback_update(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), [
        'feedback_id' => 'required|int',
        'status'      => 'in:pending,in_progress,resolved,closed',
        'priority'    => 'in:low,medium,high,urgent',
        'response'    => 'max:2000',
        'delete'      => 'in:0,1',
    ]);

    $stmt = db()->prepare('SELECT * FROM feedback WHERE id = ? LIMIT 1');
    $stmt->execute([(int) $in['feedback_id']]);
    $row = $stmt->fetch();

    if (!$row) {
        json_error('Feedback not found.', 404);
    }

    if (($in['delete'] ?? '0') === '1') {
        db()->prepare('DELETE FROM feedback WHERE id = ?')->execute([(int) $row['id']]);
        audit((int) $admin['id'], 'delete', 'feedback', (int) $row['id']);
        json_ok(null, 'Feedback deleted.');
    }

    $changes = [
        'status'   => $in['status'] ?? null,
        'priority' => $in['priority'] ?? null,
    ];

    if (!empty($in['response'])) {
        $changes['admin_response'] = $in['response'];
        $changes['responded_by']   = (int) $admin['id'];
        $changes['responded_at']   = date('Y-m-d H:i:s');
    }

    if (empty(array_filter($changes, static fn($v) => $v !== null))) {
        json_error('No changes supplied.', 400);
    }

    // migration_v2.sql explicitly does not widen the live `status` enum. If
    // this database's enum lacks 'in_progress' or 'closed', MySQL in strict
    // mode rejects the write — report that plainly instead of letting a 500
    // through, so the fix (widen the enum) is obvious.
    try {
        update_row(db(), 'feedback', $changes, 'id', (int) $row['id']);
    } catch (PDOException $e) {
        if (in_array($e->getCode(), ['01000', '22001', 'HY000'], true)
            || str_contains($e->getMessage(), 'Data truncated')) {
            json_error(
                "This database's feedback.status column does not accept '"
                . ($in['status'] ?? '') . "'. Widen the enum in phpMyAdmin, "
                . 'or use one of the values it already allows.',
                422,
                ['status' => 'Not accepted by the database schema.']
            );
        }
        throw $e;
    }

    // Let the user know they got a reply, when they have an account to notify.
    if (!empty($in['response']) && !empty($row['user_id'])) {
        db()->prepare(
            'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
             VALUES (?, ?, ?, "system", "/feedback", ?)'
        )->execute([
            (int) $row['user_id'],
            'Response to your feedback',
            $in['response'],
            (int) $row['id'],
        ]);
    }

    audit((int) $admin['id'], 'update', 'feedback', (int) $row['id'],
        array_keys(array_filter($changes, static fn($v) => $v !== null)));

    json_ok(null, 'Feedback updated.');
}

// =====================================================================
// §10.10 Blood bank management
// =====================================================================

/** GET /admin/blood-banks?search&page&limit */
function admin_blood_banks(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($search = q('search')) {
        $where[] = '(name LIKE ? OR city LIKE ?)';
        $like    = '%' . $search . '%';
        $params  = [$like, $like];
    }
    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM blood_banks $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT * FROM blood_banks $whereSql ORDER BY id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['blood_banks' => array_map('admin_blood_bank_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/**
 * The wide bank row, with the eight stock columns as a nested map so the
 * client does not have to know the column naming.
 *
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function admin_blood_bank_public(array $r): array
{
    $stock = [];
    foreach (blood_group_columns() as $group => [$col]) {
        $stock[$group] = (int) ($r[$col] ?? 0);
    }

    return [
        'id'         => (int) $r['id'],
        'name'       => $r['name'],
        'address'    => $r['address'] ?? null,
        'city'       => $r['city'] ?? null,
        'phone'      => $r['phone'] ?? null,
        'email'      => $r['email'] ?? null,
        'status'     => $r['status'] ?? 'active',
        'stock'      => $stock,
        'total_units' => array_sum($stock),
        'updated_at' => $r['updated_at'] ?? null,
    ];
}

/**
 * POST /admin/blood-banks/save  {id?, name, ...,  stock:{"A+":n,...}}
 *
 * Create when `id` is absent, update when present — feature.md §10.10 "Add"
 * and "Edit" are the same form.
 */
function admin_blood_bank_save(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), [
        'id'      => 'int',
        'name'    => 'required|min:2|max:200',
        'address' => 'max:255',
        'city'    => 'max:100',
        'phone'   => 'phone',
        'email'   => 'email|max:190',
        'status'  => 'in:active,inactive',
    ]);

    $body  = json_body();
    $stock = is_array($body['stock'] ?? null) ? $body['stock'] : [];

    $fields = [
        'name'    => $in['name'],
        'address' => $in['address'] ?? null,
        'city'    => $in['city'] ?? null,
        'phone'   => $in['phone'] ?? null,
        'email'   => $in['email'] ?? null,
        'status'  => $in['status'] ?? 'active',
    ];

    // Stock keys are matched against the fixed group map, so an unexpected key
    // in the request can never reach the SQL as a column name.
    foreach (blood_group_columns() as $group => [$col]) {
        if (array_key_exists($group, $stock)) {
            $units = filter_var($stock[$group], FILTER_VALIDATE_INT);
            if ($units === false || $units < 0) {
                json_error("Stock for $group must be a whole number of units, zero or more.", 400, [
                    'stock' => "Invalid value for $group.",
                ]);
            }
            $fields[$col] = $units;
        }
    }

    $pdo = db();

    if (!empty($in['id'])) {
        $exists = $pdo->prepare('SELECT id FROM blood_banks WHERE id = ? LIMIT 1');
        $exists->execute([(int) $in['id']]);
        if (!$exists->fetch()) {
            json_error('Blood bank not found.', 404);
        }

        update_row($pdo, 'blood_banks', $fields, 'id', (int) $in['id']);
        $id = (int) $in['id'];
        audit((int) $admin['id'], 'update', 'blood_banks', $id);
    } else {
        $id = insert_row($pdo, 'blood_banks', $fields);
        audit((int) $admin['id'], 'create', 'blood_banks', $id);
    }

    $fetch = $pdo->prepare('SELECT * FROM blood_banks WHERE id = ?');
    $fetch->execute([$id]);

    json_ok(
        ['blood_bank' => admin_blood_bank_public($fetch->fetch())],
        empty($in['id']) ? 'Blood bank added.' : 'Blood bank updated.',
        null,
        empty($in['id']) ? 201 : 200
    );
}

/** POST /admin/blood-banks/delete  {id} */
function admin_blood_bank_delete(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), ['id' => 'required|int']);

    $stmt = db()->prepare('SELECT id FROM blood_banks WHERE id = ? LIMIT 1');
    $stmt->execute([(int) $in['id']]);
    if (!$stmt->fetch()) {
        json_error('Blood bank not found.', 404);
    }

    db()->prepare('DELETE FROM blood_banks WHERE id = ?')->execute([(int) $in['id']]);
    audit((int) $admin['id'], 'delete', 'blood_banks', (int) $in['id']);

    json_ok(null, 'Blood bank deleted.');
}

// =====================================================================
// §10.11 Blog management
// =====================================================================

/** GET /admin/blogs?search&status&page&limit */
function admin_blogs(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($search = q('search')) {
        $where[] = '(title LIKE ? OR category LIKE ?)';
        $like    = '%' . $search . '%';
        $params  = [$like, $like];
    }
    if (($status = q('status')) && table_has_column('blogs', 'status')) {
        $where[]  = 'status = ?';
        $params[] = $status;
    }
    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM blogs $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT * FROM blogs $whereSql ORDER BY id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn(array $r): array => [
        'id'         => (int) $r['id'],
        'title'      => $r['title'],
        'slug'       => $r['slug'] ?? null,
        'excerpt'    => $r['excerpt'] ?? null,
        'content'    => $r['content'] ?? null,
        'category'   => $r['category'] ?? null,
        'image'      => $r['image'] ?? null,
        'status'     => $r['status'] ?? 'published',
        'created_at' => $r['created_at'] ?? null,
    ], $stmt->fetchAll());

    json_ok(['blogs' => $rows], 'OK', meta_page($page, $limit, $total));
}

/**
 * POST /admin/blogs/save  {id?, title, content, ...}
 *
 * feature.md §10.11 describes the old page as read-only. Write support is
 * added here for the same reason as provider moderation: a blog module that
 * cannot publish is not a module. Reading stays exactly as it was.
 */
function admin_blog_save(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), [
        'id'       => 'int',
        'title'    => 'required|min:3|max:200',
        'slug'     => 'max:200',
        'excerpt'  => 'max:500',
        'content'  => 'required|min:10',
        'category' => 'max:100',
        'image'    => 'max:255',
        'status'   => 'in:draft,published,archived',
    ]);

    $slug = $in['slug'] ?? null;
    if ($slug === null || $slug === '') {
        $slug = admin_slugify($in['title']);
    } else {
        $slug = admin_slugify($slug);
    }

    $pdo = db();

    // `blogs.slug` is the public URL key and is unique. Suffix until free,
    // excluding the row being edited.
    $base = $slug;
    $n    = 1;
    while (true) {
        $check = $pdo->prepare('SELECT id FROM blogs WHERE slug = ? AND id <> ? LIMIT 1');
        $check->execute([$slug, (int) ($in['id'] ?? 0)]);
        if (!$check->fetch()) {
            break;
        }
        $slug = $base . '-' . (++$n);
    }

    $fields = [
        'title'    => $in['title'],
        'slug'     => $slug,
        'excerpt'  => $in['excerpt'] ?? null,
        'content'  => $in['content'],
        'category' => $in['category'] ?? null,
        'image'    => $in['image'] ?? null,
        'status'   => $in['status'] ?? 'published',
    ];

    if (!empty($in['id'])) {
        $exists = $pdo->prepare('SELECT id FROM blogs WHERE id = ? LIMIT 1');
        $exists->execute([(int) $in['id']]);
        if (!$exists->fetch()) {
            json_error('Article not found.', 404);
        }
        update_row($pdo, 'blogs', $fields, 'id', (int) $in['id']);
        $id = (int) $in['id'];
        audit((int) $admin['id'], 'update', 'blogs', $id);
    } else {
        $fields['author_id'] = (int) $admin['id'];
        $id = insert_row($pdo, 'blogs', $fields);
        audit((int) $admin['id'], 'create', 'blogs', $id);
    }

    json_ok(['id' => $id, 'slug' => $slug],
        empty($in['id']) ? 'Article created.' : 'Article updated.',
        null,
        empty($in['id']) ? 201 : 200);
}

/** POST /admin/blogs/delete  {id} */
function admin_blog_delete(): void
{
    $admin = require_role(['admin']);

    $in = validate(json_body(), ['id' => 'required|int']);

    $stmt = db()->prepare('SELECT id FROM blogs WHERE id = ? LIMIT 1');
    $stmt->execute([(int) $in['id']]);
    if (!$stmt->fetch()) {
        json_error('Article not found.', 404);
    }

    db()->prepare('DELETE FROM blogs WHERE id = ?')->execute([(int) $in['id']]);
    audit((int) $admin['id'], 'delete', 'blogs', (int) $in['id']);

    json_ok(null, 'Article deleted.');
}

/** URL-safe slug. Transliteration is not attempted — Bangla titles fall back
 *  to the id-suffixed form rather than producing an empty slug. */
function admin_slugify(string $text): string
{
    $slug = strtolower(trim($text));
    $slug = preg_replace('/[^a-z0-9]+/u', '-', $slug) ?? '';
    $slug = trim($slug, '-');

    return $slug === '' ? 'post-' . time() : substr($slug, 0, 190);
}

// =====================================================================
// §10.12 Audit log
// =====================================================================

/**
 * GET /admin/audit-log?entity&action&date_from&date_to&search&page&limit
 *
 * Reads app_audit_log — the app's own events. The website's trigger-written
 * `audit_log` is a different table with a different shape (row diffs, not
 * actions); mixing them into one feed would misrepresent both.
 */
function admin_audit_log(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($entity = q('entity')) {
        $where[]  = 'l.entity = ?';
        $params[] = $entity;
    }
    if ($action = q('action')) {
        $where[]  = 'l.action = ?';
        $params[] = $action;
    }
    if ($from = q('date_from')) {
        $where[]  = 'DATE(l.created_at) >= ?';
        $params[] = $from;
    }
    if ($to = q('date_to')) {
        $where[]  = 'DATE(l.created_at) <= ?';
        $params[] = $to;
    }
    if ($search = q('search')) {
        $where[] = '(u.name LIKE ? OR u.email LIKE ? OR l.details LIKE ?)';
        $like    = '%' . $search . '%';
        $params  = array_merge($params, [$like, $like, $like]);
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare(
        "SELECT COUNT(*) FROM app_audit_log l LEFT JOIN users u ON u.id = l.user_id $whereSql"
    );
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT l.*, u.name AS user_name, u.email AS user_email, u.role AS user_role
           FROM app_audit_log l
           LEFT JOIN users u ON u.id = l.user_id
         $whereSql
         ORDER BY l.id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn(array $r): array => [
        'id'         => (int) $r['id'],
        'user_id'    => isset($r['user_id']) ? (int) $r['user_id'] : null,
        'user_name'  => $r['user_name'] ?? null,
        'user_email' => $r['user_email'] ?? null,
        'user_role'  => $r['user_role'] ?? null,
        'action'     => $r['action'],
        'entity'     => $r['entity'],
        'entity_id'  => isset($r['entity_id']) ? (int) $r['entity_id'] : null,
        'details'    => $r['details'] ?? null,
        'ip_address' => $r['ip_address'] ?? null,
        'created_at' => $r['created_at'] ?? null,
    ], $stmt->fetchAll());

    // §10.12 summary counts, over the WHOLE log rather than the current page —
    // a per-page summary would change every time you paged, which is useless.
    $summary = db()->query(
        "SELECT
            SUM(action = 'create') AS inserts,
            SUM(action = 'update') AS updates,
            SUM(action = 'delete') AS deletes,
            COUNT(DISTINCT entity) AS tracked_entities,
            MAX(created_at)        AS latest_activity
           FROM app_audit_log"
    )->fetch() ?: [];

    // Populates the filter dropdowns without a second request.
    $entities = db()->query('SELECT DISTINCT entity FROM app_audit_log ORDER BY entity')
        ->fetchAll(PDO::FETCH_COLUMN);
    $actions = db()->query('SELECT DISTINCT action FROM app_audit_log ORDER BY action')
        ->fetchAll(PDO::FETCH_COLUMN);

    json_ok([
        'logs'    => $rows,
        'summary' => [
            'inserts'          => (int) ($summary['inserts'] ?? 0),
            'updates'          => (int) ($summary['updates'] ?? 0),
            'deletes'          => (int) ($summary['deletes'] ?? 0),
            'tracked_entities' => (int) ($summary['tracked_entities'] ?? 0),
            'latest_activity'  => $summary['latest_activity'] ?? null,
        ],
        'filters' => ['entities' => $entities, 'actions' => $actions],
    ], 'OK', meta_page($page, $limit, $total));
}

// =====================================================================
// Payment oversight — the admin counterpart to §6.3
// =====================================================================

/** GET /admin/payments?status&page&limit */
function admin_payments(): void
{
    require_role(['admin']);
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    if ($status = q('status')) {
        if (!in_array($status, ['pending', 'verified', 'rejected'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'p.payment_status = ?';
        $params[] = $status;
    }
    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    // Count and list must span the same rows. The count has never joined, so
    // the list's joins have to be LEFT or the total overstates what comes back.
    // That is the right call on its own merits too: this screen is the only
    // place an orphaned payment — one whose appointment or patient row is gone
    // — can be found and reconciled, and an inner join made exactly those rows
    // invisible. `provider_payment_public()` tolerates the nulls.
    $count = db()->prepare("SELECT COUNT(*) FROM payments p $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT p.*, a.appointment_date, a.appointment_time, a.status AS appointment_status,
                a.confirmation_code, pu.name AS patient_name, pu.phone AS patient_phone
           FROM payments p
           LEFT JOIN appointments a ON a.id = p.appointment_id
           LEFT JOIN users pu       ON pu.id = a.patient_id
         $whereSql
         ORDER BY p.id DESC LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['payments' => array_map('provider_payment_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}
