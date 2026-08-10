# Payment & Order Architecture — Root Cause Analysis and Fix

Two reported errors:

1. Cart checkout → `orders must be created through public.place_order()`
2. Appointment payment → `FunctionException(status: 400, details: {error: Appointment is not awaiting payment})`

Both were symptoms. The audit below found fourteen defects; every one is fixed
at the layer that owns it. No guard was removed, no status check was bypassed,
no RLS policy was weakened — every privilege change in this work *tightens*.

---

## 1. Root causes

### A — `SECURITY DEFINER` does not change `session_user` (causes error #1)

`guard_orders_insert()` decided whether a write was trusted with:

```sql
if session_user <> 'authenticator' then ... -- treat as trusted
```

The intent was "allow the write when it arrives from inside a SECURITY DEFINER
function". That is not what the expression tests. `SECURITY DEFINER` changes
`current_user`; it leaves `session_user` fixed at the login role for the whole
session. PostgREST always logs in as `authenticator` and then `SET ROLE`s to
`authenticated`. So `session_user` is *always* `'authenticator'` — inside
`place_order()` exactly as much as outside it.

The guard therefore fired against the one function permitted to write, and the
only way to place an order was a path the guard also rejected. `place_order()`
was unreachable by construction.

The same broken discriminator appeared in `guard_appointments_insert()` and
`guard_order_items_insert()`.

**Fix.** A transaction-local marker set by the trusted functions themselves:

```sql
perform set_config('ayur.trusted_path', '1', true);  -- true = tx-local
```

set by `trusted_path_begin()`, cleared by `trusted_path_end(prev)` (which
restores the previous value, because the calls nest — `place_order` → trigger,
`record_payment_split` → `payments_apply_verification` → `update appointments` →
more triggers), and read back by `public.trusted_path_active()`, which
`public.write_is_trusted()` wraps. `trusted_path_begin` / `_end` are revoked
from `public`, `anon`, `authenticated` **and** `service_role`, so no API caller
can arm the marker. It cannot be forged from PostgREST:
the setting is transaction-scoped, PostgREST runs one statement per
transaction, and a client has no way to execute `set_config` before its own
statement. Every guard now asks `write_is_trusted()`. The rule that orders must
come through `place_order()` is intact — it is now *enforceable* instead of
absolute.

### B — the appointment guard overwrote the status it was later checked for (causes error #2)

`guard_appointments_insert()` re-stamped every inserted row:

```sql
new.status := 'pending';
```

`create-checkout-session` then refused to start a payment unless the row was in
`pending_payment`:

```ts
if (appointment.status !== "pending_payment") return errorResponse(..., "Appointment is not awaiting payment", 400)
```

No booking could ever be in `pending_payment`, because the trigger had rewritten
it on the way in. The check was correct; the state it wanted did not exist. That
is why the pay button was reachable in a state the server rejected — the UI was
reading a real status, and the Edge Function was demanding an unreachable one.

**Fix.** `pending_payment` became a real, reachable state. `appointments_book()`
opens a booking that has a fee in `pending_payment` and a zero-fee booking in
`pending`. The guard still overwrites an untrusted client's status — that belt
stays — but it now *derives* the right opening state from the fee instead of
forcing `pending` unconditionally, and it accepts `pending_payment` as a legal
one. Belt and braces both hold: direct `INSERT` is revoked outright as well
(§3), and thereafter legality is owned by `appointments_guard_transition()`
(§4). The Edge Function's check was
**not** removed — it moved server-side into `gateway_payment_begin()` →
`assert_appointment_payable()`, which is authoritative and returns a
machine-readable reason.

### C — `guard_admin_only_columns` blocked the verification path

`payments_apply_verification()` is the only function allowed to move
`payment_status`, and the column guard refused its write for the same
`session_user` reason as A. Verification could not complete even when payment
had. Fixed by A.

### D — the Stripe migration never applied

`20260808000001_stripe_payment_integration.sql` had eight `end if` without
trailing semicolons, an `alter type ... add value` used in the same transaction
that added it, `a.fee` / `a.status` selected into a `payments%rowtype` whose
columns are `amount` / `payment_status`, and a uuid assigned to a bigint. It
aborted on load. Everything it defined was missing at runtime, which is why
failures looked like "the function is just wrong" rather than "the function is
absent".

**Fix.** The file is now a documented no-op that explains each defect, rather
than a deletion — any deployment ledger that recorded it stays consistent. Its
real content was rewritten correctly in `20260809000002`.

### E–G — three functions broken independently of the above

- `record_payment_split()` — commission maths referenced a column that does not
  exist on the row type it selected into.
- `confirm_appointment()` — assigned a uuid into a bigint parameter.
- `expire_stale_appointments()` — swept `pending` only. Once bookings began
  their life in `pending_payment`, unpaid bookings would never expire and would
  hold their slot forever.

