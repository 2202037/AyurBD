# Part 02 — Backend Services

**Phase 3.** Read `00_MASTER_PLAN.md` first. Rules R1, R2, R6 and R9 bind every
line here. This part owns the boundary between the Flutter client and
PostgreSQL: row-level security, Storage, Edge Functions, rate limiting and the
deploy runbook. It adds no business logic — that lives in Part 01 (schema) and
Part 12 (integrity).

Prerequisite: Parts 01 and 12 are applied. Several policies below reference
columns and helper functions those parts create.

---

## 1. The RLS model

### 1.1 The four helper functions are the whole vocabulary

`supabase/schema.sql:2009-2064` defines four `security definer`, `stable`,
`set search_path = ''` helpers. Every policy in `supabase/rls_policies.sql` is
written in terms of them plus `auth.uid()`. Do not add a fifth without a reason
you can write down.

| Helper | Returns | Defined at | Why it exists |
|---|---|---|---|
| `public.current_user_role()` | `public.user_role` | `schema.sql:2009` | One lookup of the caller's role, planner-cached per statement |
| `public.is_admin()` | `boolean` | `schema.sql:2019` | The admin escape hatch every table's `_admin` policy calls |
| `public.current_doctor_id()` | `bigint` | `schema.sql:2034` | The caller's `doctors.id`, **NULL when `users.is_active` is false** |
| `public.current_pharmacy_id()` | `bigint` | `schema.sql:2047` | The caller's `pharmacies.id`, same `is_active` join |

Three properties are load-bearing and must survive any edit:

**`security definer` breaks the recursion.** A policy on `public.users` that
selected from `public.users` to learn the caller's role would re-enter its own
policy and stack-overflow. These functions run as the owner, so they read the
table without RLS.

**`stable` collapses N calls into one.** Without it the planner calls the
function once *per row*, turning a 20-row page into 20 extra subqueries. This is
the single biggest RLS performance lever in the file.

**`set search_path = ''` is a privilege-escalation defence.** A `security
definer` function with a mutable search path can be hijacked by a caller who
creates a same-named function in a schema earlier on the path. Every fully
qualified name in the bodies (`public.users`, not `users`) exists for this.

**The `is_active` join is a ban switch.** `current_doctor_id()` returns NULL for
a suspended user, so every doctor-scoped policy that compares against it denies.
Banning a provider is therefore one `update users set is_active = false` — no
policy sweep. Preserve this when adding provider-scoped policies: compare to the
helper, never to a hand-written join on `doctors.user_id = auth.uid()`.

### 1.2 Per-command, never `FOR ALL`

Every policy in `rls_policies.sql` names exactly one command. There is no `for
all` in the file and none may be added. The reason is not style:

- `for all` produces one `USING` clause that Postgres applies to SELECT, UPDATE
  and DELETE, and reuses as the `WITH CHECK` for INSERT. The read predicate and
  the write predicate are then forced to be the same expression, which is almost
  never what you mean. `payments` is the proof: a patient may **read** their own
  payments but may not **insert** one at all — that difference is inexpressible
  in a single `for all`.
- A per-command policy set is auditable by reading it. `for all` requires
  simulating the planner to know what it permits.
- Removing one capability later means editing a shared predicate under `for
  all`, which silently changes the other three commands.

Naming convention, already consistent across the file — keep it:
`<table>_<command>_<audience>`, e.g. `appointments_select_doctor`,
`provider_docs_insert_own`. The audience suffix is the fastest way to answer
"who can do this" by grep.

### 1.3 RLS is authorisation, not validation

RLS decides which *rows* you may touch. It cannot say "you may update this row
but not this column of it", because `WITH CHECK` sees only the new row, never
the old one. That gap is closed by the column-guard triggers in
`rls_policies.sql` PART 1 (`guard_admin_only_columns`, `rls_policies.sql:102`)
and the guards listed in `PAYMENT_ARCHITECTURE_FIX.md` §3. Without them a
patient who may update their own `users` row may set `role = 'admin'`, and a
doctor who may update their own `doctors` row may set `verification_status =
'verified'`. Both are one PATCH away and **no policy below blocks either**.

When you add a table, you owe it two things, not one: policies, and a column
guard if any of its columns are privileged.

### 1.4 The trusted-path marker

Four tables have INSERT revoked from `anon` and `authenticated` outright —
`orders`, `order_items`, `appointments`, `payments`. They are written only by
`place_order()`, `appointments_book()` and `submit_manual_payment()`. Those
functions arm a transaction-local marker via `trusted_path_begin()`, and every
guard trigger asks `public.write_is_trusted()`.

`trusted_path_begin` / `trusted_path_end` are revoked from `public`, `anon`,
`authenticated` **and** `service_role`. Do not grant them. Do not test trust
with `session_user` — that was root cause A in `PAYMENT_ARCHITECTURE_FIX.md`
§1.A: `security definer` changes `current_user`, never `session_user`, and
PostgREST always logs in as `authenticator`, so the test was constant-true.

---

## 2. The access matrix — every table, every command

Read this as the specification. Where the "Now" column disagrees with
`rls_policies.sql`, the file is wrong and must be corrected.

