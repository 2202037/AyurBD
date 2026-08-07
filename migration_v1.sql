-- =====================================================================
-- AYUR — migration_v1.sql
-- Makes the existing, live `ayur_db` able to serve the Flutter app.
-- =====================================================================
--
-- SAFETY CONTRACT — read this before running.
--
-- This script is ADDITIVE ONLY. It contains:
--     * CREATE TABLE IF NOT EXISTS   (8 new tables)
--     * ALTER TABLE ... ADD COLUMN IF NOT EXISTS   (new, nullable columns
--       with defaults, on `doctors` and `users`)
--     * INSERT ... SELECT to backfill one derived value
--
-- It contains NO:
--     * DROP DATABASE / DROP TABLE / DROP COLUMN
--     * TRUNCATE / DELETE
--     * MODIFY or CHANGE of any existing column
--     * changes to any existing enum, index, trigger, or foreign key
--
-- One honest exception: there IS a single UPDATE, in section 1.1. It writes
-- ONLY to the four availability columns this script just added to `doctors`
-- (which are NULL in every row until then), and only where they are still
-- NULL. It cannot overwrite anything your website stored, because those
-- columns did not exist a moment earlier. No other column is touched.
--
-- Nothing your PHP website currently SELECTs or INSERTs changes shape, so
-- the site keeps working exactly as it does today. Every new column is
-- nullable or has a DEFAULT, so existing INSERT statements that omit them
-- continue to succeed.
--
-- Re-running this file is safe: every statement is guarded by IF NOT EXISTS.
--
-- Target: MariaDB 10.4.32 (ADD COLUMN IF NOT EXISTS is MariaDB syntax).
-- Charset/collation matched to your existing tables: utf8mb4_unicode_ci.
--
-- TAKE A BACKUP FIRST anyway. In phpMyAdmin: select ayur_db -> Export -> Go.
-- =====================================================================

-- Do NOT add "CREATE DATABASE" or "DROP DATABASE" here. The database exists.
-- In phpMyAdmin, select `ayur_db` in the left sidebar first, then Import.

SET NAMES utf8mb4;
SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";

-- =====================================================================
-- PART 1 — new columns on existing tables
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1.1  doctors: availability
--
-- Your `doctors` table has no availability data, so the app's booking
-- calendar has no slots to offer. These four columns are the minimum the
-- slot generator needs. All are nullable/defaulted, so your website's
-- existing INSERT INTO doctors (...) statements are unaffected.
--
-- available_days: comma-separated lowercase day names, e.g. "sat,sun,mon".
--                 NULL means "not configured" -> app shows no slots and
--                 tells the patient to call the chamber instead.
-- slot_minutes:   appointment length, used to walk from _from to _to.
-- ---------------------------------------------------------------------
ALTER TABLE `doctors`
  ADD COLUMN IF NOT EXISTS `available_days`  varchar(100) DEFAULT NULL COMMENT 'csv: sat,sun,mon,tue,wed,thu,fri',
  ADD COLUMN IF NOT EXISTS `available_from`  time         DEFAULT NULL COMMENT 'chamber start, e.g. 17:00:00',
  ADD COLUMN IF NOT EXISTS `available_to`    time         DEFAULT NULL COMMENT 'chamber end, e.g. 21:00:00',
  ADD COLUMN IF NOT EXISTS `slot_minutes`    int(11)      DEFAULT 30   COMMENT 'appointment length in minutes';

-- Give every already-verified, active doctor a sane default schedule so the
-- app is usable the moment it starts. Only fills rows where nothing is set;
-- never overwrites a schedule someone has configured.
-- Sat-Thu evenings is the common Bangladeshi chamber pattern; edit freely.
UPDATE `doctors`
   SET `available_days` = 'sat,sun,mon,tue,wed,thu',
       `available_from` = '17:00:00',
       `available_to`   = '21:00:00',
       `slot_minutes`   = 30
 WHERE `available_days` IS NULL
   AND `status` = 'active';

-- ---------------------------------------------------------------------
-- 1.2  users: city + blood_group
--
-- The app's profile screen edits these two fields. Adding them is optional
-- (the app degrades gracefully without them) but the profile form is
-- noticeably better with them. Both nullable; your website ignores them.
-- ---------------------------------------------------------------------
ALTER TABLE `users`
  ADD COLUMN IF NOT EXISTS `city`        varchar(100) DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `blood_group` enum('A+','A-','B+','B-','AB+','AB-','O+','O-') DEFAULT NULL;

