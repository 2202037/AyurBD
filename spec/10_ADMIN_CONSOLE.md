# Part 10 — Admin Console

Phase 11 of the master plan. Read `spec/00_MASTER_PLAN.md` first; it wins on any
conflict. Part 12 must already be applied — several sections here depend on
constraints it installs, and one section (§3) is the *only* safe way to expose
deletion in this app.

> The user's brief for this part: the admin *"controls everything of the app"*;
> *"keep trigger type things if anything deletes that info will be stored"*;
> audit *"categorised by time, category, date"*; and verify / approve / reject.

Each of the eleven features below is written as a vertical slice per R7:
route → screen file → provider → repository method → table and RLS → EN+BN
strings → four states (R5) → acceptance test.

---

## 0. What already exists — do not rebuild it

Verified by inspection on 2026-08-10. This is the most complete module in the
repo; the work here is mostly *filling gaps*, not writing screens.

| Piece | Path | State |
|---|---|---|
| 11 routes | `app/lib/app/router.dart:173-183` | exists |
| Route guard | `app/lib/app/router.dart:717` | exists, insufficient alone — §1 |
| 13 screens + 1 widget | `app/lib/features/admin/presentation/` | exist |
| Riverpod wiring | `app/lib/features/admin/presentation/admin_controllers.dart` | exists |
| Repository, 24 public methods | `app/lib/features/admin/data/admin_repository.dart` | exists |
| `is_admin()` | `supabase/schema.sql:2019` | exists |
| `current_user_role()` | `supabase/schema.sql:2009` | exists |
| Admin RLS policies | `supabase/rls_policies.sql`, ~40 `is_admin()` policies | exist |
| Column guard trigger | `supabase/rls_policies.sql:102` | exists |
| Row-level audit trigger | `supabase/schema.sql:1253` | exists, 18 tables |
| Dashboard aggregate | `supabase/schema.sql:2926` (view) + `rls_policies.sql:1018` (gate fn) | exists |
| Bootstrap script | `supabase/admin_bootstrap.sql` | exists |

### The real gaps this part closes

| # | Gap | Section |
|---|---|---|
| 1 | Route guard is the only *visible* gate; no DB guard on `users.role` for the console path | §1 |
| 2 | Blood banks have no verification queue (no `verification_status` column) | §2 |
| 3 | **No soft-delete convention.** `deleteUser()` issues a real `DELETE` | §3 |
| 4 | Audit UI cannot filter by date, has no export, has no retention plan | §4 |
| 5 | Reviews/blogs have no *reported* flag — only `status` | §5 |
| 6 | No category-level commission, no admin UI for either level | §6 |
| 7 | Payment queue shows a reference string, not evidence | §7 |
| 8 | No delete-account request table | §8 |
| 9 | Dashboard has no revenue/commission time series | §9 |
| 10 | No broadcast RPC (Part 05 §2.2 event 25 is `new`) | §10 |
| 11 | Hotlines have RLS and no screen at all | §11 |

### Two facts that constrain everything below

**PostgREST cannot `GROUP BY`.** Every aggregate an admin screen shows must come
from a view or a `SECURITY DEFINER` function. The repository already documents
this at `admin_repository.dart:32-36`, where the audit filter dropdowns fall back
to sampling the most recent 500 rows because no view exists over
`app_audit_log`. §4 and §9 replace those samples with real aggregates.

**`admin_dashboard_stats` is a view *and* a function, and the difference matters.**
`supabase/schema.sql:2926` creates the view; `supabase/rls_policies.sql:1016`
revokes client `SELECT` on it and `:1018` wraps it in a same-named
`SECURITY DEFINER` function that raises `42501` for non-admins. A view cannot
carry an RLS policy in Postgres, so the function is the only gate. The
repository correctly calls the *function*
(`admin_repository.dart:120`, `_sb.rpc('admin_dashboard_stats')`). Follow that
pattern for every new aggregate in §9: view for the SQL, function for the gate,
`revoke` on the view.

---

## 1. The admin access model

### 1.1 Three gates, not one

The router already redirects a non-admin away from `/admin*`
(`app/lib/app/router.dart:717`):

```dart
  if (_under(loc, Routes.adminHome) && role != UserRole.admin) return landing;
```

That line is correct and must stay. It is also, on its own, worth nothing as
security. `role` there comes from `AuthState`, which is hydrated from the cached
`AppUser` written to secure storage (`app_user.dart:124`). It decides *what the
UI draws*. It does not touch the wire. Anyone with a valid JWT can `curl` the
REST endpoint directly and never execute a line of Dart.

Three independent gates are required, and each answers a different question:

| Gate | Where | Question it answers | Failure mode if it were alone |
|---|---|---|---|
| Router guard | `router.dart:717` | Should I draw this screen? | Bypassed by any REST client |
| RLS policies | `rls_policies.sql`, `is_admin()` | May this session read/write this row? | Cannot see *which column* changed |
| Column guard trigger | `rls_policies.sql:102` | Did a non-admin change a privileged column? | — |

The middle and last gates are the load-bearing ones. `is_admin()`
(`supabase/schema.sql:2019`) is `SECURITY DEFINER` and `STABLE`: definer so a
policy can read `public.users` without recursing into that table's own policy,
stable so the planner evaluates it once per statement rather than once per row.
Both properties are deliberate. Do not make it `VOLATILE` and do not inline it.

### 1.2 Why RLS alone cannot stop privilege escalation

Cross-reference **Part 12 §12** for the full treatment; it is the most severe
item in that document. The one-paragraph version, because it decides the shape
of this console:

An RLS policy is a boolean over a row. `WITH CHECK` sees the *new* row only, so
it can express "the row must be yours" but never "this column must not have
changed". A patient legitimately updates her own `users` row to edit her
profile, so `users_update_own` must permit it — and that same policy permits
`PATCH /rest/v1/users?id=eq.<her-uuid>` with body `{"role":"admin"}`. Every
policy is satisfied. One second later she is an admin, and `is_admin()` opens
every `*_select_admin` policy on the platform to her.

Column-level immutability is a `BEFORE UPDATE` trigger's job, because a trigger
is the only construct that sees `OLD` and `NEW` together.
`guard_admin_only_columns()` at `supabase/rls_policies.sql:102` is that trigger,
wired at `:154` onwards over `role, email, is_active` on `users` and seven
columns each on the four provider tables. **Verify it exists before building
anything in this part; if it does not, stop and apply Part 12 first.**

Two properties of it are easy to break and worth restating:

- The `aa_` trigger-name prefix is not decoration. Postgres fires same-event
  `BEFORE` row triggers in alphabetical order by name, and these must run before
  any guard that acts on the new values. Keep the prefix on anything added.
- The guard receives its column list via `TG_ARGV`. A trigger created with an
  empty argument list compiles, installs, and enforces nothing. Part 12 §12
  gives the query that proves the argument list is non-empty; run it.

**The rule for this part:** every admin action below writes through a policy
gated on `is_admin()`. No admin action is authorised by the router. If you add
an admin capability and cannot name the `is_admin()` policy that permits it, the
capability is not finished.

### 1.3 A dedicated login path

There is no separate admin login *screen* and there must not be one — Part 03 §2
deletes the "Demo admin access" card that shipped live credentials on the
unauthenticated login screen of a distributable APK. Reintroducing a
`/admin/login` route with any pre-filled hint, quick-fill button or seeded
account recreates exactly that hole with a friendlier label.

What "dedicated path" means here is a *post-authentication* fork, which already
exists at `router.dart:660`:

```dart
      UserRole.admin => Routes.adminHome,
```

One login form, one credential store, one session. The role resolved from
`public.users` after sign-in decides the landing route. An admin who signs in
lands on `/admin`; a patient who types `/admin` into a deep link is bounced to
`/patient/dashboard` by `:717` and would in any case receive empty lists and
`42501`s from the database.

### 1.4 Creating the first admin

`supabase/admin_bootstrap.sql` exists and is already the correct mechanism. It
creates no user — it only promotes one that a human created in the Supabase
Dashboard:

```sql
update public.users u
set role = 'admin', updated_at = now()
from target t
where lower(u.email) = lower(t.email);
```

The properties that make it correct, each of which is a rule:

1. **No password anywhere in the repository.** The password is set by a human in
   Dashboard → Authentication → Users. Cross-ref Part 03 §2.4, which additionally
   requires rotating the burned `Ayur@1234` credential and considering a fresh
   address, because `admin@ayur.com` is now a known-valid username.
2. **Run manually, never shipped.** This file must not be added to
   `supabase/migrations/`. A migration runs on every environment including CI and
   any future restore; promotion to admin is a deliberate human act on one
   database. Keep it at `supabase/` root, where it is inert.
3. **It cannot be executed from the app.** It requires SQL Editor access, which
   requires the project owner's dashboard session. No client key reaches it.

Add a header comment to that file recording rule 1 explicitly — that no
credential may appear in any Dart file, any spec file or any commit message.

There is deliberately **no in-app "promote user to admin" button**, even for an
existing admin. `guard_admin_only_columns` blocks `users.role` for non-admins
and returns early for admins, so an admin *could* write it; the reason not to
build the UI is that admin creation is the one action with no recovery path if
misused, and forcing it through the SQL Editor guarantees a second human moment
of thought. If a second admin is needed, run the bootstrap script again with a
different email.

### 1.5 Acceptance test