### H — no order idempotency

`place_order()` had no idempotency key and no lock. A double tap, a retry after
a timeout, or a returned-to screen each placed a *separate real order*. The
client could not tell "my request was lost" from "my request succeeded and the
response was lost", and the server offered nothing to disambiguate.

### I — the cart had no gateway path

Card payment existed for appointments only. A cart order could be created with a
gateway method and then had nowhere to go.

### J — two divergent sources of truth

`schema.sql` (converted MySQL structure) and `migrations/*.sql` both define the
same functions, and `schema.sql` still contained every pre-fix definition. A
database bootstrapped from `schema.sql` alone reproduces both original errors;
applying `schema.sql` *after* the migrations silently regresses the fix.

**Fix.** An authority block at the top of `schema.sql` stating the run order,
naming the specific stale functions and their line numbers, and stating which
order converges and which regresses. The long-term remedy — regenerate it with
`supabase db dump --schema public` — is recorded there. This is a documentation
fix, not a code fix, and remains a live risk (§7).

### K — the webhook swallowed errors and returned 200

Any RPC failure was logged and answered `200`. To Stripe, `2xx` means *never
redeliver*. A transient database error during `checkout.session.completed`
permanently lost the payment confirmation: money captured, appointment never
confirmed, no retry, no alert.

### L — Flutter surfaced a state machine it did not know about

`canPay` did not exclude `expired`; no filter chip, status colour or icon
existed for `pending_payment` or `expired`; the doctor screen rendered no action
buttons for a booking in `pending_payment`, so a doctor could not act on new
bookings at all once they started life in that state.

### M — `core/providers.dart` did not compile *(found during verification)*

`paymentHealthCheckProvider` lived in `lib/core/providers.dart` and imported
`../../features/appointments/data/appointment_repository.dart`. From
`lib/core/`, `../../` is `app/` — the path resolves outside `lib/` and does not
exist. It also inverted the layering: `core` is what features are built on.
Moved to `appointment_repository.dart`, beside the method it calls.

### N — idempotency backstops fell through to "That already exists." *(found during verification)*

The unique indexes behind `place_order()` and payment settlement are the last
line of defence if two requests race past the advisory lock. When they fired,
`_uniqueMessage()` had no branch for them and produced `That already exists.` —
which tells a user nothing and invites another tap. Mapped to the specific
sentences the brief asked for.

---

## 2. Files changed

### SQL

| File | Change |
|---|---|
| `supabase/migrations/20260809000001_appointment_status_pending_payment.sql` | **New.** Adds `pending_payment` to the enum, alone in its transaction (Postgres forbids using a new enum value in the transaction that adds it). |
| `supabase/migrations/20260809000002_payment_architecture_fix.sql` | **New, 1952 lines.** The whole fix, in 15 parts. |
| `supabase/migrations/20260808000001_stripe_payment_integration.sql` | Reduced to a documented no-op (root cause D). |
| `supabase/schema.sql` | Authority / run-order block (root cause J). |

### Edge Functions

| File | Change |
|---|---|
| `supabase/functions/create-checkout-session/index.ts` | Client-side status check replaced by `gateway_payment_begin()`. Adds session reuse, `client_reference_id`, `expires_at`, Stripe customer reuse, error mapping. |
| `supabase/functions/stripe-webhook/index.ts` | Retry semantics (§5). Terminal SQLSTATEs vs retryable; `constructEventAsync`; unpaid sessions closed explicitly. |

### Flutter

| File | Change |
|---|---|
| `core/utils/idempotency.dart` | **New.** `IdempotencyToken` — mint, reuse across retries, `renew()` only once an attempt settles. |
| `features/payment/data/payment_service.dart` | **New, 484 lines.** The single authoritative payment flow: `payability()`, `submitManualPayment()`, `startCardCheckout()`, `PaymentFailure` taxonomy. |
| `core/network/supabase_service.dart` | Unique-violation messages for the idempotency backstops (N). |
| `core/providers.dart` | Removed the non-resolving import and the misplaced provider (M). |
| `features/appointments/data/appointment_repository.dart` | `pay()` / `createStripeCheckoutSession()` are thin delegates; `payability()` added; `paymentHealthCheckProvider` rehomed here. |
| `features/pharmacy/data/pharmacy_repository.dart` | `checkout()` takes and forwards `idempotencyKey`. |
| `features/pharmacy/presentation/checkout_screen.dart` | Holds the token across retries; re-entrancy guard; `DUPLICATE_ORDER` routes to the order instead of showing an error. |
| `features/appointments/presentation/payment_success_screen.dart` | Invalidates the stale list on success; stops polling on 404; no raw `e.toString()` to the user. |
| `features/appointments/presentation/my_appointments_screen.dart` | `pending_payment` / `expired` chips; benign refusals refresh instead of erroring. |
| `features/provider/presentation/doctor_appointments_screen.dart` | Confirm/Cancel now reachable for `pending_payment` (L). |
| `features/admin/presentation/admin_appointments_screen.dart` | `pending_payment` / `expired` chips. |
| `core/constants/app_colors.dart` | Status colour + icon for both new states. |
| `models/appointment_models.dart` | `canPay` excludes `expired`; `isAwaitingPayment`, `isExpired`; `StripeCheckoutSession.reused`. |

