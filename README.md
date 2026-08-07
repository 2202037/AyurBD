# AYUR — Flutter client for your existing AYUR database

A Flutter presentation-layer twin of the AYUR Ayurvedic healthcare website. It talks to
**your existing `ayur_db`** — the same database your PHP site already runs on. Flutter never
touches MySQL; every read and write goes through the PHP API in `backend/api/v1`.

```
AyurBD/
├── app/                 Flutter client — 58 Dart files
│   ├── lib/
│   └── pubspec.yaml
├── backend/             PHP 8 API v1 — no Composer, drops into XAMPP htdocs
│   ├── api/v1/          front controller + 8 feature route files
│   ├── config/
│   └── helpers/
├── database/
│   ├── migration_v1.sql              ← the ONLY file you run. Additive only.
│   └── _reference_only_DO_NOT_RUN.sql   early guess at your schema. Never execute.
└── README.md
```

---

## Your database is the source of truth

This build was reconciled against the real dump you supplied (`ayur_db`, MariaDB 10.4.32,
13 tables, 117 users, 101 doctors). **Nothing here recreates it.**

`database/_reference_only_DO_NOT_RUN.sql` is the schema this project *guessed* before your
real dump arrived. It has been neutered and renamed because it began with
`DROP DATABASE IF EXISTS ayur_db`. It is kept only so you can diff the guesses against
reality. Do not execute it, ever.