-- NOTE: deliberately NOT adding `is_active` to `users`.
-- Your site has no concept of a deactivated user, and adding one would let
-- the app lock people out via a flag your admin panel cannot see or clear.
-- The app's login no longer checks it.

-- =====================================================================
-- PART 2 — new tables: pharmacy e-commerce
--
-- Your database has a `pharmacies` directory but no product catalogue,
-- cart, or orders. These four tables add the shop the app expects.
-- They reference `pharmacies(id)` and `users(id)`, both of which exist.
-- Nothing existing points back at them, so they are inert until used.
-- =====================================================================

CREATE TABLE IF NOT EXISTS `pharmacy_products` (
  `id`            int(11)      NOT NULL AUTO_INCREMENT,
  `pharmacy_id`   int(11)      NOT NULL,
  `name`          varchar(255) NOT NULL,
  `generic_name`  varchar(255)   DEFAULT NULL,
  `brand`         varchar(150)   DEFAULT NULL,
  `category`      varchar(100)   DEFAULT NULL COMMENT 'e.g. Ayurvedic, Herbal, Supplement',
  `description`   text           DEFAULT NULL,
  `image`         varchar(255)   DEFAULT NULL,
  `price`         decimal(10,2) NOT NULL DEFAULT 0.00,
  `mrp`           decimal(10,2)  DEFAULT NULL COMMENT 'strike-through price; NULL = no discount shown',
  `unit`          varchar(50)    DEFAULT NULL COMMENT 'e.g. 100ml bottle, strip of 10',
  `stock`         int(11)       NOT NULL DEFAULT 0,
  `prescription_required` tinyint(1) NOT NULL DEFAULT 0,
  `status`        enum('active','inactive') DEFAULT 'active',
  `created_at`    timestamp     NOT NULL DEFAULT current_timestamp(),
  `updated_at`    timestamp     NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_pharmacy` (`pharmacy_id`),
  KEY `idx_category` (`category`),
  KEY `idx_status` (`status`),
  KEY `idx_name` (`name`),
  CONSTRAINT `pharmacy_products_ibfk_1`
    FOREIGN KEY (`pharmacy_id`) REFERENCES `pharmacies` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- One row per (user, product). UNIQUE lets the app use
-- INSERT ... ON DUPLICATE KEY UPDATE quantity = quantity + ?
CREATE TABLE IF NOT EXISTS `cart` (
  `id`         int(11) NOT NULL AUTO_INCREMENT,
  `user_id`    int(11) NOT NULL,
  `product_id` int(11) NOT NULL,
  `quantity`   int(11) NOT NULL DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_cart_user_product` (`user_id`,`product_id`),
  KEY `idx_product` (`product_id`),
  CONSTRAINT `cart_ibfk_1` FOREIGN KEY (`user_id`)    REFERENCES `users` (`id`)             ON DELETE CASCADE,
  CONSTRAINT `cart_ibfk_2` FOREIGN KEY (`product_id`) REFERENCES `pharmacy_products` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- payment_method mirrors the exact enum values already used by your
-- `payments` table, so the two stay consistent for reporting.
CREATE TABLE IF NOT EXISTS `orders` (
  `id`               int(11)      NOT NULL AUTO_INCREMENT,
  `user_id`          int(11)      NOT NULL,
  `pharmacy_id`      int(11)        DEFAULT NULL COMMENT 'NULL if the order spans pharmacies',
  `order_number`     varchar(20)  NOT NULL,
  `subtotal`         decimal(10,2) NOT NULL DEFAULT 0.00,
  `delivery_fee`     decimal(10,2) NOT NULL DEFAULT 0.00,
  `total`            decimal(10,2) NOT NULL DEFAULT 0.00,
  `payment_method`   enum('bKash','Nagad','Rocket','Credit/Debit Card','Bank Transfer','Cash') NOT NULL DEFAULT 'Cash',
  `payment_status`   enum('pending','paid','refunded') DEFAULT 'pending',
  `transaction_id`   varchar(100)   DEFAULT NULL,
  `sender_number`    varchar(20)    DEFAULT NULL,
  `status`           enum('pending','confirmed','processing','shipped','delivered','cancelled') DEFAULT 'pending',
  `delivery_name`    varchar(100) NOT NULL,
  `delivery_phone`   varchar(20)  NOT NULL,
  `delivery_address` text         NOT NULL,
  `delivery_city`    varchar(50)    DEFAULT NULL,
  `notes`            text           DEFAULT NULL,
  `created_at`       timestamp    NOT NULL DEFAULT current_timestamp(),
  `updated_at`       timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_order_number` (`order_number`),
  KEY `idx_user` (`user_id`),
  KEY `idx_pharmacy` (`pharmacy_id`),
  KEY `idx_status` (`status`),
  CONSTRAINT `orders_ibfk_1` FOREIGN KEY (`user_id`)     REFERENCES `users` (`id`)      ON DELETE CASCADE,
  CONSTRAINT `orders_ibfk_2` FOREIGN KEY (`pharmacy_id`) REFERENCES `pharmacies` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- product_name / unit_price are copied at checkout on purpose: an order is a
-- historical record and must not change when the pharmacy edits its price.
-- ON DELETE SET NULL on product_id keeps old orders readable after a delist.
CREATE TABLE IF NOT EXISTS `order_items` (
  `id`           int(11)      NOT NULL AUTO_INCREMENT,
  `order_id`     int(11)      NOT NULL,
  `product_id`   int(11)        DEFAULT NULL,
  `product_name` varchar(255) NOT NULL,
  `unit_price`   decimal(10,2) NOT NULL,
  `quantity`     int(11)      NOT NULL DEFAULT 1,
  `line_total`   decimal(10,2) NOT NULL,
  `created_at`   timestamp    NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_order` (`order_id`),
  KEY `idx_product` (`product_id`),
  CONSTRAINT `order_items_ibfk_1` FOREIGN KEY (`order_id`)   REFERENCES `orders` (`id`)            ON DELETE CASCADE,
  CONSTRAINT `order_items_ibfk_2` FOREIGN KEY (`product_id`) REFERENCES `pharmacy_products` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- PART 3 — new tables: notifications, blog, app audit
-- =====================================================================

CREATE TABLE IF NOT EXISTS `notifications` (
  `id`         int(11)      NOT NULL AUTO_INCREMENT,
  `user_id`    int(11)      NOT NULL,
  `type`       varchar(50)  NOT NULL DEFAULT 'general' COMMENT 'appointment|payment|order|blood|general',
  `title`      varchar(255) NOT NULL,
  `body`       text           DEFAULT NULL,
  `route`      varchar(255)   DEFAULT NULL COMMENT 'in-app deep link, e.g. /appointments',
  `ref_id`     int(11)        DEFAULT NULL COMMENT 'id of the appointment/order this refers to',
  `is_read`    tinyint(1)   NOT NULL DEFAULT 0,
  `created_at` timestamp    NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_user_read` (`user_id`,`is_read`),
  KEY `idx_created` (`created_at`),
  CONSTRAINT `notifications_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Push tokens. Created even though Firebase is out of scope for this build,
-- so that /auth/logout can clean up a token without a missing-table error.
CREATE TABLE IF NOT EXISTS `device_tokens` (
  `id`         int(11)      NOT NULL AUTO_INCREMENT,
  `user_id`    int(11)      NOT NULL,
  `fcm_token`  varchar(255) NOT NULL,
  `platform`   enum('android','ios','web') DEFAULT 'android',
  `created_at` timestamp    NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_token` (`fcm_token`),
  KEY `idx_user` (`user_id`),
  CONSTRAINT `device_tokens_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- `content` is stored and rendered as PLAIN TEXT by the app, never as HTML
-- (rendering user-authored HTML in the client would be an injection surface).
CREATE TABLE IF NOT EXISTS `blogs` (
  `id`           int(11)      NOT NULL AUTO_INCREMENT,
  `author_id`    int(11)        DEFAULT NULL,
  `slug`         varchar(200) NOT NULL,
  `title`        varchar(255) NOT NULL,
  `excerpt`      varchar(500)   DEFAULT NULL,
  `content`      longtext     NOT NULL,
  `cover_image`  varchar(255)   DEFAULT NULL,
  `category`     varchar(100)   DEFAULT NULL,
  `tags`         varchar(255)   DEFAULT NULL COMMENT 'comma separated',
  `status`       enum('draft','published') DEFAULT 'draft',
  `published_at` timestamp    NULL DEFAULT NULL,
  `views`        int(11)      NOT NULL DEFAULT 0,
  `created_at`   timestamp    NOT NULL DEFAULT current_timestamp(),
  `updated_at`   timestamp    NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_slug` (`slug`),
  KEY `idx_status_pub` (`status`,`published_at`),
  KEY `idx_category` (`category`),
  CONSTRAINT `blogs_ibfk_1` FOREIGN KEY (`author_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- app_audit_log — deliberately NOT your `audit_log`.
--
-- Your `audit_log` is written by database TRIGGERS and records row diffs
-- (table_name/record_id/old_values/new_values). It is a data-change log.
-- The app also wants to record actions that change no row at all — login,
-- logout, failed password change. Writing those into `audit_log` would mean
-- faking a table_name/record_id and polluting a log your site already reads.
--
-- So app-level events go here instead. Your triggers keep working untouched,
-- and the app's writes to appointments/blood_requests still get captured by
-- them automatically, exactly like writes from your website.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `app_audit_log` (
  `id`         bigint(20)  NOT NULL AUTO_INCREMENT,
  `user_id`    int(11)       DEFAULT NULL,
  `action`     varchar(50) NOT NULL COMMENT 'login|logout|create|update|change_password|...',
  `entity`     varchar(50)   DEFAULT NULL,
  `entity_id`  int(11)       DEFAULT NULL,
  `details`    text          DEFAULT NULL COMMENT 'JSON',
  `ip_address` varchar(45)   DEFAULT NULL,
  `created_at` timestamp   NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_user` (`user_id`),
  KEY `idx_action` (`action`),
  KEY `idx_created` (`created_at`),
  CONSTRAINT `app_audit_log_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- PART 4 — optional starter content
--
-- Everything below is sample data so the app's shop and blog are not empty
-- on first run. It is safe to delete this whole section before importing if
-- you would rather populate these tables from your own admin panel.
--
-- IF THIS SECTION ERRORS, NOTHING IS LOST. Parts 1-3 are DDL, and MySQL
-- auto-commits DDL statement by statement, so the schema changes are
-- already permanent by the time execution reaches here. A failure below
-- leaves you with a working app and an empty shop, not a broken database.
--
-- Guarded so re-running does not duplicate rows. Products attach to the
-- lowest-id active pharmacy; your `pharmacies` table is currently empty, so
-- on first import this inserts nothing and the shop shows an empty state
-- until you register a pharmacy. That is expected, not a failure.
-- =====================================================================

INSERT INTO `pharmacy_products`
      (`pharmacy_id`, `name`, `generic_name`, `brand`, `category`, `description`, `price`, `mrp`, `unit`, `stock`)
SELECT p.`id`, v.`name`, v.`generic_name`, v.`brand`, v.`category`, v.`description`, v.`price`, v.`mrp`, v.`unit`, v.`stock`
  FROM (SELECT `id` FROM `pharmacies` WHERE `status` = 'active' ORDER BY `id` LIMIT 1) p
  JOIN (
        SELECT 'Ashwagandha Capsules'  AS name, 'Withania somnifera' AS generic_name, 'AYUR Herbals' AS brand, 'Ayurvedic'  AS category, 'Traditional adaptogen used to support stress resilience and sleep quality.' AS description,  450.00 AS price,  550.00 AS mrp, 'Bottle of 60 capsules' AS unit, 120 AS stock
  UNION SELECT 'Triphala Churna',        'Triphala',            'AYUR Herbals', 'Ayurvedic',  'Classical three-fruit powder traditionally used to support digestion.',        280.00,  320.00, '100 g jar',              80
  UNION SELECT 'Neem & Tulsi Face Wash', 'Azadirachta indica',  'AYUR Care',    'Personal Care', 'Daily cleanser with neem and holy basil for oily, blemish-prone skin.',     240.00,  290.00, '100 ml tube',           150
  UNION SELECT 'Brahmi Hair Oil',        'Bacopa monnieri',     'AYUR Herbals', 'Personal Care', 'Cooling scalp oil traditionally massaged in to support hair strength.',     320.00,  380.00, '200 ml bottle',          95
  UNION SELECT 'Honey & Ginger Syrup',   'Zingiber officinale', 'AYUR Care',    'Supplement', 'Soothing syrup for seasonal throat discomfort. Not a substitute for care.', 190.00,  220.00, '150 ml bottle',         200
  UNION SELECT 'Isabgol Husk',           'Psyllium husk',       'AYUR Herbals', 'Supplement', 'Natural soluble fibre traditionally taken with water for regularity.',       210.00,  250.00, '200 g pack',            140
  ) v
 WHERE NOT EXISTS (SELECT 1 FROM `pharmacy_products` LIMIT 1);

INSERT INTO `blogs` (`slug`, `title`, `excerpt`, `content`, `category`, `status`, `published_at`)
SELECT * FROM (
  SELECT
    'welcome-to-ayur' AS slug,
    'Welcome to AYUR' AS title,
    'What this platform is for, and how to get the most out of it.' AS excerpt,
    'AYUR connects patients across Bangladesh with verified Ayurvedic and allopathic practitioners, clinics, hospitals, pharmacies and blood banks.\n\nYou can search the doctor directory by specialization and city, view a practitioner''s qualifications and chamber address, and book an appointment for an available slot. After booking you will receive a confirmation code — keep it, the chamber will ask for it.\n\nThe blood bank section lists current stock at participating banks and lets you post a request when you need donors urgently.\n\nNothing on this platform is a substitute for professional medical advice. In an emergency, go to your nearest hospital.' AS content,
    'Announcements' AS category,
    'published' AS status,
    current_timestamp() AS published_at
) v
WHERE NOT EXISTS (SELECT 1 FROM `blogs` WHERE `slug` = 'welcome-to-ayur');

INSERT INTO `blogs` (`slug`, `title`, `excerpt`, `content`, `category`, `status`, `published_at`)
SELECT * FROM (
  SELECT
    'preparing-for-your-appointment' AS slug,
    'Preparing for your first appointment' AS title,
    'A short checklist that makes a consultation go further.' AS excerpt,
    'Bring any previous prescriptions, test reports and a list of medicines you currently take, including supplements. Doses matter, so photograph the labels if you are unsure.\n\nWrite down your symptoms before you go: when they started, what makes them better or worse, and how they affect sleep and appetite. It is easy to forget details once the consultation starts.\n\nArrive a few minutes early with your confirmation code. If you need to cancel, do it from the Appointments tab so the slot returns to the pool for someone else.\n\nIf you were asked to fast before a test, confirm how many hours — it is usually eight to twelve.' AS content,
    'Patient Guides' AS category,
    'published' AS status,
    current_timestamp() AS published_at
) v
WHERE NOT EXISTS (SELECT 1 FROM `blogs` WHERE `slug` = 'preparing-for-your-appointment');

-- =====================================================================
-- Verification — run these after importing. Expected results in comments.
-- =====================================================================
-- SELECT COUNT(*) FROM information_schema.tables
--  WHERE table_schema = 'ayur_db';                         -- was 13, now 21
--
-- SELECT COUNT(*) FROM information_schema.columns
--  WHERE table_schema = 'ayur_db' AND table_name = 'doctors'
--    AND column_name IN ('available_days','available_from','available_to','slot_minutes');  -- 4
--
-- SELECT COUNT(*) FROM doctors WHERE available_days IS NOT NULL;   -- your active doctors
-- SELECT COUNT(*) FROM users;                                      -- still 117, unchanged
-- SELECT COUNT(*) FROM doctors;                                    -- still 101, unchanged
-- =====================================================================


-- =====================================================================
-- OPTIONAL, NOT RUN BY THIS SCRIPT: the double-booking unique index
-- =====================================================================
-- backend/api/v1/appointments.php refers you here, so here is the whole
-- picture.
--
-- Your `appointments` table has no unique key on
-- (doctor_id, appointment_date, appointment_time). Its only UNIQUE is on
-- confirmation_code. Nothing at the database level stops two rows from
-- claiming the same doctor at the same minute.
--
-- The app does not rely on the database for this. appointments_book() opens a
-- transaction and does a locking read (SELECT ... FOR UPDATE) on that triple
-- before inserting, so two people tapping "Confirm" at the same instant are
-- serialised and the second gets a 409. That is the approach you chose.
--
-- What that does NOT cover: a booking made by the WEBSITE at the same moment,
-- if the website's PHP inserts without a comparable locking read. The app and
-- the site are two separate clients; only a database-level constraint binds
-- both.
--
-- If you want that guarantee, this is the statement. Read the warning first.
--
--     ALTER TABLE `appointments`
--       ADD UNIQUE KEY `uq_doctor_slot` (`doctor_id`,`appointment_date`,`appointment_time`);
--
-- WARNING 1 — it will FAIL if duplicates already exist. Check before running:
--
--     SELECT doctor_id, appointment_date, appointment_time, COUNT(*) AS n
--       FROM appointments
--      GROUP BY doctor_id, appointment_date, appointment_time
--     HAVING n > 1;
--
--   Your appointments table is currently empty, so this returns nothing today
--   and the index would apply cleanly. That changes once bookings accumulate.
--
-- WARNING 2 — and this is the reason it is not enabled by default: the index
--   counts CANCELLED rows too. Once a 10:00 slot is booked and cancelled, that
--   row still occupies (doctor, date, 10:00) forever, and nobody can ever book
--   10:00 with that doctor again. Your website would hit this too, not just the
--   app. Fixing it properly means either hard-deleting cancelled rows or adding
--   a nullable "slot_key" column that is set to NULL on cancellation — both are
--   changes to how the website writes appointments, which is why this is left
--   as your decision rather than made for you.
-- =====================================================================
