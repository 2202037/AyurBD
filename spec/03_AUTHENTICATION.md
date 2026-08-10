# Part 03 — Authentication

**Phase 3.** Read `00_MASTER_PLAN.md` first. Rules R1–R8 apply. This part
hardens what exists; it does not rebuild it. Rule R3 (frozen repository
signatures) is binding on every method in `auth_repository.dart`.

---

## 1. Current architecture — what you are extending

Authentication is GoTrue (Supabase Auth) plus a mirror row in `public.users`.
Neither half is optional and neither is the source of truth for everything:

| Concern | Owner | Why |
|---|---|---|
| Password, session, refresh token | `auth.users` (GoTrue) | Never our code's business |
| `role`, name, phone, city, avatar | `public.users` | RLS policies read it via `auth.uid()` |
| Provider directory row | `doctors` / `clinics` / `hospitals` / `pharmacies` | Verification state lives per-provider |

`app/lib/features/auth/data/auth_repository.dart:100` calls `auth.signUp()`
with the profile columns as user metadata. It does **not** insert the
`public.users` row. The `handle_new_user()` trigger does, in the same
transaction as the auth user. That transactionality is the whole point: a
client-side insert after `signUp` can be abandoned mid-flight, leaving an auth
user with no profile — an account that can sign in but has no role, which
`_guard()` in `app/lib/app/router.dart:674` cannot place anywhere.

### 1.1 The role whitelist is a security boundary — the Dart one is not

`supabase/migrations/20260806000008_handle_new_user_role_whitelist.sql` fixed a
live privilege escalation. The original trigger did:

```sql
v_role := coalesce((new.raw_user_meta_data ->> 'role')::public.user_role, 'patient');
```

`user_role` is an enum that **contains `admin`**, and `raw_user_meta_data` is
entirely client-supplied. A direct GoTrue `signUp` with
`user_metadata={"role":"admin"}` produced a `public.users` row with
`role='admin'`, making `is_admin()` true and granting full RLS bypass. The
`aa_guard_users` trigger only blocks *changing* role afterwards; it never sees
the initial insert.

The fix whitelists five values in SQL:

```sql
v_role := case
  when (new.raw_user_meta_data ->> 'role') in
    ('patient', 'doctor', 'hospital', 'clinic', 'pharmacy')
  then (new.raw_user_meta_data ->> 'role')::public.user_role
  else 'patient'::public.user_role
end;
```

`AuthRepository._selfRegisterableRoles` (`auth_repository.dart:43`) holds the
same five names. **Keep both, but never treat the Dart set as protection.** It
is a UX affordance that stops a legitimate client sending a value the server
will silently clamp. Anyone can patch a Flutter binary; nobody can patch the
trigger.

> **Do not add `admin` to either list.** Admin accounts are created only by
> `supabase/admin_bootstrap.sql` — see §2.4.

### 1.2 The six roles

`UserRole` in `app/lib/models/app_user.dart:9` — `patient, doctor, clinic,
pharmacy, hospital, admin`. Note `UserRole.fromString` falls back to
`UserRole.patient`, never `admin`, on an unrecognised value
(`app_user.dart:22`). Preserve that: an unknown role must fail closed to the
least privileged role so a future schema change cannot widen access.

### 1.3 Why the keystore matters

`app/lib/core/storage/secure_store.dart:88` defines `SecureGotrueStorage`, a
custom `LocalStorage` installed in `main.dart` via
`Supabase.initialize(authOptions: FlutterAuthClientOptions(localStorage: ...))`.

supabase_flutter's default is `SharedPrefsLocalStorage`, which writes the
session blob — **including the refresh token** — to plain-text app storage. A
refresh token is a long-lived credential: it is readable on a rooted or
jailbroken device and, worse, it lands in filesystem backups that sync to a
desktop. Swapping in `flutter_secure_storage` moves it to
EncryptedSharedPreferences on Android and the Keychain on iOS.

Every method on `SecureGotrueStorage` swallows its own exception, and that is
deliberate. On web, flutter_secure_storage goes through browser crypto APIs
that throw on a non-secure origin and in hardened profiles. A throw there would
escape `Supabase.initialize` and abort bootstrap before the first frame — the
app would show nothing at all. Losing persistence degrades to "sign in again",
which the app already handles. **Do not "fix" those empty catch blocks.**

