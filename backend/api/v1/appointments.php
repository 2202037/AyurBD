<?php
/**
 * Appointments + payment — §6 /appointments/*
 *
 * §8: "server is sole arbiter of slot conflict (409) and past-date rejection."
 *
 * DOUBLE-BOOKING GUARD — read before changing appointments_book().
 * The live `appointments` table has NO unique index on
 * (doctor_id, appointment_date, appointment_time) — its only UNIQUE is on
 * `confirmation_code`. So there is no errno-1062 backstop to catch a race, and
 * an earlier version of this file that relied on one would have allowed two
 * patients into the same slot.
 *
 * The guard is therefore a locking read inside a transaction:
 *     SELECT ... FOR UPDATE on the doctor+date+time triple
 * InnoDB holds a lock for the duration, so a second concurrent booking blocks
 * until the first commits, then sees the row and gets a clean 409.
 *
 * Caveat worth knowing: this protects the app against itself. If the website
 * inserts appointments without a comparable locking read, a cross-client race
 * is still possible. Adding the unique index would close that permanently —
 * see the note at the bottom of database/migration_v1.sql.
 */

declare(strict_types=1);

/**
 * Normalise `doctors.available_days` to lowercase 3-letter abbreviations.
 *
 * The column is CSV. migration_v1.sql seeded it as "sat,sun,mon", and that is
 * what the slot generator compares against via PHP's `date('D')`. But an older
 * build of the Flutter profile form wrote full names ("Saturday,Sunday"), which
 * never matched — the doctor saved a schedule and silently became unbookable.
 *
 * Accepting both shapes here means those existing rows start working again
 * without a manual UPDATE, and it stops the mismatch from being a live bug if
 * any other client writes long names. Truncating to 3 characters is safe for
 * every English weekday: no two share their first three letters.
 *
 * @return list<string>
 */
function parse_available_days(?string $csv): array
{
    $csv = trim((string) $csv);
    if ($csv === '') {
        return [];
    }

    $out = [];
    foreach (explode(',', $csv) as $part) {
        $token = strtolower(trim($part));
        if ($token === '') {
            continue;
        }
        $out[] = substr($token, 0, 3);
    }

    return array_values(array_unique($out));
}

/**
 * Four call sites hand this the result of a bare `$stmt->fetch()`, which is
 * `false` — not an array — when the row is not there. With `declare(strict_types=1)`
 * that is a TypeError, and the front controller turns it into a 500, so a
 * just-booked appointment that a re-SELECT cannot find would fail the whole
 * request instead of the one field. `false|array` accepts it and the normaliser
 * below turns it into an empty row, which every `?? null` here already handles.
 *
 * @param array<string,mixed>|false|null $r
 * @return array<string,mixed>
 */