```bash
# 1. Router gate: sign in as a patient, deep-link to /admin -> lands on
#    /patient/dashboard, no error view.
# 2. RLS gate: with that patient's JWT,
curl -s "$SUPABASE_URL/rest/v1/audit_log?select=*&limit=1" \
  -H "apikey: $ANON" -H "Authorization: Bearer $PATIENT_JWT"
# expect: []   (empty, not 403 -- SELECT policies filter rows)

# 3. Escalation gate: same JWT,
curl -s -X PATCH "$SUPABASE_URL/rest/v1/users?id=eq.$PATIENT_UUID" \
  -H "apikey: $ANON" -H "Authorization: Bearer $PATIENT_JWT" \
  -H "Content-Type: application/json" -d '{"role":"admin"}'
# expect: 42501, 'column users.role may only be changed by an administrator'
# A 200 here means guard_admin_only_columns is missing or has an empty TG_ARGV.
```

---

## 2. Verification queues

> Brief: *verify / approve / reject*. This is the queue that unblocks every new
> provider on the platform, so it is the first screen to get right.

### 2.1 The slice

| Layer | Value |
|---|---|
| Route | `Routes.adminProviders` = `/admin/providers` (`router.dart:175`, registered `:411`) |
| Screen | `app/lib/features/admin/presentation/admin_providers_screen.dart` (690 lines) |
| Providers | `adminProviderTypeProvider`, `adminProviderVerificationProvider`, `adminProviderStatusProvider`, `adminProviderSearchProvider`, `adminProvidersProvider` (`admin_controllers.dart:54-80`) |
| Repository | `AdminRepository.providers()` (`admin_repository.dart:240`), `moderateProvider()` (`:315`) |
| Tables | `doctors`, `hospitals`, `clinics`, `pharmacies` |
| RLS | `*_select_admin`, `*_update_admin` on each, all `using (public.is_admin())` |
| Storage | private bucket `provider-documents`, signed via `_signDocument()` (`admin_repository.dart:1136`) |

The type filter defaults to `doctors` and the verification filter defaults to
`pending` (`admin_controllers.dart:59`) — an admin opens this screen to clear a
queue, not to browse everyone already verified. Keep that default.

### 2.2 The `verification_status` enum, and the four states an applicant sees

`create type verification_status as enum ('pending', 'verified', 'rejected');`
(`supabase/schema.sql:167`). Three values, not four — there is no
`resubmitted`. A rejected provider who fixes their document is moved back to
`pending` by the same `moderateProvider` call path.

Two columns move together and must not be confused. `verification_status` is the
credential decision; `status` (`provider_status`: `pending|active|inactive`,
`schema.sql:171`) is the listing decision. The public directory gates on **both**,
which is why `moderateProvider` sets `status: 'active'` alongside
`verification_status: 'verified'` (`admin_repository.dart:325-328`) — a
verified-but-inactive provider would stay invisible and the admin would have no
idea why.

What the applicant sees, per state. This table is the acceptance criterion for
§2, and every row is already reachable through `providers_notify()`
(`supabase/schema.sql:1856`):

| `verification_status` | `status` | Provider's dashboard | Notification fired | Publicly listed | Can be booked |
|---|---|---|---|---|---|
| `pending` | `pending` | "Verification in progress. We are checking your documents." | none (insert-time state) | no | no |
| `verified` | `active` | Normal workspace | "Account verified" → `/dashboard` | yes | yes |
| `rejected` | `pending` | "Not approved" + the reason verbatim + re-upload action | "Verification rejected. Reason: {reason}" | no | no |
| `verified` | `inactive` | "Your listing is paused" | "Account deactivated" | no | no |

Cross-ref **Part 05 §2.2 events 15–17**, which are marked `exists`. Do not write
new notification inserts for these — `providers_notify` already covers them, and
a client-side insert into `notifications` is refused outright (Part 12 §19).

The rejection reason is stored on the provider row's `rejection_reason` column
and appended to the notification body by `providers_notify`
(`schema.sql:1868-1870`). The screen already requires at least 5 characters
(`admin_providers_screen.dart:171`) even though the server permits an empty one.
Keep that client-side minimum — a rejection with no reason generates a support
ticket, which costs more than the dialog.

### 2.3 The document viewer

The `provider-documents` bucket is **private**. `getPublicUrl` on it returns a
URL that 400s, so signing is the only way an admin sees the credential they are
being asked to check. `_signDocument()` (`admin_repository.dart:1136`) does this
with a 300-second expiry — longer than the default minute because an admin reads
a page of these before deciding.

Its error behaviour is a deliberate design choice worth preserving: it returns
`''` rather than throwing when the object is missing or the path is a PHP-era
relative one (`p.startsWith('uploads/')`). One stale `license_document` must not
empty the entire moderation queue, which is the one screen that unblocks every
new provider.

**The gap to close:** the current screen passes the signed URL to `AvatarCircle`
(`admin_providers_screen.dart:521`), which renders it as a 40 px thumbnail. A
BMDC certificate cannot be read at 40 px. Build a real viewer:

```dart
/// Full-screen viewer for a signed `provider-documents` URL.
///
/// The URL is already time-limited (300 s, admin_repository.dart:1136). It is
/// NOT cached to disk: a cached credential document would outlive its signature
/// and sit in the app's sandbox as an unprotected copy of someone's medical
/// registration.
class CredentialViewer extends StatelessWidget {
  const CredentialViewer({super.key, required this.url, required this.label});

  final String url;   // '' when unsigned/missing -- caller must handle
  final String label;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (url.isEmpty) {
      return EmptyView(
        icon: Icons.description_outlined,
        title: l10n.adminDocMissingTitle,
        message: l10n.adminDocMissingBody,
      );
    }
    return InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Image.network(
        url,
        fit: BoxFit.contain,
        loadingBuilder: (c, child, p) =>
            p == null ? child : const LoadingView(),
        // A 400 here almost always means the signature expired while the
        // admin was reading. Say that, rather than showing a broken icon.
        errorBuilder: (c, _, __) => ErrorView(
          message: l10n.adminDocExpired,
          onRetry: () => Navigator.of(c).pop(true),  // true = refetch page
        ),
      ),
    );
  }
}
```

Open it from a full-width "View document" button on the card, not from the
avatar. PDFs: the bucket accepts them, and `Image.network` cannot render one.
Detect a `.pdf` path suffix before signing and route those to the system viewer
via `url_launcher` with `LaunchMode.externalApplication`; adding a PDF rendering
dependency for a screen used a handful of times a day is not justified.

### 2.4 Blood banks have no verification queue — and should not get one

`blood_banks` has no `user_id`, no `verification_status` and no
`commission_percentage`. It is **reference data an admin maintains**, not a
provider account that applies and is approved — which is why
`admin_blood_banks_screen.dart` is a CRUD editor and `saveBloodBank()`
(`admin_repository.dart:676`) does a plain insert/update.

The brief lists blood banks alongside the other queues. Adding
`verification_status` to `blood_banks` would mean adding an owning user, a
registration flow and a document upload — a new provider role, not a queue. That
is out of scope for this part and is not what the data models.

**What to build instead:** treat the existing `status` (`active_status`:
`active|inactive`) as the review gate, and require an admin to set `active`
explicitly on create. Cross-ref Part 09 for the blood bank inventory screens.
Note this deviation from the brief in `IMPLEMENTATION_LOG.md` per R8, with this
paragraph as the reason.

### 2.5 Strings

| Key | EN | BN |
|---|---|---|
| `adminVerifyTitle` | Verification queue | যাচাইকরণ তালিকা |
| `adminVerifyApprove` | Approve | অনুমোদন |
| `adminVerifyReject` | Reject | প্রত্যাখ্যান |
| `adminRejectReasonLabel` | Why is this rejected? | কেন প্রত্যাখ্যান করা হচ্ছে? |
| `adminRejectReasonHint` | e.g. the uploaded licence document is unreadable | যেমন আপলোড করা লাইসেন্স নথি পড়া যাচ্ছে না |
| `adminRejectReasonTooShort` | Please give a reason of at least 5 characters. | অন্তত ৫ অক্ষরের একটি কারণ লিখুন। |
| `adminDocView` | View document | নথি দেখুন |
| `adminDocMissingTitle` | No document uploaded | কোনো নথি আপলোড করা হয়নি |
| `adminDocMissingBody` | This applicant has not uploaded a credential. Reject with a reason asking for it. | আবেদনকারী কোনো সনদ আপলোড করেননি। কারণ উল্লেখ করে প্রত্যাখ্যান করুন। |
| `adminDocExpired` | The document link expired. Reopen the queue to view it again. | নথির লিঙ্কের মেয়াদ শেষ। আবার দেখতে তালিকাটি পুনরায় খুলুন। |

### 2.6 Four states

| State | Rendering |
|---|---|
| Loading | `LoadingView()` — skeleton cards, not a bare spinner; the page is a list |
| Empty | `EmptyView` "Queue clear. Nothing waiting for verification." / "তালিকা খালি। যাচাইয়ের অপেক্ষায় কিছু নেই।" |
| Error | `ErrorView` with retry calling `controller.reload()` |
| Content | Paged cards, each with document button, approve, reject |

### 2.7 Acceptance test

