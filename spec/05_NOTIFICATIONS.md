# Part 05 — Notifications

**Phase 8.** Decision D3 governs this entire part:

> **In-app notifications + local scheduled reminders only. No Firebase, no FCM,
> no push.** Adding `firebase_messaging` means a Firebase project, a
> `google-services.json`, an APNs key, and a second vendor — none of which
> exists, and none of which the user asked for.

Prerequisites: Parts 01, 12, 02, 03, 06 done. This part comes after
localization because every notification string is bilingual on its first write,
and §6 makes that a schema decision rather than a display decision.

Do not add a package outside §5's list. Do not add `firebase_core`. If a later
requirement genuinely needs push, it is a separate part with its own decision
record.

---

## 1. Why notifications are written by triggers, not by the app

### 1.1 The structural reason

Nearly every notification in this system tells a **different user** than the one
who caused it:

| Actor | Notified |
|---|---|
| Patient books | patient (receipt) **and** doctor (new booking) |
| Doctor confirms | patient |
| Admin verifies a payment | patient |
| Admin verifies a provider | provider |
| Patient leaves a review | provider |
| Provider replies to a review | patient |
| Blood requester posts | every matching donor |

Now consider what RLS can express for a client-side insert:

- **`with check (user_id = (select auth.uid()))`** — a user may only insert
  notifications addressed to themselves. Correct, and useless: the doctor
  cannot be told about a booking, because it is the *patient's* session doing
  the writing.
- **`with check (true)`** — anyone may insert a notification addressed to
  anyone. Now any user with the anon key can forge "Your payment was rejected"
  or "Your account has been suspended — click here" into any other user's
  notification centre. The anon key ships in the binary; assume it is public.

There is no third policy that permits the legitimate case and forbids the
forgery, because from the database's point of view the two writes are
identical. The difference is not *who* is writing or *what* they are writing —
it is *whether the event actually happened*. A row-level policy cannot see that.

So the write must happen where the event is visible: inside the transaction
that performed it.

### 1.2 What is already built

This is done, and correctly. `public.notify()` (`supabase/schema.sql:1553`):

```sql
create or replace function public.notify(
  p_user_id uuid, p_title text, p_body text,
  p_type text, p_route text, p_ref_id bigint
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_user_id is null then
    return;   -- older provider rows may have no owning user
  end if;
  insert into public.notifications (user_id, title, body, type, route, ref_id)
  values (p_user_id, p_title, p_body, p_type, p_route, p_ref_id);
end;
$$;

revoke all on function public.notify(uuid, text, text, text, text, bigint)
  from public, anon, authenticated;
```

`security definer` lets it insert past RLS. The `revoke` means no client can
call it — not `anon`, not `authenticated`, not even to send itself a
notification. It is reachable **only** from a trigger running in the same
transaction as the event.

And the policies, `supabase/rls_policies.sql:836-856`:

```
-- No INSERT policy on notifications for anyone. Rows arrive only through
-- the SECURITY DEFINER triggers in schema.sql PART 3.4.
```

`notifications_select_own` (:844), `notifications_update_own` (:849, for
marking read), `notifications_delete_own` (:854). No insert policy exists, so
inserts are refused by default — RLS denies what no policy permits.

`ContentRepository`'s doc comment (`app/lib/features/content/data/content_repository.dart:10`)
records the same fact from the client side: "UPDATE on `notifications` and
nothing more — no INSERT grant, no insert path."

### 1.3 The rule for this part

**Never add an INSERT policy on `notifications`. Never grant EXECUTE on
`notify()`.** Every new notification in §2 is a new trigger or a new branch in
an existing one, and it calls `notify()` from inside `security definer` code.

If you find yourself wanting to insert a notification from Dart, the event you
are reacting to is not represented in the database — fix that instead.

Cross-reference: Part 01 §3.4 defines the notifier triggers; Part 12 §4 covers
the trusted-path marker that lets these writes coexist with the column guards.

---

## 2. The event catalogue

### 2.1 What exists today

Five notifier functions and eight triggers (`supabase/schema.sql:3143-3171`):

| Function | Line | Trigger | Fires on |
|---|---|---|---|
| `appointments_notify()` | :1591 | `appointments_notify_trg` | `after insert or update of status on appointments` |
| `payments_notify()` | :1684 | `payments_notify_trg` | `after insert or update of payment_status on payments` |
| `orders_notify()` | :1897 | `orders_notify_trg` | `after insert on orders` |
| `feedback_notify()` | :1914 | `feedback_notify_trg` | `after update of admin_response on feedback` |
| `providers_notify()` | :1856 | `doctors_` / `hospitals_` / `clinics_` / `pharmacies_notify_trg` | `after update of verification_status, status` |

Trigger name order is load-bearing: `payments_apply_verification_trg` (a)
precedes `payments_notify_trg` (n) so the notifier sees the settled state
(`schema.sql:3138-3140`). Do not rename either.

### 2.2 Complete catalogue

`type` is constrained by convention to `appointment|payment|order|blood|general`
(`schema.sql:1041`) plus `system`, which `providers_notify` and
`feedback_notify` already use. Reality has six values; the comment lists five.
Update the comment, do not narrow the code.