function appointment_public(array|false|null $r): array
{
    $r = is_array($r) ? $r : [];

    // Every key is read with a fallback, including the ones that "obviously"
    // exist. `index.php` installs a set_error_handler that rethrows any PHP
    // notice as an ErrorException, so a single "Undefined array key" here does
    // not degrade one field — it takes the whole endpoint down as a 500, and the
    // app shows an error or an empty list for the entire appointment section.
    // Column drift between dumps of this database is a known hazard (it is why
    // helpers/schema.php exists), so one absent column must cost one value, not
    // the response.
    $out = [
        'id'               => (int) ($r['id'] ?? 0),
        'patient_id'       => (int) ($r['patient_id'] ?? 0),
        'doctor_id'        => (int) ($r['doctor_id'] ?? 0),
        'appointment_date' => $r['appointment_date'] ?? null,
        'appointment_time' => $r['appointment_time'] ?? null,
        // The real column is `symptoms`. It is exposed as `reason` too so the
        // app's existing model keeps working, and both names carry the value.
        'symptoms'         => $r['symptoms'] ?? null,
        'reason'           => $r['symptoms'] ?? null,
        'type'             => $r['type'] ?? null,
        'fee'              => isset($r['fee']) ? (float) $r['fee'] : null,
        'status'           => $r['status'] ?? 'pending',
        'notes'            => $r['notes'] ?? null,
        // Set by a database trigger / the website; the app only displays it.
        'confirmation_code' => $r['confirmation_code'] ?? null,
        'created_at'       => $r['created_at'] ?? null,
    ];

    // Joined display fields (§6: joined payloads to avoid N+1).
    //
    // The gate is array_key_exists, NOT isset, and the difference is the whole
    // point. These blocks exist to tell "this query did not join the doctor at
    // all" apart from "it joined and the row is gone". Since the joins in
    // `appointment_select_sql()` are LEFT, the second case now yields a key that
    // is present with a NULL value — and isset() is false for NULL, so it would
    // have skipped the entire block, including `consultation_fee`. Losing that
    // key sends `fee` to 0 on the client, and `Appointment.canPay` requires
    // `fee > 0`, so a patient would silently lose the ability to pay for a real
    // appointment. array_key_exists asks the question actually intended: did the
    // SELECT include this column?
    if (array_key_exists('doctor_name', $r)) {
        $out['doctor_name']      = $r['doctor_name'];
        $out['doctor_specialty'] = $r['specialization'] ?? null;
        $out['doctor_image']     = $r['profile_image'] ?? null;
        $out['consultation_fee'] = isset($r['consultation_fee']) ? (float) $r['consultation_fee'] : null;
        // Workplace is free text on `doctors`; there is no clinics FK to join.
        $out['clinic_name']      = $r['hospital_clinic_name'] ?? null;
        $out['clinic_address']   = $r['chamber_address'] ?? null;
    }
    if (array_key_exists('patient_name', $r)) {
        $out['patient_name']  = $r['patient_name'];
        $out['patient_phone'] = $r['patient_phone'] ?? null;
    }

    // Payment view. `appointments.payment_status` is the authoritative column
    // (enum pending|paid|refunded) and always exists. The joined payments row
    // adds method/amount when one has been recorded.
    $out['payment_status'] = $r['payment_status'] ?? 'pending';
    $out['payment_amount'] = isset($r['payment_amount']) && $r['payment_amount'] !== null
        ? (float) $r['payment_amount']
        : (isset($r['fee']) ? (float) $r['fee'] : null);
    $out['payment_method'] = $r['payment_method'] ?? null;
    // pending|verified|rejected — the admin's manual verification state, which
    // is not the same thing as the patient having submitted a payment.
    $out['payment_review'] = $r['payment_review'] ?? null;

    return $out;
}

/**
 * Standard SELECT for an appointment with everything the app renders.
 *
 * The payments join is deliberately restricted to the most recent row per
 * appointment: `payments` has no UNIQUE on appointment_id, so a patient who
 * submits a bKash reference twice produces two rows, and an unrestricted join
 * would duplicate the appointment in every list.
 *
 * Every join here is a LEFT JOIN, and that matters more than it looks. These
 * were inner joins, which meant an appointment was returned only if its doctor
 * row, that doctor's user row, AND its patient's user row all still existed.
 * Miss any one and the appointment did not come back missing a name — it did
 * not come back at all. `admin_user_delete()` deletes `users` rows, so removing
 * one patient silently erased their whole appointment history from every list
 * in the app, including the doctor's and the admin's, with no error anywhere.
 * The shaper below already guards each joined block with isset(), so a null
 * name is a case it is written to handle; a vanished row is not.
 */
function appointment_select_sql(): string
{
    return "SELECT a.*, u.name AS doctor_name, u.profile_image,
                   d.specialization, d.consultation_fee,
                   d.hospital_clinic_name, d.chamber_address,
                   pu.name AS patient_name, pu.phone AS patient_phone,
                   p.amount AS payment_amount,
                   p.payment_method,
                   p.payment_status AS payment_review
              FROM appointments a
              LEFT JOIN doctors d ON d.id = a.doctor_id
              LEFT JOIN users u   ON u.id = d.user_id
              LEFT JOIN users pu  ON pu.id = a.patient_id
              LEFT JOIN payments p ON p.id = (
                    SELECT p2.id FROM payments p2
                     WHERE p2.appointment_id = a.id
                     ORDER BY p2.id DESC LIMIT 1
              )";
}