Legend: **own** = `user_id = auth.uid()` (or the table's equivalent owner
column) · **pub** = `anon` + `authenticated` · **admin** = `is_admin()` ·
**dr** = `current_doctor_id()` · **ph** = `current_pharmacy_id()` ·
**RPC** = direct DML revoked; only a `security definer` function writes · **—** =
no policy, i.e. denied.

### 2.1 Identity and providers

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `users` | pub for provider-owning rows (`users_select_public_providers`); own; appointment counterparty; admin | — (trigger `handle_new_user()` only) | own (column-guarded); admin | admin |
| `doctors` | pub (verified, not deleted); own; admin | own | own (column-guarded); admin | admin |
| `hospitals` | pub; own; admin | own | own (column-guarded); admin | admin |
| `clinics` | pub; own; admin | own | own (column-guarded); admin | admin |
| `pharmacies` | pub; own; admin | own | own (column-guarded); admin | admin |

`users` has no INSERT policy for anyone. Rows appear only from the
`handle_new_user()` trigger on `auth.users`. A client-side insert after `signUp`
could be abandoned mid-flight and leave an auth user with no profile; the
trigger runs in the same transaction as the auth user, so it cannot.

`users_select_public_providers` is deliberately narrow: it exposes the name and
photo of users who own a *published* provider row, not every user. A patient's
row is never publicly readable. See §5 — this policy is also the surface a
scraper attacks.

### 2.2 Money

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `appointments` | patient; doctor; admin | RPC `appointments_book()` | patient (cancel only); doctor; admin — all through `appointments_guard_transition()` | admin |
| `payments` | own; the appointment's doctor; admin | RPC `submit_manual_payment()` / webhook | admin only (`payments_apply_verification()`) | admin |
| `payment_sessions` | own | RPC `gateway_payment_begin()` | RPC / service-role (`gateway_payment_attach()`) | — |
| `provider_payouts` | own (`provider_user_id`); admin | — (trigger `record_payment_split()`) | admin | — |

Four observations that are not obvious from the table:

- **`payments` has an insert policy (`payments_insert_own`, `rls_policies.sql:491`)
  but INSERT is also revoked at the grant level.** Belt and braces: the revoke is
  structural, the policy is what would apply if a future grant were restored.
  Do not remove either.
- **`payment_sessions` has no DELETE policy at all.** A payment attempt is
  evidence. It transitions to `expired`; it is never erased.
- **`provider_payouts` has no INSERT policy.** Payout rows are created by the
  settlement trigger from what was actually collected. A client that could insert
  one could invent money owed to itself.
- **Nobody may UPDATE a verified payment**, enforced by
  `20260806000018_payments_verified_immutable.sql` rather than by policy — RLS
  cannot see the old value.

### 2.3 Pharmacy

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `pharmacy_products` | pub (active); owner ph; admin | owner ph | owner ph; admin | owner ph; admin |
| `cart` | own | own | own | own |
| `orders` | own; owning pharmacy; admin | RPC `place_order()` | own (cancel); pharmacy (fulfilment); admin | admin |
| `order_items` | via the parent order | via the parent order (RPC) | admin | admin |

`cart` is the only table in the schema with a full own-row CRUD set, and that is
correct: a cart is scratch space with no financial meaning until `place_order()`
reads it under a lock and re-prices every line from `pharmacy_products`. Client
prices are never trusted.

### 2.4 Community and content

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `reviews` | approved (pub); own; the reviewed provider; admin | own, gated by `guard_reviews_insert` | own **while pending**; admin | own; admin |
| `blogs` | published (pub); author; admin | admin | admin | admin |
| `feedback` | own; admin | anon; authenticated | admin | admin |
| `blood_banks` | pub | admin | admin | admin |
| `blood_donors` | available donors (pub); own; admin | anon; self | own; admin | own; admin |
| `blood_requests` | active (pub); admin | anon; authenticated | admin | admin |
| `emergency_hotlines` | pub | admin | admin | admin |
| `emergency_sms` | own; admin | anon; authenticated | — | — |

`reviews_update_own_pending` (`rls_policies.sql:718`) is the one policy whose
predicate encodes a *business* rule rather than an ownership rule: once a review
is approved, the author can no longer silently rewrite it. Part 12 item 18 adds
the edit window and `edited_at` audit on top.

### 2.5 Notifications, devices, audit

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `notifications` | own | **nobody** | own (`is_read` only, in practice) | own |
| `device_tokens` | own | own | own | own |
| `audit_log` | admin | — (triggers) | — | — |
| `app_audit_log` | own; admin | self | — | — |

**`notifications` having no INSERT policy for any role is the single most
important row in this document.** Part 05 §1 explains why in full: a server event
notifies a *different* user than the actor, so any insert policy expressible in
terms of `auth.uid()` is either impossible-to-use or forgeable. Rows arrive only
via `public.notify()` (`schema.sql:1553`), which is `security definer` and has
`EXECUTE` revoked from `public, anon, authenticated` (`schema.sql:1578`).

`device_tokens` has no admin read policy, by design. A push token is a device
identifier; an admin has no operational reason to enumerate handsets.

`audit_log` is admin-read and nobody-write. It is written by triggers whose
function owner bypasses RLS. An audit trail the audited party can edit is not an
audit trail.

---

## 3. New policies for what Parts 01 and 12 add

