<?php
/**
 * Server-side validation. §4: "PHP is the enforcement authority — never trust
 * client validation alone." The Flutter forms mirror these rules for UX only.
 */

declare(strict_types=1);

require_once __DIR__ . '/response.php';
require_once __DIR__ . '/../config/config.php';

/**
 * Read and decode the JSON request body.
 *
 * @return array<string,mixed>
 */
function json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || trim($raw) === '') {
        return [];
    }

    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        json_error('Request body must be valid JSON.', 400);
    }

    return $decoded;
}

/**
 * Rule-based validator.
 *
 * Rules: required | email | min:N | max:N | numeric | int | in:a,b,c
 *        date (Y-m-d) | time (H:i or H:i:s) | phone | image
 *
 * @param array<string,mixed>  $data
 * @param array<string,string> $rules  field => 'required|email|max:190'
 * @return array<string,mixed>         Cleaned values for the passing fields.
 */
function validate(array $data, array $rules): array
{
    $errors = [];
    $clean  = [];

    foreach ($rules as $field => $ruleStr) {
        $value    = $data[$field] ?? null;
        $ruleList = explode('|', $ruleStr);
        $isReq    = in_array('required', $ruleList, true);

        $missing = $value === null || (is_string($value) && trim($value) === '');
        if ($missing) {
            if ($isReq) {
                $errors[$field] = ucfirst(str_replace('_', ' ', $field)) . ' is required.';
            }
            continue;   // optional + absent → skip remaining rules
        }

        if (is_string($value)) {
            $value = trim($value);
        }

        foreach ($ruleList as $rule) {
            if ($rule === '' || $rule === 'required') {
                continue;
            }

            [$name, $param] = array_pad(explode(':', $rule, 2), 2, null);

            switch ($name) {
                case 'email':
                    if (!filter_var($value, FILTER_VALIDATE_EMAIL)) {
                        $errors[$field] = 'Enter a valid email address.';
                    }
                    break;

                case 'min':
                    if (is_numeric($value)) {
                        if ((float) $value < (float) $param) {
                            $errors[$field] = "Must be at least $param.";
                        }
                    } elseif (mb_strlen((string) $value) < (int) $param) {
                        $errors[$field] = "Must be at least $param characters.";
                    }
                    break;

                case 'max':
                    if (is_numeric($value)) {
                        if ((float) $value > (float) $param) {
                            $errors[$field] = "Must not exceed $param.";
                        }
                    } elseif (mb_strlen((string) $value) > (int) $param) {
                        $errors[$field] = "Must not exceed $param characters.";
                    }
                    break;

                case 'numeric':
                    if (!is_numeric($value)) {
                        $errors[$field] = 'Must be a number.';
                    }
                    break;

                case 'int':
                    if (filter_var($value, FILTER_VALIDATE_INT) === false) {
                        $errors[$field] = 'Must be a whole number.';
                    } else {
                        $value = (int) $value;
                    }
                    break;

                case 'in':
                    $allowed = explode(',', (string) $param);
                    if (!in_array((string) $value, $allowed, true)) {
                        $errors[$field] = 'Must be one of: ' . implode(', ', $allowed) . '.';
                    }
                    break;

                case 'date':
                    $d = DateTime::createFromFormat('Y-m-d', (string) $value);
                    if (!$d || $d->format('Y-m-d') !== $value) {
                        $errors[$field] = 'Must be a valid date (YYYY-MM-DD).';
                    }
                    break;

                case 'time':
                    if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/', (string) $value)) {
                        $errors[$field] = 'Must be a valid time (HH:MM).';
                    } elseif (strlen((string) $value) === 5) {
                        $value .= ':00';   // normalise to MySQL TIME
                    }
                    break;

                case 'phone':
                    if (!preg_match('/^[0-9+\-\s()]{6,30}$/', (string) $value)) {
                        $errors[$field] = 'Enter a valid phone number.';
                    }
                    break;
            }

            if (isset($errors[$field])) {
                break;   // first failure per field is enough
            }
        }

        if (!isset($errors[$field])) {
            $clean[$field] = $value;
        }
    }

    if (!empty($errors)) {
        json_error('Validation failed.', 400, $errors);
    }

    return $clean;
}

/** Clamp pagination params to sane bounds (§11: never full loads). */
function paging(): array
{
    $page  = max(1, (int) ($_GET['page'] ?? 1));
    $limit = (int) ($_GET['limit'] ?? DEFAULT_PAGE_SIZE);
    $limit = max(1, min(MAX_PAGE_SIZE, $limit));

    return [$page, $limit, ($page - 1) * $limit];
}

/** Trimmed non-empty query string param, or null. */
function q(string $key): ?string
{
    $v = $_GET[$key] ?? null;
    if ($v === null) {
        return null;
    }
    $v = trim((string) $v);

    return $v === '' ? null : $v;
}
