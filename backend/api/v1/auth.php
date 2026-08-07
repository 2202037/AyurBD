<?php
/**
 * Auth endpoints — §6 /auth/*
 *
 * Token: HS256 JWT, claims {sub, role}. §15 Q3 — if the live site already
 * issues tokens, replace jwt_issue_for_user() and keep these response shapes.
 */

declare(strict_types=1);

/**
 * Shape a users row into the §6 user object. Password never leaves this layer.
 *
 * @param array<string,mixed> $row
 * @return array<string,mixed>
 */
function user_public(array $row): array
{
    return [
        'id'            => (int) $row['id'],
        'name'          => $row['name'],
        'email'         => $row['email'],
        'role'          => $row['role'],
        'phone'         => $row['phone'] ?? null,
        'profile_image' => $row['profile_image'] ?? null,
        'address'       => $row['address'] ?? null,
        'gender'        => $row['gender'] ?? null,
        // city / blood_group are added by database/migration_v1.sql. The ??
        // keeps this working if the migration has not been run yet.
        'city'          => $row['city'] ?? null,
        'blood_group'   => $row['blood_group'] ?? null,
        'created_at'    => $row['created_at'] ?? null,
    ];
}

/**
 * feature.md §4 — auto-create the fallback admin when the configured
 * credentials are used and no such account exists.
 *
 * Returns the freshly created row, or null when the fallback does not apply.
 * Guarded four ways: the feature must be enabled, the email must match
 * exactly, the password must match exactly, and NO account with that email
 * may already exist. That last one matters most — if you later change the
 * fallback admin's password, this can never resurrect the old one.
 *
 * @return array<string,mixed>|null
 */
function auth_bootstrap_fallback_admin(string $email, string $password): ?array
{
    if (!ADMIN_FALLBACK_ENABLED) {
        return null;
    }
    if (!hash_equals(ADMIN_FALLBACK_EMAIL, strtolower($email))
        || !hash_equals(ADMIN_FALLBACK_PASS, $password)) {
        return null;
    }

    $pdo = db();

    // Re-check under the same connection rather than trusting the caller's
    // earlier SELECT — two simultaneous first-logins would otherwise both
    // insert, and `users.email` may not be unique in this schema.
    $exists = $pdo->prepare('SELECT id FROM users WHERE email = ? LIMIT 1');
    $exists->execute([ADMIN_FALLBACK_EMAIL]);
    if ($exists->fetch()) {
        return null;
    }

    try {
        $pdo->prepare(
            'INSERT INTO users (name, email, password, role) VALUES (?, ?, ?, "admin")'
        )->execute([
            'Administrator',
            ADMIN_FALLBACK_EMAIL,
            password_hash(ADMIN_FALLBACK_PASS, PASSWORD_BCRYPT),
        ]);
    } catch (Throwable $e) {
        // The live `users.role` enum may not include 'admin' — the schema drift
        // called out in feature.md §14. Fail as a normal auth error rather than
        // a 500, and leave a breadcrumb explaining exactly what to widen.
        error_log('[ayur][admin-fallback] ' . $e->getMessage());

        return null;
    }

    $id = (int) $pdo->lastInsertId();
    audit($id, 'create', 'users', $id, ['role' => 'admin', 'via' => 'fallback_bootstrap']);

    $fetch = $pdo->prepare('SELECT * FROM users WHERE id = ?');
    $fetch->execute([$id]);

    return $fetch->fetch() ?: null;
}

/**
 * POST /auth/login  {email,password,login_as?} → {token,user}
 *
 * `login_as` is the feature.md §4 role selector. It is a CHECK, never a
 * grant: the role still comes from the database row. Picking "admin" on the
 * form does not make you one — it only fails the login if you are not.
 */