The one file you do run is `database/migration_v1.sql`, and it is additive only: seven
`CREATE TABLE IF NOT EXISTS`, some `ADD COLUMN IF NOT EXISTS`, and guarded seed inserts. No
`DROP`, no `TRUNCATE`, no `MODIFY` of an existing column, no change to any existing enum,
index, trigger or foreign key. Your website keeps working exactly as it does today. See
[What the migration adds](#what-the-migration-adds) for the line-by-line list.

**Scope built:** the patient journey end to end — auth, directory, appointments + payment,
blood bank, pharmacy cart/checkout. Doctor, clinic, pharmacy, hospital and admin logins land
on an honest stub dashboard that names what is not built yet.

**Deliberately excluded:** Firebase push and Google Maps. Both need API keys and per-platform
setup that would block `flutter run` on a fresh machine. There is also **no distance sorting
or "2.3 km away" anywhere** — no table in your database stores latitude or longitude, so a
distance would have to be invented. "Directions" hands off to whatever maps app the device
has, searching by name and address text, which needs no key.

---

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| XAMPP | PHP **8.0+**, the MariaDB your `ayur_db` already lives in | Apache with `mod_rewrite` (on by default) |
| Flutter SDK | **3.19+** (Dart `>=3.3.0 <4.0.0`) | `flutter doctor` clean for your target |
| An emulator or device | Android emulator, iOS simulator, or Chrome | |

No Composer, and no PHP extensions beyond `pdo_mysql`, `json` and `mbstring` — all enabled in
XAMPP by default.

---

## Step 1 — Put the backend where Apache can serve it

Copy the whole `AyurBD` folder into your XAMPP web root:

- **Windows:** `C:\xampp\htdocs\AyurBD`
- **macOS:** `/Applications/XAMPP/htdocs/AyurBD`
- **Linux:** `/opt/lampp/htdocs/AyurBD`

The path matters — the Flutter default base URL is `.../AyurBD/backend/api/v1`. If you name
the folder something else, override the base URL in Step 6.

Start **Apache** and **MySQL** from the XAMPP control panel.

## Step 2 — Back up `ayur_db`, then run the one migration

**Back up first.** phpMyAdmin → select `ayur_db` in the left sidebar → **Export** → **Go**.
This takes ten seconds and is the only thing standing between you and a bad afternoon.

Then, still in phpMyAdmin:

1. Select **`ayur_db`** in the left sidebar. *(Do this first. The script deliberately contains
   no `CREATE DATABASE`, so importing it without a database selected just errors.)*
2. **Import** tab → Choose file → `database/migration_v1.sql` → **Go**.

Or from the command line:

```bash
# Windows — note --port 3307, see Step 3
C:\xampp\mysql\bin\mysql.exe -u root -P 3307 ayur_db < C:\xampp\htdocs\AyurBD\database\migration_v1.sql
```

Re-running it is safe — every statement is guarded by `IF NOT EXISTS`.

Verify it landed. The bottom of `migration_v1.sql` has the queries commented out; the short
version is:

```sql
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='ayur_db';  -- was 13, now 21
SELECT COUNT(*) FROM users;                                                   -- still 117
SELECT COUNT(*) FROM doctors;                                                 -- still 101
SELECT COUNT(*) FROM doctors WHERE available_days IS NOT NULL;                -- 100
```

If `users` or `doctors` changed count, something other than this script ran. Restore the
backup.

## Step 3 — Check the database connection settings

`backend/config/config.php` is already pointed at your database:

```php
DB_HOST  127.0.0.1     DB_PORT  3307
DB_NAME  ayur_db       DB_USER  root       DB_PASS  ''
```

**Port 3307, not the usual 3306.** That is taken from the header of the dump you provided
(`Host: 127.0.0.1:3307`), which is where your site's MySQL is actually listening. If you moved
it since, change `DB_PORT` — a wrong port shows up as `[2002] Connection refused` on `/health`.

Every value reads an environment variable first (`AYUR_DB_HOST`, `AYUR_DB_PORT`, `AYUR_DB_PASS`,
`AYUR_JWT_SECRET`, …), so you can override without editing the file. **If your MySQL root has a
password, set `DB_PASS`** — that is the most common cause of a 500 on first run.

Leave `JWT_SECRET` alone for local development. Change it before anything real; see
[Before you deploy](#before-you-deploy).

## Step 4 — Prove the API works before touching Flutter

Open in a browser:

```
http://localhost/AyurBD/backend/api/v1/health
```

You want exactly this shape:

```json
{
  "success": true,
  "message": "AYUR API is running.",
  "data": { "status": "ok", "api": "ayur-v1", "time": "...", "db": "connected", "php": "8.2.12" }
}
```

`"db": "connected"` is the meaningful part — the front controller opens the connection *before*
answering, so this cannot report healthy while `ayur_db` is unreachable.

Then try a real read, which proves the app is looking at *your* data and not a fixture:

```
http://localhost/AyurBD/backend/api/v1/directory/doctors?limit=5
```

You should see real names out of your `doctors` table, and `meta.total` around **100** — the
count of rows that are both `status='active'` and `verification_status='verified'`. (You have
101 doctors; one is inactive and is correctly hidden.)

If you get HTML, a 404, or a PHP error instead, fix it here. Debugging through a Flutter error
dialog is much harder. See [Troubleshooting](#troubleshooting).

## Step 5 — Generate the Flutter platform folders, then install packages

`app/` ships only `lib/` and `pubspec.yaml` — no `android/`, `ios/`, `web/` or `windows/`
directories. Those are machine- and package-name-specific, so generate them:

```bash
cd app
flutter create . --org com.ayur --project-name ayur
flutter pub get
```

`flutter create .` in an existing directory **adds** the missing platform folders and leaves
`lib/` and `pubspec.yaml` untouched. If it offers to overwrite `pubspec.yaml`, decline — the
dependency list there is deliberate. This step is not optional; without it `flutter run` fails
with "no target device / missing platform".

## Step 6 — Point the app at your server

This is the step that decides whether the app can reach XAMPP at all. `10.0.2.2` is the Android
emulator's alias for the host machine's `localhost`; nothing else uses it.

| Running on | `AYUR_BASE_URL` | Why |
| --- | --- | --- |
| **Android emulator** | *(default — nothing to pass)* | `http://10.0.2.2/AyurBD/backend/api/v1` |
| **iOS simulator** | `http://localhost/AyurBD/backend/api/v1` | shares the Mac's network stack |
| **Physical phone (same Wi-Fi)** | `http://192.168.x.x/AyurBD/backend/api/v1` | your PC's LAN IP — `ipconfig` / `ifconfig` |
| **Desktop (Windows/macOS/Linux)** | `http://localhost/AyurBD/backend/api/v1` | |
| **Chrome (web)** | `http://localhost/AyurBD/backend/api/v1` | CORS is already `*` in dev |

These are **Apache** addresses (port 80). The 3307 from Step 3 is MySQL's port and is only ever
used by PHP — it never appears in a URL the app calls.

Set it with `--dart-define`, passing **both** URLs together — `AYUR_ASSET_URL` is the site root
that images resolve against, and it is one path segment shorter:

```bash
flutter run \
  --dart-define=AYUR_BASE_URL=http://192.168.1.20/AyurBD/backend/api/v1 \
  --dart-define=AYUR_ASSET_URL=http://192.168.1.20/AyurBD
```

**Physical device check:** before running the app, open
`http://192.168.1.20/AyurBD/backend/api/v1/health` *in the phone's own browser*. If that doesn't
return JSON, the app can't reach it either — usually a firewall blocking port 80 (on Windows,
allow `httpd.exe` through Windows Defender Firewall), or Apache listening only on `127.0.0.1`.

## Step 7 — Run

```bash
flutter devices     # confirm your target is listed
flutter run
```

The app opens on a splash screen while it reads the keystore for a saved session, then routes to
`/login` or to the role's home.

---

## Logging in

Use **the accounts already in your database** — the app authenticates against your `users`
table, so anything that works on the website works here.

Two accounts in your dump were verified against their bcrypt hashes and are known-good for a
first run:

| Email | Role | Password |
| --- | --- | --- |
| `patient@test.com` | patient | `password` |
| `doctor@test.com` | doctor | `password` |

Sign in as the patient — that is the role whose journey is fully built. The doctor account lands
on the stub dashboard.

Registration through the app always creates a **patient**. The role field is hard-coded client
side and the server's validator rejects `admin` outright — a user-selectable role would be
privilege escalation.

## What you will actually see — and what will look empty

Your database has real data in some tables and none in others, so parts of the app are populated
and parts show an empty state. **Empty is correct here, not a bug:**

| Section | What you'll see | Why |
| --- | --- | --- |
| **Doctors** | ~100 real doctors, searchable, filterable by specialization and city (Dhaka 72, Chattogram 16, …) | `doctors` has 101 rows |
| **Book appointment** | Slots every 30 min, 5–9 pm, Sat–Thu | the migration gave each active doctor that default schedule — edit it per doctor whenever you like |
| **Appointments / Payments** | Empty until you book | `appointments` and `payments` are empty tables |
| **Blood bank stock** | 4 banks with real stock | `blood_banks` has 4 rows |
| **Blood donors** | 10 real donors | `blood_donors` has 10 rows |
| **Blood requests** | Empty board until someone posts | `blood_requests` is empty |
| **Clinics / Hospitals / Pharmacies** | **Empty** | all three tables are empty in your database |
| **Shop** | **Empty** | products attach to a pharmacy, and there are no pharmacies yet |
| **Blog** | 2 starter articles | seeded by the migration |
| **Reviews** | 7 real reviews on the doctors that have them | `reviews` has 7 rows |

The clinic/hospital/pharmacy directories fill in the moment those tables get rows — no code
change needed. Note that every public listing is gated on `status = 'active' AND
verification_status = 'verified'`, so a row you add stays invisible until you verify it. That is
intentional: a second client must not be a way to bypass your verification step.

## What the migration adds

Ten statements, all additive: two `ALTER TABLE` and eight `CREATE TABLE IF NOT EXISTS`. To see them
for yourself: `grep -n "^ALTER\|^CREATE TABLE" database/migration_v1.sql`.

**Six columns across two existing tables:**

| Table | Columns added | Why |
| --- | --- | --- |
| `doctors` | `available_days`, `available_from`, `available_to`, `slot_minutes` | your table has no availability data, so the booking calendar had no slots to offer. All nullable/defaulted, so your site's existing `INSERT INTO doctors` still works. |
| `users` | `city`, `blood_group` | edited by the app's profile screen; `blood_group` prefills a blood request. Both nullable; your site ignores them. |

There is exactly one `UPDATE` in the whole file, and it writes only to those four new `doctors`
columns, only where they are still `NULL`, only for `status='active'` rows. Those columns did not
exist a second earlier, so it cannot overwrite anything your website stored. It affects 100 rows.

**Eight new tables**, none of which anything existing points at, so they are inert until the app
uses them: `pharmacy_products`, `cart`, `orders`, `order_items`, `notifications`, `device_tokens`,
`blogs`, and `app_audit_log` (kept separate from your `audit_log` so the app's writes can never
be confused with your triggers'). That is why the table count in Step 2 goes from 13 to 21.

**Two things deliberately NOT done:**

- **No `users.is_active`.** Your site has no concept of a deactivated user, and adding one would
  let the app lock people out via a flag your admin panel cannot see or clear. The app's login
  does not check it and no model carries it.
- **No `UNIQUE(doctor_id, date, time)` on `appointments`.** You chose the transactional guard
  instead: `appointments_book()` opens a transaction and does a `SELECT ... FOR UPDATE` on that
  triple before inserting, so two simultaneous taps are serialised and the second gets a 409.
  The trade-off, and the exact `ALTER` if you change your mind, is written out at the bottom of
  `migration_v1.sql` — the short version is that a unique index counts *cancelled* rows too, so a
  once-cancelled 10:00 slot could never be rebooked, by the app or by your website.

---

## Troubleshooting

**`/health` returns the phpMyAdmin page or a directory listing**
The folder isn't at `htdocs/AyurBD`, or you typed the URL without `/backend/api/v1`.

**`/health` returns 404 but the same URL with `index.php` in it works**
`mod_rewrite` is off or `AllowOverride` is `None`. In `httpd.conf`, uncomment
`LoadModule rewrite_module modules/mod_rewrite.so`, set `AllowOverride All` for the `htdocs`
directory, restart Apache.

**`"db": "error"` or `[2002] Connection refused`**
Wrong port. Your MySQL is on **3307**, not 3306 — check `DB_PORT` in `backend/config/config.php`
against the port shown in the XAMPP control panel.

**`[1045] Access denied for user 'root'@'localhost'`**
Set `DB_PASS` in `backend/config/config.php`.

**`[1049] Unknown database 'ayur_db'`**
The API is connected to a different MySQL instance than the one holding your data — again,
almost always the port.

**`[1054] Unknown column 'available_days'` / `'city'` / `Table 'ayur_db.cart' doesn't exist`**
Step 2 didn't run, or it ran against the wrong database. Re-import `migration_v1.sql` with
`ayur_db` selected in the sidebar.

**Doctors list is empty but `SELECT COUNT(*) FROM doctors` says 101**
Every listing requires `status='active'` **and** `verification_status='verified'`. Check both.

**Every authenticated request 401s while login works**
Apache is stripping the `Authorization` header. `backend/api/v1/.htaccess` already forwards it
via `RewriteCond %{HTTP:Authorization}`; if you're on Nginx or PHP-FPM, replicate that.

**`SocketException` / "Connection refused" in the app, but the browser is fine**
Wrong base URL for your target. Re-read the table in Step 6 — `localhost` inside an Android
emulator means the emulator itself, not your PC.

**Android: "Cleartext HTTP traffic not permitted"**
Android 9+ blocks plain HTTP. For local development add
`android:usesCleartextTraffic="true"` inside `<application>` in
`android/app/src/main/AndroidManifest.xml`. Remove it before shipping; production must be HTTPS.

**"Too many attempts. Please try again in a few minutes." (429)**
Working as designed — auth endpoints allow 10 attempts per 5 minutes per IP. Wait it out, or
delete the `ayur_rl_*.json` files in your system temp directory.

**A field you cleared in Profile came back**
Also by design. The server's validator treats an empty string as *absent*, so a blank value can't
erase an existing one. Enter a new value instead.

**`flutter run` fails on a missing platform folder**
Step 5 wasn't run, or was run outside `app/`. `cd app` first.

---

## Notes for whoever edits this next

**A wrong key name fails silently, in both directions.** The PHP validator drops unrecognised
request keys without complaining, and a response key the Dart model doesn't read just arrives as
`null`. Neither raises an error. Both bugs happened during this build — a `city` the user typed
vanished with no error, and `doctor_public()` sent `qualification` while the model read
`qualifications`, so every doctor's qualifications came back blank. When you add a field, check
the column name, the shaper key, and the model key against each other.

**Request keys are not response column names, and the mismatch is intentional in a few places:**
booking accepts `date`/`time`/`reason` but returns `appointment_date`/`appointment_time`/`notes`;
payment accepts `transaction_ref` but returns `transaction_id`; products expose `price` while cart
lines rename it `unit_price`. Don't "fix" those into agreement.

**Things that look like bugs and are not:** `PaymentMethod` and `PaymentMethodOption` are two
separate enums with the same values on purpose — they are two independent whitelists, and merging
them would let a change to one silently send unaccepted values to the other. `Product.isActive`
looks like the `AppUser.isActive` that was deleted, but it is backed by a real column.

**The app must never set `appointments.payment_status = 'paid'`.** It records a submitted payment
as `pending`; only your admin panel marks it paid, after verifying the transaction id.

---

## What was and wasn't verified

Honesty about this matters more than a green checkmark, so:

**Verified statically** (the build environment had no Flutter, Dart, PHP or MySQL, and no
network — so nothing here was ever run against your database):

- Every table and column the PHP touches exists in **your** dump. The reconciliation pass removed
  everything that didn't: distance sorting, `has_blood_bank`, place image columns,
  `users.is_active`, and `reviews` of type `product`.
- All 46 Flutter endpoint constants (38 static strings + 8 path-builder methods) resolve to a real
  route in `index.php` (48 route entries covering 46 distinct paths, with `/auth/profile` and
  `/reviews` each taking two methods), and no route lacks a constant.
- Every model field maps to a key the API actually emits — this caught roughly a dozen mismatches
  that would each have produced a silent null or a hard 400.
- All router imports resolve, all widget classes are declared, all parameterized screen
  constructors match their call sites.
- Zero SQL driver imports anywhere in `lib/` — Flutter reaches MySQL only through PHP.
- No deprecated `withOpacity` or `surfaceVariant`; braces and parens balance in all 58 Dart files
  and all 15 PHP files.
- The two test logins were checked by verifying `password` against the bcrypt hashes in your dump.

**Not verified:**

- **The code has never been compiled or executed, and `migration_v1.sql` has never been run.**
  `flutter analyze` may still surface something; your first `flutter run` is the real test, and
  your backup is the reason a surprise in the migration is recoverable.
- **The `Icons.*` names could not be checked against the Flutter SDK** — no network to fetch the
  list, no SDK to compile against. A bad icon name is a compile error, not a runtime crash, so
  `flutter analyze` names it immediately. (`Icons.stethoscope_outlined` was already caught this
  way.)
- No automated tests were written — that was outside the agreed scope.

---

## Before you deploy

The defaults here are development defaults, and several are actively unsafe in public:

1. **`JWT_SECRET`** in `backend/config/config.php` is the literal string
   `change-me-in-production-a-long-random-string`. Replace it with 32+ random bytes, ideally via
   the `AYUR_JWT_SECRET` environment variable rather than in the file.
2. **`APP_DEBUG = true`** echoes SQL error text to the client. Set it to `false`.
3. **`CORS_ALLOWED_ORIGINS = ['*']`**. A native Flutter app sends no `Origin` header, so
   restricting this to your real web origins breaks nothing.
4. **The `password` test accounts.** `patient@test.com` and `doctor@test.com` are in your live
   database with a one-word password. Change or remove them.
5. **HTTPS.** JWTs over plain HTTP on a LAN is fine for development and unacceptable in
   production.

The security properties this build maintains, worth preserving in any edit: the JWT lives only in
`flutter_secure_storage` (never SharedPreferences); a 401 anywhere clears storage and routes to
`/login` as a normal logout rather than an error; every query uses PDO prepared statements with
emulation off; column names in updates come from a server-side whitelist, never from request keys;
sort fields come from a fixed internal map, never interpolated from user input; ownership checks
(appointments, orders, blood requests, notifications) are enforced server-side from the token's
`sub` claim, never from a client-supplied id; and blog `content` renders as plain text, never as
HTML.
