# AYUR Flutter App — Features Overview

This document describes all user-facing features implemented in the AYUR Flutter client. The app is a Bangladeshi Ayurvedic healthcare platform connecting patients with doctors, hospitals, clinics, pharmacies, and blood banks.

---

## 1. Authentication & Onboarding

| Feature | Description |
|---------|-------------|
| **Splash & Session Restore** | Cold-start reads secure storage (OS keystore via `SecureGotrueStorage`), restores Supabase session, routes to appropriate home screen. |
| **Login** | Email/password against Supabase GoTrue. Rate-limited (10 attempts / 5 min). Shows friendly errors for invalid creds, unconfirmed email, rate limit. |
| **Role Picker** | After signup, user selects role: Patient, Doctor, Hospital, Clinic, Pharmacy. Admin is not self-registerable. |
| **Patient Registration** | Basic profile: name, email, password, phone, city, blood group. |
| **Doctor Registration** | Extended profile: name, email, password, phone, specialization, qualification, experience, consultation fee, hospital/clinic name, available days/times, avatar upload. |
| **Hospital Registration** | Name, email, password, phone, address, city, description, facilities, avatar upload. |
| **Clinic Registration** | Same fields as hospital, separate table/bucket. |
| **Pharmacy Registration** | Name, email, password, phone, address, city, license number, avatar upload. |
| **Profile Screen** | Shared across all roles. Edits name, phone, city, blood group, avatar. Password change. Role-specific fields (specialization/fee for doctors, address for places). |

---

## 2. Patient Home (Tabbed Shell)

Five tabs, each with its own navigation stack:

| Tab | Route | Key Screens |
|-----|-------|-------------|
| **Home** | `/home` | Hero banner, featured doctors, nearby places, blood bank stock summary, blog carousel. |
| **Doctors** | `/doctors` | Searchable, filterable list (specialization, city). Paginated (20/page). Tap → `DoctorDetailScreen`. |
| **Shop** | `/shop` | Pharmacy products list (paginated). Tap → `ProductDetailScreen`. Cart badge on tab. |
| **Appointments** | `/appointments` | Upcoming & past appointments. Status badges. Tap → detail. |
| **Profile** | `/profile` | Account info, orders, payments sub-routes. |

---

## 3. Doctor Directory

| Screen | Features |
|--------|----------|
| **DoctorsScreen** | Infinite scroll, search by name, filter by specialization & city. Uses `PagedController`. |
| **DoctorDetailScreen** | Photo, name, specialization, qualification, experience, consultation fee, workplace, available days/times, reviews, "Book Appointment" CTA. |

---

## 4. Place Directories (Clinics / Hospitals / Pharmacies)

| Screen | Features |
|--------|----------|
| **PlacesScreen** | Unified list for each kind. Search by name, filter by city. Paginated. |
| **PlaceDetailScreen** | Photo, name, address, city, description, facilities, reviews. Pharmacy detail shows products. |

---

## 5. Appointment Booking

| Screen | Features |
|--------|----------|
| **BookAppointmentScreen** | Calendar (table_calendar) showing doctor's available days. 30-min slots 5–9 pm Sat–Thu. Select date → time → reason. Submits to backend, returns confirmation code. |
| **MyAppointmentsScreen** | Two tabs: Upcoming / Past. Status chips (pending, confirmed, cancelled, completed). Pull-to-refresh. |
| **DoctorAppointmentsScreen** | Doctor's view: list of appointments for their slots. Actions: confirm (generates code), cancel, complete. |

---

## 6. Pharmacy & Shopping

| Screen | Features |
|--------|----------|
| **ProductsScreen** | Grid/list of products. Search, filter by category. Paginated. |
| **ProductDetailScreen** | Image, name, price, description, pharmacy, stock status. "Add to Cart". |
| **CartScreen** | Quantity steppers, line totals, BDT currency. Persists in Supabase `cart` table. |
| **CheckoutScreen** | Address confirmation, payment method (Cash on Delivery, bKash, Nagad, Card), order summary. Creates `orders` + `order_items`. |
| **OrdersScreen** | List of orders with status (pending, confirmed, shipped, delivered, cancelled). |
| **OrderDetailScreen** | Items, totals, payment status, shipping address, timeline. |

