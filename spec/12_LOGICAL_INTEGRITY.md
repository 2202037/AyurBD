# Part 12 — Logical Integrity

Subordinate to `spec/00_MASTER_PLAN.md`. Read that first. If this file appears
to contradict it, stop and report.

**This is Phase 2 — it runs before any feature work.** Master plan §5 explains
why: these constraints define what the application is *permitted* to do. Screens
written before the rules exist are written against rules that do not yet exist,
and retro-fitting them breaks flows that quietly depended on the gap.

---

## 0. The governing principle, and what it costs

> **A business rule enforced only in Dart is a rule that will eventually be
> violated.** Enforce every invariant in PostgreSQL — constraint, trigger, or
> `SECURITY DEFINER` function — and let the UI merely *predict* what the database
> will allow. The UI's job is to avoid ugly errors; the database's job is to make
> violations impossible.

The cost of this principle is that **users meet errors the UI did not anticipate**.
A patient who taps "confirm" 200 ms after someone else does will get a rejection
no amount of client-side checking could have prevented. So every rule in this
file is specified in six parts, and the last three are as mandatory as the first
three:

1. The invariant, in one plain-English sentence.
2. A concrete failure scenario with two actors and precise timing.
3. The exact DDL — complete and runnable, never a sketch.
4. The SQLSTATE it raises.
5. How `SupabaseService.guard()` maps it, and what the user reads in EN and BN.
6. A reproduction test proving the violation is rejected.

A constraint without step 5 produces `duplicate key value violates unique
constraint "uq_appointments_doctor_slot"` on a patient's phone. That is a bug,
not an enforcement.

---

## 1. Before you write anything: what already exists

**Eleven of the twenty-one are already enforced in this repository.** An agent who
skips this section will write duplicate constraints, and a duplicate partial
unique index on a hot table is not harmless — it doubles write cost and produces a
second, differently-named error the Dart layer does not recognise.

Verified by direct inspection on 2026-08-10.

| # | Contradiction | Status | Where |
|---:|---|---|---|
| 1 | Two patients book one slot | **Exists** (index); hold flow **missing** | `supabase/schema.sql:588` |
| 2 | Review before consultation | **Exists** | `supabase/schema.sql:2487` `guard_reviews_insert()` |
| 3 | Booking a doctor in the past | **Exists**, indirectly | `available_slots()` `schema.sql:2120` |
| 4 | Booking outside published hours | **Exists**, indirectly | same |
| 5 | Booking an unverified provider | **Exists** | `schema.sql:2213`, `payment_architecture_fix.sql:753` |
| 6 | Booking while another is unpaid | **Missing** | — |
| 7 | Two reviews for one appointment | **Exists** | `schema.sql:929` `uq_reviews_appointment` |
| 8 | Reviewing a provider never consulted | **Exists** | `schema.sql:2512` |
| 9 | Ordering more than stock | **Exists** | `place_order()` `schema.sql:2733` |
| 10 | Stock negative under concurrency | **Exists** | `pharmacy_products_stock_check` `:737` |
| 11 | Paying twice | **Exists** | `uq_payments_verified_appointment` `payment_architecture_fix.sql:590` |
| 12 | Commission not reconciling | **Exists** | `payments_split_check` `schema.sql:627` |
| 13 | Payout exceeding collected | **Partial** — uniqueness yes, amount no | `uq_provider_payouts_payment` `:894` |
| 14 | Privilege escalation | **Exists** | `guard_admin_only_columns()` `rls_policies.sql:102` |
| 15 | Price edited after booking | **Exists** | `appointments.fee` guarded, `rls_policies.sql:180` |
| 16 | Blood units negative | **Partial** — CHECK yes, no decrement path | `blood_banks_stock_non_negative` `:958` |
| 17 | Cancelling a completed appointment | **Exists** | `appointments_guard_transition()` `payment_architecture_fix.sql:661` |
| 18 | Editing a review years later | **Partial** — pending-only, no window | `reviews_update_own_pending` `rls_policies.sql:719` |
| 19 | Deleting a user with live appointments | **Wrong** — `CASCADE`, not `RESTRICT` | `schema.sql:549` |
| 20 | Blog published without moderation | **Exists** | `blogs_insert_admin` `rls_policies.sql:925` |
| 21 | Notification forged | **Exists** | no INSERT grant, `schema.sql:3381` |

So the work is: **six genuinely new enforcements** (6, 13, 16, 18, 19, and the
payment-hold half of 1), **six verifications** that must be run rather than
assumed, and **twenty-one bilingual error mappings**, most of which do not exist
yet because the app has no localization until Phase 5.

### The `schema.sql` trap

`supabase/schema.sql` is a **snapshot that predates the last migration**. Its
guard functions still contain `session_user <> 'authenticator'`, which
`20260809000002_payment_architecture_fix.sql` replaced with
`public.write_is_trusted()`. When the two disagree, **the migration is
authoritative**. Never copy a guard preamble out of `schema.sql`.

---

## 2. The error contract — read this before any DDL

Every rule below ends in a SQLSTATE. `SupabaseService.guard()`
(`app/lib/core/network/supabase_service.dart:86`) already maps them; this section
records the mapping so no rule invents a new one.

| SQLSTATE | Raised by | `guard()` maps to | `ApiException` |
|---|---|---|---|
| `23505` | unique / partial-unique index violation | `_fromPostgrest` case `'23505'` (`:200`) | `statusCode 409`, message from `_uniqueMessage()` |
| `23514` | `CHECK` constraint | case `'23514'` (`:226`) | `statusCode 422`, message = raw |
| `23P01` | `EXCLUDE` constraint | **unmapped** — falls to the default at `:267` | `statusCode 400`, message = raw |
| `23503` | foreign key | case `'23503'` (`:209`) | `409`, "That item no longer exists." |
| `42501` | `raise ... using errcode = '42501'`, and RLS refusal | case `'42501'` (`:189`) | `403` |
| `P0001` | bare `raise exception` in PL/pgSQL | case `'P0001'` (`:238`) | `422`, message passed through verbatim |
| `22P02` | invalid enum input | case `'22P02'` (`:227`) | `422` |

Three facts about that mapping decide how every rule below is written.

**First: `P0001` passes the message through verbatim to the user.** Look at
`supabase_service.dart:238-243` — for `P0001` the raw database message *is* the
sentence shown. So a `raise exception` message is user-facing copy and must be
written as such. `'appt % invalid'` is a bug.

**Second: the DETAIL field carries a machine code.** `_detailCode()`
(`:281`) accepts only `SHOUTING_SNAKE_CASE`, at most 64 characters, and puts it
on `ApiException.code`. `api_exception.dart:34` says why: *"Screens should branch
on this rather than on [message]: the wording is written for people and is
expected to change, while the code is a contract."* **Every rule in this file
raises with a DETAIL code.** That is what makes bilingual messaging possible at
all — the Dart layer keys the ARB lookup off the code, not off English text.

**Third: `_uniqueMessage()` matches on constraint names that do not all exist.**
`supabase_service.dart:329` tests for `appointments_no_double_booking` and
`uniq_doctor_slot`. The real index is **`uq_appointments_doctor_slot`**
(`schema.sql:588`). Neither string matches it, so a real double-booking collision
currently falls through to `'That already exists.'` — the single most important
error in the application, and it is wrong today. §3 fixes it.

### The bilingual pattern every rule uses

Localization does not exist until Phase 5 (Part 06), so this file specifies the
*keys* and the *strings*, and Part 06 places them in the ARB files. The pattern:

```dart
// app/lib/core/network/integrity_errors.dart  (new file, Part 06 wires l10n)
//
// Maps a database DETAIL code to an ARB key. The database sends a code;
// the UI decides the language. No English travels from server to screen.
const Map<String, String> kIntegrityErrorKeys = {
  'SLOT_TAKEN'        : 'errSlotTaken',
  'UNPAID_HOLD'       : 'errUnpaidHold',
  'REVIEW_TOO_EARLY'  : 'errReviewTooEarly',
  // ... one entry per rule below
};

/// Resolve an ApiException to a localized sentence.
///
/// Falls back to [e.message] when the code is unknown, because a P0001
/// message is already a human sentence (in English) and showing it beats
/// showing nothing.
String localizeIntegrityError(BuildContext context, ApiException e) {
  final key = e.code == null ? null : kIntegrityErrorKeys[e.code];
  if (key == null) return e.message;
  return AppLocalizations.of(context)!.byKey(key);
}
```

Each rule below gives its DETAIL code, its ARB key, and both strings.

---

## 3. Contradiction #1 — two patients cannot book the same slot

### The invariant

One doctor cannot hold two live appointments at the same date and time.

### The failure scenario

Dr Rahman opens Thursday's chamber. Two patients are on the booking screen.

```
14:32:07.100  Ayesha's device:  select * from available_slots(7, '2026-08-14')
                                -> [09:00, 09:30, 10:00, 10:30, ...]
14:32:07.140  Karim's device:   select * from available_slots(7, '2026-08-14')
                                -> [09:00, 09:30, 10:00, 10:30, ...]   (same list)
14:32:11.902  Ayesha taps 10:00 -> appointments_book(7, '2026-08-14', '10:00')
14:32:11.955  Karim taps 10:00  -> appointments_book(7, '2026-08-14', '10:00')
```

Both `available_slots()` calls returned 10:00, because at the moment each ran,
10:00 genuinely was free. 53 milliseconds separate the two writes.

**A `not exists` check inside the booking function does not fix this.** Under
`READ COMMITTED` — PostgreSQL's default, and what PostgREST uses — Karim's
subquery at 14:32:11.955 cannot see Ayesha's row, because her transaction has not
committed. Both checks pass. Both rows land. Dr Rahman has two patients in one
chair and neither was told.

`appointments_book()` runs exactly this check at
`supabase/migrations/20260809000002_payment_architecture_fix.sql:764`. It is a
UX filter, not a guarantee, and the comment there says so.

Only a unique index closes it: uniqueness is enforced at the index level *after*
the row is written, so Karim's insert blocks on Ayesha's uncommitted index entry
and then fails the moment she commits.

### The DDL — already present, do not re-create

```sql
-- supabase/schema.sql:588 -- EXISTS. Reproduced for reference only.
create unique index uq_appointments_doctor_slot
  on public.appointments (doctor_id, appointment_date, appointment_time)
  where status not in ('cancelled', 'expired');
```

### Why the `WHERE` clause is essential

Without it the index would be over every row ever written, and a **cancelled
appointment would block its slot forever**. Ayesha books 10:00 and cancels an
hour later; the row stays in the table because it is a clinical and financial
record (`appointments.doctor_id` is `on delete restrict`, `schema.sql:552`). With
an unconditional unique index that dead row still owns `(7, 2026-08-14, 10:00)`
and no one can ever book 10:00 again. The doctor's Thursday silently loses a slot
per cancellation until the day is unbookable.

The predicate makes the index cover only *live* bookings, so cancelling genuinely
frees the slot — which is also exactly what `available_slots()` assumes at
`schema.sql:2126` (`a.status not in ('cancelled','expired')`). The two must list
the same statuses or the generator will offer a slot the index then refuses.

**This is the single most important line in the schema. Its predicate and
`available_slots()`'s predicate must be edited together, always.**

### SQLSTATE

`23505`, constraint name `uq_appointments_doctor_slot`.

### The Dart mapping — currently broken, fix it

`_uniqueMessage()` at `app/lib/core/network/supabase_service.dart:329` tests:

```dart
if (d.contains('appointments_no_double_booking') ||
    d.contains('uniq_doctor_slot')) {
  return 'That time slot has just been taken. Please pick another.';
}
```

Neither string is the real index name. Verify and fix:

```bash
cd "F:/Project folder/AyurBD"
grep -n "uq_appointments_doctor_slot" supabase/schema.sql
grep -n "uniq_doctor_slot\|appointments_no_double_booking" app/lib/core/network/supabase_service.dart
```

The edit — add the real name, **keep** the two legacy strings so an older
deployment still matches:

```dart
if (d.contains('uq_appointments_doctor_slot') ||        // the real index
    d.contains('appointments_no_double_booking') ||     // legacy, kept
    d.contains('uniq_doctor_slot')) {                   // legacy, kept
  return 'That time slot has just been taken. Please pick another.';
}
```

| Locale | String |
|---|---|
| ARB key | `errSlotTaken` |
| DETAIL code | `SLOT_TAKEN` |
| `en` | That time slot has just been taken. Please pick another. |
| `bn` | এই সময়টি এইমাত্র বুক হয়ে গেছে। অনুগ্রহ করে অন্য একটি সময় বেছে নিন। |

The booking screen must **re-fetch `available_slots()` on this error**, not just
show the message. The list the patient is looking at is now known to be stale;
leaving it on screen invites a second failure on the next tap.

### Reproduction test

Two concurrent sessions are required — a single-session test proves nothing,
because the second insert would see the first's committed row and be rejected by
the UX filter instead of by the index.

```sql
-- Session A                          -- Session B
begin;                                begin;
insert into public.appointments
  (patient_id, doctor_id, appointment_date, appointment_time, fee, status)
values ('<uuid-a>', 7, '2026-08-14', '10:00', 500, 'pending');
                                      insert into public.appointments
                                        (patient_id, doctor_id, appointment_date,
                                         appointment_time, fee, status)
                                      values ('<uuid-b>', 7, '2026-08-14',
                                              '10:00', 500, 'pending');
                                      -- BLOCKS here, waiting on A's index entry
commit;
                                      -- ERROR: 23505 duplicate key value
                                      -- violates unique constraint
                                      -- "uq_appointments_doctor_slot"
rollback;
rollback;   -- clean up: R1 permits no leftover rows
```

`insert into public.appointments` directly requires a non-client session:
`20260809000002_payment_architecture_fix.sql:539` revokes INSERT on
`appointments` from `anon, authenticated`. Run this as `postgres` in the SQL
editor, in two browser tabs.

**Proof that the `WHERE` clause works:**

```sql
begin;
  insert into public.appointments
    (patient_id, doctor_id, appointment_date, appointment_time, fee, status)
  values ('<uuid-a>', 7, '2026-08-15', '11:00', 500, 'cancelled');

  -- Must SUCCEED: the cancelled row is not in the index.
  insert into public.appointments
    (patient_id, doctor_id, appointment_date, appointment_time, fee, status)
  values ('<uuid-b>', 7, '2026-08-15', '11:00', 500, 'pending');
rollback;
```

If the second insert fails, the predicate has been dropped and every cancellation
is permanently burning a slot.

---

## 4. Contradiction #1b — the payment hold, and expiring it

### The problem the master plan calls out

> *the slot must be held during checkout but released if payment never completes.*

The two obvious designs are both wrong:

- **Insert the appointment only after payment succeeds.** Then the slot is free
  during the entire checkout, and a second patient can take it while the first is
  on the Stripe page. The first patient pays for a slot that no longer exists,
  and now you owe a refund.
- **Insert immediately and never expire it.** Then a patient who opens checkout
  and closes the app has silently removed a slot from the doctor's day forever.

The correct design is a **hold with a deadline**: the row exists (so the unique
index blocks everyone else) but it carries an expiry, and a sweeper releases it.

### What already exists

`appointments_book()` (`payment_architecture_fix.sql:775-790`) opens a fee-bearing
booking in `status='pending_payment'`. Since `'pending_payment'` is not in the
index's exclusion list (`cancelled`, `expired`), **the hold already blocks other
patients.** That half is done.

`expire_stale_appointments()` (`payment_architecture_fix.sql:1725`) sweeps
`'pending_payment'` rows — but only once the *appointment slot itself* is in the
past:

```sql
   where status in ('pending', 'pending_payment', 'confirmed')
     and payment_status = 'pending'
     and (appointment_date < current_date
          or (appointment_date = current_date
              and appointment_time < localtime));
```

So an abandoned checkout for **next Thursday** holds that slot for **six days**.
The sweep is also a statement-level trigger on `appointments`
(`schema.sql:3126`), which means it only runs when somebody else writes to the
table — a doctor with no other bookings never triggers the sweep at all.

Both gaps are real. This is the missing work for #1.

### The DDL

```sql
-- =====================================================================
-- 20260810000009_payment_hold_expiry.sql
--
-- A checkout hold that releases itself.
--
-- appointments_book() already opens a fee-bearing booking in
-- 'pending_payment', and uq_appointments_doctor_slot already covers that
-- status, so the slot is genuinely blocked during checkout. What was
-- missing is the deadline: expire_stale_appointments() only releases a
-- hold once the SLOT is in the past, so an abandoned checkout for next
-- week squats the slot for a week.
--
-- Structure only. No INSERT statements (master plan R1).
-- =====================================================================

alter table public.appointments
  add column if not exists hold_expires_at timestamptz;

comment on column public.appointments.hold_expires_at is
  'Deadline for a pending_payment hold. Past it, expire_payment_holds() releases the slot. NULL for every status except pending_payment.';

-- The hold is 15 minutes. Rationale: a bKash or Nagad app-switch round
-- trip on a slow Bangladeshi mobile connection is minutes, not seconds,
-- and Stripe Checkout sessions themselves default to 24h but are
-- realistically abandoned or completed inside 10. Fifteen is long
-- enough that no honest payer is cut off mid-flow and short enough that
-- a popular slot is not lost for an afternoon.
create or replace function public.appointments_set_hold_deadline()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'pending_payment' then
    -- Only on entry to the state, so a retry inside the window does not
    -- silently extend the hold indefinitely.
    if tg_op = 'INSERT' or old.status is distinct from 'pending_payment' then
      new.hold_expires_at := now() + interval '15 minutes';
    end if;
  else
    -- Leaving pending_payment (paid, cancelled, expired) clears it, so a
    -- stale deadline can never re-expire a live booking.
    new.hold_expires_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists ab_set_hold_deadline on public.appointments;
create trigger ab_set_hold_deadline
  before insert or update of status on public.appointments
  for each row execute function public.appointments_set_hold_deadline();
```

```sql
-- ---------------------------------------------------------------------
-- The sweeper. A standalone function, NOT folded into
-- expire_stale_appointments(): that one is a statement-level trigger and
-- only runs when something else writes to appointments. A hold must
-- expire on wall-clock time, whether or not anybody is using the app.
--
-- trusted_path_begin() is mandatory. Its UPDATE has to pass
-- appointments_guard_transition() (the state machine) and
-- guard_admin_only_columns(); without the marker the sweep would be
-- refused by the app's own guards. See
-- 20260809000002_payment_architecture_fix.sql:92 for the marker, and
-- :1735 for the same pattern in expire_stale_appointments().
-- ---------------------------------------------------------------------
create or replace function public.expire_payment_holds()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev  text;
  v_count integer;
begin
  v_prev := public.trusted_path_begin();

  with released as (
    update public.appointments
       set status          = 'expired',
           hold_expires_at = null
     where status          = 'pending_payment'
       and payment_status  = 'pending'
       and hold_expires_at is not null
       and hold_expires_at < now()
    returning id, patient_id
  )
  select count(*) into v_count from released;

  perform public.trusted_path_end(v_prev);
  return v_count;
end;
$$;

comment on function public.expire_payment_holds() is
  'Releases checkout holds whose 15-minute deadline has passed. Run every minute by pg_cron. Returns the number of slots freed.';

-- No client may run the sweeper: it moves appointments to a terminal
-- state, and the default privileges in 20260806000000_reset_public.sql
-- grant EXECUTE on new functions to anon/authenticated, so this revoke
-- is mandatory rather than decorative. Same reasoning as
-- 20260806000017_revoke_expire_stale_execute.sql.
revoke all on function public.expire_payment_holds()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- The index that makes the sweep cheap.
--
-- Query: the sweeper's own WHERE clause, run 1440 times a day. Without
-- a partial index this is a sequential scan of the whole appointments
-- table every minute, forever. The predicate keeps the index to exactly
-- the rows currently on hold -- a handful at any moment -- so it stays
-- tiny no matter how large the table grows.
-- ---------------------------------------------------------------------
create index if not exists idx_appointments_hold_expiry
  on public.appointments (hold_expires_at)
  where status = 'pending_payment' and hold_expires_at is not null;
```

### The pg_cron job

```sql
-- ---------------------------------------------------------------------
-- pg_cron. Available on Supabase but NOT enabled by default. This must
-- run in the `extensions` schema, which is where Supabase places every
-- extension (see schema.sql:149 for pgcrypto and :754 for pg_trgm).
--
-- If this CREATE EXTENSION fails, holds are never released and every
-- abandoned checkout permanently burns a slot. Do not treat a failure
-- here as cosmetic -- see the fallback below.
-- ---------------------------------------------------------------------
create extension if not exists pg_cron with schema extensions;

-- Unschedule first: cron.schedule raises on a duplicate jobname, which
-- would make this migration non-idempotent.
do $$
begin
  perform extensions.cron.unschedule('expire-payment-holds');
exception when others then
  null;   -- the job did not exist; that is the normal first-run path
end $$;

select extensions.cron.schedule(
  'expire-payment-holds',
  '* * * * *',                        -- every minute
  $job$ select public.expire_payment_holds(); $job$
);
```

**Verify the job is registered and is actually running:**

```sql
-- Expect one row, active = true.
select jobid, jobname, schedule, active, command
  from extensions.cron.job
 where jobname = 'expire-payment-holds';

-- Expect recent rows with status 'succeeded'. An empty result after a
-- few minutes means the job is registered but not firing.
select start_time, status, return_message
  from extensions.cron.job_run_details
 where jobid = (select jobid from extensions.cron.job
                 where jobname = 'expire-payment-holds')
 order by start_time desc
 limit 10;
```

### If pg_cron is unavailable

On some Supabase plans and on a local `supabase start`, `pg_cron` may not be
installable. **Say so in `IMPLEMENTATION_LOG.md` rather than pretending the sweep
runs.** The fallback, which must be specified as a fallback and not as the design:

```sql
-- FALLBACK ONLY, when pg_cron cannot be enabled. This is strictly worse:
-- it only runs when somebody writes to appointments, so a doctor with no
-- other traffic keeps a stale hold indefinitely. Use it to bound the
-- damage, not to close the gap.
create or replace function public.expire_payment_holds_trg()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('appointments.hold_sweep_lock', true) is not null then
    return null;
  end if;
  perform set_config('appointments.hold_sweep_lock', '1', true);
  perform public.expire_payment_holds();
  return null;
end;
$$;

drop trigger if exists zz_expire_holds on public.appointments;
create trigger zz_expire_holds
  after insert or update on public.appointments
  for each statement execute function public.expire_payment_holds_trg();
```

The re-entrancy flag is not optional — the sweeper's own `UPDATE` re-fires a
statement-level trigger on the same table, and without the flag it recurses to the
stack limit. This is the identical pattern `expire_stale_appointments()` uses at
`schema.sql:2799`.

### SQLSTATE and the user-visible behaviour

Expiry raises nothing. It is a background transition, so the patient learns about
it the next time they act. Two surfaces must handle it:

1. **Returning from the gateway after the hold expired.** The settlement path
   finds the appointment `expired` and refuses. `guard_payments_insert()`
   (`schema.sql:2404`) already raises `P0001` for a dead appointment. Add the
   DETAIL code so the message can be localized.
2. **The appointment list.** An expired hold must render as "expired", not
   silently vanish — a booking that disappears reads as a bug.

| Locale | String |
|---|---|
| ARB key | `errHoldExpired` |
| DETAIL code | `HOLD_EXPIRED` |
| `en` | Your reservation expired before payment completed and the slot was released. Please book again. |
| `bn` | পেমেন্ট সম্পন্ন হওয়ার আগেই আপনার সংরক্ষণের সময় শেষ হয়ে গেছে এবং সময়টি ছেড়ে দেওয়া হয়েছে। অনুগ্রহ করে আবার বুক করুন। |

**If money was actually captured**, do not show this message — that is a refund,
not an expiry. Part 04 §6 owns that path. The distinguishing test is whether a
`payments` row reached `payment_status='verified'`, not whether the appointment
expired.

