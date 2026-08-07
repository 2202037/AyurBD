<?php
/**
 * Auth + role guards + audit logging.
 *
 * Status code contract (§6):
 *   401 — missing/invalid/expired token, or user no longer active
 *   403 — valid token, wrong role
 */

declare(strict_types=1);

require_once __DIR__ . '/jwt.php';
require_once __DIR__ . '/response.php';
require_once __DIR__ . '/../config/database.php';

/** Pull the bearer token out of the request, tolerating server quirks. */
function bearer_token(): ?string
{
    $header = $_SERVER['HTTP_AUTHORIZATION'] ?? $_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '';

    if ($header === '' && function_exists('apache_request_headers')) {
        // Some Apache configs strip Authorization from $_SERVER.
        foreach (apache_request_headers() as $k => $v) {
            if (strcasecmp($k, 'Authorization') === 0) {
                $header = $v;
                break;
            }
        }
    }

    if (preg_match('/Bearer\s+(\S+)/i', $header, $m)) {
        return $m[1];
    }

    return null;
}

/**
 * Resolve the caller, or null if unauthenticated. Use for optional-auth routes.
 *
 * @return array<string,mixed>|null
 */
function current_user(): ?array
{
    static $cached = null;
    static $resolved = false;

    if ($resolved) {
        return $cached;
    }
    $resolved = true;

    $token = bearer_token();
    if ($token === null) {
        return $cached = null;
    }

    $claims = jwt_decode_token($token);
    if ($claims === null || !isset($claims['sub'])) {
        return $cached = null;
    }

    // No is_active column here, and none is wanted — see the matching note in
    // auth.php and database/migration_v1.sql. Selecting it would have made every
    // authenticated request fail, because the live `users` table has no such
    // column. A deleted user simply has no row, and the !$user check covers that.
    $stmt = db()->prepare(
        'SELECT id, name, email, phone, gender, role, profile_image, address
           FROM users WHERE id = ? LIMIT 1'
    );
    $stmt->execute([(int) $claims['sub']]);
    $user = $stmt->fetch();

    if (!$user) {
        return $cached = null;
    }

    return $cached = $user;
}

/**
 * Require a logged-in caller. Halts with 401 if absent.
 *
 * @return array<string,mixed>
 */
function require_auth(): array
{
    $user = current_user();
    if ($user === null) {
        json_error('Authentication required.', 401);
    }

    return $user;
}

/**
 * Require one of the given roles. Halts 401 if unauthenticated, 403 if wrong role.
 *
 * @param string[] $roles
 * @return array<string,mixed>
 */
function require_role(array $roles): array
{
    $user = require_auth();

    if (!in_array($user['role'], $roles, true)) {
        json_error('You do not have permission to perform this action.', 403);
    }

    return $user;
}

/**
 * §5/§12: write on every sensitive mutation. Never let an audit failure break
 * the request the user actually made — log and move on.
 *
 * @param array<string,mixed>|null $details
 */
function audit(?int $userId, string $action, string $entity, ?int $entityId = null, ?array $details = null): void
{
    try {
        // app_audit_log, NOT the live site's `audit_log`.
        // `audit_log` is written by database triggers and stores row diffs
        // (table_name / record_id / old_values / new_values). App-level events
        // like login and logout change no row, so they have no record_id to
        // report and would pollute a log the website already reads. They go in
        // their own table instead; the triggers keep capturing the app's
        // appointment and blood-request writes automatically.
        $stmt = db()->prepare(
            'INSERT INTO app_audit_log (user_id, action, entity, entity_id, details, ip_address)
             VALUES (?, ?, ?, ?, ?, ?)'
        );
        $stmt->execute([
            $userId,
            $action,
            $entity,
            $entityId,
            $details === null ? null : json_encode($details, JSON_UNESCAPED_UNICODE),
            $_SERVER['REMOTE_ADDR'] ?? null,
        ]);
    } catch (Throwable $e) {
        error_log('[ayur][audit] ' . $e->getMessage());
    }
}

/**
 * §10: crude file-based rate limit for auth endpoints. Good enough for XAMPP/LAN.
 * Swap for Redis or a DB counter in production.
 */
function rate_limit(string $bucket, ?int $max = null, ?int $window = null): void
{
    $max    = $max ?? RATE_LIMIT_ATTEMPTS;
    $window = $window ?? RATE_LIMIT_WINDOW;
    $ip     = $_SERVER['REMOTE_ADDR'] ?? 'unknown';

    $file = sys_get_temp_dir() . '/ayur_rl_' . md5($bucket . '|' . $ip) . '.json';
    $now  = time();

    $hits = [];
    if (is_readable($file)) {
        $decoded = json_decode((string) file_get_contents($file), true);
        if (is_array($decoded)) {
            $hits = $decoded;
        }
    }

    // Drop timestamps outside the window.
    $hits = array_values(array_filter($hits, static fn($t) => ($now - (int) $t) < $window));

    if (count($hits) >= $max) {
        header('Retry-After: ' . $window);
        json_error('Too many attempts. Please try again in a few minutes.', 429);
    }

    $hits[] = $now;
    @file_put_contents($file, json_encode($hits), LOCK_EX);
}