| # | Event | Trigger source | Recipient | `type` | Title EN / BN | Body EN / BN | `route` | `ref_id` | Status |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Appointment requested | `appointments` INSERT | patient | `appointment` | Appointment requested / অ্যাপয়েন্টমেন্টের অনুরোধ | Your request for {date} at {time} has been received. / {date} তারিখে {time}-এ আপনার অনুরোধ গৃহীত হয়েছে। | `/appointments` | appointment id | **exists** |
| 2 | New booking for the doctor | `appointments` INSERT | doctor's user | `appointment` | New booking / নতুন বুকিং | {patient} booked {date} at {time}. / {patient} {date} {time}-এ বুক করেছেন। | `/provider/appointments` | appointment id | **new** |
| 3 | Appointment confirmed | `appointments` UPDATE status | patient | `appointment` | Appointment confirmed / অ্যাপয়েন্টমেন্ট নিশ্চিত | Confirmed by the doctor. / ডাক্তার নিশ্চিত করেছেন। | `/appointments` | id | **exists** |
| 4 | Appointment completed | UPDATE status | patient | `appointment` | Appointment completed / সম্পন্ন | You can now leave a review. / আপনি এখন রিভিউ দিতে পারেন। | `/appointments` | id | **exists** |
| 5 | Appointment cancelled | UPDATE status | patient **and** doctor | `appointment` | Appointment cancelled / বাতিল | Your appointment on {date} has been cancelled. / {date}-এর অ্যাপয়েন্টমেন্ট বাতিল হয়েছে। | `/appointments` | id | patient **exists**, doctor **new** |
| 6 | Appointment expired | UPDATE status | patient | `appointment` | Appointment expired / মেয়াদোত্তীর্ণ | Your slot on {date} expired. Book again. / {date}-এর স্লটের মেয়াদ শেষ। আবার বুক করুন। | `/appointments` | id | **exists** |
| 7 | Reminder, 24 h before | **local**, §5 | patient | `appointment` | Appointment tomorrow / আগামীকাল অ্যাপয়েন্টমেন্ট | {doctor} at {time}. / {doctor}, {time}। | `/appointments` | id | **new** |
| 8 | Reminder, 2 h before | **local**, §5 | patient | `appointment` | Appointment in 2 hours / ২ ঘণ্টা পরে | {doctor} at {time}. / {doctor}, {time}। | `/appointments` | id | **new** |
| 9 | Payment submitted | `payments` INSERT | patient | `payment` | Payment submitted / পেমেন্ট জমা | Awaiting verification. / যাচাইয়ের অপেক্ষায়। | `/appointments` | appointment id | **exists** |
| 10 | Payment awaiting verification | `payments` INSERT | admins | `payment` | Payment to verify / যাচাই করার পেমেন্ট | ৳{amount} from {patient} via {method}. / {patient}-এর ৳{amount}, {method}। | `/admin/payments` | payment id | **new** |
| 11 | Payment verified | UPDATE payment_status | patient | `payment` | Payment verified / পেমেন্ট যাচাই হয়েছে | Marked paid. Confirmation code follows when the provider confirms. / পরিশোধিত। প্রদানকারী নিশ্চিত করলে কোড পাঠানো হবে। | `/appointments` | appointment id | **exists** |
| 12 | Payment rejected | UPDATE payment_status | patient | `payment` | Payment rejected / পেমেন্ট বাতিল | Reason: {reason} / কারণ: {reason} | `/appointments` | appointment id | **exists** |
| 13 | Payment received | UPDATE → verified | provider's user | `payment` | Payment received / পেমেন্ট পেয়েছেন | ৳{provider_share} for {date}. / {date}-এর জন্য ৳{provider_share}। | `/provider/earnings` | payment id | **new** |
| 14 | Payout settled | `provider_payouts` UPDATE → paid | provider's user | `payment` | Payout sent / পেআউট পাঠানো হয়েছে | ৳{amount} has been settled. / ৳{amount} নিষ্পত্তি হয়েছে। | `/provider/earnings` | payout id | **new** |
| 15 | Provider verified | `doctors`/`hospitals`/`clinics`/`pharmacies` UPDATE | provider | `system` | Account verified / অ্যাকাউন্ট যাচাই হয়েছে | Listed publicly now. / এখন প্রকাশ্যে তালিকাভুক্ত। | `/dashboard` | provider id | **exists** |
| 16 | Provider rejected | same | provider | `system` | Verification rejected / যাচাই বাতিল | Reason: {reason} / কারণ: {reason} | `/dashboard` | provider id | **exists** |
| 17 | Account activated / deactivated | same | provider | `system` | Account activated / deactivated | — | `/dashboard` | provider id | **exists** |
| 18 | New review | `reviews` INSERT | reviewed provider's user | `general` | New review / নতুন রিভিউ | {stars}★ from {patient}. / {patient}-এর {stars}★। | `/provider/reviews` | review id | **new** |
| 19 | Review reply | `reviews` UPDATE reply | review author | `general` | Reply to your review / আপনার রিভিউর জবাব | {provider} replied. / {provider} জবাব দিয়েছেন। | `/reviews` | review id | **new** |
| 20 | Blood request matching group | `blood_requests` INSERT | donors, matching group, `is_available` | `blood` | {group} blood needed / {group} রক্ত প্রয়োজন | At {hospital}, {city}. / {hospital}, {city}। | `/blood/requests` | request id | **new** |
| 21 | Order placed | `orders` INSERT | patient | `order` | Order placed / অর্ডার হয়েছে | Order {number} received. / অর্ডার {number} গৃহীত। | `/pharmacy/orders` | order id | **exists** |
| 22 | New order for the pharmacy | `orders` INSERT | pharmacy's user | `order` | New order / নতুন অর্ডার | Order {number}, ৳{total}. / অর্ডার {number}, ৳{total}। | `/provider/orders` | order id | **new** |
| 23 | Order status changed | `orders` UPDATE status | patient | `order` | Order {status} / অর্ডার {status} | Order {number} is now {status}. / অর্ডার {number} এখন {status}। | `/pharmacy/orders` | order id | **new** |
| 24 | Feedback answered | `feedback` UPDATE | user | `system` | Response to your feedback / আপনার মতামতের জবাব | {admin_response} | `/feedback` | feedback id | **exists** |
| 25 | Admin broadcast | `broadcast_notification()` RPC | all, or one role | `general` | admin-supplied | admin-supplied | admin-supplied | null | **new** |

