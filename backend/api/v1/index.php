<?php
/**
 * AYUR API v1 — front controller.
 *
 * Every request enters here (see .htaccess). Routes are matched on
 * METHOD + path, then dispatched to a handler function in the feature files.
 *
 * §6: versioned additions only — do not change existing v1 behaviour.
 */

declare(strict_types=1);

require_once __DIR__ . '/../../config/cors.php';
require_once __DIR__ . '/../../config/database.php';
require_once __DIR__ . '/../../helpers/response.php';
require_once __DIR__ . '/../../helpers/validator.php';
require_once __DIR__ . '/../../helpers/auth.php';
require_once __DIR__ . '/../../helpers/schema.php';

apply_cors();

// Unexpected failures must still return the §6 error envelope, never HTML.
set_exception_handler(static function (Throwable $e): void {
    error_log('[ayur][500] ' . $e->getMessage() . ' @ ' . $e->getFile() . ':' . $e->getLine());
    json_error(
        APP_DEBUG ? 'Server error: ' . $e->getMessage() : 'An unexpected server error occurred.',
        500
    );
});

set_error_handler(static function (int $no, string $str, string $file, int $line): bool {
    throw new ErrorException($str, 0, $no, $file, $line);
});

// ---------------------------------------------------------------------
// Resolve the path relative to this API root, so the app works whether it
// sits at /ayur/backend/api/v1/... or at a vhost root.
// ---------------------------------------------------------------------
$uri  = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$base = rtrim(str_replace('\\', '/', dirname($_SERVER['SCRIPT_NAME'] ?? '')), '/');

$path = $uri;
if ($base !== '' && str_starts_with($uri, $base)) {
    $path = substr($uri, strlen($base));
}
$path   = '/' . trim($path, '/');
$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');

// Feature handlers
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/directory.php';
require_once __DIR__ . '/appointments.php';
require_once __DIR__ . '/blood_bank.php';
require_once __DIR__ . '/pharmacy.php';
require_once __DIR__ . '/notifications.php';
require_once __DIR__ . '/content.php';
require_once __DIR__ . '/patient.php';
require_once __DIR__ . '/provider.php';
require_once __DIR__ . '/admin.php';

