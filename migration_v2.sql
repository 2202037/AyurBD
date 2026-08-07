-- =====================================================================
-- AYUR — migration_v2.sql
-- Adds what the role features from feature.md need on top of v1.
-- =====================================================================
--
-- SAFETY CONTRACT — identical to migration_v1.sql. Read it before running.
--
-- This script is ADDITIVE ONLY. It contains:
--     * ALTER TABLE ... ADD COLUMN IF NOT EXISTS   (nullable / defaulted)
--     * CREATE TABLE IF NOT EXISTS                 (2 new tables)
--
-- It contains NO:
--     * DROP DATABASE / DROP TABLE / DROP COLUMN
--     * TRUNCATE / DELETE / UPDATE
--     * MODIFY or CHANGE of any existing column
--     * changes to any existing enum, index, trigger, or foreign key
--
-- Unlike v1 there is not even one UPDATE in this file. Nothing already
-- stored is read or rewritten.
--
-- Every new column is nullable or has a DEFAULT, so the website's existing
-- INSERT statements keep succeeding untouched.
--
-- Re-running is safe: every statement is guarded by IF NOT EXISTS.
--
-- PREREQUISITE: run migration_v1.sql first. This file assumes the tables it
-- created (notably `blogs`) already exist.
--
-- Target: MariaDB 10.4.32 (ADD COLUMN IF NOT EXISTS is MariaDB syntax).
-- Charset/collation matched to the existing tables: utf8mb4_unicode_ci.
--
-- TAKE A BACKUP FIRST. phpMyAdmin: select ayur_db -> Export -> Go.
-- =====================================================================

-- Do NOT add "CREATE DATABASE" here. Select `ayur_db` in the sidebar first.

SET NAMES utf8mb4;
SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";

-- =====================================================================
-- PART 1 — payment verification (feature.md 6.3)
--
-- The doctor verifies a patient's manually-submitted payment and a
-- confirmation code is generated. `payments` already carries
-- payment_status enum('pending','verified','rejected'); what it lacks is
-- any record of WHO verified it, WHEN, and why a rejection happened.
-- Without these the verification history screen has nothing to show and a
-- rejected payment cannot explain itself to the patient.
-- =====================================================================
ALTER TABLE `payments`
  ADD COLUMN IF NOT EXISTS `verified_by`      int(11)      DEFAULT NULL COMMENT 'users.id of the doctor/admin who reviewed',
  ADD COLUMN IF NOT EXISTS `verified_at`      datetime     DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `rejection_reason` varchar(255) DEFAULT NULL;

-- =====================================================================
-- PART 2 — feedback moderation (feature.md 10.9)
--
-- Admin marks feedback in-progress / resolved / closed, sets a priority,
-- and replies to the user. The live `feedback` table has none of these.
--
-- NOTE ON `status`: the live table already has a status column, and this
-- script deliberately does NOT touch its enum — a MODIFY would breach the
-- safety contract above. The admin endpoints therefore write only values
-- the existing enum already accepts. If your enum lacks 'in_progress' or
-- 'closed', the API reports the write as rejected rather than silently
-- truncating, and you can widen the enum yourself in phpMyAdmin.
-- =====================================================================
ALTER TABLE `feedback`
  ADD COLUMN IF NOT EXISTS `priority`       enum('low','medium','high','urgent') NOT NULL DEFAULT 'medium',
  ADD COLUMN IF NOT EXISTS `admin_response` text     DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `responded_by`   int(11)  DEFAULT NULL COMMENT 'users.id of the responding admin',
  ADD COLUMN IF NOT EXISTS `responded_at`   datetime DEFAULT NULL;

-- =====================================================================
-- PART 3 — blog authoring (feature.md 10.11)
--
-- `blogs` is created by migration_v1.sql for read-only display. Admin
-- management needs to know who wrote a post and whether it is published.
-- =====================================================================
ALTER TABLE `blogs`
  ADD COLUMN IF NOT EXISTS `author_id` int(11) DEFAULT NULL COMMENT 'users.id of the admin author',
  ADD COLUMN IF NOT EXISTS `status`    enum('draft','published','archived') NOT NULL DEFAULT 'published';