function auth_login(): void
{
    rate_limit('login');   // §10

    $in = validate(json_body(), [
        'email'    => 'required|email|max:190',
        'password' => 'required|min:1|max:255',
        'login_as' => 'in:patient,doctor,hospital,clinic,pharmacy,admin',
    ]);

    $stmt = db()->prepare('SELECT * FROM users WHERE email = ? LIMIT 1');
    $stmt->execute([$in['email']]);
    $user = $stmt->fetch();

    if (!$user) {
        // feature.md §4: first login as the configured admin creates it.
        $user = auth_bootstrap_fallback_admin($in['email'], $in['password']);
    }

    // Same message for unknown email and wrong password — no account enumeration.
    if (!$user || !password_verify($in['password'], $user['password'])) {
        json_error('Incorrect email or password.', 401);
    }

    // Wrong selector is a 403, not a 401: the credentials were right, so
    // repeating them will not help — the user needs to change the dropdown.
    if (isset($in['login_as']) && $in['login_as'] !== $user['role']) {
        json_error(
            'This account is not registered as a ' . $in['login_as'] . '.',
            403,
            ['login_as' => 'Your account role is ' . $user['role'] . '.']
        );
    }

    // NOTE: there is deliberately no is_active / deactivated check here.
    // The live `users` table has no such column, and the website has no way to
    // set or clear one. Adding it app-side would let the app lock a user out
    // through a flag the admin panel cannot see. Account suspension, if it is
    // ever wanted, belongs in the website's admin panel first.

    $token = jwt_issue_for_user((int) $user['id'], $user['role']);
    audit((int) $user['id'], 'login', 'users', (int) $user['id']);

    json_ok([
        'token' => $token,
        'user'  => user_public($user),
    ], 'Signed in successfully.');
}

/**
 * Per-role extra field rules for registration (feature.md §3.2–3.5).
 *
 * These are the fields BEYOND the shared name/email/password/phone set. Every
 * one is optional at the API level even where the form marks it required —
 * validating it here as `required` would make a partially-filled provider
 * signup impossible to save, and the row is created with status 'pending'
 * anyway, so an incomplete profile is never publicly visible. The Flutter
 * forms enforce their own required-field UX on top of this.
 *
 * @return array<string,string>
 */
function auth_role_rules(string $role): array
{
    switch ($role) {
        case 'doctor':
            return [
                'gender'            => 'in:male,female,other',
                'bmdc_number'       => 'max:50',
                'bmdc_certificate'  => 'max:255',
                'specialization'    => 'max:150',
                'qualifications'    => 'max:255',
                'medical_school'    => 'max:150',
                'graduation_year'   => 'int|min:1900|max:2100',
                'experience_years'  => 'int|min:0|max:80',
                'doctor_type'       => 'max:50',
                'hospital_clinic_name' => 'max:200',
                'chamber_address'   => 'max:255',
                'area'              => 'max:100',
                'consultation_fee'  => 'numeric|min:0|max:1000000',
                'bio'               => 'max:2000',
            ];

        case 'hospital':
            return [
                'emergency_phone'    => 'phone',
                'registration_number' => 'max:100',
                'license_number'     => 'max:100',
                'license_document'   => 'max:255',
                'hospital_type'      => 'max:50',
                'established_year'   => 'int|min:1800|max:2100',
                'website'            => 'max:255',
                'area'               => 'max:100',
                'total_beds'         => 'int|min:0|max:100000',
                'icu_beds'           => 'int|min:0|max:100000',
                'facilities'         => 'max:2000',
                'departments'        => 'max:2000',
                'open_24_hours'      => 'in:0,1',
                'opening_time'       => 'time',
                'closing_time'       => 'time',
                'description'        => 'max:2000',
            ];

        case 'clinic':
            return [
                'website'            => 'max:255',
                'registration_number' => 'max:100',
                'license_number'     => 'max:100',
                'license_document'   => 'max:255',
                'clinic_type'        => 'max:50',
                'established_year'   => 'int|min:1800|max:2100',
                'area'               => 'max:100',
                'services'           => 'max:2000',
                'specializations'    => 'max:2000',
                'available_days'     => 'max:100',
                'opening_time'       => 'time',
                'closing_time'       => 'time',
                'description'        => 'max:2000',
            ];

        case 'pharmacy':
            return [
                'whatsapp'           => 'phone',
                'license_number'     => 'max:100',
                'drug_license_number' => 'max:100',
                'license_document'   => 'max:255',
                'pharmacy_type'      => 'max:50',
                'owner_name'         => 'max:150',
                'pharmacist_name'    => 'max:150',
                'pharmacist_license' => 'max:100',
                'established_year'   => 'int|min:1800|max:2100',
                'area'               => 'max:100',
                'services'           => 'max:2000',
                'delivery_available' => 'in:0,1',
                'delivery_radius_km' => 'int|min:0|max:500',
                'open_24_hours'      => 'in:0,1',
                'opening_time'       => 'time',
                'closing_time'       => 'time',
                'description'        => 'max:2000',
            ];

        default:
            return [];
    }
}