`SecureStore` (same file, line 25) separately caches the `AppUser` JSON so a
cold start can pick a shell without a network round trip. `clear()` also
deletes the retired `ayur.jwt` key from the PHP era, and deliberately does
*not* delete GoTrue's session key — `auth.signOut()` owns that.

---

## 2. Remove the demo credentials card — do this first

### 2.1 What to delete

**File:** `app/lib/features/auth/presentation/login_screen.dart`

Two edits, both mandatory:

1. **Delete the call site**, `login_screen.dart:183-187`:

```dart
                      const SizedBox(height: 8),
                      _DemoCredentials(onUseAdmin: () {
                        _email.text = 'admin@ayur.com';
                        _password.text = 'Ayur@1234';
                        setState(() => _obscure = false);
                      }),
```

2. **Delete the entire widget class**, `login_screen.dart:200-263` — the doc
   comment beginning `/// How to get an account, shown in-app...` through the
   closing brace of `class _DemoCredentials`. It renders a card titled
   "Demo admin access", prints `admin@ayur.com` / `Ayur@1234` in monospace, and
   offers a "Fill admin credentials" button.

After the deletion, `AppTheme` may become an unused import in this file. Check
and remove it if so; `flutter analyze` must stay clean (R8/§6.1 of the master
plan).

### 2.2 What replaces it

**Nothing, or one neutral line.** Preferred replacement, keeping the existing
`SizedBox` rhythm:

```dart
                      const SizedBox(height: 8),
                      Text(
                        l10n.loginAdminAccessHint, // "Administrator access is
                                                   //  issued by your organisation."
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
```

Do **not** replace it with a "demo mode" button, a role picker that
auto-signs-in, or a link to a seeded account. Any of those recreates the same
hole with a friendlier label.

### 2.3 Why this is not cosmetic

State it plainly, because the reasoning is the whole justification:

- The credentials are **real and live**. `supabase/admin_bootstrap.sql`
  promotes a genuine Supabase Auth user to `role = 'admin'` in `public.users`.
- `is_admin()` gates the admin RLS policies. An admin session is not "sees more
  UI" — it is read/write access to `users`, `payments`, `provider_payouts`,
  `audit_log` and every other table for **every** user of the platform.
- The card ships in the binary and renders on the *unauthenticated* login
  screen. Every person who installs the APK is handed full platform
  administration, with a one-tap button so they need not even type it.
- The APK is distributable. Publishing the app publishes the credential.
  Decompilation is not even required — the app displays it.

There is no threat model in which this is acceptable, including "it is only a
demo". A demo build and a release build are the same artefact here.

### 2.4 Rotate the password and re-home the bootstrap

Deleting the widget removes the *display*. The credential itself is still
compromised — it has been in the source tree and in every build produced from
it. Three follow-up actions, all required:

1. **Rotate.** In the Supabase Dashboard → Authentication → Users, set a new
   password for the admin account. `Ayur@1234` is burned; treat it as public.
2. **Consider a fresh address.** `admin@ayur.com` is now a known-valid
   username, which is half of a credential-stuffing attempt and an invitation
   to rate-limit probing. Creating a new admin identity and demoting the old
   row to `patient` is cheap.
3. **Bootstrap lives in SQL only.** `supabase/admin_bootstrap.sql` is already
   the correct mechanism — it creates no user, it only promotes an existing one:

```sql
update public.users u
set role = 'admin', updated_at = now()
from target t
where lower(u.email) = lower(t.email);
```

   Keep it that way. The password is set by a human in the Dashboard and is
   never written down in the repository. Add a header comment recording that
   no credential may appear in any Dart file, any spec file or any commit
   message.

### 2.5 The other credential leak in the same flow

`auth_repository.dart:53-58` contains a live diagnostic that runs on **every**
sign-in attempt, in release builds:

```dart
      print('[login-diag] email=<${email.trim()}> rawLen=${email.length} '
          'pwLen=${password.length} pw="${password.replaceAll(RegExp(r'.'), 'x')}" '
          'first="${password.codeUnits.take(8).toList()}"');
```

`password.codeUnits.take(8)` prints **the first eight characters of the
password as integers**. For `Ayur@1234` that is the entire password. On web
this goes to the browser console; on Android to logcat, readable by any app
holding `READ_LOGS` and by anyone with adb.

**Delete lines 53-58 and the `catch (e) { print(...); rethrow; }` block at
`auth_repository.dart:65-69` with them.** Replace the whole `try`/`catch` with
the plain call:

```dart
      final res = await _sb.auth.signInWithPassword(
        email: email.trim(),
        password: password,
      );
```

`SupabaseService.guard()` already maps `AuthException` onto `ApiException`, so
nothing downstream changes.

---

## 3. Registration — five roles

One repository method serves all five: `AuthRepository.register()`
(`auth_repository.dart:100`). Role-specific columns travel in the `extra` map,
built by `RegistrationFields` (`app/lib/features/auth/data/registration_fields.dart`)
so no screen assembles wire keys by hand. R3 freezes that signature.

### 3.1 Screens

| Role | Screen | `extra` builder |
|---|---|---|
| patient | `presentation/register_screen.dart` | none |
| doctor | `presentation/doctor_register_screen.dart` | `RegistrationFields.doctor()` (`registration_fields.dart:60`) |
| hospital | `presentation/hospital_register_screen.dart` | `RegistrationFields.hospital()` (`:94`) |
| clinic | `presentation/clinic_register_screen.dart` | `RegistrationFields.clinic()` (`:136`) |
| pharmacy | `presentation/pharmacy_register_screen.dart` | `RegistrationFields.pharmacy()` (`:170`) |

`presentation/role_picker_screen.dart` is the fork at `/signup`; `SignupRole`
(`registration_fields.dart:30`) supplies label + blurb for each card.

### 3.2 Required fields

Common to every role (validated client-side by `core/utils/validators.dart`,
enforced server-side by column constraints): `name`, `email`, `password`,
`password_confirm`, `phone`. Optional common: `address`, `city`, `gender`
(`male|female|other` — anything else is dropped by `handle_new_user()`).

| Role | Required beyond common | Notable optional |
|---|---|---|
| patient | — | `blood_group` |
| doctor | `bmdc_number`, `specialization`, `consultation_fee` | `qualifications`, `medical_school`, `graduation_year`, `experience_years`, `doctor_type`, `hospital_clinic_name`, `chamber_address`, `area`, `bio` |
| hospital | `registration_number`, `license_number` | `emergency_phone`, `hospital_type`, `established_year`, `website`, `total_beds`, `icu_beds`, `facilities`, `departments`, `open_24_hours`, `opening_time`, `closing_time` |
| clinic | `registration_number`, `license_number` | `clinic_type`, `services`, `specializations`, `available_days`, `opening_time`, `closing_time` |
| pharmacy | `license_number` (column is NOT NULL) | `drug_license_number`, `pharmacy_type`, `owner_name`, `pharmacist_name`, `pharmacist_license`, `whatsapp` |

Two conventions in `RegistrationFields` that must survive any edit:

- **Booleans go over as `'1'`/`'0'`**, not JSON `true` (`_flag`, used at
  `registration_fields.dart:123`). The server rule is `in:0,1`.
- **Empty keys are omitted, not sent blank.** A blank string fails the server's
  `int` and `time` rules where a missing key passes. `_compact()` enforces it.
- `opening_time`/`closing_time` are suppressed when `open_24_hours` is set
  (`registration_fields.dart:127`), so a profile never renders
  "Open 24 hours · 09:00–17:00".

### 3.3 Document upload — `provider-documents`

Today the document columns (`bmdc_certificate` and friends) are `varchar(255)`
**paths**, and no screen collects them (`registration_fields.dart:56`). Wire
them now:

1. Upload happens **after** the account exists, not during signup. RLS on the
   `provider-documents` bucket is keyed to `auth.uid()`, and during `signUp`
   there is no session yet on the email-confirmation path.
2. Object path convention: `<user_uuid>/<doc_kind>.<ext>` — enforced by the
   bucket policies in `supabase/storage_setup.sql`. Never invent a flat
   filename; the policy will reject it.
3. Store the returned **path**, not a URL. `SupabaseStorage` maps path → signed
   or public URL at read time; `AppConfig.resolveAsset` returns `''` for any
   non-absolute value, which is how legacy PHP-era paths degrade to a
   placeholder instead of a 404 (`app_config.dart`, `resolveAsset`).
4. The bucket is **private**. Documents are identity evidence; only the owner
   and an admin may read them. Use a signed URL with a short expiry in the
   admin verification screen.
5. Four states (R5) on the upload tile: idle, uploading with progress, uploaded
   with filename + replace action, failed with retry.

### 3.4 The verification lifecycle

