<?php
/**
 * Minimal HS256 JWT — no Composer dependency, so this drops into a plain
 * XAMPP htdocs without `composer install`.
 *
 * §15 Q3: if the live AYUR PHP already issues JWTs, delete this and point
 * auth_user() at the existing verifier. Keep the claim names below either way:
 * the Flutter client only reads the opaque token string, but the API layer
 * expects `sub` (user id) and `role`.
 */

declare(strict_types=1);

require_once __DIR__ . '/../config/config.php';

function base64url_encode(string $data): string
{
    return rtrim(strtr(base64_encode($data), '+/', '-_'), '=');
}

function base64url_decode(string $data): string
{
    $pad = strlen($data) % 4;
    if ($pad > 0) {
        $data .= str_repeat('=', 4 - $pad);
    }
    return base64_decode(strtr($data, '-_', '+/')) ?: '';
}

/**
 * @param array<string,mixed> $claims
 */
function jwt_encode(array $claims, ?int $ttl = null): string
{
    $now = time();
    $payload = array_merge([
        'iss' => JWT_ISSUER,
        'iat' => $now,
        'exp' => $now + ($ttl ?? JWT_TTL),
    ], $claims);

    $h = base64url_encode(json_encode(['typ' => 'JWT', 'alg' => 'HS256'], JSON_UNESCAPED_SLASHES));
    $p = base64url_encode(json_encode($payload, JSON_UNESCAPED_SLASHES));
    $s = base64url_encode(hash_hmac('sha256', "$h.$p", JWT_SECRET, true));

    return "$h.$p.$s";
}

/**
 * Verify signature + expiry.
 *
 * @return array<string,mixed>|null  Claims on success, null on any failure.
 */
function jwt_decode_token(string $token): ?array
{
    $parts = explode('.', $token);
    if (count($parts) !== 3) {
        return null;
    }
    [$h, $p, $s] = $parts;

    $expected = base64url_encode(hash_hmac('sha256', "$h.$p", JWT_SECRET, true));
    // hash_equals: constant-time, prevents signature-timing oracles.
    if (!hash_equals($expected, $s)) {
        return null;
    }

    $claims = json_decode(base64url_decode($p), true);
    if (!is_array($claims)) {
        return null;
    }
    if (isset($claims['exp']) && time() >= (int) $claims['exp']) {
        return null;   // expired → caller returns 401 → app clears storage (§10)
    }

    return $claims;
}

function jwt_issue_for_user(int $userId, string $role): string
{
    return jwt_encode(['sub' => $userId, 'role' => $role]);
}