1. Register a doctor, upload a BMDC certificate. Row lands `pending`/`pending`.
2. Admin opens `/admin/providers`. The row appears without changing any filter.
3. Tap "View document" — the certificate renders legibly and zooms.
4. Reject with a 10-character reason. Assert: `verification_status='rejected'`,
   `rejection_reason` stored, one `notifications` row for the doctor's `user_id`
   whose body ends with that reason, and the doctor is absent from
   `/doctors`.
5. Re-approve. Assert `verification_status='verified'` **and** `status='active'`,
   a second notification, and the doctor now visible and bookable.
6. Attempt step 5 as the doctor themselves via REST — expect `42501` from
   `aa_guard_doctors`.

---

## 3. Soft delete and retention

> Brief: *"keep trigger type things if anything deletes that info will be stored"*.
> This section is the answer to that sentence, and it is the highest-priority
> item in this part.

### 3.1 Why this is urgent, not tidy

Cross-reference **Part 12 §17**, which found that fourteen tables `CASCADE` from
`public.users`, including `appointments` (`schema.sql:549`), `payments`
(`:598`), `orders` (`:766`) and `provider_payouts` (`:866`). And
`admin_users_screen.dart:88` wires a delete button straight to it:

```dart
      await ref.read(adminRepositoryProvider).deleteUser(user.id);
```

`deleteUser()` (`admin_repository.dart:223`) issues a real
`delete().eq('id', userId)`. One click on the admin users list currently destroys
every payment that user ever made, every payout owed to them, and every
appointment they attended — irreversibly, with no record of what was lost. Unlike
every other integrity problem in this codebase, this one does not produce a
rejected write. It produces silent data loss that no constraint will ever
surface.

Part 12 §17 supplies the `ON DELETE RESTRICT` migration that stops the
destruction at the FK level. **Apply that first.** This section supplies the
positive half: the operation an admin actually performs instead.

### 3.2 The convention

Three columns, the same three names, on every table where an admin may remove
something. Uniformity is the point — one RLS predicate, one restore path, one
mental model, and a generic trigger that needs no per-table knowledge.

| Column | Type | Meaning |
|---|---|---|
| `deleted_at` | `timestamptz` | NULL = live. Non-NULL = soft-deleted, and when. |
| `deleted_by` | `uuid references public.users(id) on delete set null` | Which admin. `set null` so deleting the *admin* later does not erase the fact of the deletion. |
| `deletion_reason` | `text` | Why. Required by the UI, not by the DB — see below. |

`deleted_at` is a timestamp, not a boolean, because "when" is free to store and
answers the retention question in §3.6 without a second column.

**Do not rename `is_deleted`.** `doctors`, `hospitals`, `clinics` and
`pharmacies` already carry `is_deleted boolean not null default false`
(`schema.sql:342`, `:410`, `:464`, `:519`), it is read by `available_slots` and
`appointments_book` (`schema.sql:2091`, `:2218`, `:2647`, `:3291`), and R2
forbids renames. Add the three columns *beside* it and keep them consistent with
a trigger, so both the old server-side gates and the new console keep working.

### 3.3 The DDL

```sql
-- =====================================================================
-- 20260810000030_soft_delete.sql
--
-- Part 10 §3. The brief: "if anything deletes that info will be stored".
--
-- Depends on 20260810000021_user_deletion_integrity.sql (Part 12 §17).
-- Apply that first: without RESTRICT on the money tables, a hard delete
-- is still reachable from the Supabase dashboard and this is cosmetic.
-- =====================================================================

-- 1. Columns. Nine tables an admin can remove things from.
do $$
declare
  t text;
begin
  foreach t in array array[
    'users', 'doctors', 'hospitals', 'clinics', 'pharmacies',
    'blood_banks', 'blogs', 'reviews', 'emergency_hotlines'
  ] loop
    execute format($f$
      alter table public.%I
        add column if not exists deleted_at      timestamptz,
        add column if not exists deleted_by      uuid
          references public.users (id) on delete set null,
        add column if not exists deletion_reason text
    $f$, t);

    -- Partial: the index only ever serves "where deleted_at is null",
    -- which is every ordinary read, so indexing the deleted rows would
    -- be dead weight.
    execute format(
      'create index if not exists idx_%1$s_live on public.%1$I (id) '
      'where deleted_at is null', t);
  end loop;
end $$;

-- 2. Keep the legacy is_deleted flag in step with deleted_at.
--
-- Both directions, because both are written: the console writes
-- deleted_at, while setProviderDeleted() (admin_repository.dart:376)
-- still writes is_deleted and ~4 server functions still read it.
-- Without this, a provider soft-deleted through the new path would stay
-- bookable, because appointments_book checks is_deleted.
create or replace function public.sync_is_deleted()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.is_deleted := (new.deleted_at is not null);
    return new;
  end if;

  if new.deleted_at is distinct from old.deleted_at then
    new.is_deleted := (new.deleted_at is not null);
  elsif new.is_deleted is distinct from old.is_deleted then
    -- Written through the legacy path. Synthesise the audit columns so a
    -- row deleted the old way is still attributable.
    if new.is_deleted then
      new.deleted_at := coalesce(new.deleted_at, now());
      new.deleted_by := coalesce(new.deleted_by, auth.uid());
    else
      new.deleted_at      := null;
      new.deleted_by      := null;
      new.deletion_reason := null;
    end if;
  end if;
  return new;
end;
$$;

-- aa_ prefix: BEFORE row triggers fire in alphabetical order and this must
-- run before any guard that inspects the new values. See Part 12 §12.
create trigger aa_sync_is_deleted
  before insert or update on public.doctors
  for each row execute function public.sync_is_deleted();
create trigger aa_sync_is_deleted
  before insert or update on public.hospitals
  for each row execute function public.sync_is_deleted();
create trigger aa_sync_is_deleted
  before insert or update on public.clinics
  for each row execute function public.sync_is_deleted();
create trigger aa_sync_is_deleted
  before insert or update on public.pharmacies
  for each row execute function public.sync_is_deleted();
```

### 3.4 The soft-delete RPC, and the hard-delete refusal

Soft delete is not a plain `UPDATE`, because three columns must move together
and `deletion_reason` must be enforced. A `SECURITY DEFINER` function is the
only place that enforcement cannot be skipped.

```sql
-- ---------------------------------------------------------------------
-- admin_soft_delete / admin_restore
--
-- p_table is validated against a whitelist rather than interpolated:
-- format(%I) quotes an identifier but does not stop 'auth.users' being
-- named, and this function runs as its owner.
-- ---------------------------------------------------------------------
create or replace function public.admin_soft_delete(
  p_table  text,
  p_id     text,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows int;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  if p_table not in ('users','doctors','hospitals','clinics','pharmacies',
                     'blood_banks','blogs','reviews','emergency_hotlines') then
    raise exception 'table % is not soft-deletable', p_table
      using errcode = '22023';
  end if;

  -- A deletion with no stated reason is the thing the brief asks us to
  -- prevent. Enforced here, not only in the dialog.
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception 'a deletion reason of at least 5 characters is required'
      using errcode = '23514', detail = 'deletion_reason_required';
  end if;

  -- id is text because users.id is a uuid and every other table is
  -- bigint identity. The ::text cast on the left compares both without a
  -- per-table branch; the partial index on (id) still serves the lookup
  -- for the bigint tables, and users has a uuid PK index.
  execute format($f$
    update public.%I
       set deleted_at      = now(),
           deleted_by      = auth.uid(),
           deletion_reason = btrim($1)
     where id::text = $2
       and deleted_at is null
  $f$, p_table) using p_reason, p_id;

  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'row not found, or already deleted'
      using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.admin_restore(p_table text, p_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows int;
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  if p_table not in ('users','doctors','hospitals','clinics','pharmacies',
                     'blood_banks','blogs','reviews','emergency_hotlines') then
    raise exception 'table % is not soft-deletable', p_table
      using errcode = '22023';
  end if;

  -- deletion_reason is NOT cleared. "This was deleted on 3 March for
  -- fraud and restored on 5 March" is exactly the history the brief
  -- wants kept; blanking it would erase the reason the row was ever
  -- suspect. Only deleted_at is cleared, which is what makes it live.
  execute format($f$
    update public.%I set deleted_at = null
     where id::text = $1 and deleted_at is not null
  $f$, p_table) using p_id;

  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'row not found, or not deleted' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.admin_soft_delete(text,text,text) from public, anon;
revoke all on function public.admin_restore(text,text)          from public, anon;
grant execute on function public.admin_soft_delete(text,text,text) to authenticated;
grant execute on function public.admin_restore(text,text)          to authenticated;
```

**Hard delete refuses to destroy financial records.** Part 12 §17's `RESTRICT`
constraints make a `users` delete fail with a raw FK violation; this trigger
turns that into an answer an admin can act on, and extends the refusal to rows
that have no FK pointing at them but still constitute evidence:

```sql
create or replace function public.guard_financial_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_blockers text[] := '{}';
  v_n        bigint;
begin
  if tg_table_name = 'users' then
    select count(*) into v_n from public.payments where user_id = old.id;
    if v_n > 0 then v_blockers := v_blockers || format('%s payment(s)', v_n); end if;

    select count(*) into v_n from public.provider_payouts
     where provider_user_id = old.id;
    if v_n > 0 then v_blockers := v_blockers || format('%s payout(s)', v_n); end if;

    select count(*) into v_n from public.appointments where patient_id = old.id;
    if v_n > 0 then v_blockers := v_blockers || format('%s appointment(s)', v_n); end if;

    select count(*) into v_n from public.orders where user_id = old.id;
    if v_n > 0 then v_blockers := v_blockers || format('%s order(s)', v_n); end if;
  end if;

  if array_length(v_blockers, 1) > 0 then
    raise exception
      'this account has % and cannot be deleted; soft-delete it instead',
      array_to_string(v_blockers, ', ')
      using errcode = '23503', detail = 'financial_history_exists';
  end if;
  return old;
end;
$$;

create trigger zz_guard_financial_delete
  before delete on public.users
  for each row execute function public.guard_financial_delete();
```