Append these to `rls_policies.sql` in a new `PART 12` block, and mirror them into
a migration so a fresh bootstrap gets them. Each is per-command and reuses the
existing helpers.

### 3.1 `commission_settings` (Part 01, driven by Part 04 §4)

Admin sets a percentage per category. Everyone must be able to *read* it — the
booking screen shows the fee breakdown before the row exists — and only an admin
may write it.

```sql
alter table public.commission_settings enable row level security;

-- Public read: the patient sees "platform fee 2%" on the booking sheet, and
-- an unauthenticated visitor comparing doctors sees the same total.
create policy commission_settings_select_public
  on public.commission_settings for select to anon, authenticated
  using (true);

create policy commission_settings_insert_admin
  on public.commission_settings for insert to authenticated
  with check (public.is_admin());

create policy commission_settings_update_admin
  on public.commission_settings for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- No delete policy. A category's history is referenced by frozen rows on
-- appointments; deleting the setting would orphan the explanation of a past
-- split. Deactivate instead (`is_active = false`).
```

### 3.2 `appointments.hold_expires_at` (Part 12 §4.1)

No new policy. The column travels with the row, so
`appointments_select_patient` already covers reading it, and the client never
writes it — `appointments_book()` sets it and the `pg_cron` sweep clears it.
Confirm the column guard lists it as client-immutable.

### 3.3 `provider_blackouts` (Part 09, referenced by Part 12 item 4)

```sql
alter table public.provider_blackouts enable row level security;

-- Public read so the slot picker can grey out a holiday without a round trip
-- through a privileged function.
create policy blackouts_select_public
  on public.provider_blackouts for select to anon, authenticated
  using (true);

create policy blackouts_insert_own
  on public.provider_blackouts for insert to authenticated
  with check (doctor_id = public.current_doctor_id());

create policy blackouts_update_own
  on public.provider_blackouts for update to authenticated
  using (doctor_id = public.current_doctor_id())
  with check (doctor_id = public.current_doctor_id());

create policy blackouts_delete_own
  on public.provider_blackouts for delete to authenticated
  using (doctor_id = public.current_doctor_id());

create policy blackouts_update_admin
  on public.provider_blackouts for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
```

Note the `insert` check compares to `current_doctor_id()`, which is NULL for a
suspended user — `doctor_id = NULL` is NULL, not true, so the policy denies. That
is the intended behaviour and the reason not to hand-roll the join.

### 3.4 `notification_preferences` (Part 05 §8)

```sql
alter table public.notification_preferences enable row level security;

create policy notif_prefs_select_own
  on public.notification_preferences for select to authenticated
  using (user_id = (select auth.uid()));

create policy notif_prefs_insert_own
  on public.notification_preferences for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy notif_prefs_update_own
  on public.notification_preferences for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy notif_prefs_delete_own
  on public.notification_preferences for delete to authenticated
  using (user_id = (select auth.uid()));
```

`(select auth.uid())` rather than bare `auth.uid()` is the existing convention
throughout `rls_policies.sql`, and it is a performance decision: wrapping it in a
subquery lets the planner treat it as a one-time `InitPlan` instead of
re-evaluating per row.

### 3.5 `prescriptions` (Part 09)

A prescription image is medical data. Owner plus the fulfilling pharmacy plus
admin, never public.

```sql
alter table public.prescriptions enable row level security;

create policy prescriptions_select_own
  on public.prescriptions for select to authenticated
  using (user_id = (select auth.uid()));

create policy prescriptions_select_pharmacy
  on public.prescriptions for select to authenticated
  using (exists (
    select 1 from public.orders o
     where o.id = prescriptions.order_id
       and o.pharmacy_id = public.current_pharmacy_id()));

create policy prescriptions_select_admin
  on public.prescriptions for select to authenticated
  using (public.is_admin());

create policy prescriptions_insert_own
  on public.prescriptions for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy prescriptions_delete_own
  on public.prescriptions for delete to authenticated
  using (user_id = (select auth.uid()) and order_id is null);
```

The `order_id is null` clause on delete matters: a prescription attached to a
placed order is a compliance record and must survive the patient changing their
mind.

### 3.6 Verification queries to run after applying

`rls_policies.sql` PART 11 already carries a read-only verification block.
Extend it:

```sql
-- Every RLS-enabled table has at least one policy. A table with RLS on and no
-- policy denies everything, which usually means someone forgot a step.
select c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relrowsecurity
   and not exists (select 1 from pg_policies p
                    where p.schemaname = 'public' and p.tablename = c.relname)
 order by 1;

-- No FOR ALL policy anywhere (§1.2).
select tablename, policyname from pg_policies
 where schemaname = 'public' and cmd = 'ALL' order by 1, 2;

-- notifications must have no INSERT policy (§2.5).
select policyname from pg_policies
 where schemaname = 'public' and tablename = 'notifications' and cmd = 'INSERT';
```

All three must return zero rows.

---

## 4. Storage

`supabase/storage_setup.sql` is the authority. It contains **no INSERT** — bucket
rows are created by hand via the Dashboard or CLI (its PART 0 explains the
reasoning and gives both routes). This section specifies what the buckets must
be and what the Dart layer must do.

### 4.1 The four buckets

