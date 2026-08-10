# Part 09 — Provider Features

**Phase 10.** Depends on Parts 01, 12, 02, 03, 06, 07, 04, 05 being complete.
Read the master plan first; it wins every conflict.

This part builds the four provider workspaces: the doctor's personal chamber,
the hospital/clinic, the pharmacy, and blood-bank management. It also retires
`stub_dashboard_screen.dart`, which currently tells five roles their dashboard
does not exist while two full modules sit beside it.

No SQL from Parts 01, 04 or 12 is restated here. Where a rule is enforced in the
database, this part names it and cites the section that owns it.

---

## 0. What already exists — verified 2026-08-10, do not re-derive

Twelve files. Every path below was read.

| File | Lines | What it is |
|---|---:|---|
| `app/lib/features/provider/data/provider_repository.dart` | 842 | one repository for all four roles |
| `.../presentation/provider_controllers.dart` | 78 | Riverpod wiring, 9 providers |
| `.../presentation/doctor_dashboard_screen.dart` | — | doctor landing |
| `.../presentation/doctor_appointments_screen.dart` | — | filterable list |
| `.../presentation/doctor_payouts_screen.dart` | — | payout ledger |
| `.../presentation/doctor_profile_screen.dart` | — | multi-section form |
| `.../presentation/place_dashboard_screen.dart` | — | hospital/clinic/pharmacy landing |
| `.../presentation/place_profile_screen.dart` | — | place form |
| `.../presentation/provider_reviews_screen.dart` | — | shared by doctor and place |
| `.../presentation/widgets/verification_banner.dart` | — | three-state banner |
| `.../presentation/widgets/workspace_actions.dart` | — | shared AppBar menu |
| `.../presentation/widgets/stat_grid.dart` | — | dashboard tiles |

The repository's public methods are frozen by R3. They are:

`doctorDashboard()`, `doctorAppointments()`, `setAppointmentStatus()`,
`payouts()`, `updateDoctorProfile()`, `placeDashboard()`,
`updatePlaceProfile()`, `reviews()`.

Everything this part adds is a **new method beside them**, never a change to one.

### Three facts that shape every section below

**Ownership is resolved from the JWT, never from a parameter.**
`_requireDoctor()` (`provider_repository.dart:548`) and `_requirePlace()` (`:570`)
look the row up by `auth.uid()`. `_requirePlace()` tries all three place tables
in turn rather than trusting `users.role`, so a user whose role says `hospital`
but who owns no hospital row gets a clean 403 instead of an empty dashboard.
Keep this pattern. Every new method starts with one of these two calls.

**`ApiException` is the only error type.** `SupabaseService.guard()` wraps every
call and maps SQLSTATEs to status codes. Do not introduce a second error type;
Part 12 §2 defines the DETAIL-code contract that carries integrity failures
through to a localized message.

**Blood bank is not a provider role.** See §5 — this is the one place the brief
and the schema disagree, and the disagreement is load-bearing.

---

## 1. The shared provider shell and the verification gate

### 1.1 What the gate is for

A provider registers, uploads documents, and waits. During that wait the account
exists and can sign in. The question this section answers is: *what may they
touch?*

The wrong answer — and the easy one — is "everything, the API will 403 them."
That produces a workspace of error views, and a provider who cannot tell a
permissions problem from a broken app. The other wrong answer is a blank screen
that says "pending", because a pending provider still needs to finish their
profile and re-upload a rejected document.

The rule:

> A provider may always edit their own profile and read their own status.
> They may not touch anything that implies they are live — publishing a
> schedule, taking a booking, listing a product, or reading money.

### 1.2 The three states, and what each unlocks

`verification_status` is the enum `('pending','verified','rejected')`
(`supabase/schema.sql:167`). `status` is `provider_status`
`('pending','active','inactive')` (`:171`). They are independent: an admin may
deactivate an already-verified provider, which hides them from the directory
without revoking their verification.

`VerificationBanner` already models exactly this — see its doc comment at
`app/lib/features/provider/presentation/widgets/verification_banner.dart:1-6`,
and the `deactivated` branch at `:35`. Do not rewrite it. Localize it (Part 06)
and reuse it.

| Surface | pending | rejected | verified + active | verified + inactive |
|---|---|---|---|---|
| Dashboard (read own status) | yes | yes | yes | yes |
| Profile edit | yes | **yes** | yes | yes |
| Document re-upload | yes | **yes** | yes | yes |
| Schedule / services / products — read | yes, read-only | read-only | yes | yes |
| Schedule / services / products — write | **no** | **no** | yes | yes |
| Appointment / order queue | empty by construction | empty | yes | yes |
| Earnings, payouts, sales history | **no** | **no** | yes | yes |
| Reviews about me | yes | yes | yes | yes |

Two entries deserve their reason stated.

**Rejected keeps profile and upload.** Rejection is not a ban. The admin gives a
reason (`doctors.rejection_reason`, `schema.sql:364`) and the applicant's only
route back is to fix what was wrong and resubmit. Locking the form locks them
out of the remedy.

**Earnings are hidden before approval, not merely empty.** An unverified provider
has no payouts, so the screen would render an empty state — which reads as "you
have earned nothing" rather than "this is not available yet". Those are different
statements and the second one is the true one. Gate the route, do not rely on the
query returning zero rows.

### 1.3 Where the gate lives — three layers, and why all three

| Layer | File | What it stops |
|---|---|---|
| Router | `app/lib/app/router.dart` `_guard()` | a deep link to `/doctor/payouts` while pending |
| Widget | `ProviderGate` (new) | a stale in-memory route after a status change |
| Database | Part 12 §6 trigger, Part 02 RLS | a REST client bypassing the app entirely |