The `zz_` prefix is the mirror of `aa_`: this must run *after* any other
`BEFORE DELETE` logic, since it is the final veto.

**A trigger alone is not the fix, and this is the trap Part 12 §17 names.** A
guard trigger can be dropped, disabled with `ALTER TABLE ... DISABLE TRIGGER`,
or bypassed by a cascade originating in `auth.users` — which the Supabase
dashboard exposes as a button. The `RESTRICT` FKs are what make the destruction
structurally impossible; this trigger only makes the refusal comprehensible.
Ship both.

### 3.5 RLS — ordinary users never see soft-deleted rows, admins do

The policies must change, or soft delete is a decoration: the row is still
returned by every existing `*_select_*` policy. Full policy text belongs in
Part 02 §3; the *shape* is what matters here, and it is one predicate added to
each non-admin SELECT policy:

```sql
-- Pattern, applied to every non-admin SELECT policy on the nine tables.
drop policy if exists blogs_select_published on public.blogs;
create policy blogs_select_published
  on public.blogs for select to anon, authenticated
  using (status = 'published' and deleted_at is null);

-- The admin policy is left alone: it already says using (public.is_admin()),
-- with no deleted_at clause, which is exactly right. An admin who cannot see
-- what they deleted cannot restore it.
```

Two consequences to design around rather than discover:

- **Provider tables need no policy change**, because their existing directory
  filters already gate on `is_deleted` and `aa_sync_is_deleted` keeps that flag
  true. Verify this rather than assume it; if any policy or function reads the
  provider tables *without* an `is_deleted` filter, add `deleted_at is null`
  there.
- **`users` is the awkward one.** A soft-deleted patient's *name* must still
  render on the appointments their doctor attended, or the doctor's history
  becomes a list of blanks. Do not add `deleted_at is null` to
  `users_select_*`. Instead treat a soft-deleted user as suspended: the ban path
  in §8 (`is_active = false`) is what blocks them from acting, and `deleted_at`
  records that removal was requested. The two flags are independent on purpose.

### 3.6 Retention: what a hard delete is still for

Soft delete is not infinite retention, and the free tier is 500 MB. The policy:

| Class | Soft-delete window | Then | Why |
|---|---|---|---|
| Financial (`payments`, `provider_payouts`, `orders`, `order_items`) | never soft-deleted; never hard-deleted | retained indefinitely | The platform's evidence money moved. Part 12 §17. |
| Clinical (`appointments`) | never deleted, only `cancelled` | retained indefinitely | Referenced by payments; a booking history is a care record. |
| Accounts (`users`) | indefinite while any financial row references them | purge only if zero references | See §8's delete-account request flow. |
| Content (`blogs`, `reviews`) | 180 days | eligible for hard delete | No financial or clinical value. |
| Reference (`blood_banks`, `emergency_hotlines`) | 180 days | eligible for hard delete | Recreatable. |

"Eligible" is not "automatic". Do not schedule a purge job in this phase. Write
the query, leave it manual, and record in `IMPLEMENTATION_LOG.md` that it is
unscheduled:

```sql
-- Purge candidates. Run by hand; review the list before deleting anything.
select 'blogs' as tbl, id::text, deleted_at, deletion_reason
  from public.blogs
 where deleted_at < now() - interval '180 days'
union all
select 'reviews', id::text, deleted_at, deletion_reason
  from public.reviews
 where deleted_at < now() - interval '180 days'
 order by deleted_at;
```

A hard delete of one of these still writes a full `audit_log` row with
`old_values` populated (§4), so even the purge is recoverable from the audit
trail. That is the brief's sentence satisfied at the last possible layer.

### 3.7 The slice

| Layer | Value |
|---|---|
| Route | reuses each list screen; no dedicated route |
| Screen | add a "Deleted" filter chip to `admin_users_screen.dart`, `admin_providers_screen.dart`, `admin_blogs_screen.dart`, `admin_blood_banks_screen.dart` |
| Provider | new `adminShowDeletedProvider = StateProvider<bool>((ref) => false)` in `admin_controllers.dart`, watched by each list controller so toggling resets the page |
| Repository | two new methods beside the old ones — R3 forbids changing existing signatures |
| RPC | `admin_soft_delete`, `admin_restore` |

```dart
  /// Soft-deletes any row on a whitelisted table. [reason] is mandatory and
  /// enforced server-side (23514 / deletion_reason_required), so the dialog's
  /// validator is a convenience, not the guarantee.
  ///
  /// [id] is a String because `users.id` is a uuid while every other table is
  /// bigint identity; the RPC compares `id::text`.
  Future<void> softDelete({
    required String table,
    required String id,
    required String reason,
  }) async {
    return SupabaseService.guard(() async {
      await _sb.rpc<void>('admin_soft_delete', params: {
        'p_table': table,
        'p_id': id,
        'p_reason': reason.trim(),
      });
    });
  }

  Future<void> restore({required String table, required String id}) async {
    return SupabaseService.guard(() async {
      await _sb.rpc<void>('admin_restore', params: {
        'p_table': table,
        'p_id': id,
      });
    });
  }
```

`deleteUser()` (`admin_repository.dart:223`) stays — R3 freezes its signature —
but its **body is rewritten** to call `admin_soft_delete` with the reason the
dialog collected. Rewriting internals is explicitly permitted. Update its
doc comment, which currently describes a cascade that will no longer happen.
The existing self-delete refusal at `:226-231` stays.

### 3.8 Strings

| Key | EN | BN |
|---|---|---|
| `adminDeleteTitle` | Delete this record? | এই রেকর্ডটি মুছবেন? |
| `adminDeleteExplain` | It is hidden from users but kept, with your name and reason, and can be restored. | এটি ব্যবহারকারীদের কাছ থেকে লুকানো হবে কিন্তু আপনার নাম ও কারণসহ সংরক্ষিত থাকবে এবং পুনরুদ্ধার করা যাবে। |
| `adminDeleteReasonLabel` | Reason for deletion | মুছে ফেলার কারণ |
| `adminDeleteReasonTooShort` | Give a reason of at least 5 characters. | অন্তত ৫ অক্ষরের কারণ লিখুন। |
| `adminRestore` | Restore | পুনরুদ্ধার |
| `adminShowDeleted` | Show deleted | মুছে ফেলা দেখান |
| `adminDeletedBadge` | Deleted {date} by {admin} | {admin} কর্তৃক {date} তারিখে মুছে ফেলা |
| `adminDeleteBlockedFinancial` | This account has {items} and cannot be removed. It has been hidden instead. | এই অ্যাকাউন্টে {items} রয়েছে, তাই সরানো যাবে না। পরিবর্তে এটি লুকানো হয়েছে। |

### 3.9 Acceptance test

1. Soft-delete a blog. Assert it vanishes from `/blog` for an anonymous session,
   still appears for the admin with a "Deleted" badge, and
   `deleted_at`/`deleted_by`/`deletion_reason` are all populated.
2. Restore it. Assert it reappears publicly and `deletion_reason` is **still
   set** — the history is not erased.
3. Call `admin_soft_delete` with a 3-character reason. Expect `23514`.
4. Call it as a patient. Expect `42501`.
5. Soft-delete a doctor through the new path. Assert `is_deleted` flipped true
   via `aa_sync_is_deleted`, and that `appointments_book` now refuses that
   doctor — proving the legacy server-side gates still fire.
6. `delete from public.users where id = '<uuid with one payment>'`. Expect
   `23503` with `detail = 'financial_history_exists'`, not a cascade.
7. Drop `zz_guard_financial_delete` and repeat step 6. Expect the FK
   `RESTRICT` from Part 12 §17 to refuse it anyway. **If it succeeds, Part 12
   §17 was not applied and the whole of §3 is decorative.**

---

## 4. The audit system

> Brief: audit *"categorised by time, category, date"*.

### 4.1 First, reconcile the two tables — there are two, and they are not redundant

The repo has `audit_log` **and** `app_audit_log`. Before writing a line, know
which is which, because the console currently reads the wrong one for the wrong
purpose.

| | `audit_log` (`schema.sql:1180`) | `app_audit_log` (`schema.sql:1204`) |
|---|---|---|
| Written by | **triggers only** — `audit_row_change()` (`schema.sql:1253`), `SECURITY DEFINER` | **the Flutter app**, over REST |
| Grants | `select` to `authenticated`; **no INSERT to anyone** (`schema.sql:3389-3391`) | `select, insert` to `authenticated` (`schema.sql:3387`) |
| RLS | `audit_log_select_admin` — admin only (`rls_policies.sql:991`) | `app_audit_select_own`, `app_audit_select_admin`, `app_audit_insert_self` (`:995-1005`) |
| Granularity | one row per changed row, per table | one row per user-meaningful event |
| Records | `table_name`, `record_id`, `action_type` (`INSERT/UPDATE/DELETE`), `old_values` jsonb, `new_values` jsonb, `changed_fields` | `user_id`, `action` (`login`, `logout`, `change_password`, …), `entity`, `entity_id`, `details` jsonb |
| Actor | **not recorded** — see §4.2 | `user_id`, and it is the whole point |
| Coverage | 18 tables (`schema.sql:2987-3004`) | wherever the app remembers to call it |
| Tamper-proof | yes — no client INSERT, no UPDATE, no DELETE policy anywhere | partially — a user may insert rows *attributed to themselves* |