/**
 * GET /appointments/slots?doctor_id&date
 * Generates the slot grid from the doctor's window and marks taken ones.
 * Not in §6, but the booking UI needs it to avoid guess-and-409 loops.
 */
function appointments_slots(): void
{
    $doctorId = q('doctor_id');
    $date     = q('date');

    if ($doctorId === null || !ctype_digit($doctorId)) {
        json_error('doctor_id is required.', 400, ['doctor_id' => 'Required.']);
    }
    if ($date === null) {
        json_error('date is required.', 400, ['date' => 'Required (YYYY-MM-DD).']);
    }
    $d = DateTime::createFromFormat('Y-m-d', $date);
    if (!$d || $d->format('Y-m-d') !== $date) {
        json_error('Invalid date.', 400, ['date' => 'Must be YYYY-MM-DD.']);
    }

    $stmt = db()->prepare("SELECT * FROM doctors WHERE id = ? AND status = 'active' LIMIT 1");
    $stmt->execute([(int) $doctorId]);
    $doctor = $stmt->fetch();

    if (!$doctor) {
        json_error('Doctor not found.', 404);
    }

    $today  = new DateTime('today');
    $isPast = $d < $today;

    // Does the doctor work that weekday?
    //
    // available_days is CSV, written lowercase by migration_v1.sql
    // ("sat,sun,mon"). Comparison is case-insensitive so a row edited by hand
    // to "Sat,Sun" still matches.
    //
    // An unset schedule means "unknown", NOT "available every day". Offering
    // slots for a doctor whose hours nobody has configured would send patients
    // to a chamber that is closed, so the endpoint returns an empty grid and
    // lets the app tell them to phone instead.
    $dayAbbr    = strtolower($d->format('D'));        // sat, sun, mon…
    $daysRaw    = trim((string) ($doctor['available_days'] ?? ''));
    $days       = parse_available_days($daysRaw);
    $configured = $daysRaw !== '' && $doctor['available_from'] && $doctor['available_to'];
    $worksToday = $configured && in_array($dayAbbr, $days, true);

    $slots = [];

    if (!$isPast && $worksToday) {
        $from = $doctor['available_from'];
        $to   = $doctor['available_to'];
        $step = max(5, (int) ($doctor['slot_minutes'] ?: 30));

        // Already-booked times for this doctor/date. A cancelled appointment
        // releases its slot: there is no unique index holding it, so the time
        // genuinely becomes bookable again.
        $bs = db()->prepare(
            "SELECT appointment_time FROM appointments
              WHERE doctor_id = ? AND appointment_date = ? AND status <> 'cancelled'"
        );
        $bs->execute([(int) $doctorId, $date]);
        $taken = array_column($bs->fetchAll(), 'appointment_time');

        $cursor = new DateTime($date . ' ' . $from);
        $end    = new DateTime($date . ' ' . $to);
        $now    = new DateTime();

        while ($cursor < $end) {
            $t = $cursor->format('H:i:s');

            // Slots earlier today are unbookable.
            $isPastToday = $cursor <= $now;

            $slots[] = [
                'time'      => $t,
                'label'     => $cursor->format('g:i A'),
                'available' => !in_array($t, $taken, true) && !$isPastToday,
            ];

            $cursor->modify("+$step minutes");
        }
    }

    json_ok([
        'doctor_id'    => (int) $doctorId,
        'date'         => $date,
        'works_on_day' => $worksToday && !$isPast,
        // Lets the app distinguish "closed that day" from "hours never set up",
        // which need different messages.
        'schedule_set' => $configured,
        'slot_minutes' => (int) ($doctor['slot_minutes'] ?: 30),
        'slots'        => $slots,
    ]);
}

/**
 * POST /appointments/book  {doctor_id,date,time,reason}
 * → created appointment + doctor info. 409 on conflict, 422 on business rule.
 */
