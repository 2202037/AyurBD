<?php
/**
 * Provider endpoints — feature.md §6 (doctor), §7 (hospital), §8 (clinic),
 * §9 (pharmacy).
 *
 * Every handler here resolves the caller's OWN provider row from the token's
 * user id. No handler accepts a doctor_id / clinic_id from the client, so one
 * provider can never read or write another's data — the ownership rule the
 * README calls out as load-bearing.
 *
 * The doctor journey is the deep one because it has appointments and payments
 * behind it. Hospital, clinic and pharmacy are profile + dashboard, which is
 * what feature.md §7–9 describe them as.
 */

declare(strict_types=1);

/**
 * The provider tables, keyed by role. Used to pick a table from a fixed map
 * rather than interpolating anything derived from a request.
 */
const PROVIDER_TABLES = [
    'doctor'   => 'doctors',
    'clinic'   => 'clinics',
    'hospital' => 'hospitals',
    'pharmacy' => 'pharmacies',
];

/**
 * Fetch the caller's provider row, or halt.
 *
 * @param string[] $roles  which provider roles this endpoint serves
 * @return array{0:array<string,mixed>,1:array<string,mixed>}  [user, row]
 */
function provider_row(array $roles): array
{
    $user  = require_role($roles);
    $table = PROVIDER_TABLES[$user['role']] ?? null;

    if ($table === null) {
        json_error('This endpoint is not available for your account type.', 403);
    }

    $stmt = db()->prepare("SELECT * FROM `$table` WHERE user_id = ? LIMIT 1");
    $stmt->execute([(int) $user['id']]);
    $row = $stmt->fetch();

    if (!$row) {
        // Registration creates this row, so a missing one means the account was
        // made another way (or the row was deleted). 409 rather than 404: the
        // account is fine, it is the profile that needs creating, and the
        // doctor profile-edit endpoint below will create it on first save.
        json_error(
            'Your provider profile has not been set up yet. Complete your profile to continue.',
            409
        );
    }

    return [$user, $row];
}

// =====================================================================
// §6.1 Doctor dashboard
// =====================================================================

/**
 * GET /provider/doctor/dashboard
 *
 * feature.md §6.1: verification status, appointment totals by status, pending
 * payments needing verification, profile overview, contact/location, recent
 * appointments.
 */
function provider_doctor_dashboard(): void
{
    [$user, $doctor] = provider_row(['doctor']);
    $doctorId = (int) $doctor['id'];

    // One grouped query rather than five COUNT(*)s.
    $stmt = db()->prepare(
        'SELECT status, COUNT(*) AS n FROM appointments WHERE doctor_id = ? GROUP BY status'
    );
    $stmt->execute([$doctorId]);

    $byStatus = ['pending' => 0, 'confirmed' => 0, 'completed' => 0, 'cancelled' => 0];
    $total    = 0;
    foreach ($stmt->fetchAll() as $r) {
        $byStatus[$r['status']] = (int) $r['n'];
        $total += (int) $r['n'];
    }

    // Today's and upcoming load — the two numbers a doctor actually opens the
    // app for.
    $today = db()->prepare(
        "SELECT COUNT(*) FROM appointments
          WHERE doctor_id = ? AND appointment_date = CURDATE()
            AND status IN ('pending','confirmed')"
    );
    $today->execute([$doctorId]);

    $upcoming = db()->prepare(
        "SELECT COUNT(*) FROM appointments
          WHERE doctor_id = ? AND appointment_date >= CURDATE()
            AND status IN ('pending','confirmed')"
    );
    $upcoming->execute([$doctorId]);

    // Payments awaiting this doctor's verification (§6.3).
    $pendingPay = db()->prepare(
        "SELECT COUNT(*) FROM payments p
           JOIN appointments a ON a.id = p.appointment_id
          WHERE a.doctor_id = ? AND p.payment_status = 'pending'"
    );
    $pendingPay->execute([$doctorId]);

    // Earnings count verified payments only — a submitted-but-unverified
    // transaction id is not money.
    $earnings = db()->prepare(
        "SELECT COALESCE(SUM(p.amount), 0) FROM payments p
           JOIN appointments a ON a.id = p.appointment_id
          WHERE a.doctor_id = ? AND p.payment_status = 'verified'"
    );
    $earnings->execute([$doctorId]);

    $recent = db()->prepare(
        appointment_select_sql() . ' WHERE a.doctor_id = ?
         ORDER BY a.appointment_date DESC, a.appointment_time DESC LIMIT 5'
    );
    $recent->execute([$doctorId]);

    json_ok([
        'stats' => [
            'total_appointments'     => $total,
            'pending_appointments'   => $byStatus['pending'],
            'confirmed_appointments' => $byStatus['confirmed'],
            'completed_appointments' => $byStatus['completed'],
            'cancelled_appointments' => $byStatus['cancelled'],
            'today_appointments'     => (int) $today->fetchColumn(),
            'upcoming_appointments'  => (int) $upcoming->fetchColumn(),
            'pending_payments'       => (int) $pendingPay->fetchColumn(),
            'total_earnings'         => (float) $earnings->fetchColumn(),
        ],
        // The dashboard header shows pending / verified / rejected verbatim so
        // "not reviewed yet" reads differently from "rejected" (§6.1).
        'verification_status' => $doctor['verification_status'] ?? 'pending',
        'status'              => $doctor['status'] ?? 'pending',
        'doctor'              => doctor_public($doctor + [
            'doctor_name'  => $user['name'],
            'doctor_email' => $user['email'],
            'doctor_phone' => $user['phone'],
            'profile_image' => $user['profile_image'] ?? null,
        ]),
        'recent_appointments' => array_map('appointment_public', $recent->fetchAll()),
    ]);
}