`verification_status` lives on the four provider tables — `doctors`,
`clinics`, `hospitals`, `pharmacies` — **not** on `public.users`. This is why
`_profileColumns` (`auth_repository.dart:287`) deliberately omits `status`:
`public.users` has no such column, and asking PostgREST for it returns
400 "column users.status does not exist", which broke every sign-in until it
was removed. Do not add it back.

| State | Who sets it | What the provider sees |
|---|---|---|
| `pending` | `handle_new_user()` at signup | Workspace loads, banner: "Your account is under review. Patients cannot find you yet." Listings hidden. Profile editing allowed. |
| `verified` | Admin, via `admin_providers_screen.dart` | Full workspace. Notification "Account verified" fires (`providers_notify()`, `schema.sql:1865`). Listed publicly. |
| `rejected` | Admin, with `rejection_reason` | Banner shows the reason verbatim plus a "Contact support" action. Listings stay hidden. Editing + re-submission allowed. |

A `pending` provider must still be able to sign in and reach their own
workspace. Locking them out at the router would leave them with no way to
correct a rejected submission.

### 3.5 What to collect so an admin can verify a provider quickly

The brief asks which information makes a doctor easy to verify. The answer is
whatever an admin can check against an independent public register in under a
minute, without a phone call. Collect exactly that, and no more — every extra
field is PII you now have to protect.

| Role | Primary proof (checkable online) | Supporting documents | Where the admin checks it |
|---|---|---|---|
| doctor | **BMDC registration number** — `doctors.bmdc_number`, already required | BMDC certificate photo, NID front, MBBS/BDS degree certificate, chamber photo | bmdc.org.bd public register: number → name must match `users.name` |
| hospital | **Hospital registration number** (DGHS) — `hospitals.registration_number` | DGHS licence document, trade licence, NID of the authorised signatory | DGHS establishment list |
| clinic | **Clinic registration number** (DGHS) — `clinics.registration_number` | Same as hospital | DGHS establishment list |
| pharmacy | **Drug licence number** — `pharmacies.drug_license_number` | DGDA drug licence, trade licence, the dispensing pharmacist's Pharmacy Council registration (`pharmacist_license`) | DGDA licence list; Pharmacy Council register |
| blood bank | Managed by admin, not self-registered | — | Not applicable — see §3.6 |

Three rules for the fields themselves:

1. **The registration number is the primary key of the verification.** It is a
   short string an admin retypes into a public register. Validate its *shape*
   client-side (BMDC numbers are digits, typically 5–6) but never reject on
   shape alone — reject only in the admin screen, with a reason.
2. **NID is collected as an image, never as a number.** A stored NID number is a
   national identifier with no benefit to us; an image an admin looks at once and
   which lives in a private bucket is materially less dangerous. Do not add an
   `nid_number` column.
3. **The chamber photo is what catches the cheapest fraud** — a real BMDC number
   copied from a register, attached to someone who has no practice. It costs the
   applicant nothing honest and is hard to fake convincingly.

Store each document as a path in `provider-documents` under
`<user_uuid>/<kind>.<ext>` per Part 02 §4.3, with `kind` from a fixed set:
`bmdc_certificate`, `nid_front`, `degree`, `chamber_photo`, `drug_license`,
`trade_license`, `registration_certificate`, `pharmacist_license`.

### 3.6 Blood bank is not a self-registering role

`UserRole` (`app/lib/models/app_user.dart:9`) has six values — `patient, doctor,
clinic, pharmacy, hospital, admin`. **There is no `blood_bank` role**, and
`blood_banks` (`supabase/schema.sql:940`) has no `user_id` column: it is an
admin-managed directory of facilities, with `blood_banks_insert_admin` /
`_update_admin` / `_delete_admin` policies and no owner-scoped policy at all.

The brief lists blood bank among the roles to register. **Do not add the role.**
R2 forbids widening `user_role` casually, and the schema has no owner column to
hang it on. Register a blood bank as a `hospital` (which is what a blood bank
attached to a facility is) and let the admin link it to a `blood_banks` row, or
have the admin create the directory entry directly. Record this in
`IMPLEMENTATION_LOG.md` as a deliberate divergence from the brief with this
reasoning, so it is not "fixed" later by someone adding a seventh enum value.

---

## 4. Email verification and password reset

### 4.1 Email verification

Free, unlimited on the Supabase free tier, and already wired. `signUp()` sends
the confirmation mail; the user is not signed in until they click it, unless
"Confirm email" is disabled in the dashboard.