| Bucket | Public | Size limit | MIME allowlist | Path convention | Backing columns |
|---|---|---:|---|---|---|
| `avatars` | yes | 2 MB | `image/jpeg`, `image/png`, `image/webp` | `<user_uuid>/<filename>` | `users.profile_image` |
| `provider-documents` | **no** | 8 MB | above + `application/pdf` | `<user_uuid>/<filename>` | `doctors.bmdc_certificate`, `hospitals.license_document`, `clinics.license_document`, `pharmacies.license_document` |
| `product-images` | yes | 2 MB | `image/jpeg`, `image/png`, `image/webp` | `<pharmacy_id>/<filename>` | `pharmacy_products.image` |
| `blog-covers` | yes | 4 MB | `image/jpeg`, `image/png`, `image/webp` | `<filename>` (flat) | `blogs.cover_image` |

The MIME allowlist and the size limit are enforced by the bucket row, not by the
policies, and therefore apply to *every* client including a raw `curl`. Setting
them only in Dart would be advisory. `20260806000011_storage_bucket_limits.sql`
already exists — check it applied.

`provider-documents` is private because a BMDC certificate and a trade licence
are identity documents. In a public bucket every object is readable by anyone
who can guess or is handed the URL, with no token and no log. Read it through
`createSignedUrl` with a short expiry (600 s is enough for an admin to look at a
licence) in `admin_providers_screen.dart`.

### 4.2 The path convention is a contract, not a style

Storage has no foreign keys. The only thing a policy can reason about is the
object's own name, via `storage.foldername(name)`, which splits it into a
`text[]`. Putting the owner's id in the **first** segment is what makes "you may
only write your own files" expressible at all:

```sql
create policy avatars_insert_own
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
```

(`storage_setup.sql:174`.) If Dart uploads to a different shape the policy
rejects it with a 403 that looks like a permissions bug and is actually a naming
bug. `product-images` keys on `current_pharmacy_id()::text` instead — the owner
there is a pharmacy row, not a user (`storage_setup.sql:264`). `blog-covers` is
flat and gates on `is_admin()` because authoring is admin-only.

### 4.3 How Dart must build paths

One helper, used everywhere. Add it to `core/storage/` beside `secure_store.dart`
rather than letting each feature concatenate strings.

```dart
/// Object paths for the four buckets. The first segment is what the storage
/// policies match against (storage_setup.sql PART 2-5), so every path is built
/// here and nowhere else.
class StoragePaths {
  const StoragePaths._();

  /// `<uid>/avatar_<millis>.<ext>` — the timestamp defeats CDN caching of a
  /// replaced photo without needing a cache-busting query string, which the
  /// public URL form does not carry reliably.
  static String avatar(String userId, String ext) =>
      '$userId/avatar_${DateTime.now().millisecondsSinceEpoch}.$ext';

  /// `<uid>/<kind>.<ext>` — stable, so re-uploading a document replaces it
  /// (upsert: true) rather than accumulating orphans an admin must sift.
  static String providerDocument(String userId, String kind, String ext) =>
      '$userId/$kind.$ext';

  /// `<pharmacyId>/<productId>_<millis>.<ext>`
  static String productImage(int pharmacyId, int productId, String ext) =>
      '$pharmacyId/${productId}_${DateTime.now().millisecondsSinceEpoch}.$ext';

  static String blogCover(String slug, String ext) => '$slug.$ext';
}
```

**Store the path, never the URL.** Every one of the seven backing columns holds
an object path such as `3f9a.../avatar.jpg`. A URL embeds the project ref and the
CDN host; a path survives both changing. Repositories map path → absolute URL via
`SupabaseStorage` at read time, before the model is constructed.

### 4.4 Legacy PHP-era values, and why nothing crashes

Rows migrated from MySQL carry values like `uploads/avatars/12.jpg`. **These match
no object in any bucket** — the PHP site stored them, and its files were never
copied. `AppConfig.resolveAsset()` (`app/lib/core/constants/app_config.dart:181`)
returns `''` for anything that is not already `http://` or `https://`:

```dart
static String resolveAsset(String? path) {
  if (path == null) return '';
  final p = path.trim();
  if (p.isEmpty) return '';
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  return '';
}
```

`RemoteImage` and `AvatarCircle` (`core/widgets/state_views.dart:228` and `:280`,
used at 26 sites) draw their placeholder for an empty URL. So a legacy row
renders an initials avatar rather than firing a request that 404s. **Do not
"fix" `resolveAsset` to prefix a bucket** — it receives only a path and cannot
know which bucket it belongs to; that mapping happens one layer down, in the
repository. Changing it would turn 26 placeholders into 26 broken-image icons.

### 4.5 Client-side compression is mandatory

Master plan §2 Q2: the free tier is 1 GB of storage and 2 GB of egress per
month. A 12-megapixel phone photo is roughly 4 MB. **Two hundred and fifty
avatars would exhaust the entire quota**, and egress dies first — every list
screen that shows an avatar pays for the full-resolution download.

Rules, enforced before the upload call, not after:

| Bucket | Max long edge | JPEG quality | Target bytes | Reject above |
|---|---:|---:|---:|---:|
| `avatars` | 512 px | 80 | ~60 KB | 2 MB |
| `product-images` | 1024 px | 82 | ~150 KB | 2 MB |
| `blog-covers` | 1600 px | 82 | ~300 KB | 4 MB |
| `provider-documents` | 2048 px (images) | 85 | ~500 KB | 8 MB |