/**
 * POST /auth/register → {user,token}
 *
 * Shared fields for every role, plus the role-specific set from
 * auth_role_rules(). feature.md §3.
 */
function auth_register(): void
{
    rate_limit('register');

    $body = json_body();

    // Read the role first so the right extra rules are applied, but validate it
    // through validate() below so an unknown value is still a clean 400.
    $requested = is_string($body['role'] ?? null) ? strtolower(trim($body['role'])) : 'patient';
    $role = in_array($requested, ['doctor', 'clinic', 'pharmacy', 'hospital'], true)
        ? $requested
        : 'patient';

    $in = validate($body, [
        'name'     => 'required|min:2|max:150',
        'email'    => 'required|email|max:190',
        'password' => 'required|min:8|max:255',
        // feature.md §3.1 requires the confirmation to match. Checked below,
        // because a cross-field rule has no place in a per-field rule string.
        'password_confirm' => 'max:255',
        'phone'    => 'phone',
        // Self-registration cannot create an admin — that is admin-panel only.
        'role'     => 'in:patient,doctor,clinic,pharmacy,hospital',
        'address'  => 'max:255',
        'city'     => 'max:100',
        'gender'   => 'in:male,female,other',
    ] + auth_role_rules($role));

    // Only enforced when the client sent it — an API caller that omits the
    // field entirely is not forced into a web form's confirm-box convention.
    if (isset($in['password_confirm']) && !hash_equals($in['password'], $in['password_confirm'])) {
        json_error('The passwords do not match.', 400, [
            'password_confirm' => 'The passwords do not match.',
        ]);
    }

    $check = db()->prepare('SELECT id FROM users WHERE email = ? LIMIT 1');
    $check->execute([$in['email']]);
    if ($check->fetch()) {
        json_error('An account with this email already exists.', 409, [
            'email' => 'This email is already registered.',
        ]);
    }

    $pdo = db();
    $pdo->beginTransaction();

    try {
        $stmt = $pdo->prepare(
            'INSERT INTO users (name, email, password, phone, role, address, city, gender)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute([
            $in['name'],
            $in['email'],
            password_hash($in['password'], PASSWORD_BCRYPT),
            $in['phone'] ?? null,
            $role,
            $in['address'] ?? null,
            $in['city'] ?? null,
            $in['gender'] ?? null,
        ]);
        $userId = (int) $pdo->lastInsertId();

        // Provider roles need their directory row to exist, else they are
        // invisible to /directory/* and cannot be managed.
        //
        // The live schema marks address, city and (for pharmacies)
        // license_number NOT NULL, so those fall back to '' rather than null
        // when the form left them blank — otherwise the INSERT dies under
        // STRICT_TRANS_TABLES. Every row is left at its default status
        // 'pending' / verification_status 'pending' (feature.md §3.2–3.5), so
        // an incomplete profile never reaches the public directory.
        $addr = $in['address'] ?? '';
        $city = $in['city'] ?? '';

        // Column => value, built per role. insert_row() turns this into a
        // parameterised INSERT; keys are literals from this file, never input.
        if ($role === 'doctor') {
            insert_row($pdo, 'doctors', [
                'user_id'              => $userId,
                'bmdc_number'          => $in['bmdc_number'] ?? null,
                'bmdc_certificate'     => $in['bmdc_certificate'] ?? null,
                'specialization'       => $in['specialization'] ?? null,
                'qualifications'       => $in['qualifications'] ?? null,
                'medical_school'       => $in['medical_school'] ?? null,
                'graduation_year'      => $in['graduation_year'] ?? null,
                'experience_years'     => $in['experience_years'] ?? null,
                'doctor_type'          => $in['doctor_type'] ?? null,
                'hospital_clinic_name' => $in['hospital_clinic_name'] ?? null,
                'chamber_address'      => $in['chamber_address'] ?? null,
                'city'                 => $city,
                'area'                 => $in['area'] ?? null,
                'consultation_fee'     => $in['consultation_fee'] ?? null,
                'bio'                  => $in['bio'] ?? null,
            ]);
        } elseif ($role === 'clinic') {
            insert_row($pdo, 'clinics', [
                'user_id'             => $userId,
                'name'                => $in['name'],
                'email'               => $in['email'],
                'phone'               => $in['phone'] ?? null,
                'website'             => $in['website'] ?? null,
                'registration_number' => $in['registration_number'] ?? null,
                'license_number'      => $in['license_number'] ?? null,
                'license_document'    => $in['license_document'] ?? null,
                'clinic_type'         => $in['clinic_type'] ?? null,
                'established_year'    => $in['established_year'] ?? null,
                'address'             => $addr,
                'city'                => $city,
                'area'                => $in['area'] ?? null,
                'services'            => $in['services'] ?? null,
                'specializations'     => $in['specializations'] ?? null,
                'available_days'      => $in['available_days'] ?? null,
                'opening_time'        => $in['opening_time'] ?? null,
                'closing_time'        => $in['closing_time'] ?? null,
                'description'         => $in['description'] ?? null,
            ]);
        } elseif ($role === 'hospital') {
            insert_row($pdo, 'hospitals', [
                'user_id'             => $userId,
                'name'                => $in['name'],
                'email'               => $in['email'],
                'phone'               => $in['phone'] ?? null,
                'emergency_phone'     => $in['emergency_phone'] ?? null,
                'registration_number' => $in['registration_number'] ?? null,
                'license_number'      => $in['license_number'] ?? null,
                'license_document'    => $in['license_document'] ?? null,
                'hospital_type'       => $in['hospital_type'] ?? null,
                'established_year'    => $in['established_year'] ?? null,
                'website'             => $in['website'] ?? null,
                'address'             => $addr,
                'city'                => $city,
                'area'                => $in['area'] ?? null,
                'total_beds'          => $in['total_beds'] ?? null,
                'icu_beds'            => $in['icu_beds'] ?? null,
                'facilities'          => $in['facilities'] ?? null,
                'departments'         => $in['departments'] ?? null,
                'open_24_hours'       => isset($in['open_24_hours']) ? (int) $in['open_24_hours'] : null,
                'opening_time'        => $in['opening_time'] ?? null,
                'closing_time'        => $in['closing_time'] ?? null,
                'description'         => $in['description'] ?? null,
            ]);
        } elseif ($role === 'pharmacy') {
            insert_row($pdo, 'pharmacies', [
                'user_id'             => $userId,
                'name'                => $in['name'],
                'email'               => $in['email'],
                'phone'               => $in['phone'] ?? null,
                'whatsapp'            => $in['whatsapp'] ?? null,
                'license_number'      => $in['license_number'] ?? '',
                'drug_license_number' => $in['drug_license_number'] ?? null,
                'license_document'    => $in['license_document'] ?? null,
                'pharmacy_type'       => $in['pharmacy_type'] ?? null,
                'owner_name'          => $in['owner_name'] ?? null,
                'pharmacist_name'     => $in['pharmacist_name'] ?? null,
                'pharmacist_license'  => $in['pharmacist_license'] ?? null,
                'established_year'    => $in['established_year'] ?? null,
                'address'             => $addr,
                'city'                => $city,
                'area'                => $in['area'] ?? null,
                'services'            => $in['services'] ?? null,
                'delivery_available'  => isset($in['delivery_available']) ? (int) $in['delivery_available'] : null,
                'delivery_radius_km'  => $in['delivery_radius_km'] ?? null,
                'open_24_hours'       => isset($in['open_24_hours']) ? (int) $in['open_24_hours'] : null,
                'opening_time'        => $in['opening_time'] ?? null,
                'closing_time'        => $in['closing_time'] ?? null,
                'description'         => $in['description'] ?? null,
            ]);
        }

        $pdo->commit();
    } catch (Throwable $e) {
        $pdo->rollBack();
        throw $e;
    }

    $fetch = $pdo->prepare('SELECT * FROM users WHERE id = ?');
    $fetch->execute([$userId]);
    $user = $fetch->fetch();

    audit($userId, 'create', 'users', $userId, ['role' => $role]);

    json_ok([
        'token' => jwt_issue_for_user($userId, $role),
        'user'  => user_public($user),
    ], 'Account created successfully.', null, 201);
}