-- =====================================================================
-- PART 4 — emergency SMS log (feature.md 5.9)
--
-- The emergency screen sends an SMS request. No gateway is configured in
-- this build, so the request is RECORDED, not transmitted — the row is the
-- deliverable, and `status` stays 'queued' until you wire a provider.
-- Storing it means an unsent emergency is visible in the admin panel
-- rather than lost. Nothing existing points at this table.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `emergency_sms` (
  `id`              int(11)       NOT NULL AUTO_INCREMENT,
  `user_id`         int(11)       DEFAULT NULL,
  `sender_phone`    varchar(20)   NOT NULL,
  `recipient_phone` varchar(20)   NOT NULL,
  `message`         text          NOT NULL,
  `location`        varchar(255)  DEFAULT NULL,
  `latitude`        decimal(10,7) DEFAULT NULL,
  `longitude`       decimal(10,7) DEFAULT NULL,
  `status`          enum('queued','sent','failed') NOT NULL DEFAULT 'queued',
  `created_at`      timestamp     NOT NULL DEFAULT current_timestamp(),
  PRIMARY KEY (`id`),
  KEY `idx_emergency_user` (`user_id`),
  KEY `idx_emergency_created` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- PART 5 — emergency hotlines (feature.md 5.9)
--
-- The hotline list is reference data, seeded here so the emergency screen
-- is useful immediately. Guarded by INSERT ... SELECT ... WHERE NOT EXISTS
-- so re-running never duplicates a row, and so your own edits to these
-- numbers are never overwritten.
-- =====================================================================
CREATE TABLE IF NOT EXISTS `emergency_hotlines` (
  `id`          int(11)      NOT NULL AUTO_INCREMENT,
  `name`        varchar(150) NOT NULL,
  `phone`       varchar(30)  NOT NULL,
  `category`    varchar(50)  NOT NULL DEFAULT 'general',
  `description` varchar(255) DEFAULT NULL,
  `sort_order`  int(11)      NOT NULL DEFAULT 0,
  `status`      enum('active','inactive') NOT NULL DEFAULT 'active',
  PRIMARY KEY (`id`),
  KEY `idx_hotline_status` (`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO `emergency_hotlines` (`name`, `phone`, `category`, `description`, `sort_order`)
SELECT * FROM (SELECT
  'National Emergency Service' AS a, '999' AS b, 'general' AS c,
  'Police, fire and ambulance — one number, nationwide.' AS d, 1 AS e) AS tmp
WHERE NOT EXISTS (SELECT 1 FROM `emergency_hotlines` WHERE `phone` = '999');

INSERT INTO `emergency_hotlines` (`name`, `phone`, `category`, `description`, `sort_order`)
SELECT * FROM (SELECT
  'Ambulance Service' AS a, '199' AS b, 'ambulance' AS c,
  'Dedicated ambulance dispatch.' AS d, 2 AS e) AS tmp
WHERE NOT EXISTS (SELECT 1 FROM `emergency_hotlines` WHERE `phone` = '199');

INSERT INTO `emergency_hotlines` (`name`, `phone`, `category`, `description`, `sort_order`)
SELECT * FROM (SELECT
  'Fire Service and Civil Defence' AS a, '16163' AS b, 'fire' AS c,
  'Fire, rescue and civil defence.' AS d, 3 AS e) AS tmp
WHERE NOT EXISTS (SELECT 1 FROM `emergency_hotlines` WHERE `phone` = '16163');

INSERT INTO `emergency_hotlines` (`name`, `phone`, `category`, `description`, `sort_order`)
SELECT * FROM (SELECT
  'Health Call Centre (Shastho Batayan)' AS a, '16263' AS b, 'health' AS c,
  'Government health advice line, 24 hours.' AS d, 4 AS e) AS tmp
WHERE NOT EXISTS (SELECT 1 FROM `emergency_hotlines` WHERE `phone` = '16263');

INSERT INTO `emergency_hotlines` (`name`, `phone`, `category`, `description`, `sort_order`)
SELECT * FROM (SELECT
  'Women and Children Helpline' AS a, '109' AS b, 'support' AS c,
  'Violence against women and children.' AS d, 5 AS e) AS tmp
WHERE NOT EXISTS (SELECT 1 FROM `emergency_hotlines` WHERE `phone` = '109');

-- =====================================================================
-- Verify it landed (run these yourself; they are read-only)
-- =====================================================================
-- SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ayur_db';
--   -- was 21 after v1, now 23
-- SELECT COUNT(*) FROM users;      -- unchanged
-- SELECT COUNT(*) FROM doctors;    -- unchanged
-- SELECT COUNT(*) FROM payments;   -- unchanged
-- SELECT COUNT(*) FROM emergency_hotlines;  -- 5
--
-- If users / doctors / payments changed count, something other than this
-- script ran. Restore your backup.