In one sentence each:

- **`audit_log` is the forensic record of data.** It answers "what did this row
  look like before, and what is it now". It cannot be forged from a client
  because no client can write it.
- **`app_audit_log` is the behavioural record of people.** It answers "who signed
  in, when, from where". It is app-written, therefore only as trustworthy as the
  app, and `app_audit_insert_self` deliberately caps the damage by refusing rows
  attributed to anyone else.

**Neither replaces the other, and neither is to be duplicated.** Do not create a
third audit table. Do not migrate one into the other. The brief's "if anything
deletes that info will be stored" is already satisfied by `audit_log` for the 18
covered tables — a `DELETE` writes a row with `old_values` holding the entire
vanished row as jsonb.

**The console currently mixes them up.** `AdminRepository.auditLog()`
(`admin_repository.dart:834`) and the recent-activity list on the dashboard
(`:123-128`) both read `app_audit_log` only. The screen at
`admin_audit_screen.dart` is therefore a *login history*, not an audit trail —
`audit_log`, the table that holds the before/after data the brief cares about, is
never displayed anywhere in the app. The dashboard even counts it
(`db_audit_logs`, `schema.sql:2953`) and then shows nothing behind that number.

### 4.2 The one real gap: `audit_log` does not record who

`audit_row_change()` captures table, record id, operation, old, new, changed
fields and timestamp. It does **not** capture the actor. The table has
`ip_address inet` and `user_agent text` columns (`schema.sql:1191-1192`) and the
trigger never populates either — they are MySQL-era leftovers.

So the audit trail can say "`doctors` row 42 changed `verification_status` from
`pending` to `verified` at 14:02" and cannot say which admin did it. For a
console whose entire purpose is privileged action, that is the gap worth closing,
and it is one column plus two lines of trigger.

This is additive, so R2 permits it. `auth.uid()` is available inside the trigger
because it is `SECURITY DEFINER` with `search_path = ''` — reference it fully
qualified.

```sql
-- =====================================================================
-- 20260810000031_audit_actor.sql
--
-- Part 10 §4.2. audit_log records what changed but not who changed it.
-- Additive: one nullable column, and audit_row_change() gains two lines.
-- =====================================================================

alter table public.audit_log
  add column if not exists actor_id uuid
    references public.users (id) on delete set null;

-- on delete set null, not cascade: deleting an admin must not erase the
-- record of what that admin did. Compare provider_payouts.paid_by
-- (schema.sql:873), which made the same choice for the same reason.

create index if not exists idx_audit_actor on public.audit_log (actor_id);
-- Serves the console's actor filter (§4.4) and nothing else.

-- The whole change to the trigger. Everything else in the body is
-- unchanged from schema.sql:1253 -- re-read it there before editing, and
-- keep the `updated_at` exclusion and the `v_changed is null` early
-- return, both of which stop the log filling with noise.
create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old     jsonb;
  v_new     jsonb;
  v_changed text;
  v_record  text;
  v_actor   uuid := auth.uid();   -- NEW. NULL for trigger-internal and
                                  -- service-role writes, which is correct:
                                  -- "no human did this" is information.
begin
  if tg_op = 'INSERT' then
    v_new    := to_jsonb(new);
    v_record := v_new ->> 'id';

  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_record := v_new ->> 'id';

    select string_agg(key, ',' order by key)
      into v_changed
      from jsonb_each(v_new) n(key, value)
     where key <> 'updated_at'
       and value is distinct from (v_old -> n.key);

    if v_changed is null then
      return null;
    end if;

  else -- DELETE
    v_old    := to_jsonb(old);
    v_record := v_old ->> 'id';
  end if;

  insert into public.audit_log
    (table_name, record_id, action_type, old_values, new_values,
     changed_fields, actor_id)                      -- NEW column
  values
    (tg_table_name, v_record, tg_op::public.audit_action,
     v_old, v_new, v_changed, v_actor);             -- NEW value

  return null;
end;
$$;

revoke all on function public.audit_row_change() from public, anon, authenticated;
```

Two things not to do here:

- **Do not add an `UPDATE` or `DELETE` policy to `audit_log`** to "clean up" old
  rows. There is deliberately none (`rls_policies.sql:1007`). An audit log that
  can be edited from the client is not an audit log. Retention is handled in
  §4.6 by a manual, admin-run purge that itself is logged.
- **Do not populate `ip_address` from the client.** A client-supplied IP is a
  client-supplied claim. Leave both legacy columns NULL; if real IPs are ever
  needed they must come from an Edge Function reading `x-forwarded-for`.

### 4.3 Category — the brief's word, and what it maps to

"Categorised by time, category, date" needs a definition of *category* the
database can filter on. Neither table has such a column, and adding an
uncontrolled free-text one would produce a dropdown of forty values within a
month. Derive it instead, from `table_name`, in a view:

| Category | `audit_log.table_name` | Why grouped |
|---|---|---|
| `money` | `payments`, `provider_payouts`, `orders`, `order_items`, `payment_sessions` | Anything where an amount moved. The category an auditor opens first. |
| `care` | `appointments` | Clinical commitments. |
| `providers` | `doctors`, `hospitals`, `clinics`, `pharmacies` | Verification and listing decisions. |
| `accounts` | `users` | Role, ban, contact changes. |
| `content` | `reviews`, `feedback`, `notifications` | Moderation surface. |
| `blood` | `blood_banks`, `blood_donors`, `blood_requests` | Separate because it is non-commercial. |
| `other` | anything not listed | Catch-all, so a new table never disappears from the log. |

Categories are a `case` in the view, not a column, so no backfill is needed and
adding a table is a one-line view change.

### 4.4 The unified audit view, and why it must be a view

PostgREST cannot `GROUP BY`, and it also cannot `UNION`. The console needs both
tables in one time-ordered list with one set of filters, so the union has to
happen server-side.

```sql
-- =====================================================================
-- 20260810000032_audit_console.sql
-- =====================================================================

create or replace view public.audit_feed
with (security_invoker = on) as
select
  'data'::text                       as source,
  'd' || a.id::text                  as feed_id,   -- unique across sources
  a.action_timestamp                 as occurred_at,
  a.actor_id,
  lower(a.action_type::text)         as action,    -- insert|update|delete
  a.table_name                       as entity,
  a.record_id                        as entity_id,
  case a.table_name
    when 'payments'         then 'money'
    when 'provider_payouts' then 'money'
    when 'orders'           then 'money'
    when 'order_items'      then 'money'
    when 'payment_sessions' then 'money'
    when 'appointments'     then 'care'
    when 'doctors'          then 'providers'
    when 'hospitals'        then 'providers'
    when 'clinics'          then 'providers'
    when 'pharmacies'       then 'providers'
    when 'users'            then 'accounts'
    when 'reviews'          then 'content'
    when 'feedback'         then 'content'
    when 'notifications'    then 'content'
    when 'blood_banks'      then 'blood'
    when 'blood_donors'     then 'blood'
    when 'blood_requests'   then 'blood'
    else 'other'
  end                                as category,
  a.changed_fields,
  a.old_values,
  a.new_values
from public.audit_log a
union all
select
  'app'::text,
  'a' || l.id::text,
  l.created_at,
  l.user_id,
  l.action,
  coalesce(l.entity, 'session'),
  l.entity_id,
  case
    when l.action in ('login','logout','register','change_password') then 'sessions'
    else 'other'
  end,
  null::text,
  null::jsonb,
  l.details              -- app events carry no before-image; details is the after
from public.app_audit_log l;

-- security_invoker = on so the caller's own RLS on both base tables still
-- applies. That is not the gate, though: it would let a non-admin see
-- their own app_audit_log rows through this view. Revoke and wrap.
revoke all on public.audit_feed from anon, authenticated;

create or replace function public.admin_audit_feed(
  p_from     timestamptz default null,
  p_to       timestamptz default null,
  p_category text        default null,
  p_actor    uuid        default null,
  p_action   text        default null,
  p_entity   text        default null,
  p_search   text        default null,
  p_limit    int         default 20,
  p_offset   int         default 0
)
returns table (
  source        text,
  feed_id       text,
  occurred_at   timestamptz,
  actor_id      uuid,
  actor_name    text,
  actor_email   text,
  actor_role    text,
  action        text,
  entity        text,
  entity_id     text,
  category      text,
  changed_fields text,
  old_values    jsonb,
  new_values    jsonb,
  total_count   bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;

  return query
  with filtered as (
    select f.*
      from public.audit_feed f
     where (p_from     is null or f.occurred_at >= p_from)
       -- Half-open on the upper bound. A caller passing a bare date for
       -- p_to would otherwise cut that day off at midnight; the Dart side
       -- sends start-of-next-day, matching _endOfDay()
       -- (admin_repository.dart:1417).
       and (p_to       is null or f.occurred_at <  p_to)
       and (p_category is null or f.category  = p_category)
       and (p_actor    is null or f.actor_id  = p_actor)
       and (p_action   is null or f.action    = p_action)
       and (p_entity   is null or f.entity    = p_entity)
       and (p_search   is null or
            f.entity_id ilike '%' || p_search || '%' or
            coalesce(f.new_values, f.old_values)::text ilike '%' || p_search || '%')
  )
  select f.source, f.feed_id, f.occurred_at, f.actor_id,
         u.name, u.email, u.role::text,
         f.action, f.entity, f.entity_id, f.category,
         f.changed_fields, f.old_values, f.new_values,
         -- The total for the pager, computed once over the filtered set.
         -- PostgREST's exact-count header cannot reach a function's result,
         -- so it rides along on every row.
         count(*) over () as total_count
    from filtered f
    left join public.users u on u.id = f.actor_id
   order by f.occurred_at desc, f.feed_id desc
   limit  greatest(1, least(p_limit, 100))
  offset greatest(0, p_offset);
end;
$$;

grant execute on function public.admin_audit_feed(
  timestamptz, timestamptz, text, uuid, text, text, text, int, int
) to authenticated;
```