function appointments_book(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'doctor_id' => 'required|int',
        'date'      => 'required|date',
        'time'      => 'required|time',
        // Request key stays `reason` (the app sends that); it is stored in the
        // real `symptoms` column. `type` maps to the appointments enum.
        'reason'    => 'max:500',
        'type'      => 'in:new,followup,online',
    ]);

    // §8: past dates rejected server-side regardless of what the client allows.
    $when  = new DateTime($in['date'] . ' ' . $in['time']);
    $now   = new DateTime();
    if ($when < $now) {
        json_error('Cannot book an appointment in the past.', 422, [
            'date' => 'Choose a future date and time.',
        ]);
    }

    $pdo = db();

    $ds = $pdo->prepare("SELECT * FROM doctors WHERE id = ? AND status = 'active' LIMIT 1");
    $ds->execute([$in['doctor_id']]);
    $doctor = $ds->fetch();

    if (!$doctor) {
        json_error('Doctor not found or unavailable.', 404);
    }

    // Weekday check against the doctor's schedule. Case-insensitive, matching
    // appointments_slots(). An unconfigured schedule blocks booking rather than
    // waving it through — same reasoning as the slot grid.
    $daysRaw = trim((string) ($doctor['available_days'] ?? ''));
    if ($daysRaw === '' || !$doctor['available_from'] || !$doctor['available_to']) {
        json_error(
            'This doctor has not published consulting hours yet. Please contact the chamber directly.',
            422,
            ['doctor_id' => 'No schedule configured.']
        );
    }

    $abbr = strtolower((new DateTime($in['date']))->format('D'));
    $days = parse_available_days($daysRaw);
    if (!in_array($abbr, $days, true)) {
        json_error('The doctor is not available on that day.', 422, [
            'date' => 'Doctor is unavailable on this weekday.',
        ]);
    }

    // Time window check.
    $t = $in['time'];
    if ($t < $doctor['available_from'] || $t >= $doctor['available_to']) {
        json_error('That time is outside the doctor\'s consulting hours.', 422, [
            'time' => 'Outside consulting hours.',
        ]);
    }

    // §5 concurrency. See the double-booking note in this file's header: there
    // is no unique index on the slot, so the transaction below IS the guard,
    // not a friendly-message optimisation in front of one.
    $pdo->beginTransaction();

    try {
        // FOR UPDATE is what makes this safe. The lock is held until commit, so
        // a second request for the same slot blocks here, then sees the row the
        // first one inserted and returns 409 instead of a duplicate booking.
        //
        // Note this locks a gap rather than an existing row (usually no row
        // matches yet), which InnoDB handles under REPEATABLE READ — the
        // default on your MariaDB install.
        $slot = $pdo->prepare(
            "SELECT id FROM appointments
              WHERE doctor_id = ? AND appointment_date = ? AND appointment_time = ?
                AND status <> 'cancelled'
              LIMIT 1 FOR UPDATE"
        );
        $slot->execute([$in['doctor_id'], $in['date'], $in['time']]);
        if ($slot->fetch()) {
            $pdo->rollBack();
            json_error('That time slot has just been taken. Please choose another.', 409, [
                'time' => 'Slot no longer available.',
            ]);
        }

        // Separate rule: the same patient may not hold two live appointments
        // with the same doctor on one day, even at different times.
        $dup = $pdo->prepare(
            "SELECT id FROM appointments
              WHERE patient_id = ? AND doctor_id = ? AND appointment_date = ?
                AND status IN ('pending','confirmed') LIMIT 1 FOR UPDATE"
        );
        $dup->execute([$user['id'], $in['doctor_id'], $in['date']]);
        if ($dup->fetch()) {
            $pdo->rollBack();
            json_error('You already have an appointment with this doctor on that date.', 409);
        }

        // `fee` is snapshotted from the doctor now, so a later fee change does
        // not silently rewrite what this patient was quoted.
        $fee = (float) $doctor['consultation_fee'];

        $stmt = $pdo->prepare(
            "INSERT INTO appointments
                (patient_id, doctor_id, appointment_date, appointment_time,
                 type, symptoms, fee, status, payment_status)
             VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 'pending')"
        );
        $stmt->execute([
            $user['id'],
            $in['doctor_id'],
            $in['date'],
            $in['time'],
            $in['type'] ?? 'new',
            $in['reason'] ?? null,
            $fee,
        ]);
        $apptId = (int) $pdo->lastInsertId();

        // NO payments row is created here.
        //
        // `payments` requires a payment_method from a fixed enum and represents
        // a payment the patient actually submitted, awaiting admin verification.
        // Inserting a placeholder row would mean inventing a method and would
        // show up in the site's payment reports as a real pending payment.
        // The unpaid state already lives on appointments.payment_status.

        // In-app notification so the bell badge is correct immediately.
        $pdo->prepare(
            "INSERT INTO notifications (user_id, title, body, type, route, ref_id)
             VALUES (?, ?, ?, 'appointment', '/appointments', ?)"
        )->execute([
            $user['id'],
            'Appointment requested',
            'Your appointment request for ' . $in['date'] . ' at ' . $in['time'] . ' has been received.',
            $apptId,
        ]);

        $pdo->commit();
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }

    $fetch = $pdo->prepare(appointment_select_sql() . ' WHERE a.id = ?');
    $fetch->execute([$apptId]);

    json_ok(
        ['appointment' => appointment_public($fetch->fetch())],
        'Appointment booked successfully.',
        null,
        201
    );
}