`provider-documents` gets the largest budget because an admin must read a
registration number off a licence photograph; over-compressing it defeats the
purpose of collecting it. PDFs pass through untouched.

Implementation: decode with `package:image` or `dart:ui`'s
`instantiateImageCodec` with `targetWidth`, re-encode as JPEG, then upload the
bytes with `uploadBinary`. Do the work off the UI isolate (`compute`) — decoding
a 12 MP image on the main isolate drops frames visibly. If the result still
exceeds the reject threshold, show a localized "This image is too large" message
rather than letting the server return an opaque 413.

### 4.6 Images only. Leave the schema video-ready

Master plan §2 Q2 forbids video on the free tier: a 60-second clip is 30–60 MB,
twenty of them exhaust the storage quota, and the egress bill arrives first.

Do not add a video bucket. Do add the column now, so enabling video later is a
feature flag rather than a migration against live data:

```sql
-- Part 01 adds this alongside each media-bearing column.
alter table public.pharmacy_products
  add column if not exists media_type varchar(10) not null default 'image'
  check (media_type in ('image', 'video'));

comment on column public.pharmacy_products.media_type is
  'Always ''image'' today. Reserved so video can be enabled on a paid plan or
   an external host without a migration on a populated table.';
```

The Dart model reads it and the UI branches on it, defaulting to the image
widget. A `video` value with no player wired must render the image placeholder,
never a crash.

---

## 5. Edge Functions

### 5.1 Correction to the master plan's inventory

Master plan §1 lists **four** Edge Functions. On disk there are **two with
code**:

```
supabase/functions/create-checkout-session/index.ts   553 lines
supabase/functions/stripe-webhook/index.ts            559 lines
```

`create-payment-intent/` and `payment-webhook/` were **empty directories** —
named in the plan, containing no `index.ts`, and now absent from the working
tree entirely. `PAYMENT_ARCHITECTURE_FIX.md:365` recorded this and §7.3 of that
document required their deletion, because `supabase functions deploy` iterating
the directory fails on a function with no entrypoint.

**Action: confirm neither directory exists before deploying. Do not recreate
them.** Their absence is also a security fact worth stating: there is no
alternate, unguarded payment entrypoint.

### 5.2 `create-checkout-session`

**Purpose.** Start — or re-open — a Stripe Checkout Session for one appointment.

**Invoked by** `PaymentService.startCardCheckout()`
(`app/lib/features/payment/data/payment_service.dart:240`) via
`_sb.functionsInvoke`. That is the only caller in the repo.

**Request** (`POST`, `Authorization: Bearer <user JWT>`):

```json
{ "appointment_id": 123, "return_target": "ayurbd" }
```

**Response, success:**

```json
{ "success": true,
  "data": { "checkout_url": "https://checkout.stripe.com/c/pay/cs_test_...",
            "session_id": "cs_test_...", "reused": false } }
```

**Response, failure:**

```json
{ "success": false, "code": "APPOINTMENT_NOT_PAYABLE",
  "message": "This appointment is no longer available for payment.",
  "details": { } }
```

The response shape is frozen — `payment_service.dart:255-300` reads exactly
these keys, and `PaymentService.failureForCode()` (`:320`) branches on `code`.
Adding a field is safe; renaming one is not.

**Authorisation.** The function does **not** decide payability. It calls
`public.gateway_payment_begin()`, which re-checks ownership, takes an advisory
lock on the appointment, asserts payability through
`assert_appointment_payable()`, and returns a live `payment_sessions` row —
reusing an existing one when the patient taps twice. This is the fix for root
cause B in `PAYMENT_ARCHITECTURE_FIX.md` §1.B; the old in-function
`status !== "pending_payment"` comparison is what produced the reported
"Appointment is not awaiting payment" and must not come back.

**Input validation.**

| Field | Rule | On failure |
|---|---|---|
| `appointment_id` | present, integer, > 0 | `VALIDATION_ERROR`, 400 |
| `return_target` | string; passed through `resolveReturnTarget()` | silently falls back to `APP_URL` |
| JWT | present and valid; user id extracted server-side | `UNAUTHORIZED`, 401 |

The patient id is never read from the body. It comes from the verified JWT.

**Secrets:** `STRIPE_SECRET_KEY`, `APP_URL`, `APP_WEB_ORIGINS`,
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`. Per **decision D2 the first three
stay EMPTY** until the user supplies them; the last two are injected by the
platform. With `STRIPE_SECRET_KEY` empty the function returns
`STRIPE_NOT_CONFIGURED`, which `failureForCode` maps to
`PaymentFailure.gatewayUnavailable`, which Part 04 §2 renders as the labelled
"Online card payment is not configured yet" state. **That path must be tested.**

### 5.3 The `return_target` allowlist

From `CONFIGURATION_AUDIT.md` §3 and §6. This is the part most likely to be
"simplified" by someone who does not see the attack.

A single server-side `APP_URL` cannot be right for both platforms at once. Set
it to the web dev origin (`http://localhost:62095`) and every Android user is
redirected to *the phone itself*. Set it to `ayurbd` and no browser can follow
it. The client is the only party that knows which it is — so it says, and the
function decides whether to believe it:

```ts
function resolveReturnTarget(requested: unknown, appUrl: string): string {
  const fallback = appUrl.trim();
  if (typeof requested !== "string") return fallback;
  const want = requested.trim().replace(/\/+$/, "");
  if (!want) return fallback;
  if (want === "ayurbd" || want === "ayurbd://") return "ayurbd";

  const allowed = new Set<string>();
  for (const raw of (Deno.env.get("APP_WEB_ORIGINS") || "").split(",")) {
    const o = raw.trim().replace(/\/+$/, "");
    if (o) allowed.add(o);
  }
  const configured = fallback.replace(/\/+$/, "");
  if (configured) allowed.add(configured);

  return allowed.has(want) ? want : fallback;
}
```

(`supabase/functions/create-checkout-session/index.ts:92`.)

**Why an allowlist and not a pass-through.** `success_url` ends up in a redirect
that carries `session_id` as a query parameter. Accepting an arbitrary origin
would let a caller aim that redirect — and the session id in it — at a host of
their choosing. Unrecognised values fall back to `APP_URL` rather than failing
the payment, which is exactly the behaviour that existed before the parameter
did, so an old client is unaffected.

The client half is `AppConfig.paymentReturnTarget`
(`app/lib/core/constants/app_config.dart:116`): `'ayurbd'` off web,
`Uri.base.origin` on web, `''` if `Uri.origin` throws. Computed rather than
hard-coded, so `flutter run`'s randomly chosen web port is always correct
without editing a constant.

`APP_WEB_ORIGINS` is comma-separated. A realistic value once configured:

```
APP_WEB_ORIGINS=https://ayur.example.com,http://localhost:62095
```

### 5.4 `stripe-webhook`

**Purpose.** Receive Stripe events and settle the payment server-side.

**Request.** Stripe `POST` with a `stripe-signature` header. **No user JWT** —
this function must be deployed with `--no-verify-jwt`, or Stripe's unauthorised
POST is rejected before the handler runs.

**Events handled:** `checkout.session.completed`,
`checkout.session.expired`, `payment_intent.payment_failed`,
`charge.refunded`.

**Validation.** Signature verified with `constructEventAsync` (the async form —
Deno's Web Crypto has no synchronous HMAC, and the sync `constructEvent` throws
in this runtime). An unsigned or mis-signed body is a 400 and nothing is written.

**Retry semantics — the important part.** Root cause K
(`PAYMENT_ARCHITECTURE_FIX.md` §1.K) was that any RPC failure was logged and
answered `200`. To Stripe, `2xx` means *never redeliver*. A transient database
error during `checkout.session.completed` therefore lost the confirmation
permanently: money captured, appointment never confirmed, no retry, no alert.

The rule now:

| Outcome | HTTP | Effect |
|---|---:|---|
| Settled, or duplicate event (already settled) | 200 | Stripe stops |
| Terminal SQLSTATE — `PGRST116`, `42501`, `P0001`, `22023`, `22P02` | 200 | Stripe stops, **critical reconciliation log written** — retrying cannot help |
| Anything else (timeouts, connection loss, 5xx) | **500** | Stripe redelivers with backoff |
| Bad signature | 400 | Stripe stops |

Idempotency: a duplicate `checkout.session.completed` is a no-op, backstopped by
`uq_payments_gateway_txn` (`schema.sql:649`), a unique index on
`gateway_transaction_id`.

**Secrets:** `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
`SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`. The first two are **EMPTY per D2**.

**Known gap to carry forward:** terminal failures write a log, not an alarm.
Nothing pages a human (`PAYMENT_ARCHITECTURE_FIX.md` §7.6). Part 10 gives the
admin console a "payment reconciliation" screen reading those rows so the log has
a reader.

### 5.5 General Edge Function rules

1. **Never read the caller's identity from the body.** Extract it from the
   verified JWT. `appointment_id` in the body plus `patient_id` in the body is
   an authorisation bug waiting to be found.
2. **Never re-implement a database rule in TypeScript.** Call the RPC. A check
   in an Edge Function is advisory — it cannot stop the PostgREST endpoints, and
   it drifts from the database the moment either side changes. That is root
   cause B, in one sentence.
3. **CORS.** The existing `corsHeaders` uses `Access-Control-Allow-Origin: *`,
   which is acceptable because every response is either a preflight or requires
   a Bearer token that a cross-origin page cannot mint. Do not add credentials
   to that combination.
4. **Return the envelope, always.** `{ success, data }` or
   `{ success, code, message, details }`. Dart branches on `success` and `code`,
   never on HTTP status alone.
5. **Log with the appointment id and never the payload.** A Stripe event body
   contains a customer email.

---

## 6. Rate limiting

### 6.1 The exposure, stated precisely

`users_select_public_providers` (`rls_policies.sql:221`) publishes the name,
photo and — through the joined `doctors` row — the **phone number and chamber
address** of every verified doctor to `anon`. That is deliberate; a patient must
be able to ring the chamber. But PostgREST accepts `?limit=1000&offset=N` from
anyone holding the publishable key, which ships in the APK. A scraper needs no
account, no session and no cleverness: three requests and it holds the phone
number of every doctor on the platform.

RLS cannot help. Each individual row is one the policy genuinely permits. The
problem is the *rate*, and rate is not a row predicate.

Be honest about what this means: **you cannot make a public directory
unscrapeable.** The goal is to make bulk extraction slow and noisy enough to be
unattractive, and to detect it.

### 6.2 What Supabase gives you free, and what it does not

| Mechanism | Free tier | Verdict |
|---|---|---|
| Postgres statement timeout | yes | Stops runaway queries, not enumeration |
| Kong/gateway rate limiting | **no** — Team plan and above | Unavailable |
| Supabase WAF / Cloudflare rules | **no** — paid | Unavailable |
| Auth rate limits (sign-in, OTP, recovery) | yes, built in | Already protects the auth endpoints |
| Postgres-side counter table + trigger | yes | **Usable.** §6.3 |
| Edge Function as a throttled read proxy | yes (500k invocations/month) | **Usable.** §6.4 |
| `pg_cron` sweep of the counter table | yes | Needed to stop it growing |

The auth endpoints are already covered — GoTrue's own limits apply on the free
tier, which is why §5 of Part 03 does not re-specify them.

### 6.3 The free approach: a counter table plus a gate function

Do not put a trigger on `SELECT` — Postgres has no `BEFORE SELECT` trigger. Route
the sensitive read through a `security definer` function that counts calls first.
The directory list stays on the fast PostgREST path; **only the phone number
moves behind the gate.**

```sql
-- One row per (identity, action, minute bucket). Small, and swept hourly.
create table if not exists public.rate_limit_counters (
  identity   text        not null,
  action     text        not null,
  bucket     timestamptz not null,
  hits       integer     not null default 0,
  primary key (identity, action, bucket)
);

