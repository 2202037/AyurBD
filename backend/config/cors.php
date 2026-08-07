<?php
/**
 * CORS + JSON content negotiation. Included once by the front controller.
 */

declare(strict_types=1);

require_once __DIR__ . '/config.php';

function apply_cors(): void
{
    $origin = $_SERVER['HTTP_ORIGIN'] ?? '';

    if (in_array('*', CORS_ALLOWED_ORIGINS, true)) {
        header('Access-Control-Allow-Origin: *');
    } elseif ($origin !== '' && in_array($origin, CORS_ALLOWED_ORIGINS, true)) {
        header('Access-Control-Allow-Origin: ' . $origin);
        header('Vary: Origin');
    }

    header('Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Requested-With');
    header('Access-Control-Max-Age: 86400');
    header('Content-Type: application/json; charset=utf-8');

    // Preflight ends here — never reaches a route handler.
    if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'OPTIONS') {
        http_response_code(204);
        exit;
    }
}