Nine exist. Sixteen are new. Every new one is a trigger or a branch, never a
client insert.

### 2.3 Two representative new triggers

Blood requests fan out to many recipients — the only one-to-many notifier here,
so it is the one worth writing out:

```sql
-- Notifies every available donor whose blood group matches. One statement,
-- one insert per donor; no loop, because a loop over 400 donors inside a
-- trigger is 400 round trips through the executor.
create or replace function public.blood_requests_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.notifications (user_id, title, body, type, route, ref_id)
  select d.user_id,
         'blood.request.title',
         jsonb_build_object(
           'group',    new.blood_group,
           'hospital', coalesce(new.hospital_name, ''),
           'city',     coalesce(new.city, ''))::text,
         'blood', '/blood/requests', new.id
    from public.blood_donors d
   where d.blood_group = new.blood_group
     and d.is_available
     and d.user_id is not null
     and d.user_id <> new.user_id;   -- never notify the requester
  return null;
end;
$$;

drop trigger if exists blood_requests_notify_trg on public.blood_requests;
create trigger blood_requests_notify_trg
  after insert on public.blood_requests
  for each row execute function public.blood_requests_notify();
```

Note it inserts directly rather than calling `notify()` in a loop. That is
allowed: the function is `security definer` and owned by the same role, so the
security property is identical, and one set-returning insert is the right shape
for a fan-out. `notify()` stays the single-recipient path.

Also note the title is a **key**, not a sentence, and the body is **JSON**. That
is §6, and it applies to every new notification.

The admin broadcast is the one notification a human composes, so it needs an
RPC rather than a trigger:

```sql
create or replace function public.broadcast_notification(
  p_title text, p_body text, p_role text default null, p_route text default null
) returns integer
language plpgsql security definer set search_path = ''
as $$
declare v_count integer;
begin
  if not public.is_admin() then
    raise exception 'admins only' using errcode = '42501';
  end if;
  if btrim(coalesce(p_title, '')) = '' then
    raise exception 'a broadcast needs a title' using errcode = '22023';
  end if;

  insert into public.notifications (user_id, title, body, type, route, ref_id)
  select u.id, p_title, p_body, 'general', p_route, null
    from public.users u
   where u.is_active
     and (p_role is null or u.role::text = p_role);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.broadcast_notification(text, text, text, text)
  from public, anon;
grant execute on function public.broadcast_notification(text, text, text, text)
  to authenticated;
```

The `is_admin()` check is inside the function, not expressed as a grant,
because `authenticated` must be able to *call* it for the check to run. A
non-admin gets `42501`. This is the **only** function in the system that writes
a notification on a human's instruction, and it is the only one that needs a
confirmation dialog stating the recipient count before it fires.

Broadcast bodies are literal sentences, not keys — an admin types them. So
§6's rendering must tolerate both: a `title` that resolves to a known key gets
translated, and one that does not is shown verbatim. That fallback is specified
in §6.3.

---

## 3. The notification centre

`app/lib/features/content/presentation/notifications_screen.dart`, 328 lines,
route `/notifications` (`app/lib/app/router.dart:135`), also mounted as a
patient shell tab (`:466`) and at the root (`:593`).

### 3.1 A bug to fix first

`ContentRepository.notifications()` selects `route`
(`content_repository.dart:60`):

```dart
          .select('id, type, title, body, route, ref_id, is_read, created_at')
```

but `AppNotification.fromJson` (`app/lib/models/content_models.dart:41-48`)
**never reads it**. There is no `route` field on the model. The column is
fetched over the wire on every page and thrown away.

The consequence is `isActionable` (`:53`):

```dart
  bool get isActionable => referenceId != null && type != null;
```

Tap targeting is therefore reconstructed from `type` + `ref_id` in the screen,
which is why the doc comment says "Anything else renders with a neutral icon and
stays un-tappable rather than guessing a destination". The server already told
the client exactly where to go — `/appointments`, `/admin/payments`,
`/provider/earnings` — and the client is guessing instead.

Fix:

```dart
  /// `notifications.route` — the in-app destination the server chose for this
  /// notification. Authoritative: the trigger that created the row knows what
  /// it refers to, and a client reconstructing the route from `type` will get
  /// provider-facing notifications wrong.
  final String? route;

  /// True when a tap can go somewhere. A server-supplied route is sufficient
  /// on its own; `type` + `ref_id` remains a fallback for legacy rows written
  /// before `route` was populated.
  bool get isActionable =>
      (route != null && route!.isNotEmpty) || (referenceId != null && type != null);
```

Adding a field is a widening, permitted under D1. No signature changes, so R3
holds.

### 3.2 Tap routing

Ordered. Stop at the first that applies.

1. **`route` is set and matches a known `Routes` constant** → navigate there.
   If `ref_id` is also set and the route takes a parameter, append it:
   `/appointments` + `42` → the appointment detail path.
