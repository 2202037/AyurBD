<?php
/**
 * §6 response envelope + status codes. Every endpoint returns through here so
 * the Flutter ApiClient can rely on exactly one shape.
 *
 *  success: {success:true,  message, data:{}, meta?:{page,limit,total}}
 *  error:   {success:false, message, errors:{}}
 */

declare(strict_types=1);

/**
 * @param mixed                    $data
 * @param array<string,mixed>|null $meta
 */
function json_ok($data = null, string $message = 'OK', ?array $meta = null, int $code = 200): void
{
    http_response_code($code);

    $body = [
        'success' => true,
        'message' => $message,
        // Empty object rather than empty array — keeps `data` a map in JSON so
        // Dart can cast to Map<String,dynamic> without a type check.
        'data'    => $data ?? new stdClass(),
    ];
    if ($meta !== null) {
        $body['meta'] = $meta;
    }

    echo json_encode($body, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/**
 * @param array<string,string> $errors  Field-keyed validation messages.
 */
function json_error(string $message, int $code = 400, array $errors = []): void
{
    http_response_code($code);

    echo json_encode([
        'success' => false,
        'message' => $message,
        'errors'  => empty($errors) ? new stdClass() : $errors,
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}

/** Pagination meta block for list endpoints. */
function meta_page(int $page, int $limit, int $total): array
{
    return [
        'page'        => $page,
        'limit'       => $limit,
        'total'       => $total,
        'total_pages' => $limit > 0 ? (int) ceil($total / $limit) : 0,
    ];
}