---

## 7. Blood Bank

| Screen | Features |
|--------|----------|
| **BloodBankScreen** | List of blood banks with real-time stock per blood group (A+, A-, B+, B-, AB+, AB-, O+, O-). Search by name/city. |
| **BloodRequestScreen** | Create request: blood group, units needed, urgency, contact info, notes. Lists user's past requests. |

---

## 8. Content & Static Pages

| Screen | Description |
|--------|-------------|
| **BlogScreen** | Paginated list of blog posts (cover image, title, excerpt, author, date). |
| **BlogDetailScreen** | Full article content (plain text, no HTML rendering). |
| **AboutScreen** | Static page: mission, team, contact. |
| **TermsScreen** | Terms of Service. |
| **PrivacyScreen** | Privacy Policy. |
| **ContactScreen** | Contact form (name, email, subject, message) → submits to `feedback` table. |
| **NotificationsScreen** | In-app notifications (appointment updates, order status, system). Mark-as-read, delete. |

---

## 9. Patient Extras

| Screen | Features |
|--------|----------|
| **PatientDashboardScreen** | Stats cards: upcoming appointments, pending orders, blood requests, reviews written. Quick actions. |
| **EmergencyScreen** | Ambulance/hospital quick-dial buttons. Opens phone dialer with pre-filled numbers. No auth required. |
| **FeedbackScreen** | Submit feedback/rating (1–5 stars, comment). Optional auth. |
| **MyReviewsScreen** | List of reviews authored by the patient. Edit/delete own reviews. |
| **NearbyScreen** | Placeholder for "nearby" feature (distance sorting not implemented — no lat/lng in schema). Shows all active places. |

---

## 10. Doctor Workspace (`/doctor` prefix)

| Screen | Features |
|--------|----------|
| **DoctorDashboardScreen** | Stats: today's appointments, total patients, pending payouts, rating. Quick actions. |
| **DoctorAppointmentsScreen** | Calendar view + list. Filter by date/status. Confirm/cancel/complete actions. |
| **DoctorPayoutsScreen** | List of payouts (completed appointments). Status: pending, paid. Amount, date, transaction ref. |
| **DoctorProfileScreen** | Edit specialization, qualification, experience, fee, workplace, schedule, avatar. |
| **ProviderReviewsScreen** | Reviews for this doctor. Reply to reviews. |

---

## 11. Place Workspace (`/place` prefix — Hospital, Clinic, Pharmacy)

| Screen | Features |
|--------|----------|
| **PlaceDashboardScreen** | Stats: today's appointments/orders, total doctors/products, pending payouts, rating. |
| **PlaceProfileScreen** | Edit name, address, city, description, facilities, avatar. Pharmacy: manage products (CRUD). |
| **ProviderReviewsScreen** | Shared widget — reviews for this place. Reply to reviews. |

---

## 12. Admin Console (`/admin` prefix)

| Screen | Features |
|--------|----------|
| **AdminDashboardScreen** | Overview stats via RPC `admin_dashboard_stats()`: users, doctors, places, appointments, orders, revenue, blood requests. |
| **AdminUsersScreen** | Paginated user table. Search, filter by role. Actions: view, ban/unban, promote to admin. |
| **AdminProvidersScreen** | Unified table for doctors + places. Filter by type, status, verification. Actions: verify, reject, view details. |
| **AdminAppointmentsScreen** | All appointments. Filter by date, status, doctor, patient. Admin can override status. |
| **AdminReviewsScreen** | All reviews. Filter by target type (doctor/place), rating. Moderate: hide/show. |
| **AdminFeedbackScreen** | All feedback submissions. Mark resolved. |
| **AdminBloodBanksScreen** | CRUD for blood banks. Manage stock per blood group. |
| **AdminBlogsScreen** | CRUD for blog posts. Rich text not supported — plain text content. |
| **AdminPaymentsScreen** | All payment records. Filter by status, method, date. **Manual verification only** — admin marks `payment_status = 'paid'` after verifying transaction ref. |
| **AdminPayoutsScreen** | Doctor/place payouts. Filter by status. Mark paid, add transaction ref. |
| **AdminAuditScreen** | Immutable audit log (`app_audit_log` table). Filter by actor, action, entity, date range. |