alter table public.rate_limit_counters enable row level security;
-- No policy at all: only SECURITY DEFINER functions touch it.

comment on table public.rate_limit_counters is
  'Rate-limit ledger. No RLS policy by design — the gate function owns it.';

create or replace function public.rate_limit_hit(
  p_action text,
  p_limit  integer,
  p_window interval default interval '1 minute'
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_identity text;
  v_bucket   timestamptz;
  v_hits     integer;
begin
  -- Anonymous callers share one bucket per action. That is coarse and it is
  -- the point: an unauthenticated scraper cannot fragment its own quota, and
  -- we have no per-caller identity to key on without an IP, which PostgREST
  -- does not forward.
  v_identity := coalesce(auth.uid()::text, 'anon');
  v_bucket   := date_trunc('minute', now());

  insert into public.rate_limit_counters (identity, action, bucket, hits)
  values (v_identity, p_action, v_bucket, 1)
  on conflict (identity, action, bucket)
  do update set hits = public.rate_limit_counters.hits + 1
  returning hits into v_hits;

  return v_hits <= p_limit;
end;
$$;

revoke all on function public.rate_limit_hit(text, integer, interval)
  from public, anon, authenticated;
```

The gated read:

```sql
create or replace function public.doctor_contact(p_doctor_id bigint)
returns table (phone text, chamber_address text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.rate_limit_hit('doctor_contact', 20) then
    raise exception 'Too many requests. Please wait a moment.'
      using errcode = 'P0001', detail = 'RATE_LIMITED';
  end if;

  return query
    select u.phone::text, d.chamber_address::text
      from public.doctors d
      join public.users u on u.id = d.user_id
     where d.id = p_doctor_id
       and d.verification_status = 'verified'
       and not coalesce(d.is_deleted, false);
end;
$$;

grant execute on function public.doctor_contact(bigint) to anon, authenticated;
```

Then **remove `phone` and `chamber_address` from the columns
`users_select_public_providers` and `doctors_select_public` expose**, so the
directory list carries everything needed to browse and compare but the contact
details require one gated call per doctor. Twenty per minute is generous for a
human and ruinous for a scraper that wants six hundred.

`SupabaseService.guard()` maps `P0001` to a 422 and passes the message through,
so `ApiException.message` already reaches the UI — Part 06 localizes it via the
`RATE_LIMITED` detail code, not by matching the English text.

Sweep, so the table does not grow without bound:

```sql
select cron.schedule('rate-limit-sweep', '7 * * * *', $$
  delete from public.rate_limit_counters where bucket < now() - interval '2 hours';
$$);
```

**Honest limits of this design.** The counter is per-database, not per-IP, so
one aggressive user degrades every anonymous caller for that minute. It is a
blunt instrument chosen because the sharp ones cost money. If anonymous access
proves to be the problem, the next free step is to require a session for
`doctor_contact` (`revoke execute ... from anon`), which at least attaches a
scrape to an account an admin can ban.

### 6.4 The Edge Function alternative

An Edge Function can see `x-forwarded-for` and throttle per IP, which the
database cannot. It costs one invocation per read out of 500 000 free per month
and adds ~100 ms. Worth it only for the highest-value endpoint. Same counter
table, same function, keyed on the forwarded IP instead of `auth.uid()`. Specify
it as a documented option, not the default — the Postgres gate is fewer moving
parts.

### 6.5 What genuinely needs a paid tier

State these plainly rather than pretending the free design covers them:

- **Per-IP limiting at the gateway**, before a request reaches Postgres. Team
  plan.
- **WAF rules, bot detection, geo-blocking.** Paid.
- **Log-based alerting** on a spike in `doctor_contact` refusals. The free tier
  keeps 1 day of logs and has no alerting.
- **Read replicas** so a scrape cannot degrade interactive traffic.

---

## 7. Deploy runbook

Run from the repository root. `supabase link` has already been done — the
project ref is in `supabase/.temp/project-ref`.

### 7.1 Prerequisites

```bash
supabase --version                  # >= 1.180
supabase projects list              # confirms auth
supabase link --project-ref cbmmhygivrejcjpfodkr   # only if .temp is missing
```

### 7.2 Migrations

```bash
# 1. See what the remote is missing. Read this before pushing anything.
supabase migration list

# 2. Dry run against a shadow database — catches syntax errors without touching
#    the project. This is the step that would have caught root cause D
#    (20260808000001 aborted on load and everything it defined was silently
#    absent at runtime).
supabase db push --dry-run

# 3. Apply.
supabase db push

# 4. Verify the tail landed.
supabase migration list | tail -5
```

**Never run `supabase/schema.sql` against a migrated database.** It is a second
source of truth and still contains pre-fix definitions of functions the
migrations corrected (`PAYMENT_ARCHITECTURE_FIX.md` §1.J, §7.2). Applying it
after the migrations *regresses* the payment fix. It is a bootstrap-only file,
and the long-term remedy recorded there is to regenerate it with
`supabase db dump --schema public` from a migrated instance.

RLS and storage policies are not migrations. Apply them explicitly, in order:

```bash
psql "$SUPABASE_DB_URL" -f supabase/rls_policies.sql
psql "$SUPABASE_DB_URL" -f supabase/storage_setup.sql
```

Both files are re-runnable — each drops its own policies by name before
recreating them, and touches nothing belonging to Supabase.

### 7.3 Buckets (manual, once)

`storage_setup.sql` contains no INSERT (R1). Create the buckets first:

```bash
supabase storage create-bucket avatars            --public
supabase storage create-bucket product-images     --public
supabase storage create-bucket blog-covers        --public
supabase storage create-bucket provider-documents            # NOT public
```

Then confirm, and check `provider-documents` is private before continuing:

```sql
select id, public, file_size_limit, allowed_mime_types
  from storage.buckets order by id;
```

### 7.4 Edge Functions

```bash
# Confirm only the two real functions exist (§5.1).
ls supabase/functions

supabase functions deploy create-checkout-session
supabase functions deploy stripe-webhook --no-verify-jwt
```

`--no-verify-jwt` on the webhook is mandatory and only there: Stripe posts with
a `stripe-signature` header and no user JWT. Omit it and every event is rejected
before the handler runs. Never pass it to `create-checkout-session`.

### 7.5 Secrets

Per **D2, set these to empty strings now** and re-run the command with real
values when the user provides them. Setting an empty value is deliberate — it
makes the slot visible in `supabase secrets list` instead of leaving a
mystery-shaped absence.

```bash
supabase secrets set STRIPE_SECRET_KEY=""
supabase secrets set STRIPE_WEBHOOK_SECRET=""
supabase secrets set APP_URL=""
supabase secrets set APP_WEB_ORIGINS=""

supabase secrets list     # names only; values are never echoed back
```

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected
by the platform. **Do not set them by hand and never place any of these in
`app_config.dart`** — R6, asserted at startup by
`AppConfig.assertValidBackendConfig()` (`app_config.dart:56`), which throws if
the shipped key looks like a secret.

When the real Stripe keys arrive:

```bash
supabase secrets set STRIPE_SECRET_KEY="sk_test_..."
supabase secrets set STRIPE_WEBHOOK_SECRET="whsec_..."
supabase secrets set APP_URL="https://ayur.example.com"
supabase secrets set APP_WEB_ORIGINS="https://ayur.example.com,http://localhost:62095"
supabase functions deploy create-checkout-session   # secrets are read at boot
supabase functions deploy stripe-webhook --no-verify-jwt
```

Redeploying after a secret change is required: a Deno isolate reads
`Deno.env` when it starts, so a running function keeps the old value.

### 7.6 Post-deploy verification

```bash
supabase functions logs create-checkout-session --limit 20
```

```sql
-- Helpers exist and are STABLE + SECURITY DEFINER.
select proname, provolatile, prosecdef from pg_proc
 where proname in ('is_admin','current_user_role','current_doctor_id','current_pharmacy_id');
-- expect provolatile = 's', prosecdef = t for all four

-- notify() is not executable by clients.
select has_function_privilege('authenticated',
  'public.notify(uuid,text,text,text,text,bigint)', 'execute');
-- expect false

-- The three §3.6 audit queries return zero rows.
```

And from the app: sign in, open a doctor, tap Pay. With `STRIPE_SECRET_KEY`
empty you must see the labelled "not configured" state from Part 04 §2 — not a
crash, not a blank screen, not a raw error string. **That is the acceptance test
for this whole part.**

### 7.7 Rollback

`supabase db push` has no undo. Before pushing anything to a project with real
data:

```bash
supabase db dump --data-only -f backup_$(date +%Y%m%d).sql
supabase db dump --schema public -f schema_$(date +%Y%m%d).sql
```

Roll a bad policy change back by re-running the previous `rls_policies.sql` from
git — it is idempotent, which is precisely why it drops before creating.