### Reproduction test

```sql
begin;
  -- 1. A hold that is already stale.
  insert into public.appointments
    (patient_id, doctor_id, appointment_date, appointment_time, fee,
     status, payment_status)
  values ('<uuid-a>', 7, '2026-09-30', '10:00', 500,
          'pending_payment', 'pending');

  -- The trigger must have stamped a deadline ~15 minutes out.
  select id, status, hold_expires_at, hold_expires_at - now() as remaining
    from public.appointments where doctor_id = 7 and appointment_date = '2026-09-30';

  -- 2. Force it into the past.
  update public.appointments set hold_expires_at = now() - interval '1 minute'
   where doctor_id = 7 and appointment_date = '2026-09-30';

  -- 3. Sweep. Expect 1.
  select public.expire_payment_holds() as released;

  -- 4. Expect status 'expired' and hold_expires_at NULL.
  select id, status, hold_expires_at
    from public.appointments where doctor_id = 7 and appointment_date = '2026-09-30';

  -- 5. And the slot must now be re-bookable: 'expired' is excluded from
  --    uq_appointments_doctor_slot, so this must SUCCEED.
  insert into public.appointments
    (patient_id, doctor_id, appointment_date, appointment_time, fee,
     status, payment_status)
  values ('<uuid-b>', 7, '2026-09-30', '10:00', 500,
          'pending_payment', 'pending');
rollback;
```

Step 5 is the one that matters. A sweeper that expires the row but leaves the slot
blocked has made things worse than doing nothing.

---

## 5. Contradiction #2 — a review requires a consultation that has happened

### The invariant

A review may exist only if an appointment links this reviewer to this doctor, its
scheduled **end** time has passed in Asia/Dhaka, its status is `completed`, and no
review exists for it already.

### The failure scenario

Karim books Dr Rahman for 2026-08-14 at 10:00, fee ৳500. At 09:15 he decides the
clinic is too far and wants to punish it.

```
2026-08-14 09:15 Dhaka   Karim opens the doctor's page. Review button is disabled.
2026-08-14 09:15 Dhaka   Karim opens a REST client instead:

  POST /rest/v1/reviews
  Authorization: Bearer <his own valid JWT>
  {"user_id":"<karim>","reviewable_type":"doctor","reviewable_id":7,
   "appointment_id":9912,"rating":1,"comment":"terrible"}
```

He is authenticated. He owns the appointment. `reviews_insert_own`
(`supabase/rls_policies.sql:713`) checks only `user_id = auth.uid()`, which is
true. **RLS permits this row.** The consultation is 45 minutes in the future.

The rule is not expressible in RLS at all: RLS can see *who* is writing and *what*
the row says, but "has this consultation happened yet" is a fact about a different
table plus the clock. That is a trigger's job.

### What already exists — and the regression you must find before anything else

**Stop and read this. `supabase/schema.sql` will lie to you here.**

`schema.sql:2487` shows a `guard_reviews_insert()` that blocks Karim. But
`schema.sql` is a regenerated snapshot, and five migrations have redefined this
function. In filename order — which is apply order — they are:

| Migration | What it did to `guard_reviews_insert` |
|---|---|
| `20260806000001_schema.sql:2063` | created it; ownership check only |
| `20260806000003_payment_commission_reviews.sql:233` | **added** the "consultation must have happened" check |
| `20260806000004_guard_session_user_fix.sql:75` | swapped `current_user` for `session_user` |
| `20260806000014_dhaka_timezone_fix.sql:95` | **fixed** the comparison to `now() at time zone 'Asia/Dhaka'` |
| `20260809000002_payment_architecture_fix.sql:345` | **removed the timing check entirely** |

Read the live version, `20260809000002_payment_architecture_fix.sql:345`. Its
doctor branch is now only this:

```sql
    select exists (
      select 1 from public.appointments a
       where a.id = new.appointment_id
         and a.patient_id = (select auth.uid())
         and a.doctor_id  = new.reviewable_id
    ) into v_owned;
    if not v_owned then
      raise exception 'the appointment does not match the reviewed doctor'
        using errcode = '23505';
    end if;
```

No status test. No time test. **Contradiction #2 is currently unenforced in the
deployed database.** Karim's 09:15 REST call succeeds today. The last migration
rewrote the whole guard block to convert `session_user <> 'authenticator'` to
`public.write_is_trusted()` and, in retyping the body, dropped two conditions and
the `20260806000014` timezone fix with them.

This is the single most valuable thing in this section, and it is also the reason
Part 12 exists: **an invariant that lives only in a function body can be deleted
by an unrelated refactor and nothing will fail.** Confirm it yourself before
writing the fix:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "Asia/Dhaka" supabase/migrations/20260809000002_payment_architecture_fix.sql
# expect: no match inside guard_reviews_insert
```

Verify against the live database, which is the only authority:

```sql
select pg_get_functiondef('public.guard_reviews_insert()'::regprocedure)
  like '%Asia/Dhaka%' as timing_check_present;
-- expect false before this migration, true after
```

There is a second, deliberate divergence to reconcile. The comment above the
function in `schema.sql:2480` states:

> There is deliberately NO "must be completed" requirement: the product decision
> is that a review may be left at any time against an owned appointment

That comment contradicts master plan §3 row 2, which requires `status =
'completed'`. **The master plan is a locked decision (R9: enforce in the database,
not the UI) and wins.** Delete the stale comment when you replace the function so
the next reader is not sent back the other way.

### The two gaps in the strongest version that ever shipped

Even `20260806000014_dhaka_timezone_fix.sql:95` — the best version this schema has
ever had, and the one `schema.sql:2512` still displays — has two gaps. Restore it
*with these fixed*, do not simply revert:

```sql
    select exists (
      select 1 from public.appointments a
       where a.id = new.appointment_id
         and a.patient_id = (select auth.uid())
         and a.doctor_id  = new.reviewable_id
         and a.status not in ('cancelled', 'expired')
         and (a.appointment_date + a.appointment_time)
             < (now() at time zone 'Asia/Dhaka')
    ) into v_owned;
```

Three of the master plan's four conditions are there. Two things are wrong:

**Gap A — `status not in ('cancelled','expired')` is not `status = 'completed'`.**
An appointment sitting at `pending` or `pending_payment` whose slot time has
passed satisfies this test. So a patient who booked, never paid, never attended,
and whose booking has not yet been swept to `expired` can review the doctor. The
master plan's condition 3 says `completed`, and `completed` is a state only the
doctor can set (`appointments_guard_transition()`,
`20260809000002_payment_architecture_fix.sql:683`) — which is exactly the point.
A review should require the *provider's* attestation that the consultation
happened, not merely that its clock time went by.

**Gap B — it compares against the appointment's START time.** A 10:00 slot passes
this test at 10:00:01, while the patient is still in the waiting room. The
scheduled *end* is start + the doctor's slot length
(`doctors.slot_minutes`, `schema.sql:342`, default 30).

**Also worth noting, and correct as-is:** the fourth condition ("no review
already") is enforced by `uq_reviews_appointment` (`schema.sql:929`) rather than
by the trigger. That works, but it surfaces as a bare `23505` whose constraint
name `_uniqueMessage()` does not recognise, so the patient reads *"That already
exists."* The replacement below checks it in the trigger so the message is right.

### The timezone trap — and why the usual description of it is backwards

The comparison is `timestamp < timestamp`:

- `(a.appointment_date + a.appointment_time)` is `date + time` → a **`timestamp`
  without time zone**, holding Dhaka wall-clock: `2026-08-14 10:00`.
- `now() at time zone 'Asia/Dhaka'` converts the current instant into **Dhaka
  wall-clock**, also a `timestamp`.

Both sides are the same kind of quantity, so the comparison is right. Now consider
the ways to get it wrong, because each one fails in a different direction:

| Written as | What Postgres does | When the review unlocks | Direction |
|---|---|---|---|
| `... < now() at time zone 'Asia/Dhaka'` | timestamp vs timestamp, both Dhaka | Dhaka 10:00 | **correct** |
| `... < now()` | left side cast to `timestamptz` using the session `TimeZone`, which on Supabase is **UTC** | 10:00 UTC = Dhaka 16:00 | 6 h **late** |
| client-side, device on UTC | device thinks it is 04:00 when Dhaka is 10:00 | Dhaka 16:00 | 6 h **late** |
| client-side, device ahead of Dhaka (UTC+12) | device thinks it is 10:00 when Dhaka is 04:00 | Dhaka 04:00 | 6 h **early** |

The important consequence: **every server-side mistake errs late, and every
client-side mistake errs in whichever direction the device's clock points.** That
is precisely why this is dangerous. A team testing in Bangladesh sees the client
check behave correctly, because their devices are on Asia/Dhaka. A misconfigured
phone, a traveller, or an emulator on a different zone silently gains the ability
to review early — and a REST client has no timezone at all and is not running the
check in the first place.

**The rule therefore lives in the database and compares against Dhaka wall-clock,
and the client check is downgraded to a prediction that only greys out a button.**
Any comparison anywhere in `supabase/` involving `appointment_date` or
`appointment_time` must go through `now() at time zone 'Asia/Dhaka'`. Audit:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "appointment_date\|appointment_time" supabase/ | grep -n "now()" | grep -v "Asia/Dhaka"
# expect zero lines
```

`20260806000014_dhaka_timezone_fix.sql` exists precisely because this was got
wrong once already. Read it before editing any time comparison.

### The DDL

`supabase/migrations/20260810000010_review_timing_restore.sql`. It restores the
lost check, upgrades it to the master plan's four conditions, and — because a
function body proved deletable — adds a regression test that fails loudly if it
is ever dropped again.

```sql
-- =====================================================================
-- 20260810000010_review_timing_restore.sql
--
-- Contradiction #2: a review requires a consultation that has happened.
--
-- 20260809000002_payment_architecture_fix.sql:345 rewrote
-- guard_reviews_insert() to adopt write_is_trusted() and, in doing so,
-- silently dropped the timing check added by 20260806000003 and the
-- Asia/Dhaka correction added by 20260806000014. This restores both and
-- applies the master plan's four conditions in full.
--
-- Depends on: public.write_is_trusted(), public.is_admin().
-- =====================================================================

create or replace function public.guard_reviews_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appt   public.appointments%rowtype;
  v_endsat timestamp;   -- Dhaka wall-clock, no zone: see below
begin
  -- Internal trigger paths and the SECURITY DEFINER helpers write through
  -- here too. write_is_trusted() is the current discriminator; see the
  -- trap table in 01_DATABASE.md section 6.4 for why current_user and
  -- session_user are both wrong.
  if public.write_is_trusted() then
    return new;
  end if;

  if new.user_id is distinct from (select auth.uid()) then
    raise exception 'A review must be attributed to the caller.'
      using errcode = '42501', detail = 'REVIEW_NOT_OWN';
  end if;

  if not exists (
    select 1 from public.users u
     where u.id = (select auth.uid()) and u.is_active
  ) then
    raise exception 'Your account is not active.'
      using errcode = '42501', detail = 'ACCOUNT_INACTIVE';
  end if;

  -- Moderation state is never client-supplied. Without this line a REST
  -- client posts status='approved' and self-publishes.
  new.status := 'pending';

  -- Non-doctor targets (hospital, clinic, pharmacy) have no appointment
  -- and no consultation, so only ownership and moderation apply. The
  -- uq_reviews_user_target index still caps them at one per target.
  if new.reviewable_type <> 'doctor' then
    return new;
  end if;

  if new.appointment_id is null then
    raise exception 'A doctor review must reference an appointment.'
      using errcode = 'P0001', detail = 'REVIEW_NEEDS_APPOINTMENT';
  end if;

  -- Condition 1: the appointment exists AND links this reviewer to this
  -- doctor. Both halves are in the WHERE clause, so a mismatched pair
  -- returns no row and is reported as "not yours" rather than leaking
  -- whether appointment 9912 exists.
  select * into v_appt
    from public.appointments a
   where a.id          = new.appointment_id
     and a.patient_id  = (select auth.uid())
     and a.doctor_id   = new.reviewable_id;

  if not found then
    raise exception 'That appointment is not yours, or is not with this doctor.'
      using errcode = 'P0001', detail = 'REVIEW_APPOINTMENT_MISMATCH';
  end if;

  -- Condition 3, checked before condition 2 because it produces the more
  -- useful message. A patient whose appointment is cancelled needs to
  -- hear "cancelled", not "wait until 10:30".
  if v_appt.status <> 'completed' then
    raise exception
      'You can review this doctor once the consultation is marked completed.'
      using errcode = 'P0001', detail = 'REVIEW_NOT_COMPLETED';
  end if;

  -- Condition 2: the scheduled END is past, in Dhaka wall-clock.
  --
  -- (date + time) yields `timestamp` (no zone) holding Dhaka wall-clock.
  -- `now() at time zone 'Asia/Dhaka'` yields `timestamp` in the same
  -- frame. Comparing against a bare now() would cast the left side using
  -- the session TimeZone (UTC on Supabase) and unlock reviews six hours
  -- late. Do not "simplify" this.
  v_endsat := (v_appt.appointment_date + v_appt.appointment_time)
            + make_interval(mins => coalesce(
                (select d.slot_minutes from public.doctors d
                  where d.id = v_appt.doctor_id), 30));

  if v_endsat >= (now() at time zone 'Asia/Dhaka') then
    raise exception
      'You can review this doctor after the consultation has finished.'
      using errcode = 'P0001', detail = 'REVIEW_TOO_EARLY';
  end if;

  -- Condition 4: no review yet. uq_reviews_appointment also enforces
  -- this, and remains the real guarantee under concurrency — two
  -- simultaneous inserts both pass this check and one loses at the
  -- index. Checking here only buys the correct message on the common,
  -- non-racing path.
  if exists (
    select 1 from public.reviews r where r.appointment_id = new.appointment_id
  ) then
    raise exception 'You have already reviewed this consultation.'
      using errcode = 'P0001', detail = 'REVIEW_DUPLICATE';
  end if;

  return new;
end;
$$;

comment on function public.guard_reviews_insert() is
  'Contradiction #2. Doctor reviews require an owned, completed appointment '
  'whose scheduled end has passed in Asia/Dhaka. The timing check was lost '
  'in 20260809000002 and restored in 20260810000010 — do not remove it.';
```

The trigger already exists (`schema.sql:3103`) and `create or replace function`
keeps it bound, so it does not need recreating. Assert it anyway, in the same
migration — if a future reset drops it, the function above becomes dead code that
still reads correctly:

```sql
do $$
begin
  if not exists (
    select 1 from pg_trigger
     where tgname = 'reviews_guard_insert'
       and tgrelid = 'public.reviews'::regclass
       and not tgisinternal
  ) then
    create trigger reviews_guard_insert
      before insert on public.reviews
      for each row execute function public.guard_reviews_insert();
  end if;
end $$;
```

### The anti-regression guard

This invariant has been deleted once by a refactor that was not about reviews.
Assume it will happen again. Append to the same migration:

```sql
-- Fails the migration if the timing check is ever absent from the live
-- function body. Cheap, and it turns a silent deletion into a failed
-- deploy. Any future rewrite must keep the Asia/Dhaka comparison to pass.
do $$
begin
  if pg_get_functiondef('public.guard_reviews_insert()'::regprocedure)
     not like '%Asia/Dhaka%' then
    raise exception
      'guard_reviews_insert() has lost its Asia/Dhaka timing check (contradiction #2)';
  end if;
end $$;
```

Add the same probe to the project's smoke suite so it runs on every deploy, not
only when this migration is applied. See section 22 for the full list.

### SQLSTATE

| Condition | SQLSTATE | DETAIL code |
|---|---|---|
| review not attributed to caller | `42501` | `REVIEW_NOT_OWN` |
| account not active | `42501` | `ACCOUNT_INACTIVE` |
| doctor review with no appointment | `P0001` | `REVIEW_NEEDS_APPOINTMENT` |
| appointment not owned / wrong doctor | `P0001` | `REVIEW_APPOINTMENT_MISMATCH` |
| appointment not `completed` | `P0001` | `REVIEW_NOT_COMPLETED` |
| consultation has not finished | `P0001` | `REVIEW_TOO_EARLY` |
| already reviewed (trigger path) | `P0001` | `REVIEW_DUPLICATE` |
| already reviewed (race path) | `23505` | none — `uq_reviews_appointment` |

Note the last two are the *same rule* arriving by two SQLSTATEs. The Dart mapping
below must produce one message for both, or a patient who happens to lose a race
gets different wording than one who simply taps twice slowly.

One deliberate change from the existing code: `20260809000002:361` raises the
"appointment does not match" error with `errcode = '23505'`. That is wrong —
nothing was duplicated — and `guard()` routes `23505` through `_uniqueMessage()`
(`app/lib/core/network/supabase_service.dart:326`), which recognises none of these
names and returns *"That already exists."* for a mismatched appointment. The
replacement uses `P0001` throughout so the raise message reaches the user verbatim
(`supabase_service.dart:238`).

### The Dart mapping

All seven trigger paths carry a DETAIL code, so `_detailCode()`
(`supabase_service.dart:281`) populates `ApiException.code` and screens branch on
the rule. Add to `app/lib/core/network/integrity_errors.dart`:

```dart
// Contradiction #2 — review timing.
'REVIEW_NOT_OWN':              (en: 'That review is not yours.',
                                bn: 'এই রিভিউটি আপনার নয়।'),
'REVIEW_NEEDS_APPOINTMENT':    (en: 'Select the consultation you are reviewing.',
                                bn: 'আপনি যে পরামর্শের রিভিউ দিচ্ছেন সেটি নির্বাচন করুন।'),
'REVIEW_APPOINTMENT_MISMATCH': (en: 'That appointment is not yours, or is not with this doctor.',
                                bn: 'এই অ্যাপয়েন্টমেন্টটি আপনার নয়, অথবা এই ডাক্তারের সাথে নয়।'),
'REVIEW_NOT_COMPLETED':        (en: 'You can review this doctor once the consultation is marked completed.',
                                bn: 'পরামর্শটি সম্পন্ন হিসেবে চিহ্নিত হলে আপনি এই ডাক্তারের রিভিউ দিতে পারবেন।'),
'REVIEW_TOO_EARLY':            (en: 'You can review this doctor after the consultation has finished.',
                                bn: 'পরামর্শ শেষ হওয়ার পরে আপনি এই ডাক্তারের রিভিউ দিতে পারবেন।'),
'REVIEW_DUPLICATE':            (en: 'You have already reviewed this consultation.',
                                bn: 'আপনি ইতিমধ্যে এই পরামর্শের রিভিউ দিয়েছেন।'),
```

The `23505` race path has no DETAIL code, so it must be caught by constraint name.
`_uniqueMessage()` (`supabase_service.dart:336`) currently matches
`reviews_one_per_user`, **an index that does not exist** — the real names are
`uq_reviews_appointment` (`schema.sql:930`) and `uq_reviews_user_target`
(`schema.sql:934`). Replace that branch, keeping the dead string so any legacy row
still matches:

```dart
    if (d.contains('uq_reviews_appointment')) {
      return 'You have already reviewed this consultation.';
    }
    if (d.contains('uq_reviews_user_target') ||
        d.contains('reviews_one_per_user')) {
      return 'You have already reviewed this.';
    }
```

### What the client must and must not do

Grey out the review button when the appointment is not `completed` or its end time
is in the future — but compute that from `appointment_date`, `appointment_time`
and `slot_minutes` **converted to Asia/Dhaka**, never from the device's local
clock:

```dart
// Correct: the appointment's wall-clock is Dhaka's, so compare in Dhaka.
final dhakaNow = DateTime.now().toUtc().add(const Duration(hours: 6));
```

Bangladesh has not observed DST since 2009, so the fixed +6 offset is safe and is
what the rest of the app already assumes. This check is a courtesy that hides a
button; it is not the enforcement. If it disagrees with the server the server
wins, and the screen shows the returned message.

### Reproduction test

Run as an ordinary patient, not as `postgres` — `write_is_trusted()` short-circuits
for trusted callers and every assertion below would silently pass.

```sql
-- Arrange: patient P, doctor D, appointment A yesterday 10:00, slot 30 min.
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient-uuid>","role":"authenticated"}';

-- 1. Not completed yet -> rejected, even though the time has passed.
update public.appointments set status = 'confirmed' where id = <A>;  -- as admin
insert into public.reviews (user_id, reviewable_type, reviewable_id,
                            appointment_id, rating, comment)
values ('<patient-uuid>', 'doctor', <D>, <A>, 5, 'good');
-- expect: P0001, DETAIL REVIEW_NOT_COMPLETED

-- 2. Completed but scheduled for tomorrow -> rejected.
update public.appointments
   set status = 'completed', appointment_date = current_date + 1 where id = <A>;
insert into public.reviews (...) values (...);
-- expect: P0001, DETAIL REVIEW_TOO_EARLY

-- 3. Completed, ended 10 minutes ago -> accepted, status forced to 'pending'.
update public.appointments
   set appointment_date = current_date,
       appointment_time = ((now() at time zone 'Asia/Dhaka')
                           - interval '40 minutes')::time
 where id = <A>;
insert into public.reviews (...) returning id, status;
-- expect: one row, status = 'pending'

-- 4. Second review for the same appointment -> rejected.
insert into public.reviews (...) values (...);
-- expect: P0001, DETAIL REVIEW_DUPLICATE

rollback;
```

The boundary case is the one to keep. Set `appointment_time` to exactly
`(now() at time zone 'Asia/Dhaka') - interval '30 minutes'` with a 30-minute slot:
the consultation ends this instant, `v_endsat >= now` is true, and the insert must
be **rejected**. One second earlier and it must succeed. A test that only checks
"yesterday fails, last week works" would pass against a version comparing the
start time, which is the bug this section exists to prevent.

The timezone proof, which no functional test will catch:

```sql
-- Set the session to UTC, as a misconfigured client or a psql session would.
-- The guard must behave identically: it never reads the session TimeZone.
set time zone 'UTC';
-- rerun case 2 -> still REVIEW_TOO_EARLY
set time zone 'Asia/Dhaka';
-- rerun case 2 -> still REVIEW_TOO_EARLY
```

Identical results across both is the whole point. If they differ, a bare `now()`
has crept back in.

---

## 6. Contradictions #3, #4, #5 — a slot must be real before it can be booked

These three share one enforcement path, so they are treated together. All three
are **already enforced**; this section's job is to prove it, name the one gap, and
fix the error codes, which are wrong in a way that produces nonsense messages.

| # | Invariant |
|---|---|
| 3 | An appointment cannot be booked for a time that has already passed in Asia/Dhaka. |
| 4 | An appointment cannot be booked outside the doctor's published days and hours. |
| 5 | An appointment cannot be booked with a doctor who is not verified and active. |

### The single mechanism

`guard_appointments_insert()` (live version:
`20260809000002_payment_architecture_fix.sql:222`) delegates #3 and #4 to
`available_slots()` and handles #5 itself:

```sql
  select d.consultation_fee, u.name
    into v_fee, v_name
    from public.doctors d
    join public.users u on u.id = d.user_id
   where d.id = new.doctor_id
     and d.status = 'active'
     and d.verification_status = 'verified'
     and not d.is_deleted;
  if not found then
    raise exception 'this doctor is not accepting appointments'
      using errcode = '42501';
  end if;
  ...
  if not exists (
    select 1 from public.available_slots(new.doctor_id, new.appointment_date) s
     where s.slot_time = new.appointment_time
  ) then
    raise exception 'this slot is not available' using errcode = '23505';
  end if;
```

and `available_slots()` (live version:
`20260806000014_dhaka_timezone_fix.sql`, rewritten by 01_DATABASE.md §6.2) does
the rest:

```sql
  v_day := lower(to_char(p_date, 'dy'));
  if position(v_day in lower(v_doc.available_days)) = 0 then
    return;                                    -- #4, wrong weekday
  end if;
  ...
      select generate_series(
               p_date + v_doc.available_from,  -- #4, before opening
               p_date + v_doc.available_to
                        - make_interval(mins => v_doc.slot_minutes),
               make_interval(mins => v_doc.slot_minutes))
  ...
     where s.ts > (now() at time zone 'Asia/Dhaka')   -- #3, in the past
```

The design is worth stating plainly because it is the pattern the rest of this
document reuses: **the function that lists the legal values is the same function
that validates the submitted one.** There is no second copy of the opening-hours
arithmetic to drift out of step. If `available_slots()` will not offer it, the
insert cannot take it.

### The failure scenario, and why the UI cannot be trusted with any of the three

Dr Rahman works Sat–Wed, 17:00–21:00. At 18:20 on a Saturday, a patient's phone
has a cached slot list fetched at 09:00 that morning.

- **#3**: the cached list still contains 17:00, 17:30, 18:00. Tapping 17:00 sends
  a booking for a time 80 minutes in the past. The doctor's schedule now shows a
  patient who cannot possibly arrive.
- **#4**: the same patient edits the request by hand to `"appointment_time":
  "23:00"`. Nothing in the payload is malformed; PostgREST is happy;
  `appointments_insert_own` (`supabase/rls_policies.sql:158`) checks only
  `patient_id = auth.uid()`, which is true.
- **#5**: Dr Karim registered last week and is `verification_status = 'pending'`.
  His profile row exists, so his `doctors.id` is guessable — they are sequential
  `bigint`s. A REST client posts an appointment against it. Money is then taken
  for a consultation with someone the platform has not checked.

#5 is the one with real-world consequences: an unverified provider taking payments
through the platform is a regulatory problem, not a UX one.

### The gap: `available_slots()` does not filter on `verification_status`

Compare the two predicates. `guard_appointments_insert()` requires
`status = 'active' and verification_status = 'verified' and not is_deleted`.
`available_slots()` requires only `status = 'active' and not is_deleted`.

An unverified-but-active doctor therefore **returns a full slot list**, so the app
renders a bookable calendar, the patient picks a time, and the insert is rejected
with "this doctor is not accepting appointments". Safe, but a dead end the user
cannot escape. The rewritten `available_slots()` in 01_DATABASE.md §6.2 already
aligns the predicate; if you are applying Part 12 before Part 01, apply this:

```sql
-- 20260810000011_available_slots_verified_only.sql
-- Aligns available_slots() with guard_appointments_insert() so an
-- unverified doctor advertises no slots rather than advertising slots
-- that cannot be booked. Superseded by 01_DATABASE.md section 6.2 if that
-- migration has already run — both leave the same predicate in place.
--
-- The full function body is in 01_DATABASE.md section 6.2. The only change
-- relative to 20260806000014 is the doctor lookup:
--
--     from public.doctors
--    where id = p_doctor_id
--      and status = 'active'
--      and verification_status = 'verified'   -- <- added
--      and not is_deleted;
```

Do not write a second copy of the function here. Two definitions of
`available_slots()` in two migrations is exactly the drift that lost
contradiction #2.

### SQLSTATE — currently wrong, fix it

| Condition | Raised now | Should be | Why |
|---|---|---|---|
| #3/#4 slot not offered | `23505` | `P0001` + `SLOT_NOT_AVAILABLE` | nothing is duplicated |
| #5 doctor not bookable | `42501` | `P0001` + `DOCTOR_NOT_BOOKABLE` | it is not a permission failure |

`23505` is actively harmful. `guard()` routes it to `_uniqueMessage()`
(`app/lib/core/network/supabase_service.dart:326`), which matches none of these
strings and returns **"That already exists."** — shown to a patient who booked a
time outside opening hours. `42501` is routed to
`supabase_service.dart:189`, which prefixes **"You do not have permission to do
that."** — shown to a patient who did nothing wrong.

Both are fixed by changing two lines. Add to
`supabase/migrations/20260810000011_available_slots_verified_only.sql`, reusing
the live function body from `20260809000002:222` and changing only these raises:

```sql
  if not found then
    raise exception 'This doctor is not currently accepting appointments.'
      using errcode = 'P0001', detail = 'DOCTOR_NOT_BOOKABLE';
  end if;
```

```sql
  if not exists (
    select 1 from public.available_slots(new.doctor_id, new.appointment_date) s
     where s.slot_time = new.appointment_time
  ) then
    raise exception 'That time is no longer available. Please choose another.'
      using errcode = 'P0001', detail = 'SLOT_NOT_AVAILABLE';
  end if;
```

One message covers #3 and #4 deliberately. The guard cannot distinguish "past"
from "outside hours" — `available_slots()` returns an empty set for both — and
inventing a distinction would mean duplicating the schedule logic in the guard.
"No longer available, choose another" is true in every case and leads the patient
to the same correct action.

### The Dart mapping

```dart
// Contradictions #3, #4, #5 — slot and provider validity.
'SLOT_NOT_AVAILABLE':  (en: 'That time is no longer available. Please choose another.',
                        bn: 'এই সময়টি আর খালি নেই। অনুগ্রহ করে অন্য সময় বেছে নিন।'),
'DOCTOR_NOT_BOOKABLE': (en: 'This doctor is not currently accepting appointments.',
                        bn: 'এই ডাক্তার এই মুহূর্তে অ্যাপয়েন্টমেন্ট নিচ্ছেন না।'),
```

On `SLOT_NOT_AVAILABLE` the booking screen must **refetch the slot list** before
showing the message, not merely display it. The cause is nearly always a stale
cache, and a patient told "choose another" while looking at the same stale grid
will tap a second unavailable time.

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient-uuid>","role":"authenticated"}';

-- #3 in the past: yesterday, inside opening hours.
insert into public.appointments
  (patient_id, doctor_id, appointment_date, appointment_time, status)
values ('<patient>', <verified-doctor>, current_date - 1, '18:00', 'pending');
-- expect P0001 / SLOT_NOT_AVAILABLE

-- #3 boundary: today, one minute ago in Dhaka. Must also fail.
insert into public.appointments (...)
values ('<patient>', <verified-doctor>, current_date,
        ((now() at time zone 'Asia/Dhaka') - interval '1 minute')::time, 'pending');
-- expect P0001 / SLOT_NOT_AVAILABLE

-- #4 outside hours: tomorrow at 23:00, doctor closes 21:00.
insert into public.appointments (...)
values ('<patient>', <verified-doctor>, current_date + 1, '23:00', 'pending');
-- expect P0001 / SLOT_NOT_AVAILABLE

-- #4 off-grid: 18:07 when slot_minutes = 30 and opening is 17:00.
insert into public.appointments (...)
values ('<patient>', <verified-doctor>, current_date + 1, '18:07', 'pending');
-- expect P0001 / SLOT_NOT_AVAILABLE

-- #4 wrong weekday: the next date whose to_char(...,'dy') is absent from
-- the doctor's available_days.
-- expect P0001 / SLOT_NOT_AVAILABLE

-- #5 unverified doctor, legal time from that doctor's own window.
insert into public.appointments (...)
values ('<patient>', <pending-doctor>, current_date + 1, '18:00', 'pending');
-- expect P0001 / DOCTOR_NOT_BOOKABLE

-- Control: verified doctor, tomorrow, on-grid, inside hours.
insert into public.appointments (...)
values ('<patient>', <verified-doctor>, current_date + 1, '18:00', 'pending')
returning id, fee, status;
-- expect one row; fee copied from doctors.consultation_fee, never from
-- the request; status 'pending_payment' when fee > 0.

rollback;
```

The off-grid case at 18:07 is the one teams forget. A guard that checked only
"between `available_from` and `available_to`" would accept it, and the appointment
would overlap two slots without colliding with either in
`uq_appointments_doctor_slot`. Membership in `available_slots()` — not a range
comparison — is what makes it impossible.

And the gap test, which must be run against the unverified doctor **before** the
fix to see it fail:

```sql
select count(*) from public.available_slots(<pending-doctor>, current_date + 1);
-- before 20260810000011: non-zero (slots advertised, bookings rejected)
-- after:                 0
```

---

## 7. Contradiction #6 — one patient cannot hold many slots at once

**Status: not enforced. This is new work.**

### The invariant

A patient may hold at most one unpaid `pending_payment` appointment at a time.

### The failure scenario

Section 4 gave every unpaid booking a 15-minute hold, which fixed abandoned
checkouts. It also created this hole, because nothing caps how many holds one
patient may open.

Rafiq wants a same-day appointment with the city's only paediatric cardiologist,
who publishes eight slots a day.

```
09:00:00.0  Rafiq's script POSTs 8 bookings for tomorrow, one per slot.
09:00:00.4  All 8 succeed. Each is 'pending_payment', hold_expires_at 09:15.
            uq_appointments_doctor_slot is satisfied: 8 different times.
09:00:01    available_slots() returns zero rows for tomorrow.
09:03       Rafiq pays for the 14:00 one and abandons the rest.
09:15       The sweeper expires the other 7. They were unbookable for 15 min.
09:15:30    The script runs again.
```

Every constraint held. The unique index only stops two patients taking the *same*
slot; it says nothing about one patient taking *all* of them. Repeat the loop and
the doctor's calendar is permanently empty to everyone else, at zero cost — the
holds are unpaid, so the attacker never spends a taka.

This is not only malicious. The honest version is commoner: a patient opens the
booking screen on a phone and a tablet, or taps "Book" then backs out and books a
different time without cancelling. They now hold two slots and will pay for one.

The window is short but the damage is not, because it is *renewable*. An attacker
paying nothing can keep the calendar empty indefinitely by re-running every 15
minutes.

### Why the obvious fixes fail

**A partial unique index on `(patient_id)` where `status = 'pending_payment'`** is
the right shape and is what we use. Note carefully why it must be on `patient_id`
alone and not `(patient_id, doctor_id)`: the latter would still let Rafiq hold one
slot with each of forty doctors, and a patient legitimately booking two different
specialists in one sitting is not a real workflow — they can complete one payment
and start the next.

**Rate-limiting in the app** does nothing. The attack is a REST client.

**Counting in the guard** (`select count(*) ... where status='pending_payment'`)
is a `not exists` check by another name and loses the same race under `READ
COMMITTED`: two concurrent inserts both count zero, both proceed. It may be added
for the message, never for the guarantee.

### The DDL

```sql
-- =====================================================================
-- 20260810000012_single_payment_hold.sql
--
-- Contradiction #6: one unpaid hold per patient.
--
-- Depends on: 20260810000009_payment_hold_expiry.sql (hold_expires_at,
-- expire_payment_holds()). Without a working expirer this constraint
-- would lock a patient out permanently after one abandoned checkout, so
-- do not apply it first.
-- =====================================================================

-- The guarantee. Partial, so it costs nothing on the 99.9% of rows that
-- are not holds, and so a patient may have any number of confirmed,
-- completed or cancelled appointments.
create unique index uq_appointments_one_hold_per_patient
  on public.appointments (patient_id)
  where status = 'pending_payment';

comment on index public.uq_appointments_one_hold_per_patient is
  'Contradiction #6: at most one unpaid pending_payment appointment per '
  'patient, so no one can hold a doctor''s whole calendar for free.';
```

Creating it on a live table needs the concurrent form, because the plain form
takes an `ACCESS EXCLUSIVE` lock and blocks every booking while it builds:

```sql
-- Run OUTSIDE a transaction block. Supabase migrations run inside one, so
-- this must be executed manually via psql or as its own statement with
-- the migration runner's transaction disabled.
create unique index concurrently uq_appointments_one_hold_per_patient
  on public.appointments (patient_id)
  where status = 'pending_payment';
```

**Check for pre-existing violations first.** `create unique index` fails outright
if any patient already holds two, and `concurrently` leaves an `INVALID` index
behind that silently enforces nothing:

```sql
select patient_id, count(*) as holds
  from public.appointments
 where status = 'pending_payment'
 group by patient_id having count(*) > 1
 order by holds desc;
-- Must be empty. If not, expire the older holds before proceeding:
--   update public.appointments set status = 'expired'
--    where status = 'pending_payment' and id not in (
--      select distinct on (patient_id) id from public.appointments
--       where status = 'pending_payment' order by patient_id, created_at desc);
-- Run that as a trusted path (see appointments_guard_transition).

-- After a CONCURRENTLY build, confirm it is valid:
select indisvalid from pg_index
 where indexrelid = 'public.uq_appointments_one_hold_per_patient'::regclass;
-- expect true; if false, drop and rebuild.
```

Now the message. The index alone raises a bare `23505` whose constraint name
`_uniqueMessage()` does not know, so the patient reads "That already exists."
Add a guard that produces the useful sentence on the non-racing path — which is
almost every occurrence, since the real cause is a second tab, not a race:

```sql
create or replace function public.appointments_one_hold_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing record;
begin
  if new.status <> 'pending_payment' then
    return new;
  end if;
  if public.write_is_trusted() then
    -- appointments_book() runs trusted and must still be caught, so do
    -- not return early here on the trusted path. Only skip when the row
    -- is not a hold, handled above.
    null;
  end if;

  select id, appointment_date, appointment_time, hold_expires_at
    into v_existing
    from public.appointments
   where patient_id = new.patient_id
     and status     = 'pending_payment'
     and id is distinct from new.id
   limit 1;

  if found then
    raise exception
      'You already have an unpaid booking for % at %. Complete or cancel it first.',
      to_char(v_existing.appointment_date, 'DD Mon'),
      to_char(v_existing.appointment_time, 'HH12:MI AM')
      using errcode = 'P0001', detail = 'HOLD_ALREADY_OPEN';
  end if;

  return new;
end;
$$;

revoke all on function public.appointments_one_hold_guard() from public, anon, authenticated;

-- ab_ so it runs after aa_guard_appointments (the column-immutability
-- guard) and after guard_appointments_insert has stamped status. A guard
-- that reads new.status must fire after whatever sets it.
create trigger ab_one_hold_guard
  before insert or update of status on public.appointments
  for each row execute function public.appointments_one_hold_guard();
```

The trigger-ordering note is load-bearing. `guard_appointments_insert()` decides
between `pending` and `pending_payment` based on the fee
(`20260809000002_payment_architecture_fix.sql:266`); reading `new.status` before
that runs would test a client-supplied value. Postgres fires same-event `BEFORE`
row triggers **in alphabetical order by trigger name**, so the existing
`appointments_guard_insert` sorts before `ab_one_hold_guard`. Verify rather than
trust:

```sql
select tgname from pg_trigger
 where tgrelid = 'public.appointments'::regclass and not tgisinternal
 order by tgname;
-- ab_one_hold_guard must appear AFTER appointments_guard_insert.
-- If a future rename breaks that, rename this trigger, not the other one.
```

Note the deliberate absence of a trusted-path escape. `appointments_book()`
(`20260809000002_payment_architecture_fix.sql:765`) runs inside the trusted path,
and it is the *primary* way holds are created — exempting trusted writers would
exempt the only writer that matters. The `null;` branch above is written out
explicitly so no one "tidies" it into an early return.

### SQLSTATE

| Path | SQLSTATE | DETAIL |
|---|---|---|
| second hold, normal case | `P0001` | `HOLD_ALREADY_OPEN` |
| second hold, concurrent race | `23505` | none — `uq_appointments_one_hold_per_patient` |

### The Dart mapping

```dart
// Contradiction #6 — one unpaid hold per patient.
'HOLD_ALREADY_OPEN': (en: 'You already have an unpaid booking. Complete or cancel it first.',
                      bn: 'আপনার একটি অপরিশোধিত বুকিং রয়েছে। আগে সেটি সম্পন্ন করুন বা বাতিল করুন।'),
```

The `P0001` message from the trigger is richer than this fallback — it names the
date and time — and `guard()` passes it through verbatim
(`app/lib/core/network/supabase_service.dart:238`), so the English the patient
sees is the trigger's sentence. The map entry is the Bangla translation and the
fallback for the race path. Because the trigger interpolates a date, the Bangla
string cannot be assembled server-side; when `preferred_language = 'bn'` the
client must use the mapped string and, if it has the pending appointment loaded,
append its own formatted date.

And the race path, keyed by name:

```dart
    if (d.contains('uq_appointments_one_hold_per_patient')) {
      return 'You already have an unpaid booking. Complete or cancel it first.';
    }
```

The booking screen should do better than showing an error: on
`HOLD_ALREADY_OPEN`, offer "Go to unpaid booking" and route to the existing hold.
A patient who hit this has a payment to finish, and the error is really a
navigation problem.

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient>","role":"authenticated"}';

-- 1. First hold on a paid doctor: succeeds.
select public.appointments_book(<verified-paid-doctor>, current_date + 1, '18:00');
-- expect one row, status 'pending_payment'

-- 2. Second hold, different slot, same doctor: rejected.
select public.appointments_book(<verified-paid-doctor>, current_date + 1, '18:30');
-- expect P0001 / HOLD_ALREADY_OPEN

-- 3. Second hold, different doctor: also rejected. This is the case that
--    proves the index is on patient_id alone.
select public.appointments_book(<other-verified-paid-doctor>, current_date + 1, '10:00');
-- expect P0001 / HOLD_ALREADY_OPEN

-- 4. A FREE doctor opens in 'pending', not 'pending_payment', so it must
--    NOT be blocked. Partial index, partial guard.
select public.appointments_book(<verified-free-doctor>, current_date + 1, '11:00');
-- expect success

-- 5. Release the hold, then book again: succeeds.
update public.appointments set status = 'cancelled'
 where patient_id = '<patient>' and status = 'pending_payment';
select public.appointments_book(<verified-paid-doctor>, current_date + 1, '18:30');
-- expect success

rollback;
```

Case 4 is the one to keep in the regression suite. An index written without the
`where status = 'pending_payment'` clause, or a guard that tested "any open
appointment", would block a patient from booking a free follow-up while paying for
something else — a rule nobody asked for, discovered weeks later.

---

## 8. Contradictions #7 and #8 — one review per encounter, and only for encounters you had

### The invariants

| # | Invariant |
|---|---|
| 7 | An appointment can carry at most one review. |
| 8 | A provider can be reviewed only by someone who actually used it. |

### #7 — already enforced, and the constraint is the guarantee

`uq_reviews_appointment` (`supabase/schema.sql:930`):

```sql
create unique index uq_reviews_appointment
  on public.reviews (appointment_id)
  where appointment_id is not null;
```

The `where` clause is what makes it usable at all. `reviews.appointment_id` is
nullable by design — hospital, clinic and pharmacy reviews have no appointment
(`schema.sql:910`) — and a plain unique index treats every `NULL` as distinct in
Postgres, so it *would* work. The partial form is still better: it excludes every
non-doctor review from the index entirely, which on a table where most reviews are
of pharmacies keeps it a fraction of the size.

Alongside it, `uq_reviews_user_target` (`schema.sql:934`):

```sql
create unique index uq_reviews_user_target
  on public.reviews (user_id, reviewable_type, reviewable_id);
```

These two say different things and both are needed. The first stops one
appointment producing two reviews. The second stops one patient reviewing the same
doctor once per appointment across ten appointments — which the first would allow.

**The consequence nobody notices until support asks:** a patient who sees a doctor
in January and again in June can review only once, ever. That is a deliberate
product choice inherited from the MySQL schema, and it is enforced. If the product
later wants per-visit reviews, `uq_reviews_user_target` is the constraint to drop —
not `uq_reviews_appointment`. Record that here so the wrong one is not removed.

The trigger check added in section 5 (`REVIEW_DUPLICATE`) covers the common path;
the index covers the race. Both are required, for the reason given there.

### #8 — enforced for doctors, and completely open for everyone else

Section 5's guard proves the encounter for `reviewable_type = 'doctor'`. Read its
third branch again:

```sql
  if new.reviewable_type <> 'doctor' then
    return new;
  end if;
```

For `hospital`, `clinic` and `pharmacy` — three of the four values of
`reviewable_type` (`schema.sql:221`) — **any active account can post any rating
about any provider, having never used it.** A competitor can one-star every
pharmacy in Dhaka from a single signup. `recalc_reviewable_rating()` then folds
those into the provider's public average.

This is the largest unenforced hole in the review system and the master plan's
row 8 names it directly. The honest difficulty is that **the schema models an
encounter for only two of the four target types**:

| Target | Evidence an encounter happened | Available? |
|---|---|---|
| `doctor` | `appointments` row, completed | yes |
| `pharmacy` | `orders` row with `pharmacy_id`, delivered | yes — `schema.sql` orders table, `pharmacy_id` column |
| `hospital` | nothing. No admission, visit or service booking exists | no |
| `clinic` | nothing | no |

01_DATABASE.md §6.3 adds `hospital_services`, but a service *catalogue* is not a
*booking*: it says the hospital offers an MRI, not that this patient had one.

### The decision, and why it is not "enforce it everywhere"

Enforce what the schema can prove, and refuse to fake the rest.

- **`pharmacy`**: require a delivered order from that pharmacy. The evidence
  exists; use it.
- **`hospital` and `clinic`**: leave unenforceable at the database level and route
  every such review through moderation. `guard_reviews_insert()` already forces
  `status := 'pending'`, and `reviews_select_approved`
  (`supabase/rls_policies.sql:683`) hides pending rows from the public, so an
  unearned hospital review is invisible until an admin approves it.

The alternative — inventing a `hospital_visits` table so the constraint has
something to point at — would mean fabricating rows nobody enters, and R1 forbids
seeding business data. A table that is always empty makes the constraint reject
*every* hospital review, which is worse than moderation.

**Write this limitation into the spec output, not just the code.** Part 12's
completion report must state that #8 is enforced for `doctor` and `pharmacy` and
mitigated by moderation for `hospital` and `clinic`. Reporting it as "done" would
be the dishonest reporting R8 forbids.

### The DDL

```sql
-- =====================================================================
-- 20260810000013_review_pharmacy_evidence.sql
--
-- Contradiction #8, pharmacy half: a pharmacy review requires a
-- delivered order from that pharmacy. Extends the function defined in
-- 20260810000010; apply that first.
-- =====================================================================
```

Insert this branch into `guard_reviews_insert()` immediately **before** the
`reviewable_type <> 'doctor'` early return, replacing it:

```sql
  if new.reviewable_type = 'pharmacy' then
    if not exists (
      select 1 from public.orders o
       where o.user_id     = (select auth.uid())
         and o.pharmacy_id = new.reviewable_id
         and o.status      = 'delivered'
    ) then
      raise exception
        'You can review a pharmacy after an order from it has been delivered.'
        using errcode = 'P0001', detail = 'REVIEW_NO_ORDER';
    end if;
    return new;
  end if;

  if new.reviewable_type <> 'doctor' then
    -- hospital, clinic: no encounter record exists in this schema, so the
    -- rule cannot be expressed. Moderation is the control: status was
    -- forced to 'pending' above and reviews_select_approved hides pending
    -- rows from the public. Do NOT relax that policy.
    return new;
  end if;
```

Confirm `'delivered'` is a real `order_status` value before applying — the enum is
at `schema.sql`, and a typo here raises `22P02` at runtime rather than at migration
time:

```sql
select enumlabel from pg_enum
 where enumtypid = 'public.order_status'::regtype order by enumsortorder;
```

Supporting index — the guard runs on every pharmacy review insert and the existing
`idx_orders_user` does not carry `pharmacy_id` or `status`:

```sql
-- Serves: "has this user had a delivered order from pharmacy N?"
create index idx_orders_user_pharmacy_delivered
  on public.orders (user_id, pharmacy_id)
  where status = 'delivered';
```

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | DETAIL |
|---|---|---|
| pharmacy review with no delivered order | `P0001` | `REVIEW_NO_ORDER` |
| second review of the same appointment (race) | `23505` | `uq_reviews_appointment` |
| second review of the same target (race) | `23505` | `uq_reviews_user_target` |

```dart
// Contradiction #8 — pharmacy reviews need a delivered order.
'REVIEW_NO_ORDER': (en: 'You can review a pharmacy after an order from it has been delivered.',
                    bn: 'এই ফার্মেসি থেকে অর্ডার ডেলিভারি হওয়ার পরে আপনি রিভিউ দিতে পারবেন।'),