**Decide this explicitly and write it down.** With confirmation *on*, `signUp()`
returns a `User` with no `Session`, so `register()` cannot immediately load a
profile. The current `AuthRepository.register()` (`auth_repository.dart:100`)
handles the no-session case via `_profileFromMetadata()` (`:337`), which builds
an `AppUser` from the metadata it just sent rather than reading `public.users` —
because with no session, RLS would refuse the read. Preserve that path; it is
what makes the confirm-email flow work at all.

After `register()` returns with no session, route to a **"check your email"**
screen, not to the shell. It needs: the address the mail went to, a "resend"
action (`auth.resend(type: OtpType.signup, email: ...)`) rate-limited by GoTrue
itself, a "change address" action returning to the form, and an "open mail app"
action via `url_launcher`. Four states (R5) apply to the resend button.

### 4.2 Password reset — currently absent

**There is no reset method and no forgot-password screen in the repository.**
`grep -rn "resetPassword" app/lib` returns nothing. A user who forgets their
password today has no path back to their account. Adding this is required, not
optional.

R3 freezes existing signatures but explicitly permits new methods. Add two to
`AuthRepository`:

```dart
  /// Sends the reset mail. Deliberately reports success even for an address
  /// that has no account: telling a caller "no such user" turns this endpoint
  /// into a free account-enumeration oracle. GoTrue behaves the same way.
  Future<void> sendPasswordReset(String email) async {
    await SupabaseService.guard(() async {
      await _sb.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: AppConfig.passwordResetRedirect,
      );
    });
  }

  /// Completes the reset. Requires the recovery session GoTrue creates when
  /// the emailed link is opened — so this can only be called from the screen
  /// the link lands on.
  Future<void> completePasswordReset(String newPassword) async {
    await SupabaseService.guard(() async {
      await _sb.auth.updateUser(UserAttributes(password: newPassword));
    });
  }
```

`changePassword()` (`auth_repository.dart:225`) already exists for the
signed-in case and is unchanged.

### 4.3 Redirect configuration — the part that breaks on mobile

The reset link must land somewhere the app can read. This is the same
backend-versus-frontend-origin distinction that `CONFIGURATION_AUDIT.md` was
written about, and it has the same failure mode: a single configured URL cannot
serve both platforms.

Add to `app_config.dart`, beside `paymentReturnTarget` and following its shape:

```dart
  /// Where GoTrue should send a password-reset or email-confirmation link.
  ///
  /// Same split as [paymentReturnTarget]: on web the frontend origin plus a
  /// hash route; on mobile the `ayurbd://` custom scheme the manifest already
  /// registers for the Stripe return trip. Computed, not hard-coded, so the
  /// web dev server's random port is always right.
  static String get passwordResetRedirect =>
      kIsWeb ? '${Uri.base.origin}/#/reset-password' : 'ayurbd://reset-password';
```

Then, in the Supabase Dashboard under **Authentication → URL Configuration**, add
both to **Redirect URLs**. GoTrue validates `redirectTo` against that allowlist
and silently falls back to the Site URL if it does not match — which presents as
"the link works on web and does nothing on Android":

```
ayurbd://reset-password
ayurbd://payment-success
ayurbd://payment-cancelled
https://ayur.example.com/**
http://localhost:*/**
```

The mobile side needs no new plugin. `DeepLinkService`
(`app/lib/core/deep_links/deep_link_service.dart`) already bridges custom-scheme
intents into go_router locations, and `toRouterLocation()` (`:57`) strips the
scheme textually — so `ayurbd://reset-password#access_token=...` becomes
`/reset-password`. Two things to get right:

- `toRouterLocation` cuts at the **first `#`** and keeps what follows, which is
  correct for web hash routes but wrong for a GoTrue recovery link, where the
  token arrives *in* the fragment. Verify against a real link before trusting
  it, and if the fragment is being eaten, hand the raw URI to
  `supabase.auth.getSessionFromUrl()` before converting to a location.
- `supabase_flutter` picks up the recovery token automatically and emits
  `AuthChangeEvent.passwordRecovery`. Listen for it and push `/reset-password`;
  do not try to parse the token yourself.

New route and screen: `Routes.resetPassword = '/reset-password'`, added to
`_anonymousOnly` so a signed-out user reaches it — but see §5.3, because a
recovery session makes the user *technically* authenticated, and the guard as
written would bounce them straight to their landing screen.

---

## 5. Role-based routing

### 5.1 The complete table