// ---------------------------------------------------------------------
// Route table.  'METHOD /path' => callable
// {id} / {slug} become regex captures passed to the handler in order.
// ---------------------------------------------------------------------
$routes = [
    // Health — handy for confirming the base URL from a phone browser.
    'GET /health'                     => 'route_health',

    // Auth (§6 Existing)
    'POST /auth/login'                => 'auth_login',
    'POST /auth/register'             => 'auth_register',
    'GET /auth/profile'               => 'auth_profile_get',
    'PUT /auth/profile'               => 'auth_profile_update',
    'POST /auth/logout'               => 'auth_logout',
    'POST /auth/refresh'              => 'auth_refresh',
    'POST /auth/change-password'      => 'auth_change_password',

    // Directory (§6 — hospitals/pharmacies marked NEW)
    'GET /directory/doctors'          => 'directory_doctors',
    'GET /directory/doctors/{id}'     => 'directory_doctor_detail',
    'GET /directory/clinics'          => 'directory_clinics',
    'GET /directory/clinics/{id}'     => 'directory_clinic_detail',
    'GET /directory/hospitals'        => 'directory_hospitals',
    'GET /directory/hospitals/{id}'   => 'directory_hospital_detail',
    'GET /directory/pharmacies'       => 'directory_pharmacies',
    'GET /directory/pharmacies/{id}'  => 'directory_pharmacy_detail',
    'GET /directory/specialties'      => 'directory_specialties',

    // Appointments
    'POST /appointments/book'         => 'appointments_book',
    'GET /appointments/my'            => 'appointments_my',
    'GET /appointments/slots'         => 'appointments_slots',
    'POST /appointments/cancel'       => 'appointments_cancel',
    'POST /appointments/payment'      => 'appointments_payment',
    'GET /appointments/payments'      => 'appointments_payment_history',

    // Blood bank
    'GET /blood_bank/inventory'       => 'blood_inventory_list',
    'POST /blood_bank/request'        => 'blood_request_create',
    'GET /blood_bank/requests'        => 'blood_request_list',
    'GET /blood_bank/nearby'          => 'blood_nearby',
    'GET /blood_bank/donors'          => 'blood_donors_list',
    'POST /blood_bank/donor'          => 'blood_donor_register',

    // Pharmacy
    'GET /pharmacy/products'          => 'pharmacy_products',
    'GET /pharmacy/products/{id}'     => 'pharmacy_product_detail',
    'GET /pharmacy/categories'        => 'pharmacy_categories',
    'GET /pharmacy/cart'              => 'pharmacy_cart_get',
    'POST /pharmacy/cart/add'         => 'pharmacy_cart_add',
    'POST /pharmacy/cart/update'      => 'pharmacy_cart_update',
    'POST /pharmacy/cart/remove'      => 'pharmacy_cart_remove',
    'POST /pharmacy/checkout'         => 'pharmacy_checkout',
    'GET /pharmacy/orders'            => 'pharmacy_orders',
    'GET /pharmacy/orders/{id}'       => 'pharmacy_order_detail',

    // Notifications
    'GET /notifications/my'           => 'notifications_my',
    'POST /notifications/{id}/read'   => 'notifications_mark_read',
    'POST /notifications/read-all'    => 'notifications_mark_all_read',
    'POST /notifications/fcm'         => 'notifications_register_token',

    // Content: blog / reviews / feedback
    'GET /blog'                       => 'blog_list',
    'GET /blog/{slug}'                => 'blog_detail',
    'GET /reviews'                    => 'reviews_list',
    'POST /reviews'                   => 'reviews_create',
    'POST /feedback'                  => 'feedback_create',

    // Patient area (§5)
    'GET /patient/dashboard'          => 'patient_dashboard',
    'GET /patient/reviews'            => 'patient_reviews',

    // Emergency + nearby (§5.8, §5.9) — deliberately public
    'GET /emergency/hotlines'         => 'emergency_hotlines',
    'POST /emergency/sms'             => 'emergency_sms_send',
    'GET /nearby'                     => 'nearby_search',

    // Doctor provider area (§6)
    'GET /provider/doctor/dashboard'         => 'provider_doctor_dashboard',
    'GET /provider/doctor/appointments'      => 'provider_doctor_appointments',
    'POST /provider/doctor/appointments/status' => 'provider_doctor_appointment_status',
    'GET /provider/doctor/payments'          => 'provider_doctor_payments',
    'POST /provider/doctor/payments/verify'  => 'provider_doctor_payment_verify',
    'PUT /provider/doctor/profile'           => 'provider_doctor_profile_update',

    // Hospital / clinic / pharmacy provider area (§7–9). One pair of routes
    // serves all three: the handler resolves which from the caller's role.
    'GET /provider/place/dashboard'   => 'provider_place_dashboard',
    'PUT /provider/place/profile'     => 'provider_place_profile_update',
    'GET /provider/reviews'           => 'provider_reviews',

    // Admin (§10)
    'GET /admin/dashboard'                     => 'admin_dashboard',
    'GET /admin/users'                         => 'admin_users',
    'POST /admin/users/delete'                 => 'admin_user_delete',
    'GET /admin/providers/{slug}'              => 'admin_providers',
    'POST /admin/providers/{slug}/moderate'    => 'admin_provider_moderate',
    'GET /admin/appointments'                  => 'admin_appointments',
    'GET /admin/reviews'                       => 'admin_reviews',
    'POST /admin/reviews/moderate'             => 'admin_review_moderate',
    'GET /admin/feedback'                      => 'admin_feedback',
    'POST /admin/feedback/update'              => 'admin_feedback_update',
    'GET /admin/blood-banks'                   => 'admin_blood_banks',
    'POST /admin/blood-banks/save'             => 'admin_blood_bank_save',
    'POST /admin/blood-banks/delete'           => 'admin_blood_bank_delete',
    'GET /admin/blogs'                         => 'admin_blogs',
    'POST /admin/blogs/save'                   => 'admin_blog_save',
    'POST /admin/blogs/delete'                 => 'admin_blog_delete',
    'GET /admin/audit-log'                     => 'admin_audit_log',
    'GET /admin/payments'                      => 'admin_payments',
];

function route_health(): void
{
    json_ok([
        'status'    => 'ok',
        'api'       => 'ayur-v1',
        'time'      => date('c'),
        'db'        => 'connected',
        'php'       => PHP_VERSION,
    ], 'AYUR API is running.');
}

// ---------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------
$key = "$method $path";

// 1. Exact match (fast path)
if (isset($routes[$key])) {
    // Touch the DB early so /health reports honestly and a misconfigured
    // connection fails with 500 + envelope rather than mid-handler.
    db();
    $routes[$key]();
    exit;
}

// 2. Pattern match for {id}/{slug} routes
foreach ($routes as $route => $handler) {
    [$rMethod, $rPath] = explode(' ', $route, 2);
    if ($rMethod !== $method || !str_contains($rPath, '{')) {
        continue;
    }

    $regex = '#^' . preg_replace(
        ['/\\\{id\\\}/', '/\\\{slug\\\}/'],
        ['(\d+)', '([A-Za-z0-9\-_]+)'],
        preg_quote($rPath, '#')
    ) . '$#';

    if (preg_match($regex, $path, $m)) {
        db();
        $handler(...array_slice($m, 1));
        exit;
    }
}

// 3. Nothing matched — distinguish "wrong method" from "no such route" so
// client-side mistakes are easier to debug.
$allowed = [];
foreach ($routes as $route => $_) {
    [$rMethod, $rPath] = explode(' ', $route, 2);
    $regex = '#^' . preg_replace(
        ['/\\\{id\\\}/', '/\\\{slug\\\}/'],
        ['(\d+)', '([A-Za-z0-9\-_]+)'],
        preg_quote($rPath, '#')
    ) . '$#';
    if ($rPath === $path || preg_match($regex, $path)) {
        $allowed[] = $rMethod;
    }
}

if (!empty($allowed)) {
    header('Allow: ' . implode(', ', array_unique($allowed)));
    json_error("Method $method is not allowed for this endpoint.", 405);
}

json_error("Endpoint not found: $method $path", 404);