`order by occurred_at desc, feed_id desc` — the tiebreaker is not optional. Two
rows can share a timestamp to the microsecond under a single statement that
touches two tables, and an unstable sort makes a paged list silently repeat or
skip rows.

**Indexes.** The existing ones cover most of this:
`idx_audit_timestamp` (`schema.sql:1198`), `idx_audit_table_name` (`:1195`),
`idx_app_audit_created` (`:1221`), `idx_app_audit_action` (`:1220`), plus
`idx_audit_actor` from §4.2. The one to add is for the date-range scan on the
larger table, which is `audit_log`:

```sql
create index if not exists idx_audit_table_time
  on public.audit_log (table_name, action_timestamp desc);
```

### 4.5 The console slice

| Layer | Value |
|---|---|
| Route | `Routes.adminAudit` = `/admin/audit-log` (`router.dart:183`, registered `:451`) |
| Screen | `app/lib/features/admin/presentation/admin_audit_screen.dart` |
| Providers | `adminAuditActionProvider`, `adminAuditEntityProvider`, `adminAuditSearchProvider`, `adminAuditSummaryProvider`, `adminAuditProvider` (`admin_controllers.dart:176-205`) |
| Repository | `AdminRepository.auditLog()` (`admin_repository.dart:834`) |
| Source | `admin_audit_feed()` RPC — replaces the direct `app_audit_log` read |

**Two gaps in the existing screen, both confirmed by inspection:**

1. **Date filtering is unreachable.** `auditLog()` accepts `dateFrom` and
   `dateTo` (`admin_repository.dart:840-841`) and correctly makes the upper bound
   inclusive of the whole end day via `_endOfDay()` (`:1417`). No controller and
   no widget passes either — `adminAuditProvider` (`admin_controllers.dart:192`)
   forwards only `action`, `entity` and `search`. The brief asks for time and
   date filtering explicitly, so this is a required fix, and the plumbing already
   exists behind it.
2. **The filter dropdowns read a capped sample.** Documented honestly at
   `admin_repository.dart:32-36`: with no view over `app_audit_log`, the distinct
   action and entity values come from the most recent 500 rows
   (`_auditSampleSize`, `:76`), so a value that has not occurred recently is
   absent from the dropdown. `admin_audit_feed` fixes the *page*; add a companion
   for the *filter values*, so the dropdowns become exact:

```sql
create or replace function public.admin_audit_facets()
returns table (kind text, value text, n bigint)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'admin only' using errcode = '42501';
  end if;
  return query
    select 'category', f.category, count(*) from public.audit_feed f group by 1,2
    union all
    select 'action',   f.action,   count(*) from public.audit_feed f group by 1,2
    union all
    select 'entity',   f.entity,   count(*) from public.audit_feed f group by 1,2
    order by 1, 3 desc;
end;
$$;
grant execute on function public.admin_audit_facets() to authenticated;
```

Now the counts beside each dropdown value are exact *and* whole-log, where before
only the three summary totals were. Delete `_auditSampleSize` and `_auditSummary`
(`admin_repository.dart:76`, `:1236`) once this lands — leaving a sampled path
beside an exact one guarantees someone reads the wrong number.

Repository additions, beside the frozen `auditLog()` per R3:

```dart
  /// Both audit tables, one time-ordered feed. See Part 10 §4.4.
  ///
  /// [from]/[to] are the brief's date range; [to] is exclusive and the caller
  /// passes start-of-next-day, which is what `_endOfDay` already computes.
  /// [category] is derived server-side from the table name -- it is not a
  /// stored column, so the values come from `admin_audit_facets`, never from a
  /// hardcoded list that would drift.
  Future<Paged<AuditEntry>> auditFeed({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
    DateTime? from,
    DateTime? to,
    String? category,
    String? actorId,
    String? action,
    String? entity,
    String? search,
  }) async {
    return SupabaseService.guard(() async {
      final range = PageRange(page, limit);
      final rows = await _sb.rpc<List<dynamic>>('admin_audit_feed', params: {
        'p_from': from?.toUtc().toIso8601String(),
        'p_to': to?.toUtc().toIso8601String(),
        'p_category': _nullIfEmpty(category),
        'p_actor': _nullIfEmpty(actorId),
        'p_action': _nullIfEmpty(action),
        'p_entity': _nullIfEmpty(entity),
        'p_search': _nullIfEmpty(search),
        'p_limit': limit,
        'p_offset': range.from,
      });

      // total_count rides on every row (see the function). An empty page is
      // a genuine zero, not a missing total.
      final total = rows.isEmpty
          ? 0
          : Fmt.toInt((rows.first as Map<String, dynamic>)['total_count']);

      return Paged(
        items: rows
            .map((r) => AuditEntry.fromJson(
                  _shapeFeed(r as Map<String, dynamic>),
                ))
            .toList(),
        meta: PageMeta(page: page, limit: limit, total: total),
      );
    });
  }
```

`_shapeFeed` mirrors `_shapeAudit` (`admin_repository.dart:1214`), including its
`jsonEncode` of the jsonb payload — encoding keeps the rendered text valid JSON
rather than Dart's `Map.toString()`, which is not parseable and which a
before/after diff view has to parse.

**UI.** Add to `admin_audit_screen.dart`, above the existing action/entity
pickers:

- A date-range control with presets — Today, 7 days, 30 days, Custom. Presets
  first because a date picker is four taps and "what happened today" is the
  common question. Compute in `Asia/Dhaka`, not device local: an admin abroad
  must see the platform's day. Cross-ref Part 06 for Bangla numerals in the
  displayed range.
- A category picker fed by `admin_audit_facets`, placed *before* action and
  entity, since category is the coarsest cut.
- An actor picker — reuse the user search from §8 rather than a dropdown; a
  platform with thousands of users cannot enumerate actors in a menu.