`_landingFor()` is at `app/lib/app/router.dart:656`; the prefix lists are at
`:206` (`_anonymousOnly`), `:222` (`_openToAll`) and `:233` (`_patientOnly`).

| Role | Landing | Allowed prefixes | On violation |
|---|---|---|---|
| `patient` | `/home` | the whole patient shell (`/home`, `/doctors`, `/shop`, `/appointments`, `/profile`), everything in `_patientOnly`, `_openToAll`, `/account`, `/notifications`, `/blog`, `/payment-success`, `/payment-cancelled` | `/home` |
| `doctor` | `/doctor` | `/doctor/**`, `_openToAll`, `/account`, `/notifications`, `/blog`, payment returns | `/doctor` |
| `hospital` | `/place` | `/place/**`, same extras | `/place` |
| `clinic` | `/place` | identical to hospital | `/place` |
| `pharmacy` | `/place` | identical to hospital | `/place` |
| `admin` | `/admin` | `/admin/**`, same extras | `/admin` |
| signed out | `/login` | `_anonymousOnly` (`/splash`, `/login`, `/signup`, `/register/**`), `_openToAll` (`/about`, `/terms`, `/privacy`, `/contact`, `/emergency`, `/feedback`) | `/login` |

The three place roles share one workspace because the backend picks the table
from the caller's role — there is nothing role-specific to route to
(`router.dart:653`).

### 5.2 `_under()` — why plain `startsWith` is a bug

```dart
bool _under(String loc, String prefix) =>
    loc == prefix || loc.startsWith('$prefix/');
```

(`router.dart:670`.) The patient directory is `/doctors` and the doctor
workspace is `/doctor`. A plain prefix match would put **every patient browsing
the doctor list** into the provider guard and bounce them to `/doctor`, which
then bounces them back — a redirect loop on the app's most-used screen.
Requiring the next character to be `/` keeps the two apart. Any new prefix pair
that shares a stem inherits this hazard; always use `_under`.

### 5.3 The guard, ordered

`_guard()` (`router.dart:674`) evaluates in an order that is itself load-bearing.
Preserve it exactly, and add the two marked steps.

1. **Unresolved → splash.** `if (!auth.isResolved) return loc == Routes.splash ?
   null : Routes.splash;` Nothing renders while `restore()` reads the keystore,
   so a signed-in user never sees a flash of `/login` on cold start.
2. **Signed out:** `_openToAll` passes; `_anonymousOnly` (except splash) passes;
   everything else → `/login`.
3. **NEW — password recovery.** A recovery session makes `isAuthenticated` true,
   so step 4 would bounce the user off the reset screen to their dashboard,
   leaving them signed in with the password they cannot remember. Insert before
   step 4:
   ```dart
   // A recovery session exists only to set a new password. It is the one
   // authenticated state that belongs on an anonymous-only screen.
   if (auth.isRecovering && _under(loc, Routes.resetPassword)) return null;
   ```
   `isRecovering` is set by the `AuthChangeEvent.passwordRecovery` listener in
   `auth_controller.dart` and cleared on `completePasswordReset` or sign-out.
4. **Signed in on an auth screen → landing.** Checked *before* `_openToAll` so
   `/register/doctor` still bounces a signed-in user, while `/privacy` stays
   reachable from their profile.
5. `_openToAll` → allow.
6. **Non-patient on a `_patientOnly` prefix → landing.**
7. **Wrong workspace → landing** — one check per prefix (`/doctor`, `/place`,
   `/admin`).
8. Otherwise allow.

Step 6 deserves its comment at `router.dart:249`: `/dashboard` is in
`_patientOnly` **not** because it 403s for a provider but because it does not —
it returns a clean 200 with every count at zero, since a doctor's appointments
are keyed by `doctor_id`, never `patient_id`. An empty dashboard reads as "you
have no appointments", which is worse than an error.

### 5.4 `/account` and `/profile` — keep both

`Routes.profile = '/profile'` (`router.dart:109`) is a **branch of the patient
shell**; `Routes.account = '/account'` (`router.dart:122`) is the **same
`ProfileScreen` on the root navigator**. Do not merge them.

Changing your own password is not a patient feature — the underlying RPCs take
no role — so every role needs the screen. But `/profile` is a shell branch, so a
doctor opening it wears the patient tab bar, and four of those five tabs
redirect them straight back out. Two paths to one screen is the smaller cost:
patients keep branch history on the tab; every other role pushes `/account` over
their own workspace and gets a back button instead of someone else's navigation.