/** GET /auth/profile → {user} (+ provider profile when applicable) */
function auth_profile_get(): void
{
    $user = require_auth();
    $data = ['user' => user_public($user)];

    // Attach the role-specific row so the app can render one profile screen
    // without a second request (§6 joined payloads / avoid N+1).
    switch ($user['role']) {
        case 'doctor':
            // The live `doctors` table records the workplace as a free-text
            // `hospital_clinic_name`, not clinic_id/hospital_id foreign keys,
            // so there is nothing to join here.
            $s = db()->prepare('SELECT * FROM doctors WHERE user_id = ? LIMIT 1');
            $s->execute([$user['id']]);
            if ($row = $s->fetch()) {
                $data['doctor'] = doctor_public($row);
            }
            break;

        case 'clinic':
            $s = db()->prepare('SELECT * FROM clinics WHERE user_id = ? LIMIT 1');
            $s->execute([$user['id']]);
            if ($row = $s->fetch()) {
                $data['clinic'] = place_public($row);
            }
            break;

        case 'hospital':
            $s = db()->prepare('SELECT * FROM hospitals WHERE user_id = ? LIMIT 1');
            $s->execute([$user['id']]);
            if ($row = $s->fetch()) {
                $data['hospital'] = place_public($row);
            }
            break;

        case 'pharmacy':
            $s = db()->prepare('SELECT * FROM pharmacies WHERE user_id = ? LIMIT 1');
            $s->execute([$user['id']]);
            if ($row = $s->fetch()) {
                $data['pharmacy'] = place_public($row);
            }
            break;
    }

    json_ok($data);
}