2. **`route` is set but unknown** → go to the route's *prefix* if that is
   known, else fall to 3. Never `push` an arbitrary server string into
   `go_router` — a malformed or hostile `route` value would otherwise be a
   navigation injection. Validate against the `Routes` allowlist.
3. **`type` + `ref_id`** → the legacy mapping already in the screen.
4. **Neither** → not tappable. Neutral icon, no ripple.

Marking read happens on tap **and** on the explicit action, in that order:
mark read, then navigate. If the mark fails the navigation still happens —
failing to open a notification because a bookkeeping write failed is the wrong
trade.

### 3.3 Grouping by day

Replace the flat list with sticky day headers: **Today / আজ**, **Yesterday /
গতকাল**, then `EEEE, d MMMM` for the last week, then `d MMMM yyyy`. Computed in
Asia/Dhaka (§5.2) — a notification at 01:00 Dhaka time is "Today" for a Dhaka
user regardless of what UTC says.

Grouping is done on the **client**, over the page already fetched. A grouped
server query would need a second round trip per page and would break as soon as
a group spans a page boundary. The header for a group that continues onto the
next page simply repeats; that is correct and invisible.

### 3.4 The rest of the screen

| Element | Behaviour |
|---|---|
| Unread styling | Left accent bar in the primary colour, `FontWeight.w600` title, tinted surface. **Not** a red dot — this list can be long and a wall of red dots reads as errors |
| Mark one read | On tap, plus swipe-to-read. Returns the server's fresh count (`markRead` already does this, `content_repository.dart:87`) |
| Mark all read | AppBar action, enabled only when `unreadCount > 0`, confirmation only if over 20 |
| Delete | Swipe the other way. `notifications_delete_own` already permits it (`rls_policies.sql:854`) |
| Unread-only filter | `unreadOnlyProvider` exists (`notifications_screen.dart:36`). Keep it; surface it as a two-chip segmented control |
| Pagination | `PagedController` already used. Keep |
| Pull to refresh | `RefreshIndicator` → `refresh()` on the controller, and re-read the count |
| Loading | Six shimmer rows, not a centred spinner — a spinner on a list that is usually populated reads as a hang |
| Empty | Bell illustration, "No notifications yet" / "এখনো কোনো নোটিফিকেশন নেই". Unread-only + empty says "Nothing unread" instead, with a "Show all" action — otherwise a filtered-empty list looks like data loss |
| Error | `ApiException.message` + Retry. No raw text |

### 3.5 The count is the server's, always

`notifications_screen.dart:5-8` already states the rule and
`ContentRepository._unreadCount` (`:147`) implements it: the badge is a separate
unfiltered `count` query, never the length of the loaded page. `markRead` and
`markAllRead` both return a freshly computed count for the same reason
(`:103`, `:120`).

Keep this. Decrementing a local counter on tap drifts the moment a trigger
inserts a row between the fetch and the tap, and a badge that says 3 over an
empty list is the kind of bug users report for months.

---

## 4. A live unread badge without Realtime

### 4.1 Why polling

There is no Realtime subscription anywhere in this codebase — `grep -rn
'\.channel(' app/lib` returns nothing. That is deliberate (master plan §2): a
websocket held open by a mobile app on a Bangladeshi mobile network drains
battery, reconnects constantly, and on the Supabase free tier competes for a
shared connection limit against every other feature.

Polling a single indexed `count` is cheap. `idx_notifications_unread`
(`schema.sql:1048-1050`) is a partial index on `(user_id, created_at desc)
where not is_read` — the count query never touches a read row.

If Realtime is added later, it replaces the poll behind the same provider and
nothing else changes. Design for that, do not build it.

### 4.2 The schedule

```dart
/// Polls the unread count. One timer for the whole app.
///
/// The intervals are a compromise between "the badge feels live" and "we are
/// not billing a query every second for a user staring at a static screen".
/// A notification arriving while the app is open is not urgent — the user is
/// already here.
class UnreadPoller {
  static const _foreground = Duration(seconds: 45);
  static const _backoffMax = Duration(minutes: 5);
  ...
}
```

| Condition | Interval |
|---|---|
| App foregrounded, screen visible | 45 s |
| Immediately after any navigation | once, at once (debounced to 3 s) |
| After a pull-to-refresh | once, at once |
| After `markRead` / `markAllRead` | not polled — those return a fresh count |
| App backgrounded | **stopped**, timer cancelled |
| Returning to foreground | once, at once, then resume the 45 s cycle |
| After a failed poll | double the interval: 45 s → 90 s → 3 min → 5 min (capped) |
| After a successful poll following failures | reset to 45 s |

Backoff on failure matters more than it looks. Without it, a user on a dead
connection generates a failed request every 45 seconds for as long as the app is
open, and every one of them logs an error.

Stopping when backgrounded is not an optimisation, it is correctness: a timer
firing in the background on Android wakes the process, and on iOS it simply
does not fire — so code that assumes it did will show a stale badge forever.
Observe `AppLifecycleState` and re-poll on `resumed`.

### 4.3 Where it lives

```dart
/// The unread count, polled. Single source for every badge in the app.
///
/// autoDispose is deliberately NOT used: the count is needed by the shell for
/// the whole session, and disposing it on a screen change would restart the
/// poll cycle on every navigation.
final unreadCountPollerProvider =
    NotifierProvider<UnreadPoller, int>(UnreadPoller.new);
```

`unreadCountProvider` already exists as a `StateProvider<int>`
(`notifications_screen.dart:40`) and is written by every list fetch and every
mark-read call. Keep it as the source of truth and have the poller write into
it, rather than introducing a second count that can disagree with the first.
Two counters is how a badge starts lying.