// =====================================================================
// §6.2 Doctor appointment management
// =====================================================================

/** GET /provider/doctor/appointments?status&date&page&limit */
function provider_doctor_appointments(): void
{
    [, $doctor] = provider_row(['doctor']);
    [$page, $limit, $offset] = paging();

    $where  = ['a.doctor_id = ?'];
    $params = [(int) $doctor['id']];

    if ($status = q('status')) {
        if (!in_array($status, ['pending', 'confirmed', 'completed', 'cancelled'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'a.status = ?';
        $params[] = $status;
    }
    if ($date = q('date')) {
        $d = DateTime::createFromFormat('Y-m-d', $date);
        if (!$d || $d->format('Y-m-d') !== $date) {
            json_error('Invalid date filter.', 400, ['date' => 'Use YYYY-MM-DD.']);
        }
        $where[]  = 'a.appointment_date = ?';
        $params[] = $date;
    }

    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM appointments a $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    // $limit/$offset are ints from paging(), never strings from the client.
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

/**
 * POST /provider/doctor/appointments/status  {appointment_id,status,notes?}
 *
 * feature.md §6.2: confirm a pending appointment, mark a confirmed one
 * completed, or cancel.
 */
function provider_doctor_appointment_status(): void
{
    [$user, $doctor] = provider_row(['doctor']);

    $in = validate(json_body(), [
        'appointment_id' => 'required|int',
        'status'         => 'required|in:confirmed,completed,cancelled',
        'notes'          => 'max:1000',
    ]);

    $pdo = db();
    $stmt = $pdo->prepare('SELECT * FROM appointments WHERE id = ? LIMIT 1');
    $stmt->execute([$in['appointment_id']]);
    $appt = $stmt->fetch();

    if (!$appt) {
        json_error('Appointment not found.', 404);
    }
    // Ownership from the token's doctor row, never from the request.
    if ((int) $appt['doctor_id'] !== (int) $doctor['id']) {
        json_error('This appointment is not yours.', 403);
    }

    // Legal transitions. Completing a pending appointment is blocked on
    // purpose: it would skip the confirmation the patient is told to wait for.
    $allowed = [
        'pending'   => ['confirmed', 'cancelled'],
        'confirmed' => ['completed', 'cancelled'],
        'completed' => [],
        'cancelled' => [],
    ];
    $from = (string) $appt['status'];

    if (!in_array($in['status'], $allowed[$from] ?? [], true)) {
        json_error(
            "An appointment that is $from cannot be marked {$in['status']}.",
            422,
            ['status' => 'Invalid transition from ' . $from . '.']
        );
    }

    $sets   = ['status = ?'];
    $params = [$in['status']];

    if (isset($in['notes'])) {
        $sets[]   = 'notes = ?';
        $params[] = $in['notes'];
    }

    // Confirming generates the code the patient shows at the chamber, unless
    // one already exists (a trigger or the website may have set it).
    $code = $appt['confirmation_code'] ?? null;
    if ($in['status'] === 'confirmed'
        && ($code === null || $code === '')
        && table_has_column('appointments', 'confirmation_code')) {
        $code     = provider_confirmation_code();
        $sets[]   = 'confirmation_code = ?';
        $params[] = $code;
    }

    $params[] = (int) $appt['id'];
    $pdo->prepare('UPDATE appointments SET ' . implode(', ', $sets) . ' WHERE id = ?')
        ->execute($params);

    $messages = [
        'confirmed' => ['Appointment confirmed', 'Your appointment has been confirmed by the doctor.'],
        'completed' => ['Appointment completed', 'Your appointment is marked complete. You can now leave a review.'],
        'cancelled' => ['Appointment cancelled', 'Your appointment was cancelled by the doctor.'],
    ];
    [$title, $body] = $messages[$in['status']];

    $pdo->prepare(
        'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
         VALUES (?, ?, ?, "appointment", "/appointments", ?)'
    )->execute([(int) $appt['patient_id'], $title, $body, (int) $appt['id']]);

    audit((int) $user['id'], 'update', 'appointments', (int) $appt['id'], [
        'from' => $from,
        'to'   => $in['status'],
    ]);

    $fetch = $pdo->prepare(appointment_select_sql() . ' WHERE a.id = ?');
    $fetch->execute([(int) $appt['id']]);

    json_ok(
        ['appointment' => appointment_public($fetch->fetch())],
        'Appointment marked ' . $in['status'] . '.'
    );
}

/**
 * Short human-readable confirmation code (§6.3).
 *
 * Ambiguous characters (0/O, 1/I) are excluded because this gets read aloud
 * over the phone and typed off a screen. random_int() is the CSPRNG — a code
 * that is guessable lets someone claim another patient's slot.
 */
function provider_confirmation_code(): string
{
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    $out      = '';
    for ($i = 0; $i < 8; $i++) {
        $out .= $alphabet[random_int(0, strlen($alphabet) - 1)];
    }

    return $out;
}

// =====================================================================
// §6.3 Payment verification
// =====================================================================

/** GET /provider/doctor/payments?status&page&limit */
function provider_doctor_payments(): void
{
    [, $doctor] = provider_row(['doctor']);
    [$page, $limit, $offset] = paging();

    $status = q('status') ?? 'pending';
    if (!in_array($status, ['pending', 'verified', 'rejected', 'all'], true)) {
        json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
    }

    $where  = ['a.doctor_id = ?'];
    $params = [(int) $doctor['id']];

    if ($status !== 'all') {
        $where[]  = 'p.payment_status = ?';
        $params[] = $status;
    }
    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare(
        "SELECT COUNT(*) FROM payments p JOIN appointments a ON a.id = p.appointment_id $whereSql"
    );
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    $stmt = db()->prepare(
        "SELECT p.*, a.appointment_date, a.appointment_time, a.status AS appointment_status,
                a.confirmation_code, pu.name AS patient_name, pu.phone AS patient_phone
           FROM payments p
           JOIN appointments a ON a.id = p.appointment_id
           LEFT JOIN users pu  ON pu.id = a.patient_id
         $whereSql
         ORDER BY p.id DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    json_ok(
        ['payments' => array_map('provider_payment_public', $stmt->fetchAll())],
        'OK',
        meta_page($page, $limit, $total)
    );
}

/**
 * @param array<string,mixed> $r
 * @return array<string,mixed>
 */
function provider_payment_public(array $r): array
{
    return [
        'id'                 => (int) ($r['id'] ?? 0),
        'appointment_id'     => (int) ($r['appointment_id'] ?? 0),
        'amount'             => (float) ($r['amount'] ?? 0),
        'payment_method'     => $r['payment_method'] ?? null,
        'transaction_id'     => $r['transaction_id'] ?? null,
        'sender_number'      => $r['sender_number'] ?? null,
        'payment_status'     => $r['payment_status'] ?? 'pending',
        'notes'              => $r['notes'] ?? null,
        // Added by migration_v2.sql; ?? keeps this working before it is run.
        'rejection_reason'   => $r['rejection_reason'] ?? null,
        'verified_at'        => $r['verified_at'] ?? null,
        'created_at'         => $r['created_at'] ?? null,
        'appointment_date'   => $r['appointment_date'] ?? null,
        'appointment_time'   => $r['appointment_time'] ?? null,
        'appointment_status' => $r['appointment_status'] ?? null,
        'confirmation_code'  => $r['confirmation_code'] ?? null,
        'patient_name'       => $r['patient_name'] ?? null,
        'patient_phone'      => $r['patient_phone'] ?? null,
    ];
}

/**
 * POST /provider/doctor/payments/verify
 *   {payment_id, action: verify|reject, rejection_reason?}
 *
 * feature.md §6.3. Verifying is what moves appointments.payment_status to
 * 'paid' and mints the confirmation code.
 */
function provider_doctor_payment_verify(): void
{
    [$user, $doctor] = provider_row(['doctor']);

    $in = validate(json_body(), [
        'payment_id'       => 'required|int',
        'action'           => 'required|in:verify,reject',
        'rejection_reason' => 'max:255',
    ]);

    if ($in['action'] === 'reject' && empty($in['rejection_reason'])) {
        json_error('Tell the patient why the payment was rejected.', 422, [
            'rejection_reason' => 'A reason is required when rejecting.',
        ]);
    }

    $pdo = db();
    $stmt = $pdo->prepare(
        'SELECT p.*, a.doctor_id, a.patient_id, a.confirmation_code
           FROM payments p
           JOIN appointments a ON a.id = p.appointment_id
          WHERE p.id = ? LIMIT 1'
    );
    $stmt->execute([$in['payment_id']]);
    $payment = $stmt->fetch();

    if (!$payment) {
        json_error('Payment not found.', 404);
    }
    if ((int) $payment['doctor_id'] !== (int) $doctor['id']) {
        json_error('This payment is not for one of your appointments.', 403);
    }
    if ($payment['payment_status'] !== 'pending') {
        json_error(
            'This payment has already been ' . $payment['payment_status'] . '.',
            422
        );
    }

    $verified = $in['action'] === 'verify';
    $code     = $payment['confirmation_code'] ?? null;

    $pdo->beginTransaction();

    try {
        update_row($pdo, 'payments', [
            'payment_status'   => $verified ? 'verified' : 'rejected',
            'verified_by'      => (int) $user['id'],
            'verified_at'      => date('Y-m-d H:i:s'),
            'rejection_reason' => $verified ? null : $in['rejection_reason'],
        ], 'id', (int) $payment['id']);

        // update_row() drops nulls so a column default applies, which would
        // leave a stale reason on a re-verified row. Clear it explicitly.
        if ($verified && table_has_column('payments', 'rejection_reason')) {
            $pdo->prepare('UPDATE payments SET rejection_reason = NULL WHERE id = ?')
                ->execute([(int) $payment['id']]);
        }

        if ($verified) {
            // The one place appointments.payment_status becomes 'paid'. The
            // README forbids the patient-facing app from ever setting it; this
            // is the doctor's manual verification, which is exactly the step
            // that is allowed to.
            $sets   = ['payment_status = "paid"'];
            $params = [];

            if (($code === null || $code === '')
                && table_has_column('appointments', 'confirmation_code')) {
                $code     = provider_confirmation_code();
                $sets[]   = 'confirmation_code = ?';
                $params[] = $code;
            }
            $params[] = (int) $payment['appointment_id'];

            $pdo->prepare(
                'UPDATE appointments SET ' . implode(', ', $sets) . ' WHERE id = ?'
            )->execute($params);
        }

        $title = $verified ? 'Payment verified' : 'Payment rejected';
        $body  = $verified
            ? 'Your payment was verified.' . ($code ? " Confirmation code: $code" : '')
            : 'Your payment was rejected: ' . $in['rejection_reason'];

        $pdo->prepare(
            'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
             VALUES (?, ?, ?, "payment", "/appointments", ?)'
        )->execute([
            (int) $payment['patient_id'],
            $title,
            $body,
            (int) $payment['appointment_id'],
        ]);

        $pdo->commit();
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }

    audit((int) $user['id'], $verified ? 'verify_payment' : 'reject_payment',
        'payments', (int) $payment['id']);

    json_ok(
        ['confirmation_code' => $verified ? $code : null],
        $verified ? 'Payment verified.' : 'Payment rejected.'
    );
}

// =====================================================================
// §6.4 Doctor profile editing
// =====================================================================

/**
 * PUT /provider/doctor/profile
 *
 * feature.md §6.4: "Creates a doctor profile record if one does not exist
 * yet" and "Keeps the user and doctor tables synchronized" — so this is the
 * one provider write that does not go through provider_row().
 */
function provider_doctor_profile_update(): void
{
    $user = require_role(['doctor']);

    $in = validate(json_body(), [
        // users columns
        'name'          => 'min:2|max:150',
        'phone'         => 'phone',
        'address'       => 'max:255',
        'gender'        => 'in:male,female,other',
        'profile_image' => 'max:255',
        // doctors columns
        'bmdc_number'          => 'max:50',
        'bmdc_certificate'     => 'max:255',
        'medical_school'       => 'max:150',
        'graduation_year'      => 'int|min:1900|max:2100',
        'doctor_type'          => 'max:50',
        'specialization'       => 'max:150',
        'qualifications'       => 'max:255',
        'experience_years'     => 'int|min:0|max:80',
        'hospital_clinic_name' => 'max:200',
        'chamber_address'      => 'max:255',
        'city'                 => 'max:100',
        'area'                 => 'max:100',
        'consultation_fee'     => 'numeric|min:0|max:1000000',
        'bio'                  => 'max:2000',
        // availability (added by migration_v1.sql)
        'available_days'   => 'max:100',
        'available_from'   => 'time',
        'available_to'     => 'time',
        'slot_minutes'     => 'int|min:5|max:240',
    ]);

    if (empty($in)) {
        json_error('No fields to update.', 400);
    }

    $pdo = db();
    $pdo->beginTransaction();

    try {
        // users side. `city` lives on both tables; it is written to each.
        update_row($pdo, 'users', [
            'name'          => $in['name'] ?? null,
            'phone'         => $in['phone'] ?? null,
            'address'       => $in['address'] ?? null,
            'gender'        => $in['gender'] ?? null,
            'city'          => $in['city'] ?? null,
            'profile_image' => $in['profile_image'] ?? null,
        ], 'id', (int) $user['id']);

        $doctorFields = [
            'bmdc_number'          => $in['bmdc_number'] ?? null,
            'bmdc_certificate'     => $in['bmdc_certificate'] ?? null,
            'medical_school'       => $in['medical_school'] ?? null,
            'graduation_year'      => $in['graduation_year'] ?? null,
            'doctor_type'          => $in['doctor_type'] ?? null,
            'specialization'       => $in['specialization'] ?? null,
            'qualifications'       => $in['qualifications'] ?? null,
            'experience_years'     => $in['experience_years'] ?? null,
            'hospital_clinic_name' => $in['hospital_clinic_name'] ?? null,
            'chamber_address'      => $in['chamber_address'] ?? null,
            'city'                 => $in['city'] ?? null,
            'area'                 => $in['area'] ?? null,
            'consultation_fee'     => $in['consultation_fee'] ?? null,
            'bio'                  => $in['bio'] ?? null,
            'available_days'       => $in['available_days'] ?? null,
            'available_from'       => $in['available_from'] ?? null,
            'available_to'         => $in['available_to'] ?? null,
            'slot_minutes'         => $in['slot_minutes'] ?? null,
        ];

        $exists = $pdo->prepare('SELECT id FROM doctors WHERE user_id = ? LIMIT 1');
        $exists->execute([(int) $user['id']]);
        $doctorId = $exists->fetchColumn();

        if ($doctorId === false) {
            // §6.4 create-if-absent. Left at the default pending status so a
            // self-created profile cannot appear in the directory unverified.
            $doctorId = insert_row($pdo, 'doctors',
                ['user_id' => (int) $user['id']] + $doctorFields);
        } else {
            update_row($pdo, 'doctors', $doctorFields, 'id', (int) $doctorId);
        }

        $pdo->commit();
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }

    audit((int) $user['id'], 'update', 'doctors', (int) $doctorId, array_keys($in));

    $fetch = $pdo->prepare(
        'SELECT d.*, u.name AS doctor_name, u.email AS doctor_email,
                u.phone AS doctor_phone, u.profile_image
           FROM doctors d JOIN users u ON u.id = d.user_id
          WHERE d.user_id = ? LIMIT 1'
    );
    $fetch->execute([(int) $user['id']]);

    json_ok(['doctor' => doctor_public($fetch->fetch())], 'Profile updated.');
}

// =====================================================================
// §7–9 Hospital / clinic / pharmacy dashboards
// =====================================================================

/**
 * GET /provider/place/dashboard
 *
 * One handler for all three roles: feature.md §7, §8 and §9 describe the same
 * screen with different field labels (verification badge, profile summary,
 * contact, location, services, operating hours). The row shape differs, and
 * place_public() already handles that per-table.
 */
function provider_place_dashboard(): void
{
    [$user, $row] = provider_row(['hospital', 'clinic', 'pharmacy']);

    $type = $user['role'];
    $id   = (int) $row['id'];

    // Review counts drive the "Reviews" shortcut card (§7–9).
    $reviews = db()->prepare(
        'SELECT
            COUNT(*) AS total,
            SUM(status = "pending")  AS pending,
            SUM(status = "approved") AS approved
           FROM reviews WHERE reviewable_type = ? AND reviewable_id = ?'
    );
    $reviews->execute([$type, $id]);
    $rev = $reviews->fetch() ?: [];

    $stats = [
        'total_reviews'    => (int) ($rev['total'] ?? 0),
        'pending_reviews'  => (int) ($rev['pending'] ?? 0),
        'approved_reviews' => (int) ($rev['approved'] ?? 0),
        'rating'           => (float) ($row['rating'] ?? 0),
    ];

    // Pharmacies get product/order counts instead of a doctor count — those are
    // the shortcut cards §9 lists (Inventory, Orders).
    if ($type === 'pharmacy') {
        $products = db()->prepare(
            'SELECT COUNT(*) FROM pharmacy_products WHERE pharmacy_id = ?'
        );
        $products->execute([$id]);
        $stats['total_products'] = (int) $products->fetchColumn();

        $orders = db()->prepare(
            'SELECT COUNT(*) AS n, COALESCE(SUM(total_amount), 0) AS revenue
               FROM orders WHERE pharmacy_id = ?'
        );
        $orders->execute([$id]);
        $o = $orders->fetch() ?: [];
        $stats['total_orders']  = (int) ($o['n'] ?? 0);
        $stats['total_revenue'] = (float) ($o['revenue'] ?? 0);
    } else {
        // Doctors are linked to a hospital/clinic by free-text name in this
        // schema, not an FK — so this counts by name and is only as good as the
        // spelling. Zero here means "no doctor lists this workplace", not
        // necessarily "no doctors".
        $docs = db()->prepare(
            'SELECT COUNT(*) FROM doctors WHERE hospital_clinic_name = ?'
        );
        $docs->execute([(string) $row['name']]);
        $stats['linked_doctors'] = (int) $docs->fetchColumn();
    }

    json_ok([
        'type'                => $type,
        'verification_status' => $row['verification_status'] ?? 'pending',
        'status'              => $row['status'] ?? 'pending',
        'profile'             => place_public($row),
        'stats'               => $stats,
        'owner'               => user_public($user),
    ]);
}

/**
 * PUT /provider/place/profile
 *
 * Hospital / clinic / pharmacy profile editing. Each role gets its own field
 * whitelist; a pharmacy cannot write `total_beds` even by sending it, because
 * the key is not in its list and filter_to_columns() would drop it anyway.
 */
function provider_place_profile_update(): void
{
    [$user, $row] = provider_row(['hospital', 'clinic', 'pharmacy']);
    $table = PROVIDER_TABLES[$user['role']];

    // Shared across all three.
    $rules = [
        'name'         => 'min:2|max:200',
        'phone'        => 'phone',
        'email'        => 'email|max:190',
        'website'      => 'max:255',
        'address'      => 'max:255',
        'city'         => 'max:100',
        'area'         => 'max:100',
        'description'  => 'max:2000',
        'opening_time' => 'time',
        'closing_time' => 'time',
    ];

    $perRole = [
        'hospital' => [
            'emergency_phone'  => 'phone',
            'hospital_type'    => 'max:50',
            'established_year' => 'int|min:1800|max:2100',
            'total_beds'       => 'int|min:0|max:100000',
            'icu_beds'         => 'int|min:0|max:100000',
            'facilities'       => 'max:2000',
            'departments'      => 'max:2000',
            'open_24_hours'    => 'in:0,1',
            'registration_number' => 'max:100',
            'license_number'   => 'max:100',
            'license_document' => 'max:255',
        ],
        'clinic' => [
            'clinic_type'      => 'max:50',
            'established_year' => 'int|min:1800|max:2100',
            'services'         => 'max:2000',
            'specializations'  => 'max:2000',
            'available_days'   => 'max:100',
            'registration_number' => 'max:100',
            'license_number'   => 'max:100',
            'license_document' => 'max:255',
        ],
        'pharmacy' => [
            'whatsapp'            => 'phone',
            'pharmacy_type'       => 'max:50',
            'owner_name'          => 'max:150',
            'pharmacist_name'     => 'max:150',
            'pharmacist_license'  => 'max:100',
            'established_year'    => 'int|min:1800|max:2100',
            'services'            => 'max:2000',
            'delivery_available'  => 'in:0,1',
            'delivery_radius_km'  => 'int|min:0|max:500',
            'open_24_hours'       => 'in:0,1',
            'license_number'      => 'max:100',
            'drug_license_number' => 'max:100',
            'license_document'    => 'max:255',
        ],
    ];

    $in = validate(json_body(), $rules + $perRole[$user['role']]);

    if (empty($in)) {
        json_error('No fields to update.', 400);
    }

    // Booleans arrive as '0'/'1' strings from the validator's in: rule.
    foreach (['open_24_hours', 'delivery_available'] as $flag) {
        if (isset($in[$flag])) {
            $in[$flag] = (int) $in[$flag];
        }
    }

    $pdo = db();

    // Editing the profile must NOT re-open verification, and must not let a
    // provider set its own verification_status — neither key is in the rules
    // above, so neither can arrive here.
    update_row($pdo, $table, $in, 'id', (int) $row['id']);

    // Keep the owning user row in step with the public-facing contact details.
    update_row($pdo, 'users', [
        'name'    => $in['name'] ?? null,
        'phone'   => $in['phone'] ?? null,
        'address' => $in['address'] ?? null,
        'city'    => $in['city'] ?? null,
    ], 'id', (int) $user['id']);

    audit((int) $user['id'], 'update', $table, (int) $row['id'], array_keys($in));

    $fetch = $pdo->prepare("SELECT * FROM `$table` WHERE id = ?");
    $fetch->execute([(int) $row['id']]);

    json_ok(['profile' => place_public($fetch->fetch())], 'Profile updated.');
}

/**
 * GET /provider/reviews?status&page&limit
 *
 * The "Reviews" shortcut card from §6–9. A provider sees reviews written
 * about them, including pending ones, so they know what is coming.
 */
function provider_reviews(): void
{
    $user = require_role(['doctor', 'hospital', 'clinic', 'pharmacy']);
    [$page, $limit, $offset] = paging();

    $table = PROVIDER_TABLES[$user['role']];
    $own   = db()->prepare("SELECT id FROM `$table` WHERE user_id = ? LIMIT 1");
    $own->execute([(int) $user['id']]);
    $ownId = $own->fetchColumn();

    if ($ownId === false) {
        json_ok(['reviews' => []], 'OK', meta_page($page, $limit, 0));
    }

    $where  = ['r.reviewable_type = ?', 'r.reviewable_id = ?'];
    $params = [$user['role'], (int) $ownId];

    if ($status = q('status')) {
        if (!in_array($status, ['pending', 'approved', 'rejected'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'r.status = ?';
        $params[] = $status;
    }
    $whereSql = 'WHERE ' . implode(' AND ', $where);

    $count = db()->prepare("SELECT COUNT(*) FROM reviews r $whereSql");
    $count->execute($params);
    $total = (int) $count->fetchColumn();

    // LEFT, to match the unjoined COUNT directly above. The shaper below already
    // defaults `reviewer_name`/`reviewer_image` to null, so a review whose
    // author is gone renders anonymously instead of disappearing from the
    // provider's own list while still counting against their rating.
    $stmt = db()->prepare(
        "SELECT r.*, u.name AS reviewer_name, u.profile_image AS reviewer_image
           FROM reviews r
           LEFT JOIN users u ON u.id = r.user_id
         $whereSql
         ORDER BY r.id DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    $rows = array_map(static fn(array $r): array => [
        'id'             => (int) $r['id'],
        'rating'         => (int) $r['rating'],
        'comment'        => $r['comment'] ?? null,
        'status'         => $r['status'],
        'created_at'     => $r['created_at'] ?? null,
        'reviewer_name'  => $r['reviewer_name'] ?? null,
        'reviewer_image' => $r['reviewer_image'] ?? null,
    ], $stmt->fetchAll());

    json_ok(['reviews' => $rows], 'OK', meta_page($page, $limit, $total));
}