/** PUT /auth/profile — updates only the fields present in the body. */
function auth_profile_update(): void
{
    $user = require_auth();

    $in = validate(json_body(), [
        'name'          => 'min:2|max:150',
        'phone'         => 'phone',
        'address'       => 'max:255',
        'city'          => 'max:100',
        'blood_group'   => 'in:A+,A-,B+,B-,AB+,AB-,O+,O-',
        'profile_image' => 'max:255',
    ]);

    if (empty($in)) {
        json_error('No fields to update.', 400);
    }

    // Whitelist → column names are never taken from user input.
    $allowed = ['name', 'phone', 'address', 'city', 'blood_group', 'profile_image'];
    $sets    = [];
    $params  = [];

    foreach ($allowed as $col) {
        if (array_key_exists($col, $in)) {
            $sets[]   = "$col = ?";
            $params[] = $in[$col];
        }
    }

    $params[] = $user['id'];
    db()->prepare('UPDATE users SET ' . implode(', ', $sets) . ' WHERE id = ?')->execute($params);

    audit((int) $user['id'], 'update', 'users', (int) $user['id'], array_keys($in));

    $s = db()->prepare('SELECT * FROM users WHERE id = ?');
    $s->execute([$user['id']]);

    json_ok(['user' => user_public($s->fetch())], 'Profile updated.');
}

/**
 * POST /auth/logout
 * Stateless JWT: nothing to revoke server-side. The client discards the token
 * from secure storage. Endpoint exists so the app has one call site and the
 * event lands in audit_logs.
 */
function auth_logout(): void
{
    $user = current_user();
    if ($user !== null) {
        // Drop this device's push token so a logged-out phone stops receiving.
        $body = json_body();
        if (!empty($body['fcm_token'])) {
            db()->prepare('DELETE FROM device_tokens WHERE user_id = ? AND fcm_token = ?')
                ->execute([$user['id'], $body['fcm_token']]);
        }
        audit((int) $user['id'], 'logout', 'users', (int) $user['id']);
    }

    json_ok(null, 'Signed out.');
}

/** POST /auth/refresh → new token for the current caller. */
function auth_refresh(): void
{
    $user = require_auth();

    json_ok([
        'token' => jwt_issue_for_user((int) $user['id'], $user['role']),
        'user'  => user_public($user),
    ], 'Token refreshed.');
}

/** POST /auth/change-password {current_password,new_password} */
function auth_change_password(): void
{
    $user = require_auth();
    rate_limit('change-password');

    $in = validate(json_body(), [
        'current_password' => 'required|max:255',
        'new_password'     => 'required|min:8|max:255',
    ]);

    $s = db()->prepare('SELECT password FROM users WHERE id = ?');
    $s->execute([$user['id']]);
    $row = $s->fetch();

    if (!$row || !password_verify($in['current_password'], $row['password'])) {
        json_error('Current password is incorrect.', 400, [
            'current_password' => 'Current password is incorrect.',
        ]);
    }

    db()->prepare('UPDATE users SET password = ? WHERE id = ?')
        ->execute([password_hash($in['new_password'], PASSWORD_BCRYPT), $user['id']]);

    audit((int) $user['id'], 'change_password', 'users', (int) $user['id']);

    json_ok(null, 'Password changed successfully.');
}