Start the poller once, in the root widget, after the session is known. Not in
`main()` — there is no user yet. Not in a screen — it must outlive any screen.

### 4.4 Where the badge sits

`app/lib/features/home/presentation/patient_shell.dart:48` builds the
`NavigationBar`; `:53` builds each `NavigationDestination` from a `_Tab` record.

Wrap the icon:

```dart
            NavigationDestination(
              icon: t.showsBadge
                  ? Badge.count(count: unread, isLabelVisible: unread > 0,
                                child: Icon(t.icon))
                  : Icon(t.icon),
              ...
            ),
```

Add `showsBadge` to `_Tab` (`patient_shell.dart:64`) rather than special-casing
an index — an index-based check breaks silently the first time the tab order
changes.

| Surface | Badge |
|---|---|
| Patient shell, notifications tab | `Badge.count`, hidden at zero |
| Provider dashboard app bar bell | Same |
| Admin shell | Same |
| Any screen's app bar | No. One badge per shell. A count repeated in two places on one screen is noise |

`Badge.count` caps its own display at 99+, which is the right behaviour and one
less thing to write.

### 4.5 What the badge counts

Unread rows for the signed-in user. Not "notifications since last visit", not
"important ones only". If §8's per-category toggles are off for a category,
those rows are **not created at all** (§8.2), so the count needs no filtering —
another reason to suppress at write time rather than at read time.

---

## 5. Local scheduled reminders

Events 7 and 8 in §2.2. These are the only notifications that reach a user who
is not looking at the app, and the only ones this part schedules on the device.

### 5.1 Dependencies to add

