-- phpMyAdmin SQL Dump
-- version 5.2.1
-- https://www.phpmyadmin.net/
--
-- Host: 127.0.0.1:3307
-- Generation Time: Aug 03, 2026 at 01:50 PM
-- Server version: 10.4.32-MariaDB
-- PHP Version: 8.2.12

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
START TRANSACTION;
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8mb4 */;

--
-- Database: `ayur_db`
--

-- --------------------------------------------------------

--
-- Table structure for table `appointments`
--

CREATE TABLE `appointments` (
  `id` int(11) NOT NULL,
  `patient_id` int(11) NOT NULL,
  `doctor_id` int(11) NOT NULL,
  `appointment_date` date NOT NULL,
  `appointment_time` time NOT NULL,
  `type` enum('new','followup','online') DEFAULT 'new',
  `symptoms` text DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `fee` decimal(10,2) DEFAULT 0.00,
  `status` enum('pending','confirmed','completed','cancelled') DEFAULT 'pending',
  `payment_status` enum('pending','paid','refunded') DEFAULT 'pending',
  `payment_verified_at` timestamp NULL DEFAULT NULL,
  `payment_verified_by` int(11) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `confirmation_code` varchar(12) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `appointments`
--

INSERT INTO `appointments` (`id`, `patient_id`, `doctor_id`, `appointment_date`, `appointment_time`, `type`, `symptoms`, `notes`, `fee`, `status`, `payment_status`, `payment_verified_at`, `payment_verified_by`, `created_at`, `updated_at`, `confirmation_code`) VALUES
(104, 125, 100, '2026-08-04', '17:00:00', 'new', NULL, NULL, 1400.00, 'pending', 'pending', NULL, NULL, '2026-08-01 07:01:59', '2026-08-01 07:01:59', NULL),
(105, 125, 2, '2026-08-06', '20:30:00', 'new', 'checkup', NULL, 1000.00, 'pending', 'pending', NULL, NULL, '2026-08-01 07:08:05', '2026-08-01 07:08:05', NULL),
(106, 125, 1, '2026-08-03', '19:30:00', 'new', 'djhdkk', NULL, 1500.00, 'pending', 'pending', NULL, NULL, '2026-08-01 07:09:46', '2026-08-01 07:09:46', NULL),
(107, 126, 103, '2026-08-05', '01:21:00', '', '', NULL, 0.00, 'completed', 'pending', NULL, NULL, '2026-08-01 07:18:15', '2026-08-03 09:08:26', 'N9EY3H92'),
(108, 127, 1, '2026-08-04', '17:30:00', 'new', NULL, NULL, 1500.00, 'pending', 'pending', NULL, NULL, '2026-08-02 13:28:46', '2026-08-02 13:28:46', NULL),
(109, 127, 1, '2026-08-03', '19:00:00', 'new', NULL, NULL, 1500.00, 'pending', 'pending', NULL, NULL, '2026-08-03 01:58:52', '2026-08-03 01:58:52', NULL),
(110, 127, 103, '2026-08-04', '03:51:00', 'new', NULL, NULL, 500.00, 'confirmed', 'pending', NULL, NULL, '2026-08-03 11:26:53', '2026-08-03 11:27:34', '52G2MXPM');

--
-- Triggers `appointments`
--
DELIMITER $$
CREATE TRIGGER `appointments_after_insert` AFTER INSERT ON `appointments` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'appointments',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'patient_id', NEW.patient_id,
            'doctor_id', NEW.doctor_id,
            'appointment_date', NEW.appointment_date,
            'appointment_time', NEW.appointment_time,
            'type', NEW.type,
            'fee', NEW.fee,
            'status', NEW.status,
            'payment_status', NEW.payment_status,
            'confirmation_code', NEW.confirmation_code
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `appointments_after_update` AFTER UPDATE ON `appointments` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.appointment_date != NEW.appointment_date THEN SET changed = CONCAT(changed, 'appointment_date,'); END IF;
    IF OLD.appointment_time != NEW.appointment_time THEN SET changed = CONCAT(changed, 'appointment_time,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF IFNULL(OLD.payment_status,'') != IFNULL(NEW.payment_status,'') THEN SET changed = CONCAT(changed, 'payment_status,'); END IF;
    IF IFNULL(OLD.notes,'') != IFNULL(NEW.notes,'') THEN SET changed = CONCAT(changed, 'notes,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'appointments',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'patient_id', OLD.patient_id,
                'doctor_id', OLD.doctor_id,
                'appointment_date', OLD.appointment_date,
                'appointment_time', OLD.appointment_time,
                'status', OLD.status,
                'payment_status', OLD.payment_status
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'patient_id', NEW.patient_id,
                'doctor_id', NEW.doctor_id,
                'appointment_date', NEW.appointment_date,
                'appointment_time', NEW.appointment_time,
                'status', NEW.status,
                'payment_status', NEW.payment_status
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `appointments_before_delete` BEFORE DELETE ON `appointments` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'appointments',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'patient_id', OLD.patient_id,
            'doctor_id', OLD.doctor_id,
            'appointment_date', OLD.appointment_date,
            'appointment_time', OLD.appointment_time,
            'status', OLD.status,
            'payment_status', OLD.payment_status,
            'confirmation_code', OLD.confirmation_code
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `app_audit_log`
--

CREATE TABLE `app_audit_log` (
  `id` bigint(20) NOT NULL,
  `user_id` int(11) DEFAULT NULL,
  `action` varchar(50) NOT NULL COMMENT 'login|logout|create|update|change_password|...',
  `entity` varchar(50) DEFAULT NULL,
  `entity_id` int(11) DEFAULT NULL,
  `details` text DEFAULT NULL COMMENT 'JSON',
  `ip_address` varchar(45) DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `app_audit_log`
--

INSERT INTO `app_audit_log` (`id`, `user_id`, `action`, `entity`, `entity_id`, `details`, `ip_address`, `created_at`) VALUES
(1, 125, 'create', 'users', 125, '{\"role\":\"patient\"}', '::1', '2026-08-01 06:51:46'),
(2, 125, 'update', 'users', 125, '[\"address\",\"city\",\"blood_group\"]', '::1', '2026-08-01 06:52:27'),
(3, 125, 'logout', 'users', 125, NULL, '::1', '2026-08-01 07:00:45'),
(4, 125, 'login', 'users', 125, NULL, '::1', '2026-08-01 07:01:00'),
(5, 125, 'logout', 'users', 125, NULL, '::1', '2026-08-01 07:20:59'),
(6, 126, 'login', 'users', 126, NULL, '::1', '2026-08-01 07:21:24'),
(7, 126, 'logout', 'users', 126, NULL, '::1', '2026-08-01 07:21:42'),
(8, 127, 'create', 'users', 127, '{\"role\":\"patient\"}', '127.0.0.1', '2026-08-02 13:27:27'),
(9, 127, 'login', 'users', 127, NULL, '::1', '2026-08-02 15:49:23'),
(10, 127, 'login', 'users', 127, NULL, '::1', '2026-08-02 16:00:01'),
(11, 127, 'login', 'users', 127, NULL, '::1', '2026-08-02 16:07:12'),
(12, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 01:58:39'),
(13, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 03:16:09'),
(14, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 04:48:53'),
(15, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 09:02:22'),
(16, 127, 'logout', 'users', 127, NULL, '::1', '2026-08-03 09:04:02'),
(17, 126, 'login', 'users', 126, NULL, '::1', '2026-08-03 09:04:14'),
(18, 126, 'update', 'appointments', 107, '{\"from\":\"pending\",\"to\":\"confirmed\"}', '::1', '2026-08-03 09:04:28'),
(19, 126, 'update', 'doctors', 103, '[\"name\",\"phone\",\"medical_school\",\"graduation_year\",\"doctor_type\",\"specialization\",\"qualifications\",\"hospital_clinic_name\",\"chamber_address\",\"city\",\"consultation_fee\",\"bio\",\"available_days\",\"available_from\",\"available_to\",\"slot_minutes\"]', '::1', '2026-08-03 09:05:01'),
(20, 126, 'update', 'doctors', 103, '[\"name\",\"phone\",\"medical_school\",\"graduation_year\",\"doctor_type\",\"specialization\",\"qualifications\",\"hospital_clinic_name\",\"chamber_address\",\"city\",\"consultation_fee\",\"bio\",\"available_days\",\"available_from\",\"available_to\",\"slot_minutes\"]', '::1', '2026-08-03 09:05:15'),
(21, 126, 'logout', 'users', 126, NULL, '::1', '2026-08-03 09:05:43'),
(22, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 09:05:56'),
(23, 127, 'logout', 'users', 127, NULL, '::1', '2026-08-03 09:07:31'),
(24, 126, 'login', 'users', 126, NULL, '::1', '2026-08-03 09:07:43'),
(25, 126, 'update', 'appointments', 107, '{\"from\":\"confirmed\",\"to\":\"completed\"}', '::1', '2026-08-03 09:08:26'),
(26, 126, 'update', 'doctors', 103, '[\"name\",\"phone\",\"medical_school\",\"graduation_year\",\"doctor_type\",\"specialization\",\"qualifications\",\"hospital_clinic_name\",\"chamber_address\",\"city\",\"consultation_fee\",\"bio\",\"available_days\",\"available_from\",\"available_to\",\"slot_minutes\"]', '::1', '2026-08-03 09:09:00'),
(27, 126, 'logout', 'users', 126, NULL, '::1', '2026-08-03 09:09:45'),
(28, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 09:10:23'),
(29, 127, 'logout', 'users', 127, NULL, '::1', '2026-08-03 09:16:25'),
(30, 5, 'login', 'users', 5, NULL, '::1', '2026-08-03 09:16:31'),
(31, 5, 'logout', 'users', 5, NULL, '::1', '2026-08-03 09:17:39'),
(32, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 09:18:16'),
(33, 127, 'logout', 'users', 127, NULL, '::1', '2026-08-03 09:20:57'),
(34, 126, 'login', 'users', 126, NULL, '::1', '2026-08-03 09:21:08'),
(35, 126, 'update', 'doctors', 103, '[\"name\",\"phone\",\"medical_school\",\"graduation_year\",\"doctor_type\",\"specialization\",\"qualifications\",\"experience_years\",\"hospital_clinic_name\",\"chamber_address\",\"city\",\"area\",\"consultation_fee\",\"bio\",\"available_days\",\"available_from\",\"available_to\",\"slot_minutes\"]', '::1', '2026-08-03 09:21:52'),
(36, 126, 'logout', 'users', 126, NULL, '::1', '2026-08-03 09:22:08'),
(37, 5, 'login', 'users', 5, NULL, '::1', '2026-08-03 09:24:39'),
(38, 5, 'logout', 'users', 5, NULL, '::1', '2026-08-03 09:24:59'),
(39, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 09:25:10'),
(40, 127, 'logout', 'users', 127, NULL, '::1', '2026-08-03 09:26:44'),
(41, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 09:27:11'),
(42, 127, 'login', 'users', 127, NULL, '::1', '2026-08-03 11:26:08'),
(43, 127, 'create', 'reviews', 11, '{\"target\":\"doctor#103\",\"rating\":3}', '::1', '2026-08-03 11:26:30'),
(44, 127, 'logout', 'users', 127, NULL, '::1', '2026-08-03 11:27:03'),
(45, 126, 'login', 'users', 126, NULL, '::1', '2026-08-03 11:27:29'),
(46, 126, 'update', 'appointments', 110, '{\"from\":\"pending\",\"to\":\"confirmed\"}', '::1', '2026-08-03 11:27:34'),
(47, 126, 'logout', 'users', 126, NULL, '::1', '2026-08-03 11:27:55'),
(48, 5, 'login', 'users', 5, NULL, '::1', '2026-08-03 11:28:44'),
(49, 5, 'approve', 'reviews', 11, '{\"target\":\"doctor#103\"}', '::1', '2026-08-03 11:28:49'),
(50, 5, 'logout', 'users', 5, NULL, '::1', '2026-08-03 11:30:15');

-- --------------------------------------------------------

--
-- Table structure for table `audit_log`
--

CREATE TABLE `audit_log` (
  `id` bigint(20) NOT NULL,
  `table_name` varchar(100) NOT NULL,
  `record_id` int(11) NOT NULL,
  `action_type` enum('INSERT','UPDATE','DELETE') NOT NULL,
  `old_values` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`old_values`)),
  `new_values` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL CHECK (json_valid(`new_values`)),
  `changed_fields` text DEFAULT NULL,
  `action_timestamp` timestamp NOT NULL DEFAULT current_timestamp(),
  `ip_address` varchar(45) DEFAULT NULL,
  `user_agent` text DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `audit_log`
--

INSERT INTO `audit_log` (`id`, `table_name`, `record_id`, `action_type`, `old_values`, `new_values`, `changed_fields`, `action_timestamp`, `ip_address`, `user_agent`) VALUES
(1, 'users', 7, 'UPDATE', '{\"id\": 7, \"name\": \"pollob\", \"email\": \"pollob@gmail.com\", \"phone\": \"01834023685\", \"gender\": null, \"address\": \"Sadar road,12\", \"role\": \"patient\"}', '{\"id\": 7, \"name\": \"pollob\", \"email\": \"pollob@gmail.com\", \"phone\": \"01835457475\", \"gender\": null, \"address\": \"Sadar road,12\", \"role\": \"patient\"}', 'phone', '2025-12-31 22:36:08', NULL, NULL),
(2, 'reviews', 4, 'INSERT', NULL, '{\"id\": 4, \"user_id\": 2, \"reviewable_type\": \"doctor\", \"reviewable_id\": 1, \"rating\": 5, \"comment\": \"Excellent doctor! Very professional and caring. The consultation was thorough and he explained everything clearly. Highly recommended for anyone seeking quality healthcare.\", \"status\": \"approved\"}', NULL, '2025-12-31 22:42:38', NULL, NULL),
(3, 'reviews', 5, 'INSERT', NULL, '{\"id\": 5, \"user_id\": 6, \"reviewable_type\": \"doctor\", \"reviewable_id\": 2, \"rating\": 5, \"comment\": \"Best experience ever! The doctor was very attentive and took time to understand my concerns. The treatment was effective and I recovered quickly.\", \"status\": \"approved\"}', NULL, '2025-12-31 22:42:38', NULL, NULL),
(4, 'reviews', 6, 'INSERT', NULL, '{\"id\": 6, \"user_id\": 7, \"reviewable_type\": \"doctor\", \"reviewable_id\": 3, \"rating\": 4, \"comment\": \"Very good service. The doctor was knowledgeable and provided great advice. The clinic was clean and well-organized. Will definitely visit again.\", \"status\": \"approved\"}', NULL, '2025-12-31 22:42:38', NULL, NULL),
(5, 'reviews', 7, 'INSERT', NULL, '{\"id\": 7, \"user_id\": 8, \"reviewable_type\": \"doctor\", \"reviewable_id\": 4, \"rating\": 5, \"comment\": \"Amazing healthcare service! The staff was friendly and the doctor was extremely helpful. Got my appointment quickly through this platform.\", \"status\": \"approved\"}', NULL, '2025-12-31 22:42:38', NULL, NULL),
(6, 'reviews', 8, 'INSERT', NULL, '{\"id\": 8, \"user_id\": 9, \"reviewable_type\": \"doctor\", \"reviewable_id\": 5, \"rating\": 4, \"comment\": \"Great platform for finding doctors. I found a specialist easily and the booking process was smooth. The doctor was professional and helpful.\", \"status\": \"approved\"}', NULL, '2025-12-31 22:42:38', NULL, NULL),
(7, 'reviews', 9, 'INSERT', NULL, '{\"id\": 9, \"user_id\": 2, \"reviewable_type\": \"doctor\", \"reviewable_id\": 6, \"rating\": 5, \"comment\": \"Ayur made it so easy to find the right doctor for my needs. The consultation was excellent and I feel much better now. Thank you!\", \"status\": \"approved\"}', NULL, '2025-12-31 22:42:38', NULL, NULL),
(8, 'users', 7, 'UPDATE', '{\"id\": 7, \"name\": \"pollob\", \"email\": \"pollob@gmail.com\", \"phone\": \"01835457475\", \"gender\": null, \"address\": \"Sadar road,12\", \"role\": \"patient\"}', '{\"id\": 7, \"name\": \"pollob\", \"email\": \"pollob@gmail.com\", \"phone\": \"01835457475\", \"gender\": null, \"address\": \"Sadar road,12\", \"role\": \"patient\"}', 'profile_image', '2025-12-31 22:51:18', NULL, NULL),
(9, 'users', 118, 'DELETE', '{\"id\": 118, \"name\": \"Donor 118\", \"email\": \"donor118@ayur.com\", \"phone\": \"01720000118\", \"gender\": \"male\", \"address\": \"Barishal Sadar, Barishal\", \"profile_image\": null, \"role\": \"patient\", \"created_at\": \"2025-12-30 10:08:00\", \"updated_at\": \"2025-12-30 10:08:00\"}', NULL, NULL, '2026-01-02 23:37:36', NULL, NULL),
(10, 'users', 123, 'INSERT', NULL, '{\"id\": 123, \"name\": \"abcd\", \"email\": \"abcd@gmail.com\", \"phone\": \"01834562355\", \"gender\": null, \"address\": \"patuakhali\", \"role\": \"patient\", \"created_at\": \"2026-01-03 05:39:57\"}', NULL, '2026-01-02 23:39:57', NULL, NULL),
(11, 'reviews', 10, 'INSERT', NULL, '{\"id\": 10, \"user_id\": 123, \"reviewable_type\": \"doctor\", \"reviewable_id\": 1, \"rating\": 3, \"comment\": \"good doctor\", \"status\": \"pending\"}', NULL, '2026-01-02 23:41:11', NULL, NULL),
(12, 'reviews', 10, 'UPDATE', '{\"id\": 10, \"user_id\": 123, \"reviewable_type\": \"doctor\", \"reviewable_id\": 1, \"rating\": 3, \"comment\": \"good doctor\", \"status\": \"pending\"}', '{\"id\": 10, \"user_id\": 123, \"reviewable_type\": \"doctor\", \"reviewable_id\": 1, \"rating\": 3, \"comment\": \"good doctor\", \"status\": \"approved\"}', 'status', '2026-01-02 23:42:02', NULL, NULL),
(13, 'doctors', 1, 'UPDATE', '{\"id\": 1, \"specialization\": \"Cardiologist\", \"qualifications\": \"MBBS, FCPS (Cardiology)\", \"experience_years\": 14, \"consultation_fee\": 1500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Dhaka\", \"rating\": 3.00}', '{\"id\": 1, \"specialization\": \"Cardiologist\", \"qualifications\": \"MBBS, FCPS (Cardiology)\", \"experience_years\": 14, \"consultation_fee\": 1500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Dhaka\", \"rating\": 4.00}', 'rating', '2026-01-02 23:42:02', NULL, NULL),
(14, 'blood_banks', 4, 'INSERT', NULL, '{\"id\": 4, \"name\": \"ezaz\", \"address\": \"patuakhali\", \"city\": \"Chittagong\", \"phone\": \"01834562355\", \"email\": \"ezaz@gmail.com\", \"blood_a_positive\": 0, \"blood_a_negative\": 3, \"blood_b_positive\": 0, \"blood_b_negative\": 0, \"blood_ab_positive\": 2, \"blood_ab_negative\": 0, \"blood_o_positive\": 0, \"blood_o_negative\": 0, \"status\": \"active\"}', NULL, '2026-01-03 00:07:21', NULL, NULL),
(15, 'users', 119, 'DELETE', '{\"id\": 119, \"name\": \"Donor 119\", \"email\": \"donor119@ayur.com\", \"phone\": \"01720000119\", \"gender\": \"female\", \"address\": \"Rangpur Sadar, Rangpur\", \"profile_image\": null, \"role\": \"patient\", \"created_at\": \"2025-12-30 10:09:00\", \"updated_at\": \"2025-12-30 10:09:00\"}', NULL, NULL, '2026-01-03 12:00:18', NULL, NULL),
(16, 'doctors', 102, 'UPDATE', '{\"id\": 102, \"specialization\": \"Epileptologist\", \"qualifications\": \"MBBS, MD (Neurology)\", \"experience_years\": 13, \"consultation_fee\": 1700.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Chattogram\", \"rating\": 0.00}', '{\"id\": 102, \"specialization\": \"Epileptologist\", \"qualifications\": \"MBBS, MD (Neurology)\", \"experience_years\": 13, \"consultation_fee\": 1700.00, \"verification_status\": \"verified\", \"status\": \"inactive\", \"city\": \"Chattogram\", \"rating\": 0.00}', 'status', '2026-01-03 12:59:15', NULL, NULL),
(17, 'users', 124, 'INSERT', NULL, '{\"id\": 124, \"name\": \"shahriar ahmed\", \"email\": \"shahriar@gmail.com\", \"phone\": \"01938298192\", \"gender\": null, \"address\": \"dumki patuakhali\", \"role\": \"patient\", \"created_at\": \"2026-07-31 13:16:46\"}', NULL, '2026-07-31 07:16:46', NULL, NULL),
(18, 'users', 125, 'INSERT', NULL, '{\"id\": 125, \"name\": \"shah\", \"email\": \"shah@gmail.com\", \"phone\": \"01736253456\", \"gender\": null, \"address\": null, \"role\": \"patient\", \"created_at\": \"2026-08-01 12:51:45\"}', NULL, '2026-08-01 06:51:45', NULL, NULL),
(19, 'users', 125, 'UPDATE', '{\"id\": 125, \"name\": \"shah\", \"email\": \"shah@gmail.com\", \"phone\": \"01736253456\", \"gender\": null, \"address\": null, \"role\": \"patient\"}', '{\"id\": 125, \"name\": \"shah\", \"email\": \"shah@gmail.com\", \"phone\": \"01736253456\", \"gender\": null, \"address\": \"dumki\", \"role\": \"patient\"}', 'address', '2026-08-01 06:52:27', NULL, NULL),
(20, 'appointments', 104, 'INSERT', NULL, '{\"id\": 104, \"patient_id\": 125, \"doctor_id\": 100, \"appointment_date\": \"2026-08-04\", \"appointment_time\": \"17:00:00\", \"type\": \"new\", \"fee\": 1400.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-01 07:01:59', NULL, NULL),
(21, 'appointments', 105, 'INSERT', NULL, '{\"id\": 105, \"patient_id\": 125, \"doctor_id\": 2, \"appointment_date\": \"2026-08-06\", \"appointment_time\": \"20:30:00\", \"type\": \"new\", \"fee\": 1000.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-01 07:08:05', NULL, NULL),
(22, 'appointments', 106, 'INSERT', NULL, '{\"id\": 106, \"patient_id\": 125, \"doctor_id\": 1, \"appointment_date\": \"2026-08-03\", \"appointment_time\": \"19:30:00\", \"type\": \"new\", \"fee\": 1500.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-01 07:09:46', NULL, NULL),
(23, 'users', 126, 'INSERT', NULL, '{\"id\": 126, \"name\": \"shahriar ahmed\", \"email\": \"shahriarahmed@gmail.com\", \"phone\": \"01712457832\", \"gender\": \"male\", \"address\": null, \"role\": \"doctor\", \"created_at\": \"2026-08-01 13:13:03\"}', NULL, '2026-08-01 07:13:03', NULL, NULL),
(24, 'doctors', 103, 'INSERT', NULL, '{\"id\": 103, \"user_id\": 126, \"bmdc_registration_number\": \"145214\", \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 0, \"doctor_type\": \"general\", \"hospital_clinic_name\": \"Dumki hospital\", \"city\": \"Sylhet\", \"consultation_fee\": 500.00, \"verification_status\": \"pending\", \"status\": \"pending\"}', NULL, '2026-08-01 07:13:03', NULL, NULL),
(25, 'doctors', 103, 'UPDATE', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 0, \"consultation_fee\": 500.00, \"verification_status\": \"pending\", \"status\": \"pending\", \"city\": \"Sylhet\", \"rating\": 0.00}', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 0, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 0.00}', 'verification_status,status', '2026-08-01 07:14:04', NULL, NULL),
(26, 'doctors', 103, 'UPDATE', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 0, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 0.00}', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 0, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 0.00}', 'bio', '2026-08-01 07:15:27', NULL, NULL),
(27, 'appointments', 107, 'INSERT', NULL, '{\"id\": 107, \"patient_id\": 126, \"doctor_id\": 103, \"appointment_date\": \"2026-08-05\", \"appointment_time\": \"01:21:00\", \"type\": \"\", \"fee\": 0.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-01 07:18:15', NULL, NULL),
(28, 'users', 127, 'INSERT', NULL, '{\"id\": 127, \"name\": \"abc\", \"email\": \"abc1@gmail.com\", \"phone\": \"01823745618\", \"gender\": null, \"address\": null, \"role\": \"patient\", \"created_at\": \"2026-08-02 19:27:27\"}', NULL, '2026-08-02 13:27:27', NULL, NULL),
(29, 'appointments', 108, 'INSERT', NULL, '{\"id\": 108, \"patient_id\": 127, \"doctor_id\": 1, \"appointment_date\": \"2026-08-04\", \"appointment_time\": \"17:30:00\", \"type\": \"new\", \"fee\": 1500.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-02 13:28:46', NULL, NULL),
(30, 'appointments', 109, 'INSERT', NULL, '{\"id\": 109, \"patient_id\": 127, \"doctor_id\": 1, \"appointment_date\": \"2026-08-03\", \"appointment_time\": \"19:00:00\", \"type\": \"new\", \"fee\": 1500.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-03 01:58:52', NULL, NULL),
(31, 'appointments', 107, 'UPDATE', '{\"id\": 107, \"patient_id\": 126, \"doctor_id\": 103, \"appointment_date\": \"2026-08-05\", \"appointment_time\": \"01:21:00\", \"status\": \"pending\", \"payment_status\": \"pending\"}', '{\"id\": 107, \"patient_id\": 126, \"doctor_id\": 103, \"appointment_date\": \"2026-08-05\", \"appointment_time\": \"01:21:00\", \"status\": \"confirmed\", \"payment_status\": \"pending\"}', 'status', '2026-08-03 09:04:28', NULL, NULL),
(32, 'appointments', 107, 'UPDATE', '{\"id\": 107, \"patient_id\": 126, \"doctor_id\": 103, \"appointment_date\": \"2026-08-05\", \"appointment_time\": \"01:21:00\", \"status\": \"confirmed\", \"payment_status\": \"pending\"}', '{\"id\": 107, \"patient_id\": 126, \"doctor_id\": 103, \"appointment_date\": \"2026-08-05\", \"appointment_time\": \"01:21:00\", \"status\": \"completed\", \"payment_status\": \"pending\"}', 'status', '2026-08-03 09:08:26', NULL, NULL),
(33, 'doctors', 103, 'UPDATE', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 0, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 0.00}', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 10, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 0.00}', 'experience_years', '2026-08-03 09:21:52', NULL, NULL),
(34, 'reviews', 11, 'INSERT', NULL, '{\"id\": 11, \"user_id\": 127, \"reviewable_type\": \"doctor\", \"reviewable_id\": 103, \"rating\": 3, \"comment\": \"good doctor\", \"status\": \"pending\"}', NULL, '2026-08-03 11:26:30', NULL, NULL),
(35, 'appointments', 110, 'INSERT', NULL, '{\"id\": 110, \"patient_id\": 127, \"doctor_id\": 103, \"appointment_date\": \"2026-08-04\", \"appointment_time\": \"03:51:00\", \"type\": \"new\", \"fee\": 500.00, \"status\": \"pending\", \"payment_status\": \"pending\", \"confirmation_code\": null}', NULL, '2026-08-03 11:26:53', NULL, NULL),
(36, 'appointments', 110, 'UPDATE', '{\"id\": 110, \"patient_id\": 127, \"doctor_id\": 103, \"appointment_date\": \"2026-08-04\", \"appointment_time\": \"03:51:00\", \"status\": \"pending\", \"payment_status\": \"pending\"}', '{\"id\": 110, \"patient_id\": 127, \"doctor_id\": 103, \"appointment_date\": \"2026-08-04\", \"appointment_time\": \"03:51:00\", \"status\": \"confirmed\", \"payment_status\": \"pending\"}', 'status', '2026-08-03 11:27:34', NULL, NULL),
(37, 'reviews', 11, 'UPDATE', '{\"id\": 11, \"user_id\": 127, \"reviewable_type\": \"doctor\", \"reviewable_id\": 103, \"rating\": 3, \"comment\": \"good doctor\", \"status\": \"pending\"}', '{\"id\": 11, \"user_id\": 127, \"reviewable_type\": \"doctor\", \"reviewable_id\": 103, \"rating\": 3, \"comment\": \"good doctor\", \"status\": \"approved\"}', 'status', '2026-08-03 11:28:49', NULL, NULL),
(38, 'doctors', 103, 'UPDATE', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 10, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 0.00}', '{\"id\": 103, \"specialization\": \"Oncologist\", \"qualifications\": \"MBBS\", \"experience_years\": 10, \"consultation_fee\": 500.00, \"verification_status\": \"verified\", \"status\": \"active\", \"city\": \"Sylhet\", \"rating\": 3.00}', 'rating', '2026-08-03 11:28:49', NULL, NULL);

-- --------------------------------------------------------

--
-- Table structure for table `blogs`
--

CREATE TABLE `blogs` (
  `id` int(11) NOT NULL,
  `author_id` int(11) DEFAULT NULL,
  `slug` varchar(200) NOT NULL,
  `title` varchar(255) NOT NULL,
  `excerpt` varchar(500) DEFAULT NULL,
  `content` longtext NOT NULL,
  `cover_image` varchar(255) DEFAULT NULL,
  `category` varchar(100) DEFAULT NULL,
  `tags` varchar(255) DEFAULT NULL COMMENT 'comma separated',
  `status` enum('draft','published') DEFAULT 'draft',
  `published_at` timestamp NULL DEFAULT NULL,
  `views` int(11) NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `blogs`
--

INSERT INTO `blogs` (`id`, `author_id`, `slug`, `title`, `excerpt`, `content`, `cover_image`, `category`, `tags`, `status`, `published_at`, `views`, `created_at`, `updated_at`) VALUES
(1, NULL, 'welcome-to-ayur', 'Welcome to AYUR', 'What this platform is for, and how to get the most out of it.', 'AYUR connects patients across Bangladesh with verified Ayurvedic and allopathic practitioners, clinics, hospitals, pharmacies and blood banks.\n\nYou can search the doctor directory by specialization and city, view a practitioner\'s qualifications and chamber address, and book an appointment for an available slot. After booking you will receive a confirmation code — keep it, the chamber will ask for it.\n\nThe blood bank section lists current stock at participating banks and lets you post a request when you need donors urgently.\n\nNothing on this platform is a substitute for professional medical advice. In an emergency, go to your nearest hospital.', NULL, 'Announcements', NULL, 'published', '2026-08-01 06:06:47', 0, '2026-08-01 06:06:47', '2026-08-01 06:06:47'),
(2, NULL, 'preparing-for-your-appointment', 'Preparing for your first appointment', 'A short checklist that makes a consultation go further.', 'Bring any previous prescriptions, test reports and a list of medicines you currently take, including supplements. Doses matter, so photograph the labels if you are unsure.\n\nWrite down your symptoms before you go: when they started, what makes them better or worse, and how they affect sleep and appetite. It is easy to forget details once the consultation starts.\n\nArrive a few minutes early with your confirmation code. If you need to cancel, do it from the Appointments tab so the slot returns to the pool for someone else.\n\nIf you were asked to fast before a test, confirm how many hours — it is usually eight to twelve.', NULL, 'Patient Guides', NULL, 'published', '2026-08-01 06:06:47', 0, '2026-08-01 06:06:47', '2026-08-01 06:06:47');

-- --------------------------------------------------------

--
-- Table structure for table `blood_banks`
--

CREATE TABLE `blood_banks` (
  `id` int(11) NOT NULL,
  `name` varchar(255) NOT NULL,
  `address` text NOT NULL,
  `city` varchar(100) NOT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `email` varchar(100) DEFAULT NULL,
  `blood_a_positive` int(11) DEFAULT 0,
  `blood_a_negative` int(11) DEFAULT 0,
  `blood_b_positive` int(11) DEFAULT 0,
  `blood_b_negative` int(11) DEFAULT 0,
  `blood_ab_positive` int(11) DEFAULT 0,
  `blood_ab_negative` int(11) DEFAULT 0,
  `blood_o_positive` int(11) DEFAULT 0,
  `blood_o_negative` int(11) DEFAULT 0,
  `status` enum('active','inactive') DEFAULT 'active',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

--
-- Dumping data for table `blood_banks`
--

INSERT INTO `blood_banks` (`id`, `name`, `address`, `city`, `phone`, `email`, `blood_a_positive`, `blood_a_negative`, `blood_b_positive`, `blood_b_negative`, `blood_ab_positive`, `blood_ab_negative`, `blood_o_positive`, `blood_o_negative`, `status`, `created_at`, `updated_at`) VALUES
(1, 'Badhon', 'PSTU', 'Patuakhali', '01834562355', 'ezaz@gmail.com', 4, 5, 4, 0, 5, 0, 5, 0, 'active', '2026-01-02 23:52:40', '2026-01-02 23:52:40'),
(2, 'aabb', 'patuakhali', 'Chittagong', '01834562355', 'aabb@gmail.com', 0, 3, 0, 0, 3, 0, 0, 0, 'active', '2026-01-02 23:57:03', '2026-01-02 23:57:03'),
(3, 'ahmed', 'patuakhali', 'Chittagong', '01834562355', 'ahmed@gmail.com', 0, 3, 0, 0, 2, 0, 0, 0, 'active', '2026-01-03 00:05:14', '2026-01-03 00:05:14'),
(4, 'ezaz', 'patuakhali', 'Chittagong', '01834562355', 'ezaz@gmail.com', 0, 3, 0, 0, 2, 0, 0, 0, 'active', '2026-01-03 00:07:21', '2026-01-03 00:07:21');

--
-- Triggers `blood_banks`
--
DELIMITER $$
CREATE TRIGGER `blood_banks_after_insert` AFTER INSERT ON `blood_banks` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'blood_banks',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'name', NEW.name,
            'address', NEW.address,
            'city', NEW.city,
            'phone', NEW.phone,
            'email', NEW.email,
            'blood_a_positive', NEW.blood_a_positive,
            'blood_a_negative', NEW.blood_a_negative,
            'blood_b_positive', NEW.blood_b_positive,
            'blood_b_negative', NEW.blood_b_negative,
            'blood_ab_positive', NEW.blood_ab_positive,
            'blood_ab_negative', NEW.blood_ab_negative,
            'blood_o_positive', NEW.blood_o_positive,
            'blood_o_negative', NEW.blood_o_negative,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `blood_banks_after_update` AFTER UPDATE ON `blood_banks` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.name != NEW.name THEN SET changed = CONCAT(changed, 'name,'); END IF;
    IF IFNULL(OLD.address,'') != IFNULL(NEW.address,'') THEN SET changed = CONCAT(changed, 'address,'); END IF;
    IF OLD.city != NEW.city THEN SET changed = CONCAT(changed, 'city,'); END IF;
    IF IFNULL(OLD.phone,'') != IFNULL(NEW.phone,'') THEN SET changed = CONCAT(changed, 'phone,'); END IF;
    IF IFNULL(OLD.email,'') != IFNULL(NEW.email,'') THEN SET changed = CONCAT(changed, 'email,'); END IF;
    IF OLD.blood_a_positive != NEW.blood_a_positive THEN SET changed = CONCAT(changed, 'blood_a_positive,'); END IF;
    IF OLD.blood_a_negative != NEW.blood_a_negative THEN SET changed = CONCAT(changed, 'blood_a_negative,'); END IF;
    IF OLD.blood_b_positive != NEW.blood_b_positive THEN SET changed = CONCAT(changed, 'blood_b_positive,'); END IF;
    IF OLD.blood_b_negative != NEW.blood_b_negative THEN SET changed = CONCAT(changed, 'blood_b_negative,'); END IF;
    IF OLD.blood_ab_positive != NEW.blood_ab_positive THEN SET changed = CONCAT(changed, 'blood_ab_positive,'); END IF;
    IF OLD.blood_ab_negative != NEW.blood_ab_negative THEN SET changed = CONCAT(changed, 'blood_ab_negative,'); END IF;
    IF OLD.blood_o_positive != NEW.blood_o_positive THEN SET changed = CONCAT(changed, 'blood_o_positive,'); END IF;
    IF OLD.blood_o_negative != NEW.blood_o_negative THEN SET changed = CONCAT(changed, 'blood_o_negative,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'blood_banks',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'address', OLD.address,
                'city', OLD.city,
                'phone', OLD.phone,
                'email', OLD.email,
                'blood_a_positive', OLD.blood_a_positive,
                'blood_a_negative', OLD.blood_a_negative,
                'blood_b_positive', OLD.blood_b_positive,
                'blood_b_negative', OLD.blood_b_negative,
                'blood_ab_positive', OLD.blood_ab_positive,
                'blood_ab_negative', OLD.blood_ab_negative,
                'blood_o_positive', OLD.blood_o_positive,
                'blood_o_negative', OLD.blood_o_negative,
                'status', OLD.status
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'address', NEW.address,
                'city', NEW.city,
                'phone', NEW.phone,
                'email', NEW.email,
                'blood_a_positive', NEW.blood_a_positive,
                'blood_a_negative', NEW.blood_a_negative,
                'blood_b_positive', NEW.blood_b_positive,
                'blood_b_negative', NEW.blood_b_negative,
                'blood_ab_positive', NEW.blood_ab_positive,
                'blood_ab_negative', NEW.blood_ab_negative,
                'blood_o_positive', NEW.blood_o_positive,
                'blood_o_negative', NEW.blood_o_negative,
                'status', NEW.status
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `blood_banks_before_delete` BEFORE DELETE ON `blood_banks` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'blood_banks',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'name', OLD.name,
            'address', OLD.address,
            'city', OLD.city,
            'phone', OLD.phone,
            'email', OLD.email,
            'blood_a_positive', OLD.blood_a_positive,
            'blood_a_negative', OLD.blood_a_negative,
            'blood_b_positive', OLD.blood_b_positive,
            'blood_b_negative', OLD.blood_b_negative,
            'blood_ab_positive', OLD.blood_ab_positive,
            'blood_ab_negative', OLD.blood_ab_negative,
            'blood_o_positive', OLD.blood_o_positive,
            'blood_o_negative', OLD.blood_o_negative,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `blood_donors`
--

CREATE TABLE `blood_donors` (
  `id` int(11) NOT NULL,
  `user_id` int(11) DEFAULT NULL,
  `name` varchar(100) NOT NULL,
  `phone` varchar(20) NOT NULL,
  `email` varchar(100) DEFAULT NULL,
  `blood_group` enum('A+','A-','B+','B-','AB+','AB-','O+','O-') NOT NULL,
  `city` varchar(50) NOT NULL,
  `area` varchar(100) DEFAULT NULL,
  `address` text DEFAULT NULL,
  `last_donation_date` date DEFAULT NULL,
  `is_available` tinyint(1) DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `blood_donors`
--

INSERT INTO `blood_donors` (`id`, `user_id`, `name`, `phone`, `email`, `blood_group`, `city`, `area`, `address`, `last_donation_date`, `is_available`, `created_at`, `updated_at`) VALUES
(1, 110, 'Donor 110', '01720000110', 'donor110@ayur.com', 'A+', 'Dhaka', 'Mirpur', 'Mirpur, Dhaka', '2025-10-15', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(2, 111, 'Donor 111', '01720000111', 'donor111@ayur.com', 'B+', 'Dhaka', 'Gulshan', 'Gulshan-2, Dhaka', '2025-09-20', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(3, 112, 'Donor 112', '01720000112', 'donor112@ayur.com', 'O+', 'Dhaka', 'Uttara', 'Uttara Sector 7, Dhaka', '2025-08-05', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(4, 113, 'Donor 113', '01720000113', 'donor113@ayur.com', 'AB+', 'Dhaka', 'Dhanmondi', 'Road 10, Dhanmondi', '2025-07-12', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(5, 114, 'Donor 114', '01720000114', 'donor114@ayur.com', 'A-', 'Chattogram', 'Agrabad', 'Agrabad Access Rd, Chattogram', '2025-11-01', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(6, 115, 'Donor 115', '01720000115', 'donor115@ayur.com', 'B-', 'Sylhet', 'Zindabazar', 'Zindabazar, Sylhet', '2025-06-30', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(7, 116, 'Donor 116', '01720000116', 'donor116@ayur.com', 'O-', 'Rajshahi', 'Shaheb Bazar', 'Shaheb Bazar, Rajshahi', '2025-05-18', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(8, 117, 'Donor 117', '01720000117', 'donor117@ayur.com', 'AB-', 'Khulna', 'Boyra', 'Boyra Main Rd, Khulna', '2025-04-22', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(9, NULL, 'Donor 118', '01720000118', 'donor118@ayur.com', 'A+', 'Barishal', 'Sadar', 'Sadar Rd, Barishal', '2025-03-10', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00'),
(10, NULL, 'Donor 119', '01720000119', 'donor119@ayur.com', 'B+', 'Rangpur', 'Sadar', 'Sadar, Rangpur', '2025-02-14', 1, '2025-12-29 20:36:00', '2025-12-29 20:36:00');

--
-- Triggers `blood_donors`
--
DELIMITER $$
CREATE TRIGGER `blood_donors_after_insert` AFTER INSERT ON `blood_donors` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'blood_donors',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'name', NEW.name,
            'phone', NEW.phone,
            'blood_group', NEW.blood_group,
            'city', NEW.city,
            'is_available', NEW.is_available
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `blood_donors_after_update` AFTER UPDATE ON `blood_donors` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.name != NEW.name THEN SET changed = CONCAT(changed, 'name,'); END IF;
    IF OLD.phone != NEW.phone THEN SET changed = CONCAT(changed, 'phone,'); END IF;
    IF OLD.blood_group != NEW.blood_group THEN SET changed = CONCAT(changed, 'blood_group,'); END IF;
    IF OLD.city != NEW.city THEN SET changed = CONCAT(changed, 'city,'); END IF;
    IF OLD.is_available != NEW.is_available THEN SET changed = CONCAT(changed, 'is_available,'); END IF;
    IF IFNULL(OLD.last_donation_date,'') != IFNULL(NEW.last_donation_date,'') THEN SET changed = CONCAT(changed, 'last_donation_date,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'blood_donors',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'phone', OLD.phone,
                'blood_group', OLD.blood_group,
                'city', OLD.city,
                'is_available', OLD.is_available,
                'last_donation_date', OLD.last_donation_date
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'phone', NEW.phone,
                'blood_group', NEW.blood_group,
                'city', NEW.city,
                'is_available', NEW.is_available,
                'last_donation_date', NEW.last_donation_date
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `blood_donors_before_delete` BEFORE DELETE ON `blood_donors` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'blood_donors',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'name', OLD.name,
            'phone', OLD.phone,
            'blood_group', OLD.blood_group,
            'city', OLD.city,
            'is_available', OLD.is_available
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `blood_requests`
--

CREATE TABLE `blood_requests` (
  `id` int(11) NOT NULL,
  `requester_name` varchar(100) NOT NULL,
  `requester_phone` varchar(20) NOT NULL,
  `patient_name` varchar(100) NOT NULL,
  `blood_group` enum('A+','A-','B+','B-','AB+','AB-','O+','O-') NOT NULL,
  `units_needed` int(11) DEFAULT 1,
  `hospital_name` varchar(255) NOT NULL,
  `city` varchar(50) NOT NULL,
  `needed_by` date NOT NULL,
  `reason` text DEFAULT NULL,
  `status` enum('active','fulfilled','cancelled') DEFAULT 'active',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Triggers `blood_requests`
--
DELIMITER $$
CREATE TRIGGER `blood_requests_after_insert` AFTER INSERT ON `blood_requests` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'blood_requests',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'requester_name', NEW.requester_name,
            'requester_phone', NEW.requester_phone,
            'patient_name', NEW.patient_name,
            'blood_group', NEW.blood_group,
            'units_needed', NEW.units_needed,
            'hospital_name', NEW.hospital_name,
            'city', NEW.city,
            'needed_by', NEW.needed_by,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `blood_requests_after_update` AFTER UPDATE ON `blood_requests` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF OLD.units_needed != NEW.units_needed THEN SET changed = CONCAT(changed, 'units_needed,'); END IF;
    IF OLD.needed_by != NEW.needed_by THEN SET changed = CONCAT(changed, 'needed_by,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'blood_requests',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'requester_name', OLD.requester_name,
                'patient_name', OLD.patient_name,
                'blood_group', OLD.blood_group,
                'units_needed', OLD.units_needed,
                'status', OLD.status,
                'needed_by', OLD.needed_by
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'requester_name', NEW.requester_name,
                'patient_name', NEW.patient_name,
                'blood_group', NEW.blood_group,
                'units_needed', NEW.units_needed,
                'status', NEW.status,
                'needed_by', NEW.needed_by
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `blood_requests_before_delete` BEFORE DELETE ON `blood_requests` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'blood_requests',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'requester_name', OLD.requester_name,
            'requester_phone', OLD.requester_phone,
            'patient_name', OLD.patient_name,
            'blood_group', OLD.blood_group,
            'hospital_name', OLD.hospital_name,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `cart`
--

CREATE TABLE `cart` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `product_id` int(11) NOT NULL,
  `quantity` int(11) NOT NULL DEFAULT 1,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `clinics`
--

CREATE TABLE `clinics` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `name` varchar(255) NOT NULL,
  `registration_number` varchar(100) DEFAULT NULL,
  `license_number` varchar(100) DEFAULT NULL,
  `license_document` varchar(255) DEFAULT NULL,
  `email` varchar(100) DEFAULT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `website` varchar(255) DEFAULT NULL,
  `address` text NOT NULL,
  `city` varchar(50) NOT NULL,
  `area` varchar(100) DEFAULT NULL,
  `clinic_type` enum('general','dental','eye','diagnostic','specialized','polyclinic') DEFAULT 'general',
  `established_year` year(4) DEFAULT NULL,
  `services` text DEFAULT NULL,
  `specializations` text DEFAULT NULL,
  `available_days` varchar(100) DEFAULT NULL,
  `opening_time` time DEFAULT NULL,
  `closing_time` time DEFAULT NULL,
  `description` text DEFAULT NULL,
  `rating` decimal(3,2) DEFAULT 0.00,
  `total_reviews` int(11) DEFAULT 0,
  `verification_status` enum('pending','verified','rejected') DEFAULT 'pending',
  `status` enum('pending','active','inactive') DEFAULT 'pending',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Triggers `clinics`
--
DELIMITER $$
CREATE TRIGGER `clinics_after_insert` AFTER INSERT ON `clinics` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'clinics',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'name', NEW.name,
            'registration_number', NEW.registration_number,
            'city', NEW.city,
            'clinic_type', NEW.clinic_type,
            'verification_status', NEW.verification_status,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `clinics_after_update` AFTER UPDATE ON `clinics` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.name != NEW.name THEN SET changed = CONCAT(changed, 'name,'); END IF;
    IF IFNULL(OLD.phone,'') != IFNULL(NEW.phone,'') THEN SET changed = CONCAT(changed, 'phone,'); END IF;
    IF IFNULL(OLD.address,'') != IFNULL(NEW.address,'') THEN SET changed = CONCAT(changed, 'address,'); END IF;
    IF IFNULL(OLD.city,'') != IFNULL(NEW.city,'') THEN SET changed = CONCAT(changed, 'city,'); END IF;
    IF IFNULL(OLD.verification_status,'') != IFNULL(NEW.verification_status,'') THEN SET changed = CONCAT(changed, 'verification_status,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF OLD.rating != NEW.rating THEN SET changed = CONCAT(changed, 'rating,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'clinics',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'phone', OLD.phone,
                'address', OLD.address,
                'city', OLD.city,
                'verification_status', OLD.verification_status,
                'status', OLD.status,
                'rating', OLD.rating
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'phone', NEW.phone,
                'address', NEW.address,
                'city', NEW.city,
                'verification_status', NEW.verification_status,
                'status', NEW.status,
                'rating', NEW.rating
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `clinics_before_delete` BEFORE DELETE ON `clinics` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'clinics',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'name', OLD.name,
            'registration_number', OLD.registration_number,
            'city', OLD.city,
            'clinic_type', OLD.clinic_type,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `device_tokens`
--

CREATE TABLE `device_tokens` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `fcm_token` varchar(255) NOT NULL,
  `platform` enum('android','ios','web') DEFAULT 'android',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `doctors`
--

CREATE TABLE `doctors` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `bmdc_registration_number` varchar(50) DEFAULT NULL,
  `bmdc_certificate` varchar(255) DEFAULT NULL,
  `specialization` varchar(100) DEFAULT NULL,
  `qualifications` varchar(255) DEFAULT NULL,
  `medical_school` varchar(255) DEFAULT NULL,
  `graduation_year` year(4) DEFAULT NULL,
  `experience_years` int(11) DEFAULT 0,
  `doctor_type` enum('general','specialist','consultant') DEFAULT 'general',
  `hospital_clinic_name` varchar(255) DEFAULT NULL,
  `chamber_address` text DEFAULT NULL,
  `city` varchar(50) DEFAULT NULL,
  `area` varchar(100) DEFAULT NULL,
  `consultation_fee` decimal(10,2) DEFAULT 0.00,
  `bio` text DEFAULT NULL,
  `rating` decimal(3,2) DEFAULT 0.00,
  `total_reviews` int(11) DEFAULT 0,
  `verification_status` enum('pending','verified','rejected') DEFAULT 'pending',
  `status` enum('pending','active','inactive') DEFAULT 'pending',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `available_days` varchar(100) DEFAULT NULL COMMENT 'csv: sat,sun,mon,tue,wed,thu,fri',
  `available_from` time DEFAULT NULL COMMENT 'chamber start, e.g. 17:00:00',
  `available_to` time DEFAULT NULL COMMENT 'chamber end, e.g. 21:00:00',
  `slot_minutes` int(11) DEFAULT 30 COMMENT 'appointment length in minutes'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `doctors`
--

INSERT INTO `doctors` (`id`, `user_id`, `bmdc_registration_number`, `bmdc_certificate`, `specialization`, `qualifications`, `medical_school`, `graduation_year`, `experience_years`, `doctor_type`, `hospital_clinic_name`, `chamber_address`, `city`, `area`, `consultation_fee`, `bio`, `rating`, `total_reviews`, `verification_status`, `status`, `created_at`, `updated_at`, `available_days`, `available_from`, `available_to`, `slot_minutes`) VALUES
(1, 3, 'A-12345', NULL, 'Cardiologist', 'MBBS, FCPS (Cardiology)', 'Dhaka Medical College', '2010', 14, 'specialist', 'City Heart Hospital', 'House 123, Road 10, Dhanmondi', 'Dhaka', 'Dhanmondi', 1500.00, 'Experienced cardiologist specializing in heart diseases and cardiac care.', 4.00, 2, 'verified', 'active', '2025-12-28 13:03:13', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(2, 4, '125486932', NULL, 'Ophthalmologist', 'MBBS', 'Rajshahi Medical college', '2014', 5, 'specialist', 'Rajshahi Medical College', 'Sadar road,12', 'Rajshahi', 'sadar', 1000.00, 'i am a good doctor', 3.00, 1, 'verified', 'active', '2025-12-28 13:05:48', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(3, 10, 'A-10010', NULL, 'General Practitioner', 'MBBS', 'Dhaka Medical College', '2012', 12, 'general', 'Green Life Clinic', 'Road 4, Dhanmondi', 'Dhaka', 'Dhanmondi', 700.00, 'Primary care physician focusing on preventive medicine.', 0.00, 0, 'verified', 'active', '2025-12-30 02:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(4, 11, 'B-11011', NULL, 'Dermatologist', 'MBBS, MD (Dermatology)', 'Bangabandhu Sheikh Mujib Medical University', '2011', 13, 'specialist', 'Skin Care Center', 'House 22, Gulshan 2', 'Dhaka', 'Gulshan', 1200.00, 'Treats chronic and cosmetic skin conditions.', 0.00, 0, 'verified', 'active', '2025-12-30 02:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(5, 12, 'C-12012', NULL, 'Neurologist', 'MBBS, FCPS (Neurology)', 'Chittagong Medical College', '2009', 15, 'consultant', 'Neuro Care Hospital', 'Agrabad Access Rd', 'Chattogram', 'Agrabad', 1800.00, 'Manages stroke, epilepsy, and neuro disorders.', 0.00, 0, 'verified', 'active', '2025-12-30 02:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(6, 13, 'D-13013', NULL, 'Orthopedic Surgeon', 'MBBS, MS (Ortho)', 'Sylhet MAG Osmani Medical College', '2010', 14, 'consultant', 'Ortho Plus Hospital', 'Shibganj Main Rd', 'Sylhet', 'Shibganj', 2000.00, 'Specializes in joint replacement and trauma care.', 0.00, 0, 'verified', 'active', '2025-12-30 02:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(7, 14, 'E-14014', NULL, 'Pediatrician', 'MBBS, DCH', 'Rajshahi Medical College', '2013', 11, 'specialist', 'Sunrise Children Hospital', 'Sadar Ave 10', 'Rajshahi', 'Sadar', 900.00, 'Provides comprehensive pediatric care and immunization.', 0.00, 0, 'verified', 'active', '2025-12-30 02:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(8, 15, 'F-15015', NULL, 'ENT Specialist', 'MBBS, MS (ENT)', 'Mymensingh Medical College', '2011', 13, 'specialist', 'Ear Nose Throat Clinic', 'College Rd 7', 'Mymensingh', 'College Rd', 1100.00, 'Handles sinusitis, hearing loss, and throat disorders.', 0.00, 0, 'verified', 'active', '2025-12-30 02:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(9, 16, 'G-16016', NULL, 'Endocrinologist', 'MBBS, MD (Endocrinology)', 'Dhaka Medical College', '2008', 16, 'consultant', 'Hormone Care Center', 'Mirpur 10, Lane 3', 'Dhaka', 'Mirpur', 1700.00, 'Focuses on diabetes, thyroid, and metabolic diseases.', 0.00, 0, 'verified', 'active', '2025-12-30 02:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(10, 17, 'H-17017', NULL, 'Gastroenterologist', 'MBBS, MD (Gastro)', 'Sir Salimullah Medical College', '2009', 15, 'consultant', 'Digestive Health Institute', 'Kawran Bazar 55', 'Dhaka', 'Kawran Bazar', 1600.00, 'Treats liver, stomach, and gut disorders.', 0.00, 0, 'verified', 'active', '2025-12-30 02:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(11, 18, 'I-18018', NULL, 'Pulmonologist', 'MBBS, MD (Pulmonology)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Lung Care Center', 'Halishahar Rd 12', 'Chattogram', 'Halishahar', 1400.00, 'Manages asthma, COPD, and respiratory infections.', 0.00, 0, 'verified', 'active', '2025-12-30 02:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(12, 19, 'J-19019', NULL, 'Nephrologist', 'MBBS, MD (Nephrology)', 'Dhaka Medical College', '2007', 17, 'consultant', 'Kidney Care Hospital', 'Uttara Sector 7', 'Dhaka', 'Uttara', 1900.00, 'Specializes in kidney diseases and dialysis care.', 0.00, 0, 'verified', 'active', '2025-12-30 02:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(13, 20, 'K-20020', NULL, 'Oncologist', 'MBBS, MD (Oncology)', 'Bangabandhu Sheikh Mujib Medical University', '2006', 18, 'consultant', 'Hope Cancer Center', 'Mohakhali DOHS 5', 'Dhaka', 'Mohakhali', 2100.00, 'Provides chemo and cancer counseling services.', 0.00, 0, 'verified', 'active', '2025-12-30 02:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(14, 21, 'L-21021', NULL, 'Psychiatrist', 'MBBS, MD (Psychiatry)', 'Sylhet MAG Osmani Medical College', '2009', 15, 'consultant', 'Mind Wellness Clinic', 'Zindabazar 3', 'Sylhet', 'Zindabazar', 1300.00, 'Focuses on mood, anxiety, and behavioral disorders.', 0.00, 0, 'verified', 'active', '2025-12-30 02:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(15, 22, 'M-22022', NULL, 'Gynecologist', 'MBBS, FCPS (Gyne)', 'Rangpur Medical College', '2010', 14, 'specialist', 'Women Care Hospital', 'Station Rd 8', 'Rangpur', 'Station Rd', 1200.00, 'Handles prenatal care, delivery, and women health.', 0.00, 0, 'verified', 'active', '2025-12-30 03:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(16, 23, 'N-23023', NULL, 'Urologist', 'MBBS, MS (Urology)', 'Khulna Medical College', '2011', 13, 'consultant', 'Uro Center', 'Boyra Main Rd', 'Khulna', 'Boyra', 1500.00, 'Manages urinary tract and renal surgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 03:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(17, 24, 'O-24024', NULL, 'Rheumatologist', 'MBBS, MD (Rheumatology)', 'Dhaka Medical College', '2008', 16, 'consultant', 'Joint Care Clinic', 'Paltan Line 2', 'Dhaka', 'Paltan', 1400.00, 'Treats arthritis, lupus, and autoimmune diseases.', 0.00, 0, 'verified', 'active', '2025-12-30 03:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(18, 25, 'P-25025', NULL, 'Dentist', 'BDS, FCPS (Dental)', 'Dhaka Dental College', '2013', 11, 'specialist', 'Smile Dental Care', 'Banani 11', 'Dhaka', 'Banani', 800.00, 'Offers restorative and cosmetic dental care.', 0.00, 0, 'verified', 'active', '2025-12-30 03:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(19, 26, 'Q-26026', NULL, 'Cardiologist', 'MBBS, MD (Cardiology)', 'Sir Salimullah Medical College', '2007', 17, 'consultant', 'Heart Point Hospital', 'Shahbagh 9', 'Dhaka', 'Shahbagh', 1800.00, 'Cardiac imaging and interventional cardiology.', 0.00, 0, 'verified', 'active', '2025-12-30 03:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(20, 27, 'R-27027', NULL, 'Hepatologist', 'MBBS, MD (Hepatology)', 'Chittagong Medical College', '2009', 15, 'consultant', 'Liver Care Center', 'Probartak Mor', 'Chattogram', 'Probartak', 1700.00, 'Focus on hepatitis, fatty liver, and liver cirrhosis.', 0.00, 0, 'verified', 'active', '2025-12-30 03:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(21, 28, 'S-28028', NULL, 'Allergist', 'MBBS, MD (Allergy & Immunology)', 'Bangabandhu Sheikh Mujib Medical University', '2012', 12, 'specialist', 'Allergy Relief Center', 'Baridhara 4', 'Dhaka', 'Baridhara', 1000.00, 'Treats asthma, rhinitis, and immune disorders.', 0.00, 0, 'verified', 'active', '2025-12-30 03:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(22, 29, 'T-29029', NULL, 'Physiotherapist', 'BPT, MPT', 'State College of Physiotherapy', '2014', 10, 'specialist', 'Rehab Plus', 'Shantinagar 12', 'Dhaka', 'Shantinagar', 700.00, 'Rehabilitation and musculoskeletal therapy.', 0.00, 0, 'verified', 'active', '2025-12-30 03:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(23, 30, 'U-30030', NULL, 'Ophthalmologist', 'MBBS, MS (Ophthalmology)', 'Mymensingh Medical College', '2010', 14, 'consultant', 'Vision Care Hospital', 'Station Rd 5', 'Mymensingh', 'Station Rd', 1100.00, 'Cataract, glaucoma, and refractive surgery.', 0.00, 0, 'verified', 'active', '2025-12-30 03:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(24, 31, 'V-31031', NULL, 'Neonatologist', 'MBBS, FCPS (Neonatology)', 'Dhaka Medical College', '2012', 12, 'consultant', 'Newborn Care Unit', 'Malibagh 3', 'Dhaka', 'Malibagh', 1400.00, 'Specializes in newborn intensive care and growth.', 0.00, 0, 'verified', 'active', '2025-12-30 03:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(25, 32, 'W-32032', NULL, 'Hematologist', 'MBBS, MD (Hematology)', 'Chittagong Medical College', '2008', 16, 'consultant', 'Blood Care Center', 'GEC Circle 6', 'Chattogram', 'GEC', 1800.00, 'Treats anemia, clotting, and blood cancers.', 0.00, 0, 'verified', 'active', '2025-12-30 03:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(26, 33, 'X-33033', NULL, 'Plastic Surgeon', 'MBBS, MS (Plastic Surgery)', 'Dhaka Medical College', '2007', 17, 'consultant', 'Aesthetic Surgery Center', 'Gulshan Ave 101', 'Dhaka', 'Gulshan', 2500.00, 'Reconstructive and cosmetic procedures.', 0.00, 0, 'verified', 'active', '2025-12-30 03:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(27, 34, 'Y-34034', NULL, 'Endodontist', 'BDS, FCPS (Endodontics)', 'Dhaka Dental College', '2014', 10, 'specialist', 'Root Canal Clinic', 'Mirpur 2 Lane 5', 'Dhaka', 'Mirpur', 900.00, 'Focus on root canal and restorative dentistry.', 0.00, 0, 'verified', 'active', '2025-12-30 04:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(28, 35, 'Z-35035', NULL, 'Periodontist', 'BDS, MDS (Periodontology)', 'Bangabandhu Sheikh Mujib Medical University', '2011', 13, 'specialist', 'Gum Care Center', 'Dhanmondi 5A', 'Dhaka', 'Dhanmondi', 850.00, 'Treats gum disease and implants.', 0.00, 0, 'verified', 'active', '2025-12-30 04:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(29, 36, 'AA-36036', NULL, 'Anesthesiologist', 'MBBS, DA', 'Sir Salimullah Medical College', '2009', 15, 'consultant', 'Safe Anesthesia Team', 'Panthapath 9', 'Dhaka', 'Panthapath', 1300.00, 'Perioperative and pain management specialist.', 0.00, 0, 'verified', 'active', '2025-12-30 04:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(30, 37, 'AB-37037', NULL, 'Radiologist', 'MBBS, MD (Radiology)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Imaging Diagnostics', 'Nasirabad 4', 'Chattogram', 'Nasirabad', 1500.00, 'Expert in MRI, CT, and ultrasound imaging.', 0.00, 0, 'verified', 'active', '2025-12-30 04:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(31, 38, 'AC-38038', NULL, 'Pathologist', 'MBBS, MD (Pathology)', 'Dhaka Medical College', '2008', 16, 'consultant', 'Lab Diagnostics Center', 'Eskaton 12', 'Dhaka', 'Eskaton', 1200.00, 'Provides clinical pathology and lab diagnostics.', 0.00, 0, 'verified', 'active', '2025-12-30 04:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(32, 39, 'AD-39039', NULL, 'Infectious Disease Specialist', 'MBBS, MD (Infectious Diseases)', 'Rangpur Medical College', '2011', 13, 'consultant', 'ID Care Clinic', 'Jahaj Company Mor', 'Rangpur', 'Jahaj Mor', 1400.00, 'Treats complex infections and tropical diseases.', 0.00, 0, 'verified', 'active', '2025-12-30 04:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(33, 40, 'AE-40040', NULL, 'Geriatrician', 'MBBS, MD (Geriatrics)', 'Dhaka Medical College', '2007', 17, 'consultant', 'Elder Care Clinic', 'Bashundhara Block C', 'Dhaka', 'Bashundhara', 1100.00, 'Focus on elderly care and chronic diseases.', 0.00, 0, 'verified', 'active', '2025-12-30 04:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(34, 41, 'AF-41041', NULL, 'Sports Medicine Specialist', 'MBBS, MS (Sports Med)', 'Bangabandhu Sheikh Mujib Medical University', '2012', 12, 'specialist', 'Athlete Care Center', 'Army Stadium Rd', 'Dhaka', 'Cantonment', 1300.00, 'Injury prevention and rehabilitation for athletes.', 0.00, 0, 'verified', 'active', '2025-12-30 04:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(35, 42, 'AG-42042', NULL, 'Nutritionist', 'BSc, MSc (Nutrition)', 'National Institute of Nutrition', '2013', 11, 'general', 'Diet & Wellness Center', 'Uttara 5', 'Dhaka', 'Uttara', 600.00, 'Provides diet plans for metabolic and weight issues.', 0.00, 0, 'verified', 'active', '2025-12-30 04:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(36, 43, 'AH-43043', NULL, 'Chiropractor', 'Doctor of Chiropractic', 'International Chiro Institute', '2014', 10, 'general', 'Spine Relief Clinic', 'Banani 3', 'Dhaka', 'Banani', 900.00, 'Manual therapy for spine and posture problems.', 0.00, 0, 'verified', 'active', '2025-12-30 04:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(37, 44, 'AI-44044', NULL, 'Audiologist', 'BSc, MSc (Audiology)', 'Institute of Health Tech', '2013', 11, 'general', 'Hearing Plus Center', 'Kallyanpur 2', 'Dhaka', 'Kallyanpur', 700.00, 'Hearing assessment and hearing aid fitting.', 0.00, 0, 'verified', 'active', '2025-12-30 04:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(38, 45, 'AJ-45045', NULL, 'Occupational Therapist', 'BOT, MOT', 'State College of OT', '2014', 10, 'general', 'OT Care Hub', 'Shyamoli 6', 'Dhaka', 'Shyamoli', 650.00, 'Rehabilitation for daily living and workplace safety.', 0.00, 0, 'verified', 'active', '2025-12-30 04:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(39, 46, 'AK-46046', NULL, 'Palliative Care Specialist', 'MBBS, MD (Palliative)', 'Bangabandhu Sheikh Mujib Medical University', '2010', 14, 'consultant', 'Comfort Care Center', 'Dhanmondi 8', 'Dhaka', 'Dhanmondi', 1200.00, 'Focus on pain relief and quality-of-life care.', 0.00, 0, 'verified', 'active', '2025-12-30 05:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(40, 47, 'AL-47047', NULL, 'Pain Specialist', 'MBBS, DA, FIPM', 'Dhaka Medical College', '2009', 15, 'consultant', 'Pain Relief Clinic', 'New Eskaton 12', 'Dhaka', 'Eskaton', 1300.00, 'Interventional pain management and nerve blocks.', 0.00, 0, 'verified', 'active', '2025-12-30 05:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(41, 48, 'AM-48048', NULL, 'Critical Care Specialist', 'MBBS, MD (Critical Care)', 'Chittagong Medical College', '2011', 13, 'consultant', 'ICU Care Unit', 'Mehedibagh 9', 'Chattogram', 'Mehedibagh', 2000.00, 'Manages ICU patients and complex critical illnesses.', 0.00, 0, 'verified', 'active', '2025-12-30 05:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(42, 49, 'AN-49049', NULL, 'Emergency Medicine Specialist', 'MBBS, MD (Emergency)', 'Sylhet MAG Osmani Medical College', '2012', 12, 'consultant', '24/7 Emergency Center', 'Subidbazar 2', 'Sylhet', 'Subidbazar', 1500.00, 'Handles acute trauma and emergency stabilization.', 0.00, 0, 'verified', 'active', '2025-12-30 05:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(43, 50, 'AO-50050', NULL, 'Pulmonary Rehabilitation Specialist', 'MBBS, MD (Pulmonology)', 'Dhaka Medical College', '2010', 14, 'consultant', 'Breathe Easy Clinic', 'Mohammadpur 4', 'Dhaka', 'Mohammadpur', 1200.00, 'Rehab for COPD and long COVID recovery.', 0.00, 0, 'verified', 'active', '2025-12-30 05:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(44, 51, 'AP-51051', NULL, 'Sleep Medicine Specialist', 'MBBS, MD (Pulmonology)', 'Sir Salimullah Medical College', '2009', 15, 'consultant', 'Sleep Care Lab', 'Bashabo 6', 'Dhaka', 'Bashabo', 1300.00, 'Treats sleep apnea, insomnia, and hypersomnia.', 0.00, 0, 'verified', 'active', '2025-12-30 05:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(45, 52, 'AQ-52052', NULL, 'Immunologist', 'MBBS, PhD (Immunology)', 'Bangabandhu Sheikh Mujib Medical University', '2008', 16, 'consultant', 'Immune Health Center', 'Kakrail 2', 'Dhaka', 'Kakrail', 1800.00, 'Manages immune deficiencies and auto-immune cases.', 0.00, 0, 'verified', 'active', '2025-12-30 05:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(46, 53, 'AR-53053', NULL, 'Clinical Pharmacologist', 'MBBS, MD (Pharmacology)', 'Dhaka Medical College', '2011', 13, 'consultant', 'Medicines & Safety Clinic', 'Kalabagan 3', 'Dhaka', 'Kalabagan', 1000.00, 'Optimizes medication therapy and safety.', 0.00, 0, 'verified', 'active', '2025-12-30 05:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(47, 54, 'AS-54054', NULL, 'Public Health Specialist', 'MBBS, MPH', 'Johns Hopkins Bloomberg School of Public Health', '2013', 11, 'general', 'Community Health Office', 'Puran Dhaka 7', 'Dhaka', 'Chawkbazar', 900.00, 'Population health, vaccination, and prevention.', 0.00, 0, 'verified', 'active', '2025-12-30 05:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(48, 55, 'AT-55055', NULL, 'Toxicologist', 'MBBS, MD (Toxicology)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Poison Care Center', 'EPZ 2', 'Chattogram', 'EPZ', 1500.00, 'Manages poisoning, drug overdose, and detox.', 0.00, 0, 'verified', 'active', '2025-12-30 05:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(49, 56, 'AU-56056', NULL, 'Occupational Health Specialist', 'MBBS, MPH (Occupational Health)', 'Dhaka Medical College', '2009', 15, 'consultant', 'Workplace Health Center', 'Tejgaon 11', 'Dhaka', 'Tejgaon', 1100.00, 'Industrial health, ergonomics, and safety.', 0.00, 0, 'verified', 'active', '2025-12-30 05:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(50, 57, 'AV-57057', NULL, 'Hyperbaric Medicine Specialist', 'MBBS, MD (Hyperbaric)', 'Bangabandhu Sheikh Mujib Medical University', '2012', 12, 'consultant', 'Hyperbaric Care Unit', 'Old Airport Rd', 'Dhaka', 'Banani', 1900.00, 'Treats decompression sickness and wound healing.', 0.00, 0, 'verified', 'active', '2025-12-30 05:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(51, 58, 'AW-58058', NULL, 'Dermatologic Surgeon', 'MBBS, FCPS (Derm Surgery)', 'Dhaka Medical College', '2011', 13, 'consultant', 'Laser & Skin Surgery Center', 'Gulshan 1', 'Dhaka', 'Gulshan', 2000.00, 'Performs skin surgery and laser procedures.', 0.00, 0, 'verified', 'active', '2025-12-30 06:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(52, 59, 'AX-59059', NULL, 'Clinical Geneticist', 'MBBS, PhD (Genetics)', 'University of Dhaka', '2010', 14, 'consultant', 'Genomics Clinic', 'Science Lab 3', 'Dhaka', 'Katabon', 2100.00, 'Handles inherited diseases and genetic counseling.', 0.00, 0, 'verified', 'active', '2025-12-30 06:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(53, 60, 'AY-60060', NULL, 'Fertility Specialist', 'MBBS, MS (Reproductive Medicine)', 'Bangabandhu Sheikh Mujib Medical University', '2012', 12, 'consultant', 'Fertility Hope Center', 'Baily Road 5', 'Dhaka', 'Baily Road', 2200.00, 'IVF, IUI, and reproductive endocrinology.', 0.00, 0, 'verified', 'active', '2025-12-30 06:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(54, 61, 'AZ-61061', NULL, 'Maternal-Fetal Medicine Specialist', 'MBBS, FCPS (Obs & Gyn)', 'Dhaka Medical College', '2009', 15, 'consultant', 'High Risk Pregnancy Unit', 'Shantinagar 9', 'Dhaka', 'Shantinagar', 2000.00, 'Manages high-risk pregnancies and fetal care.', 0.00, 0, 'verified', 'active', '2025-12-30 06:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(55, 62, 'BA-62062', NULL, 'Neonatal Surgeon', 'MBBS, MS (Pediatric Surgery)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Pediatric Surgery Center', 'Kotwali 6', 'Chattogram', 'Kotwali', 2300.00, 'Surgery for newborns and children.', 0.00, 0, 'verified', 'active', '2025-12-30 06:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(56, 63, 'BB-63063', NULL, 'Pediatric Cardiologist', 'MBBS, MD (Pediatric Cardiology)', 'Bangabandhu Sheikh Mujib Medical University', '2011', 13, 'consultant', 'Kids Heart Center', 'Barishal Sadar 3', 'Barishal', 'Sadar', 2200.00, 'Manages congenital heart diseases in children.', 0.00, 0, 'verified', 'active', '2025-12-30 06:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(57, 64, 'BC-64064', NULL, 'Pediatric Neurologist', 'MBBS, MD (Pediatric Neurology)', 'Dhaka Medical College', '2012', 12, 'consultant', 'Child Neuro Care', 'Mirpur 11', 'Dhaka', 'Mirpur', 2100.00, 'Epilepsy, developmental delay, and neuro rehab.', 0.00, 0, 'verified', 'active', '2025-12-30 06:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(58, 65, 'BD-65065', NULL, 'Pediatric Endocrinologist', 'MBBS, MD (Endocrinology)', 'Sir Salimullah Medical College', '2013', 11, 'consultant', 'Child Hormone Clinic', 'Farmgate 12', 'Dhaka', 'Farmgate', 1900.00, 'Diabetes and growth disorders in children.', 0.00, 0, 'verified', 'active', '2025-12-30 06:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(59, 66, 'BE-66066', NULL, 'Pediatric Pulmonologist', 'MBBS, MD (Pediatric Pulmonology)', 'Chittagong Medical College', '2011', 13, 'consultant', 'Kids Lung Center', 'Khulshi 7', 'Chattogram', 'Khulshi', 1800.00, 'Asthma, allergies, and lung infections in kids.', 0.00, 0, 'verified', 'active', '2025-12-30 06:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(60, 67, 'BF-67067', NULL, 'Pediatric Gastroenterologist', 'MBBS, MD (Pediatric Gastro)', 'Dhaka Medical College', '2012', 12, 'consultant', 'Child GI Clinic', 'Mohammadpur 3', 'Dhaka', 'Mohammadpur', 1900.00, 'GI, liver, and nutrition issues in children.', 0.00, 0, 'verified', 'active', '2025-12-30 06:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(61, 68, 'BG-68068', NULL, 'Adolescent Medicine Specialist', 'MBBS, MD (Adolescent Health)', 'Bangabandhu Sheikh Mujib Medical University', '2014', 10, 'general', 'Teen Health Clinic', 'Dhanmondi 12A', 'Dhaka', 'Dhanmondi', 1000.00, 'Focus on teen wellness and mental health.', 0.00, 0, 'verified', 'active', '2025-12-30 06:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(62, 69, 'BH-69069', NULL, 'Clinical Psychologist', 'BSc, MSc, PhD (Clinical Psychology)', 'University of Dhaka', '2013', 11, 'general', 'Behavioral Health Center', 'Nilkhet 5', 'Dhaka', 'Nilkhet', 900.00, 'CBT, counseling, and psychological assessments.', 0.00, 0, 'verified', 'active', '2025-12-30 06:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(63, 70, 'BI-70070', NULL, 'Sexual Health Specialist', 'MBBS, Diploma (Sexology)', 'Dhaka Medical College', '2011', 13, 'consultant', 'Sexual Wellness Clinic', 'Motijheel 8', 'Dhaka', 'Motijheel', 1200.00, 'Manages sexual health, counseling, and fertility.', 0.00, 0, 'verified', 'active', '2025-12-30 07:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(64, 71, 'BJ-71071', NULL, 'Andrologist', 'MBBS, MS (Andrology)', 'Bangabandhu Sheikh Mujib Medical University', '2010', 14, 'consultant', 'Men Health Center', 'Badda Link Rd', 'Dhaka', 'Badda', 1400.00, 'Male fertility, hormones, and reproductive surgery.', 0.00, 0, 'verified', 'active', '2025-12-30 07:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(65, 72, 'BK-72072', NULL, 'Vascular Surgeon', 'MBBS, MS (Vascular Surgery)', 'Chittagong Medical College', '2009', 15, 'consultant', 'Vascular Care Institute', 'Agrabad 7', 'Chattogram', 'Agrabad', 2300.00, 'Peripheral vascular disease and varicose vein surgery.', 0.00, 0, 'verified', 'active', '2025-12-30 07:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(66, 73, 'BL-73073', NULL, 'Thoracic Surgeon', 'MBBS, MS (Thoracic Surgery)', 'Dhaka Medical College', '2008', 16, 'consultant', 'Chest Surgery Center', 'Khilgaon 6', 'Dhaka', 'Khilgaon', 2400.00, 'Lung and chest wall surgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 07:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(67, 74, 'BM-74074', NULL, 'Colorectal Surgeon', 'MBBS, MS (Colorectal Surgery)', 'Sir Salimullah Medical College', '2010', 14, 'consultant', 'Colon Care Center', 'Malibagh Chowdhury Para', 'Dhaka', 'Malibagh', 2200.00, 'Manages piles, fissures, and colorectal cancers.', 0.00, 0, 'verified', 'active', '2025-12-30 07:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(68, 75, 'BN-75075', NULL, 'Hepatobiliary Surgeon', 'MBBS, MS (Hepatobiliary Surgery)', 'Bangabandhu Sheikh Mujib Medical University', '2009', 15, 'consultant', 'Liver & Pancreas Surgery Center', 'Shyamoli 2', 'Dhaka', 'Shyamoli', 2400.00, 'Surgery for liver, gallbladder, and pancreas.', 0.00, 0, 'verified', 'active', '2025-12-30 07:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(69, 76, 'BO-76076', NULL, 'Spine Surgeon', 'MBBS, MS (Orthopedics)', 'Chittagong Medical College', '2008', 16, 'consultant', 'Spine Institute', 'Nasirabad 5', 'Chattogram', 'Nasirabad', 2500.00, 'Specializes in spine deformity and disc surgery.', 0.00, 0, 'verified', 'active', '2025-12-30 07:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(70, 77, 'BP-77077', NULL, 'Hand Surgeon', 'MBBS, MS (Orthopedics)', 'Dhaka Medical College', '2009', 15, 'consultant', 'Hand & Microsurgery Center', 'Banani 9', 'Dhaka', 'Banani', 2100.00, 'Microsurgery for hand trauma and nerve repair.', 0.00, 0, 'verified', 'active', '2025-12-30 07:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(71, 78, 'BQ-78078', NULL, 'Maxillofacial Surgeon', 'BDS, MS (Maxillofacial)', 'Dhaka Dental College', '2011', 13, 'consultant', 'Face & Jaw Surgery Center', 'Dhanmondi 32', 'Dhaka', 'Dhanmondi', 2300.00, 'Jaw fractures, orthognathic, and facial trauma.', 0.00, 0, 'verified', 'active', '2025-12-30 07:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(72, 79, 'BR-79079', NULL, 'Ophthalmic Surgeon', 'MBBS, MS (Ophthalmology)', 'Mymensingh Medical College', '2010', 14, 'consultant', 'Eye Surgery Suite', 'Brahmanbaria Sadar 4', 'Brahmanbaria', 'Sadar', 1800.00, 'Cataract, cornea, and retina surgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 07:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(73, 80, 'BS-80080', NULL, 'ENT Surgeon', 'MBBS, MS (ENT)', 'Dhaka Medical College', '2009', 15, 'consultant', 'Advanced ENT Surgery', 'Uttara Sector 4', 'Dhaka', 'Uttara', 1700.00, 'Sinus, tonsil, and ear microsurgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 07:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(74, 81, 'BT-81081', NULL, 'Head & Neck Surgeon', 'MBBS, FCPS (ENT)', 'Sir Salimullah Medical College', '2008', 16, 'consultant', 'Head Neck Institute', 'Paltan 5', 'Dhaka', 'Paltan', 2200.00, 'Thyroid, parotid, and head-neck cancers.', 0.00, 0, 'verified', 'active', '2025-12-30 07:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(75, 82, 'BU-82082', NULL, 'Breast Surgeon', 'MBBS, MS (Breast Surgery)', 'Bangabandhu Sheikh Mujib Medical University', '2009', 15, 'consultant', 'Breast Care Center', 'Dhanmondi 27', 'Dhaka', 'Dhanmondi', 2200.00, 'Breast cancer and benign breast disease surgery.', 0.00, 0, 'verified', 'active', '2025-12-30 08:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(76, 83, 'BV-83083', NULL, 'Bariatric Surgeon', 'MBBS, MS (Surgery)', 'Dhaka Medical College', '2008', 16, 'consultant', 'Weight Loss Surgery Center', 'Gulshan 5', 'Dhaka', 'Gulshan', 2600.00, 'Obesity surgery including sleeve and bypass.', 0.00, 0, 'verified', 'active', '2025-12-30 08:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(77, 84, 'BW-84084', NULL, 'Endoscopic Surgeon', 'MBBS, MS (Surgery)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Minimal Access Surgery Unit', 'Bayezid 6', 'Chattogram', 'Bayezid', 2000.00, 'Laparoscopic GI and gallbladder surgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 08:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(78, 85, 'BX-85085', NULL, 'Transplant Surgeon', 'MBBS, MS (Transplant)', 'Bangabandhu Sheikh Mujib Medical University', '2007', 17, 'consultant', 'Transplant Institute', 'Shere Bangla Nagar 7', 'Dhaka', 'Agargaon', 3000.00, 'Kidney and liver transplant surgeon.', 0.00, 0, 'verified', 'active', '2025-12-30 08:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(79, 86, 'BY-86086', NULL, 'Interventional Cardiologist', 'MBBS, MD, DM (Cardiology)', 'Dhaka Medical College', '2009', 15, 'consultant', 'Cath Lab Center', 'Panthapath 15', 'Dhaka', 'Panthapath', 2600.00, 'Angioplasty, stenting, and structural heart care.', 0.00, 0, 'verified', 'active', '2025-12-30 08:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(80, 87, 'BZ-87087', NULL, 'Electrophysiologist', 'MBBS, MD (Cardiology)', 'Sir Salimullah Medical College', '2010', 14, 'consultant', 'Heart Rhythm Center', 'Motijheel 12', 'Dhaka', 'Motijheel', 2400.00, 'Arrhythmia ablation and pacemaker implantation.', 0.00, 0, 'verified', 'active', '2025-12-30 08:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(81, 88, 'CA-88088', NULL, 'Cardiac Surgeon', 'MBBS, MS (Cardiothoracic Surgery)', 'Chittagong Medical College', '2008', 16, 'consultant', 'Heart Surgery Center', 'Halishahar 3', 'Chattogram', 'Halishahar', 3200.00, 'CABG, valve replacement, and thoracic surgery.', 0.00, 0, 'verified', 'active', '2025-12-30 08:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(82, 89, 'CB-89089', NULL, 'Cardiac Anesthesiologist', 'MBBS, MD (Cardiac Anesthesia)', 'Dhaka Medical College', '2009', 15, 'consultant', 'Cardiac Anesthesia Team', 'Shahbagh 3', 'Dhaka', 'Shahbagh', 2200.00, 'Anesthesia for cardiac and thoracic surgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 08:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(83, 90, 'CC-90090', NULL, 'Clinical Cardiologist', 'MBBS, FCPS (Cardiology)', 'Sir Salimullah Medical College', '2011', 13, 'consultant', 'Heart Failure Clinic', 'Uttara Sector 9', 'Dhaka', 'Uttara', 2000.00, 'Heart failure and preventive cardiology.', 0.00, 0, 'verified', 'active', '2025-12-30 08:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(84, 91, 'CD-91091', NULL, 'Preventive Cardiologist', 'MBBS, MPH', 'Bangabandhu Sheikh Mujib Medical University', '2012', 12, 'general', 'Cardiac Wellness Center', 'Mirpur DOHS 2', 'Dhaka', 'Mirpur', 1500.00, 'Lifestyle, risk reduction, and cardiac rehab.', 0.00, 0, 'verified', 'active', '2025-12-30 08:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(85, 92, 'CE-92092', NULL, 'Interventional Radiologist', 'MBBS, MD (Radiology)', 'Dhaka Medical College', '2010', 14, 'consultant', 'IR Suite', 'Bashundhara Block D', 'Dhaka', 'Bashundhara', 2500.00, 'Image-guided vascular and oncologic interventions.', 0.00, 0, 'verified', 'active', '2025-12-30 08:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(86, 93, 'CF-93093', NULL, 'Nuclear Medicine Specialist', 'MBBS, MD (Nuclear Medicine)', 'Bangabandhu Sheikh Mujib Medical University', '2009', 15, 'consultant', 'Nuclear Imaging Center', 'Agargaon 9', 'Dhaka', 'Agargaon', 2400.00, 'PET, SPECT, and radionuclide therapy.', 0.00, 0, 'verified', 'active', '2025-12-30 08:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(87, 94, 'CG-94094', NULL, 'Radiation Oncologist', 'MBBS, MD (Radiation Oncology)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Radiation Therapy Unit', 'Foy0 0 bazar 4', 'Chattogram', 'Foy0 0 bazar', 2600.00, 'Radiation therapy planning and delivery.', 0.00, 0, 'verified', 'active', '2025-12-30 09:00:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(88, 95, 'CH-95095', NULL, 'Medical Oncologist', 'MBBS, MD (Medical Oncology)', 'Dhaka Medical College', '2010', 14, 'consultant', 'Chemo Day Care', 'Mohakhali 2', 'Dhaka', 'Mohakhali', 2400.00, 'Chemotherapy, immunotherapy, and cancer follow-up.', 0.00, 0, 'verified', 'active', '2025-12-30 09:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(89, 96, 'CI-96096', NULL, 'Surgical Oncologist', 'MBBS, MS (Surgical Oncology)', 'Sir Salimullah Medical College', '2009', 15, 'consultant', 'Onco Surgery Unit', 'Azimpur 3', 'Dhaka', 'Azimpur', 2700.00, 'Cancer resections and reconstruction.', 0.00, 0, 'verified', 'active', '2025-12-30 09:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(90, 97, 'CJ-97097', NULL, 'Gynecologic Oncologist', 'MBBS, MS (Gyn Oncology)', 'Bangabandhu Sheikh Mujib Medical University', '2009', 15, 'consultant', 'Women Cancer Center', 'Kamalapur 5', 'Dhaka', 'Kamalapur', 2600.00, 'Treats ovarian, cervical, and uterine cancers.', 0.00, 0, 'verified', 'active', '2025-12-30 09:15:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(91, 98, 'CK-98098', NULL, 'Pediatric Oncologist', 'MBBS, MD (Pediatric Oncology)', 'Dhaka Medical College', '2011', 13, 'consultant', 'Kids Cancer Care', 'Shyamoli Ring Rd', 'Dhaka', 'Shyamoli', 2500.00, 'Manages leukemia and solid tumors in children.', 0.00, 0, 'verified', 'active', '2025-12-30 09:20:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(92, 99, 'CL-99099', NULL, 'Neuro Oncologist', 'MBBS, MD (Neuro Oncology)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Brain Tumor Clinic', 'Lalkhan Bazar 6', 'Chattogram', 'Lalkhan Bazar', 2700.00, 'Brain and spine tumors management.', 0.00, 0, 'verified', 'active', '2025-12-30 09:25:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(93, 100, 'CM-101000', NULL, 'Psycho-Oncologist', 'MBBS, MD (Psychiatry)', 'Dhaka Medical College', '2012', 12, 'consultant', 'Cancer Support Clinic', 'Shahbagh 10', 'Dhaka', 'Shahbagh', 1400.00, 'Mental health support for cancer patients.', 0.00, 0, 'verified', 'active', '2025-12-30 09:30:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(94, 101, 'CN-101101', NULL, 'Neuropsychiatrist', 'MBBS, MD (Psychiatry)', 'Bangabandhu Sheikh Mujib Medical University', '2011', 13, 'consultant', 'Mind & Brain Clinic', 'Green Rd 6', 'Dhaka', 'Green Road', 1500.00, 'Bridges neurology and psychiatry for complex cases.', 0.00, 0, 'verified', 'active', '2025-12-30 09:35:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(95, 102, 'CO-101202', NULL, 'Sleep Psychologist', 'BSc, MSc, PhD (Psychology)', 'University of Dhaka', '2013', 11, 'general', 'Sleep & Mind Lab', 'Dhanmondi 15', 'Dhaka', 'Dhanmondi', 900.00, 'CBT-I and behavioral therapy for sleep disorders.', 0.00, 0, 'verified', 'active', '2025-12-30 09:40:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(96, 103, 'CP-101303', NULL, 'Addiction Psychiatrist', 'MBBS, MD (Psychiatry)', 'Chittagong Medical College', '2010', 14, 'consultant', 'Recovery Wellness Center', 'Agrabad Access 8', 'Chattogram', 'Agrabad', 1600.00, 'Substance use treatment and rehabilitation.', 0.00, 0, 'verified', 'active', '2025-12-30 09:45:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(97, 104, 'CQ-101404', NULL, 'Forensic Psychiatrist', 'MBBS, MD (Psychiatry)', 'Sir Salimullah Medical College', '2009', 15, 'consultant', 'Forensic Mental Health Unit', 'Court House Rd', 'Dhaka', 'Judge Court', 1700.00, 'Assessment for legal and forensic cases.', 0.00, 0, 'verified', 'active', '2025-12-30 09:50:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(98, 105, 'CR-101505', NULL, 'Gastrointestinal Surgeon', 'MBBS, MS (Surgery)', 'Dhaka Medical College', '2009', 15, 'consultant', 'GI Surgery Center', 'Kalyanpur 7', 'Dhaka', 'Kalyanpur', 2300.00, 'Upper GI, colorectal, and hernia surgeries.', 0.00, 0, 'verified', 'active', '2025-12-30 09:55:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(100, 107, 'CT-101707', NULL, 'Geriatric Psychiatrist', 'MBBS, MD (Psychiatry)', 'Dhaka Medical College', '2010', 14, 'consultant', 'Elder Mind Clinic', 'Rampura 6', 'Dhaka', 'Rampura', 1400.00, 'Memory disorders, dementia, and late-life depression.', 0.00, 0, 'verified', 'active', '2025-12-30 10:05:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(101, 108, 'CU-101808', NULL, 'Movement Disorder Specialist', 'MBBS, MD (Neurology)', 'Sir Salimullah Medical College', '2011', 13, 'consultant', 'Parkinsons & Movement Clinic', 'Dhanmondi 19', 'Dhaka', 'Dhanmondi', 1800.00, 'Parkinsons, dystonia, and tremor management.', 0.00, 0, 'verified', 'active', '2025-12-30 10:10:00', '2026-08-01 06:06:46', 'sat,sun,mon,tue,wed,thu', '17:00:00', '21:00:00', 30),
(102, 109, 'CV-101909', NULL, 'Epileptologist', 'MBBS, MD (Neurology)', 'Chittagong Medical College', '2011', 13, 'consultant', 'Epilepsy Care Center', 'Jamal Khan Rd 9', 'Chattogram', 'Jamal Khan', 1700.00, 'Epilepsy diagnosis, EEG, and medical management.', 0.00, 0, 'verified', 'inactive', '2025-12-30 10:15:00', '2026-01-03 12:59:15', NULL, NULL, NULL, 30),
(103, 126, '145214', NULL, 'Oncologist', 'MBBS', 'Dhaka medical college', '2016', 10, 'general', 'Dumki hospital', '25, Tughlaq Road', 'Sylhet', 'dumki', 500.00, 'Good doctor', 3.00, 1, 'verified', 'active', '2026-08-01 07:13:03', '2026-08-03 11:28:49', 'Saturday,Sunday,Monday,Tuesday,Wednesday,Thursday', '03:41:00', '09:00:00', 10);

--
-- Triggers `doctors`
--
DELIMITER $$
CREATE TRIGGER `doctors_after_insert` AFTER INSERT ON `doctors` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'doctors',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'bmdc_registration_number', NEW.bmdc_registration_number,
            'specialization', NEW.specialization,
            'qualifications', NEW.qualifications,
            'experience_years', NEW.experience_years,
            'doctor_type', NEW.doctor_type,
            'hospital_clinic_name', NEW.hospital_clinic_name,
            'city', NEW.city,
            'consultation_fee', NEW.consultation_fee,
            'verification_status', NEW.verification_status,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `doctors_after_update` AFTER UPDATE ON `doctors` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF IFNULL(OLD.specialization,'') != IFNULL(NEW.specialization,'') THEN SET changed = CONCAT(changed, 'specialization,'); END IF;
    IF IFNULL(OLD.qualifications,'') != IFNULL(NEW.qualifications,'') THEN SET changed = CONCAT(changed, 'qualifications,'); END IF;
    IF OLD.experience_years != NEW.experience_years THEN SET changed = CONCAT(changed, 'experience_years,'); END IF;
    IF IFNULL(OLD.consultation_fee,0) != IFNULL(NEW.consultation_fee,0) THEN SET changed = CONCAT(changed, 'consultation_fee,'); END IF;
    IF IFNULL(OLD.verification_status,'') != IFNULL(NEW.verification_status,'') THEN SET changed = CONCAT(changed, 'verification_status,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF IFNULL(OLD.city,'') != IFNULL(NEW.city,'') THEN SET changed = CONCAT(changed, 'city,'); END IF;
    IF IFNULL(OLD.bio,'') != IFNULL(NEW.bio,'') THEN SET changed = CONCAT(changed, 'bio,'); END IF;
    IF OLD.rating != NEW.rating THEN SET changed = CONCAT(changed, 'rating,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'doctors',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'specialization', OLD.specialization,
                'qualifications', OLD.qualifications,
                'experience_years', OLD.experience_years,
                'consultation_fee', OLD.consultation_fee,
                'verification_status', OLD.verification_status,
                'status', OLD.status,
                'city', OLD.city,
                'rating', OLD.rating
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'specialization', NEW.specialization,
                'qualifications', NEW.qualifications,
                'experience_years', NEW.experience_years,
                'consultation_fee', NEW.consultation_fee,
                'verification_status', NEW.verification_status,
                'status', NEW.status,
                'city', NEW.city,
                'rating', NEW.rating
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `doctors_before_delete` BEFORE DELETE ON `doctors` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'doctors',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'bmdc_registration_number', OLD.bmdc_registration_number,
            'specialization', OLD.specialization,
            'qualifications', OLD.qualifications,
            'experience_years', OLD.experience_years,
            'city', OLD.city,
            'consultation_fee', OLD.consultation_fee,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `feedback`
--

CREATE TABLE `feedback` (
  `id` int(11) NOT NULL,
  `user_id` int(11) DEFAULT NULL,
  `name` varchar(100) NOT NULL,
  `email` varchar(100) NOT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `feedback_type` enum('general','suggestion','complaint','bug_report','doctor_issue','hospital_issue','appointment_issue','payment_issue','appreciation') DEFAULT 'general',
  `subject` varchar(255) NOT NULL,
  `message` text NOT NULL,
  `admin_response` text DEFAULT NULL,
  `status` enum('new','in_progress','resolved','closed') DEFAULT 'new',
  `priority` enum('low','normal','high','urgent') DEFAULT 'normal',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Triggers `feedback`
--
DELIMITER $$
CREATE TRIGGER `feedback_after_insert` AFTER INSERT ON `feedback` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'feedback',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'name', NEW.name,
            'email', NEW.email,
            'feedback_type', NEW.feedback_type,
            'subject', NEW.subject,
            'message', NEW.message,
            'status', NEW.status,
            'priority', NEW.priority
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `feedback_after_update` AFTER UPDATE ON `feedback` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF IFNULL(OLD.priority,'') != IFNULL(NEW.priority,'') THEN SET changed = CONCAT(changed, 'priority,'); END IF;
    IF IFNULL(OLD.admin_response,'') != IFNULL(NEW.admin_response,'') THEN SET changed = CONCAT(changed, 'admin_response,'); END IF;
    IF IFNULL(OLD.message,'') != IFNULL(NEW.message,'') THEN SET changed = CONCAT(changed, 'message,'); END IF;
    IF IFNULL(OLD.subject,'') != IFNULL(NEW.subject,'') THEN SET changed = CONCAT(changed, 'subject,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'feedback',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'email', OLD.email,
                'feedback_type', OLD.feedback_type,
                'subject', OLD.subject,
                'status', OLD.status,
                'priority', OLD.priority,
                'admin_response', OLD.admin_response
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'email', NEW.email,
                'feedback_type', NEW.feedback_type,
                'subject', NEW.subject,
                'status', NEW.status,
                'priority', NEW.priority,
                'admin_response', NEW.admin_response
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `feedback_before_delete` BEFORE DELETE ON `feedback` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'feedback',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'name', OLD.name,
            'email', OLD.email,
            'feedback_type', OLD.feedback_type,
            'subject', OLD.subject,
            'message', OLD.message,
            'status', OLD.status,
            'priority', OLD.priority,
            'admin_response', OLD.admin_response
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `hospitals`
--

CREATE TABLE `hospitals` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `name` varchar(255) NOT NULL,
  `registration_number` varchar(100) DEFAULT NULL,
  `license_number` varchar(100) DEFAULT NULL,
  `license_document` varchar(255) DEFAULT NULL,
  `email` varchar(100) DEFAULT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `emergency_phone` varchar(20) DEFAULT NULL,
  `website` varchar(255) DEFAULT NULL,
  `address` text NOT NULL,
  `city` varchar(50) NOT NULL,
  `area` varchar(100) DEFAULT NULL,
  `hospital_type` enum('private','government','specialized','teaching') DEFAULT 'private',
  `established_year` year(4) DEFAULT NULL,
  `total_beds` int(11) DEFAULT 0,
  `icu_beds` int(11) DEFAULT 0,
  `facilities` text DEFAULT NULL,
  `departments` text DEFAULT NULL,
  `open_24_hours` tinyint(1) DEFAULT 0,
  `opening_time` time DEFAULT NULL,
  `closing_time` time DEFAULT NULL,
  `description` text DEFAULT NULL,
  `rating` decimal(3,2) DEFAULT 0.00,
  `total_reviews` int(11) DEFAULT 0,
  `verification_status` enum('pending','verified','rejected') DEFAULT 'pending',
  `status` enum('pending','active','inactive') DEFAULT 'pending',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Triggers `hospitals`
--
DELIMITER $$
CREATE TRIGGER `hospitals_after_insert` AFTER INSERT ON `hospitals` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'hospitals',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'name', NEW.name,
            'registration_number', NEW.registration_number,
            'city', NEW.city,
            'hospital_type', NEW.hospital_type,
            'total_beds', NEW.total_beds,
            'verification_status', NEW.verification_status,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `hospitals_after_update` AFTER UPDATE ON `hospitals` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.name != NEW.name THEN SET changed = CONCAT(changed, 'name,'); END IF;
    IF IFNULL(OLD.phone,'') != IFNULL(NEW.phone,'') THEN SET changed = CONCAT(changed, 'phone,'); END IF;
    IF IFNULL(OLD.address,'') != IFNULL(NEW.address,'') THEN SET changed = CONCAT(changed, 'address,'); END IF;
    IF IFNULL(OLD.city,'') != IFNULL(NEW.city,'') THEN SET changed = CONCAT(changed, 'city,'); END IF;
    IF OLD.total_beds != NEW.total_beds THEN SET changed = CONCAT(changed, 'total_beds,'); END IF;
    IF IFNULL(OLD.verification_status,'') != IFNULL(NEW.verification_status,'') THEN SET changed = CONCAT(changed, 'verification_status,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF OLD.rating != NEW.rating THEN SET changed = CONCAT(changed, 'rating,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'hospitals',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'phone', OLD.phone,
                'address', OLD.address,
                'city', OLD.city,
                'total_beds', OLD.total_beds,
                'verification_status', OLD.verification_status,
                'status', OLD.status,
                'rating', OLD.rating
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'phone', NEW.phone,
                'address', NEW.address,
                'city', NEW.city,
                'total_beds', NEW.total_beds,
                'verification_status', NEW.verification_status,
                'status', NEW.status,
                'rating', NEW.rating
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `hospitals_before_delete` BEFORE DELETE ON `hospitals` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'hospitals',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'name', OLD.name,
            'registration_number', OLD.registration_number,
            'city', OLD.city,
            'hospital_type', OLD.hospital_type,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `notifications`
--

CREATE TABLE `notifications` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `type` varchar(50) NOT NULL DEFAULT 'general' COMMENT 'appointment|payment|order|blood|general',
  `title` varchar(255) NOT NULL,
  `body` text DEFAULT NULL,
  `route` varchar(255) DEFAULT NULL COMMENT 'in-app deep link, e.g. /appointments',
  `ref_id` int(11) DEFAULT NULL COMMENT 'id of the appointment/order this refers to',
  `is_read` tinyint(1) NOT NULL DEFAULT 0,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `notifications`
--

INSERT INTO `notifications` (`id`, `user_id`, `type`, `title`, `body`, `route`, `ref_id`, `is_read`, `created_at`) VALUES
(1, 125, 'appointment', 'Appointment requested', 'Your appointment request for 2026-08-04 at 17:00:00 has been received.', '/appointments', 104, 0, '2026-08-01 07:01:59'),
(2, 125, 'appointment', 'Appointment requested', 'Your appointment request for 2026-08-06 at 20:30:00 has been received.', '/appointments', 105, 0, '2026-08-01 07:08:05'),
(3, 125, 'appointment', 'Appointment requested', 'Your appointment request for 2026-08-03 at 19:30:00 has been received.', '/appointments', 106, 0, '2026-08-01 07:09:46'),
(4, 127, 'appointment', 'Appointment requested', 'Your appointment request for 2026-08-04 at 17:30:00 has been received.', '/appointments', 108, 0, '2026-08-02 13:28:46'),
(5, 127, 'appointment', 'Appointment requested', 'Your appointment request for 2026-08-03 at 19:00:00 has been received.', '/appointments', 109, 0, '2026-08-03 01:58:52'),
(6, 126, 'appointment', 'Appointment confirmed', 'Your appointment has been confirmed by the doctor.', '/appointments', 107, 0, '2026-08-03 09:04:28'),
(7, 126, 'appointment', 'Appointment completed', 'Your appointment is marked complete. You can now leave a review.', '/appointments', 107, 0, '2026-08-03 09:08:26'),
(8, 127, 'appointment', 'Appointment requested', 'Your appointment request for 2026-08-04 at 03:51:00 has been received.', '/appointments', 110, 0, '2026-08-03 11:26:53'),
(9, 127, 'appointment', 'Appointment confirmed', 'Your appointment has been confirmed by the doctor.', '/appointments', 110, 0, '2026-08-03 11:27:34');

-- --------------------------------------------------------

--
-- Table structure for table `orders`
--

CREATE TABLE `orders` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `pharmacy_id` int(11) DEFAULT NULL COMMENT 'NULL if the order spans pharmacies',
  `order_number` varchar(20) NOT NULL,
  `subtotal` decimal(10,2) NOT NULL DEFAULT 0.00,
  `delivery_fee` decimal(10,2) NOT NULL DEFAULT 0.00,
  `total` decimal(10,2) NOT NULL DEFAULT 0.00,
  `payment_method` enum('bKash','Nagad','Rocket','Credit/Debit Card','Bank Transfer','Cash') NOT NULL DEFAULT 'Cash',
  `payment_status` enum('pending','paid','refunded') DEFAULT 'pending',
  `transaction_id` varchar(100) DEFAULT NULL,
  `sender_number` varchar(20) DEFAULT NULL,
  `status` enum('pending','confirmed','processing','shipped','delivered','cancelled') DEFAULT 'pending',
  `delivery_name` varchar(100) NOT NULL,
  `delivery_phone` varchar(20) NOT NULL,
  `delivery_address` text NOT NULL,
  `delivery_city` varchar(50) DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `order_items`
--

CREATE TABLE `order_items` (
  `id` int(11) NOT NULL,
  `order_id` int(11) NOT NULL,
  `product_id` int(11) DEFAULT NULL,
  `product_name` varchar(255) NOT NULL,
  `unit_price` decimal(10,2) NOT NULL,
  `quantity` int(11) NOT NULL DEFAULT 1,
  `line_total` decimal(10,2) NOT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `payments`
--

CREATE TABLE `payments` (
  `id` int(11) NOT NULL,
  `appointment_id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `amount` decimal(10,2) NOT NULL,
  `payment_method` enum('bKash','Nagad','Rocket','Credit/Debit Card','Bank Transfer','Cash') NOT NULL,
  `transaction_id` varchar(100) DEFAULT NULL,
  `sender_number` varchar(20) DEFAULT NULL,
  `payment_status` enum('pending','verified','rejected') DEFAULT 'pending',
  `verified_by` int(11) DEFAULT NULL,
  `verified_at` timestamp NULL DEFAULT NULL,
  `rejection_reason` text DEFAULT NULL,
  `notes` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Triggers `payments`
--
DELIMITER $$
CREATE TRIGGER `payments_after_insert` AFTER INSERT ON `payments` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'payments',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'appointment_id', NEW.appointment_id,
            'user_id', NEW.user_id,
            'amount', NEW.amount,
            'payment_method', NEW.payment_method,
            'transaction_id', NEW.transaction_id,
            'payment_status', NEW.payment_status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `payments_after_update` AFTER UPDATE ON `payments` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF IFNULL(OLD.payment_status,'') != IFNULL(NEW.payment_status,'') THEN SET changed = CONCAT(changed, 'payment_status,'); END IF;
    IF IFNULL(OLD.verified_by,0) != IFNULL(NEW.verified_by,0) THEN SET changed = CONCAT(changed, 'verified_by,'); END IF;
    IF IFNULL(OLD.rejection_reason,'') != IFNULL(NEW.rejection_reason,'') THEN SET changed = CONCAT(changed, 'rejection_reason,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'payments',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'appointment_id', OLD.appointment_id,
                'amount', OLD.amount,
                'payment_method', OLD.payment_method,
                'payment_status', OLD.payment_status,
                'verified_by', OLD.verified_by
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'appointment_id', NEW.appointment_id,
                'amount', NEW.amount,
                'payment_method', NEW.payment_method,
                'payment_status', NEW.payment_status,
                'verified_by', NEW.verified_by
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `payments_before_delete` BEFORE DELETE ON `payments` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'payments',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'appointment_id', OLD.appointment_id,
            'user_id', OLD.user_id,
            'amount', OLD.amount,
            'payment_method', OLD.payment_method,
            'transaction_id', OLD.transaction_id,
            'payment_status', OLD.payment_status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `pharmacies`
--

CREATE TABLE `pharmacies` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `name` varchar(255) NOT NULL,
  `license_number` varchar(100) NOT NULL,
  `drug_license_number` varchar(100) DEFAULT NULL,
  `license_document` varchar(255) DEFAULT NULL,
  `owner_name` varchar(100) DEFAULT NULL,
  `pharmacist_name` varchar(100) DEFAULT NULL,
  `pharmacist_license` varchar(100) DEFAULT NULL,
  `email` varchar(100) DEFAULT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `whatsapp` varchar(20) DEFAULT NULL,
  `address` text NOT NULL,
  `city` varchar(50) NOT NULL,
  `area` varchar(100) DEFAULT NULL,
  `pharmacy_type` enum('retail','wholesale','hospital','chain') DEFAULT 'retail',
  `established_year` year(4) DEFAULT NULL,
  `services` text DEFAULT NULL,
  `delivery_available` tinyint(1) DEFAULT 0,
  `delivery_radius_km` int(11) DEFAULT 0,
  `open_24_hours` tinyint(1) DEFAULT 0,
  `opening_time` time DEFAULT NULL,
  `closing_time` time DEFAULT NULL,
  `description` text DEFAULT NULL,
  `rating` decimal(3,2) DEFAULT 0.00,
  `total_reviews` int(11) DEFAULT 0,
  `verification_status` enum('pending','verified','rejected') DEFAULT 'pending',
  `status` enum('pending','active','inactive') DEFAULT 'pending',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Triggers `pharmacies`
--
DELIMITER $$
CREATE TRIGGER `pharmacies_after_insert` AFTER INSERT ON `pharmacies` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'pharmacies',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'name', NEW.name,
            'license_number', NEW.license_number,
            'city', NEW.city,
            'pharmacy_type', NEW.pharmacy_type,
            'delivery_available', NEW.delivery_available,
            'verification_status', NEW.verification_status,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `pharmacies_after_update` AFTER UPDATE ON `pharmacies` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.name != NEW.name THEN SET changed = CONCAT(changed, 'name,'); END IF;
    IF IFNULL(OLD.phone,'') != IFNULL(NEW.phone,'') THEN SET changed = CONCAT(changed, 'phone,'); END IF;
    IF IFNULL(OLD.address,'') != IFNULL(NEW.address,'') THEN SET changed = CONCAT(changed, 'address,'); END IF;
    IF IFNULL(OLD.city,'') != IFNULL(NEW.city,'') THEN SET changed = CONCAT(changed, 'city,'); END IF;
    IF OLD.delivery_available != NEW.delivery_available THEN SET changed = CONCAT(changed, 'delivery_available,'); END IF;
    IF IFNULL(OLD.verification_status,'') != IFNULL(NEW.verification_status,'') THEN SET changed = CONCAT(changed, 'verification_status,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    IF OLD.rating != NEW.rating THEN SET changed = CONCAT(changed, 'rating,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'pharmacies',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'phone', OLD.phone,
                'address', OLD.address,
                'city', OLD.city,
                'delivery_available', OLD.delivery_available,
                'verification_status', OLD.verification_status,
                'status', OLD.status,
                'rating', OLD.rating
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'phone', NEW.phone,
                'address', NEW.address,
                'city', NEW.city,
                'delivery_available', NEW.delivery_available,
                'verification_status', NEW.verification_status,
                'status', NEW.status,
                'rating', NEW.rating
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `pharmacies_before_delete` BEFORE DELETE ON `pharmacies` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'pharmacies',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'name', OLD.name,
            'license_number', OLD.license_number,
            'city', OLD.city,
            'pharmacy_type', OLD.pharmacy_type,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `pharmacy_products`
--

CREATE TABLE `pharmacy_products` (
  `id` int(11) NOT NULL,
  `pharmacy_id` int(11) NOT NULL,
  `name` varchar(255) NOT NULL,
  `generic_name` varchar(255) DEFAULT NULL,
  `brand` varchar(150) DEFAULT NULL,
  `category` varchar(100) DEFAULT NULL COMMENT 'e.g. Ayurvedic, Herbal, Supplement',
  `description` text DEFAULT NULL,
  `image` varchar(255) DEFAULT NULL,
  `price` decimal(10,2) NOT NULL DEFAULT 0.00,
  `mrp` decimal(10,2) DEFAULT NULL COMMENT 'strike-through price; NULL = no discount shown',
  `unit` varchar(50) DEFAULT NULL COMMENT 'e.g. 100ml bottle, strip of 10',
  `stock` int(11) NOT NULL DEFAULT 0,
  `prescription_required` tinyint(1) NOT NULL DEFAULT 0,
  `status` enum('active','inactive') DEFAULT 'active',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- --------------------------------------------------------

--
-- Table structure for table `reviews`
--

CREATE TABLE `reviews` (
  `id` int(11) NOT NULL,
  `user_id` int(11) NOT NULL,
  `reviewable_type` enum('doctor','hospital','clinic','pharmacy') NOT NULL,
  `reviewable_id` int(11) NOT NULL,
  `rating` tinyint(4) NOT NULL CHECK (`rating` >= 1 and `rating` <= 5),
  `comment` text DEFAULT NULL,
  `status` enum('pending','approved','rejected') DEFAULT 'pending',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp()
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `reviews`
--

INSERT INTO `reviews` (`id`, `user_id`, `reviewable_type`, `reviewable_id`, `rating`, `comment`, `status`, `created_at`, `updated_at`) VALUES
(4, 2, 'doctor', 1, 5, 'Excellent doctor! Very professional and caring. The consultation was thorough and he explained everything clearly. Highly recommended for anyone seeking quality healthcare.', 'approved', '2025-12-31 22:42:38', '2025-12-31 22:42:38'),
(5, 6, 'doctor', 2, 5, 'Best experience ever! The doctor was very attentive and took time to understand my concerns. The treatment was effective and I recovered quickly.', 'approved', '2025-12-31 22:42:38', '2025-12-31 22:42:38'),
(6, 7, 'doctor', 3, 4, 'Very good service. The doctor was knowledgeable and provided great advice. The clinic was clean and well-organized. Will definitely visit again.', 'approved', '2025-12-31 22:42:38', '2025-12-31 22:42:38'),
(7, 8, 'doctor', 4, 5, 'Amazing healthcare service! The staff was friendly and the doctor was extremely helpful. Got my appointment quickly through this platform.', 'approved', '2025-12-31 22:42:38', '2025-12-31 22:42:38'),
(8, 9, 'doctor', 5, 4, 'Great platform for finding doctors. I found a specialist easily and the booking process was smooth. The doctor was professional and helpful.', 'approved', '2025-12-31 22:42:38', '2025-12-31 22:42:38'),
(9, 2, 'doctor', 6, 5, 'Ayur made it so easy to find the right doctor for my needs. The consultation was excellent and I feel much better now. Thank you!', 'approved', '2025-12-31 22:42:38', '2025-12-31 22:42:38'),
(10, 123, 'doctor', 1, 3, 'good doctor', 'approved', '2026-01-02 23:41:11', '2026-01-02 23:42:02'),
(11, 127, 'doctor', 103, 3, 'good doctor', 'approved', '2026-08-03 11:26:30', '2026-08-03 11:28:49');

--
-- Triggers `reviews`
--
DELIMITER $$
CREATE TRIGGER `reviews_after_insert` AFTER INSERT ON `reviews` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'reviews',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'user_id', NEW.user_id,
            'reviewable_type', NEW.reviewable_type,
            'reviewable_id', NEW.reviewable_id,
            'rating', NEW.rating,
            'comment', NEW.comment,
            'status', NEW.status
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `reviews_after_update` AFTER UPDATE ON `reviews` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.rating != NEW.rating THEN SET changed = CONCAT(changed, 'rating,'); END IF;
    IF IFNULL(OLD.comment,'') != IFNULL(NEW.comment,'') THEN SET changed = CONCAT(changed, 'comment,'); END IF;
    IF IFNULL(OLD.status,'') != IFNULL(NEW.status,'') THEN SET changed = CONCAT(changed, 'status,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'reviews',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'user_id', OLD.user_id,
                'reviewable_type', OLD.reviewable_type,
                'reviewable_id', OLD.reviewable_id,
                'rating', OLD.rating,
                'comment', OLD.comment,
                'status', OLD.status
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'user_id', NEW.user_id,
                'reviewable_type', NEW.reviewable_type,
                'reviewable_id', NEW.reviewable_id,
                'rating', NEW.rating,
                'comment', NEW.comment,
                'status', NEW.status
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `reviews_before_delete` BEFORE DELETE ON `reviews` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'reviews',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'user_id', OLD.user_id,
            'reviewable_type', OLD.reviewable_type,
            'reviewable_id', OLD.reviewable_id,
            'rating', OLD.rating,
            'comment', OLD.comment,
            'status', OLD.status
        )
    );
END
$$
DELIMITER ;

-- --------------------------------------------------------

--
-- Table structure for table `users`
--

CREATE TABLE `users` (
  `id` int(11) NOT NULL,
  `name` varchar(100) NOT NULL,
  `email` varchar(100) NOT NULL,
  `password` varchar(255) NOT NULL,
  `phone` varchar(20) DEFAULT NULL,
  `gender` enum('male','female','other') DEFAULT NULL,
  `address` text DEFAULT NULL,
  `profile_image` varchar(255) DEFAULT NULL,
  `role` enum('patient','doctor','hospital','clinic','pharmacy','admin') DEFAULT 'patient',
  `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
  `updated_at` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
  `city` varchar(100) DEFAULT NULL,
  `blood_group` enum('A+','A-','B+','B-','AB+','AB-','O+','O-') DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

--
-- Dumping data for table `users`
--

INSERT INTO `users` (`id`, `name`, `email`, `password`, `phone`, `gender`, `address`, `profile_image`, `role`, `created_at`, `updated_at`, `city`, `blood_group`) VALUES
(2, 'Test Patient', 'patient@test.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01711111111', NULL, 'Dhaka, Bangladesh', NULL, 'patient', '2025-12-28 13:03:13', '2025-12-28 13:03:13', NULL, NULL),
(3, 'Dr. Rahman Khan', 'doctor@test.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01722222222', 'male', NULL, NULL, 'doctor', '2025-12-28 13:03:13', '2025-12-28 13:03:13', NULL, NULL),
(4, 'ahmed', 'ahmed@gmail.com', '$2y$10$oaPMGoNdJHDBJat6Iv.hnesGBci0ZmQy3D9S.//Joihb21aNM77JK', '01834023685', 'male', NULL, '695185bbc3caf.jpg', 'doctor', '2025-12-28 13:05:48', '2025-12-28 13:32:11', NULL, NULL),
(5, 'Admin', 'admin@ayur.com', '$2y$10$Z/49SoP64vNOf5zvHDOKheEBlpFRt1TbgAVWmLZmFh9RP6sOSFA3C', '', NULL, NULL, NULL, 'admin', '2025-12-28 13:13:48', '2025-12-28 13:13:48', NULL, NULL),
(6, 'ezaz', 'ezaz@gmail.com', '$2y$10$2cPgj.5d6YLsd9D3eRRLZuMV0a1nVtI4ZcqB.tgxHwU9kDNtMsHAS', '01834023685', NULL, 'Sadar road,12', NULL, 'patient', '2025-12-28 13:49:27', '2025-12-28 13:49:27', NULL, NULL),
(7, 'pollob', 'pollob@gmail.com', '$2y$10$iEWtwtJVM/1JUNwMGrFCM.vGd2GjN7HLDr.i5FeKY43YW2yqA1vna', '01835457475', NULL, 'Sadar road,12', '6955a8e64a494.jpg', 'patient', '2025-12-28 22:28:57', '2025-12-31 22:51:18', NULL, NULL),
(8, 'Brazil', 'brazil@gmai.com', '$2y$10$.v3jF91d2A.1IsgiCs6Ht.kvSTWe7hHNOAYnkkYZMTscyL95ZqKI6', '01834023685', NULL, 'Sadar road,12', NULL, 'patient', '2025-12-28 23:02:52', '2025-12-28 23:02:52', NULL, NULL),
(9, 'abc', 'abc@gmail.com', '$2y$10$zffaXH7tNC7jH2VJf8w/I.GjH2jDLhfEgt2ebbjbndRcilTasIdhC', '01834023685', NULL, 'Sadar road,12', NULL, 'patient', '2025-12-28 23:06:23', '2025-12-28 23:06:23', NULL, NULL),
(10, 'Doctor 10', 'doctor10@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000010', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:00:00', '2025-12-30 02:00:00', NULL, NULL),
(11, 'Doctor 11', 'doctor11@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000011', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:01:00', '2025-12-30 02:01:00', NULL, NULL),
(12, 'Doctor 12', 'doctor12@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000012', 'male', 'Chattogram', NULL, 'doctor', '2025-12-30 02:02:00', '2025-12-30 02:02:00', NULL, NULL),
(13, 'Doctor 13', 'doctor13@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000013', 'male', 'Sylhet', NULL, 'doctor', '2025-12-30 02:03:00', '2025-12-30 02:03:00', NULL, NULL),
(14, 'Doctor 14', 'doctor14@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000014', 'female', 'Rajshahi', NULL, 'doctor', '2025-12-30 02:04:00', '2025-12-30 02:04:00', NULL, NULL),
(15, 'Doctor 15', 'doctor15@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000015', 'male', 'Mymensingh', NULL, 'doctor', '2025-12-30 02:05:00', '2025-12-30 02:05:00', NULL, NULL),
(16, 'Doctor 16', 'doctor16@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000016', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:06:00', '2025-12-30 02:06:00', NULL, NULL),
(17, 'Doctor 17', 'doctor17@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000017', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:07:00', '2025-12-30 02:07:00', NULL, NULL),
(18, 'Doctor 18', 'doctor18@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000018', 'male', 'Chattogram', NULL, 'doctor', '2025-12-30 02:08:00', '2025-12-30 02:08:00', NULL, NULL),
(19, 'Doctor 19', 'doctor19@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000019', 'female', 'Sylhet', NULL, 'doctor', '2025-12-30 02:09:00', '2025-12-30 02:09:00', NULL, NULL),
(20, 'Doctor 20', 'doctor20@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000020', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:10:00', '2025-12-30 02:10:00', NULL, NULL),
(21, 'Doctor 21', 'doctor21@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000021', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:11:00', '2025-12-30 02:11:00', NULL, NULL),
(22, 'Doctor 22', 'doctor22@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000022', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:12:00', '2025-12-30 02:12:00', NULL, NULL),
(23, 'Doctor 23', 'doctor23@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000023', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:13:00', '2025-12-30 02:13:00', NULL, NULL),
(24, 'Doctor 24', 'doctor24@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000024', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:14:00', '2025-12-30 02:14:00', NULL, NULL),
(25, 'Doctor 25', 'doctor25@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000025', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:15:00', '2025-12-30 02:15:00', NULL, NULL),
(26, 'Doctor 26', 'doctor26@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000026', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:16:00', '2025-12-30 02:16:00', NULL, NULL),
(27, 'Doctor 27', 'doctor27@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000027', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:17:00', '2025-12-30 02:17:00', NULL, NULL),
(28, 'Doctor 28', 'doctor28@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000028', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:18:00', '2025-12-30 02:18:00', NULL, NULL),
(29, 'Doctor 29', 'doctor29@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000029', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:19:00', '2025-12-30 02:19:00', NULL, NULL),
(30, 'Doctor 30', 'doctor30@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000030', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:20:00', '2025-12-30 02:20:00', NULL, NULL),
(31, 'Doctor 31', 'doctor31@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000031', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:21:00', '2025-12-30 02:21:00', NULL, NULL),
(32, 'Doctor 32', 'doctor32@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000032', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:22:00', '2025-12-30 02:22:00', NULL, NULL),
(33, 'Doctor 33', 'doctor33@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000033', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:23:00', '2025-12-30 02:23:00', NULL, NULL),
(34, 'Doctor 34', 'doctor34@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000034', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:24:00', '2025-12-30 02:24:00', NULL, NULL),
(35, 'Doctor 35', 'doctor35@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000035', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:25:00', '2025-12-30 02:25:00', NULL, NULL),
(36, 'Doctor 36', 'doctor36@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000036', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:26:00', '2025-12-30 02:26:00', NULL, NULL),
(37, 'Doctor 37', 'doctor37@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000037', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:27:00', '2025-12-30 02:27:00', NULL, NULL),
(38, 'Doctor 38', 'doctor38@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000038', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:28:00', '2025-12-30 02:28:00', NULL, NULL),
(39, 'Doctor 39', 'doctor39@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000039', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:29:00', '2025-12-30 02:29:00', NULL, NULL),
(40, 'Doctor 40', 'doctor40@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000040', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:30:00', '2025-12-30 02:30:00', NULL, NULL),
(41, 'Doctor 41', 'doctor41@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000041', 'male', 'Chattogram', NULL, 'doctor', '2025-12-30 02:31:00', '2025-12-30 02:31:00', NULL, NULL),
(42, 'Doctor 42', 'doctor42@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000042', 'female', 'Sylhet', NULL, 'doctor', '2025-12-30 02:32:00', '2025-12-30 02:32:00', NULL, NULL),
(43, 'Doctor 43', 'doctor43@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000043', 'male', 'Rajshahi', NULL, 'doctor', '2025-12-30 02:33:00', '2025-12-30 02:33:00', NULL, NULL),
(44, 'Doctor 44', 'doctor44@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000044', 'female', 'Khulna', NULL, 'doctor', '2025-12-30 02:34:00', '2025-12-30 02:34:00', NULL, NULL),
(45, 'Doctor 45', 'doctor45@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000045', 'male', 'Barishal', NULL, 'doctor', '2025-12-30 02:35:00', '2025-12-30 02:35:00', NULL, NULL),
(46, 'Doctor 46', 'doctor46@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000046', 'female', 'Rangpur', NULL, 'doctor', '2025-12-30 02:36:00', '2025-12-30 02:36:00', NULL, NULL),
(47, 'Doctor 47', 'doctor47@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000047', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:37:00', '2025-12-30 02:37:00', NULL, NULL),
(48, 'Doctor 48', 'doctor48@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000048', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:38:00', '2025-12-30 02:38:00', NULL, NULL),
(49, 'Doctor 49', 'doctor49@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000049', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:39:00', '2025-12-30 02:39:00', NULL, NULL),
(50, 'Doctor 50', 'doctor50@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000050', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:40:00', '2025-12-30 02:40:00', NULL, NULL),
(51, 'Doctor 51', 'doctor51@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000051', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:41:00', '2025-12-30 02:41:00', NULL, NULL),
(52, 'Doctor 52', 'doctor52@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000052', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:42:00', '2025-12-30 02:42:00', NULL, NULL),
(53, 'Doctor 53', 'doctor53@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000053', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:43:00', '2025-12-30 02:43:00', NULL, NULL),
(54, 'Doctor 54', 'doctor54@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000054', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:44:00', '2025-12-30 02:44:00', NULL, NULL),
(55, 'Doctor 55', 'doctor55@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000055', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:45:00', '2025-12-30 02:45:00', NULL, NULL),
(56, 'Doctor 56', 'doctor56@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000056', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:46:00', '2025-12-30 02:46:00', NULL, NULL),
(57, 'Doctor 57', 'doctor57@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000057', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:47:00', '2025-12-30 02:47:00', NULL, NULL),
(58, 'Doctor 58', 'doctor58@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000058', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:48:00', '2025-12-30 02:48:00', NULL, NULL),
(59, 'Doctor 59', 'doctor59@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000059', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:49:00', '2025-12-30 02:49:00', NULL, NULL),
(60, 'Doctor 60', 'doctor60@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000060', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:50:00', '2025-12-30 02:50:00', NULL, NULL),
(61, 'Doctor 61', 'doctor61@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000061', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:51:00', '2025-12-30 02:51:00', NULL, NULL),
(62, 'Doctor 62', 'doctor62@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000062', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:52:00', '2025-12-30 02:52:00', NULL, NULL),
(63, 'Doctor 63', 'doctor63@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000063', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:53:00', '2025-12-30 02:53:00', NULL, NULL),
(64, 'Doctor 64', 'doctor64@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000064', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:54:00', '2025-12-30 02:54:00', NULL, NULL),
(65, 'Doctor 65', 'doctor65@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000065', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:55:00', '2025-12-30 02:55:00', NULL, NULL),
(66, 'Doctor 66', 'doctor66@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000066', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:56:00', '2025-12-30 02:56:00', NULL, NULL),
(67, 'Doctor 67', 'doctor67@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000067', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:57:00', '2025-12-30 02:57:00', NULL, NULL),
(68, 'Doctor 68', 'doctor68@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000068', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 02:58:00', '2025-12-30 02:58:00', NULL, NULL),
(69, 'Doctor 69', 'doctor69@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000069', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 02:59:00', '2025-12-30 02:59:00', NULL, NULL),
(70, 'Doctor 70', 'doctor70@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000070', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:00:00', '2025-12-30 03:00:00', NULL, NULL),
(71, 'Doctor 71', 'doctor71@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000071', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:01:00', '2025-12-30 03:01:00', NULL, NULL),
(72, 'Doctor 72', 'doctor72@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000072', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:02:00', '2025-12-30 03:02:00', NULL, NULL),
(73, 'Doctor 73', 'doctor73@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000073', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:03:00', '2025-12-30 03:03:00', NULL, NULL),
(74, 'Doctor 74', 'doctor74@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000074', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:04:00', '2025-12-30 03:04:00', NULL, NULL),
(75, 'Doctor 75', 'doctor75@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000075', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:05:00', '2025-12-30 03:05:00', NULL, NULL),
(76, 'Doctor 76', 'doctor76@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000076', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:06:00', '2025-12-30 03:06:00', NULL, NULL),
(77, 'Doctor 77', 'doctor77@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000077', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:07:00', '2025-12-30 03:07:00', NULL, NULL),
(78, 'Doctor 78', 'doctor78@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000078', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:08:00', '2025-12-30 03:08:00', NULL, NULL),
(79, 'Doctor 79', 'doctor79@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000079', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:09:00', '2025-12-30 03:09:00', NULL, NULL),
(80, 'Doctor 80', 'doctor80@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000080', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:10:00', '2025-12-30 03:10:00', NULL, NULL),
(81, 'Doctor 81', 'doctor81@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000081', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:11:00', '2025-12-30 03:11:00', NULL, NULL),
(82, 'Doctor 82', 'doctor82@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000082', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:12:00', '2025-12-30 03:12:00', NULL, NULL),
(83, 'Doctor 83', 'doctor83@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000083', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:13:00', '2025-12-30 03:13:00', NULL, NULL),
(84, 'Doctor 84', 'doctor84@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000084', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:14:00', '2025-12-30 03:14:00', NULL, NULL),
(85, 'Doctor 85', 'doctor85@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000085', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:15:00', '2025-12-30 03:15:00', NULL, NULL),
(86, 'Doctor 86', 'doctor86@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000086', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:16:00', '2025-12-30 03:16:00', NULL, NULL),
(87, 'Doctor 87', 'doctor87@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000087', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:17:00', '2025-12-30 03:17:00', NULL, NULL),
(88, 'Doctor 88', 'doctor88@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000088', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:18:00', '2025-12-30 03:18:00', NULL, NULL),
(89, 'Doctor 89', 'doctor89@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000089', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:19:00', '2025-12-30 03:19:00', NULL, NULL),
(90, 'Doctor 90', 'doctor90@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000090', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:20:00', '2025-12-30 03:20:00', NULL, NULL),
(91, 'Doctor 91', 'doctor91@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000091', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:21:00', '2025-12-30 03:21:00', NULL, NULL),
(92, 'Doctor 92', 'doctor92@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000092', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:22:00', '2025-12-30 03:22:00', NULL, NULL),
(93, 'Doctor 93', 'doctor93@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000093', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:23:00', '2025-12-30 03:23:00', NULL, NULL),
(94, 'Doctor 94', 'doctor94@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000094', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:24:00', '2025-12-30 03:24:00', NULL, NULL),
(95, 'Doctor 95', 'doctor95@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000095', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:25:00', '2025-12-30 03:25:00', NULL, NULL),
(96, 'Doctor 96', 'doctor96@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000096', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:26:00', '2025-12-30 03:26:00', NULL, NULL),
(97, 'Doctor 97', 'doctor97@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000097', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:27:00', '2025-12-30 03:27:00', NULL, NULL),
(98, 'Doctor 98', 'doctor98@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000098', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:28:00', '2025-12-30 03:28:00', NULL, NULL),
(99, 'Doctor 99', 'doctor99@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000099', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:29:00', '2025-12-30 03:29:00', NULL, NULL),
(100, 'Doctor 100', 'doctor100@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000100', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:30:00', '2025-12-30 03:30:00', NULL, NULL),
(101, 'Doctor 101', 'doctor101@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000101', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:31:00', '2025-12-30 03:31:00', NULL, NULL),
(102, 'Doctor 102', 'doctor102@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000102', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:32:00', '2025-12-30 03:32:00', NULL, NULL),
(103, 'Doctor 103', 'doctor103@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000103', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:33:00', '2025-12-30 03:33:00', NULL, NULL),
(104, 'Doctor 104', 'doctor104@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000104', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:34:00', '2025-12-30 03:34:00', NULL, NULL),
(105, 'Doctor 105', 'doctor105@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000105', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:35:00', '2025-12-30 03:35:00', NULL, NULL),
(107, 'Doctor 107', 'doctor107@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000107', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:37:00', '2025-12-30 03:37:00', NULL, NULL),
(108, 'Doctor 108', 'doctor108@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000108', 'female', 'Dhaka', NULL, 'doctor', '2025-12-30 03:38:00', '2025-12-30 03:38:00', NULL, NULL),
(109, 'Doctor 109', 'doctor109@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01710000109', 'male', 'Dhaka', NULL, 'doctor', '2025-12-30 03:39:00', '2025-12-30 03:39:00', NULL, NULL),
(110, 'Donor 110', 'donor110@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000110', 'male', 'Mirpur, Dhaka', NULL, 'patient', '2025-12-30 04:00:00', '2025-12-30 04:00:00', NULL, NULL),
(111, 'Donor 111', 'donor111@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000111', 'female', 'Gulshan, Dhaka', NULL, 'patient', '2025-12-30 04:01:00', '2025-12-30 04:01:00', NULL, NULL),
(112, 'Donor 112', 'donor112@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000112', 'male', 'Uttara, Dhaka', NULL, 'patient', '2025-12-30 04:02:00', '2025-12-30 04:02:00', NULL, NULL),
(113, 'Donor 113', 'donor113@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000113', 'female', 'Dhanmondi, Dhaka', NULL, 'patient', '2025-12-30 04:03:00', '2025-12-30 04:03:00', NULL, NULL),
(114, 'Donor 114', 'donor114@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000114', 'male', 'Chattogram Sadar, Chattogram', NULL, 'patient', '2025-12-30 04:04:00', '2025-12-30 04:04:00', NULL, NULL),
(115, 'Donor 115', 'donor115@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000115', 'female', 'Sylhet Sadar, Sylhet', NULL, 'patient', '2025-12-30 04:05:00', '2025-12-30 04:05:00', NULL, NULL),
(116, 'Donor 116', 'donor116@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000116', 'male', 'Rajshahi Sadar, Rajshahi', NULL, 'patient', '2025-12-30 04:06:00', '2025-12-30 04:06:00', NULL, NULL),
(117, 'Donor 117', 'donor117@ayur.com', '$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi', '01720000117', 'female', 'Khulna Sadar, Khulna', NULL, 'patient', '2025-12-30 04:07:00', '2025-12-30 04:07:00', NULL, NULL),
(123, 'abcd', 'abcd@gmail.com', '$2y$10$Hn8VQYHEwR99JUW4UPk7AOiPBGGU.sxrGpcrm2iAgyjk.AWYguNI.', '01834562355', NULL, 'patuakhali', NULL, 'patient', '2026-01-02 23:39:57', '2026-01-02 23:39:57', NULL, NULL),
(124, 'shahriar ahmed', 'shahriar@gmail.com', '$2y$10$E..qNYWcT.ApWxiF6ddQ7OVFthzX3qYg22xJ50qQ/UWQiT6djxSB.', '01938298192', NULL, 'dumki patuakhali', NULL, 'patient', '2026-07-31 07:16:46', '2026-07-31 07:16:46', NULL, NULL),
(125, 'shah', 'shah@gmail.com', '$2y$10$ItP60xXEdX6M8RdtDdqgB.LARyu4l/9NUl6b8Kte4k7R.hHoqaXYa', '01736253456', NULL, 'dumki', NULL, 'patient', '2026-08-01 06:51:45', '2026-08-01 06:52:27', 'Rangpur', 'B+'),
(126, 'shahriar ahmed', 'shahriarahmed@gmail.com', '$2y$10$TWvFog4srlLf5mNFgKW5newrQqXHUrQsqg0vym5yjz.kUllumpA0i', '01712457832', 'male', NULL, NULL, 'doctor', '2026-08-01 07:13:03', '2026-08-03 09:05:01', 'Sylhet', NULL),
(127, 'abc', 'abc1@gmail.com', '$2y$10$to30L7PDKWDmfyXVBS8KOueG65k5R288PpSMDzcMt9cSMehdKGI0.', '01823745618', NULL, NULL, NULL, 'patient', '2026-08-02 13:27:27', '2026-08-02 13:27:27', NULL, NULL);

--
-- Triggers `users`
--
DELIMITER $$
CREATE TRIGGER `users_after_insert` AFTER INSERT ON `users` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, new_values)
    VALUES (
        'users',
        NEW.id,
        'INSERT',
        JSON_OBJECT(
            'id', NEW.id,
            'name', NEW.name,
            'email', NEW.email,
            'phone', NEW.phone,
            'gender', NEW.gender,
            'address', NEW.address,
            'role', NEW.role,
            'created_at', NEW.created_at
        )
    );
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `users_after_update` AFTER UPDATE ON `users` FOR EACH ROW BEGIN
    DECLARE changed TEXT DEFAULT '';
    
    IF OLD.name != NEW.name THEN SET changed = CONCAT(changed, 'name,'); END IF;
    IF OLD.email != NEW.email THEN SET changed = CONCAT(changed, 'email,'); END IF;
    IF IFNULL(OLD.phone,'') != IFNULL(NEW.phone,'') THEN SET changed = CONCAT(changed, 'phone,'); END IF;
    IF IFNULL(OLD.gender,'') != IFNULL(NEW.gender,'') THEN SET changed = CONCAT(changed, 'gender,'); END IF;
    IF IFNULL(OLD.address,'') != IFNULL(NEW.address,'') THEN SET changed = CONCAT(changed, 'address,'); END IF;
    IF IFNULL(OLD.profile_image,'') != IFNULL(NEW.profile_image,'') THEN SET changed = CONCAT(changed, 'profile_image,'); END IF;
    IF OLD.role != NEW.role THEN SET changed = CONCAT(changed, 'role,'); END IF;
    
    IF changed != '' THEN
        INSERT INTO audit_log (table_name, record_id, action_type, old_values, new_values, changed_fields)
        VALUES (
            'users',
            NEW.id,
            'UPDATE',
            JSON_OBJECT(
                'id', OLD.id,
                'name', OLD.name,
                'email', OLD.email,
                'phone', OLD.phone,
                'gender', OLD.gender,
                'address', OLD.address,
                'role', OLD.role
            ),
            JSON_OBJECT(
                'id', NEW.id,
                'name', NEW.name,
                'email', NEW.email,
                'phone', NEW.phone,
                'gender', NEW.gender,
                'address', NEW.address,
                'role', NEW.role
            ),
            TRIM(TRAILING ',' FROM changed)
        );
    END IF;
END
$$
DELIMITER ;
DELIMITER $$
CREATE TRIGGER `users_before_delete` BEFORE DELETE ON `users` FOR EACH ROW BEGIN
    INSERT INTO audit_log (table_name, record_id, action_type, old_values)
    VALUES (
        'users',
        OLD.id,
        'DELETE',
        JSON_OBJECT(
            'id', OLD.id,
            'name', OLD.name,
            'email', OLD.email,
            'phone', OLD.phone,
            'gender', OLD.gender,
            'address', OLD.address,
            'profile_image', OLD.profile_image,
            'role', OLD.role,
            'created_at', OLD.created_at,
            'updated_at', OLD.updated_at
        )
    );
END
$$
DELIMITER ;

--
-- Indexes for dumped tables
--

--
-- Indexes for table `appointments`
--
ALTER TABLE `appointments`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `confirmation_code` (`confirmation_code`),
  ADD KEY `idx_patient` (`patient_id`),
  ADD KEY `idx_doctor` (`doctor_id`),
  ADD KEY `idx_date` (`appointment_date`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_confirmation_code` (`confirmation_code`);

--
-- Indexes for table `app_audit_log`
--
ALTER TABLE `app_audit_log`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_user` (`user_id`),
  ADD KEY `idx_action` (`action`),
  ADD KEY `idx_created` (`created_at`);

--
-- Indexes for table `audit_log`
--
ALTER TABLE `audit_log`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_table_name` (`table_name`),
  ADD KEY `idx_record_id` (`record_id`),
  ADD KEY `idx_action_type` (`action_type`),
  ADD KEY `idx_timestamp` (`action_timestamp`),
  ADD KEY `idx_table_record` (`table_name`,`record_id`);

--
-- Indexes for table `blogs`
--
ALTER TABLE `blogs`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_slug` (`slug`),
  ADD KEY `idx_status_pub` (`status`,`published_at`),
  ADD KEY `idx_category` (`category`),
  ADD KEY `blogs_ibfk_1` (`author_id`);

--
-- Indexes for table `blood_banks`
--
ALTER TABLE `blood_banks`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `blood_donors`
--
ALTER TABLE `blood_donors`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`),
  ADD KEY `idx_blood_group` (`blood_group`),
  ADD KEY `idx_city` (`city`),
  ADD KEY `idx_available` (`is_available`);

--
-- Indexes for table `blood_requests`
--
ALTER TABLE `blood_requests`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_blood_group` (`blood_group`),
  ADD KEY `idx_city` (`city`),
  ADD KEY `idx_status` (`status`);

--
-- Indexes for table `cart`
--
ALTER TABLE `cart`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_cart_user_product` (`user_id`,`product_id`),
  ADD KEY `idx_product` (`product_id`);

--
-- Indexes for table `clinics`
--
ALTER TABLE `clinics`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `user_id` (`user_id`),
  ADD KEY `idx_city` (`city`),
  ADD KEY `idx_clinic_type` (`clinic_type`),
  ADD KEY `idx_status` (`status`);

--
-- Indexes for table `device_tokens`
--
ALTER TABLE `device_tokens`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_token` (`fcm_token`),
  ADD KEY `idx_user` (`user_id`);

--
-- Indexes for table `doctors`
--
ALTER TABLE `doctors`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `user_id` (`user_id`),
  ADD KEY `idx_specialization` (`specialization`),
  ADD KEY `idx_city` (`city`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_verification` (`verification_status`);

--
-- Indexes for table `feedback`
--
ALTER TABLE `feedback`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_type` (`feedback_type`),
  ADD KEY `idx_priority` (`priority`);

--
-- Indexes for table `hospitals`
--
ALTER TABLE `hospitals`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `user_id` (`user_id`),
  ADD KEY `idx_city` (`city`),
  ADD KEY `idx_hospital_type` (`hospital_type`),
  ADD KEY `idx_status` (`status`);

--
-- Indexes for table `notifications`
--
ALTER TABLE `notifications`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_user_read` (`user_id`,`is_read`),
  ADD KEY `idx_created` (`created_at`);

--
-- Indexes for table `orders`
--
ALTER TABLE `orders`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `uq_order_number` (`order_number`),
  ADD KEY `idx_user` (`user_id`),
  ADD KEY `idx_pharmacy` (`pharmacy_id`),
  ADD KEY `idx_status` (`status`);

--
-- Indexes for table `order_items`
--
ALTER TABLE `order_items`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_order` (`order_id`),
  ADD KEY `idx_product` (`product_id`);

--
-- Indexes for table `payments`
--
ALTER TABLE `payments`
  ADD PRIMARY KEY (`id`),
  ADD KEY `verified_by` (`verified_by`),
  ADD KEY `idx_appointment` (`appointment_id`),
  ADD KEY `idx_user` (`user_id`),
  ADD KEY `idx_transaction` (`transaction_id`),
  ADD KEY `idx_status` (`payment_status`);

--
-- Indexes for table `pharmacies`
--
ALTER TABLE `pharmacies`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `user_id` (`user_id`),
  ADD KEY `idx_city` (`city`),
  ADD KEY `idx_pharmacy_type` (`pharmacy_type`),
  ADD KEY `idx_status` (`status`);

--
-- Indexes for table `pharmacy_products`
--
ALTER TABLE `pharmacy_products`
  ADD PRIMARY KEY (`id`),
  ADD KEY `idx_pharmacy` (`pharmacy_id`),
  ADD KEY `idx_category` (`category`),
  ADD KEY `idx_status` (`status`),
  ADD KEY `idx_name` (`name`);

--
-- Indexes for table `reviews`
--
ALTER TABLE `reviews`
  ADD PRIMARY KEY (`id`),
  ADD KEY `user_id` (`user_id`),
  ADD KEY `idx_reviewable` (`reviewable_type`,`reviewable_id`),
  ADD KEY `idx_status` (`status`);

--
-- Indexes for table `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`id`),
  ADD UNIQUE KEY `email` (`email`),
  ADD KEY `idx_email` (`email`),
  ADD KEY `idx_role` (`role`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `appointments`
--
ALTER TABLE `appointments`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=111;

--
-- AUTO_INCREMENT for table `app_audit_log`
--
ALTER TABLE `app_audit_log`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=51;

--
-- AUTO_INCREMENT for table `audit_log`
--
ALTER TABLE `audit_log`
  MODIFY `id` bigint(20) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=39;

--
-- AUTO_INCREMENT for table `blogs`
--
ALTER TABLE `blogs`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=3;

--
-- AUTO_INCREMENT for table `blood_banks`
--
ALTER TABLE `blood_banks`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=5;

--
-- AUTO_INCREMENT for table `blood_donors`
--
ALTER TABLE `blood_donors`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=12;

--
-- AUTO_INCREMENT for table `blood_requests`
--
ALTER TABLE `blood_requests`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=2;

--
-- AUTO_INCREMENT for table `cart`
--
ALTER TABLE `cart`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `clinics`
--
ALTER TABLE `clinics`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `device_tokens`
--
ALTER TABLE `device_tokens`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `doctors`
--
ALTER TABLE `doctors`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=104;

--
-- AUTO_INCREMENT for table `feedback`
--
ALTER TABLE `feedback`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `hospitals`
--
ALTER TABLE `hospitals`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `notifications`
--
ALTER TABLE `notifications`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=10;

--
-- AUTO_INCREMENT for table `orders`
--
ALTER TABLE `orders`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `order_items`
--
ALTER TABLE `order_items`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `payments`
--
ALTER TABLE `payments`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pharmacies`
--
ALTER TABLE `pharmacies`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `pharmacy_products`
--
ALTER TABLE `pharmacy_products`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT;

--
-- AUTO_INCREMENT for table `reviews`
--
ALTER TABLE `reviews`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=12;

--
-- AUTO_INCREMENT for table `users`
--
ALTER TABLE `users`
  MODIFY `id` int(11) NOT NULL AUTO_INCREMENT, AUTO_INCREMENT=128;

--
-- Constraints for dumped tables
--

--
-- Constraints for table `appointments`
--
ALTER TABLE `appointments`
  ADD CONSTRAINT `appointments_ibfk_1` FOREIGN KEY (`patient_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
  ADD CONSTRAINT `appointments_ibfk_2` FOREIGN KEY (`doctor_id`) REFERENCES `doctors` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `app_audit_log`
--
ALTER TABLE `app_audit_log`
  ADD CONSTRAINT `app_audit_log_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `blogs`
--
ALTER TABLE `blogs`
  ADD CONSTRAINT `blogs_ibfk_1` FOREIGN KEY (`author_id`) REFERENCES `users` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `blood_donors`
--
ALTER TABLE `blood_donors`
  ADD CONSTRAINT `blood_donors_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `cart`
--
ALTER TABLE `cart`
  ADD CONSTRAINT `cart_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
  ADD CONSTRAINT `cart_ibfk_2` FOREIGN KEY (`product_id`) REFERENCES `pharmacy_products` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `clinics`
--
ALTER TABLE `clinics`
  ADD CONSTRAINT `clinics_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `device_tokens`
--
ALTER TABLE `device_tokens`
  ADD CONSTRAINT `device_tokens_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `doctors`
--
ALTER TABLE `doctors`
  ADD CONSTRAINT `doctors_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `feedback`
--
ALTER TABLE `feedback`
  ADD CONSTRAINT `feedback_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `hospitals`
--
ALTER TABLE `hospitals`
  ADD CONSTRAINT `hospitals_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `notifications`
--
ALTER TABLE `notifications`
  ADD CONSTRAINT `notifications_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `orders`
--
ALTER TABLE `orders`
  ADD CONSTRAINT `orders_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
  ADD CONSTRAINT `orders_ibfk_2` FOREIGN KEY (`pharmacy_id`) REFERENCES `pharmacies` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `order_items`
--
ALTER TABLE `order_items`
  ADD CONSTRAINT `order_items_ibfk_1` FOREIGN KEY (`order_id`) REFERENCES `orders` (`id`) ON DELETE CASCADE,
  ADD CONSTRAINT `order_items_ibfk_2` FOREIGN KEY (`product_id`) REFERENCES `pharmacy_products` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `payments`
--
ALTER TABLE `payments`
  ADD CONSTRAINT `payments_ibfk_1` FOREIGN KEY (`appointment_id`) REFERENCES `appointments` (`id`) ON DELETE CASCADE,
  ADD CONSTRAINT `payments_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE,
  ADD CONSTRAINT `payments_ibfk_3` FOREIGN KEY (`verified_by`) REFERENCES `users` (`id`) ON DELETE SET NULL;

--
-- Constraints for table `pharmacies`
--
ALTER TABLE `pharmacies`
  ADD CONSTRAINT `pharmacies_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `pharmacy_products`
--
ALTER TABLE `pharmacy_products`
  ADD CONSTRAINT `pharmacy_products_ibfk_1` FOREIGN KEY (`pharmacy_id`) REFERENCES `pharmacies` (`id`) ON DELETE CASCADE;

--
-- Constraints for table `reviews`
--
ALTER TABLE `reviews`
  ADD CONSTRAINT `reviews_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE;
COMMIT;

/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