---

## 13. Payment & Payouts

- **Patient payments**: Created at checkout. Status: `pending` → admin verifies → `paid`. Never auto-marked paid.
- **Doctor/Place payouts**: Generated when appointment/order marked `completed`. Status: `pending` → admin pays → `paid`.
- **Payment methods**: Cash on Delivery, bKash, Nagad, Card (stub).
- **Transaction ref**: Manual entry by admin during verification.
- **History preserved**: Payment/payout records never overwritten; new rows for each state change.

---

## 14. Reviews & Ratings

- **One review per user per target** (enforced by unique constraint).
- **Targets**: Doctors, Hospitals, Clinics, Pharmacies.
- **Rating**: 1–5 stars + optional comment.
- **Provider reply**: Doctors/places can reply once per review.
- **Moderation**: Admin can hide inappropriate reviews.

---

## 15. Technical Foundations

| Area | Implementation |
|------|----------------|
| **State Management** | `flutter_riverpod` (plain providers, no codegen). |
| **Routing** | `go_router` with role-based guards (`_under()` segment-aware matching). |
| **Backend** | Supabase (PostgREST + GoTrue + Storage). No direct DB access. |
| **Network Layer** | `SupabaseService.guard()` wraps every call → `ApiException`. |
| **Pagination** | `PagedController` + `PagedListView` (1-based, `CountOption.exact`). |
| **Images** | `cached_network_image`. Storage columns hold **paths**; repositories resolve to signed/public URLs via `SupabaseStorage`. |
| **Formatting** | `Fmt` class (money `৳`, dates, times). No distance/geo formatter. |
| **Auth Persistence** | Session + user in OS keystore (`SecureGotrueStorage`). Theme in `SharedPreferences`. |
| **Error Mapping** | SQLSTATE codes → user messages (42501=RLS, PGRST116=404, 23505=unique, P0001=business rule). |

---

## 16. Role-Based Access Summary

| Route Prefix | Allowed Roles | Redirect If Wrong Role |
|--------------|---------------|------------------------|
| `/splash`, `/login`, `/signup`, `/register*` | Unauthenticated only | → own landing |
| `/about`, `/terms`, `/privacy`, `/contact`, `/emergency`, `/feedback` | Anyone | — |
| `/home`, `/doctors`, `/shop`, `/appointments`, `/clinics`, `/hospitals`, `/pharmacies`, `/blood-bank`, `/cart`, `/checkout`, `/orders`, `/payments`, `/nearby`, `/my-reviews`, `/dashboard`, `/profile`, `/book*` | **Patient only** | → own landing |
| `/doctor*` | **Doctor only** | → `/doctor` |
| `/place*` | **Hospital, Clinic, Pharmacy** | → `/place` |
| `/admin*` | **Admin only** | → `/admin` |

---

## 17. Business Rules (Enforced on Backend)

- Payment verification is **manual only** — admin must verify transaction ref before marking `paid`.
- Appointment slots **never double-booked** — guarded by DB unique constraint + transactional `SELECT ... FOR UPDATE`.
- Only **doctor confirmation** generates a confirmation code.
- **All payment history preserved** — never overwrite verified records.
- **Appointment status ≠ Payment status** — separate concepts.
- **All rules enforced in Supabase** (RLS, triggers, CHECK constraints, SECURITY DEFINER functions) — client is presentation only.