`/profile` is in `_patientOnly`; `/account` is in neither list, so it is
reachable by any signed-in role. That asymmetry is the entire mechanism.

### 5.5 The router refresh listener

`_AuthRefresh` (`router.dart:727`) notifies only when `status` or `role`
changes:

```dart
if (prev?.status != next.status || prev?.role != next.role) notifyListeners();
```

Notifying on every `busy` flip would re-run the redirect on each keystroke of
the login form. If you add a field the guard reads — `isRecovering` from §5.3 —
**add it to this comparison** or the guard will not re-evaluate when it changes.

---

## 6. Session lifecycle

| Moment | What must happen | Owner |
|---|---|---|
| Cold start | `bootstrap()` calls `AppConfig.assertValidBackendConfig()`, then `Supabase.initialize` with `SecureGotrueStorage`; `AuthController.restore()` reads the cached `AppUser` from `SecureStore`; router holds on `/splash` until `isResolved` | `main.dart`, `auth_controller.dart` |
| Cached user, valid session | Land on the role's screen with no network round trip; refresh the profile in the background and update if it changed | `auth_controller.dart` |
| Cached user, expired refresh token | GoTrue emits `signedOut`; clear the cache; route to `/login` with a localized "Your session expired, please sign in again" — **not** a raw error | `auth_controller.dart` |
| Token refresh | Automatic, in `supabase_flutter`. Never refresh by hand and never store the access token yourself | GoTrue |
| Mid-session expiry | A 401 surfaces as `ApiException.isUnauthorized`. One global listener signs out and routes to `/login`. Individual screens must not each handle it | `supabase_service.dart` + `auth_controller.dart` |
| Sign-out | See below | `auth_repository.logout()` |

**Sign-out must clear more than the session.** `logout()`
(`auth_repository.dart:250`) currently calls `auth.signOut()` and
`SecureStore.clear()`. Add, in this order:

1. `auth.signOut()` — GoTrue owns and deletes its own session key.
2. `SecureStore.clear()` — drops the cached `AppUser`, and the retired
   `ayur.jwt` key from the PHP era. It deliberately does **not** touch GoTrue's
   key; leave that alone.
3. **Invalidate the cart provider.** Otherwise the next user on the same device
   inherits the previous user's cart in memory until a refetch. The rows are
   RLS-scoped so nothing leaks from the server — but the UI showing them is a
   privacy incident regardless.
4. **Cancel scheduled local notifications** —
   `flutter_local_notifications.cancelAll()`. Appointment reminders are
   scheduled on-device with no user check at fire time; without this, a signed-out
   phone still buzzes with the previous user's appointment. See Part 05 §5.
5. **Invalidate every Riverpod provider holding user data.** Prefer disposing a
   parent scope over remembering a list that will drift.

Sign-out must be idempotent and must never fail visibly. If `signOut()` throws
because the device is offline, still do steps 2–5 and still route to `/login` —
a user who cannot sign out is a worse outcome than a server-side session that
expires on its own.

---

## 7. Security checklist

- **No secret in the binary (R6).** Only the publishable/anon key.
  `assertValidBackendConfig()` (`app_config.dart:56`) throws at startup if the
  key starts with `sb_secret_` or contains `service_role`. Do not weaken that
  check, and do not add a `--dart-define` escape hatch for it.
- **RLS is the boundary; Dart is a hint.** `_selfRegisterableRoles`
  (`auth_repository.dart:43`) is a UX affordance. The SQL whitelist in
  `handle_new_user()` is the control. Anyone can patch a Flutter binary; nobody
  can patch the trigger.
- **Never log a credential.** Delete `auth_repository.dart:53-58` per §2.5. The
  general rule: never log passwords or fragments of them, access or refresh
  tokens, OTPs, reset links, full `raw_user_meta_data`, or the body of a Stripe
  event. Logging an email address is acceptable; logging its password length is
  not (it narrows a brute force).
- **`verboseHttp` stays off by default** (`app_config.dart:139`). It puts access
  tokens and profile data into the browser console.
- **Errors must not enumerate accounts.** "No account with that email" is an
  enumeration oracle. Both sign-in failure modes get one message: "Email or
  password is incorrect." Password reset always reports success (§4.2).
- **Do not trust `role` from the client, ever** — not in a query filter, not in
  a request body, not in user metadata after signup. Read it from
  `public.users`.
