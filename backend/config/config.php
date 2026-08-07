<?php
/**
 * AYUR API — application configuration.
 *
 * NOTE (§10): no secrets ship in the Flutter client; they live here, server-side.
 * For a real deployment move JWT_SECRET and DB_PASS into environment variables
 * or a .env file that is git-ignored. The defaults below are XAMPP dev defaults.
 */

declare(strict_types=1);

// ---------------------------------------------------------------------
// Database — points at the EXISTING live ayur_db. Do not recreate it.
//
// PORT 3307, not the MySQL default 3306. Taken from the phpMyAdmin dump
// header of the live database ("Host: 127.0.0.1:3307", MariaDB 10.4.32).
// If you later move MySQL back to 3306, override with the AYUR_DB_PORT env
// var rather than editing this line, so the two stay distinguishable.
// ---------------------------------------------------------------------
define('DB_HOST', getenv('AYUR_DB_HOST') ?: '127.0.0.1');
define('DB_PORT', getenv('AYUR_DB_PORT') ?: '3307');
define('DB_NAME', getenv('AYUR_DB_NAME') ?: 'ayur_db');
define('DB_USER', getenv('AYUR_DB_USER') ?: 'root');
define('DB_PASS', getenv('AYUR_DB_PASS') ?: '');

// ---------------------------------------------------------------------
// JWT (§15 Q3 — if the live PHP auth already issues tokens, replace this
// helper with the existing one and keep the same claim names.)
// ---------------------------------------------------------------------
define('JWT_SECRET', getenv('AYUR_JWT_SECRET') ?: 'change-me-in-production-a-long-random-string');
define('JWT_ISSUER', 'ayur-api');
define('JWT_TTL', 60 * 60 * 24 * 7);   // access token: 7 days
define('JWT_REFRESH_TTL', 60 * 60 * 24 * 30);

// ---------------------------------------------------------------------
// CORS (§10: limit to trusted clients). '*' is dev-only — a native Flutter
// app does not send Origin, so tightening this does not break the app.
// ---------------------------------------------------------------------
define('CORS_ALLOWED_ORIGINS', ['*']);

// ---------------------------------------------------------------------
// Behaviour
// ---------------------------------------------------------------------
define('APP_DEBUG', true);         // false in production — hides SQL errors

// ---------------------------------------------------------------------
// Fallback admin bootstrap (feature.md §4).
//
// When true, a login attempt with ADMIN_FALLBACK_EMAIL / ADMIN_FALLBACK_PASS
// CREATES that admin account if it does not already exist. This is how the
// spec describes it, and it is reproduced here on request.
//
// Understand what it means before deploying: anyone who can reach /auth/login
// can self-provision a full administrator on this database using a password
// that is written in plain text three lines below. It is a documented
// backdoor, not an accident.
//
// It is a named constant precisely so you can turn it off in one place. Set
// AYUR_ADMIN_FALLBACK=0 in the environment, or flip this to false, the moment
// this build is reachable by anyone but you. Once a real admin account exists
// the fallback never fires again, so disabling it afterwards costs nothing.
// ---------------------------------------------------------------------
define('ADMIN_FALLBACK_ENABLED', getenv('AYUR_ADMIN_FALLBACK') !== '0');
define('ADMIN_FALLBACK_EMAIL', 'admin@ayur.com');
define('ADMIN_FALLBACK_PASS', 'admin123');
define('DEFAULT_PAGE_SIZE', 20);
define('MAX_PAGE_SIZE', 100);
define('RATE_LIMIT_ATTEMPTS', 10); // §10 rate-limit auth endpoints
define('RATE_LIMIT_WINDOW', 300);  // seconds

date_default_timezone_set('Asia/Dhaka');