```

The two `23505` names are mapped in section 5. The client should hide the review
control for a pharmacy the user has no delivered order from, using the same order
history it already fetches — but the rule is the trigger's, not the widget's.

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<user>","role":"authenticated"}';

-- #7: two reviews for one appointment.
insert into public.reviews (user_id, reviewable_type, reviewable_id,
                            appointment_id, rating)
values ('<user>', 'doctor', <D>, <completed-past-appt>, 5);          -- ok
insert into public.reviews (user_id, reviewable_type, reviewable_id,
                            appointment_id, rating)
values ('<user>', 'doctor', <D>, <completed-past-appt>, 1);
-- expect P0001 / REVIEW_DUPLICATE

-- #7 second form: same doctor, a DIFFERENT completed appointment.
insert into public.reviews (...) values ('<user>','doctor',<D>,<other-appt>,4);
-- expect 23505 / uq_reviews_user_target -> 'You have already reviewed this.'
-- This is the deliberate one-review-per-doctor-ever rule, not a bug.

-- #8 pharmacy, no order at all.
insert into public.reviews (user_id, reviewable_type, reviewable_id, rating)
values ('<user>', 'pharmacy', <P>, 1);
-- expect P0001 / REVIEW_NO_ORDER

-- #8 pharmacy, order exists but status = 'pending'.
insert into public.orders (...) values (...);   -- via place_order(), status pending
insert into public.reviews (...) values ('<user>','pharmacy',<P>,1);
-- expect P0001 / REVIEW_NO_ORDER

-- #8 pharmacy, order delivered.
update public.orders set status = 'delivered' where id = <O>;  -- as pharmacy owner
insert into public.reviews (...) values ('<user>','pharmacy',<P>,5) returning status;
-- expect one row, status 'pending'

-- #8 hospital: accepted by design, but must not be publicly visible.
insert into public.reviews (...) values ('<user>','hospital',<H>,1) returning status;
-- expect one row, status 'pending'
rollback;

-- Then, as anon, the moderation control must actually hold:
set local role anon;
select count(*) from public.reviews
 where reviewable_type = 'hospital' and status <> 'approved';
-- expect 0 rows visible
```

That last query is the real test for the hospital half. The mitigation is not the
trigger — there is none — it is `reviews_select_approved`. If that policy is ever
loosened, contradiction #8 reopens for hospitals and clinics with no error
anywhere to signal it.

---

## 9. Contradictions #9 and #10 — stock cannot be oversold, and cannot go negative

### The invariants

| # | Invariant |
|---|---|
| 9 | An order cannot be placed for more units than are in stock. |
| 10 | `pharmacy_products.stock` can never be negative. |

Both are **already enforced**, and the pair is worth studying closely because it
is the cleanest example in this schema of the layering this whole document argues
for: a `CHECK` that makes the bad state unrepresentable, and an atomic `UPDATE`
that makes the good path race-free. Neither alone is sufficient.

### The failure scenario

One box of a scarce antibiotic is left. `pharmacy_products.stock = 1`.

```
19:41:02.310  Session A (Nadia)  place_order() begins.
19:41:02.318  Session B (Imran)  place_order() begins.
19:41:02.402  A reads stock = 1.                 -- if it read first
19:41:02.404  B reads stock = 1.                 -- READ COMMITTED: also 1
19:41:02.409  A: "1 >= 1, proceed."
19:41:02.411  B: "1 >= 1, proceed."
19:41:02.480  A writes stock = 0. Order placed.
19:41:02.495  B writes stock = 0. Order placed.
```

Two customers are each promised the last box. The pharmacy discovers it at
packing time, and one of them has already paid.

This is the read-then-write race, identical in shape to the double booking in
section 3, and it defeats any amount of checking in Dart or in a separate `select`
inside the function. Under `READ COMMITTED` both transactions see the pre-update
value because neither has committed.

### Why the existing code is correct

`place_order()` (`supabase/schema.sql:2731`) does not read then write. It writes
conditionally:

```sql
    update public.pharmacy_products
       set stock = stock - v_item.quantity
     where id = v_item.product_id
       and stock >= v_item.quantity;
    if not found then
      raise exception 'insufficient stock for %', v_item.product_name
        using errcode = 'P0001';
    end if;
```

The whole rule lives in one statement. Replay the race against it:

```
19:41:02.480  A's UPDATE matches (stock 1 >= 1), sets stock = 0, holds a
              row lock. Not yet committed.
19:41:02.495  B's UPDATE finds the row, sees it locked, and BLOCKS.
19:41:02.510  A commits.
19:41:02.511  B wakes, RE-EVALUATES its WHERE against the new row version
              (this is what READ COMMITTED does after a lock wait),
              finds stock = 0, and 0 >= 1 is false. No row matches.
19:41:02.511  FOUND is false. B raises 'insufficient stock'.
```

The re-evaluation after a blocking wait is the mechanism, and it is the reason
this works where a separate `select ... for update` plus arithmetic would merely
be more code doing the same thing. **Do not "optimise" this into a read, a check
and a write.** Add a comment to that effect if the function is ever touched.

The `order by c.id` on the cart loop is also deliberate, though the comment does
not say so: iterating products in a consistent order across all sessions is what
prevents deadlock when two carts contain the same two products in opposite orders.
Preserve it.

### The backstop: #10

`pharmacy_products_stock_check` (`schema.sql:737`):

```sql
  constraint pharmacy_products_stock_check check (stock >= 0),
```

This exists because `place_order()` is not the only writer. A pharmacy owner can
update their own stock directly — `pharmacy_products_update_owner`
(`supabase/rls_policies.sql:565`) permits it — and could set `-5` by typo or by
REST call. The CHECK makes negative stock unrepresentable regardless of which path
writes it, which is precisely R9. Without it, #10 would depend on every current
and future writer remembering the rule.

Note the ordering: the CHECK fires on `place_order()`'s UPDATE too, so even if the
`and stock >= v_item.quantity` predicate were deleted the database would still
refuse to go negative — with a worse message, but not with wrong data. That is
what a backstop is for.

There is a second instance of the same pattern at `schema.sql:958`,
`blood_banks_stock_non_negative`, which section 14 returns to.

### SQLSTATE — one fix needed

| Condition | SQLSTATE now | DETAIL now | Change |
|---|---|---|---|
| #9 insufficient stock | `P0001` | none | add `OUT_OF_STOCK` |
| #10 negative stock | `23514` | n/a | none |

`place_order()` raises `P0001` with no DETAIL, so `ApiException.code` is null
(`app/lib/core/network/supabase_service.dart:281`) and the cart screen cannot tell
an out-of-stock failure from an empty cart or an inactive account — all three are
bare `P0001`. The message reaches the user correctly, but the screen cannot react
by refreshing the cart, which is the useful behaviour. Add the code:

```sql
-- =====================================================================
-- 20260810000014_place_order_detail_codes.sql
--
-- Contradiction #9: attach DETAIL codes to place_order()'s raises so the
-- client can distinguish them. No logic changes -- the atomic UPDATE and
-- its WHERE clause are correct and must be preserved exactly.
--
-- Reproduce the full body from supabase/schema.sql:2664 and change ONLY
-- the `using errcode` clauses listed below.
-- =====================================================================
```

| Existing raise (`schema.sql`) | Add |
|---|---|
| `'not authenticated'` | `, detail = 'NOT_AUTHENTICATED'` |
| `'account is not active'` | `, detail = 'ACCOUNT_INACTIVE'` |
| `'cart is empty'` | `, detail = 'CART_EMPTY'` |
| `'insufficient stock for %'` | `, detail = 'OUT_OF_STOCK'` |

Keep the `%` interpolation of `v_item.product_name`. Naming the product is the
difference between an error the customer can act on and one they cannot, and
`guard()` passes the assembled message through verbatim
(`supabase_service.dart:238`).

### The Dart mapping

```dart
// Contradictions #9, #10 — stock.
'OUT_OF_STOCK': (en: 'One of the items in your cart is no longer in stock.',
                 bn: 'আপনার কার্টের একটি পণ্য আর স্টকে নেই।'),
'CART_EMPTY':   (en: 'Your cart is empty.',
                 bn: 'আপনার কার্ট খালি।'),
```

As in section 7, the server's English is more specific than the map entry because
it names the product; the map supplies the Bangla and the generic fallback.

On `OUT_OF_STOCK` the cart screen must **re-fetch the cart with current stock and
mark the offending line**, not just show a toast. The customer's next action is to
remove or reduce that item, and they cannot do it from an error message.

`23514` from the stock CHECK reaches the user as the raw constraint text
(`supabase_service.dart:226`), which reads `new row for relation
"pharmacy_products" violates check constraint "pharmacy_products_stock_check"`.
That is only ever seen by a pharmacy owner editing their own inventory, so it is
tolerable — but the inventory screen should validate `>= 0` client-side so the
message is never reached in normal use. This is one of the few places where a
client-side check is worth writing, precisely because the server-side message is
unfit for display.

### Reproduction test

The race needs two real sessions; a single transaction cannot demonstrate it.

```sql
-- Arrange (as pharmacy owner): product X, stock = 1, status 'active'.
-- Both customers have X in their cart with quantity 1.

-- Session A                          -- Session B
begin;                                begin;
set local role authenticated;         set local role authenticated;
set local request.jwt.claims =        set local request.jwt.claims =
  '{"sub":"<nadia>","role":"authenticated"}';  '{"sub":"<imran>",...}';

select public.place_order(...);
-- returns an order id, does not commit
                                      select public.place_order(...);
                                      -- BLOCKS here. This is the proof.
commit;
                                      -- unblocks, then raises:
                                      -- P0001, DETAIL OUT_OF_STOCK
                                      rollback;

-- Verify afterwards:
select stock from public.pharmacy_products where id = <X>;   -- expect 0
select count(*) from public.orders where ...;                -- expect exactly 1
```

If Session B does **not** block, the `where ... and stock >= quantity` predicate
has been removed and the guarantee is gone even though the test may still pass by
timing.

And #10 directly, which needs no concurrency:

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"<pharmacy-owner>","role":"authenticated"}';
update public.pharmacy_products set stock = -1 where id = <X>;
-- expect 23514, pharmacy_products_stock_check

update public.pharmacy_products set stock = 0 where id = <X>;
-- expect success: zero is legal, negative is not
```

---

## 10. Contradictions #11 and #12 — one payment per appointment, and the split must balance

### The invariants

| # | Invariant |
|---|---|
| 11 | An appointment cannot be paid for twice. |
| 12 | `admin_share + provider_share` must equal the amount collected, exactly. |

### #11 — enforced by four indexes, one of which may not exist

The payment path has four unique indexes, and each closes a different door.
Enumerate them before touching anything, because they are easy to confuse:

| Index | Where | Stops |
|---|---|---|
| `uq_payments_verified_appointment` | `20260809000002:590` | two **verified** payments for one appointment |
| `uq_payments_pending_appt` | `schema.sql:672` | two **pending** submissions for one appointment |
| `uq_payments_stripe_session` | `schema.sql:660` | replaying one Stripe Checkout session |
| `uq_payments_stripe_pi` | `schema.sql:664` | replaying one Stripe PaymentIntent |

The pair is deliberate and the `where` clauses are the whole design.
`uq_payments_pending_appt` covers `payment_status = 'pending'` only, so a patient
whose bKash reference was **rejected** may submit again — a full unique index on
`appointment_id` would trap them forever after one typo.
`uq_payments_verified_appointment` covers `'verified'` only, so the money side is
absolute regardless of how many rejected attempts precede it.

**Now the finding that matters.** Read `20260809000002:585-606`. The index is
created inside a `do` block that catches `unique_violation` and downgrades it to a
`raise warning`:

```sql
  exception when unique_violation then
    ...
    raise warning
      'uq_payments_verified_appointment NOT created: appointments with more
       than one verified payment: %. ...',
```

The reasoning given — that aborting the migration would leave every other fix
unapplied — is sound. The consequence is not: **if that database had duplicate
verified payments when the migration ran, the migration reported success, printed
a warning nobody read, and contradiction #11 is unenforced right now.** A warning
is not a failure, and `supabase db push` exits 0.

This is the first thing to check in Part 12, before writing any DDL:

```sql
select indisvalid, indisready
  from pg_index
 where indexrelid = to_regclass('public.uq_payments_verified_appointment');
-- ZERO ROWS means the index does not exist and #11 is open.
-- A row with indisvalid = false means a CONCURRENTLY build failed.
```

If it is missing, find and resolve the duplicates, then arm it:

```sql
-- Who is affected, and by how much money.
select p.appointment_id,
       count(*)              as verified_payments,
       sum(p.amount)         as total_taken,
       min(p.created_at)     as first_paid,
       max(p.created_at)     as last_paid,
       string_agg(p.id::text, ', ' order by p.created_at) as payment_ids
  from public.payments p
 where p.payment_status = 'verified'
 group by p.appointment_id
having count(*) > 1
 order by total_taken desc;
```

**Do not resolve these by deleting rows.** Every row is money a real person sent.
The duplicates must be refunded and marked, which is an operational decision, not
a migration. Record the list, refund the later payment of each pair through the
gateway, set its `payment_status` to `'rejected'` with a `rejection_reason`
naming the refund reference, and only then create the index. The Part 12 report
must state whether this was needed.

```sql
-- After the duplicates are cleared:
create unique index concurrently uq_payments_verified_appointment
  on public.payments (appointment_id)
  where payment_status = 'verified';
-- Then re-run the indisvalid check above. Do not skip it: CONCURRENTLY
-- fails silently into an INVALID index that enforces nothing.
```

Add the same probe to the smoke suite (section 22), because an index that can be
silently skipped once can be silently dropped later:

```sql
do $$
begin
  if to_regclass('public.uq_payments_verified_appointment') is null then
    raise exception 'contradiction #11 is unenforced: uq_payments_verified_appointment is missing';
  end if;
end $$;
```

There is also a guard raising the user-facing message before the index is reached
(`20260809000002:325`, `'You have already paid for this appointment.'`,
`errcode = 'P0001'`). That guard is the message; the index is the guarantee. Both
stay.

### #12 — enforced by a CHECK, and the CHECK is the right tool

`payments_split_check` (`supabase/schema.sql:628`):

```sql
  constraint payments_split_check check (
    (admin_share is null and provider_share is null)
    or (admin_share is not null and provider_share is not null
        and admin_share + provider_share = amount)),
```

`orders_split_check` (`schema.sql`, orders table) is its twin for pharmacy orders.
Three things about this are worth stating because each would be got wrong by
someone rewriting it:

**The three-state shape is required, not stylistic.** A payment is unverified
(both `NULL`) or settled (both set and balanced). "One set, one `NULL`" is
unrepresentable, which means no code path can leave a half-computed split behind
after an error. Writing it as `admin_share + provider_share = amount` alone would
evaluate to `NULL` when either side is `NULL`, and **a CHECK that evaluates to
`NULL` passes** — so the naive form would silently permit both `NULL`s *and*
every half-filled row. That single fact is why the verbose version exists.

**Exact equality is correct because the columns are `numeric(10,2)`.** R10 in the
master plan exists for this line. Had they been `float`, `admin_share +
provider_share = amount` would fail unpredictably on values like 333.33 + 666.67,
and someone would "fix" it with a tolerance — at which point the platform can lose
a paisa per transaction forever. `numeric` addition is exact; no tolerance is
needed and none must be added.

**It cannot be replaced by computing `provider_share` as a generated column.**
`amount - admin_share` looks tempting, but the commission percentage is resolved
at settlement time from the provider's rate (01_DATABASE.md §6.4), and a stored
generated column cannot reference another table. The split is computed by
`payments_apply_verification()` and the CHECK verifies its arithmetic.

### SQLSTATE

| Condition | SQLSTATE | DETAIL |
|---|---|---|
| #11 second verified payment, guard path | `P0001` | add `ALREADY_PAID` |
| #11 second verified payment, race path | `23505` | `uq_payments_verified_appointment` |
| #11 second pending submission | `23505` | `uq_payments_pending_appt` |
| #11 replayed Stripe session/PI | `23505` | `uq_payments_stripe_*` |
| #12 split does not balance | `23514` | n/a — `payments_split_check` |

The `P0001` guard at `20260809000002:325` carries no DETAIL. Add
`detail = 'ALREADY_PAID'` when reproducing that function — the master plan's own
example of a DETAIL code is `ALREADY_PAID`, and it is currently absent.

`_uniqueMessage()` (`app/lib/core/network/supabase_service.dart:350`) already
maps all three payment index names to "You have already paid for this
appointment." — verify those strings still match after any rename. It does **not**
map `uq_payments_pending_appt`, which is a different situation with a different
answer. Add it:

```dart
    if (d.contains('uq_payments_pending_appt')) {
      return 'A payment for this appointment is already awaiting confirmation.';
    }
```

Placed **before** the existing `uq_payments_verified_appointment` branch is
unnecessary — the names do not overlap — but keep it adjacent so the two are read
together.

### The Dart mapping

```dart
// Contradictions #11, #12 — payment uniqueness and the money split.
'ALREADY_PAID':   (en: 'You have already paid for this appointment.',
                   bn: 'আপনি ইতিমধ্যে এই অ্যাপয়েন্টমেন্টের জন্য পেমেন্ট করেছেন।'),
'PAYMENT_PENDING':(en: 'A payment for this appointment is already awaiting confirmation.',
                   bn: 'এই অ্যাপয়েন্টমেন্টের একটি পেমেন্ট ইতিমধ্যে নিশ্চিতকরণের অপেক্ষায় আছে।'),
```

`23514` from `payments_split_check` must **never** be shown to a patient. It can
only mean the platform's own settlement arithmetic is wrong, and the correct
response is an admin alert, not a dialogue. In the payment screens, treat a
`23514` whose message contains `split_check` as an internal error: show the
generic "Something went wrong on our side" copy and log the raw text.

```dart
// In the payment result handler.
if (e.statusCode == 422 && e.message.contains('split_check')) {
  // Platform arithmetic failure, not a user error. Never blame the user.
  return  (en: 'Something went wrong on our side. Your payment was not taken.',
           bn: 'আমাদের দিকে কিছু সমস্যা হয়েছে। আপনার পেমেন্ট নেওয়া হয়নি।');
}
```

### Reproduction test

```sql
begin;
-- #12 first, because it needs no fixture beyond one payment row.
set local role postgres;   -- the split is written by a trusted path
insert into public.payments (appointment_id, user_id, amount, payment_method,
                             payment_status, admin_share, provider_share)
values (<A>, '<patient>', 500.00, 'bKash', 'verified', 50.00, 400.00);
-- expect 23514, payments_split_check   (50 + 400 <> 500)

insert into public.payments (...) values (<A>, '<patient>', 500.00, 'bKash',
                                          'verified', 50.00, null);
-- expect 23514: half-filled splits are unrepresentable

insert into public.payments (...) values (<A>, '<patient>', 500.00, 'bKash',
                                          'verified', 50.00, 450.00);
-- expect success

-- #11: a second verified payment for the same appointment.
insert into public.payments (...) values (<A>, '<patient>', 500.00, 'bKash',
                                          'verified', 50.00, 450.00);
-- expect 23505, uq_payments_verified_appointment
-- IF THIS SUCCEEDS the index was never created. Go back to the top of
-- this section.
rollback;
```

The middle case — half-filled split — is the one that catches a rewritten CHECK.
A developer simplifying the constraint to `admin_share + provider_share = amount`
would see cases one and three behave correctly and ship the bug.

---

## 11. Contradiction #13 — a payout cannot exceed what was collected

**Status: partially enforced. The amount is unvalidated. This is new work.**

### The invariant

A payout to a provider must equal the `provider_share` of the payment or order it
settles, and each source may be settled at most once.

### What exists

`provider_payouts` (`supabase/schema.sql`) carries four CHECKs:

```sql
  constraint provider_payouts_source_check check (
    (payment_id is not null and order_id is null)
    or (payment_id is null and order_id is not null)),
  constraint provider_payouts_amount_check check (amount >= 0),
  constraint provider_payouts_commission_check
    check (commission_percentage >= 0 and commission_percentage <= 100),
  constraint provider_payouts_status_check
    check (status in ('pending', 'paid', 'reversed'))
```

`provider_payouts_source_check` is the XOR that 01_DATABASE.md §6.3 cites as
precedent: exactly one of `payment_id` / `order_id`, never both, never neither. It
is good work and it is not the rule that is missing.

**Nothing relates `amount` to the money actually collected.** `amount >= 0` admits
50,000.00 against a payment of 500.00. And no unique constraint stops the same
`payment_id` being paid out twice.

### The failure scenario

Dr Rahman's consultation, ৳500. `payments_apply_verification()` computes
`admin_share = 50.00`, `provider_share = 450.00` and writes a payout row for
450.00. Correct.

Now the two ways it goes wrong, neither of which needs an attacker:

**Duplicate settlement.** An admin runs the settlement batch, the connection drops
before the response arrives, and they run it again. Two payout rows for
`payment_id = 8812`, ৳450 each. The platform pays ৳900 against ৳500 collected and
is ৳450 down, plus its own ৳50 commission. Nothing in the schema objects. This
compounds: it is invisible until a reconciliation nobody has scheduled.

**Amount drift.** `provider_payouts_update_admin` (`supabase/rls_policies.sql:529`)
lets an admin update any payout row, including `amount`. RLS can express *who* may
write; it cannot express *which columns* — the same limitation section 12 covers
for role escalation. An admin account (or anything that has obtained one) can
change a payout from 450.00 to 45000.00 and mark it `paid`.

The precise timing:

```
Tue 11:04:22  Admin A runs settlement for payment 8812. Payout #501, 450.00.
Tue 11:04:31  Response times out at the proxy. A sees a spinner, then an error.
Tue 11:05:10  A re-runs it. Payout #502, 450.00, same payment_id.
Tue 18:00     Disbursement job pays both. Provider receives 900.00.
```

There is no race here at all, which is the point: this is a correctness gap that
ordinary operational noise triggers. It does not need concurrency to bite.

### The DDL

```sql
-- =====================================================================
-- 20260810000015_payout_amount_integrity.sql
--
-- Contradiction #13: a payout must match the provider_share of its
-- source, and each source settles at most once.
--
-- Depends on: payments.provider_share, orders.provider_share (both
-- present since 20260806000003).
-- =====================================================================

-- One payout per source. Partial and separate, because the XOR means
-- exactly one column is non-null in every row and a composite index
-- would be useless.
create unique index uq_provider_payouts_payment
  on public.provider_payouts (payment_id)
  where payment_id is not null and status <> 'reversed';

create unique index uq_provider_payouts_order
  on public.provider_payouts (order_id)
  where order_id is not null and status <> 'reversed';
```

The `status <> 'reversed'` clause is deliberate and mirrors the reasoning in
section 3. A reversed payout must not permanently block re-settlement: if a
disbursement fails at the bank and is reversed, the platform has to pay it again.
Excluding reversed rows makes the source settleable once more, while `pending` and
`paid` rows still hold the slot.

Check for existing duplicates before creating either, as in section 10:

```sql
select payment_id, count(*), sum(amount)
  from public.provider_payouts
 where payment_id is not null and status <> 'reversed'
 group by payment_id having count(*) > 1;
-- Must be empty. Any row here is money already over-paid: reverse the
-- later payout (do not delete it) and record the recovery separately.
```

Now the amount. This cannot be a CHECK — a CHECK cannot read another table — so it
is a trigger:

```sql
create or replace function public.provider_payouts_validate_amount()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_share    numeric(10,2);
  v_provider uuid;