---

## 3. Database functions and policies changed

**Trust primitive (new).** `trusted_path_begin()` / `trusted_path_end(text)` /
`trusted_path_active()`, and `write_is_trusted()` — the single discriminator
every guard now asks.

**Guards re-pointed at it, semantics otherwise unchanged:**
`guard_orders_insert`, `guard_order_items_insert`, `guard_appointments_insert`,
`guard_admin_only_columns`, `guard_payments_insert`, `guard_provider_insert`,
`guard_reviews_insert`, `appointments_guard_confirm`,
`appointments_guard_reschedule`.

**Rewritten:** `place_order()` (idempotency key + advisory lock + re-check),
`appointments_book()` (opens in `pending_payment` when a fee is due — signature
byte-identical, so no PostgREST overload ambiguity), `record_payment_split()`
(E), `confirm_appointment()` (F), `handle_failed_payment()`,
`expire_stale_appointments()` (G), `payment_health_check()`.

**New:** `appointment_payability(bigint)` — the single payability predicate,
returning `{payable, code, message, status, amount}`; `assert_appointment_payable()`,
which raises it as an error for write paths; `appointments_guard_transition()`
(the state machine, §4); `gateway_payment_begin()` / `gateway_payment_attach()`;
`submit_manual_payment()`; `payments_apply_verification()`.

**Privileges — every change tightens.** Four `revoke insert` (orders,
order_items, appointments, payments from `anon`, `authenticated`), so the RPCs
are the only way in *structurally*, not merely by trigger convention. `revoke
all` on `trusted_path_begin/_end` from every API role, and on
`record_payment_split` / `confirm_appointment` / `handle_failed_payment` from
`public`, `anon`, `authenticated` — `20260808000001` had granted those three to
`authenticated`, which would have let any signed-in user mark their own
appointment paid. They are now `service_role` only.

**Structural constraints (the backstops behind the locks):**

```sql
alter table public.orders add column if not exists idempotency_key varchar(64);
create unique index if not exists uq_orders_idempotency
  on public.orders (user_id, idempotency_key) where idempotency_key is not null;
```

plus partial unique indexes on verified payments per appointment and on the
Stripe session / payment-intent ids.

**Overload safety.** `place_order()` gained a parameter. Adding a defaulted
parameter without dropping the old signature makes PostgREST ambiguous and
breaks *every* call, so the 7-arg form is explicitly dropped before the 8-arg
form is created, and the grant names the 8-arg signature. Four other functions
are dropped and recreated with identical signatures because
`create or replace` cannot change a return type.

**RLS.** No policy was loosened. The guards became *more* precise: previously
they rejected everything including the trusted path; now they reject exactly the
untrusted path.

---

## 4. State transitions

```
                         fee = 0
   appointments_book() ──────────────► pending ──► confirmed ──► completed
            │                             │
            │ fee > 0                     └──► cancelled / expired
            ▼
     pending_payment ──── paid & verified ────► confirmed ──► completed
            │
            ├── cancelled (by patient/doctor/admin)
            └── expired   (sweep, unpaid past its window)
```

Enforced by `appointments_guard_transition()` on the
`aa_guard_status_transition` trigger (`before update of status`). The `aa_`
prefix is load-bearing: trigger order is alphabetical, so this runs first.
Illegal transitions raise `P0001`. Legality binds this application's own RPCs as
well as clients — a state machine our server code can sidestep is not a state
machine — and only an administrator or a direct database session may repair a
row outside it. Separately, the only status a client may set directly is
`cancelled`, and only the owning patient or the booking's doctor may set it.

- `pending_payment` is entered **only** by `appointments_book()`.
- It is left for `confirmed` **only** by the settlement path, after verification.
- `expired` is reached **only** by the sweep, which now includes
  `pending_payment` (G).
- The client never writes a status. It requests an action; the server decides.

---

## 5. Payment flow after the fix

**Cart.** Screen mints an `IdempotencyToken` → `checkout(idempotencyKey:)` →
`place_order()` looks the key up; if it finds an order it returns that one. If
not, it takes `pg_advisory_xact_lock` on the user, re-checks under the lock,
then validates the cart, re-reads every price and stock level **from the
products table** (client prices are never trusted), writes order + items +
stock decrements + cart clear in one transaction, and stamps the key. The unique
index is the backstop if two requests race past the lock.