/**
 * GET /appointments/my?status&page&limit — scoped to caller role (§6).
 * patient → their own; doctor → their queue; admin → everything.
 */
function appointments_my(): void
{
    $user = require_auth();
    [$page, $limit, $offset] = paging();

    $where  = [];
    $params = [];

    switch ($user['role']) {
        case 'patient':
            $where[]  = 'a.patient_id = ?';
            $params[] = $user['id'];
            break;

        case 'doctor':
            // Resolve the doctors row for this login; a doctor with no row sees
            // an empty list rather than an error.
            $ds = db()->prepare('SELECT id FROM doctors WHERE user_id = ? LIMIT 1');
            $ds->execute([$user['id']]);
            $docId = $ds->fetchColumn();
            if ($docId === false) {
                json_ok(['appointments' => []], 'OK', meta_page($page, $limit, 0));
            }
            $where[]  = 'a.doctor_id = ?';
            $params[] = (int) $docId;
            break;

        // Clinic and hospital scoping is NAME-BASED, and that is a limitation of
        // the live schema, not a shortcut. `doctors` has no clinic_id or
        // hospital_id — a doctor's workplace is the free-text column
        // `hospital_clinic_name`. So the only link available is an exact match
        // between that text and the facility's own `name`.
        //
        // Consequence to be aware of: a doctor who typed "Square Hospital Ltd."
        // will not appear under a facility registered as "Square Hospital", and
        // two facilities sharing a name would see each other's appointments.
        // The list is therefore best-effort. A real fix is a clinic_id /
        // hospital_id FK on `doctors`, which would need the website's doctor
        // profile form to change too, so it is out of scope here.
        case 'clinic':
        case 'hospital':
            $table = $user['role'] === 'clinic' ? 'clinics' : 'hospitals';
            $fs = db()->prepare("SELECT name FROM {$table} WHERE user_id = ? LIMIT 1");
            $fs->execute([$user['id']]);
            $facility = $fs->fetchColumn();
            if ($facility === false || trim((string) $facility) === '') {
                // No facility row, or an unnamed one: empty list, not an error.
                json_ok(['appointments' => []], 'OK', meta_page($page, $limit, 0));
            }
            $where[]  = 'd.hospital_clinic_name = ?';
            $params[] = $facility;
            break;

        case 'admin':
            break;   // no scope filter

        default:
            json_error('This role has no appointment list.', 403);
    }

    if ($status = q('status')) {
        if (!in_array($status, ['pending', 'confirmed', 'completed', 'cancelled'], true)) {
            json_error('Invalid status filter.', 400, ['status' => 'Unknown status.']);
        }
        $where[]  = 'a.status = ?';
        $params[] = $status;
    }
    if ($from = q('from')) {
        $where[]  = 'a.appointment_date >= ?';
        $params[] = $from;
    }
    if ($to = q('to')) {
        $where[]  = 'a.appointment_date <= ?';
        $params[] = $to;
    }

    $whereSql = empty($where) ? '' : 'WHERE ' . implode(' AND ', $where);

    // The join list must match `appointment_select_sql()` exactly, or the count
    // and the rows disagree: a total that counts appointments the list then
    // drops leaves a last page that renders empty. LEFT, for the same reason it
    // is LEFT there. The join is still required — clinic/hospital scoping
    // filters on `d.hospital_clinic_name`, and for those roles a NULL doctor
    // fails that comparison and drops out of both queries alike.
    $cs = db()->prepare(
        "SELECT COUNT(*) FROM appointments a LEFT JOIN doctors d ON d.id = a.doctor_id $whereSql"
    );
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

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

/** POST /appointments/cancel {appointment_id} */
function appointments_cancel(): void
{
    $user = require_auth();

    $in = validate(json_body(), ['appointment_id' => 'required|int']);

    $pdo = db();
    $stmt = $pdo->prepare('SELECT * FROM appointments WHERE id = ? LIMIT 1');
    $stmt->execute([$in['appointment_id']]);
    $appt = $stmt->fetch();

    if (!$appt) {
        json_error('Appointment not found.', 404);
    }

    // Ownership: the patient who booked it, the doctor who owns the slot, or admin.
    $allowed = false;
    if ($user['role'] === 'admin') {
        $allowed = true;
    } elseif ((int) $appt['patient_id'] === (int) $user['id']) {
        $allowed = true;
    } elseif ($user['role'] === 'doctor') {
        $ds = $pdo->prepare('SELECT id FROM doctors WHERE user_id = ? LIMIT 1');
        $ds->execute([$user['id']]);
        $allowed = (int) $ds->fetchColumn() === (int) $appt['doctor_id'];
    }

    if (!$allowed) {
        json_error('You cannot cancel this appointment.', 403);
    }

    if ($appt['status'] === 'cancelled') {
        json_error('This appointment is already cancelled.', 422);
    }
    if ($appt['status'] === 'completed') {
        json_error('A completed appointment cannot be cancelled.', 422);
    }

    $pdo->prepare('UPDATE appointments SET status = "cancelled" WHERE id = ?')
        ->execute([$in['appointment_id']]);

    // Refund marker only — no gateway call (§8).
    //
    // Two places record payment state and both must move:
    //   * appointments.payment_status  enum('pending','paid','refunded')
    //   * payments.payment_status      enum('pending','verified','rejected')
    // Note the enums are NOT the same list. `payments` has no 'refunded' value,
    // so a verified payment cannot be marked refunded there without altering the
    // enum — which would touch a column the website already reads. The refund is
    // therefore recorded on the appointment, and the payments row is left as the
    // historical record of a payment that was genuinely verified.
    if ($appt['payment_status'] === 'paid') {
        $pdo->prepare('UPDATE appointments SET payment_status = "refunded" WHERE id = ?')
            ->execute([$in['appointment_id']]);
    }

    $pdo->prepare(
        'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
         VALUES (?, ?, ?, "appointment", "/appointments", ?)'
    )->execute([
        (int) $appt['patient_id'],
        'Appointment cancelled',
        'Your appointment on ' . $appt['appointment_date'] . ' has been cancelled.',
        (int) $appt['id'],
    ]);

    audit((int) $user['id'], 'cancel', 'appointments', (int) $appt['id']);

    $fetch = $pdo->prepare(appointment_select_sql() . ' WHERE a.id = ?');
    $fetch->execute([$in['appointment_id']]);

    json_ok(
        ['appointment' => appointment_public($fetch->fetch())],
        'Appointment cancelled.'
    );
}

/**
 * POST /appointments/payment {appointment_id,method,transaction_ref?,sender_number?}
 * §6: "updates payment + appointment view together" — one transaction.
 *
 * WHAT THIS DOES NOT DO — read before changing it.
 * It does not mark the appointment paid. On the live site a payment is a
 * SUBMISSION that an admin verifies by hand: the patient sends money via bKash
 * or similar, types the transaction id, and someone in the admin panel checks it
 * against the merchant statement and sets payments.payment_status = 'verified'
 * plus appointments.payment_status = 'paid' / payment_verified_by / _at.
 *
 * If the app flipped appointments.payment_status to 'paid' here, anyone could
 * mark their own appointment paid by typing a made-up transaction id, and the
 * site's payment reports would show revenue that never arrived. So this endpoint
 * writes a 'pending' payments row and leaves verification to the admin panel.
 *
 * The two enums are different lists and easy to confuse:
 *     appointments.payment_status  pending | paid    | refunded
 *     payments.payment_status      pending | verified | rejected
 */
function appointments_payment(): void
{
    $user = require_auth();

    // Method values are the live enum, exact casing included. 'bKash' with a
    // lowercase b and 'Credit/Debit Card' with the slash are what the column
    // accepts; anything else is rejected by MySQL as a truncated-data error, so
    // the whitelist here has to match character for character.
    $in = validate(json_body(), [
        'appointment_id'  => 'required|int',
        'method'          => 'required|in:bKash,Nagad,Rocket,Credit/Debit Card,Bank Transfer,Cash',
        'transaction_ref' => 'max:100',
        'sender_number'   => 'max:20',
        'notes'           => 'max:500',
    ]);

    $pdo = db();

    $stmt = $pdo->prepare('SELECT * FROM appointments WHERE id = ? LIMIT 1');
    $stmt->execute([$in['appointment_id']]);
    $appt = $stmt->fetch();

    if (!$appt) {
        json_error('Appointment not found.', 404);
    }
    if ((int) $appt['patient_id'] !== (int) $user['id'] && $user['role'] !== 'admin') {
        json_error('You cannot pay for this appointment.', 403);
    }
    if ($appt['status'] === 'cancelled') {
        json_error('Cannot pay for a cancelled appointment.', 422);
    }
    if ($appt['payment_status'] === 'paid') {
        json_error('This appointment is already paid.', 422);
    }

    // Every method except Cash needs a reference an admin can actually check
    // against a statement. Enforced here rather than in the rule string because
    // it depends on another field's value.
    if ($in['method'] !== 'Cash' && empty($in['transaction_ref'])) {
        json_error('A transaction ID is required for this payment method.', 422, [
            'transaction_ref' => 'Enter the transaction ID from your payment receipt.',
        ]);
    }

    $pdo->beginTransaction();

    try {
        // Latest submission for this appointment. `payments` has no UNIQUE on
        // appointment_id, so ORDER BY id DESC is what "current" means.
        $ps = $pdo->prepare(
            'SELECT * FROM payments WHERE appointment_id = ? ORDER BY id DESC LIMIT 1'
        );
        $ps->execute([$in['appointment_id']]);
        $payment = $ps->fetch();

        if ($payment && $payment['payment_status'] === 'verified') {
            $pdo->rollBack();
            json_error('This payment has already been verified.', 422);
        }
        if ($payment && $payment['payment_status'] === 'pending') {
            $pdo->rollBack();
            json_error(
                'A payment for this appointment is already awaiting verification.',
                409,
                ['transaction_ref' => 'Please wait for the current submission to be reviewed.']
            );
        }

        // A rejected submission may be replaced. Insert rather than update, so the
        // rejected attempt survives as history for whoever reviews the next one.
        $fs = $pdo->prepare('SELECT consultation_fee FROM doctors WHERE id = ? LIMIT 1');
        $fs->execute([(int) $appt['doctor_id']]);
        $fee = (float) $appt['fee'] > 0
            ? (float) $appt['fee']
            : (float) ($fs->fetchColumn() ?: 0);

        $pdo->prepare(
            'INSERT INTO payments
                (appointment_id, user_id, amount, payment_method,
                 transaction_id, sender_number, payment_status, notes)
             VALUES (?, ?, ?, ?, ?, ?, "pending", ?)'
        )->execute([
            $in['appointment_id'],
            (int) $appt['patient_id'],
            $fee,
            $in['method'],
            $in['transaction_ref'] ?? null,
            $in['sender_number'] ?? null,
            $in['notes'] ?? null,
        ]);

        // appointments.payment_status stays 'pending' on purpose — see the note in
        // this function's docblock. Only the admin panel moves it to 'paid'.

        $pdo->prepare(
            'INSERT INTO notifications (user_id, title, body, type, route, ref_id)
             VALUES (?, ?, ?, "payment", "/appointments", ?)'
        )->execute([
            (int) $appt['patient_id'],
            'Payment submitted',
            'Your payment details were received and are awaiting verification.',
            (int) $appt['id'],
        ]);

        $pdo->commit();
    } catch (Throwable $e) {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
        throw $e;
    }

    audit((int) $user['id'], 'payment', 'appointments', (int) $appt['id'], ['method' => $in['method']]);

    $fetch = $pdo->prepare(appointment_select_sql() . ' WHERE a.id = ?');
    $fetch->execute([$in['appointment_id']]);

    json_ok(
        ['appointment' => appointment_public($fetch->fetch())],
        'Payment submitted. It will be confirmed once verified.'
    );
}

/** GET /appointments/payments — payment history for the caller. */
function appointments_payment_history(): void
{
    $user = require_auth();
    [$page, $limit, $offset] = paging();

    $scope  = $user['role'] === 'admin' ? '' : 'WHERE a.patient_id = ?';
    $params = $user['role'] === 'admin' ? [] : [$user['id']];

    $cs = db()->prepare(
        "SELECT COUNT(*) FROM payments p JOIN appointments a ON a.id = p.appointment_id $scope"
    );
    $cs->execute($params);
    $total = (int) $cs->fetchColumn();

    $stmt = db()->prepare(
        "SELECT p.*, a.appointment_date, a.appointment_time, a.status AS appointment_status,
                u.name AS doctor_name, d.specialization
           FROM payments p
           JOIN appointments a ON a.id = p.appointment_id
           LEFT JOIN doctors d ON d.id = a.doctor_id
           LEFT JOIN users u   ON u.id = d.user_id
         $scope
         ORDER BY p.created_at DESC
         LIMIT $limit OFFSET $offset"
    );
    $stmt->execute($params);

    // The app-facing keys stay as they were (`method`, `status`, `transaction_ref`)
    // so the Dart Payment model does not need to change; only the columns they are
    // read from moved. `verified_at` replaces the invented `paid_at` and is null
    // until an admin approves the submission — which is the honest answer, since
    // before that no money is confirmed to have arrived.
    //
    // Every column is read with `??`, and two of them genuinely need it:
    // `verified_at` and `rejection_reason` are added by migration_v2.sql, so on a
    // database where that has not been run yet the keys are simply absent. The
    // front controller promotes an "Undefined array key" notice to an exception,
    // which would 500 the entire payment history rather than leave one field
    // empty. The rest are guarded on the same principle — a column that drifts
    // should cost its own value and nothing else.
    $rows = array_map(static fn($r) => [
        'id'                 => (int) ($r['id'] ?? 0),
        'appointment_id'     => (int) ($r['appointment_id'] ?? 0),
        'amount'             => (float) ($r['amount'] ?? 0),
        'method'             => $r['payment_method'] ?? null,
        'status'             => $r['payment_status'] ?? 'pending',
        'transaction_ref'    => $r['transaction_id'] ?? null,
        'sender_number'      => $r['sender_number'] ?? null,
        'paid_at'            => $r['verified_at'] ?? null,
        'rejection_reason'   => $r['rejection_reason'] ?? null,
        'created_at'         => $r['created_at'] ?? null,
        'appointment_date'   => $r['appointment_date'] ?? null,
        'appointment_time'   => $r['appointment_time'] ?? null,
        'appointment_status' => $r['appointment_status'] ?? null,
        'doctor_name'        => $r['doctor_name'] ?? null,
        'doctor_specialty'   => $r['specialization'] ?? null,
    ], $stmt->fetchAll());

    json_ok(['payments' => $rows], 'OK', meta_page($page, $limit, $total));
}


//hello world 