begin
  if new.payment_id is not null then
    select p.provider_share, d.user_id
      into v_share, v_provider
      from public.payments p
      join public.appointments a on a.id = p.appointment_id
      join public.doctors      d on d.id = a.doctor_id
     where p.id = new.payment_id
       and p.payment_status = 'verified';
    if not found then
      raise exception 'A payout requires a verified payment.'
        using errcode = 'P0001', detail = 'PAYOUT_SOURCE_UNVERIFIED';
    end if;
  else
    select o.provider_share, ph.user_id
      into v_share, v_provider
      from public.orders     o
      join public.pharmacies ph on ph.id = o.pharmacy_id
     where o.id = new.order_id
       and o.payment_status = 'paid';
    if not found then
      raise exception 'A payout requires a paid order.'
        using errcode = 'P0001', detail = 'PAYOUT_SOURCE_UNVERIFIED';
    end if;
  end if;

  if v_share is null then
    raise exception 'That payment has not been split yet.'
      using errcode = 'P0001', detail = 'PAYOUT_NOT_SPLIT';
  end if;

  if new.amount is distinct from v_share then
    raise exception
      'A payout must equal the provider share of its source (expected %, got %).',
      v_share, new.amount
      using errcode = 'P0001', detail = 'PAYOUT_AMOUNT_MISMATCH';
  end if;

  -- The recipient is derived, never supplied. Otherwise an admin could
  -- redirect a correct amount to the wrong account, which no amount
  -- check would catch.
  new.provider_user_id := v_provider;

  return new;
end;
$$;

revoke all on function public.provider_payouts_validate_amount() from public, anon, authenticated;

create trigger aa_validate_payout_amount
  before insert or update of amount, payment_id, order_id, provider_user_id
  on public.provider_payouts
  for each row execute function public.provider_payouts_validate_amount();
```

Three points on the design:

**No `write_is_trusted()` escape.** `payments_apply_verification()` writes payouts
from the trusted path, and it is exactly the writer whose arithmetic this
validates. An escape hatch would exempt the only caller that matters — the same
reasoning as section 7.

**It fires on `UPDATE OF amount` as well as `INSERT`**, which is what closes the
`provider_payouts_update_admin` hole. An admin marking a payout `paid` does not
touch `amount`, so the trigger does not fire and the normal workflow is unaffected;
an admin *changing* `amount` triggers a full revalidation against the source.

**It overwrites `provider_user_id` rather than checking it.** Deriving is stronger
than validating: there is no supplied value left to be wrong.

### SQLSTATE

| Condition | SQLSTATE | DETAIL |
|---|---|---|
| amount ≠ provider_share | `P0001` | `PAYOUT_AMOUNT_MISMATCH` |
| source not verified/paid | `P0001` | `PAYOUT_SOURCE_UNVERIFIED` |
| source not split yet | `P0001` | `PAYOUT_NOT_SPLIT` |
| duplicate settlement | `23505` | `uq_provider_payouts_payment` / `_order` |
| negative amount | `23514` | `provider_payouts_amount_check` |

### The Dart mapping

These are admin-facing, so the Bangla matters less in practice — but the admin app
uses the same `preferred_language`, so supply both:

```dart
// Contradiction #13 — payout integrity. Admin-facing.
'PAYOUT_AMOUNT_MISMATCH':   (en: 'A payout must equal the provider share of its source.',
                             bn: 'পেআউট অবশ্যই এর উৎসের প্রোভাইডার শেয়ারের সমান হতে হবে।'),
'PAYOUT_SOURCE_UNVERIFIED': (en: 'That payment or order has not been verified yet.',
                             bn: 'এই পেমেন্ট বা অর্ডার এখনো যাচাই করা হয়নি।'),
'PAYOUT_NOT_SPLIT':         (en: 'That payment has not been split into shares yet.',
                             bn: 'এই পেমেন্ট এখনো শেয়ারে ভাগ করা হয়নি।'),
```

```dart
    if (d.contains('uq_provider_payouts_payment') ||
        d.contains('uq_provider_payouts_order')) {
      return 'That payment has already been settled.';
    }
```

The duplicate-settlement message is the important one, and it should be shown as
**information, not failure**: the admin's retry did the right thing and the first
attempt succeeded. Present it as "Already settled — payout #501" with a link,
which is what the admin actually needs to know.

### Reproduction test

```sql
begin;
set local role postgres;   -- payouts are written by trusted paths only

-- Fixture: payment 8812, verified, amount 500.00, split 50/450.

-- 1. Correct payout: accepted.
insert into public.provider_payouts
  (provider_user_id, payment_id, amount, commission_percentage)
values ('<wrong-uuid-on-purpose>', 8812, 450.00, 10.00)
returning provider_user_id;
-- expect success, and provider_user_id RETURNED AS THE DOCTOR'S uuid,
-- not the wrong one supplied. That proves the derivation.

-- 2. Duplicate settlement of the same payment.
insert into public.provider_payouts (...) values (..., 8812, 450.00, 10.00);
-- expect 23505 / uq_provider_payouts_payment

-- 3. Inflated amount on a fresh payment 8813 (500.00, split 50/450).
insert into public.provider_payouts (...) values (..., 8813, 45000.00, 10.00);
-- expect P0001 / PAYOUT_AMOUNT_MISMATCH, message naming 450.00 and 45000.00

-- 4. The update path — the RLS hole.
update public.provider_payouts set amount = 45000.00 where id = <first-payout>;
-- expect P0001 / PAYOUT_AMOUNT_MISMATCH

-- 5. Marking paid without touching amount: must still work.
update public.provider_payouts set status = 'paid', paid_at = now()
 where id = <first-payout>;
-- expect success

-- 6. Reversal frees the source for re-settlement.
update public.provider_payouts set status = 'reversed' where id = <first-payout>;
insert into public.provider_payouts (...) values (..., 8812, 450.00, 10.00);
-- expect success
rollback;
```

Cases 4 and 5 must both be run. A trigger written as `before insert or update`
without the `of amount, ...` column list would fire on case 5 too — harmlessly
here, but it would revalidate against the source on every status change, and a
payout for a payment later refunded to `'rejected'` could then no longer be marked
paid. Cases 4 and 5 together are what pin the column list down.

---

## 12. Contradiction #14 — a patient cannot promote themselves

**Status: enforced. Verify it, understand it, and do not "simplify" it.**

### The invariant

A non-admin cannot change `users.role`, `users.email`, `users.is_active`, or any
provider's `verification_status`, `status`, `rating`, `is_deleted` or
`commission_percentage`.

### The failure scenario

Nusrat has an ordinary patient account. The app lets her edit her own profile, so
a policy must permit her to update her own `users` row —
`users_update_own` (`supabase/rls_policies.sql`) checks `id = auth.uid()`.

```
23:10:00  Nusrat opens any REST tool with her own valid JWT.
23:10:04  PATCH /rest/v1/users?id=eq.<her-uuid>
          {"role":"admin"}
```

Every policy is satisfied. She is authenticated, the row is hers, `USING` and
`WITH CHECK` both pass. **RLS has no opinion about which columns changed.**

One second later she is an admin: `is_admin()` returns true for her, every
`*_select_admin` policy opens, she can read every patient's medical history,
verify her own doctor account, approve her own reviews, and mark payouts paid.

The same shape applies to a doctor setting `verification_status = 'verified'` on
their own `doctors` row — skipping the platform's licence check entirely — or
setting `commission_percentage = 0` to keep the platform's cut.

**This is the most severe item in the list and the cheapest to exploit.** It needs
no race, no timing, no second account, and no tooling beyond curl.

### Why RLS cannot express it

An RLS policy is a boolean over the row. `WITH CHECK` sees the *new* row; it does
not see the old one, so it cannot say "this column must not have changed".

`WITH CHECK (role = 'patient')` fails immediately: it would prevent an admin's own
row from ever being updated, and it hardcodes a value rather than an invariant.
`WITH CHECK (role = (select role from users where id = auth.uid()))` reads the
table being written and is both recursive and racy.

Column-level immutability is a `BEFORE UPDATE` trigger's job, because a trigger is
the only construct that sees `OLD` and `NEW` together.

### What exists

`guard_admin_only_columns()` — live version at
`20260809000002_payment_architecture_fix.sql:422` — is a generic trigger driven by
`TG_ARGV`:

```sql
  foreach v_col in array tg_argv loop
    if v_new -> v_col is distinct from v_old -> v_col then
      raise exception
        'column %.% may only be changed by an administrator',
        tg_table_name, v_col
        using errcode = '42501';
    end if;
  end loop;
```

The `jsonb` comparison is the design decision worth understanding. `to_jsonb(old)`
and `to_jsonb(new)` let one function guard any column of any table without knowing
its type, and `is distinct from` on `jsonb` handles `NULL` on either side
correctly — where `v_new.role <> v_old.role` would evaluate to `NULL` and pass when
either was `NULL`. The same `NULL`-passes-the-check trap as section 10's split
constraint, avoided the same way.

Wired at `supabase/rls_policies.sql:154` onwards:

| Trigger | Table | Guarded columns |
|---|---|---|
| `aa_guard_users` | `users` | `role`, `email`, `is_active` |
| `aa_guard_doctors` | `doctors` | `verification_status`, `status`, `rating`, `total_reviews`, `rejection_reason`, `is_deleted`, `commission_percentage` |
| `aa_guard_hospitals` | `hospitals` | same seven |
| `aa_guard_clinics` | `clinics` | same seven |
| `aa_guard_pharmacies` | `pharmacies` | same seven |
| `aa_guard_reviews` | `reviews` | `status` |
| `aa_guard_feedback` | `feedback` | `admin_response`, `status`, `priority` |
| `aa_guard_orders` | `orders` | `order_number`, `subtotal`, `delivery_fee`, `total`, … |
| `aa_guard_appointments` | `appointments` | `fee`, … (section 14) |

The `aa_` prefix is not decoration. Postgres fires same-event `BEFORE` row triggers
in **alphabetical order by trigger name**, and these must run before any guard that
acts on the new values. Keep the prefix on anything added here.

### The discriminator — the brief's version is two generations out of date

The master plan describes this guard as early-returning when
`current_user not in ('authenticated','anon')`. **Do not write that.** It has been
wrong twice and is now correct in a third form. The history:

| Version | Test | Why it was replaced |
|---|---|---|
| `20260806000001` | `current_user not in ('authenticated','anon')` | the function is `SECURITY DEFINER`, so `current_user` is the **owner** (`postgres`) for every caller. The guard exempted everyone and enforced nothing. |
| `20260806000004` | `session_user <> 'authenticator'` | correct for PostgREST traffic, but blocks internal trigger paths that legitimately need to write guarded columns (e.g. `payments_apply_verification()` setting `appointments.payment_status`) when they run under the same session. |
| `20260809000002` | `public.write_is_trusted()` | current and correct. |

`write_is_trusted()` (`20260809000002`):

```sql
  select public.trusted_path_active()
      or session_user <> 'authenticator'
      or public.is_admin();
```

Three disjuncts, each earning its place: an explicit transaction-local marker set
by a trusted function, the non-PostgREST connection case, and admin callers. Note
that the `is_admin()` check moved *into* `write_is_trusted()` — the older
standalone `if public.is_admin() then return new; end if;` that
`supabase/rls_policies.sql:127` still shows is now redundant, which is why the live
version does not have it.

**`supabase/rls_policies.sql` still shows the `session_user` version at line 117.**
That file is a stale snapshot, exactly like `schema.sql` (see section 1). Verify
against the database, never the file:

```sql
select pg_get_functiondef('public.guard_admin_only_columns()'::regprocedure);
-- Must contain write_is_trusted(). If it contains current_user, the
-- guard is inert and #14 is wide open.
```

### The gap check

The guard is only as good as its column lists. Any privileged column added later
is unguarded until someone remembers. Run this after every schema change:

```sql
-- Guarded columns, per table, as actually wired.
select c.relname as table_name,
       t.tgname,
       (select array_agg(a) from unnest(tgargs_text(t)) a) as guarded
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
 where not t.tgisinternal
   and t.tgfoid = 'public.guard_admin_only_columns'::regproc
 order by 1;
```

`tgargs` is a null-separated `bytea`, so if no helper exists, read the arguments
the simple way:

```sql
select c.relname, pg_get_triggerdef(t.oid)
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
 where not t.tgisinternal
   and t.tgfoid = 'public.guard_admin_only_columns'::regproc
 order by 1;
```

Compare the output against every column a client must not set. Two additions this
project needs:

```sql
-- 20260810000016_guard_column_coverage.sql
-- Contradiction #14: extend column coverage to fields added since the
-- guards were wired. Recreating the trigger is the only way to change
-- TG_ARGV -- there is no ALTER TRIGGER ... SET ARGUMENTS.

drop trigger if exists aa_guard_users on public.users;
create trigger aa_guard_users
  before update on public.users
  for each row execute function
    public.guard_admin_only_columns('role', 'email', 'is_active', 'phone_verified');
```

`phone_verified` (01_DATABASE.md §6.1) must be here: a self-settable "verified"
flag is worth nothing. 01_DATABASE.md §6.1 notes it was deliberately left off
pending this section — this is where it is added.

`preferred_language` must **not** be added. It is the user's own setting.

### SQLSTATE and the Dart mapping

`42501`, no DETAIL. `guard()` maps it at
`app/lib/core/network/supabase_service.dart:189` to a 403 with
"You do not have permission to do that." plus the raw text.

This is one of the few places where the generic message is the right one. A client
reaching this guard is either broken or hostile, and neither deserves a
better-targeted error. Do **not** add a DETAIL code here — a machine-readable code
would tell an attacker exactly which column tripped, and there is no legitimate
screen that needs to branch on it.

```dart
// Contradiction #14 — no Dart mapping by design. The generic 403 in
// supabase_service.dart:189 is correct and deliberately uninformative.
```

If a legitimate screen ever hits this, the screen is wrong: it is sending a column
it should not have in its update map. Fix the repository, not the guard.

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient-uuid>","role":"authenticated"}';

-- The headline attack.
update public.users set role = 'admin' where id = '<patient-uuid>';
-- expect 42501, 'column users.role may only be changed by an administrator'

update public.users set is_active = true where id = '<patient-uuid>';
-- expect 42501 even though the value may be unchanged in spirit --
-- 'is distinct from' compares actual values, so a no-op update passes.

-- The legitimate edit must still work.
update public.users set name = 'Nusrat Jahan', address = 'Dhanmondi'
 where id = '<patient-uuid>';
-- expect success

-- Doctor self-verification.
set local request.jwt.claims = '{"sub":"<doctor-uuid>","role":"authenticated"}';
update public.doctors set verification_status = 'verified'
 where user_id = '<doctor-uuid>';
-- expect 42501

update public.doctors set commission_percentage = 0 where user_id = '<doctor-uuid>';
-- expect 42501

-- Doctor editing their own legitimate fields.
update public.doctors set consultation_fee = 800, available_to = '21:00'
 where user_id = '<doctor-uuid>';
-- expect success
rollback;
```

Then prove the trusted path still works, which is what the third discriminator
generation exists for:

```sql
-- As an admin, the same write must succeed.
set local request.jwt.claims = '{"sub":"<admin-uuid>","role":"authenticated"}';
update public.doctors set verification_status = 'verified' where id = <D>;
-- expect success

-- And an internal path: verifying a payment must be able to move
-- appointments.payment_status, which aa_guard_appointments guards.
select public.payments_verify(<payment-id>);   -- or the project's equivalent
-- expect success, not 42501
```

That last case is the regression the `session_user` generation caused. If it
raises `42501`, `write_is_trusted()` is not being consulted or the trusted-path
marker is not being set.

---

## 13. Contradiction #15 — the fee is frozen at booking

**Status: enforced. One clarification and one gap.**

### The invariant

Once an appointment exists, its `fee` cannot change — not by the patient, not by
the doctor, not by raising the doctor's `consultation_fee` afterwards.

### The failure scenario

Two versions, one malicious and one accidental. The accidental one is the reason
this matters.

**Malicious.** Sabbir books a ৳1,500 consultation. Before paying:

```
20:14:33  PATCH /rest/v1/appointments?id=eq.4471   {"fee": 1}
20:14:35  He pays ৳1 through bKash.
20:14:40  payments_apply_verification splits 1.00 into 0.10 / 0.90.
```

The doctor is owed ninety paisa for a consultation they will still perform.

**Accidental, and far commoner.** Dr Rahman raises `consultation_fee` from ৳500 to
৳800 on 1 September. Forty patients booked in August at ৳500 and have not yet paid.

```
Sep 01 10:00  UPDATE doctors SET consultation_fee = 800 WHERE id = 12;
Sep 01 10:00  If fee were read live at payment time, all 40 unpaid
              appointments would silently reprice to 800.
```

Forty patients would be charged ৳300 more than the amount they agreed to. No
attacker, no race — just a price change, which providers do routinely.

### What exists, and the part that actually does the work

Two mechanisms, and it is worth being precise about which does what, because the
master plan's row 15 credits only the second.

**Copy-on-write, at booking.** `guard_appointments_insert()`
(`20260809000002_payment_architecture_fix.sql:246`) does not accept the client's
fee. It reads the doctor's and overwrites:

```sql
  select d.consultation_fee, u.name
    into v_fee, v_name
    from public.doctors d ...
  new.fee                 := v_fee;
  new.doctor_name         := v_name;
```

This is what makes the *accidental* case impossible: the fee is a snapshot on the
appointment row, not a live lookup. `doctor_name` is snapshotted for the same
reason — a doctor changing their display name must not rewrite history.

**Immutability, after booking.** `aa_guard_appointments`
(`supabase/rls_policies.sql:181`) guards `fee` alongside the three payment
columns:

```sql
create trigger aa_guard_appointments
  before update on public.appointments
  for each row execute function public.guard_admin_only_columns(
    'payment_status', 'payment_verified_at', 'payment_verified_by', 'fee');
```

Together these are complete for #15: the value cannot be supplied, and it cannot
be changed.

### The gap: rescheduling

`appointments_guard_reschedule` (`20260806000010`) lets a patient move a booking to
a new date and time. It does **not** re-read the fee — correctly, since the price
is frozen. But nothing stops a patient rescheduling onto a *different doctor*, if
`doctor_id` is writable, thereby carrying a cheap doctor's ৳300 fee to an expensive
one's ৳2,000 slot.

Check whether `doctor_id` is guarded:

```sql
select pg_get_triggerdef(t.oid)
  from pg_trigger t
 where t.tgrelid = 'public.appointments'::regclass
   and t.tgname = 'aa_guard_appointments';
-- If 'doctor_id' is absent from the argument list, apply the fix below.
```

```sql
-- 20260810000017_freeze_appointment_doctor.sql
-- Contradiction #15: the fee is frozen to a doctor, so the doctor must
-- be frozen too. Rescheduling changes the time, never the provider --
-- a different doctor is a different booking.
drop trigger if exists aa_guard_appointments on public.appointments;
create trigger aa_guard_appointments
  before update on public.appointments
  for each row execute function public.guard_admin_only_columns(
    'payment_status', 'payment_verified_at', 'payment_verified_by',
    'fee', 'doctor_id', 'patient_id');
```

`patient_id` belongs there for the same reason: transferring an appointment to
another user would move a paid consultation to someone who did not pay for it.

### SQLSTATE and the Dart mapping

`42501`, no DETAIL, generic 403 — as section 12. No mapping by design.