Neither package is in `app/pubspec.yaml` today — check before assuming
(the file's only relevant note is `:48-49`, which excludes Firebase by design):

```yaml
  # Local scheduled reminders only — no push, no Firebase (decision D3).
  # The plugin schedules on the OS alarm/notification manager; nothing
  # network-facing is added by this.
  flutter_local_notifications: ^17.2.2

  # Required by flutter_local_notifications for zonedSchedule(). Supplies the
  # IANA database, so Asia/Dhaka resolves without a platform call.
  timezone: ^0.9.4
```

Pinned minors, not `any`. No other package. If a task seems to need
`permission_handler`, it does not — `flutter_local_notifications` requests its
own permission on both platforms.

### 5.2 Asia/Dhaka, and why this is a trap

`supabase/migrations/20260806000014_dhaka_timezone_fix.sql` exists because this
exact confusion already caused three production bugs. Read its header. Summary
of the underlying fact:

`appointments.appointment_date` is a `date` and `appointment_time` is a `time`.
Neither carries a zone. They are **Bangladesh wall clock** values — 15:30 means
half past three in Dhaka. Meanwhile `now()` on Supabase resolves in UTC, and
Dhaka is UTC+06:00 with no DST. For the six hours from 18:00 to 24:00 UTC
(00:00–06:00 Dhaka) the calendar dates disagree, which broke `available_slots()`,
`guard_reviews_insert()` and `expire_stale_appointments()`.

The client side of the same mistake: `DateTime(date.year, date.month, date.day,
time.hour, time.minute)` produces a **device-local** time. On a phone set to
Dhaka that is right by accident. On a phone in London it schedules the reminder
six hours late, and phones travel.

So convert explicitly:

```dart
/// Appointment wall-clock values are Dhaka-local by definition (see
/// migration 20260806000014). Build the instant in that zone, never in the
/// device zone — a patient whose phone is set to another timezone must still
/// be reminded at the right Dhaka moment.
tz.TZDateTime appointmentInstant(DateTime date, String time) {
  final dhaka = tz.getLocation('Asia/Dhaka');
  final parts = time.split(':');
  return tz.TZDateTime(dhaka, date.year, date.month, date.day,
      int.parse(parts[0]), int.parse(parts[1]));
}
```

Initialise once at startup: `tz.initializeTimeZones()`. Do **not** call
`tz.setLocalLocation` to Dhaka — that would silently change every other
`TZDateTime` in the app. Pass the location explicitly.

### 5.3 Notification ids must be derivable

The plugin cancels by integer id, so the id has to be recomputable from the
appointment alone — you cannot store a map and expect it to survive a reinstall
or a cache clear.

```dart
/// 24h reminder → appointmentId * 10, 2h reminder → appointmentId * 10 + 1.
///
/// Derivable rather than random so cancellation needs nothing but the
/// appointment id. Ids are 32-bit on Android; appointment ids are bigint, so
/// this breaks above ~214 million appointments. Acceptable, and documented
/// here rather than discovered.
int reminderId(int appointmentId, {required bool isDayBefore}) =>
    appointmentId * 10 + (isDayBefore ? 0 : 1);
```

### 5.4 Android 13+ permission and the exact-alarm problem

Two separate things, both required, and they are frequently conflated.

**`POST_NOTIFICATIONS`** (Android 13 / API 33+) is a runtime permission. Without
it, scheduled notifications are created and silently never shown. Add to
`app/android/app/src/main/AndroidManifest.xml`, which currently declares only
`INTERNET` (`:16`):

```xml
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
```

Request it **in context** — when the user first confirms an appointment, not at
app launch. A permission prompt on first run, before any value has been
demonstrated, gets denied and Android will not ask twice.

**Exact alarms.** `AndroidScheduleMode.exactAllowWhileIdle` needs
`SCHEDULE_EXACT_ALARM`, which on Android 14+ is only granted to alarm-clock and
calendar apps; a health app requesting it risks a Play Store rejection. Use
inexact:

```dart
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
```

A reminder that lands a few minutes off is fine — "your appointment is in about
two hours" tolerates drift, and the alternative is a permission the app should
not have. Do not request `SCHEDULE_EXACT_ALARM`.

`RECEIVE_BOOT_COMPLETED` is what makes scheduled reminders survive a reboot; the
plugin's receiver handles it, but the permission must be declared or every
pending reminder dies at the next restart.

### 5.5 iOS

`requestAlertPermission` / `requestBadgePermission` / `requestSoundPermission` at
initialisation, and the same in-context timing. iOS caps pending local
notifications at **64** per app — schedule reminders only for appointments in
the next 30 days and let §5.7's reconciliation top them up.

`app/ios/` does not exist in this repo (Part 02 §1 records the missing iOS
platform). If it is generated later, `Info.plist` needs no notification key for
local notifications, but the plugin's `AppDelegate` registration is required.

### 5.6 When to schedule and cancel

| Event | Action |
|---|---|
| Appointment reaches `confirmed` | Schedule both reminders |
| Appointment reaches `cancelled` / `expired` / `completed` | Cancel both |
| Rescheduled (date or time changed) | Cancel both, schedule both from the new values |
| Payment rejected → back to `pending_payment` | Cancel both |
| Sign-out | Cancel **all** — Part 03 §6 already requires this |
| Reminder time already past | Skip silently. `zonedSchedule` with a past instant throws on some platforms and fires immediately on others; neither is wanted |
| Web | No-op — see §5.8 |

Schedule from the **client**, driven by observing appointment state. There is no
server-side scheduler in this architecture (no pg_cron on the free tier, no push
transport), so a reminder exists only on the device that saw the confirmation.
State that limitation plainly in the code comment: a patient who confirms on
their phone and then uninstalls gets no reminder, and nothing can be done about
that without push.

### 5.7 Reconciliation on app start

Because reminders live only on the device, they drift from the truth. On every
cold start, after the session resolves:

1. `pendingNotificationRequests()` — what the OS currently holds.
2. Fetch the user's `confirmed` appointments in the next 30 days.
3. Cancel any pending id whose appointment is no longer in that set.
4. Schedule any appointment in the set with no pending id.

This is the only thing that repairs a reboot, a reinstall, a timezone change, a
cancellation that happened on another device, and an iOS 64-slot eviction. Four
bugs, one loop. Run it once per launch, not per navigation.

### 5.8 Web degrades, it does not crash

`flutter_local_notifications` has no web implementation. Calling it on web
throws `MissingPluginException` — which, unguarded, would break app startup for
every web user the moment reconciliation runs.

```dart
/// Local notifications do not exist on web. Every method is a no-op there
/// rather than a thrown MissingPluginException, so calling code needs no
/// kIsWeb checks scattered through it.
abstract interface class ReminderScheduler {
  Future<void> initialize();
  Future<void> scheduleFor(Appointment appointment);
  Future<void> cancelFor(int appointmentId);
  Future<void> reconcile(List<Appointment> confirmed);
}

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) =>
    kIsWeb ? const NoopReminderScheduler() : LocalReminderScheduler(...));
```

One `kIsWeb` check, at the provider. The in-app notification centre works
identically on web, so a web user loses only the ambient reminder — and the
appointment list still shows what is coming. Do not show a "notifications
unavailable" warning on web; nothing is broken from the user's point of view.

---

## 6. Bilingual notifications

### 6.1 The problem

Notification text is written by a Postgres trigger, at the moment of the event.
The trigger does not know the recipient's language — and even if it did, the
recipient can change it afterwards. A row written today in English is read next
week by a user who has since switched to Bangla.

### 6.2 Three options

**A. Store the sentence in one language.** What happens today:
`appointments_notify` (`schema.sql:1591`) writes literal English. A Bangla user
sees an English notification centre. Rejected.

**B. Store both languages.** Add `title_bn` and `body_bn`, or make them
`jsonb`. Every trigger writes both. Works, and it is the standard answer.

**C. Store a key plus JSON parameters, render on the client.** `title` holds
`'appointment.confirmed'`, `body` holds
`{"date":"2026-08-12","doctor":"Dr Rahman"}`, and the client resolves both
against `AppLocalizations`.

### 6.3 Choose C

Four reasons, in order of weight:

1. **Existing rows retranslate.** A user who switches to Bangla sees their whole
   history in Bangla. Under B, everything written before the switch stays in
   whatever the trigger wrote, so the notification centre is permanently mixed.
   This alone decides it.
2. **A third language is an ARB file**, not a migration plus a rewrite of every
   trigger. B makes each new language a schema change.
3. **Wording fixes are client-side.** Under B, correcting a typo means updating
   a trigger and leaving every historical row wrong.
4. **Smaller rows.** Marginal, but the free tier has a 500 MB database.

The cost of C is real and worth naming: **the database no longer contains
human-readable notification text.** Someone reading the `notifications` table in
the Supabase console sees `appointment.confirmed` and a JSON blob. Mitigate by
keeping keys self-describing and documenting the catalogue in §2.2 — which is
why that table lists both languages inline.

C also needs a fallback, because §2.3's admin broadcast writes literal
sentences:

```dart
/// Resolves a notification's stored title to display text.
///
/// A known key is translated. Anything else is shown verbatim — this is what
/// makes admin broadcasts (which are typed by a human, not keyed) and legacy
/// rows written before this change both render correctly.
String resolveTitle(BuildContext context, AppNotification n) {
  final key = NotificationKeys.lookup(n.title);
  return key == null ? n.title : key.resolve(context, n.paramsJson);
}
```

Never show a raw key to a user. If `lookup` returns null the stored string is
displayed; if a parameter is missing the sentence renders without it rather
than printing `{doctor}`.

### 6.4 Storage shape, without a migration

No new columns. `title varchar(255)` holds the key; `body text` holds the JSON.
Both columns already exist and neither changes type, so R2 and D1 are satisfied
and no data is rewritten.

| Column | Before | After |
|---|---|---|
| `title` | `'Appointment confirmed'` | `'appointment.confirmed'` |
| `body` | `'Your appointment has been confirmed by the doctor.'` | `'{"doctor":"Dr Rahman","date":"2026-08-12"}'` |

`AppNotification` gains a lazily parsed `Map<String, dynamic> get params`, with
a `try/catch` returning `const {}` — a body that is not JSON is a legacy row or
a broadcast, and must render as plain text rather than throw.

### 6.5 Existing rows

Do not migrate them. R1 forbids inserting business data and rewriting live rows
is worse. Old rows have a non-key title and a prose body; §6.3's fallback
renders them exactly as they read today. They age out.

### 6.6 The key catalogue

One Dart enum or const class mirroring §2.2, so a key typo is a compile error
rather than a notification that renders as `appointment.confimed`:

```dart
enum NotificationKey {
  appointmentRequested('appointment.requested'),
  appointmentConfirmed('appointment.confirmed'),
  appointmentCancelled('appointment.cancelled'),
  paymentVerified('payment.verified'),
  bloodRequestMatch('blood.request.match'),
  ...;
  const NotificationKey(this.wire);
  final String wire;
}
```

The SQL side has no such protection, so the migration that changes each trigger
must be reviewed against this list line by line. A key that exists in SQL and
not in Dart falls through to §6.3's verbatim path and ships a
machine-readable string to a user — the one failure mode worth a test.

### 6.7 Localized notifications for `flutter_local_notifications`

A scheduled reminder is rendered by the **OS**, not by Flutter, so its text is
fixed at scheduling time in whatever locale was then active. Switching language
afterwards does not retranslate a pending reminder.

Accept it, and repair it in §5.7's reconciliation: if the app's locale differs
from the one recorded when the reminders were scheduled, cancel and reschedule
all of them. Store the locale used alongside the schedule in
`shared_preferences` — non-sensitive, which is what that dependency is already
scoped for (`app/pubspec.yaml:28-29`).

---

## 7. `device_tokens` — intentionally dormant

### 7.1 What exists

`public.device_tokens` (`supabase/schema.sql:1055`):

```sql
create table public.device_tokens (
  id         bigint generated always as identity primary key,
  user_id    uuid    not null references public.users (id) on delete cascade,
  fcm_token  varchar(255) not null,
  platform   device_platform default 'android',
  created_at timestamptz not null default now(),
  constraint uq_device_token unique (fcm_token)
);
```

Four owner-only RLS policies (`supabase/rls_policies.sql:860-875`), commented
"a push token is a device identifier. Strictly owner-only, no admin read." And
`ContentRepository.registerFcmToken()`
(`app/lib/features/content/data/content_repository.dart:131`) upserts on
`fcm_token`, whose own doc comment already states the situation: "Kept because
the table exists and wiring a token later should not need a repository change."

### 7.2 It stays exactly as it is

| Action | Do |
|---|---|
| Drop the table | **No** — R2, and it is the seam a later push implementation plugs into |
| Remove `registerFcmToken()` | **No** — R3 freezes the signature |
| Call `registerFcmToken()` | **No** — nothing produces an FCM token without `firebase_messaging` |
| Add `firebase_core` / `firebase_messaging` | **No** — D3 |
| Add a nullable `last_seen_at` or similar | No. Do not tidy a dormant table |

Nothing in this part reads or writes `device_tokens`. That is the correct amount
of work: zero.

### 7.3 Say so in one place

Add a table comment so the next person does not spend an afternoon looking for
the push code:

```sql
comment on table public.device_tokens is
  'Dormant by design (spec 05 §7). No FCM dependency is installed and no code '
  'writes here; the table and ContentRepository.registerFcmToken() exist so '
  'adding push later needs no schema or repository change. See decision D3.';
```

`app/pubspec.yaml:48-49` already carries the matching client-side note:

```
  # NOT included by design (integration choice: skip keyed integrations):
  #   firebase_core / firebase_messaging  — needs a real Firebase project
```

Two comments, one in each half of the system. That is the whole deliverable for
this section.

### 7.4 What adding push would actually cost

Recorded so the decision can be revisited on facts rather than re-litigated:

1. A Firebase project, `google-services.json` in `app/android/app/`, and an APNs
   authentication key for iOS.
2. `firebase_core` + `firebase_messaging`, plus a background message handler
   that must be a top-level function.
3. A server-side sender. Supabase Edge Functions can POST to FCM v1, which needs
   a service-account JSON as a function secret — a fifth secret to manage.
4. A `notifications`-table trigger that calls the function, which means
   `pg_net` or a queue, because a trigger must not block on an HTTP request.
5. Token lifecycle: refresh, invalidation, per-device cleanup on sign-out.

Five new moving parts and a second vendor, for a benefit — reaching a user who
does not open the app — that the in-app centre plus local reminders covers for
appointment reminders, the only genuinely time-critical case. Hence D3.

---

## 8. Per-category preferences

### 8.1 The categories are already defined

`schema.sql:1041` comments `notifications.type` as
`appointment|payment|order|blood|general`. Those five are the toggles. Do not
invent a sixth, and do not make the toggles finer than the column — a preference
the write path cannot honour is a lie in a settings screen.

`general` is **not** toggleable. It carries admin broadcasts, which include
service notices a user must not be able to opt out of. Show it in the list as a
permanently-on row with an explanatory subtitle rather than hiding it, so the
list matches the categories a user actually receives.

### 8.2 New table

```sql
-- Per-user notification opt-outs. A missing row means "everything on", so a
-- user who never opens settings needs no row written for them (R1: we do not
-- seed business data).
create table if not exists public.notification_preferences (
  user_id     uuid primary key references public.users (id) on delete cascade,
  appointment boolean not null default true,
  payment     boolean not null default true,
  "order"     boolean not null default true,
  blood       boolean not null default true,
  updated_at  timestamptz not null default now()
);

comment on table public.notification_preferences is
  'Opt-outs per notifications.type. Absent row = all enabled. No "general" '
  'column: broadcasts and service notices are not optional (spec 05 §8.1).';
```

`"order"` is quoted because `order` is reserved. That is mildly unpleasant and
the alternative — naming it `orders` while the type value is `order` — is worse,
because then the lookup in §8.3 cannot be built from the type string. Keep the
quoting and keep the names identical to the enum values.

Four owner-only policies, matching the `device_tokens` shape
(`rls_policies.sql:860-875`):

```sql
create policy notification_preferences_select_own
  on public.notification_preferences for select to authenticated
  using (user_id = (select auth.uid()));

create policy notification_preferences_insert_own
  on public.notification_preferences for insert to authenticated
  with check (user_id = (select auth.uid()));

create policy notification_preferences_update_own
  on public.notification_preferences for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

create policy notification_preferences_delete_own
  on public.notification_preferences for delete to authenticated
  using (user_id = (select auth.uid()));
```

No admin read. An admin has no reason to know which notifications a patient
muted, and the broadcast path ignores preferences anyway.

### 8.3 Enforce at write time, inside `notify()`

The check belongs in the one function every single-recipient notification already
goes through — not in each trigger, and not on the client.

```sql
create or replace function public.notify(
  p_user_id uuid, p_title text, p_body text,
  p_type text, p_route text default null, p_ref_id bigint default null
) returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_user_id is null then return; end if;

  -- Honour the recipient's opt-out. A missing preferences row means everything
  -- is enabled, which is why this is `exists (... and not enabled)` rather
  -- than a join — a left join with a null default is the same logic written
  -- so it can be got wrong later.
  if p_type <> 'general' and exists (
    select 1 from public.notification_preferences p
     where p.user_id = p_user_id
       and case p_type
             when 'appointment' then not p.appointment
             when 'payment'     then not p.payment
             when 'order'       then not p."order"
             when 'blood'       then not p.blood
             else false
           end
  ) then
    return;
  end if;

  insert into public.notifications (user_id, title, body, type, route, ref_id)
  values (p_user_id, p_title, p_body, p_type, p_route, p_ref_id);
end;
$$;
```

Suppressing at write time rather than filtering at read time is what makes §4.5
work: the unread count needs no preference awareness, because a muted
notification was never a row. Filtering at read time would leave the count
counting things the user cannot see.

§2.3's `blood_requests_notify()` inserts directly for fan-out efficiency, so it
must repeat the check in its `where` clause:

```sql
     and not exists (
       select 1 from public.notification_preferences p
        where p.user_id = d.user_id and not p.blood)
```

That duplication is the price of the set-based insert. Flag it in a comment
pointing at `notify()`, because a future category added to one and not the other
is exactly the bug this arrangement invites.

### 8.4 The settings screen

Lives under the existing settings surface, reached from the notification
centre's app bar and from the profile screen. Five rows, `SwitchListTile`, all
labels and subtitles through `AppLocalizations` (R4).

| State | Behaviour |
|---|---|
| Loading | Five skeleton rows. Not a spinner — the layout is known |
| Loaded, no row exists | All switches on. Nothing is written until the user changes one |
| Toggle | Optimistic flip, `upsert` on `user_id`, revert with a snackbar on failure |
| Error on load | Retry, with the switches shown disabled rather than hidden |
| `general` row | On, disabled, subtitle explaining that service notices cannot be turned off |

The upsert creates the row on first change, which is why no default row is
seeded (R1).

Local reminders (§5) are governed by the `appointment` toggle **on the client**:
turning it off cancels every pending reminder, turning it on triggers §5.7's
reconciliation. The database cannot cancel an OS alarm, so this one enforcement
point is necessarily client-side — the only such exception in this part, and
worth the comment saying so.

---

## 9. Definition of done

1. `notify()` carries the preference check; `authenticated` still has no insert
   grant on `notifications` (`schema.sql:1578`).
2. Every event in §2.2 fires from a trigger and lands on the right recipient.
   Verified by acting as one user and reading as the other.
3. `AppNotification` parses `route`; taps use it, validated against `Routes`.
4. The badge polls, backs off on failure, stops when backgrounded, and always
   shows the server's count.
5. A confirmed appointment schedules two reminders at Dhaka wall-clock times;
   cancelling removes them; a cold start reconciles them.
6. Titles are keys, bodies are JSON, and switching to বাংলা retranslates the
   existing list.
7. `device_tokens` is untouched and commented; `flutter pub deps` shows no
   Firebase package.
8. Five toggles persist; a muted category creates no row.
9. `flutter analyze` — zero errors, zero warnings.
10. Every screen in this part satisfies R5's four states.