- **Rate limiting on auth endpoints is GoTrue's, and it is on** for the free
  tier. Part 02 §6 covers the data endpoints, which have none.
- **Rotate anything that has ever been in the repository.** §2.4.

### 7.1 SMS OTP is out of scope — and the seam for it

Master plan §2 Q3: every SMS gateway charges per message and Bangladeshi
providers require a business licence, so there is no free option. Phone numbers
are collected and validated against `01[3-9]XXXXXXXX`, stored, and **labelled
unverified in the UI** — an unverified number presented as verified is worse
than no verification.

Add the seam so a provider drops in later without a schema change:

```dart
/// Phone verification. No implementation ships — see master plan §2 Q3.
///
/// The interface exists so the call sites are written now and an SMS provider
/// becomes one binding change rather than a UI rewrite. A no-op that returns
/// `false` is the honest answer to "is this number verified", and every caller
/// must be written to accept that answer as normal, not as an error.
abstract interface class PhoneVerifier {
  /// Whether verification is available at all. False for [NoopPhoneVerifier],
  /// so the UI hides the "Verify" button instead of offering a dead one.
  bool get isAvailable;

  /// Sends a code. Throws [UnsupportedError] when [isAvailable] is false —
  /// callers must check first.
  Future<void> sendCode(String phone);

  /// Returns true when the code matched.
  Future<bool> verifyCode(String phone, String code);
}

class NoopPhoneVerifier implements PhoneVerifier {
  const NoopPhoneVerifier();

  @override
  bool get isAvailable => false;

  @override
  Future<void> sendCode(String phone) =>
      throw UnsupportedError('Phone verification is not configured.');

  @override
  Future<bool> verifyCode(String phone, String code) async => false;
}

final phoneVerifierProvider =
    Provider<PhoneVerifier>((ref) => const NoopPhoneVerifier());
```

Part 01 adds `users.phone_verified boolean not null default false`. Nothing sets
it to true yet, and no feature may gate on it being true.

For provider accounts, identity is proved by admin review of uploaded documents
(§3.5) — a stronger check than an SMS OTP, and what the brief actually asks for.

---

## 8. Every auth string through `AppLocalizations`

R4. Part 06 establishes the mechanism; this section lists what Part 03 owes it.
Phase 5 precedes all UI work precisely so these are written bilingual on their
first pass.

**Screens:** login, role picker, five registration forms, verify-email, forgot
password, reset password, profile. Every label, hint, button, app-bar title,
snackbar and dialog.

**Validation messages** are the ones most often missed, because they live in
`core/utils/validators.dart` rather than in a screen. Each needs both locales:

| Rule | English | বাংলা |
|---|---|---|
| Required | This field is required | এই ঘরটি পূরণ করতে হবে |
| Email format | Enter a valid email address | সঠিক ইমেইল ঠিকানা লিখুন |
| Password length | Password must be at least 8 characters | পাসওয়ার্ড কমপক্ষে ৮ অক্ষরের হতে হবে |
| Password mismatch | Passwords do not match | পাসওয়ার্ড দুটি মিলছে না |
| Phone format | Enter a valid Bangladeshi mobile number (01XXXXXXXXX) | সঠিক বাংলাদেশি মোবাইল নম্বর লিখুন (০১XXXXXXXXX) |
| BMDC required | BMDC registration number is required | বিএমডিসি রেজিস্ট্রেশন নম্বর প্রয়োজন |
| Licence required | Licence number is required | লাইসেন্স নম্বর প্রয়োজন |
| Fee non-negative | Consultation fee cannot be negative | পরামর্শ ফি ঋণাত্মক হতে পারে না |

Note the Bangla row uses **Bangla numerals** (৮, ০১) per master plan §7.
`validators.dart` returns a message today; it must return a *key* the widget
resolves against the current locale, because a validator has no `BuildContext`.
Pass `AppLocalizations` into the validator, or return an enum the form maps.
Decide once, in Part 06, and apply it here uniformly.

**Server messages need the same treatment.** `ApiException.message` frequently
carries English written in SQL. Localize by the machine-readable code — the
`P0001` `DETAIL` field, or `PaymentFailure` — never by matching the English
text, which breaks the moment a message is reworded.

**Also localize:** the verification-lifecycle banners in §3.4, the four
document-upload states in §3.3, the session-expired message in §6, and the
neutral admin-access line that replaces the demo card in §2.2.