The booking screen must send `fee` on **neither** insert nor update. On insert the
guard overwrites it; on update the guard rejects it. A repository that includes
`fee` in its update map will fail every reschedule, and the error will look
mysterious because the user did not touch the price. Audit:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "'fee'" app/lib/features/*/data/ app/lib/data/ 2>/dev/null
# Any occurrence inside an update payload is a bug.
```

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient>","role":"authenticated"}';

-- Copy-on-write: a supplied fee is ignored, not honoured.
insert into public.appointments
  (patient_id, doctor_id, appointment_date, appointment_time, fee)
values ('<patient>', <D-fee-1500>, current_date + 1, '18:00', 1.00)
returning fee;
-- expect 1500.00, NOT 1.00

-- Immutability.
update public.appointments set fee = 1 where id = <that-id>;
-- expect 42501

-- Provider swap.
update public.appointments set doctor_id = <expensive-doctor> where id = <that-id>;
-- expect 42501 after 20260810000017

-- A legitimate reschedule must still work.
update public.appointments set appointment_date = current_date + 2,
                               appointment_time = '19:00'
 where id = <that-id>;
-- expect success
rollback;

-- The accidental case, which needs no client at all:
-- as admin, raise the doctor's price, then confirm nothing moved.
update public.doctors set consultation_fee = 800 where id = <D-fee-1500>;
select fee from public.appointments where id = <that-id>;
-- expect the original 1500.00
```

That final check is the one worth automating. It is the only one that catches a
future refactor replacing `appointments.fee` with a join to `doctors`.

---

## 14. Contradiction #16 — blood units cannot go negative

**Status: partially enforced. The CHECK exists; nothing decrements safely.**

### The invariant

A blood bank's unit count for any group can never fall below zero, and two
requests cannot both claim the last unit.

### What exists

`blood_banks_stock_non_negative` (`supabase/schema.sql:958`):

```sql
  constraint blood_banks_stock_non_negative check (
    blood_a_positive  >= 0 and blood_a_negative  >= 0 and
    blood_b_positive  >= 0 and blood_b_negative  >= 0 and
    blood_ab_positive >= 0 and blood_ab_negative >= 0 and
    blood_o_positive  >= 0 and blood_o_negative  >= 0
  )
```

The floor is solid. **There is no decrement path at all** — no function analogous
to `place_order()`, and eight separate columns rather than a row per group, so
there is nothing to lock and nothing that knows which column a `blood_request`
refers to.

### The failure scenario

`blood_banks.blood_o_negative = 1`. O− is the universal donor; this is the unit
everyone wants at 03:00.

```
03:12:44.100  Dhaka Medical requests 1 unit O- for a road accident.
03:12:44.130  A private clinic requests 1 unit O- for a surgery.
03:12:44.900  Bank staff open request 1, see "1 available", approve it.
03:12:45.200  Bank staff open request 2, see "1 available", approve it.
```

Both are approved. Neither write touched `blood_o_negative`, because no code path
does. The CHECK never fires — nothing decremented. Two hospitals dispatch for one
unit, and the ambulance that loses finds out on arrival.

Note carefully that this failure does **not** violate the CHECK. The constraint
guards a column nobody writes. **A constraint on an unused column enforces
nothing**, and that is the finding for #16.

### The decision: enforce the floor, do not fake the ledger

A correct implementation needs a `blood_bank_inventory` table keyed by
`(blood_bank_id, blood_group)` with a row per group, plus an atomic decrement in
the pattern of `place_order()` (section 9). That is a schema redesign that
contradicts D1 (extend, do not restructure) and R2 (never rename), and it changes
`blood_banks` columns the Dart repository reads today.

**What Part 12 does instead**, honestly and in this order:

1. Keep the CHECK. It is correct and costs nothing.
2. Add the missing atomic decrement **against the existing eight columns**, so
   there is one safe writer.
3. Guard the columns against direct client writes.
4. Record in the completion report that O−-style contention is mitigated, not
   eliminated, because approval and dispatch are separate real-world steps.

### The DDL

```sql
-- =====================================================================
-- 20260810000018_blood_unit_decrement.sql
--
-- Contradiction #16: give the non-negative CHECK something to guard by
-- providing the only safe decrement path, in the atomic-UPDATE pattern
-- of place_order() (see 12_LOGICAL_INTEGRITY.md section 9).
-- =====================================================================

create or replace function public.blood_bank_dispense(
  p_bank_id     bigint,
  p_blood_group text,
  p_units       integer default 1
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_col       text;
  v_remaining integer;
begin
  if not public.is_admin()
     and not exists (select 1 from public.users u
                      where u.id = (select auth.uid()) and u.role = 'admin') then
    raise exception 'Only an administrator can dispense blood units.'
      using errcode = '42501', detail = 'NOT_ADMIN';
  end if;

  if p_units is null or p_units < 1 then
    raise exception 'Units must be at least 1.'
      using errcode = 'P0001', detail = 'INVALID_UNITS';
  end if;

  -- Map the group to its column. A CASE, not string concatenation into
  -- dynamic SQL from a caller-supplied value -- that would be injectable.
  v_col := case upper(btrim(p_blood_group))
             when 'A+'  then 'blood_a_positive'
             when 'A-'  then 'blood_a_negative'
             when 'B+'  then 'blood_b_positive'
             when 'B-'  then 'blood_b_negative'
             when 'AB+' then 'blood_ab_positive'
             when 'AB-' then 'blood_ab_negative'
             when 'O+'  then 'blood_o_positive'
             when 'O-'  then 'blood_o_negative'
           end;
  if v_col is null then
    raise exception 'Unknown blood group: %', p_blood_group
      using errcode = 'P0001', detail = 'UNKNOWN_BLOOD_GROUP';
  end if;

  -- One conditional UPDATE. The WHERE clause is the guarantee: a second
  -- session blocks on the row lock, re-evaluates after commit, and finds
  -- the predicate false. Identical mechanism to place_order().
  execute format(
    'update public.blood_banks
        set %1$I = %1$I - $1, updated_at = now()
      where id = $2 and %1$I >= $1
      returning %1$I', v_col)
    into v_remaining
    using p_units, p_bank_id;

  if v_remaining is null then
    raise exception 'Not enough % units are available.', p_blood_group
      using errcode = 'P0001', detail = 'BLOOD_OUT_OF_STOCK';
  end if;

  return v_remaining;
end;
$$;

revoke all on function public.blood_bank_dispense(bigint, text, integer)
  from public, anon;
grant execute on function public.blood_bank_dispense(bigint, text, integer)
  to authenticated;
```

`format(..., %1$I)` with the column name resolved from a fixed `CASE` is safe:
the identifier can only be one of eight literals this function chose. Passing
`p_blood_group` into `format` directly would be an injection, which is why the
`CASE` exists rather than a lookup.

Then close the direct-write path, so the function is the *only* writer:

```sql
create trigger aa_guard_blood_banks
  before update on public.blood_banks
  for each row execute function public.guard_admin_only_columns(
    'blood_a_positive',  'blood_a_negative',
    'blood_b_positive',  'blood_b_negative',
    'blood_ab_positive', 'blood_ab_negative',
    'blood_o_positive',  'blood_o_negative');
```

Admins still pass — `write_is_trusted()` includes `is_admin()` — so restocking by
hand keeps working. What is blocked is an ordinary authenticated client writing
these columns directly, which no screen should do.

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | DETAIL |
|---|---|---|
| insufficient units | `P0001` | `BLOOD_OUT_OF_STOCK` |
| unknown group string | `P0001` | `UNKNOWN_BLOOD_GROUP` |
| non-admin caller | `42501` | `NOT_ADMIN` |
| negative via any other path | `23514` | `blood_banks_stock_non_negative` |

```dart
// Contradiction #16 — blood inventory.
'BLOOD_OUT_OF_STOCK':  (en: 'Not enough units of that blood group are available.',
                        bn: 'এই রক্তের গ্রুপের পর্যাপ্ত ইউনিট নেই।'),
'UNKNOWN_BLOOD_GROUP': (en: 'That blood group is not recognised.',
                        bn: 'এই রক্তের গ্রুপটি সনাক্ত করা যায়নি।'),
```

`BLOOD_OUT_OF_STOCK` is an emergency-context message. The screen must show the
nearest alternative banks holding that group, not a bare error — a user seeing
this at 03:00 needs a next step, not an apology.

### Reproduction test

```sql
-- Fixture: bank B with blood_o_negative = 1.

-- Session A                             -- Session B
begin;                                   begin;
set local request.jwt.claims =           set local request.jwt.claims =
  '{"sub":"<admin>","role":"authenticated"}';   '{"sub":"<admin2>",...}';
select public.blood_bank_dispense(<B>, 'O-', 1);
-- returns 0
                                         select public.blood_bank_dispense(<B>,'O-',1);
                                         -- BLOCKS
commit;
                                         -- unblocks, raises
                                         -- P0001 / BLOOD_OUT_OF_STOCK
                                         rollback;

select blood_o_negative from public.blood_banks where id = <B>;   -- expect 0
```

And the floor, plus the new guard:

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient>","role":"authenticated"}';
update public.blood_banks set blood_o_negative = 99 where id = <B>;
-- expect 42501 after aa_guard_blood_banks

set local role postgres;
update public.blood_banks set blood_o_negative = -1 where id = <B>;
-- expect 23514, blood_banks_stock_non_negative
--   even as postgres: a CHECK has no trusted-path exemption, which is
--   exactly why it is the backstop.
```

---

## 15. Contradiction #17 — status moves only along legal edges

**Status: enforced. One DETAIL-code bug to fix.**

### The invariant

An appointment's status may change only along the edges of the state machine, and
only an actor entitled to that edge may make it.

### The failure scenario

Two shapes, and the second is the expensive one.

**Resurrection.** Sabbir cancels an appointment at 09:00 and is refunded by
`appointments_refund()`. At 09:20 he PATCHes it back:

```
09:20:11  PATCH /rest/v1/appointments?id=eq.4471   {"status":"confirmed"}
```

He owns the row, so `appointments_update_patient` permits it. He now holds a
confirmed booking he has been refunded for. The slot is also blocked again,
because `uq_appointments_doctor_slot` counts anything not `cancelled`/`expired`
(section 3) — so the resurrection re-takes a slot that was released and possibly
already sold to someone else, producing a duplicate that the index cannot catch
because the two rows were never simultaneously active.

**Self-completion.** A patient sets `status = 'completed'` on their own
`pending_payment` booking. After section 5's fix, `completed` is the condition for
leaving a review; a patient who can self-complete can review a doctor they never
saw, reopening contradiction #2 from a different direction.

### What exists

`appointments_guard_transition()`
(`20260809000002_payment_architecture_fix.sql:661`) holds the edge table:

```sql
  v_ok := case old.status
    when 'pending_payment' then new.status in ('pending', 'confirmed', 'cancelled', 'expired')
    when 'pending'         then new.status in ('confirmed', 'cancelled', 'expired')
    when 'confirmed'       then new.status in ('completed', 'cancelled', 'expired')
    else false
  end;
```

The `else false` is the strongest line in the function. `cancelled`, `completed`
and `expired` are **terminal**: they match no `when`, so every edge out of them is
illegal. Resurrection is impossible by construction rather than by enumeration —
nobody has to remember to forbid `cancelled -> confirmed` specifically.

Actor rules are separated deliberately. `appointments_guard_confirm()`
(`20260809000002:449`) owns "only the owning doctor may confirm or complete";
this function owns legality only. The comment at `:655` states the reasoning: two
concerns in one function drift apart. Preserve the split.

### The discriminator here is deliberately NOT `write_is_trusted()`

```sql
  if session_user <> 'authenticator' or public.is_admin() then
    return new;
  end if;
```

Everywhere else in this document the correct test is `public.write_is_trusted()`
(section 12). **Here it would be wrong**, and the difference is the point.

`write_is_trusted()` includes `trusted_path_active()`, which is set by the
project's own SECURITY DEFINER functions. Using it would let
`appointments_book()`, `appointments_refund()` and every future RPC move status
anywhere. The comment at `:673` says exactly this: *"A state machine our own
server code can sidestep is not a state machine."*

So the escape here is narrower on purpose: direct database sessions and admins
only. Application RPCs obey the table like everyone else. If someone "unifies the
discriminators" as a tidy-up, this guarantee disappears silently. Leave a comment
saying so if you touch the function.

Note the second block at `:695` uses `trusted_path_active()` — for the *actor*
rule, where an RPC legitimately acts on the user's behalf. Two different tests in
one function, each correct for its own question.

### The bug: the DETAIL code is unreadable

```sql
    raise exception 'This appointment cannot move from % to %.', old.status, new.status
      using errcode = 'P0001',
            detail  = format('appointment %s: illegal status transition', old.id);
```

`_detailCode()` (`app/lib/core/network/supabase_service.dart:281`) accepts only
`^[A-Z][A-Z0-9_]*$`, at most 64 characters. `appointment 4471: illegal status
transition` matches neither, so `ApiException.code` is **null** and no screen can
branch on this rule. That is not an accident of the regex — the regex exists so
Postgres's own DETAIL prose is never mistaken for a code (`supabase_service.dart:
278`) — but it means this raise's DETAIL is silently discarded.

The message still reaches the user correctly via `P0001`
(`supabase_service.dart:238`). Only the machine-readable half is lost. Fix:

```sql
-- 20260810000019_transition_detail_code.sql
-- Contradiction #17: the DETAIL carried prose, which _detailCode() in
-- app/lib/core/network/supabase_service.dart:281 discards. Reproduce
-- appointments_guard_transition() from 20260809000002:661 and change
-- ONLY these two raises:
--
--     detail = 'ILLEGAL_STATUS_TRANSITION'
--     detail = 'STATUS_SET_BY_SYSTEM'
--
-- The appointment id was the only thing the old DETAIL added, and it is
-- already known to the caller -- it is in the URL of the request.
```

Audit for other instances of the same mistake:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "detail\s*=" supabase/migrations/*.sql supabase/*.sql \
  | grep -vE "detail\s*=\s*'[A-Z][A-Z0-9_]*'"
# Every line printed is a DETAIL the Dart layer will throw away.
```

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | DETAIL (after fix) |
|---|---|---|
| illegal edge | `P0001` | `ILLEGAL_STATUS_TRANSITION` |
| client setting a system-owned status | `42501` | `STATUS_SET_BY_SYSTEM` |
| non-doctor confirming/completing | `42501` | none (`appointments_guard_confirm`) |

```dart
// Contradiction #17 — appointment state machine.
'ILLEGAL_STATUS_TRANSITION': (en: 'This appointment can no longer be changed.',
                              bn: 'এই অ্যাপয়েন্টমেন্ট আর পরিবর্তন করা যাবে না।'),
'STATUS_SET_BY_SYSTEM':      (en: 'That status is set automatically.',
                              bn: 'এই স্ট্যাটাসটি স্বয়ংক্রিয়ভাবে নির্ধারিত হয়।'),
```

The server's English names the two states ("cannot move from cancelled to
confirmed"), which is right for a doctor's dashboard and wrong for a patient. On
`ILLEGAL_STATUS_TRANSITION` the patient-facing screens should use the mapped
string and **refresh the appointment**, since the usual cause is a stale list: the
doctor cancelled while the patient's screen still showed "Confirm".

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient>","role":"authenticated"}';

-- Terminal states are terminal.
update public.appointments set status = 'confirmed' where id = <cancelled-appt>;
-- expect P0001 / ILLEGAL_STATUS_TRANSITION

update public.appointments set status = 'pending' where id = <completed-appt>;
-- expect P0001 / ILLEGAL_STATUS_TRANSITION

-- Skipping an edge.
update public.appointments set status = 'completed' where id = <pending-appt>;
-- expect P0001 / ILLEGAL_STATUS_TRANSITION  (pending -> completed is absent)

-- Legal edge, wrong actor: a patient confirming their own booking.
update public.appointments set status = 'confirmed' where id = <pending-appt>;
-- expect 42501 from appointments_guard_confirm, NOT from this trigger.
-- Two different guards, two different messages: that is the separation
-- working.

-- Legal edge, right actor.
set local request.jwt.claims = '{"sub":"<the-doctor>","role":"authenticated"}';
update public.appointments set status = 'confirmed' where id = <pending-appt>;
-- expect success

-- The no-op must not be blocked.
update public.appointments set notes = 'bring reports' where id = <pending-appt>;
-- expect success: the guard returns early when status is unchanged
rollback;
```

The no-op case is the one that breaks if someone rewrites the early return. Every
appointment UPDATE fires this trigger, not just status changes.

---

## 16. Contradiction #18 — a review cannot be rewritten after approval

**Status: partially enforced. The policy is right; there is no edit window and no
audit of edits.**

### The invariant

An author may edit their review only while it is `pending` moderation and only
within a short window of writing it.

### What exists

`reviews_update_own_pending` (`supabase/rls_policies.sql:718`):

```sql
create policy reviews_update_own_pending
  on public.reviews for update to authenticated
  using (user_id = (select auth.uid()) and status = 'pending')
  with check (user_id = (select auth.uid()));
```

and `aa_guard_reviews` (`rls_policies.sql:186`) guards `status`, so the author
cannot self-approve. Together these already stop the headline attack: a review
that has been approved and is publicly visible cannot be edited, because `USING`
fails on `status = 'pending'`.

### The failure scenario that remains

The hole is in the `WITH CHECK`, which omits `status`.

```
Mon 14:00  Farhana posts a fair 4-star review of a pharmacy. status='pending'.
Mon 16:30  Admin approves it. status='approved'. It is now public.
```

She cannot edit it now — `USING` blocks her. So far so good. But consider the
other order, which is what actually happens:

```
Tue 09:00  Farhana posts a glowing 5-star review of a pharmacy she owns
           a stake in. status='pending'.
Tue 09:05  Admin approves it, seeing a normal-looking review.
```

Nothing to exploit yet. Now the real one — **a review left pending indefinitely**:

```
Wed 10:00  Rakib posts a bland 3-star review. status='pending'.
Wed 10:00  It sits unmoderated for eleven days.
Sun 22:14  Rakib PATCHes it to 1 star with a defamatory comment.
Mon 09:00  A different admin, working the backlog, approves what they see.
```

`USING` passes (still pending), `WITH CHECK` passes (still his). The review the
first admin would have approved and the text now published are different, and
nothing records that it changed. The longer the moderation backlog, the wider the
window — and a backlog is guaranteed.

There is a second, quieter hole: `WITH CHECK` does not re-assert `status =
'pending'`, so an update that *also* set `status` would pass the check. It is
blocked in practice by `aa_guard_reviews`, so this is defence in depth rather than
a live bug — but the policy should say what it means.

### The DDL

```sql
-- =====================================================================
-- 20260810000020_review_edit_window.sql
--
-- Contradiction #18: bound review edits to a short window and record
-- that an edit happened, so moderation approves what it reviewed.
-- =====================================================================

alter table public.reviews
  add column if not exists edited_at timestamptz,
  add column if not exists edit_count integer not null default 0;

comment on column public.reviews.edited_at is
  'Set by reviews_track_edit when the rating or comment changes after '
  'insert. NULL means the text is as originally submitted.';

-- Re-state the pending requirement on the write side too, so the policy
-- is self-contained and does not rely on aa_guard_reviews for meaning.
drop policy if exists reviews_update_own_pending on public.reviews;
create policy reviews_update_own_pending
  on public.reviews for update to authenticated
  using  (user_id = (select auth.uid()) and status = 'pending')
  with check (user_id = (select auth.uid()) and status = 'pending');

create or replace function public.reviews_track_edit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Only content edits count. A moderator changing status, or any
  -- trusted path, is not an author edit.
  if new.rating is not distinct from old.rating
     and new.comment is not distinct from old.comment then
    return new;
  end if;

  if public.write_is_trusted() then
    return new;
  end if;

  -- The window. 30 minutes is long enough to fix a typo or a wrong star
  -- count -- the two real reasons anyone edits -- and short enough that
  -- a moderation backlog cannot be exploited. It is measured from
  -- created_at, not from the last edit, so repeated edits cannot walk
  -- the window forward indefinitely.
  if now() > old.created_at + interval '30 minutes' then
    raise exception 'A review can only be edited within 30 minutes of posting.'
      using errcode = 'P0001', detail = 'REVIEW_EDIT_WINDOW_CLOSED';
  end if;

  new.edited_at  := now();
  new.edit_count := coalesce(old.edit_count, 0) + 1;
  return new;
end;
$$;

revoke all on function public.reviews_track_edit() from public, anon, authenticated;

-- ab_, so it runs after aa_guard_reviews has rejected any status change.
create trigger ab_track_review_edit
  before update on public.reviews
  for each row execute function public.reviews_track_edit();
```

Two design notes:

**The window is measured from `created_at`, not from `edited_at`.** Measuring from
the last edit would let an author edit every 29 minutes forever, which is the same
unbounded window with extra steps.

**`now()` is a `timestamptz` compared against a `timestamptz` column**, so no
Asia/Dhaka conversion is needed or wanted here — unlike section 5, where one side
was a naive wall-clock `timestamp`. Adding `at time zone` here would be a bug. The
rule is simple: convert when comparing against `appointment_date`/`appointment_time`;
never convert when comparing two `timestamptz` values.

Moderators need to see that an edit happened, or the column is pointless. The
admin review queue must surface it:

```sql
-- Serves the moderation queue: pending reviews, edited ones first.
create index idx_reviews_pending_edited
  on public.reviews (created_at desc)
  where status = 'pending';
```

and the admin repository must select `edited_at, edit_count` and the UI must show
"edited" next to any review where `edited_at is not null`. Approving an edited
review without knowing it was edited is the failure this whole section describes.

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | DETAIL |
|---|---|---|
| edit after 30 minutes | `P0001` | `REVIEW_EDIT_WINDOW_CLOSED` |
| edit after approval | `42501` | none — RLS `USING` fails |

The approved case deserves a word. When a policy's `USING` clause excludes a row,
PostgREST does not raise `42501` — it reports **zero rows updated**. The client
sees success with an empty result, not an error. `guard()` never fires, and a
naive repository reports "saved" for an edit that did not happen. The review
repository must therefore check the returned row count:

```dart
final rows = await SupabaseService.guard(() => svc.db('reviews')
    .update({'rating': rating, 'comment': comment})
    .eq('id', id)
    .select());
if (rows.isEmpty) {
  throw ApiException(
    message: 'This review has already been published and can no longer be edited.',
    statusCode: 409,
    code: 'REVIEW_ALREADY_PUBLISHED',
  );
}
```

This pattern applies to **every** update behind a restrictive `USING` clause, not
only reviews. It is the single most common way an RLS-protected app silently lies
to its user, and it is worth grepping for:

```bash
cd "F:/Project folder/AyurBD"
grep -rn "\.update(" app/lib --include=*.dart | grep -v "\.select()"
# Each hit is an update whose refusal would be invisible.
```

```dart
// Contradiction #18 — review edit window.
'REVIEW_EDIT_WINDOW_CLOSED': (en: 'A review can only be edited within 30 minutes of posting.',
                              bn: 'রিভিউ পোস্ট করার ৩০ মিনিটের মধ্যেই কেবল সম্পাদনা করা যায়।'),
'REVIEW_ALREADY_PUBLISHED':  (en: 'This review has already been published and can no longer be edited.',
                              bn: 'এই রিভিউটি ইতিমধ্যে প্রকাশিত হয়েছে এবং আর সম্পাদনা করা যাবে না।'),
```

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<author>","role":"authenticated"}';

-- Inside the window.
update public.reviews set comment = 'fixed a typo' where id = <fresh-pending>
returning edited_at, edit_count;
-- expect edited_at set, edit_count = 1

-- Outside the window: backdate created_at as a trusted session first.
-- (set local role postgres; update ... set created_at = now() - interval '2 hours';)
update public.reviews set rating = 1 where id = <old-pending>;
-- expect P0001 / REVIEW_EDIT_WINDOW_CLOSED

-- Already approved: NOT an error, ZERO ROWS. This is the one that
-- surprises people.
update public.reviews set rating = 1 where id = <approved> returning id;
-- expect 0 rows, no exception

-- A moderator's own status change must not count as an edit.
set local request.jwt.claims = '{"sub":"<admin>","role":"authenticated"}';
update public.reviews set status = 'approved' where id = <fresh-pending>
returning edited_at, edit_count;
-- expect edit_count unchanged, edited_at unchanged
rollback;
```

The zero-rows case must be asserted explicitly in the Dart test suite too, because
a SQL-only test will read it as success.

---

## 17. Contradiction #19 — a user with live commitments cannot be deleted

**Status: not enforced, and the current behaviour is destructive. This is the most
dangerous item after #14.**

### The invariant

Deleting a user must not destroy appointments, payments, orders or payouts. A user
with financial or clinical history is deactivated, never removed.

### What exists: a cascade chain rooted outside `public`

`public.users.id` (`supabase/schema.sql:283`):

```sql
  id uuid primary key references auth.users (id) on delete cascade,
```

and fourteen tables cascade from `public.users`:

| Line in `schema.sql` | Table | Column |
|---|---|---|
| 313 | `doctors` | `user_id` |
| 382 | `hospitals` | `user_id` |
| 439 | `clinics` | `user_id` |
| 490 | `pharmacies` | `user_id` |
| **549** | **`appointments`** | **`patient_id`** |
| **598** | **`payments`** | **`user_id`** |
| 690 | `cart` | `user_id` |
| **766** | **`orders`** | **`user_id`** |
| **866** | **`provider_payouts`** | **`provider_user_id`** |
| 904 | `reviews` | `user_id` |
| 1031, 1057 | `notifications`, `devices` | `user_id` |

Follow the chain. Deleting one row from `auth.users` — which the Supabase
dashboard offers as a button, and which the Admin API exposes as
`DELETE /auth/v1/admin/users/{id}` — removes the `public.users` row, which removes
every appointment that patient ever had, **every payment they ever made**, every
order, and every payout owed to them if they are a provider.

```
15:40:02  Support deletes a duplicate signup from the Supabase dashboard.
15:40:02  ON DELETE CASCADE removes 3 appointments, 3 payments totalling
          ৳4,100, and 2 orders.
15:40:02  provider_payouts rows referencing those payments cascade too
          (payment_id ... on delete cascade, schema.sql:869).
15:40:03  The doctor's earnings report drops by ৳4,100 with no record of
          why. The payments never existed. There is nothing to reconcile
          against, because the rows that would show the discrepancy are
          the rows that were deleted.
```

No attacker, no race, one click. And unlike every other item in this document, it
is **irreversible** — the other twenty produce a rejected write; this one produces
silent data loss that no constraint will ever surface.

The `payments` cascade is the unacceptable one. A payment record is the platform's
evidence that money moved. Bangladesh's financial record-keeping expectations
aside, the platform cannot answer "did this patient pay?" for a deleted user, and
it cannot prove it did not take money it failed to pass on.

### Why `RESTRICT` alone is not the fix

Changing the FKs to `ON DELETE RESTRICT` stops the destruction, but it also breaks
the legitimate case: a patient who signed up, did nothing, and asks to be removed.
More importantly, **it cannot stop the deletion at its root.** `auth.users` is
owned by GoTrue, in a schema this project does not control, and adding a
`RESTRICT`-bearing dependency there is not supportable across Supabase upgrades.

The workable design has three parts:

1. **`RESTRICT` on the money and care tables**, so `public.users` cannot be
   deleted while history exists.
2. **A `BEFORE DELETE` guard on `public.users`** that produces a comprehensible
   error instead of a raw FK violation, and that names what is blocking.
3. **Soft delete as the supported operation**, since after (1) hard delete is
   correctly impossible for anyone with history.

### The DDL

```sql
-- =====================================================================
-- 20260810000021_user_deletion_integrity.sql
--
-- Contradiction #19: deleting a user currently cascades away their
-- appointments, payments, orders and payouts. Money and care records
-- must outlive the account.
--
-- Run OUTSIDE peak hours: each ALTER takes a brief ACCESS EXCLUSIVE lock
-- on the child table.
-- =====================================================================

-- 1. Money and care records: RESTRICT.
alter table public.appointments
  drop constraint if exists appointments_patient_id_fkey,
  add  constraint appointments_patient_id_fkey
       foreign key (patient_id) references public.users (id) on delete restrict;

alter table public.payments
  drop constraint if exists payments_user_id_fkey,
  add  constraint payments_user_id_fkey
       foreign key (user_id) references public.users (id) on delete restrict;

alter table public.orders
  drop constraint if exists orders_user_id_fkey,
  add  constraint orders_user_id_fkey
       foreign key (user_id) references public.users (id) on delete restrict;

alter table public.provider_payouts
  drop constraint if exists provider_payouts_provider_user_id_fkey,
  add  constraint provider_payouts_provider_user_id_fkey
       foreign key (provider_user_id) references public.users (id) on delete restrict;

-- Payouts must also survive their source payment being corrected.
alter table public.provider_payouts
  drop constraint if exists provider_payouts_payment_id_fkey,
  add  constraint provider_payouts_payment_id_fkey
       foreign key (payment_id) references public.payments (id) on delete restrict;
```

Verify the constraint names against the live database first — Postgres generates
them as `<table>_<column>_fkey`, but a hand-named constraint would make every
`drop constraint if exists` a silent no-op, leaving the old CASCADE in place:

```sql
select conrelid::regclass as child, conname, confdeltype
  from pg_constraint
 where contype = 'f'
   and confrelid = 'public.users'::regclass
 order by 1;
-- confdeltype: 'c' = cascade, 'r' = restrict, 'n' = set null, 'a' = no action
-- After this migration the four tables above must show 'r'.
```

Leave `cart`, `notifications`, `devices` and `reviews` on CASCADE. They hold no
money and no clinical record, and a deleted user's cart is genuinely worthless.
`doctors`/`hospitals`/`clinics`/`pharmacies` also stay CASCADE **only because**
`appointments` and `provider_payouts` now block the delete first — a provider with
any history is unreachable, and one with none may go.

Then the comprehensible error:

```sql
create or replace function public.users_guard_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_appts    integer;
  v_payments integer;
  v_orders   integer;
begin
  select count(*) into v_appts    from public.appointments where patient_id = old.id;
  select count(*) into v_payments from public.payments     where user_id    = old.id;
  select count(*) into v_orders   from public.orders       where user_id    = old.id;

  if v_appts + v_payments + v_orders > 0 then
    raise exception
      'This account has % appointment(s), % payment(s) and % order(s) and cannot be deleted. Deactivate it instead.',
      v_appts, v_payments, v_orders
      using errcode = 'P0001', detail = 'USER_HAS_HISTORY';
  end if;

  return old;
end;
$$;

revoke all on function public.users_guard_delete() from public, anon, authenticated;

create trigger aa_guard_user_delete
  before delete on public.users
  for each row execute function public.users_guard_delete();
```

No trusted-path escape. A trusted path deleting a user with payment history is a
bug in that path, not a use case.

Finally, the supported operation. `users.is_active` already exists
(`schema.sql:293`) and is already honoured — `guard_appointments_insert()` and
`guard_reviews_insert()` both reject inactive accounts — so the deactivation
mechanism is in place and needs only an entry point:

```sql
create or replace function public.users_deactivate(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() and p_user_id is distinct from (select auth.uid()) then
    raise exception 'You can only deactivate your own account.'
      using errcode = '42501', detail = 'NOT_OWN_ACCOUNT';
  end if;

  -- Cancel what has not happened yet. Completed history is untouched:
  -- that is the whole point of deactivating rather than deleting.
  perform public.trusted_path_begin();
  update public.appointments
     set status = 'cancelled'
   where patient_id = p_user_id
     and status in ('pending', 'pending_payment', 'confirmed');
  update public.users set is_active = false, updated_at = now()
   where id = p_user_id;
  perform public.trusted_path_end();
end;
$$;

grant execute on function public.users_deactivate(uuid) to authenticated;
```

Cancelling live appointments matters: a deactivated patient who cannot log in must
not continue to hold a confirmed slot the doctor is reserving for them, and
sections 3 and 4 make cancellation the thing that frees a slot.

### The operational rule this creates

After this migration, **deleting from the Supabase dashboard will fail** for any
user with history — with an FK violation, since the dashboard talks to
`auth.users` and the failure surfaces there. That is the intended behaviour and it
must be written down, or the first person who hits it will "fix" it by restoring
the cascades.

Record in `IMPLEMENTATION_LOG.md`: *user deletion is blocked by design; use
`users_deactivate()`.*

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | DETAIL |
|---|---|---|
| delete a user with history (guard) | `P0001` | `USER_HAS_HISTORY` |
| delete via a path bypassing the guard | `23503` | FK name |
| deactivate someone else's account | `42501` | `NOT_OWN_ACCOUNT` |

`23503` maps at `app/lib/core/network/supabase_service.dart:209` to **"That item
no longer exists."** — which is exactly backwards for a `RESTRICT` violation,
where the problem is that related items very much *do* exist. `23503` covers both
directions of FK failure and the current message assumes only one. Fix:

```dart
      // 23503 is raised both when a referenced row is missing (insert
      // pointing at nothing) and when dependent rows still exist (a
      // RESTRICT delete). The two need opposite messages.
      case '23503':
        final isRestrict = raw.toLowerCase().contains('still referenced');
        return ApiException(
          message: isRestrict
              ? 'This cannot be removed while other records depend on it.'
              : 'That item no longer exists.',
          statusCode: 409,
          code: serverCode,
        );
```

Postgres's wording for a `RESTRICT`/`NO ACTION` violation is `update or delete on
table "users" violates foreign key constraint ... on table "payments"` with
DETAIL `Key (id)=(...) is still referenced from table "payments"`, so the
`still referenced` test is reliable. Confirm it on this Postgres version before
relying on it.

```dart
// Contradiction #19 — user deletion.
'USER_HAS_HISTORY':  (en: 'This account has appointments or payments and cannot be deleted. Deactivate it instead.',
                      bn: 'এই অ্যাকাউন্টে অ্যাপয়েন্টমেন্ট বা পেমেন্ট রয়েছে, তাই এটি মুছে ফেলা যাবে না। এর পরিবর্তে নিষ্ক্রিয় করুন।'),
'NOT_OWN_ACCOUNT':   (en: 'You can only deactivate your own account.',
                      bn: 'আপনি কেবল নিজের অ্যাকাউন্ট নিষ্ক্রিয় করতে পারেন।'),
```

The account-settings screen must offer **Deactivate account**, not Delete, and say
plainly that history is retained. Offering "Delete" and then refusing is worse
than not offering it.

### Reproduction test

```sql
begin;
set local role postgres;

-- The headline case.
delete from public.users where id = '<patient-with-payments>';
-- expect P0001 / USER_HAS_HISTORY, message naming the counts

-- A clean account still deletes.
delete from public.users where id = '<fresh-signup-no-history>';
-- expect success

-- Prove the cascade is really gone, not merely guarded: drop the trigger
-- and retry. The FK must stop it on its own.
alter table public.users disable trigger aa_guard_user_delete;
delete from public.users where id = '<patient-with-payments>';
-- expect 23503, appointments_patient_id_fkey or payments_user_id_fkey
alter table public.users enable trigger aa_guard_user_delete;
rollback;
```

That third case is essential. A guard trigger alone would leave the CASCADE intact
and the destruction one `disable trigger` — or one `auth.users` deletion — away.
The FK is the guarantee; the trigger is only the message.

And the root of the chain, which is the case the whole section is about:

```sql
-- With the service_role key, against the live project:
--   DELETE /auth/v1/admin/users/<uuid-of-patient-with-payments>
-- expect a 500 carrying a foreign key violation on public.users.
-- Before this migration it returns 200 and destroys the history.
```

---

## 18. Contradiction #20 — a blog post cannot publish itself

**Status: enforced. Verify, and tighten one grant.**

### The invariant

Only an admin can create, edit or publish a blog post; the public sees only
`published` ones.

### The failure scenario

The app has a "health tips" feed on the home screen. If any authenticated user
could insert a `blogs` row with `status = 'published'`, that feed becomes an open
billboard — advertising, medical misinformation with the platform's branding
behind it, or links out to a phishing page. On a healthcare app, unmoderated
health advice carrying the platform's name is a liability, not a spam problem.

```
02:41:18  POST /rest/v1/blogs
          {"title":"Cure diabetes in 7 days","content":"...",
           "status":"published","author_id":"<self>"}
```

### What exists

Four policies, all admin-gated (`supabase/rls_policies.sql:925` onward):

```sql
create policy blogs_insert_admin
  on public.blogs for insert to authenticated
  with check (public.is_admin());

create policy blogs_update_admin
  on public.blogs for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy blogs_delete_admin
  on public.blogs for delete to authenticated
  using (public.is_admin());
```

and read is split three ways (`rls_policies.sql:911`):

| Policy | Audience | Sees |
|---|---|---|
| `blogs_select_published` | `anon`, `authenticated` | `status = 'published'` only |
| `blogs_select_author` | `authenticated` | own drafts |
| `blogs_select_admin` | `authenticated` | everything |

The per-command split is the pattern R9 asks for and the master plan's rule
against `FOR ALL` policies exists to produce. `FOR ALL` here would have collapsed
insert, update, delete and select into one predicate, and `blogs_select_published`
could not then coexist with admin-only writes — the public would need write access
or admins would lose read access to drafts.

`blog_status` is `('draft', 'published', 'archived')` (`schema.sql:260`), so
`archived` is also correctly invisible to the public: `blogs_select_published`
tests equality with `'published'`, not inequality with `'draft'`. Written the other
way, archiving a post would silently republish it.

### The default is right; the column is nullable

Master plan §3 specifies "status default `draft`" as part of the remedy, and
`schema.sql:1103` has it:

```sql
  status       blog_status default 'draft',
```

The default is correct — a post created without an explicit status is a draft, so
an admin who forgets the field publishes nothing. But the column has no `not null`,
so `status` can be set to `NULL` outright, and a `NULL` status satisfies neither
`blogs_select_published` nor `blogs_select_author`'s draft predicate. The post
becomes invisible to everyone except an admin.

That is a data defect rather than a leak — the failure direction is *hidden*, not
*exposed*, which is the right way round for this table. Close it anyway, because a
nullable status makes every future query about blog state a three-value question:

```sql
-- 20260810000024_blogs_status_not_null.sql
-- Contradiction #20: blogs.status is nullable, so a post can exist in no
-- state at all -- invisible to the public feed, invisible to its author's
-- draft list, and counted by neither. The default already covers omission;
-- this covers an explicit null.
update public.blogs set status = 'draft' where status is null;
alter table public.blogs alter column status set not null;
```

The `update` must come first: `set not null` fails with `23502` on an existing
`NULL`, and on a table with content that failure aborts the whole deploy.

### The gap: the table grant is wider than the policies

`schema.sql:3384`:

```sql
grant select, insert, update, delete on public.blogs to authenticated;
```

Every authenticated user holds `INSERT`, `UPDATE` and `DELETE` on `blogs`. RLS
denies each one, so nothing is exploitable today — but the protection rests
entirely on the policies, with no second layer. Every other admin-only table in
this schema is grant-restricted as well: `notifications` has no `INSERT` grant at
all (section 19), and `app_audit_log` has none for anyone.

Remove what no client needs:

```sql
-- 20260810000022_blogs_grant_narrow.sql
-- Contradiction #20: RLS already restricts blog writes to admins. Remove
-- the grants too, so a policy mistake cannot open authoring to everyone.
-- Admins reach blogs through is_admin() policies while connected as
-- `authenticated`, so the grants are needed -- but only for admins, and
-- Postgres grants are role-wide, not predicate-wide. The supported path
-- for admin authoring is therefore a SECURITY DEFINER RPC.
revoke insert, delete on public.blogs from authenticated;
```

`UPDATE` is deliberately left in place: the admin app edits posts through
PostgREST as `authenticated`, and `blogs_update_admin` is the predicate. Revoking
`INSERT` and `DELETE` means admin authoring and removal must move to SECURITY
DEFINER RPCs. **If Part 09 has not yet built those, do not apply this migration** —
breaking admin authoring to add a redundant layer is a bad trade. Record the
decision either way; an unapplied hardening migration that nobody knows about is
worse than none.

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | Result |
|---|---|---|
| non-admin insert | `42501` | "You do not have permission to do that." |
| non-admin update | — | **zero rows**, no error (see section 16) |
| non-admin reading a draft | — | **zero rows**, no error |

The update and select cases produce no error at all, which is correct RLS
behaviour and a trap for the client. A non-admin editing a post silently succeeds
with nothing changed. Apply the `.select()` row-count pattern from section 16 in
the blog repository.

No DETAIL code and no new mapping. As with section 12, a client hitting this is
broken or hostile.

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<ordinary-patient>","role":"authenticated"}';

insert into public.blogs (title, content, status, author_id)
values ('Cure diabetes in 7 days', '...', 'published', '<ordinary-patient>');
-- expect 42501

-- Self-publishing an existing draft: zero rows, NOT an error.
update public.blogs set status = 'published' where id = <draft> returning id;
-- expect 0 rows

-- Drafts are invisible.
select count(*) from public.blogs where status = 'draft';
-- expect 0
rollback;

-- And as anon, archived posts must be invisible too.
set local role anon;
select count(*) from public.blogs where status <> 'published';
-- expect 0
```

---

## 19. Contradiction #21 — a notification cannot be forged

**Status: enforced, and it is the cleanest example in the schema of the right
technique.**

### The invariant

Notification rows are written only by the database's own trigger functions. No
client can create one.

### The failure scenario

Notifications are the platform's voice. A forged one is a phishing message
delivered inside a trusted surface.

```
03:02:55  POST /rest/v1/notifications
          {"user_id":"<victim-uuid>",
           "title":"Payment failed - action required",
           "message":"Your appointment will be cancelled. Re-pay at
                      bit.ly/xxxx to keep your slot.",
           "type":"payment"}
```

The victim opens the app and sees it beside genuine notifications, in the app's own
styling, with no sender to inspect. This is materially worse than an SMS or email
phish, because the surrounding UI is authentic and the user has no habit of
distrusting it. And because `user_id` is the only routing field, one attacker can
address every user whose uuid they can enumerate.

### What exists, and why it is stronger than a policy

Two mechanisms, and the important one is **not** RLS.

**No `INSERT` grant.** `schema.sql:3381`:

```sql
-- No INSERT: notifications are written only by the trigger functions in
-- PART 3.4, never by a client. The app reads them and marks them read.
grant select, update on public.notifications to authenticated;
```

**No `INSERT` policy.** `rls_policies.sql:838`:

```sql
-- No INSERT policy on notifications for anyone. Rows arrive only through
-- the SECURITY DEFINER notify() helpers.
```

Either alone would stop the attack. Together they make it impossible to open by
accident, and the distinction is worth internalising:

- An **absent policy** denies by default, but *adding* one is a one-line mistake in
  a future migration, and RLS policies are the thing people edit.
- An **absent grant** denies before RLS is consulted at all. PostgREST cannot even
  reach the row-security layer without table-level `INSERT`.

This is the layering argument of the whole document, applied to a table where the
consequence of a mistake is phishing. **Do not add an INSERT policy to
`notifications` for any reason.** If a feature seems to need one, it needs a
SECURITY DEFINER function instead.

`notify()` and its callers are `SECURITY DEFINER`, so they write as the function
owner and need neither grant nor policy. That is the mechanism, and it is the same
one that lets `place_order()` write `orders` while `guard_orders_insert()` refuses
every client write (`20260809000002:388`).

### The narrow gap that remains

`notifications_update_own` (`rls_policies.sql:849`):

```sql
create policy notifications_update_own
  on public.notifications for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
```

The intent is "mark as read". The policy permits updating **any** column of one's
own notification — `title`, `message`, `type`. The `with check` pins `user_id`, so
a notification cannot be moved to another user, and a user rewriting a message only
they can read harms nobody.

It is still worth closing, for one reason: a support agent reading a screenshot of
a self-edited notification would believe the platform sent it. Restrict the policy
to the column it means:

```sql
-- 20260810000023_notification_read_only_flag.sql
-- Contradiction #21: notifications_update_own permits editing the title
-- and message of one's own notification. Only the read flag should move.
-- RLS cannot express column-level immutability (see section 12), so this
-- is the same generic guard, reused.
create trigger aa_guard_notifications
  before update on public.notifications
  for each row execute function public.guard_admin_only_columns(
    'user_id', 'title', 'message', 'type', 'reference_id', 'created_at');
```

Confirm the column names against the live table before applying — this guard fails
silently if a name is wrong, because `to_jsonb(old) -> 'typo'` is `NULL` on both
sides and `is distinct from` is then false:

```sql
select column_name from information_schema.columns
 where table_schema = 'public' and table_name = 'notifications'
 order by ordinal_position;
```

That silent-failure mode is worth stating plainly: **a misspelled column in a
`guard_admin_only_columns` argument list is a guard that always passes.** The
coverage query in section 12 is how you catch it, and it is the reason that query
exists.

### SQLSTATE and the Dart mapping

| Condition | SQLSTATE | Result |
|---|---|---|
| client INSERT | `42501` | "You do not have permission to do that." |
| client editing title/message | `42501` | generic 403, after the guard above |

The insert failure is a *grant* failure, so Postgres reports `permission denied
for table notifications` — `42501`, which `guard()` maps at
`app/lib/core/network/supabase_service.dart:189`. The message is deliberately
generic; the mapping already appends the raw text, which for a grant failure names
the table. That is acceptable: it tells an attacker nothing they did not just
learn.

No DETAIL code. No new mapping.

### Reproduction test

```sql
begin;
set local role authenticated;
set local request.jwt.claims = '{"sub":"<attacker>","role":"authenticated"}';

-- The forgery, aimed at someone else.
insert into public.notifications (user_id, title, message, type)
values ('<victim>', 'Payment failed', 'Re-pay at bit.ly/xxxx', 'payment');
-- expect 42501, permission denied for table notifications

-- Aimed at themselves: must also fail. The rule is about the WRITER, not
-- the target.
insert into public.notifications (user_id, title, message, type)
values ('<attacker>', 'test', 'test', 'system');
-- expect 42501

-- Marking read must still work.
update public.notifications set is_read = true where user_id = '<attacker>';
-- expect success

-- Rewriting the text must not.
update public.notifications set message = 'edited' where user_id = '<attacker>';
-- expect 42501 after aa_guard_notifications
rollback;
```

Then prove the legitimate writer still works, which is what would break if someone
"fixed" the missing grant by revoking too much:

```sql
-- A trigger-driven notification must still be created.
set local role authenticated;
set local request.jwt.claims = '{"sub":"<patient>","role":"authenticated"}';
select public.appointments_book(<verified-doctor>, current_date + 1, '18:00');
select count(*) from public.notifications
 where user_id = '<the-doctor-user-id>' and created_at > now() - interval '1 minute';
-- expect >= 1: the doctor was notified by the trigger, with no grant
-- and no policy involved.
```

That last assertion is the one to keep. It is the difference between "clients
cannot write notifications" and "nothing can write notifications", and a migration
that revoked `INSERT` from the function owner would pass every other test here.

---

## 20. How to find contradiction #22

The twenty-one items in master plan §3 are not a complete list. They are the ones
somebody noticed. This section is the method that produced them, written down so
the next feature gets the same treatment instead of the same audit.

### The method

The whole technique is two questions, asked in this order.

**One: what does the UI assume?** Read a screen, not a table. Every disabled
button, every filtered list, every validator, every `if` before a call is an
invariant somebody decided mattered. Write each as a sentence with a subject and a
verb: "a slot already booked is not offered", "the Review button is hidden until
the visit is over", "the quantity stepper stops at 99". The UI is where the
business rules are actually recorded in this codebase — the schema records only the
ones that were also translated into DDL.

**Two: what could a REST client do instead?** Now forget the app. Assume an
attacker has a valid JWT for an ordinary patient account — which requires nothing
more than signing up — and the project's anon key, which ships inside the APK and
must be treated as public. They can `POST`, `PATCH` and `DELETE` any table their
grants and policies permit, with any payload, at any rate, in any order, twice
concurrently. For each sentence from step one, ask what stops it. Only three
answers count:

| Answer | Verdict |
|---|---|
| A constraint, index, trigger or `SECURITY DEFINER` function | Enforced. Write the reproduction test. |
| An RLS policy | Enforced *for rows*, not for columns or for races. Continue to the column and concurrency questions below. |
| The app's code | **Contradiction found.** |

Anything else — "no client would do that", "the UI prevents it", "we validate in
the repository" — is the third answer wearing a different hat.

### The four questions that find most of them

Applied to each invariant, in order of how often they pay off.

1. **Two clients, same millisecond.** Does the check read a row and then write
   based on what it read? If the read and the write are separate statements with no
   lock between them, both clients pass the check. This produced #1, #6, #9, #10,
   #11 and #13. The fix is always the same shape: make the database do the
   comparison in the same statement as the write (a unique index, an exclusion
   constraint, or `update ... where <predicate>`), never in Dart and never in a
   preceding `select`.
2. **Which columns?** A policy that permits an UPDATE permits it on every column
   the grant covers. Ask which columns the row's *state* depends on, and whether
   the writer is allowed to move them. This produced #14, #15, #17, #18 and the
   payout drift in #13. RLS cannot answer it; a `BEFORE UPDATE` trigger comparing
   `OLD` and `NEW` is the only mechanism.
3. **Whose clock?** Any comparison against a `date` or naive `timestamp` column
   needs a timezone, and the server's default is UTC. Bangladesh is UTC+6, so every
   such comparison is six hours wrong in whichever direction is worse. This
   produced #2.
4. **What if it is absent?** A CHECK whose expression evaluates to `NULL` passes. A
   trigger on a column nobody writes never fires. A guard listing a misspelled
   column always succeeds. This produced #16 and the two silent-failure traps in
   sections 10 and 19.

### The result that has no error to catch

One answer deserves separating out, because it is the failure mode most likely to
survive a careful review: **when an RLS `USING` clause excludes a row, the write
affects zero rows and PostgREST returns success.** No SQLSTATE, so `guard()` never
runs, so the repository returns normally and the screen shows a confirmation.

This means "the policy stops it" and "the user is told it was stopped" are
different claims, and the second one needs the `.select()` row-count pattern from
section 16 at every call site. When you find an invariant enforced only by a
`USING` clause, you have found half a contradiction: the data is safe and the user
is being lied to.

### Applying it: four candidates in the current schema

These came out of running the method over the tables that master plan §3 does not
mention. They are recorded here as the method's output, not as instructions —
sections 3 to 19 are the work; this is the next iteration's queue.

**#22 — a push token belongs to whoever registered it first.**
`uq_device_token unique (fcm_token)` (`supabase/schema.sql:1061`) makes the token
globally unique, and `content_repository.dart:135` upserts with
`onConflict: 'fcm_token'`. An upsert that conflicts becomes an UPDATE, and that
UPDATE is filtered by `device_tokens_update_own`'s
`using (user_id = (select auth.uid()))`.

So: patient A signs in on a shared phone, then signs out. Patient B signs in on the
same phone. B's app registers the same FCM token; the upsert's UPDATE matches a row
owned by A, the `USING` clause excludes it, **zero rows, no error**. The row still
says A. Every notification the platform sends A — appointment reminders, payment
confirmations, and the message bodies section 19 works to keep authentic — is
delivered to B's phone. B's own notifications arrive nowhere.

Question 1 (two clients) did not find this. Question 4 (what if it is absent) plus
the zero-rows result did. Note that it defeats section 19 completely: an attacker
who learns a victim's FCM token and registers it first receives the victim's push
traffic without ever writing a `notifications` row.

**#23 — a cart line has no ceiling.** `cart_quantity_check check (quantity > 0)`
(`schema.sql:772`) is the only bound; the stepper's `clamp(1, 99)` at
`product_detail_screen.dart:57` is the real limit, and it is in Dart. A REST client
can `PATCH` `quantity` to 2000000000. `place_order()` then computes
`p.price * c.quantity` into a `numeric(10,2)` (`20260809000002:1698`), whose maximum
is 99999999.99 — so the order fails with `22003`, `numeric_field_overflow`, which
`_fromPostgrest` does not map. The user sees a raw Postgres sentence. The stock
check would also refuse it, so nothing is oversold; the defect is an unmapped
SQLSTATE reachable from a client, and a `check (quantity between 1 and 99)` closes
it at the source.

**#24 — an authenticated user can file anonymous feedback.**
`feedback_insert_auth`'s `with check (user_id is null or user_id = (select
auth.uid()))` (`rls_policies.sql:896`) permits `user_id is null` from a signed-in
caller, and `name` and `email` are free text. Feedback that looks like it came from
a stranger can be filed by an account, with no link back. Whether that is a defect
depends on whether anonymous feedback is a feature; it is listed because the policy
does not say which.

**Not a candidate: `emergency_sms`.** No UPDATE and no DELETE policy exists for
anyone, admin included (`rls_policies.sql:978`). An append-only log is what this
table should be, and the absence is deliberate and documented. Recorded here so a
future audit does not read the missing policies as an oversight and add them.

### When you find one

Add a section to this file in the same six-part shape — invariant, scenario, DDL,
SQLSTATE, Dart mapping in both languages, reproduction test — add the assertion to
the smoke suite in section 22, and note it in `IMPLEMENTATION_LOG.md` under R8. A
contradiction found and not written down is a contradiction that will be found
again.

---

## 21. The DETAIL code registry

Every rule above that raises `P0001` carries a machine code in DETAIL, and section
2 established why: `_detailCode()` (`app/lib/core/network/supabase_service.dart:281`)
lifts it into `ApiException.code`, so a screen branches on the *rule* rather than
matching English. This section collects them, because a code defined in one
migration and consumed in one screen is a code that will be misspelled.

### The registry

`ARB key` is the identifier Part 06 will place in `app_en.arb` and `app_bn.arb`.
Both strings are given in full in the section named.

| DETAIL code | ARB key | Section | Raised by |
|---|---|---|---|
| `SLOT_TAKEN` | `errSlotTaken` | 3 | `appointments_book()` |
| `HOLD_EXPIRED` | `errHoldExpired` | 4 | `expire_payment_holds()` (read back, not raised) |
| `SLOT_NOT_AVAILABLE` | `errSlotNotAvailable` | 6 | `guard_appointments_insert()` |
| `DOCTOR_NOT_BOOKABLE` | `errDoctorNotBookable` | 6 | `guard_appointments_insert()` |
| `HOLD_ALREADY_OPEN` | `errHoldAlreadyOpen` | 7 | `appointments_one_hold_guard()` |
| `REVIEW_NOT_OWN` | `errReviewNotOwn` | 5 | `guard_reviews_insert()` |
| `REVIEW_NEEDS_APPOINTMENT` | `errReviewNeedsAppointment` | 5 | `guard_reviews_insert()` |
| `REVIEW_APPOINTMENT_MISMATCH` | `errReviewAppointmentMismatch` | 5 | `guard_reviews_insert()` |
| `REVIEW_NOT_COMPLETED` | `errReviewNotCompleted` | 5 | `guard_reviews_insert()` |
| `REVIEW_TOO_EARLY` | `errReviewTooEarly` | 5 | `guard_reviews_insert()` |
| `REVIEW_DUPLICATE` | `errReviewDuplicate` | 5 | `guard_reviews_insert()` |
| `REVIEW_NO_ORDER` | `errReviewNoOrder` | 8 | `guard_reviews_insert()` |
| `REVIEW_EDIT_WINDOW_CLOSED` | `errReviewEditWindowClosed` | 16 | `reviews_track_edit()` |
| `REVIEW_ALREADY_PUBLISHED` | `errReviewAlreadyPublished` | 16 | `reviews_track_edit()` |
| `OUT_OF_STOCK` | `errOutOfStock` | 9 | `place_order()` |
| `CART_EMPTY` | `errCartEmpty` | 9 | `place_order()` |
| `ALREADY_PAID` | `errAlreadyPaid` | 10 | payment settlement |
| `PAYMENT_PENDING` | `errPaymentPending` | 10 | payment settlement |
| `PAYOUT_AMOUNT_MISMATCH` | `errPayoutAmountMismatch` | 11 | `provider_payouts_validate_amount()` |
| `PAYOUT_SOURCE_UNVERIFIED` | `errPayoutSourceUnverified` | 11 | `provider_payouts_validate_amount()` |
| `PAYOUT_NOT_SPLIT` | `errPayoutNotSplit` | 11 | `provider_payouts_validate_amount()` |
| `BLOOD_OUT_OF_STOCK` | `errBloodOutOfStock` | 14 | `blood_bank_dispense()` |
| `UNKNOWN_BLOOD_GROUP` | `errUnknownBloodGroup` | 14 | `blood_bank_dispense()` |
| `INVALID_UNITS` | `errInvalidUnits` | 14 | `blood_bank_dispense()` |
| `ILLEGAL_STATUS_TRANSITION` | `errIllegalStatusTransition` | 15 | `appointments_guard_transition()` |
| `STATUS_SET_BY_SYSTEM` | `errStatusSetBySystem` | 15 | `appointments_guard_transition()` |
| `USER_HAS_HISTORY` | `errUserHasHistory` | 17 | `users_guard_delete()` |
| `NOT_OWN_ACCOUNT` | `errNotOwnAccount` | 17 | `users_deactivate()` |
| `ACCOUNT_INACTIVE` | `errAccountInactive` | 17 | `users_deactivate()` |

### The codes with no ARB key, and why

Three exist in the schema and are deliberately absent from the map.

| Code | Raised by | Why unmapped |
|---|---|---|
| `NOT_ADMIN` | admin-only RPCs | Only reachable by a client attacking an endpoint the UI never shows. Section 12. |
| `NOT_AUTHENTICATED` | RPCs requiring `auth.uid()` | Same. A signed-out client calling a signed-in RPC is broken, not confused. |
| `split_check` (constraint name, `23514`) | `payments_split_check` | An arithmetic failure in our own settlement code, not a user mistake. Section 10 gives the generic apology string. |

`localizeIntegrityError` falls back to `e.message` for all three, which is the raw
English raise message. That is the right outcome: nobody legitimate sees it, and
whoever does gets something diagnosable.

### The completeness check

The registry drifts the moment a migration adds a code and the Dart is not touched.
This query lists every DETAIL literal the database can raise:

```sql
-- Every SHOUTING_SNAKE_CASE detail string in any function body.
select distinct m[1] as detail_code
  from pg_proc p
  cross join lateral regexp_matches(
       pg_get_functiondef(p.oid),
       $$detail\s*=\s*'([A-Z][A-Z0-9_]*)'$$, 'g') as m
 where p.pronamespace = 'public'::regnamespace
 order by 1;
```

and this compares it against the Dart map:

```bash
# From the repo root. Any line prefixed '<' is a code the database raises
# that the app cannot localize; '>' is a stale key with no raiser left.
psql "$DATABASE_URL" -Atqf /tmp/detail_codes.sql | sort > /tmp/db.txt
grep -o "'[A-Z][A-Z0-9_]*'\s*:" app/lib/core/network/integrity_errors.dart \
  | tr -d "':" | tr -d ' ' | sort > /tmp/dart.txt
diff /tmp/db.txt /tmp/dart.txt
```

Expect exactly three `<` lines — `NOT_ADMIN`, `NOT_AUTHENTICATED` and any code
added since this document. Zero `>` lines: a key with no raiser means a rule was
deleted, which is how contradiction #2 was lost (section 5).

Run it in the smoke suite. A missing key is not an error at runtime — the fallback
hides it — so nothing else will ever tell you.

---

## 22. The smoke suite

Sections 5, 10 and 21 each forward-reference this. It is one file, run against a
deployed database, that asserts every structure this document specifies is
*present*. It does not test behaviour — the reproduction tests in each section do
that. It tests existence, because the failure this project has already suffered
(section 5) was not a broken rule but a **deleted** one, and a deleted rule breaks
no test that only exercises the happy path.

### Why existence checks and not behaviour tests

`20260809000002_payment_architecture_fix.sql:345` removed the review timing check
while refactoring something else. Nothing failed. Every booking test passed, every
review test passed, because the tests that existed reviewed completed
appointments. The rule was gone for weeks.

A behaviour test would have caught it only if somebody had written "review an
appointment that has not happened yet, expect rejection" — which is exactly the
test nobody writes, because it asserts a negative about a path the UI does not
offer. An existence check catches it because it asserts the *mechanism*, and the
mechanism is what refactors delete.

### The file

Write it to `supabase/tests/integrity_smoke.sql`. It runs read-only, needs no
fixtures, and is safe against production.

```sql
-- supabase/tests/integrity_smoke.sql
--
-- Asserts that every structure specified in spec/12_LOGICAL_INTEGRITY.md
-- exists. Read-only. Run after every `supabase db push`:
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/integrity_smoke.sql
--
-- Any missing structure aborts with the section number that owns it.
\set ON_ERROR_STOP on

create or replace function pg_temp.want(p_ok boolean, p_what text)
returns void language plpgsql as $$
begin
  if not p_ok then
    raise exception 'INTEGRITY SMOKE FAILED: %', p_what;
  end if;
end $$;

do $smoke$
declare
  ok boolean;
begin

-- --- section 3, 6: the slot uniqueness index and its WHERE clause ------
select exists (
  select 1 from pg_index i
    join pg_class c on c.oid = i.indexrelid
   where c.relname = 'uq_appointments_doctor_slot'
     and i.indpred is not null
) into ok;
perform pg_temp.want(ok,
  'uq_appointments_doctor_slot missing or no longer partial (section 3). '
  'Without the WHERE clause a cancelled slot can never be rebooked; '
  'without the index two patients can hold the same slot.');
```

The two-part assertion matters. An index that exists but lost its `indpred` is
worse than no index: bookings still work, cancellations still work, and rebooking
a cancelled slot fails with "that time slot has just been taken" for a slot that is
visibly free. That is a bug report nobody can reproduce.

Continuing the same `do` block:

```sql
-- --- section 4: the hold column and the pg_cron job -------------------
select exists (
  select 1 from information_schema.columns
   where table_schema = 'public' and table_name = 'appointments'
     and column_name = 'hold_expires_at') into ok;
perform pg_temp.want(ok, 'appointments.hold_expires_at missing (section 4).');

select exists (
  select 1 from extensions.cron.job where jobname = 'expire-payment-holds')
 into ok;
perform pg_temp.want(ok,
  'pg_cron job expire-payment-holds is not scheduled (section 4). Holds '
  'will never expire, so every abandoned checkout permanently removes a '
  'slot from sale.');

-- --- section 5: the review timing check, and its timezone -------------
-- The probe that would have caught 20260809000002:345.
select pg_get_functiondef('public.guard_reviews_insert()'::regprocedure)
       like '%Asia/Dhaka%' into ok;
perform pg_temp.want(ok,
  'guard_reviews_insert() no longer converts to Asia/Dhaka (section 5). '
  'A device on UTC can review six hours before the consultation ends.');

select pg_get_functiondef('public.guard_reviews_insert()'::regprocedure)
       like '%REVIEW_NOT_COMPLETED%' into ok;
perform pg_temp.want(ok,
  'guard_reviews_insert() no longer checks appointment status (section 5). '
  'This is the exact regression 20260809000002 introduced.');

-- --- section 7: one open hold per patient -----------------------------
select exists (
  select 1 from pg_class where relname = 'uq_appointments_one_hold_per_patient'
) into ok;
perform pg_temp.want(ok, 'uq_appointments_one_hold_per_patient missing (section 7).');

-- --- section 9: the stock backstop ------------------------------------
select exists (
  select 1 from pg_constraint
   where conname = 'pharmacy_products_stock_check' and contype = 'c'
) into ok;
perform pg_temp.want(ok,
  'pharmacy_products stock CHECK missing (section 9). place_order() '
  'guards stock itself, but with no backstop a future writer can go '
  'negative silently.');

-- --- section 10: the index that can fail to create --------------------
-- Created inside a `do` block that downgrades unique_violation to a
-- warning, so `supabase db push` exits 0 whether or not it exists.
-- This is the only signal.
select exists (
  select 1 from pg_class where relname = 'uq_payments_verified_appointment'
) into ok;
perform pg_temp.want(ok,
  'uq_payments_verified_appointment missing (section 10). Its migration '
  'catches unique_violation and only raises a warning, so the deploy '
  'reported success. Clear the duplicate verified payments listed by the '
  'query in section 10 and re-run the migration.');

select exists (
  select 1 from pg_constraint where conname = 'payments_split_check'
) into ok;
perform pg_temp.want(ok, 'payments_split_check missing (section 10).');
```

The `uq_payments_verified_appointment` probe is the one to keep if you keep only
one. Every other structure here fails loudly at migration time. That index fails
*quietly*, by design, and the design is defensible — a migration that aborts on
pre-existing duplicates blocks the whole deploy — but it means the invariant's
presence is unknowable without asking.

Continuing:

```sql
-- --- section 11: payout integrity -------------------------------------
select count(*) = 2 from pg_class
 where relname in ('uq_provider_payouts_payment', 'uq_provider_payouts_order')
 into ok;
perform pg_temp.want(ok, 'provider payout uniqueness indexes missing (section 11).');

select exists (
  select 1 from pg_trigger where tgname = 'aa_validate_payout_amount'
    and tgrelid = 'public.provider_payouts'::regclass
) into ok;
perform pg_temp.want(ok, 'aa_validate_payout_amount trigger missing (section 11).');

-- --- section 12: guard coverage, including the columns added later ----
-- guard_admin_only_columns receives its column list via TG_ARGV, so a
-- column added to users after the trigger was written is unguarded and
-- nothing says so. Assert the full list, not just the trigger's presence.
select t.tgargs is not null
   and array['role','is_active','is_verified','phone_verified']
       <@ (select array_agg(a) from unnest(tg.tgargs_text) a)
  from pg_trigger t
  join lateral (
    select string_to_array(
             encode(t.tgargs, 'escape'), '\000') as tgargs_text) tg on true
 where t.tgname = 'aa_guard_users' and t.tgrelid = 'public.users'::regclass
 into ok;
perform pg_temp.want(coalesce(ok, false),
  'aa_guard_users does not cover all four privileged columns (section 12). '
  'A column absent from TG_ARGV is freely writable by its owner.');
```

`encode(tgargs, 'escape')` then splitting on the null byte is how you read a
trigger's arguments: `pg_trigger.tgargs` is a `bytea` of null-terminated strings,
and there is no view that decodes it. Written any other way this assertion silently
passes.

```sql
-- --- section 13, 14, 15, 16, 17: the remaining guards ------------------
select count(*) = 5 from pg_trigger
 where not tgisinternal and tgname in (
   'aa_guard_appointments',      -- fee/doctor_id/patient_id frozen (13)
   'aa_guard_blood_banks',       -- units only via dispense (14)
   'aa_guard_status_transition', -- status machine (15)
   'ab_track_review_edit',       -- edit window (16)
   'aa_guard_user_delete')       -- deletion with history (17)
 into ok;
perform pg_temp.want(ok,
  'one or more integrity triggers are missing (sections 13-17). List '
  'them with: select tgname from pg_trigger where not tgisinternal;');

-- --- section 17: the ON DELETE actions that were loosened -------------
select count(*) = 0 from pg_constraint
 where contype = 'f' and confdeltype = 'c'
   and confrelid = 'public.users'::regclass
   and conrelid in ('public.appointments'::regclass,
                    'public.payments'::regclass,
                    'public.orders'::regclass,
                    'public.provider_payouts'::regclass)
 into ok;
perform pg_temp.want(ok,
  'a financial table still cascades from public.users (section 17). One '
  'delete in the Supabase dashboard destroys payment history.');

-- --- section 19: notifications stay client-unwritable ------------------
select not has_table_privilege('authenticated', 'public.notifications', 'insert')
 into ok;
perform pg_temp.want(ok,
  'authenticated holds INSERT on notifications (section 19). Any account '
  'can send a phishing notification inside the app UI.');

select count(*) = 0 from pg_policies
 where schemaname = 'public' and tablename = 'notifications' and cmd = 'INSERT'
 into ok;
perform pg_temp.want(ok, 'an INSERT policy was added to notifications (section 19).');

raise notice 'INTEGRITY SMOKE: all assertions passed.';
end $smoke$;
```

### Three whole-schema assertions

These are not per-rule. They catch classes of mistake that this document's
techniques depend on, and each has a specific failure it prevents.

```sql
-- Every SECURITY DEFINER function must pin its search_path.
-- Without it, a caller who can create objects in a schema earlier on the
-- path can shadow a table name and have the definer-privileged function
-- read theirs instead. This is the standard privilege-escalation route
-- out of a SECURITY DEFINER function, and it applies to all 35 of them.
select string_agg(p.proname, ', ')
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and p.prosecdef
   and not exists (
     select 1 from unnest(coalesce(p.proconfig, '{}')) c
      where c like 'search\_path=%')
 into strict v_bad;
perform pg_temp.want(v_bad is null,
  'SECURITY DEFINER functions without a pinned search_path: ' ||
  coalesce(v_bad, ''));

-- Every table with RLS enabled must have at least one policy.
-- RLS on with no policies denies everything, which surfaces as an empty
-- list screen rather than an error -- the same zero-rows-is-not-an-error
-- problem as section 16, applied to reads.
select string_agg(c.relname, ', ')
  from pg_class c
 where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
   and c.relrowsecurity
   and not exists (select 1 from pg_policy p where p.polrelid = c.oid)
 into strict v_bad;
perform pg_temp.want(v_bad is null,
  'RLS enabled with no policies on: ' || coalesce(v_bad, '') ||
  ' -- these tables read as permanently empty, with no error.');

-- No policy may be FOR ALL.
-- rls_policies.sql:26 states the rule; this enforces it. A FOR ALL policy
-- collapses select/insert/update/delete into one predicate, and every
-- column-immutability argument in sections 12-18 assumes they are
-- separable.
select string_agg(polname, ', ') from pg_policy
 where polrelid in (select oid from pg_class
                     where relnamespace = 'public'::regnamespace)
   and polcmd = '*'
 into strict v_bad;
perform pg_temp.want(v_bad is null,
  'FOR ALL policies found: ' || coalesce(v_bad, ''));
```

Declare `v_bad text;` alongside `ok` in the block's `declare` section. `into
strict` is wrong for `string_agg` over an empty set — it returns one row
containing `NULL`, which is what these tests want, so plain `into` is correct.
Written with `strict` the aggregate still returns exactly one row and it passes;
it is noted because the reflex to add `strict` to a scalar select is a good one
that would be harmful on a `select ... from pg_class` with no aggregate.

### Wiring it in

```bash
# scripts/verify_integrity.sh
set -euo pipefail
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/integrity_smoke.sql
psql "$DATABASE_URL" -Atqf supabase/tests/detail_codes.sql | sort > /tmp/db.txt
grep -o "'[A-Z][A-Z0-9_]*'\s*:" app/lib/core/network/integrity_errors.dart \
  | tr -d "':" | tr -d ' ' | sort > /tmp/dart.txt
if diff <(comm -23 /tmp/db.txt /tmp/dart.txt) \
        <(printf 'NOT_ADMIN\nNOT_AUTHENTICATED\n') > /dev/null; then
  echo "DETAIL codes: in sync."
else
  echo "DETAIL codes out of sync:"; comm -3 /tmp/db.txt /tmp/dart.txt; exit 1
fi
```

Run it after every `supabase db push`, and before every release build. It takes
under a second and it is the only thing standing between this document and the
failure mode it was written about: a rule that was true when it was written, is
false now, and broke nothing when it changed.

### What it deliberately does not check

Behaviour. Every section above ends with a reproduction test that needs two
sessions, real rows, or a clock; those belong in a separate suite that runs against
a scratch database with fixtures. Keeping them apart matters, because a suite that
needs fixtures is a suite that gets skipped on production, and production is where
you most need to know whether the index exists.

---

## 23. Apply order, and what to record

### The migrations this part adds

Sixteen files, in `supabase/migrations/`. The timestamp prefix is the apply order
and it is not arbitrary — the dependencies in the last column are real.

| File | Section | Depends on |
|---|---|---|
| `20260810000009_payment_hold_expiry.sql` | 4 | pg_cron available in `extensions` |
| `20260810000010_review_timing_restore.sql` | 5 | — |
| `20260810000011_available_slots_verified_only.sql` | 6 | `01_DATABASE.md` §6.2 if the schedule model was rebuilt |
| `20260810000012_single_payment_hold.sql` | 7 | `…000009` (needs `hold_expires_at`) |
| `20260810000013_review_pharmacy_evidence.sql` | 8 | `…000010` (extends the same function) |
| `20260810000014_place_order_detail_codes.sql` | 9 | — |
| `20260810000015_payout_amount_integrity.sql` | 11 | — |
| `20260810000016_guard_column_coverage.sql` | 12 | `01_DATABASE.md` §3 (`users.phone_verified`) |
| `20260810000017_freeze_appointment_doctor.sql` | 13 | — |
| `20260810000018_blood_unit_decrement.sql` | 14 | — |
| `20260810000019_transition_detail_code.sql` | 15 | — |
| `20260810000020_review_edit_window.sql` | 16 | `…000010` |
| `20260810000021_user_deletion_integrity.sql` | 17 | — |
| `20260810000022_blogs_grant_narrow.sql` | 18 | **Hold** until Part 09 provides admin authoring RPCs |
| `20260810000023_notification_read_only_flag.sql` | 19 | column names confirmed against the live table |
| `20260810000024_blogs_status_not_null.sql` | 18 | run its `update` first |

Two are conditional and must not be applied blindly. `…000022` breaks admin blog
authoring if the RPCs do not exist yet (section 18). `…000011` must not restate
`available_slots()`'s body if `01_DATABASE.md` §6.2 rebuilt the schedule model —
restating a body you did not author is precisely how the section 5 regression
happened.

Apply them one at a time, running the smoke suite after each. A batch push that
fails tells you the batch failed; it does not tell you which invariant is now half
installed.

### The Dart changes

| File | Change | Section |
|---|---|---|
| `app/lib/core/network/integrity_errors.dart` | **New.** The map and `localizeIntegrityError`. | 2, 21 |
| `app/lib/core/network/supabase_service.dart:336` | Replace the `reviews_one_per_user` branch — that index does not exist. | 5 |
| `app/lib/core/network/supabase_service.dart:209` | `23503` message is backwards for `RESTRICT`; branch on `still referenced`. | 17 |
| `app/lib/core/network/supabase_service.dart:326` | Add the payout and hold constraint names. | 7, 11 |
| Review, blog and profile repositories | The `.select()` row-count pattern — an RLS-filtered UPDATE returns success. | 16, 18, 20 |
| Booking screen | Re-fetch `available_slots()` on `SLOT_TAKEN`, not just show the message. | 3 |
| Device token registration | The upsert-owns-nothing problem. | 20 |

The `integrity_errors.dart` map is the only new file. Everything else is an edit to
something that exists, which is what R2 and D1 require.

### The record

R8 asks for honesty in `IMPLEMENTATION_LOG.md`. For this part, that means recording
four things per contradiction, because "done" is not a useful entry:

1. Whether the mechanism was **already present**, **restored**, or **new**. Eleven
   of the twenty-one were already enforced; saying so is more useful than claiming
   twenty-one fixes.
2. Whether the reproduction test was **actually run**, and against what. A two-session
   race test that was reasoned about but not executed is not evidence.
3. Any migration **deliberately not applied**, with why. Sections 18 and 19 both
   produce one.
4. The SQLSTATE the test observed, not the one this document predicts. Where they
   differ, this document is wrong and should be corrected.

The single most valuable entry is the third. An unapplied hardening migration that
nobody has written down becomes, within a month, a migration everyone assumes is
live.

### The one sentence to keep

Every rule in this file exists because the alternative was trusting a client the
project does not control. Where a rule lives only in Dart, it is a suggestion.
Where it lives in a constraint, an index, or a trigger, it is a rule — and the
smoke suite in section 22 is how you know it is still there.