The router layer is a **convenience**, not a control. Part 12 §12 (contradiction
#14) is the standing argument: a check that lives only in Dart is one refactor
from silently disappearing, and a `curl` never runs Dart at all. The database
layer already refuses to book an unverified provider (Part 12 §6) and already
refuses to let a provider write `verification_status` (`_guardedColumns`,
`provider_repository.dart:89`). This section adds the two client layers so the
provider sees an explanation instead of a 403.

Add to `router.dart` beside `_patientOnly`:

```dart
/// Provider routes that only make sense once the account is approved.
///
/// Matched by prefix via [_under]. The database refuses these operations for an
/// unverified provider anyway (Part 12 §6); this list exists so the provider
/// reads "your account is under review" instead of a permission error.
const List<String> _verifiedProviderOnly = [
  Routes.doctorPayouts,
  Routes.doctorSchedule,
  Routes.placeServices,
  Routes.placeProducts,
  Routes.placeOrders,
  Routes.placePayouts,
];
```

The guard cannot decide this alone: `AuthState` carries `role` but not
`verification_status`, and adding a network read to a redirect callback would run
it on every navigation. So the router redirects to the *dashboard* — which always
loads — and the dashboard's own state decides what to render:

```dart
// In _guard(), after the existing workspace fences:
if (_verifiedProviderOnly.any((p) => _under(loc, p)) &&
    role != UserRole.patient &&
    role != UserRole.admin) {
  // Verification is a data question, not a session question. Bounce to the
  // workspace landing screen, which already fetches the status and renders
  // ProviderGate. Never read the network from a redirect.
  return _pendingBounce(role);
}
```

`_pendingBounce` returns `_landingFor(role)` when the gate is closed. Because the
router cannot know, the landing dashboard is authoritative: `ProviderGate` wraps
every gated body and is the component that actually refuses.

```dart
/// Renders [child] only when the provider is approved; otherwise explains why.
///
/// Placed inside each gated screen's `data` branch, so it reads a status that
/// was already fetched rather than issuing a second query. `onFixProfile` is the
/// route out for a rejected applicant — see §1.2 for why rejection must not be
/// a dead end.
class ProviderGate extends StatelessWidget {
  const ProviderGate({
    super.key,
    required this.status,
    required this.accountStatus,
    required this.child,
    this.onFixProfile,
  });

  final VerificationStatus status;
  final String? accountStatus;
  final Widget child;
  final VoidCallback? onFixProfile;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (status.isVerified) return child;

    return EmptyView(
      icon: status.isRejected
          ? Icons.report_gmailerrorred_outlined
          : Icons.hourglass_top_outlined,
      title: status.isRejected
          ? l.providerRejectedTitle
          : l.providerUnderReviewTitle,
      message: status.isRejected
          ? l.providerRejectedBody
          : l.providerUnderReviewBody,
      actionLabel: onFixProfile == null ? null : l.providerFixProfile,
      onAction: onFixProfile,
    );
  }
}
```

`EmptyView` already exists at `app/lib/core/widgets/state_views.dart:37` with an
action slot. Use it rather than a bespoke card — R5 wants one visual vocabulary
for empty states, and "not available yet" is an empty state with a reason.

### 1.4 Strings — EN / BN

Part 06 owns the ARB mechanics. These are the keys this section requires.

| Key | English | বাংলা |
|---|---|---|
| `providerUnderReviewTitle` | Your account is under review | আপনার অ্যাকাউন্ট পর্যালোচনায় আছে |
| `providerUnderReviewBody` | An administrator is checking your documents. You can finish your profile while you wait. This usually takes 1–2 working days. | একজন প্রশাসক আপনার নথি যাচাই করছেন। অপেক্ষার সময় আপনি প্রোফাইল সম্পূর্ণ করতে পারেন। সাধারণত ১–২ কর্মদিবস লাগে। |
| `providerRejectedTitle` | Verification was not approved | যাচাই অনুমোদিত হয়নি |
| `providerRejectedBody` | Read the reason below, correct your details or upload a clearer document, and submit again. | নিচের কারণটি পড়ুন, তথ্য সংশোধন করুন বা স্পষ্ট নথি আপলোড করে আবার জমা দিন। |
| `providerFixProfile` | Update my profile | প্রোফাইল সংশোধন করুন |
| `providerDeactivatedTitle` | Your listing is hidden | আপনার তালিকা লুকানো আছে |
| `providerDeactivatedBody` | Your account is approved but an administrator has deactivated the listing. Contact support. | আপনার অ্যাকাউন্ট অনুমোদিত, তবে প্রশাসক তালিকাটি নিষ্ক্রিয় করেছেন। সহায়তায় যোগাযোগ করুন। |

### 1.5 Acceptance test

1. Register a doctor. Do not approve.
2. Sign in. Expect `/doctor` to load with the pending banner.
3. Navigate to `/doctor/payouts` by deep link. Expect a redirect to `/doctor`,
   never a spinner that resolves to an error view.
4. Open `/doctor/profile`. Expect an editable form.
5. Reject the application with a reason. Reload. Expect the rejected banner, the
   reason text, and the profile still editable.
6. Approve. Reload. Expect the banner gone and `/doctor/payouts` reachable.

---

## 2. The doctor's personal chamber

### 2.1 One doctor, two workplaces — and why the data model must know the difference

The brief is explicit: a doctor may be employed at a hospital **and** run a
private chamber. Both are real, both take bookings, and the money splits
differently. If the model conflates them, every downstream number is wrong: the
hospital appears to earn the chamber's consultations, the doctor's payout ledger
mixes two employers, and a patient who books "Dr Karim at Square Hospital" ends
up at his Dhanmondi chamber.

The separation this part establishes:

| Concept | Where it lives | Owns the money |
|---|---|---|
| The personal chamber | the `doctors` row: `chamber_address` (`supabase/schema.sql:323`), `consultation_fee` (`:326`), plus `doctor_schedules` / `doctor_blackouts` (Part 01 §6.2) | `doctors.commission_percentage` (`:330`) |
| Employment at a hospital or clinic | `hospital_doctors`, new in §3.2 | the place's own `commission_percentage` (`:398`, `:454`) |
| A bookable consultation | `appointments.doctor_id` → `doctors.id` — always the chamber | the doctor's rate |
| A bookable hospital service | `hospital_services` (Part 01 §6.3) — owned by hospital or clinic, never by a doctor | the place's rate |

Read that fourth row carefully, because it is the load-bearing decision. **A
hospital does not sell a doctor's time through this platform.** It sells
*services* — an MRI, an ultrasonography, a blood test — which are priced rows in
`hospital_services` with no doctor attached. A doctor's consultation is only ever
bookable through the doctor's own chamber. This is not a simplification; it is
what the schema already says, because `appointments` has exactly one provider
column and it points at `doctors`.

The consequence is a clean rule with no special cases:

> Every appointment is a chamber appointment. Every hospital or clinic booking is
> a service booking. Nothing is both, and no row has to be interpreted.

**`doctors.hospital_clinic_name` (`:322`) is not employment.** It is free text a
doctor typed, and today `placeDashboard()` counts a place's doctors by
string-matching it — see `app/lib/features/provider/data/provider_repository.dart:426-437`,
whose own comment admits the count "is not quite the same as 'doctors here'". R2
forbids removing the column, so it stays as the display label it already is, and
`hospital_doctors` becomes the authoritative link. §3.2 specifies the cutover of
that count.

### 2.2 Signup, activation, and where a new doctor lands

`/register/doctor` exists (`app/lib/app/router.dart:99`) and Part 03 owns the
form, the email verification and the BMDC document upload. Part 09 owns only
what happens **after** the link is clicked.

| Step | Owner | Result |
|---|---|---|
| Form submit → `auth.users` + `users` + `doctors` row | Part 03 | `verification_status='pending'`, `status='pending'` |
| Verification email | Supabase Auth (Part 03 §Q3) | session becomes usable |
| First sign-in | `_guard()`, `router.dart:674` | `_landingFor(UserRole.doctor)` → `/doctor` |
| `/doctor` renders | this part | dashboard + pending banner from §1 |
| Admin approves | Part 10 | `verification_status='verified'`, `status='active'` |

Two things must be true of that landing and are worth asserting as tests, not
assumptions. The dashboard must load for a pending doctor — §1.2 gates the
*money* screens, not the dashboard — and no screen may greet an unapproved
doctor with a permissions error. `doctorDashboard()`
(`provider_repository.dart:116`) already satisfies both: it reads the doctor's
own row and `doctor_stats()`, neither of which is gated on verification.

### 2.3 The dashboard

`doctor_dashboard_screen.dart` (291 lines) exists and works. This part changes
three things and rewrites nothing.

| Change | Why |
|---|---|
| Localize every string through `AppLocalizations` | R4 |
| Wrap the earnings tiles in `ProviderGate` | §1.2 — hidden, not zero |
| Add a "Today" section listing today's appointments in time order | The brief's first doctor requirement, and `DoctorDashboard` already carries `recent_appointments` sorted by `created_at`, which is not the same thing |

`doctorDashboard()` already returns `today_appointments` as a **count**
(`provider_repository.dart:174`). A count is not a queue: a doctor opening the
app at 08:00 wants the names and times, not the number 6. Rather than widen the
frozen return type (R3), the Today section reads the existing paged endpoint
with a date filter — one extra query, no signature change:

```dart
/// Today's chamber list, in appointment-time order.
///
/// Deliberately a second provider rather than a field on [DoctorDashboard]:
/// `doctorAppointments()` is frozen by R3 and already does exactly this, and
/// keeping it separate means the dashboard renders its stats even if the day
/// list fails.
final doctorTodayProvider = FutureProvider.autoDispose<Paged<Appointment>>(
  (ref) => ref.watch(providerRepositoryProvider).doctorAppointments(
        page: 1,
        limit: 20,
        date: Fmt.apiDate(DateTime.now()),
      ),
);
```

Tiles, and the source of each — all six already exist in `DoctorStats`
(`app/lib/models/provider_models.dart:87`), so this is a labelling and gating
exercise, not new data:

| Tile | Field | Gated |
|---|---|---|
| Today's appointments | `today_appointments` | no |
| Upcoming | `upcoming_appointments` | no |
| Rating | `doctor.rating` | no |
| Total earnings | `total_earnings` | **yes** |
| Pending payout | `pending_payout` | **yes** |
| Platform fee retained | `platform_fee` | **yes** |

Showing the retained fee beside the payout is deliberate. A provider who sees
only their net share eventually asks where the rest went; showing both, with the
percentage that produced them, turns a suspicion into a line item. Part 04 §4.3
is why the number is trustworthy — it is the frozen rate, not today's.

### 2.4 Publishing availability

This is the largest new surface in §2 and the one with the most ways to go
subtly wrong.

**Route:** `/doctor/schedule` (new). **Screen:**
`app/lib/features/provider/presentation/doctor_schedule_screen.dart` (new).
**Tables:** `doctor_schedules`, `doctor_blackouts` — both defined in Part 01 §6.2,
whose SQL is not restated here.

The screen has two tabs because the two objects answer different questions:
*"which hours do I normally sit?"* and *"which specific days am I away?"*

#### Weekly hours tab

One card per weekday, Saturday first — the Bangladeshi week starts Saturday, and
a Monday-first calendar reads as foreign. Each card lists that day's active
windows; each window is `starts_at`, `ends_at`, `slot_minutes`. Multiple windows
per day are the normal case, not an advanced feature: a doctor sitting 09:00–13:00
and 17:00–21:00 is two rows, and the gap between them is simply uncovered.

Four rules the form must enforce *before* submitting, because each maps to a
constraint that would otherwise surface as a raw Postgres error:

| Rule | Constraint it predicts |
|---|---|
| End time after start time | `doctor_schedules_window_check` |
| Slot length 5–240 minutes | `doctor_schedules_slot_minutes_check` |
| Window at least one slot long | `doctor_schedules_window_fits_slot_check` |
| No overlap with another active window that day | `doctor_schedules_no_overlap` (EXCLUDE, SQLSTATE `23P01`) |

The fourth cannot be fully checked client-side — another device may have added a
window since this screen loaded — so the repository must map `23P01` to a
localized "these hours overlap hours you already published" rather than letting
the constraint name reach a user. `SupabaseService.guard()` is the single place
to add that mapping, beside the existing SQLSTATE table.

#### Editing a window is deactivate-then-insert, never update

Part 01 §6.2 put `where (is_active)` on the EXCLUDE constraint precisely so this
works. An in-place `update` that widens 09:00–13:00 to 09:00–14:00 is fine; an
edit that *splits* one window into two is not, because the first insert overlaps
the row being replaced. So the repository does both steps in one call:

```dart
/// Replaces a doctor's windows for one weekday.
///
/// Deactivate-then-insert rather than update-in-place: splitting one window
/// into two would make the first INSERT overlap the row it is replacing, and
/// doctor_schedules_no_overlap (Part 01 §6.2) would reject it. Deactivating
/// first takes the old rows out of the constraint's predicate.
///
/// Old rows are kept with `is_active = false`, not deleted: an appointment
/// already booked into a removed window must still be explicable afterwards.
Future<List<DoctorSchedule>> replaceScheduleForDay({
  required int weekday,
  required List<ScheduleWindow> windows,
}) async {
  return SupabaseService.guard(() async {
    final doctorId = Fmt.toInt((await _requireDoctor())['id']);

    await _sb
        .db('doctor_schedules')
        .update({'is_active': false, 'updated_at': 'now()'})
        .eq('doctor_id', doctorId)
        .eq('weekday', weekday)
        .eq('is_active', true);

    if (windows.isEmpty) return const <DoctorSchedule>[];

    final rows = await _sb.db('doctor_schedules').insert([
      for (final w in windows)
        {
          'doctor_id': doctorId,
          'weekday': weekday,
          'starts_at': w.startsAt,
          'ends_at': w.endsAt,
          'slot_minutes': w.slotMinutes,
        }
    ]).select();

    return rows.map(DoctorSchedule.fromJson).toList();
  });
}
```

Note what is absent: no `date` parameter, no slot generation, no write to any
appointment. Availability stays **computed** — `available_slots()` is the single
answer to "what is bookable" (Part 01 §6.2), and this screen only edits its
inputs. A doctor publishing hours can never create or destroy a booking.

#### Leave and blackout tab

A date range with an optional bilingual reason, inserted into
`doctor_blackouts`. `ends_on` is **inclusive** — a one-day leave is
`starts_on = ends_on`, and the column comment in Part 01 §6.2 says so. The form
must therefore label the second field "Last day away", not "Until", because
"until 20 September" is ambiguous in both English and Bangla and the off-by-one
is invisible until a patient books the day the doctor left.

Existing bookings in a newly blacked-out range are **not** cancelled. Blacking
out a date stops *new* slots from generating; it does not have the authority to
cancel a paid appointment, which is a refund event owned by Part 04 §8. The
screen must say so, and list the affected bookings with a link to cancel each
one deliberately:

> Marking these dates as leave stops new bookings. You have 3 appointments
> already booked in this range — cancel each one yourself if you will not be
> there. Cancelling refunds the patient.

That paragraph exists because the alternative — silently cancelling — moves
money without the doctor pressing a button that says so.

#### The fallback path, which must not be broken

`doctors.available_days`, `available_from`, `available_to` and `slot_minutes`
(`supabase/schema.sql:338-341`) are still live: Part 01 §6.2 keeps them as the
fallback for a doctor with no `doctor_schedules` rows, and the rewritten
`available_slots()` uses the template branch only when template rows exist. So
the profile form in §2.8 must keep editing them, and the schedule screen must
show a one-line note when the doctor is still on the fallback:

> Your hours come from your profile. Add weekly hours here to sit at different
> times on different days.

### 2.5 When a slot is actually taken — the rule that binds §2 to Parts 04 and 12

The brief states it plainly: *a slot is taken only after the patient has paid in
full, and once taken it is hidden from everyone else; when all slots are gone the
patient sees "no slots available".* Three separate mechanisms already implement
that sentence, and the doctor's workspace must not add a fourth.

| Question | Answered by | Where |
|---|---|---|
| Can two patients hold one slot? | partial unique index `uq_appointments_doctor_slot` | Part 12 §3, contradiction #1 |
| What happens between "Pay" and "paid"? | `status='pending_payment'` + `hold_expires_at`, expired by a `pg_cron` job | Part 12 §4, contradiction #1b |
| Is an unpaid hold visible to others? | no — the unique index covers held rows, and `available_slots()` excludes them | Part 12 §3, §6 |

Note the section numbering: contradiction **#1** is written up in Part 12 **§3**,
and the hold in **§4**. Cite the section, not the contradiction number.

The sequence, stated once so no screen re-derives it:

```
patient taps a free slot
   │
   ├─ appointments row: status 'pending_payment', hold_expires_at = now() + N min
   │  └─ the slot is ALREADY blocked here: the unique index counts
   │     pending_payment, and available_slots() no longer offers it
   │
   ├─ payment succeeds ─→ status 'pending', payment_status 'paid'
   │                      hold becomes a real booking; doctor sees it in the queue
   │
   └─ payment never completes ─→ pg_cron sets status 'expired'
                                 the index's WHERE clause releases the slot
```

**What this means for the doctor's screens, precisely:**

1. A `pending_payment` appointment is **not** in the doctor's queue. It is a
   patient mid-checkout, not a booking. `doctorAppointments()` must exclude it
   by default, and today it does not — the status filter is optional
   (`provider_repository.dart:197`) and a null filter returns everything. Fix by
   excluding `pending_payment` and `expired` unless the caller asks for them by
   name. Showing a doctor a booking that may evaporate in four minutes teaches
   them to distrust the queue.
2. The doctor never marks a slot taken. There is no such action, and adding one
   would create a second writer to availability — exactly the drift Part 01 §6.2
   rejected a materialised slot table to avoid.
3. "No slots available" is a **patient-side** empty state (Part 08), produced by
   `available_slots()` returning zero rows. The doctor's side of it is the Today
   list being full. Do not add a "fully booked" flag to `doctors`; it would be a
   cached truth with no owner.

**The doctor cannot see who is mid-checkout, and that is correct.** A
`pending_payment` row names a patient who has not paid. Exposing it would let a
doctor phone someone who abandoned a booking, and would show the doctor a number
that shrinks when holds expire. The queue shows paid and confirmed work only.

### 2.6 The appointment queue

`doctor_appointments_screen.dart` (421 lines) exists with status and date
filters. Additions:

| Action | Transition | Guard |
|---|---|---|
| Confirm | `pending → confirmed` | `appointments_guard_transition()`, Part 12 §15 |
| Complete | `confirmed → completed` | same; also the precondition for a review, Part 12 §5 |
| Cancel | `pending`/`confirmed` → `cancelled` | same, plus the refund path in Part 04 §8 |

All three go through the existing `setAppointmentStatus()`
(`provider_repository.dart:241`), which is frozen and already scopes the update
to the caller's own `doctor_id`. No new method.

Three UI obligations, each earning its place:

**Cancel demands a reason and says what it costs.** The dialog states that the
patient is refunded and notified, and requires a note — `setAppointmentStatus()`
already accepts `notes` and writes it. A cancellation with no reason is a support
ticket the platform will answer instead of the doctor.

**Complete is offered only after the appointment time has passed** in
`Asia/Dhaka`. The database does not forbid early completion, but Part 12 §5 makes
`completed` the trigger for review eligibility, so a doctor who completes a
morning list at 08:00 opens reviews for consultations that have not happened.
Predict, do not enforce — the button is hidden, the rule stays where §0 says
rules live.

**An illegal transition must read as one.** `ILLEGAL_STATUS_TRANSITION` is
already in Part 12's DETAIL registry (§21) with the ARB key
`errIllegalStatusTransition`. The list refetches after any 409 rather than
patching its local copy, because the row changed underneath it.

### 2.7 Patient history

**Route:** `/doctor/patient/:id` (new). Reached from any row in the queue.

A doctor consulting a returning patient needs the previous visits. The scope of
"needs" is the boundary that matters here:

| Visible | Not visible |
|---|---|
| Every appointment **this patient had with this doctor** | Appointments with any other doctor |
| Date, time, type, status, symptoms, the doctor's own notes | The patient's other providers, orders, or blood records |
| Name, phone, gender, blood group | Address, email, payment methods |

The second column is not squeamishness. `users` carries `phone`, `address` and
`blood_group` for every patient (`supabase/rls_policies.sql:207` flags exactly
this), and a doctor who can query one patient's full record can query all of
them. The rule: **a doctor may read a patient only through an appointment that
links them**, and only the fields a consultation needs.

That is not expressible as a table read with an RLS policy, because the policy
would have to prove the link on every row of `users`. It is a `SECURITY DEFINER`
function, in the pattern of `doctor_contact()` (Part 02 §6.3):

```sql
-- 20260810000009_doctor_patient_history.sql
create or replace function public.doctor_patient_history(p_patient uuid)
returns table (
  appointment_id   bigint,
  appointment_date date,
  appointment_time time,
  type             text,
  status           text,
  symptoms         text,
  notes            text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doctor bigint;
begin
  select d.id into v_doctor
    from public.doctors d
   where d.user_id = (select auth.uid());

  if v_doctor is null then
    raise exception 'Only a doctor can read patient history.'
      using errcode = '42501', detail = 'NOT_A_DOCTOR';
  end if;

  -- The link IS the authorisation. No appointment, no history, and the
  -- caller cannot widen it by passing a different patient id.
  if not exists (select 1 from public.appointments a
                  where a.doctor_id = v_doctor
                    and a.patient_id = p_patient) then
    raise exception 'You have no appointment with this patient.'
      using errcode = '42501', detail = 'NOT_MY_PATIENT';
  end if;

  return query
    select a.id, a.appointment_date, a.appointment_time,
           a.type::text, a.status::text, a.symptoms, a.notes
      from public.appointments a
     where a.doctor_id = v_doctor
       and a.patient_id = p_patient
       and a.status not in ('pending_payment', 'expired')
     order by a.appointment_date desc, a.appointment_time desc;
end;
$$;

revoke all on function public.doctor_patient_history(uuid) from public, anon;
grant execute on function public.doctor_patient_history(uuid) to authenticated;
```

`pending_payment` and `expired` are excluded for the §2.5 reason: they are not
encounters. Add `NOT_A_DOCTOR` and `NOT_MY_PATIENT` to the Part 12 §21 registry
when this ships — an unmapped code falls back to raw English, which §21 accepts
only for codes no legitimate user reaches, and a mis-tapped row reaches these.

Demographics come from the existing `_patients()` helper
(`provider_repository.dart:675`), which already fetches only name, phone and
image for the appointment list. Widen it to gender and blood group **inside that
helper**, not by a second query from the screen, so there is one place that
decides what a doctor may see about a patient. Note there is no age: `users` has
no date-of-birth column (`supabase/schema.sql:282-296`), and R2 says add rather
than invent — if the doctor needs it, it is a new nullable column in a Part 01
migration, not a field the screen fabricates.

### 2.8 Reviews about me — reply, and report

**Verified before specifying: there is no reply column and no report column on
`reviews`.** The table (`supabase/schema.sql:902-921`) has `id`, `user_id`,
`reviewable_type`, `reviewable_id`, `appointment_id`, `rating`, `comment`,
`status`, `created_at`, `updated_at` and nothing else. `provider_reviews_screen.dart`
(192 lines) is therefore read-only today, and correctly so. Both features in this
section are genuinely new structure.

#### Why a provider needs a reply at all

A one-star review with no answer is the platform's final word on a doctor. The
provider's only alternatives today are to say nothing or to ask an admin to
delete it — and an admin who deletes unflattering reviews has destroyed the
directory's credibility. A public reply is the cheap, honest resolution: the
complaint stands, the answer stands beside it, and the reader decides.

#### The migration

```sql
-- =====================================================================
-- 20260810000010_review_reply_and_report.sql
--
-- Two things a reviewed provider may do about a review: answer it in
-- public, and report it to an admin in private. Neither exists today --
-- reviews has no reply and no report column (schema.sql:902).
--
-- Structure only. No INSERT statements (master plan R1).
-- =====================================================================

alter table public.reviews
  add column if not exists reply          text,
  add column if not exists reply_bn       text,
  add column if not exists replied_at     timestamptz,
  add column if not exists replied_by     uuid references public.users (id) on delete set null,
  add column if not exists reported_at    timestamptz,
  add column if not exists reported_by    uuid references public.users (id) on delete set null,
  add column if not exists report_reason  text,
  add column if not exists report_status  varchar(20);

comment on column public.reviews.reply is
  'The reviewed provider''s public answer. Written only by review_reply(); no RLS policy grants a provider UPDATE on this table.';
comment on column public.reviews.reply_bn is
  'Optional Bangla reply. Falls back to `reply` when NULL, per the Part 06 bilingual-content rule.';
comment on column public.reviews.replied_by is
  'The provider user who replied. Kept for the audit trail when a place changes owner.';
comment on column public.reviews.report_status is
  'NULL = never reported. open -> an admin must look. upheld/dismissed = an admin decided.';

alter table public.reviews
  drop constraint if exists reviews_report_status_check;
alter table public.reviews
  add constraint reviews_report_status_check
  check (report_status is null
         or report_status in ('open', 'upheld', 'dismissed'));

-- A reply is one fact in three columns; none may exist without the others.
alter table public.reviews
  drop constraint if exists reviews_reply_complete_check;
alter table public.reviews
  add constraint reviews_reply_complete_check
  check ((reply is null and replied_at is null and replied_by is null)
      or (reply is not null and replied_at is not null and replied_by is not null));

-- Same for a report. A report_reason with no report_status is a row an
-- admin queue would never surface.
alter table public.reviews
  drop constraint if exists reviews_report_complete_check;
alter table public.reviews
  add constraint reviews_report_complete_check
  check ((report_status is null and reported_at is null and reported_by is null)
      or (report_status is not null and reported_at is not null and reported_by is not null));

-- The admin moderation queue: "reports needing a decision, oldest first".
create index if not exists idx_reviews_reported_open
  on public.reviews (reported_at)
  where report_status = 'open';
```

The two completeness CHECKs are worth the four extra lines. Without them the
first bug in any writer produces a review with `replied_at` set and `reply` null,
which renders as an empty answer bubble under a one-star review — the worst
possible artefact, and one no query would flag.

#### Why the writer is an RPC and not an RLS policy

The obvious design — a `reviews_update_target_owner` policy letting a provider
update reviews about them — is wrong, and the reason generalises.

RLS is **row**-level. A policy decides *whether* a row may be updated, not
*which columns* changed. A provider granted UPDATE on a review about them could
rewrite `rating` from 1 to 5 and `comment` to anything, and both the policy and
`reviews_track_edit()` (Part 12 §16, which polices the *author's* edit window)
would allow it. The existing policy set is deliberately narrow —
`reviews_update_own_pending` and `reviews_update_admin`
(`supabase/rls_policies.sql:718`, `:723`) — and nothing else may write this table.

Two ways to narrow it exist. Column-level `GRANT UPDATE (reply, reply_bn) ON
public.reviews TO authenticated` is real and would work, but it grants the
column to *every* authenticated user and then relies on a policy to scope the
row — two mechanisms that must agree, and a future policy edit silently widens
the column grant. A `SECURITY DEFINER` function is one mechanism, matches the
precedent already set by `place_order()` (`supabase/schema.sql:2731`) and
`blood_bank_dispense()` (Part 12 §14), and puts the ownership proof in the same
place as the write.

```sql
-- Continues 20260810000010_review_reply_and_report.sql

create or replace function public.review_reply(
  p_review_id bigint,
  p_reply     text,
  p_reply_bn  text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type public.reviewable_type;
  v_id   bigint;
  v_owns boolean;
begin
  if (select auth.uid()) is null then
    raise exception 'Sign in first.'
      using errcode = '42501', detail = 'NOT_AUTHENTICATED';
  end if;

  if p_reply is null or btrim(p_reply) = '' then
    raise exception 'A reply cannot be empty.'
      using errcode = 'P0001', detail = 'REPLY_EMPTY';
  end if;

  if length(p_reply) > 1000 or coalesce(length(p_reply_bn), 0) > 1000 then
    raise exception 'A reply is limited to 1000 characters.'
      using errcode = 'P0001', detail = 'REPLY_TOO_LONG';
  end if;

  select r.reviewable_type, r.reviewable_id into v_type, v_id
    from public.reviews r where r.id = p_review_id;

  if v_type is null then
    raise exception 'Review not found.'
      using errcode = 'P0002', detail = 'REVIEW_NOT_FOUND';
  end if;

  -- Ownership from the JWT, never from a parameter -- the same rule the
  -- Dart repository follows (section 0).
  v_owns := case v_type
    when 'doctor'   then exists (select 1 from public.doctors   t where t.id = v_id and t.user_id = (select auth.uid()))
    when 'hospital' then exists (select 1 from public.hospitals t where t.id = v_id and t.user_id = (select auth.uid()))
    when 'clinic'   then exists (select 1 from public.clinics   t where t.id = v_id and t.user_id = (select auth.uid()))
    when 'pharmacy' then exists (select 1 from public.pharmacies t where t.id = v_id and t.user_id = (select auth.uid()))
  end;

  if not coalesce(v_owns, false) then
    raise exception 'That review is not about you.'
      using errcode = '42501', detail = 'REVIEW_NOT_MINE';
  end if;

  update public.reviews
     set reply       = btrim(p_reply),
         reply_bn    = nullif(btrim(coalesce(p_reply_bn, '')), ''),
         replied_at  = now(),
         replied_by  = (select auth.uid()),
         updated_at  = now()
   where id = p_review_id;
end;
$$;

revoke all on function public.review_reply(bigint, text, text) from public, anon;
grant execute on function public.review_reply(bigint, text, text) to authenticated;
```

The function is an upsert of the reply, not an insert: a provider editing a
clumsy first answer should not need a delete. `replied_at` moves each time, which
is the honest record — the reply on screen is the one written at that timestamp.

#### Reporting a review to an admin

```sql
-- Continues 20260810000010_review_reply_and_report.sql

create or replace function public.review_report(
  p_review_id bigint,
  p_reason    text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type   public.reviewable_type;
  v_id     bigint;
  v_status varchar(20);
  v_owns   boolean;
begin
  if p_reason is null or length(btrim(p_reason)) < 10 then
    raise exception 'Say what is wrong with this review, in at least 10 characters.'
      using errcode = 'P0001', detail = 'REPORT_REASON_TOO_SHORT';
  end if;

  select r.reviewable_type, r.reviewable_id, r.report_status
    into v_type, v_id, v_status
    from public.reviews r where r.id = p_review_id;

  if v_type is null then
    raise exception 'Review not found.'
      using errcode = 'P0002', detail = 'REVIEW_NOT_FOUND';
  end if;

  -- Re-reporting an open report is a no-op, not an error: the provider
  -- tapped twice, or a second staff member reported the same review.
  -- Re-reporting a DECIDED one is refused -- an admin already ruled, and
  -- reopening it by tapping again would make moderation unfalsifiable.
  if v_status = 'open' then
    return;
  end if;
  if v_status in ('upheld', 'dismissed') then
    raise exception 'An administrator has already decided this report.'
      using errcode = 'P0001', detail = 'REPORT_ALREADY_DECIDED';
  end if;

  v_owns := case v_type
    when 'doctor'   then exists (select 1 from public.doctors    t where t.id = v_id and t.user_id = (select auth.uid()))
    when 'hospital' then exists (select 1 from public.hospitals  t where t.id = v_id and t.user_id = (select auth.uid()))
    when 'clinic'   then exists (select 1 from public.clinics    t where t.id = v_id and t.user_id = (select auth.uid()))
    when 'pharmacy' then exists (select 1 from public.pharmacies t where t.id = v_id and t.user_id = (select auth.uid()))
  end;

  if not coalesce(v_owns, false) then
    raise exception 'That review is not about you.'
      using errcode = '42501', detail = 'REVIEW_NOT_MINE';
  end if;

  update public.reviews
     set report_status = 'open',
         report_reason = btrim(p_reason),
         reported_at   = now(),
         reported_by   = (select auth.uid()),
         updated_at    = now()
   where id = p_review_id;
end;
$$;

revoke all on function public.review_report(bigint, text) from public, anon;
grant execute on function public.review_report(bigint, text) to authenticated;
```

**Reporting does not hide the review.** `status` is untouched, so an approved
review stays public while an admin considers it. The alternative — auto-hiding on
report — hands every provider a one-tap censor button for any review they dislike,
and the queue would fill with reports filed for that effect alone. Part 10 owns
the admin decision: `upheld` sets `status='rejected'` and the review disappears;
`dismissed` leaves it standing and the provider is told.

New DETAIL codes for the Part 12 §21 registry, with their Part 06 ARB keys:

| DETAIL code | ARB key | Raised by |
|---|---|---|
| `REPLY_EMPTY` | `errReplyEmpty` | `review_reply()` |
| `REPLY_TOO_LONG` | `errReplyTooLong` | `review_reply()` |
| `REVIEW_NOT_MINE` | `errReviewNotMine` | both |
| `REVIEW_NOT_FOUND` | `errReviewNotFound` | both |
| `REPORT_REASON_TOO_SHORT` | `errReportReasonTooShort` | `review_report()` |
| `REPORT_ALREADY_DECIDED` | `errReportAlreadyDecided` | `review_report()` |
| `NOT_A_DOCTOR` | `errNotADoctor` | `doctor_patient_history()` |
| `NOT_MY_PATIENT` | `errNotMyPatient` | `doctor_patient_history()` |

#### Dart and screen

`reviews()` (`provider_repository.dart:505`) is frozen, and it already returns
pending, approved and rejected rows to their subject via
`reviews_select_target_owner` (`rls_policies.sql:693`). Two changes:

- widen its `select` list to include the eight new columns, which is a change to
  the query, not to the signature — permitted by R3;
- add `ProviderReview.reply`, `replyBn`, `repliedAt`, `reportStatus` to the model
  (`app/lib/models/provider_models.dart:427`).

Two new methods beside it, matching §0's rule:

```dart
Future<void> replyToReview({required int reviewId, required String reply, String? replyBn});
Future<void> reportReview({required int reviewId, required String reason});
```

`provider_reviews_screen.dart` gains, per row: the reply shown as an indented
block under the review with a "Your reply" label; an edit affordance when a reply
exists; a **Report** action hidden once `reportStatus` is non-null, replaced by a
status chip reading "Reported — an administrator is reviewing this". The screen
is shared by doctor and place (§0), so both features arrive in all four provider
roles from one edit.

### 2.9 Profile, chamber photo and fees

`doctor_profile_screen.dart` (477 lines) is a working multi-section form driven
by `updateDoctorProfile()` (`provider_repository.dart:322`), which splits a flat
map across `users` and `doctors` and silently drops admin-only columns via
`_guardedColumns` (`:89`). Keep all of it. Three additions.

**Fees.** `consultation_fee` (`schema.sql:326`) is already editable. What the
form must add is the sentence next to it, because Part 12 §13 (contradiction #15)
freezes the fee onto the appointment at booking:

> Changing your fee affects new bookings only. Appointments already booked keep
> the fee the patient agreed to.

And below it, read-only, the platform's cut — `commission_percentage`
(`:330`), which is in `_guardedColumns` and must stay there. A doctor may see
the rate; only an admin may change it (Part 04 §4.2).

**Chamber photo.** No column exists. Add one:

```sql
-- 20260810000011_doctor_chamber_photo.sql
alter table public.doctors
  add column if not exists chamber_photo varchar(255);

comment on column public.doctors.chamber_photo is
  'Object path inside the `avatars` bucket, under the owning user''s uuid prefix: avatars/<user_uuid>/chamber_<ts>.jpg. Public read, like every other patient-facing image.';
```

**Why `avatars` and not a fifth bucket.** The four buckets are fixed by
`supabase/storage_setup.sql`, and the chamber photo needs exactly what `avatars`
already provides: public read, 2 MB cap, `image/*` only, and a write policy
scoped to `<user_uuid>/` (`storage_setup.sql:41`). A new bucket would need a new
policy set that says the same thing. `provider-documents` is the wrong home for
the opposite reason — it is deliberately private (`:84`) because it holds BMDC
certificates, and a photo patients must see cannot live behind a signed URL.

Add `chamber_photo` to the doctor column list and to `_shapeDoctor()`, and reuse
the existing avatar upload path in the storage helper — one more file under a
prefix the policies already cover.

**Documents.** A rejected doctor re-uploads `bmdc_certificate` from this form
(§1.2). The field must show the rejection reason inline, not only in the banner,
because the banner is at the top of a 477-line form and the field is not.

### 2.10 Strings — EN / BN

| Key | English | বাংলা |
|---|---|---|
| `docScheduleTitle` | Chamber hours | চেম্বারের সময়সূচি |
| `docScheduleWeekly` | Weekly hours | সাপ্তাহিক সময় |
| `docScheduleLeave` | Leave and holidays | ছুটি ও বন্ধের দিন |
| `docScheduleAddWindow` | Add hours | সময় যোগ করুন |
| `docScheduleOverlap` | These hours overlap hours you already published. | এই সময়টি আপনার আগের প্রকাশিত সময়ের সঙ্গে মিলে যাচ্ছে। |
| `docScheduleLastDay` | Last day away | শেষ যেদিন অনুপস্থিত |
| `docScheduleLeaveWarn` | Marking these dates as leave stops new bookings. Appointments already booked are not cancelled — cancel each one yourself if you will not be there. | এই দিনগুলো ছুটি হিসেবে চিহ্নিত করলে নতুন বুকিং বন্ধ হবে। আগে থেকে বুক করা অ্যাপয়েন্টমেন্ট বাতিল হবে না — না থাকলে প্রতিটি নিজে বাতিল করুন। |
| `docScheduleFallback` | Your hours come from your profile. Add weekly hours here to sit at different times on different days. | আপনার সময় প্রোফাইল থেকে নেওয়া হচ্ছে। ভিন্ন দিনে ভিন্ন সময়ে বসতে এখানে সাপ্তাহিক সময় যোগ করুন। |
| `docTodayTitle` | Today's appointments | আজকের অ্যাপয়েন্টমেন্ট |
| `docTodayEmpty` | No appointments today. | আজ কোনো অ্যাপয়েন্টমেন্ট নেই। |
| `docCancelReasonRequired` | Tell the patient why. They will be refunded and notified. | রোগীকে কারণ জানান। তাঁকে টাকা ফেরত দেওয়া হবে এবং জানানো হবে। |
| `docFeeFrozenNote` | Changing your fee affects new bookings only. Appointments already booked keep the fee the patient agreed to. | ফি পরিবর্তন কেবল নতুন বুকিংয়ে প্রযোজ্য। আগে বুক করা অ্যাপয়েন্টমেন্টে রোগীর সম্মত ফি-ই থাকবে। |
| `docCommissionNote` | The platform keeps {percent}% of each paid consultation. | প্রতিটি পরিশোধিত পরামর্শের {percent}% প্ল্যাটফর্ম রাখে। |
| `docPatientHistory` | Visit history with you | আপনার সঙ্গে সাক্ষাতের ইতিহাস |
| `reviewReplyLabel` | Your reply | আপনার উত্তর |
| `reviewReplyHint` | Answer publicly. Patients will see this under the review. | প্রকাশ্যে উত্তর দিন। রোগীরা রিভিউয়ের নিচে এটি দেখবেন। |
| `reviewReportAction` | Report to admin | প্রশাসককে জানান |
| `reviewReportReasonHint` | Say what is wrong with this review. | এই রিভিউয়ে কী সমস্যা তা লিখুন। |
| `reviewReportedChip` | Reported — an administrator is reviewing this | রিপোর্ট করা হয়েছে — প্রশাসক দেখছেন |
| `errReviewNotMine` | That review is not about you. | এই রিভিউটি আপনার সম্পর্কে নয়। |
| `errReportAlreadyDecided` | An administrator has already decided this report. | প্রশাসক ইতিমধ্যে এই রিপোর্টের সিদ্ধান্ত দিয়েছেন। |
| `errNotMyPatient` | You have no appointment with this patient. | এই রোগীর সঙ্গে আপনার কোনো অ্যাপয়েন্টমেন্ট নেই। |

### 2.11 Acceptance test

Two accounts: an approved doctor, and a patient.

1. **Chamber separate from employment.** Link the doctor to a hospital (§3.2).
   Confirm the patient's booking flow still books the *chamber* — one
   `appointments` row with `doctor_id` = the doctor, and no row anywhere naming
   the hospital.
2. **Publish hours.** Add Saturday 09:00–13:00, 30-minute slots. Confirm
   `available_slots()` for the next Saturday returns 8 times.
3. **Overlap refused.** Add Saturday 12:00–15:00. Expect the localized overlap
   message, not `23P01` or a constraint name.
4. **Split a window.** Replace Saturday with 09:00–11:00 and 12:00–14:00. Expect
   success, and the old row present with `is_active = false`.
5. **Leave.** Black out next Saturday. Confirm `available_slots()` returns zero
   rows for that date and the previous bookings are untouched.
6. **Hold invisibility.** As the patient, start a booking and stop at the payment
   sheet. Confirm the doctor's queue does **not** show it, and
   `available_slots()` no longer offers that time to a second patient.
7. **Hold expiry.** Wait out `hold_expires_at` (or run `expire_payment_holds()`).
   Confirm the slot is offered again and the doctor's queue never changed.
8. **Full payment takes the slot.** Pay. Confirm the appointment appears in the
   doctor's Today list, and the slot is gone from `available_slots()`.
9. **All slots gone.** Book every slot for one date. Confirm the patient sees the
   "no slots available" empty state, not an empty list with no explanation.
10. **Queue transitions.** Confirm → Complete. Then attempt
    `completed → confirmed` by REST. Expect `ILLEGAL_STATUS_TRANSITION`.
11. **Patient history.** Open the patient from the queue: the past visit is
    listed. Call `doctor_patient_history()` with a patient id you have no
    appointment with. Expect `NOT_MY_PATIENT`.
12. **Reply.** As the patient, review the completed appointment. As the doctor,
    reply. Confirm the reply is visible to the patient and to a signed-out
    visitor once the review is approved.
13. **Reply is column-scoped.** As the doctor, `PATCH /rest/v1/reviews?id=eq.N`
    with `{"rating":5}`. Expect a policy refusal — no provider UPDATE policy
    exists on `reviews`.
14. **Report.** Report the review with a 5-character reason. Expect
    `REPORT_REASON_TOO_SHORT`. Report with a real reason. Confirm the review is
    **still publicly visible** and `report_status = 'open'`.
15. **Both languages.** Repeat 2, 5 and 12 in `bn`. No English string, no
    overflow, Bangla numerals in times and dates.

---

## 3. Hospital and clinic

Hospitals and clinics share one workspace, one repository path and one set of
screens. `_requirePlace()` (`provider_repository.dart:570`) resolves which of the
three place tables the caller owns, so nothing below branches on `users.role`.
Where a rule differs between hospital and clinic it is called out; otherwise
"place" means either.

Pharmacy is the third place role and is §4. It shares `placeDashboard()` and the
profile form with this section but nothing else, because it sells products rather
than services.

### 3.1 Verification with registration documents

The columns exist. `hospitals` carries `registration_number`, `license_number`
and `license_document` (`supabase/schema.sql:384-386`); `clinics` carries the same
three (`:441-443`). `license_document` is an object path in the **private**
`provider-documents` bucket (`storage_setup.sql:27-29`, `:84`), and it must stay
private — a hospital registration certificate carries the owner's identity
details.

What Part 09 adds is a documents section in `place_profile_screen.dart` (583
lines) with, per document, the four states R5 requires and one more the generic
widget does not cover: *uploaded but not yet reviewed*. A provider who cannot
tell "we never received it" from "we have it and are looking" will upload it
again, and again.

| Document | Column | Required to verify |
|---|---|---|
| Registration certificate | `registration_number` + `license_document` | yes |
| Trade or operating licence | `license_number` | yes |
| Drug licence | pharmacy only, §4.1 | pharmacy only |

Uploads go through the same storage helper the avatar path uses, with the
`<user_uuid>/` prefix the bucket policies expect. The file is never rendered
inline — a private bucket needs a signed URL, so the UI shows the file name, the
upload time and a "Replace" action. Displaying a document thumbnail here would
require making the bucket public, which is the one thing §3.1 forbids.

### 3.2 Adding doctors — the two kinds, and the invite that connects them

A hospital adding a doctor is two different operations wearing one button.

**Case A — the doctor already has an account.** Dr Karim is registered, verified,
runs his own chamber, and also does ward rounds at this hospital. The hospital
must not create a second record of him: two profiles means two ratings, two
review streams, and a patient choosing between two versions of the same person.
The hospital **links** to his existing account, and because a link asserts
something about him in public, **he must consent**.

**Case B — the doctor has no account.** A junior registrar who will never use the
app. The hospital needs him listed on their profile page with a photo and a
specialisation. This is a **description record**: no login, no bookings, no
reviews, no payouts. It is content on the hospital's page, and the model must
make it impossible to mistake for a bookable doctor.

One table serves both, with the same XOR shape `provider_payouts` and
`hospital_services` already use.

```sql
-- =====================================================================
-- 20260810000012_hospital_doctors.sql
--
-- The employment link between a place (hospital or clinic) and a
-- doctor. Two shapes in one table:
--   doctor_id set    -> a linked, consenting, real doctor account
--   doctor_id null   -> a description-only listing with no login
-- Exactly one of hospital_id / clinic_id is set, as in
-- hospital_services (Part 01 section 6.3).
--
-- Structure only. No INSERT statements (master plan R1).
-- =====================================================================

create table if not exists public.hospital_doctors (
  id             bigint generated always as identity primary key,
  hospital_id    bigint references public.hospitals (id) on delete cascade,
  clinic_id      bigint references public.clinics   (id) on delete cascade,

  -- NULL for a description-only listing. Set once a real doctor accepts.
  doctor_id      bigint references public.doctors (id) on delete set null,

  -- Used for both shapes: for a linked doctor these are the place's own
  -- labels (department, room, visiting hours), and the doctor's name,
  -- rating and fee are read from `doctors` and never copied here.
  display_name    varchar(150) not null,
  display_name_bn varchar(150),
  designation     varchar(150),
  designation_bn  varchar(150),
  specialization  varchar(100),
  photo           varchar(255),
  description     text,
  description_bn  text,
  visiting_hours  varchar(255),
  visiting_hours_bn varchar(255),

  -- pending -> the doctor has been invited and has not answered
  -- accepted -> the doctor consented; the link is public
  -- declined -> the doctor refused; kept as a record, never shown
  -- listing -> a description-only row, which needs no consent
  link_status    varchar(20) not null default 'listing',
  invited_at     timestamptz,
  responded_at   timestamptz,
  sort_order     integer not null default 0,
  status         active_status not null default 'active',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),

  constraint hospital_doctors_owner_check check (
    (hospital_id is not null and clinic_id is null)
    or (hospital_id is null and clinic_id is not null)),

  constraint hospital_doctors_link_status_check
    check (link_status in ('pending', 'accepted', 'declined', 'listing')),

  -- The two shapes cannot be confused: a row with no doctor_id is a
  -- 'listing' and nothing else; a row with a doctor_id is never a
  -- 'listing'. Without this, a half-finished invite would render as an
  -- unconsented public claim that a named doctor works here.
  constraint hospital_doctors_shape_check check (
    (doctor_id is null     and link_status = 'listing')
    or (doctor_id is not null and link_status in ('pending', 'accepted', 'declined'))),

  -- An invite has a sent time; an answer has an answered time.
  constraint hospital_doctors_invite_time_check check (
    (link_status = 'listing' and invited_at is null)
    or (link_status <> 'listing' and invited_at is not null)),
  constraint hospital_doctors_response_time_check check (
    (link_status in ('accepted', 'declined')) = (responded_at is not null))
);
```

```sql
-- Continues 20260810000012_hospital_doctors.sql

comment on table public.hospital_doctors is
  'Employment/affiliation between a hospital or clinic and a doctor. doctor_id NULL = a description-only listing with no login. See spec/09_PROVIDER_FEATURES.md section 3.2.';
comment on column public.hospital_doctors.display_name is
  'The place''s own label. For a linked doctor the authoritative name is doctors -> users.name; this is what the place chose to print, e.g. "Prof. Dr. A. Karim".';
comment on column public.hospital_doctors.photo is
  'Object path inside the `avatars` bucket under the place owner''s uuid prefix. A linked doctor''s own avatar wins where both exist.';
comment on column public.hospital_doctors.link_status is
  'listing = no account. pending/accepted/declined = a real doctor was invited. Only accepted rows are shown publicly.';

-- One place cannot invite the same doctor twice. Partial, so a declined
-- invite can be re-sent later after a conversation offline.
create unique index if not exists uq_hospital_doctors_hospital_doctor
  on public.hospital_doctors (hospital_id, doctor_id)
  where doctor_id is not null and link_status in ('pending', 'accepted');

create unique index if not exists uq_hospital_doctors_clinic_doctor
  on public.hospital_doctors (clinic_id, doctor_id)
  where doctor_id is not null and link_status in ('pending', 'accepted');

-- Query: the place's roster editor -- everything, in display order.
create index if not exists idx_hospital_doctors_hospital
  on public.hospital_doctors (hospital_id, sort_order, id)
  where hospital_id is not null;

create index if not exists idx_hospital_doctors_clinic
  on public.hospital_doctors (clinic_id, sort_order, id)
  where clinic_id is not null;

-- Query: the doctor's own "invitations waiting for me" badge.
create index if not exists idx_hospital_doctors_pending_for_doctor
  on public.hospital_doctors (doctor_id)
  where link_status = 'pending';
```

**Why `on delete set null` on `doctor_id` and not `cascade`.** A doctor deleting
their account should not silently erase a row the hospital is responsible for.
Setting it null would however violate `hospital_doctors_shape_check`, since the
row's `link_status` is `accepted` — which is exactly the right outcome: the
delete fails loudly rather than leaving a public claim about a person who no
longer exists. Part 12 §17 (contradiction #19) already establishes that a user
with live commitments is soft-deleted, not removed, so in practice the doctor row
survives and the affiliation stays truthful. If the hard-delete path is ever
exercised, the constraint is the alarm.

#### The invite flow, and both ways it can fail to complete

```
place searches by BMDC number or email
   │
   ├─ no match ──────────────→ "Add as a listing"  → link_status 'listing'
   │                                                  doctor_id NULL, public at once
   │
   └─ match ────────────────→ "Invite Dr X"        → link_status 'pending'
                                                      invited_at = now()
                                                      NOT public
                                │
                                ├─ doctor accepts  → 'accepted', responded_at
                                │                     public on the place's page
                                ├─ doctor declines → 'declined', responded_at
                                │                     never shown; place is told
                                └─ no answer ─────→ stays 'pending' forever
                                                      never shown; see below
```

**Search is by BMDC number or exact email, never by name.** A name search over
`doctors` joined to `users` is a directory dump: type "a" and receive every
doctor's identity. Part 02 §6.3 built `doctor_contact()` and rate limiting for
precisely this attack surface. An invite needs an identifier the inviter already
possesses, which both a BMDC number and an email are. The search returns one row
or none, and it returns only name, specialisation and city — never phone, never
address.

**If the doctor declines**, the row becomes `declined` and is never rendered
publicly, in the roster editor it shows as "Declined" with the date, and the
place may not re-invite from the UI. The partial unique indexes exclude
`declined`, so a re-invite is *possible* at the database level — that is
deliberate, for the real case where the place phones the doctor and sorts it out.
It requires a new invite action, which is a deliberate act, not a retry loop. A
place that could re-invite freely would turn a decline into a notification
weapon.

**If the doctor never answers**, the row stays `pending` and nothing happens.
There is no auto-accept and no expiry, and both absences are decisions:

- *No auto-accept*, because silence is not consent, and the whole reason this is
  an invite rather than a link is that the claim is public.
- *No expiry job*, because a `pending` row is harmless — it is invisible to
  patients, it blocks nothing, and it costs one row. An expiry job would be a
  second `pg_cron` entry (Part 12 §4 owns the only one) whose sole effect is to
  delete evidence that an invite was sent.

The roster editor shows pending invites with their age — "Invited 12 days ago,
no answer" — and offers **Cancel invite**, which deletes the row. That is the
place's remedy, and it is manual because the decision is theirs.

<!--CONT-->