The token is reused across retries — a retry after a timeout is the same
request and must not create a second order — and renewed only once an attempt
settles.

**Appointment.** `payability()` asks the server whether payment may start, so
the UI never guesses. `gateway_payment_begin()` takes an advisory lock on the
appointment, re-checks payability authoritatively via
`assert_appointment_payable()`, expires anything stale, and then either returns
an existing live session — a double tap reuses the same Stripe page rather than
opening a second — or creates one. `gateway_payment_attach()` (service-role
only) links the Stripe session back. Stripe redirects to a screen that polls for
the verified state rather than trusting the redirect.

**Webhook.** Signature verified with `constructEventAsync`. Settlement is
idempotent — a duplicate `checkout.session.completed` is a no-op via the unique
index. Failures are classified: terminal SQLSTATEs (`PGRST116`, `42501`,
`P0001`, `22023`, `22P02`) return 2xx and raise a **critical reconciliation
log**, because retrying cannot help; anything else returns **500 so Stripe
redelivers**. Root cause K was the inverse of this.

**Errors.** `P0001` carries a code in `DETAIL`; `SupabaseService` maps it to 422
and passes the message through. The user sees "You have already paid for this
appointment.", "This appointment is no longer available for payment.", "Your
previous order is already being processed.", "Payment was not completed. You can
try again." Raw driver text never reaches the UI — `payment_service.dart`
filters it and the two screens that previously printed `e.toString()` no longer
do.

---

## 6. Tests performed — and what could not be run

**This must be read literally: nothing was executed.** The environment has no
Flutter or Dart SDK, no Postgres or `psql`, no Deno, no package manager (`apt`
fails on a dpkg lock), no root (`sudo` is denied), and no network egress (an
allowlist proxy returns 403). `flutter analyze`, `flutter test` and applying the
migrations were all **impossible**, not skipped.

Verification was therefore static, by reading. It found two real defects that
`flutter analyze` would have caught first — **M** (an import resolving outside
`lib/`) and **N** (unmapped constraint messages) — both now fixed.

Performed:

- Function-signature and overload audit — 27 created, 5 dropped-then-recreated;
  confirmed no PostgREST ambiguity and that `appointments_book`'s signature is
  byte-identical to its two prior definitions.
- Repo-wide sweep for direct `orders` inserts — none outside `place_order()`.
- Repo-wide sweep for appointment status writes — none client-side.
- Repo-wide sweep for payment initiation paths — all route through
  `PaymentService`.
- Confirmed `20260809000001` is a safe no-op on a fresh bootstrap, since
  `schema.sql:153` already declares the full enum.
- Confirmed `supabase/functions/create-payment-intent/` and
  `payment-webhook/` are **empty directories** — no alternate unguarded payment
  path exists (see §7).

**Still required before release, in order:** `supabase db push` against a
staging project; `flutter analyze`; `flutter test`; then manually — double-tap
checkout, kill the network mid-checkout and retry, pay an appointment twice,
replay a Stripe webhook, let an unpaid booking expire.

---

## 7. Remaining risks

1. **Nothing has been executed.** Every claim here is from reading code. The two
   defects found while re-reading are evidence that more may remain.
2. **`schema.sql` is still a second source of truth.** It now carries a warning,
   but a warning is not a mechanism. Applying it after the migrations regresses
   the database. Regenerate it from a migrated instance with
   `supabase db dump --schema public`.
3. **Two empty Edge Function directories.** `create-payment-intent/` and
   `payment-webhook/` contain no `index.ts`. Harmless at runtime, but
   `supabase functions deploy` iterating the directory will fail on them.
   Delete both.
4. **The trusted-path marker assumes one statement per transaction.** True for
   PostgREST today. If anything ever opens a multi-statement transaction on the
   `authenticated` role, the marker could outlive its intended scope. It is
   transaction-local, so it cannot leak *between* requests.
5. **Expiry windows are unproven.** The sweep now includes `pending_payment`,
   but the window has never run against real traffic. Too short strands paying
   users; too long holds slots hostage.
6. **Stripe reconciliation is a log, not an alarm.** Terminal webhook failures
   write a critical log entry. Nothing pages a human. That log needs a monitor.
7. **Manual (non-gateway) payments still require human verification**, which is
   by design — but the escrow split only runs after that step, so an unverified
   backlog silently delays provider payouts.
8. **Four files lack a trailing newline** after the CRLF normalisation
   (`deep_link_service.dart`, `payment_debug_logger.dart`,
   `payment_cancelled_screen.dart`, `receipt_screen.dart`). Cosmetic; Dart does
   not care.
