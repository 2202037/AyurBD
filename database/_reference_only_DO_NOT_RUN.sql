-- #####################################################################
-- ##  REFERENCE ONLY - DO NOT RUN THIS FILE AGAINST ayur_db          ##
-- #####################################################################
-- This was a RECONSTRUCTION built before the real schema was available.
-- The real database has since been supplied and this file is now known to
-- be wrong in ~40 places (invented tables, wrong column names, wrong enum
-- values). It is kept only as a record of what was assumed.
--
-- To set the app up against the real database, run:
--     database/migration_v1.sql
-- which is additive-only (CREATE TABLE IF NOT EXISTS / ADD COLUMN IF NOT
-- EXISTS) and changes no existing row, column, or table.
-- #####################################################################

-- =====================================================================
-- AYUR — MySQL schema
-- =====================================================================
-- PROVENANCE WARNING
-- The real ayur_db.sql was NOT attached to the build session. This file is
-- reconstructed from §5 of AYUR_Flutter_Project_Report.md (table + FK list
-- only) plus the field names implied by the §6 API contract.
--
-- Every column marked  -- [ASSUMED]  is an invention of this build, not
-- ground truth. Before pointing the app at the live AYUR database, diff this
-- file against the real schema and reconcile. Tables flagged [NET-NEW?] are
-- the ones §15 Q2 asks about: they appear as feature areas in the source
-- report but not in its table inventory.
--
-- Charset: utf8mb4 throughout (Bangla content in blogs/addresses).
-- Engine: InnoDB required — FKs, transactions (§5 concurrency rule).
-- =====================================================================

-- The three statements that used to live here were removed on reconciliation:
--   DROP DATABASE IF EXISTS ayur_db;   <-- would have destroyed the live site
--   CREATE DATABASE ayur_db ...
--   USE ayur_db;
-- The real ayur_db already exists and must not be recreated.

SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------------
-- users — §5: role ∈ {patient,doctor,clinic,pharmacy,hospital,admin}
-- ---------------------------------------------------------------------
CREATE TABLE users (
  id             INT UNSIGNED   NOT NULL AUTO_INCREMENT,
  name           VARCHAR(150)   NOT NULL,
  email          VARCHAR(190)   NOT NULL,
  password       VARCHAR(255)   NOT NULL,           -- password_hash(), bcrypt
  phone          VARCHAR(30)        NULL,
  role           ENUM('patient','doctor','clinic','pharmacy','hospital','admin')
                                NOT NULL DEFAULT 'patient',
  profile_image  VARCHAR(255)       NULL,           -- [ASSUMED] relative path
  address        VARCHAR(255)       NULL,           -- [ASSUMED]
  city           VARCHAR(100)       NULL,           -- [ASSUMED] mirrors clinics.city
  -- [ASSUMED] the donor's own group, used to prefill a blood request. Nullable:
  -- most patients never fill it in, and guessing a blood group is dangerous.
  blood_group    ENUM('A+','A-','B+','B-','AB+','AB-','O+','O-') NULL,
  is_active      TINYINT(1)     NOT NULL DEFAULT 1, -- [ASSUMED] admin deactivate
  created_at     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
                                ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_email (email),
  KEY idx_users_role (role)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- clinics — §5 lists no FKs
-- ---------------------------------------------------------------------
CREATE TABLE clinics (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id     INT UNSIGNED      NULL,            -- [ASSUMED] owner login (role=clinic)
  name        VARCHAR(190)  NOT NULL,
  address     VARCHAR(255)      NULL,
  city        VARCHAR(100)      NULL,            -- [ASSUMED]
  phone       VARCHAR(30)       NULL,
  hours       VARCHAR(120)      NULL,            -- [ASSUMED] §6 "hours" display field
  image       VARCHAR(255)      NULL,            -- [ASSUMED]
  description TEXT              NULL,            -- [ASSUMED]
  rating      DECIMAL(3,2)  NOT NULL DEFAULT 0.00, -- [ASSUMED] cached avg, §6 "rating"
  latitude    DECIMAL(10,7)     NULL,            -- [ASSUMED] §6 coords / distance sort
  longitude   DECIMAL(10,7)     NULL,            -- [ASSUMED]
  is_active   TINYINT(1)    NOT NULL DEFAULT 1,  -- [ASSUMED]
  created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_clinics_user (user_id),
  KEY idx_clinics_city (city),
  CONSTRAINT fk_clinics_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- hospitals — [NET-NEW?] §15 Q2. Mirrors clinics shape.
-- ---------------------------------------------------------------------
CREATE TABLE hospitals (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id     INT UNSIGNED      NULL,            -- [ASSUMED] role=hospital login
  name        VARCHAR(190)  NOT NULL,
  address     VARCHAR(255)      NULL,
  city        VARCHAR(100)      NULL,
  phone       VARCHAR(30)       NULL,
  emergency_phone VARCHAR(30)   NULL,            -- [ASSUMED] §7 Emergency one tap
  hours       VARCHAR(120)      NULL,
  image       VARCHAR(255)      NULL,
  description TEXT              NULL,
  beds_total  INT UNSIGNED      NULL,            -- [ASSUMED]
  rating      DECIMAL(3,2)  NOT NULL DEFAULT 0.00,
  latitude    DECIMAL(10,7)     NULL,
  longitude   DECIMAL(10,7)     NULL,
  is_active   TINYINT(1)    NOT NULL DEFAULT 1,
  created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_hospitals_city (city),
  CONSTRAINT fk_hospitals_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- doctors — §5: user_id→users, clinic_id→clinics
-- ---------------------------------------------------------------------
CREATE TABLE doctors (
  id             INT UNSIGNED   NOT NULL AUTO_INCREMENT,
  user_id        INT UNSIGNED   NOT NULL,
  clinic_id      INT UNSIGNED       NULL,
  hospital_id    INT UNSIGNED       NULL,        -- [ASSUMED] doctors also sit in hospitals
  specialty      VARCHAR(120)       NULL,        -- §6 filter + display
  qualification  VARCHAR(190)       NULL,        -- [ASSUMED]
  experience_years TINYINT UNSIGNED NULL,        -- [ASSUMED]
  bio            TEXT               NULL,        -- [ASSUMED]
  consultation_fee DECIMAL(10,2) NOT NULL DEFAULT 0.00,  -- §6 "fee"
  rating         DECIMAL(3,2)   NOT NULL DEFAULT 0.00,   -- §6 "rating"
  available_days VARCHAR(60)        NULL,        -- [ASSUMED] CSV "Sat,Sun,Mon" — see NOTE
  available_from TIME               NULL,        -- [ASSUMED] slot window start
  available_to   TIME               NULL,        -- [ASSUMED] slot window end
  slot_minutes   SMALLINT UNSIGNED NOT NULL DEFAULT 30,  -- [ASSUMED] booking grid
  is_active      TINYINT(1)     NOT NULL DEFAULT 1,
  created_at     TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_doctors_specialty (specialty),
  KEY idx_doctors_clinic (clinic_id),
  KEY idx_doctors_hospital (hospital_id),
  CONSTRAINT fk_doctors_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_doctors_clinic FOREIGN KEY (clinic_id)
    REFERENCES clinics(id) ON DELETE SET NULL ON UPDATE CASCADE,
  CONSTRAINT fk_doctors_hospital FOREIGN KEY (hospital_id)
    REFERENCES hospitals(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
-- NOTE: available_days as CSV is a compromise for a single-file schema. If the
-- real DB has a doctor_schedules table, prefer it — the slot generator in
-- backend/api/v1/appointments.php reads only these 4 columns and is easy to swap.

-- ---------------------------------------------------------------------
-- pharmacies — [ASSUMED] §6 /directory/pharmacies needs a source table
-- ---------------------------------------------------------------------
CREATE TABLE pharmacies (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id     INT UNSIGNED      NULL,            -- role=pharmacy login
  name        VARCHAR(190)  NOT NULL,
  address     VARCHAR(255)      NULL,
  city        VARCHAR(100)      NULL,
  phone       VARCHAR(30)       NULL,
  hours       VARCHAR(120)      NULL,
  image       VARCHAR(255)      NULL,
  is_24h      TINYINT(1)    NOT NULL DEFAULT 0,
  rating      DECIMAL(3,2)  NOT NULL DEFAULT 0.00,
  latitude    DECIMAL(10,7)     NULL,
  longitude   DECIMAL(10,7)     NULL,
  is_active   TINYINT(1)    NOT NULL DEFAULT 1,
  created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_pharmacies_city (city),
  CONSTRAINT fk_pharmacies_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- appointments — §5: status enum, unique(doctor_id,date,time), audit trigger
-- ---------------------------------------------------------------------
CREATE TABLE appointments (
  id           INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  patient_id   INT UNSIGNED  NOT NULL,
  doctor_id    INT UNSIGNED  NOT NULL,
  appointment_date DATE      NOT NULL,           -- §5 unique key part "date"
  appointment_time TIME      NOT NULL,           -- §5 unique key part "time"
  reason       VARCHAR(500)      NULL,           -- §6 book payload "reason"
  status       ENUM('pending','confirmed','completed','cancelled')
                             NOT NULL DEFAULT 'pending',
  notes        VARCHAR(500)      NULL,           -- [ASSUMED] provider-side note
  created_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  -- §5 hard rule: no double-booking. Server is sole arbiter (§8) — a duplicate
  -- INSERT raises errno 1062, which appointments.php maps to HTTP 409.
  UNIQUE KEY uq_appt_slot (doctor_id, appointment_date, appointment_time),
  KEY idx_appt_patient (patient_id, status),
  KEY idx_appt_doctor (doctor_id, appointment_date),
  CONSTRAINT fk_appt_patient FOREIGN KEY (patient_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_appt_doctor FOREIGN KEY (doctor_id)
    REFERENCES doctors(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- payments — §5: appointment_id→appointments, status ∈ {unpaid,paid,refunded}
-- §8: site payment may be manual/offline — no gateway added here.
-- ---------------------------------------------------------------------
CREATE TABLE payments (
  id             INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  appointment_id INT UNSIGNED  NOT NULL,
  amount         DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  method         VARCHAR(40)       NULL,         -- [ASSUMED] cash/bkash/nagad/card
  status         ENUM('unpaid','paid','refunded') NOT NULL DEFAULT 'unpaid',
  transaction_ref VARCHAR(120)     NULL,         -- [ASSUMED] manual receipt no.
  paid_at        DATETIME          NULL,         -- [ASSUMED]
  created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_payments_appt (appointment_id),  -- [ASSUMED] one payment row per appt
  CONSTRAINT fk_payments_appt FOREIGN KEY (appointment_id)
    REFERENCES appointments(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- blood_inventory — §5: status enumerated
-- ---------------------------------------------------------------------
CREATE TABLE blood_inventory (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  hospital_id INT UNSIGNED      NULL,            -- [ASSUMED] holder of the stock
  blood_group ENUM('A+','A-','B+','B-','AB+','AB-','O+','O-') NOT NULL,
  units_available INT UNSIGNED NOT NULL DEFAULT 0,
  location    VARCHAR(190)      NULL,            -- §6 ?location filter
  contact_phone VARCHAR(30)     NULL,            -- [ASSUMED] §8 one-tap call
  latitude    DECIMAL(10,7)     NULL,            -- [ASSUMED] §6 /blood_bank/nearby
  longitude   DECIMAL(10,7)     NULL,            -- [ASSUMED]
  status      ENUM('available','low','unavailable') NOT NULL DEFAULT 'available',
  updated_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_blood_group (blood_group, status),
  CONSTRAINT fk_blood_inv_hospital FOREIGN KEY (hospital_id)
    REFERENCES hospitals(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- blood_requests — §5: requester_id→users, status/urgency enumerated
-- ---------------------------------------------------------------------
CREATE TABLE blood_requests (
  id            INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  requester_id  INT UNSIGNED  NOT NULL,
  blood_group   ENUM('A+','A-','B+','B-','AB+','AB-','O+','O-') NOT NULL,
  units_needed  INT UNSIGNED  NOT NULL DEFAULT 1,
  urgency       ENUM('low','normal','high','critical') NOT NULL DEFAULT 'normal',
  hospital_name VARCHAR(190)      NULL,          -- §6 payload (free text, not FK)
  contact_phone VARCHAR(30)   NOT NULL,
  note          VARCHAR(500)      NULL,          -- [ASSUMED]
  status        ENUM('open','fulfilled','cancelled','expired') NOT NULL DEFAULT 'open',
  needed_by     DATE              NULL,          -- [ASSUMED]
  created_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_breq_group (blood_group, status),
  KEY idx_breq_requester (requester_id),
  CONSTRAINT fk_breq_user FOREIGN KEY (requester_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- pharmacy_products / cart / orders / order_items
-- §5: stock re-checked at checkout (enforced in pharmacy.php txn)
-- ---------------------------------------------------------------------
CREATE TABLE pharmacy_products (
  id           INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  pharmacy_id  INT UNSIGNED      NULL,           -- [ASSUMED] owning pharmacy
  name         VARCHAR(190)  NOT NULL,
  generic_name VARCHAR(190)      NULL,           -- [ASSUMED]
  category     VARCHAR(100)      NULL,           -- §6 ?category filter
  description  TEXT              NULL,
  price        DECIMAL(10,2) NOT NULL DEFAULT 0.00,
  stock        INT           NOT NULL DEFAULT 0,
  unit         VARCHAR(40)       NULL,           -- [ASSUMED] strip/bottle/box
  image        VARCHAR(255)      NULL,
  requires_prescription TINYINT(1) NOT NULL DEFAULT 0,  -- [ASSUMED]
  is_active    TINYINT(1)    NOT NULL DEFAULT 1,
  created_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_prod_category (category),
  KEY idx_prod_pharmacy (pharmacy_id),
  KEY idx_prod_name (name),
  CONSTRAINT fk_prod_pharmacy FOREIGN KEY (pharmacy_id)
    REFERENCES pharmacies(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE cart (
  id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED  NOT NULL,
  product_id INT UNSIGNED  NOT NULL,
  quantity   INT UNSIGNED  NOT NULL DEFAULT 1,
  created_at TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                           ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  -- one row per user+product; /cart/add on an existing pair increments instead
  UNIQUE KEY uq_cart_user_product (user_id, product_id),
  KEY idx_cart_product (product_id),
  CONSTRAINT fk_cart_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_cart_product FOREIGN KEY (product_id)
    REFERENCES pharmacy_products(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE orders (
  id             INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id        INT UNSIGNED  NOT NULL,
  order_number   VARCHAR(40)   NOT NULL,         -- [ASSUMED] human ref e.g. AYU-000123
  total_amount   DECIMAL(10,2) NOT NULL DEFAULT 0.00,  -- server-computed (§8)
  payment_method VARCHAR(40)       NULL,         -- §6 checkout payload
  payment_status ENUM('unpaid','paid','refunded') NOT NULL DEFAULT 'unpaid',
  status         ENUM('pending','processing','shipped','delivered','cancelled')
                               NOT NULL DEFAULT 'pending',
  address        VARCHAR(255)      NULL,         -- §6 checkout payload
  created_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
                               ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_orders_number (order_number),
  KEY idx_orders_user (user_id, status),
  CONSTRAINT fk_orders_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE order_items (
  id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  order_id   INT UNSIGNED  NOT NULL,
  product_id INT UNSIGNED  NOT NULL,
  quantity   INT UNSIGNED  NOT NULL DEFAULT 1,
  unit_price DECIMAL(10,2) NOT NULL DEFAULT 0.00, -- price snapshot at purchase
  PRIMARY KEY (id),
  KEY idx_oi_order (order_id),
  KEY idx_oi_product (product_id),
  CONSTRAINT fk_oi_order FOREIGN KEY (order_id)
    REFERENCES orders(id) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT fk_oi_product FOREIGN KEY (product_id)
    REFERENCES pharmacy_products(id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- notifications / device_tokens — §5: fcm_token unique per user
-- ---------------------------------------------------------------------
CREATE TABLE notifications (
  id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED  NOT NULL,
  title      VARCHAR(190)  NOT NULL,
  body       VARCHAR(500)      NULL,             -- [ASSUMED]
  type       VARCHAR(40)       NULL,             -- [ASSUMED] appointment/order/blood
  ref_id     INT UNSIGNED      NULL,             -- [ASSUMED] deep-link target
  is_read    TINYINT(1)    NOT NULL DEFAULT 0,
  created_at TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_notif_user (user_id, is_read),
  CONSTRAINT fk_notif_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE device_tokens (
  id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED  NOT NULL,
  fcm_token  VARCHAR(255)  NOT NULL,
  platform   ENUM('android','ios','web') NOT NULL DEFAULT 'android',
  created_at TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_token (fcm_token),               -- §5: unique per user
  KEY idx_dt_user (user_id),
  CONSTRAINT fk_dt_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- reviews / feedback / blogs — [NET-NEW?] §15 Q2
-- ---------------------------------------------------------------------
CREATE TABLE reviews (
  id          INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id     INT UNSIGNED  NOT NULL,
  target_type ENUM('doctor','clinic','hospital','pharmacy','product') NOT NULL,
  target_id   INT UNSIGNED  NOT NULL,            -- polymorphic: no FK possible
  rating      TINYINT UNSIGNED NOT NULL,         -- 1..5, enforced in PHP + CHECK
  comment     VARCHAR(1000)     NULL,
  is_approved TINYINT(1)    NOT NULL DEFAULT 1,  -- admin moderation
  created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_review_once (user_id, target_type, target_id),
  KEY idx_review_target (target_type, target_id, is_approved),
  CONSTRAINT chk_review_rating CHECK (rating BETWEEN 1 AND 5),
  CONSTRAINT fk_review_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE feedback (
  id         INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED      NULL,             -- §6: guest-allowed → nullable
  name       VARCHAR(150)      NULL,
  email      VARCHAR(190)      NULL,
  message    TEXT          NOT NULL,
  status     ENUM('new','in_review','resolved') NOT NULL DEFAULT 'new',
  created_at TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_feedback_status (status),
  CONSTRAINT fk_feedback_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE blogs (
  id           INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  author_id    INT UNSIGNED      NULL,
  title        VARCHAR(190)  NOT NULL,
  slug         VARCHAR(190)  NOT NULL,           -- §6 GET /blog/{slug}
  excerpt      VARCHAR(500)      NULL,
  content      LONGTEXT          NULL,
  image        VARCHAR(255)      NULL,
  category     VARCHAR(100)      NULL,
  is_published TINYINT(1)    NOT NULL DEFAULT 1,
  published_at DATETIME          NULL,
  created_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_blog_slug (slug),
  KEY idx_blog_pub (is_published, published_at),
  CONSTRAINT fk_blog_author FOREIGN KEY (author_id)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- audit_logs — §5: write on every sensitive mutation
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id    INT UNSIGNED       NULL,            -- NULL = system/trigger origin
  action     VARCHAR(60)     NOT NULL,           -- create/update/delete/login/book…
  entity     VARCHAR(60)     NOT NULL,           -- table or logical entity name
  entity_id  INT UNSIGNED       NULL,
  details    TEXT               NULL,            -- JSON blob (before/after)
  ip_address VARCHAR(45)        NULL,
  created_at TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_audit_entity (entity, entity_id),
  KEY idx_audit_user (user_id, created_at),
  CONSTRAINT fk_audit_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ---------------------------------------------------------------------
-- Appointment audit trigger — §5 "audited by DB trigger"
-- DB-level so the website and the app are both covered, even on direct SQL.
-- ---------------------------------------------------------------------
DELIMITER $$

CREATE TRIGGER trg_appointments_after_insert
AFTER INSERT ON appointments
FOR EACH ROW
BEGIN
  INSERT INTO audit_logs (user_id, action, entity, entity_id, details)
  VALUES (NEW.patient_id, 'create', 'appointments', NEW.id,
          CONCAT('{"doctor_id":', NEW.doctor_id,
                 ',"date":"', NEW.appointment_date,
                 '","time":"', NEW.appointment_time,
                 '","status":"', NEW.status, '"}'));
END$$

CREATE TRIGGER trg_appointments_after_update
AFTER UPDATE ON appointments
FOR EACH ROW
BEGIN
  IF NEW.status <> OLD.status THEN
    INSERT INTO audit_logs (user_id, action, entity, entity_id, details)
    VALUES (NEW.patient_id, 'status_change', 'appointments', NEW.id,
            CONCAT('{"from":"', OLD.status, '","to":"', NEW.status, '"}'));
  END IF;
END$$

CREATE TRIGGER trg_payments_after_update
AFTER UPDATE ON payments
FOR EACH ROW
BEGIN
  IF NEW.status <> OLD.status THEN
    INSERT INTO audit_logs (user_id, action, entity, entity_id, details)
    VALUES (NULL, 'status_change', 'payments', NEW.id,
            CONCAT('{"from":"', OLD.status, '","to":"', NEW.status,
                   '","appointment_id":', NEW.appointment_id, '}'));
  END IF;
END$$

DELIMITER ;

-- =====================================================================
-- SEED DATA — demo only. Password for EVERY seeded account: Ayur@1234
-- Hash below is bcrypt of "Ayur@1234". Replace before any real deployment.
-- =====================================================================
-- Verified against password_verify() semantics (bcrypt cost 10, $2y$ prefix).
SET @pw = '$2y$10$K6gCgbHS0TmJr/SqKg2yBui4VI5wEiVwpOHrBuHZSxZc7IENJoUbK';

INSERT INTO users (id, name, email, password, phone, role, address, city, blood_group) VALUES
  (1,  'AYUR Admin',        'admin@ayur.test',    @pw, '01700000001', 'admin',    'Dhaka',              'Dhaka',      NULL),
  (2,  'Rahim Uddin',       'patient@ayur.test',  @pw, '01700000002', 'patient',  'Mirpur, Dhaka',      'Dhaka',      'O+'),
  (3,  'Fatema Begum',      'patient2@ayur.test', @pw, '01700000003', 'patient',  'Uttara, Dhaka',      'Dhaka',      'B+'),
  (4,  'Dr. Ayesha Siddika','doctor@ayur.test',   @pw, '01700000004', 'doctor',   'Dhanmondi, Dhaka',   'Dhaka',      NULL),
  (5,  'Dr. Kamal Hossain', 'doctor2@ayur.test',  @pw, '01700000005', 'doctor',   'Gulshan, Dhaka',     'Dhaka',      NULL),
  (6,  'Dr. Nusrat Jahan',  'doctor3@ayur.test',  @pw, '01700000006', 'doctor',   'Chattogram',         'Chattogram', NULL),
  (7,  'Shefa Clinic Admin','clinic@ayur.test',   @pw, '01700000007', 'clinic',   'Dhanmondi, Dhaka',   'Dhaka',      NULL),
  (8,  'City Hospital Desk','hospital@ayur.test', @pw, '01700000008', 'hospital', 'Banani, Dhaka',      'Dhaka',      NULL),
  (9,  'Lazz Pharma Desk',  'pharmacy@ayur.test', @pw, '01700000009', 'pharmacy', 'Mohakhali, Dhaka',   'Dhaka',      NULL);

INSERT INTO clinics (id, user_id, name, address, city, phone, hours, rating, latitude, longitude) VALUES
  (1, 7,    'Shefa Ayur Clinic',   'Road 8, Dhanmondi',    'Dhaka',      '02-9101010', 'Sat–Thu 9:00–21:00', 4.60, 23.7461000, 90.3742000),
  (2, NULL, 'Green Life Ayurveda', 'Green Road',           'Dhaka',      '02-9101020', 'Daily 10:00–20:00',  4.20, 23.7509000, 90.3854000),
  (3, NULL, 'Port City Herbal',    'Agrabad C/A',          'Chattogram', '031-710101', 'Sat–Thu 9:00–18:00', 4.00, 22.3269000, 91.8123000);

INSERT INTO hospitals (id, user_id, name, address, city, phone, emergency_phone, hours, beds_total, rating, latitude, longitude) VALUES
  (1, 8,    'City General Hospital', 'Kemal Ataturk Ave, Banani', 'Dhaka',      '02-9882200', '01711000111', '24/7', 320, 4.50, 23.7936000, 90.4043000),
  (2, NULL, 'Sylhet Care Hospital',  'Zindabazar',                'Sylhet',     '0821-720101','01711000222', '24/7', 150, 4.10, 24.8949000, 91.8687000),
  (3, NULL, 'Chattogram Medical Centre','GEC Circle',             'Chattogram', '031-650101', '01711000333', '24/7', 210, 4.30, 22.3590000, 91.8214000);

INSERT INTO pharmacies (id, user_id, name, address, city, phone, hours, is_24h, rating, latitude, longitude) VALUES
  (1, 9,    'Lazz Pharma Mohakhali', 'Mohakhali DOHS',  'Dhaka',      '02-8801010', '24/7',              1, 4.70, 23.7806000, 90.4071000),
  (2, NULL, 'Tamanna Pharmacy',      'Mirpur 10',       'Dhaka',      '02-8801020', 'Daily 8:00–23:00',  0, 4.10, 23.8069000, 90.3687000),
  (3, NULL, 'Agrabad Medicine Hub',  'Agrabad',         'Chattogram', '031-720202', 'Daily 9:00–22:00',  0, 4.00, 22.3280000, 91.8100000);

INSERT INTO doctors (id, user_id, clinic_id, hospital_id, specialty, qualification, experience_years, bio, consultation_fee, rating, available_days, available_from, available_to, slot_minutes) VALUES
  (1, 4, 1,    NULL, 'Ayurvedic Medicine', 'BAMS, MD (Ayurveda)', 12, 'Focus on chronic digestive and metabolic care through classical Ayurvedic protocols.', 800.00,  4.80, 'Sat,Sun,Mon,Tue,Wed', '10:00:00', '17:00:00', 30),
  (2, 5, 2,    1,    'Panchakarma',        'BAMS, PGD Panchakarma', 8, 'Panchakarma detox therapy and post-therapy lifestyle planning.',                    1000.00, 4.50, 'Sun,Tue,Thu',         '09:00:00', '15:00:00', 45),
  (3, 6, 3,    3,    'Herbal Dermatology', 'BAMS, MSc Dermatology', 6, 'Herbal management of eczema, psoriasis and chronic skin conditions.',               600.00,  4.30, 'Sat,Mon,Wed',         '11:00:00', '18:00:00', 30);

INSERT INTO appointments (id, patient_id, doctor_id, appointment_date, appointment_time, reason, status) VALUES
  (1, 2, 1, '2026-08-05', '10:30:00', 'Chronic acidity follow-up',    'confirmed'),
  (2, 2, 3, '2026-08-11', '11:30:00', 'Eczema on both hands',         'pending'),
  (3, 3, 2, '2026-07-21', '09:45:00', 'Panchakarma consultation',     'completed');

INSERT INTO payments (appointment_id, amount, method, status, paid_at) VALUES
  (1, 800.00,  'bkash', 'paid',   '2026-07-29 12:15:00'),
  (2, 600.00,  NULL,    'unpaid', NULL),
  (3, 1000.00, 'cash',  'paid',   '2026-07-21 10:05:00');

INSERT INTO blood_inventory (hospital_id, blood_group, units_available, location, contact_phone, latitude, longitude, status) VALUES
  (1, 'A+',  12, 'City General Hospital, Banani, Dhaka',     '01711000111', 23.7936000, 90.4043000, 'available'),
  (1, 'O+',  20, 'City General Hospital, Banani, Dhaka',     '01711000111', 23.7936000, 90.4043000, 'available'),
  (1, 'O-',   3, 'City General Hospital, Banani, Dhaka',     '01711000111', 23.7936000, 90.4043000, 'low'),
  (1, 'AB+',  0, 'City General Hospital, Banani, Dhaka',     '01711000111', 23.7936000, 90.4043000, 'unavailable'),
  (2, 'B+',   9, 'Sylhet Care Hospital, Zindabazar, Sylhet', '01711000222', 24.8949000, 91.8687000, 'available'),
  (2, 'A-',   2, 'Sylhet Care Hospital, Zindabazar, Sylhet', '01711000222', 24.8949000, 91.8687000, 'low'),
  (3, 'O+',  15, 'Chattogram Medical Centre, GEC',           '01711000333', 22.3590000, 91.8214000, 'available'),
  (3, 'AB-',  1, 'Chattogram Medical Centre, GEC',           '01711000333', 22.3590000, 91.8214000, 'low');

INSERT INTO blood_requests (requester_id, blood_group, units_needed, urgency, hospital_name, contact_phone, note, status, needed_by) VALUES
  (2, 'O-', 2, 'critical', 'City General Hospital', '01700000002', 'Surgery scheduled tomorrow morning.', 'open', '2026-08-01'),
  (3, 'B+', 1, 'normal',   'Sylhet Care Hospital',  '01700000003', 'Thalassemia routine transfusion.',    'open', '2026-08-06');

INSERT INTO pharmacy_products (id, pharmacy_id, name, generic_name, category, description, price, stock, unit, requires_prescription) VALUES
  (1, 1, 'Ashwagandha Capsule 500mg', 'Withania somnifera', 'Ayurvedic',   'Adaptogen for stress and sleep support. 60 capsules.',    450.00, 120, 'bottle', 0),
  (2, 1, 'Triphala Churna 100g',      'Triphala',           'Ayurvedic',   'Classical digestive and bowel-regularity formulation.',   220.00,  80, 'pack',   0),
  (3, 1, 'Brahmi Oil 100ml',          'Bacopa monnieri',    'Ayurvedic',   'Scalp and hair oil traditionally used for calm sleep.',    310.00,  45, 'bottle', 0),
  (4, 2, 'Neem Tablet 60s',           'Azadirachta indica', 'Ayurvedic',   'Blood-purifier commonly used for skin conditions.',       180.00,   0, 'strip',  0),
  (5, 2, 'Paracetamol 500mg',         'Paracetamol',        'Allopathic',  'Fever and pain relief. 10 tablets per strip.',             12.00, 500, 'strip',  0),
  (6, 2, 'Omeprazole 20mg',           'Omeprazole',         'Allopathic',  'Acid-reflux management. Prescription required.',            95.00, 200, 'strip',  1),
  (7, 3, 'Chyawanprash 500g',         'Chyawanprash',       'Ayurvedic',   'Immunity tonic, traditional herbal jam.',                 390.00,  60, 'jar',    0),
  (8, 3, 'Vitamin D3 2000IU',         'Cholecalciferol',    'Supplement',  'Bone and immune support. 30 capsules.',                   275.00,  90, 'bottle', 0);

INSERT INTO cart (user_id, product_id, quantity) VALUES
  (2, 1, 1),
  (2, 5, 2);

INSERT INTO orders (id, user_id, order_number, total_amount, payment_method, payment_status, status, address) VALUES
  (1, 3, 'AYU-000001', 665.00, 'cash_on_delivery', 'unpaid', 'processing', 'Uttara Sector 4, Dhaka');

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
  (1, 2, 1, 220.00),
  (1, 7, 1, 390.00),
  (1, 5, 1,  12.00);

INSERT INTO notifications (user_id, title, body, type, ref_id, is_read) VALUES
  (2, 'Appointment confirmed', 'Your appointment with Dr. Ayesha Siddika on 05 Aug 2026 at 10:30 AM is confirmed.', 'appointment', 1, 0),
  (2, 'Payment received',      'Payment of BDT 800.00 received. Thank you.',                                        'payment',     1, 1),
  (3, 'Order processing',      'Order AYU-000001 is being prepared for delivery.',                                  'order',       1, 0);

INSERT INTO blogs (author_id, title, slug, excerpt, content, category, is_published, published_at) VALUES
  (1, 'Five Ayurvedic Habits for Better Digestion', 'five-ayurvedic-habits-better-digestion',
     'Small daily routines from classical Ayurveda that support digestive fire (agni).',
     'Ayurveda treats digestion as the foundation of health. Warm water in the morning, eating the largest meal at midday, avoiding cold drinks with meals, resting briefly after eating, and a light early dinner are five habits that consistently help. Each works by supporting agni, the digestive fire, rather than suppressing symptoms.',
     'Wellness', 1, '2026-07-10 09:00:00'),
  (1, 'Understanding Panchakarma: What to Expect', 'understanding-panchakarma-what-to-expect',
     'A plain-language walkthrough of the preparation, therapy, and recovery phases.',
     'Panchakarma is a staged detoxification process, not a single treatment. Preparation (purvakarma) softens and mobilises accumulated waste, the main therapies clear it, and the recovery phase (paschatkarma) rebuilds strength with diet and routine. Expect the full cycle to span one to three weeks depending on the protocol your physician selects.',
     'Treatment', 1, '2026-07-18 09:00:00'),
  (1, 'When to Donate Blood: A Quick Guide',       'when-to-donate-blood-quick-guide',
     'Eligibility basics, timing between donations, and how to prepare.',
     'Most healthy adults between 18 and 60 weighing over 50kg can donate every three to four months. Hydrate well the day before, eat a normal meal beforehand, and avoid heavy exercise for the rest of the day. If you take regular medication, check with the collection centre first.',
     'Blood Bank', 1, '2026-07-25 09:00:00');

INSERT INTO reviews (user_id, target_type, target_id, rating, comment) VALUES
  (2, 'doctor',   1, 5, 'Explained the treatment plan clearly and did not rush the consultation.'),
  (3, 'doctor',   2, 4, 'Very knowledgeable about Panchakarma. Waiting time was a bit long.'),
  (2, 'pharmacy', 1, 5, 'Open at 2am when I needed medicine urgently. Genuine stock.'),
  (3, 'hospital', 1, 4, 'Clean facility and responsive emergency desk.');

INSERT INTO feedback (user_id, name, email, message, status) VALUES
  (2,    'Rahim Uddin', 'patient@ayur.test', 'Please add Bangla language support in the app.', 'new'),
  (NULL, 'Guest User',  'guest@example.com', 'The doctor list could show consultation fees more prominently.', 'new');

-- Keep AUTO_INCREMENT above the explicit IDs used in seeds.
ALTER TABLE users              AUTO_INCREMENT = 100;
ALTER TABLE clinics            AUTO_INCREMENT = 100;
ALTER TABLE hospitals          AUTO_INCREMENT = 100;
ALTER TABLE pharmacies         AUTO_INCREMENT = 100;
ALTER TABLE doctors            AUTO_INCREMENT = 100;
ALTER TABLE appointments       AUTO_INCREMENT = 100;
ALTER TABLE pharmacy_products  AUTO_INCREMENT = 100;
ALTER TABLE orders             AUTO_INCREMENT = 100;