- An expandable row showing the before/after diff for `source = 'data'` rows.
  Render only the keys named in `changed_fields`; a full `users` row is 20 fields
  and the one that changed is what matters. Redact by key name before display —
  never render `password`, `token`, `stripe_customer_id`, `transaction_id` or
  `sender_number` (see §8's rule).

**Export.** CSV, not PDF — this is data for a spreadsheet. Reuse
`admin_audit_feed` with `p_limit` at its ceiling of 100 and page through it,
writing to a file via `share_plus`. Cap the export at 5 000 rows and say so in
the UI; an unbounded export on a mobile client is an out-of-memory crash. Escape
embedded quotes and newlines in the jsonb columns — an unescaped `old_values`
will corrupt every row after it.

### 4.6 Storage growth, and the retention plan

**This is the risk that makes the audit system a liability if ignored.**
`audit_row_change()` is wired to 18 tables (`schema.sql:2987-3004`), and each
`UPDATE` row stores `old_values` *and* `new_values` — the full row twice, as
jsonb. A `users` row is roughly 600 bytes; one profile edit therefore costs about
1.4 KB after jsonb overhead. `notifications_audit` is the worst offender: every
notification insert writes a second row into `audit_log` holding the whole
notification.

Rough arithmetic on the free tier's 500 MB: 1 000 daily active users generating
20 audited writes each is 20 000 rows/day at ~1 KB, so **~600 MB/year from the
audit log alone**. It will exhaust the database before the business data does.

Three mitigations, in order of value:

1. **Stop auditing `notifications`.** It is high-volume, entirely
   trigger-generated, and its "before image" is meaningless — a notification is
   inserted once and only ever flips `is_read`. Nothing is recoverable from
   auditing it that the table itself does not already hold.
   ```sql
   drop trigger if exists notifications_audit on public.notifications;
   ```
   Record this in `IMPLEMENTATION_LOG.md` as a deliberate coverage reduction.
2. **Do not audit `cart`.** Same reasoning: `cart_audit` (`schema.sql:3003`)
   logs every quantity tap. A cart is transient by definition. Drop it.
3. **Tiered retention, run manually.** Never automatic in this phase.

| Category | Retain full | Then | Never purge |
|---|---|---|---|
| `money` | forever | — | yes |
| `accounts` | 2 years | strip `old_values`/`new_values`, keep the row | — |
| `care` | 2 years | strip payloads | — |
| `providers` | 1 year | strip payloads | — |
| `content`, `blood`, `sessions`, `other` | 180 days | hard delete | — |

Stripping rather than deleting is the interesting half: the row still proves
*that* something changed, by whom and when, at about 5 % of the storage.

```sql
-- Run by hand, off-peak, in batches. Financial rows are excluded by the
-- table_name list, not by a category join -- an explicit list cannot be
-- widened by an accidental view edit.
update public.audit_log
   set old_values = null,
       new_values = jsonb_build_object('_stripped', true)
 where action_timestamp < now() - interval '2 years'
   and table_name not in ('payments','provider_payouts','orders',
                          'order_items','payment_sessions')
   and old_values is not null;

delete from public.audit_log
 where action_timestamp < now() - interval '180 days'
   and table_name in ('reviews','feedback','blood_donors','blood_requests');
```

Note the contradiction to resolve before running these: `audit_log` has no
`UPDATE` or `DELETE` policy (`rls_policies.sql:1007`), by design. These statements
must be run by the project owner in the SQL Editor as the table owner, never
through PostgREST, and never wrapped in a `SECURITY DEFINER` function the app can
call. A purge the application can invoke is a purge an attacker can invoke.

### 4.7 Four states, strings, acceptance

| State | Rendering |
|---|---|
| Loading | Skeleton rows; keep the filter bar interactive |
| Empty | "No activity in this range." / "এই সময়সীমায় কোনো কার্যকলাপ নেই।" — with a "Clear filters" action, because empty here is almost always an over-narrow filter |
| Error | `ErrorView` + retry |
| Content | Paged list, expandable diff, export button in the app bar |

| Key | EN | BN |
|---|---|---|
| `adminAuditTitle` | Activity log | কার্যকলাপ লগ |
| `adminAuditRangeToday` | Today | আজ |
| `adminAuditRange7` | Last 7 days | গত ৭ দিন |
| `adminAuditRange30` | Last 30 days | গত ৩০ দিন |
| `adminAuditRangeCustom` | Custom range | নির্দিষ্ট সময়সীমা |
| `adminAuditCategory` | Category | বিভাগ |
| `adminAuditActor` | Performed by | সম্পাদনকারী |
| `adminAuditBefore` | Before | পূর্বে |
| `adminAuditAfter` | After | পরে |
| `adminAuditSystem` | System | সিস্টেম |
| `adminAuditExport` | Export CSV | CSV রপ্তানি |
| `adminAuditExportCapped` | Showing the first {n} rows. Narrow the range to export the rest. | প্রথম {n}টি সারি দেখানো হচ্ছে। বাকিগুলো রপ্তানি করতে সময়সীমা কমান। |

`adminAuditSystem` is the label for a NULL `actor_id` — a trigger-internal or
service-role write. Never render an empty cell there; a blank actor reads as a
bug and invites someone to "fix" it by removing the column.

**Acceptance test.**

1. As admin, change a doctor's `verification_status`. Assert one new `audit_log`
   row with `actor_id` = your uuid, `changed_fields` naming
   `verification_status`, `old_values`/`new_values` both populated, category
   `providers` in `audit_feed`.
2. Sign out and in. Assert an `app_audit_log` row appears in the same feed with
   `source='app'`, category `sessions`.
3. Set the range to Today, category `money`. Assert only payment/payout/order
   rows from today.
4. Call `admin_audit_feed` with a patient JWT. Expect `42501`.
5. `select * from audit_feed` with a patient JWT. Expect a permission error —
   the `revoke` is what makes the function the only path.
6. Delete a blog row as admin. Assert `audit_log` holds `action_type='DELETE'`
   with the full row in `old_values`. **This is the brief's sentence, proven.**

---

## 5. Content moderation

### 5.1 Reviews

| Layer | Value |
|---|---|
| Route | `Routes.adminReviews` = `/admin/reviews` (`router.dart:177`, registered `:421`) |
| Screen | `app/lib/features/admin/presentation/admin_reviews_screen.dart` |
| Providers | `adminReviewStatusProvider` (default `'pending'`), `adminReviewTargetProvider`, `adminReviewsProvider` (`admin_controllers.dart:113-127`) |
| Repository | `reviews()` (`admin_repository.dart:487`), `moderateReview()` (`:531`) |
| Table | `reviews`; `review_status` enum = `pending|approved|rejected` (`schema.sql:225`) |
| RLS | `reviews_select_admin`, `reviews_update_admin`; `aa_guard_reviews` blocks `status` for everyone else |

Every review lands `pending` and is invisible publicly until approved, so this
queue gates the platform's rating signal. Approving or rejecting fires
`reviews_recalc_rating`, which recomputes the target's cached `rating` and
`total_reviews` from **approved rows only** — that is why rejecting is not a
no-op and why deleting fires the same recalculation.

**The gap: there is no way for a user to report a review.** `reviews` has
`status` but no reported flag, so the queue only ever contains never-yet-moderated
rows. An approved review that later turns abusive has no path back into the
queue. Add the flag; it is additive and cheap:

```sql
alter table public.reviews
  add column if not exists reported_count int  not null default 0,
  add column if not exists reported_at    timestamptz;

create index if not exists idx_reviews_reported
  on public.reviews (reported_at desc) where reported_count > 0;

-- Reporting is an RPC, not an UPDATE grant. A client that can update
-- reviews.reported_count can also set it to zero on a review about
-- themselves, and aa_guard_reviews only protects `status`.
create or replace function public.report_review(p_review_id bigint, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'sign in to report' using errcode = '42501';
  end if;
  update public.reviews
     set reported_count = reported_count + 1,
         reported_at    = now()
   where id = p_review_id;
  if not found then
    raise exception 'review not found' using errcode = 'P0002';
  end if;
  -- The reason rides into the audit trail rather than a new column: the
  -- reviews_audit trigger (schema.sql:2996) already writes a row, and
  -- app_audit_log is where a user-initiated event belongs.
  insert into public.app_audit_log (user_id, action, entity, entity_id, details)
  values (auth.uid(), 'report', 'reviews', p_review_id::text,
          jsonb_build_object('reason', left(coalesce(p_reason, ''), 500)));
end;
$$;
grant execute on function public.report_review(bigint, text) to authenticated;
```

Add a third tab to the screen — Pending, **Reported**, All — where Reported
filters `reported_count > 0` ordered by `reported_at desc`. Reported reviews are
often already `approved`, so this tab must not filter on `status`.

Repository, beside the frozen `reviews()`:

```dart
  /// Reviews users have flagged. Ordered most-recently-reported first, not
  /// most-reported: a review reported once an hour ago needs a decision more
  /// urgently than one reported five times last month and left alone.
  Future<Paged<AdminReview>> reportedReviews({
    int page = 1,
    int limit = AppConfig.defaultPageSize,
  }) async { /* .gt('reported_count', 0).order('reported_at', ascending: false) */ }
```

### 5.2 Blogs

| Layer | Value |
|---|---|
| Route | `Routes.adminBlogs` = `/admin/blogs` (`router.dart:180`, registered `:436`) |
| Screen | `admin_blogs_screen.dart` |
| Providers | `adminBlogStatusProvider`, `adminBlogSearchProvider`, `adminBlogsProvider` (`admin_controllers.dart:160-172`) |
| Repository | `blogs()` (`admin_repository.dart:733`), `saveBlog()` (`:776`), `deleteBlog()` (`:824`) |
| Table | `blogs`; `blog_status` = `draft|published|archived` (`schema.sql:260`) |

Blogs are admin-authored, so "moderation" here means the draft → published
transition, which Part 12 §18 already enforces server-side (contradiction #20:
a blog post cannot publish itself). Two behaviours in the existing repository to
preserve rather than rediscover:

- **Slugs are minted in Dart** (`_uniqueSlug`, `admin_repository.dart:1347`)
  because no trigger does it and `uq_blog_slug` is a hard constraint. Retitling
  re-slugs, and the current row is excluded from the collision check so a no-op
  save does not append `-2` to its own slug every time.
- **Publishing stamps `published_at`** (`:796`) because
  `blogs_select_published` orders on it, and a published post with a null
  timestamp sorts last forever.

`deleteBlog()` becomes a soft delete per §3 — a published article with inbound
links should stop resolving, not vanish from the record.

### 5.3 Feedback triage

| Layer | Value |
|---|---|
| Route | `Routes.adminFeedback` = `/admin/feedback` (`router.dart:178`, registered `:426`) |
| Screen | `admin_feedback_screen.dart` |
| Providers | `adminFeedbackStatusProvider`, `adminFeedbackPriorityProvider`, `adminFeedbackProvider` (`admin_controllers.dart:131-142`) |
| Repository | `feedback()` (`admin_repository.dart:560`), `updateFeedback()` (`:602`), `deleteFeedback()` (`:632`) |
| Table | `feedback`; `feedback_priority` = `('low','normal','high','urgent')` (`schema.sql:247`) |

**The vocabulary mismatch — preserve it exactly as it is.** The database enum is
`('low','normal','high','urgent')`. Every screen and every filter constant says
`medium`. The repository translates at the boundary and nowhere else:

```dart
  /// Console word -> `feedback_priority` enum value.
  static String _priorityToDb(String priority) =>
      priority.trim() == 'medium' ? 'normal' : priority.trim();

  /// `feedback_priority` enum value -> console word.
  static String _priorityToUi(String priority) =>
      priority == 'normal' ? 'medium' : priority;
```

(`admin_repository.dart:1407-1412`; the same pattern maps `feedback_status`
`new` ↔ console `pending` at `:1399-1404`.)

Do not "fix" either side. Adding `medium` to the enum would leave `normal` in
place as a second name for the same thing, since R2 forbids renaming an enum
value and there are existing rows holding it. Changing every screen to say
`normal` touches the filter constants, the badge colours and the dropdown labels
for zero user-visible benefit. **The boundary translation is the correct design
and it is already correct.** What you must do is make sure any *new* code —
the priority chips, the sort order, the l10n keys — speaks the console
vocabulary and passes through `_priorityToDb` before it reaches Postgrest. A
literal `'medium'` sent straight to `.eq('priority', ...)` is a 22P02 invalid
enum error at runtime, not a compile error.

Triage rules for the screen:

| Priority | Console word | DB value | Default sort | Badge |
|---|---|---|---|---|
| Highest | `urgent` | `urgent` | 1 | error colour |
| | `high` | `high` | 2 | warning colour |
| Default | `medium` | **`normal`** | 3 | neutral |
| Lowest | `low` | `low` | 4 | muted |

Sort urgent-first *then* oldest-first within a priority, so an urgent ticket
cannot be buried by newer urgent ones. Postgrest can express this as two
`.order()` calls; no view is needed because there is no aggregate.

Writing a response fires `feedback_notify_trg`, which notifies the submitter when
the row has a user account behind it (`admin_repository.dart:594`). Anonymous
feedback carries `name`/`email` but no `user_id`; the UI must not promise a reply
notification for those rows.

`deleteFeedback()` becomes a soft delete per §3. A deleted complaint is exactly
the thing the brief wants kept.

### 5.4 Strings and states for §5

| Key | EN | BN |
|---|---|---|
| `adminReviewsPending` | Awaiting review | পর্যালোচনার অপেক্ষায় |
| `adminReviewsReported` | Reported | রিপোর্ট করা হয়েছে |
| `adminReviewReportCount` | Reported {n} time(s) | {n} বার রিপোর্ট করা হয়েছে |
| `adminReviewApprove` | Publish | প্রকাশ করুন |
| `adminReviewReject` | Hide | লুকান |
| `adminFeedbackTriage` | Triage | অগ্রাধিকার নির্ধারণ |
| `adminFeedbackPriorityUrgent` | Urgent | অত্যাবশ্যক |
| `adminFeedbackPriorityHigh` | High | উচ্চ |
| `adminFeedbackPriorityMedium` | Medium | মধ্যম |
| `adminFeedbackPriorityLow` | Low | নিম্ন |
| `adminFeedbackReply` | Reply | জবাব দিন |
| `adminFeedbackAnonNoNotify` | This was sent without an account, so no notification can be delivered. | এটি অ্যাকাউন্ট ছাড়া পাঠানো হয়েছে, তাই কোনো বিজ্ঞপ্তি পাঠানো যাবে না। |

Empty states differ per tab and must: "No reviews awaiting a decision." /
"Nothing has been reported." / "No open feedback." A single shared "No data"
string here loses the only information the screen has.

### 5.5 Acceptance test

1. Submit a review as a patient after a completed appointment (Part 12 §5 gates
   this). Assert it lands `pending` and is absent from the doctor's public page.
2. Approve it. Assert the doctor's `rating` and `total_reviews` change.
3. Reject it. Assert the rating recomputes *without* it.
4. Call `report_review` on an approved review as a different patient. Assert
   `reported_count = 1`, it appears in the Reported tab while still `approved`,
   and one `app_audit_log` row records the reporter and reason.
5. Set a feedback row to `medium` in the UI. Assert the stored value is
   `normal`, and that reloading the screen still displays `medium`.
6. Attempt `.eq('priority','medium')` directly against Postgrest. Expect
   `22P02` — this is the test that proves the boundary mapping is load-bearing.

---

## 6. Commission control

> Brief item: the admin sets the platform's cut. Cross-ref **Part 04 §4**, which
> owns the commission and escrow design. This section owns only the *console*.

### 6.1 What Part 04 already settles — do not restate or re-derive it

| Thing | Where | State |
|---|---|---|
| Per-provider rate `commission_percentage numeric(5,2) not null default 2.00`, CHECK 0–100 | `doctors` (`schema.sql:330`), `hospitals` (`:398`), `clinics` (`:454`), `pharmacies` (`:507`) | exists |
| Frozen copy on the payout | `provider_payouts.commission_percentage` (`schema.sql:870`) | exists |
| Split columns | `payments.admin_share`/`provider_share` (`schema.sql:623-624`) | exists |
| Reconciliation CHECK `admin_share + provider_share = amount` | `payments_split_check` (`schema.sql:628`) | exists |
| Split trigger | `payments_apply_verification()` | exists |
| Category-level default table `commission_settings` | Part 04 §4.2 | **Part 04 builds it** |
| Admin UI for both levels | — | **this section** |

Blood banks have no `commission_percentage` and must never get one. Part 04 §4.2
gives the reasoning and encodes it as a CHECK; the console simply must not offer
the field for that type. `updateCommission()` (`admin_repository.dart:941`)
already routes through `_providerTable()` (`:1381`), which accepts only the four
commercial tables and raises a 400 for anything else — including `blood_banks`.
That is the enforcement; do not add a UI-level check instead.

### 6.2 Freezing — the rule the console must not break

The rate is read at the moment of payment verification and written onto the row
(Part 04 §4.3). The consequence for this console, stated as a rule:

> **Changing a commission percentage affects future transactions only. It never
> rewrites a transaction that has already settled.**

This is not a limitation to work around; it is the property that makes the
platform auditable. If changing a rate recomputed historical splits, then every
payout report, every provider's earnings screen and every reconciliation total
would silently change whenever an admin touched a number — and there would be no
way to answer "what were we owed in March" after an April rate change.

Three concrete prohibitions for the implementing agent:

1. **No bulk-update of `payments.admin_share` / `provider_share`.** Ever. Those
   columns are the frozen record. `payments_split_check` would reject an
   unbalanced write, but a *balanced* rewrite would pass and destroy history
   silently.
2. **No update of `provider_payouts.commission_percentage`** on existing rows.
   It is the frozen copy. A reversal happens by refunding the appointment
   (`admin_repository.dart:1013-1014`), which writes new rows.
3. **The rate editor shows the effective date.** Label it "applies to payments
   verified from now on", in both languages. An admin who believes a change is
   retroactive will make a decision on a false premise.

The console must also surface *which* rate applied, per transaction, since it can
differ from the provider's current rate. `provider_payouts.commission_percentage`
holds it and `payouts()` (`admin_repository.dart:1027-1034`) already selects it —
render it on every payout row rather than recomputing from the provider.

### 6.3 The slice

| Layer | Value |
|---|---|
| Route | new: `Routes.adminCommission = '/admin/commission'`, registered beside the others in `router.dart` with `parentNavigatorKey: _rootKey` |
| Screen | new: `app/lib/features/admin/presentation/admin_commission_screen.dart` |
| Providers | new: `adminCommissionCategoriesProvider` (FutureProvider over `commission_settings`), plus the per-provider editor reusing `adminProvidersProvider` |
| Repository | `updateCommission()` (`admin_repository.dart:941`) exists for the per-provider case; add `commissionSettings()` and `updateCommissionCategory()` |
| Tables | `commission_settings` (Part 04 §4.2); `commission_percentage` on the four provider tables |
| RLS | `commission_settings` readable by `authenticated`, writable by admin; provider columns via `*_update_admin` + `aa_guard_*` |

Two levels, one screen, in this order:

**Category defaults** at the top — four rows (doctor, hospital, clinic,
pharmacy), each a percentage field. These apply to *newly created* providers via
the `before insert` trigger Part 04 §4.2 specifies. Say so on screen: existing
providers are untouched, because silently changing a live provider's negotiated
rate would be a data-integrity incident, not a feature.

**Per-provider overrides** below, as a searchable list showing name, current
rate, whether it differs from the category default, and a lifetime commission
figure from §9's view. Surfacing the difference matters — an admin needs to see
at a glance which providers are on negotiated terms.

```dart
  /// The four category defaults. Read-write for an admin; readable by any
  /// authenticated user, because a doctor is entitled to know the platform's
  /// cut before they agree to it.
  Future<List<CommissionSetting>> commissionSettings() async {
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('commission_settings')
          .select('category, percentage, updated_at, updated_by')
          .order('category');
      return rows.map(CommissionSetting.fromJson).toList();
    });
  }

  /// Sets a category default. Affects providers created after this call; the
  /// per-provider rate on existing rows is deliberately not touched. See
  /// Part 10 §6.2.
  Future<void> updateCommissionCategory({
    required String category,
    required double percent,
  }) async {
    if (percent < 0 || percent > 100) {
      throw ApiException(
        message: 'Commission must be between 0 and 100 percent.',
        statusCode: 422,
        errors: const {'percentage': 'Must be 0-100.'},
      );
    }
    return SupabaseService.guard(() async {
      final rows = await _sb
          .db('commission_settings')
          .update({'percentage': percent, 'updated_by': _sb.currentUserId})
          .eq('category', category)
          .select('category');
      if (rows.isEmpty) {
        throw ApiException(message: 'Unknown category.', statusCode: 404);
      }
    });
  }
```

The client-side range check duplicates
`commission_settings_percentage_check`. That duplication is deliberate and is the
R9 pattern: the database decides, the UI predicts, so the user gets a field-level
validation message instead of a raw 23514.

<!--CONT-->
