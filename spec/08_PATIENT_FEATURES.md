# Part 08 — Patient Features

Phase 9 of the master plan. Everything a patient does: find care, compare it,
book it, pay for it, collect a receipt, review it, and get help in an emergency.

**Prerequisites.** Do not start until Parts 01, 12, 02, 03, 06, 07, 04 and 05 are
done. This part assumes: the slot model of Part 01 §6.2, the `hospital_services`
table of Part 01 §6.3, the integrity triggers of Part 12, `AppLocalizations`
from Part 06, the four-state widgets of Part 07, and the `PaymentGateway`
interface of Part 04. Building a booking screen before Part 12 exists means
writing it against rules that do not yet apply — master plan §5 says so
explicitly.

**Scope boundary.** This part is the *patient* side of every shared feature. The
provider side of the same table — a doctor editing their schedule, a hospital
editing its service catalogue, a pharmacy fulfilling an order — is Part 09. The
admin side — the delete-account queue, review reports, blog moderation — is
Part 10. Where a flow crosses that line, this file specifies the patient half
and names the counterpart.

---

## 0. Corrections to the master plan you must apply before coding

Three statements elsewhere in `spec/` are wrong about this repository. They were
verified false by direct inspection on 2026-08-10. Master plan §0 says a part
file that contradicts the plan must be reported rather than silently obeyed;
this is that report, and these three corrections win for the code in this part.

### 0.1 PostGIS is NOT enabled, and no provider table has coordinates

Master plan §2 Q5 says *"PostGIS is enabled and the repositories already return
`distance_km`."* Both halves are false.

```bash
# Run these. Both print nothing.
grep -rn "postgis\|earth_distance\|ST_Distance" supabase/
grep -rn "distance_km" app/lib/
```

The only `latitude`/`longitude` columns in the whole schema are on
`emergency_sms` (`supabase/schema.sql:1164`) — the reporter's own position, not a
provider's. `doctors`, `hospitals`, `clinics`, `pharmacies` and `blood_banks`
have `city`, `area` and `address` and nothing else. The Dart layer already knows
this and says so in eight places, e.g.
`app/lib/models/directory_models.dart:20`,
`app/lib/features/patient/presentation/nearby_screen.dart:4` and
`app/lib/core/utils/formatters.dart:98`.

Consequence: **`/nearby` is a city text search today, and distance sorting is a
feature this part must build from nothing** — a migration adding the columns, a
provider-side editor to populate them (Part 09), a Haversine expression, and a
graceful fallback for the overwhelming majority of rows that will have NULL
coordinates for a long time. §3.4 specifies all four. Do not write code that
assumes a `distance_km` column exists; it does not, in any table or any view.

### 0.2 Patients cannot write blogs under the current RLS

The brief asks for "write a health post". `blogs_insert_admin`
(`supabase/migrations/20260806000002_rls_policies.sql:925`) restricts INSERT on
`public.blogs` to admins, and the `blog-covers` bucket policies gate writes on
`is_admin()` (`supabase/storage_setup.sql:152`). `ContentRepository` has no blog
write method at all — `grep -n "Future<" app/lib/features/content/data/content_repository.dart`
returns ten methods and none of them insert a blog.

So patient authoring is genuinely new policy plus new Dart, not a screen over an
existing endpoint. §13 specifies it, and keeps contradiction #20 intact: a
patient may insert only with `status = 'draft'`, and only an admin may move it to
`published`.

### 0.3 Every package this part needs is absent

```bash
grep -n "flutter_map\|latlong2\|image_picker\|geolocator\|permission_handler" app/pubspec.yaml
# prints nothing
```

`pubspec.yaml:44-47` explicitly documents the exclusion of maps and location as a
past decision. That decision is reversed by master plan §2 Q5 for OpenStreetMap
only. §12.1 lists exactly what to add and why each one.

Already present and reusable: `pdf: ^3.10.7`, `printing: ^5.12.0`,
`url_launcher: ^6.2.6`, `table_calendar: ^3.1.2`, `cached_network_image: ^3.3.1`
(`app/pubspec.yaml:33-39`).

### 0.4 Migration numbers this part owns

Parts 01 and 12 consume `20260810000001` through `20260810000024`. This part
claims `...025` to `...029`. Do not renumber theirs.

| File | §  | Purpose |
|---|---|---|
| `20260810000025_provider_coordinates.sql` | 3.4 | lat/lng on 5 tables + Haversine RPC |
| `20260810000026_account_deletion_requests.sql` | 2 | delete-account request queue |
| `20260810000027_blood_donor_contact_privacy.sql` | 8.3 | donor phone anti-scrape |
| `20260810000028_patient_blog_authoring.sql` | 13 | patient draft INSERT policy |
| `20260810000029_patient_gaps.sql` | 15 | prescriptions, review reports, exports |

---

## 1. The shape of every slice in this file

Master plan R7 says work in vertical slices. Each numbered feature below is
written in exactly this order, and an agent should implement it in that order
too, verifying each layer before starting the next.

| Layer | What it means here |
|---|---|
| **Route** | A `static const` on `Routes` (`app/lib/app/router.dart:88`) plus a `GoRoute` in the tree at `:283`. Never a hardcoded path string in a widget. |
| **Screen** | A file under `app/lib/features/<module>/presentation/`. Says *create* or *modify*, never both. |
| **Provider** | Riverpod. `FutureProvider.autoDispose.family` for a parameterised read, `StateNotifierProvider` for anything with mutation, `PagedController` for lists. |
| **Repository** | A method on an existing repository where one exists. **R3 freezes existing public signatures** — add a new method beside the old one, never change one. |
| **Table / RLS** | Which table, which policy, and which Part 12 trigger can reject the write. |
| **Strings** | ARB keys with `en` and `bn` values. R4: no literal after Phase 5. |
| **States** | Loading, empty, error-with-retry, content — R5. `core/widgets/state_views.dart` provides `LoadingView`, `EmptyView`, `ErrorView`. |
| **Acceptance** | A test that fails before the change and passes after. |

**One rule about errors, stated once.** Every repository call goes through
`SupabaseService.guard()` (`app/lib/core/network/supabase_service.dart:86`), so
every failure arrives as a single `ApiException` carrying `statusCode`, `message`
and — for the Part 12 triggers — a DETAIL `code`. Screens branch on
`ApiException.code`, look the bilingual string up in
`core/network/integrity_errors.dart` (created in Part 12 §5), and never parse
`message`. No screen in this part catches any other exception type.

**One rule about aggregates, stated once.** PostgREST cannot express `GROUP BY`.
Any count or average a screen needs must already exist as a column, a view, or an
RPC. This is not a limitation to work around at read time — it is a schema
decision made in advance. §4 depends on it entirely.

**One rule about embeds, stated once.** A PostgREST embed defaults to an inner
join, so `reviews.select('..., users(name)')` silently drops every review whose
author row is not visible — which is every review by a deleted or non-public
user. Always write `users!left(...)`. The codebase already does this correctly at
`app/lib/features/content/data/content_repository.dart:269` and
`app/lib/features/appointments/data/appointment_repository.dart:87`; match it.

---

## 2. Onboarding, profile and account lifecycle

### 2.1 What exists

`app/lib/features/auth/presentation/profile_screen.dart` (445 lines) already
renders the account page and is reachable at **two** routes:

- `Routes.profile` = `/profile` — a branch of the patient shell, with the tab bar.
- `Routes.account` = `/account` — the same screen on the root navigator, with a
  back button.

`router.dart:117-124` explains why: `auth_profile_update()` has no role check, so
every role needs this screen, but four of the five patient tabs redirect a
non-patient straight back out. **Preserve the split.** Do not "simplify" it into
one route — a doctor opening `/profile` would land inside the patient shell and
bounce. Any new account sub-page (§2.3, §2.4, §15.5) hangs off `/account`, not
`/profile`, so every role can reach it.

The theme toggle already works: `ThemeModeController`
(`app/lib/core/theme_controller.dart:11`) persists to `SharedPreferences` via
`PrefsStore` and is rendered as a three-way `SegmentedButton` at
`profile_screen.dart:258`. It needs only its labels moved to ARB.

### 2.2 Slice — avatar upload with client-side compression

| Layer | Detail |
|---|---|
| Route | none — a bottom sheet on `/account` |
| Screen | modify `app/lib/features/auth/presentation/profile_screen.dart`; the `AvatarCircle` at `:90` becomes tappable |
| Provider | `avatarUploadProvider`, a `StateNotifierProvider<AvatarUploadController, AsyncValue<void>>` |
| Repository | **new** `AuthRepository.updateAvatar(Uint8List bytes, String ext)` |
| Storage | bucket `avatars`, path `<uid>/avatar_<millis>.<ext>` per Part 02 §4.3 `StoragePaths.avatar()` |
| Column | `users.profile_image` — stores the **path**, never a URL (Part 02 §4.3) |

Add `image_picker` and `flutter_image_compress`. The compression is not optional
and is not cosmetic: master plan §2 Q2 caps storage at 1 GB and the `avatars`
bucket rejects anything over 2 MB (Part 02 §4.1). A modern phone camera produces
a 12 MP JPEG of 4–6 MB, so **an uncompressed upload fails more often than it
succeeds**, and it fails with a storage 413 that reads like a server fault.
Compress before the request, not after a rejection.

```dart
/// Downscale and re-encode before upload. Runs on a background isolate inside
/// flutter_image_compress, so a 12 MP decode does not drop frames.
///
/// 1024 px on the long edge is the ceiling because the largest avatar drawn
/// anywhere in this app is 64 logical px (profile_screen.dart:90) — at 3x that
/// is 192 device px, so 1024 already carries 5x more detail than any surface
/// consumes. Quality 80 is the knee of the JPEG curve: below it, skin tones
/// band visibly; above it, file size climbs with no perceptible gain.
///
/// Output is always JPEG, so the extension the caller passes to StoragePaths is
/// always 'jpg' and can never disagree with the bytes — a mismatch is what
/// trips the bucket's MIME allowlist.
Future<Uint8List> compressAvatar(XFile picked) async {
  final out = await FlutterImageCompress.compressWithFile(
    picked.path,
    minWidth: 1024,
    minHeight: 1024,
    quality: 80,
    format: CompressFormat.jpeg,
  );
  if (out == null) {
    throw ApiException(
      message: 'That image could not be read.',
      statusCode: 422,
      errors: const {'avatar': 'unsupported_image'},
    );
  }
  return out;
}
```

`minWidth`/`minHeight` are a *lower bound on the result*, not a crop:
`flutter_image_compress` preserves aspect ratio and will not upscale a smaller
image, so a 300×300 avatar passes through re-encoded and un-stretched.

The repository writes storage first and the column second, and that order is
deliberate. If the column update fails, the app has an orphan object costing a
few kilobytes. If the upload failed after the column was already pointed at it,
the user would have a profile referencing an object that does not exist — which
renders as the placeholder and looks exactly like the legacy-path bug in §2.5,
making it undiagnosable.

```dart
/// R3: new method, `updateProfile()` untouched.
Future<String> updateAvatar({required Uint8List bytes, String ext = 'jpg'}) {
  return SupabaseService.guard(() async {
    final uid = _requireUser();
    final path = StoragePaths.avatar(uid, ext);
    await _storage.uploadBytes(
      bucket: AppConfig.bucketAvatars,
      path: path,
      bytes: bytes,
      contentType: 'image/jpeg',
      upsert: false,          // the millis in the path make collisions impossible
    );
    await _sb.db('users').update({'profile_image': path}).eq('id', uid);
    return path;
  });
}
```

**Four states.** Loading is a `BlockingOverlay`
(`core/widgets/state_views.dart:380`) over the avatar with `avatarUploading`, not
a full-screen spinner — the rest of the page stays readable. Empty is the
existing initials placeholder in `AvatarCircle` (`:280`). Error is a snackbar
with a Retry action that re-submits the same compressed bytes, so a user on a
flaky connection does not re-pick the photo. Content is the new image; invalidate
`currentUserProvider` so the header at `:90` and the shell both refresh.

| ARB key | en | bn |
|---|---|---|
| `avatarChange` | Change photo | ছবি পরিবর্তন করুন |
| `avatarFromCamera` | Take a photo | ছবি তুলুন |
| `avatarFromGallery` | Choose from gallery | গ্যালারি থেকে বেছে নিন |
| `avatarRemove` | Remove photo | ছবি সরিয়ে ফেলুন |
| `avatarUploading` | Uploading your photo… | আপনার ছবি আপলোড হচ্ছে… |
| `avatarTooLarge` | That image is too large. Please choose another. | ছবিটি অনেক বড়। অনুগ্রহ করে অন্য একটি বেছে নিন। |
| `avatarUnsupported` | That file is not a supported image. | এই ফাইলটি সমর্থিত ছবি নয়। |

**Acceptance.** Pick a 6 MB 4000×3000 JPEG; assert the uploaded byte length is
under 2 MB and the long edge is ≥1024 px. Assert `users.profile_image` holds a
path beginning with the caller's uuid and containing no `://`. Revoke the storage
policy and assert the column is unchanged — proving the write order above.

### 2.3 Slice — the language toggle

Part 06 owns `AppLocalizations`, the ARB files and the Bangla numeral formatter.
This part owns only the control that flips it and the write that persists it.

| Layer | Detail |
|---|---|
| Screen | modify `profile_screen.dart` — a second `SegmentedButton` beside the theme one at `:258` |
| Provider | `localeControllerProvider` (Part 06) |
| Repository | **new** `AuthRepository.updatePreferredLanguage(String code)` |
| Column | `users.preferred_language varchar(2)`, CHECK `in ('en','bn')` — Part 01 §3.2 |

Write locally first, then to the server, and **do not await the server write
before repainting**. The switch must feel instant; a user on 2G tapping "বাংলা"
and watching a spinner for four seconds will tap it again. Persist to
`SharedPreferences` synchronously, rebuild, then fire the `users` update and
ignore a failure beyond a debug log — the local value is authoritative for this
device and the server copy exists so a *second* device and the notification
triggers agree. Part 05 §6 reads this column to choose a notification language.

### 2.4 Slice — delete-account request, reviewed by an admin

The brief asks that deletion be **requested and reviewed**, not immediate. Part 12
§17 explains why this is also the only safe design: fourteen tables cascade from
`public.users` (`supabase/schema.sql:549`), and the cascade reaches `payments`
and then `provider_payouts`. Part 12's own worked example shows one deletion
removing three appointments, three payments and the payout rows referencing them.

> **A payment record is the platform's evidence that money moved.** Destroying it
> because a patient tapped "delete my account" makes the commission ledger
> unreconcilable — and master plan §8.9 requires that ledger to reconcile exactly
> for *every* completed booking, including past ones. There is no version of a
> hard delete that survives that requirement.

Part 12 §17 supplies `20260810000021_user_deletion_integrity.sql`, which converts
the dangerous FKs to `RESTRICT` and adds soft-delete columns. **This part must not
re-create any of that.** It adds only the request queue on top.

```sql
-- =====================================================================
-- 20260810000026_account_deletion_requests.sql
--
-- A patient asks to be deleted; an admin decides. The row IS the
-- request -- there is no path from this table to a DELETE statement.
-- Part 12 section 17 already made the FKs RESTRICT and added the
-- soft-delete columns this queue sets.
--
-- Structure only. No INSERT (master plan R1).
-- =====================================================================

create table if not exists public.account_deletion_requests (
  id            bigint generated always as identity primary key,
  user_id       uuid not null references public.users (id) on delete cascade,
  reason        text,
  status        varchar(20) not null default 'pending',
  requested_at  timestamptz not null default now(),
  reviewed_at   timestamptz,
  reviewed_by   uuid references public.users (id) on delete set null,
  admin_note    text,
  constraint adr_status_check
    check (status in ('pending', 'approved', 'rejected', 'withdrawn'))
);

-- One live request per user. Partial, so a rejected request does not
-- block the user from ever asking again -- which would turn a "no" into
-- a permanent one and is not what a rejection means.
create unique index if not exists uq_adr_one_pending
  on public.account_deletion_requests (user_id)
  where status = 'pending';

comment on table public.account_deletion_requests is
  'Deletion is a request reviewed by an admin, never a client-side DELETE. Approving sets users.is_deleted; it does not remove the row -- fourteen tables cascade from public.users and two of them are financial (Part 12 section 17).';
```

`on delete cascade` on `user_id` here is correct and is not the hazard Part 12
describes: if a user row is ever removed by a superuser during data repair, a
dangling request referring to nobody is pure noise. The financial tables are the
ones that must survive, and they are `RESTRICT` after `...021`.

```sql
alter table public.account_deletion_requests enable row level security;

-- Per Part 02 section 1, never FOR ALL. Four commands, four policies.
create policy adr_select_own on public.account_deletion_requests
  for select to authenticated using (user_id = (select auth.uid()));
create policy adr_select_admin on public.account_deletion_requests
  for select to authenticated using (public.is_admin());
create policy adr_insert_own on public.account_deletion_requests
  for insert to authenticated with check (user_id = (select auth.uid()));
-- A patient may withdraw; only an admin may approve or reject. The status
-- vocabulary is narrowed per-role in the WITH CHECK, not in Dart.
create policy adr_update_withdraw on public.account_deletion_requests
  for update to authenticated
  using (user_id = (select auth.uid()) and status = 'pending')
  with check (status = 'withdrawn');
create policy adr_update_admin on public.account_deletion_requests
  for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

grant select, insert, update on public.account_deletion_requests to authenticated;
-- Deliberately no DELETE grant to anyone. The audit value of this table is
-- the record that a request was made and how it was answered.
```

**The patient half of the slice.**

| Layer | Detail |
|---|---|
| Route | `Routes.deleteAccount = '/account/delete'`, pushed from `/account` |
| Screen | **create** `app/lib/features/auth/presentation/delete_account_screen.dart` |
| Provider | `deletionRequestProvider` — `FutureProvider.autoDispose` reading the caller's live request, so the screen shows status rather than a fresh form |
| Repository | **new** on `AuthRepository`: `requestAccountDeletion({String? reason})`, `myDeletionRequest()`, `withdrawDeletionRequest(int id)` |

The screen has three mutually exclusive shapes, decided by
`deletionRequestProvider`: no request → the form, with a plain-language list of
what deletion does and does not remove; a pending request → the submitted date, a
"we will email you" line, and Withdraw; a rejected request → the admin's note and
a re-request button. **The form must not promise erasure.** Say what is true: the
account is closed and hidden, and payment records are retained because the law and
the platform's accounts require it. A promise of total erasure that the schema
cannot honour is worse than the honest sentence.

Guard the submit behind a typed confirmation — the user types `DELETE` (or, in
Bangla, taps a second explicit confirm rather than typing a Latin word, since
demanding Latin input from a Bangla keyboard is a real barrier). A `23505` from
`uq_adr_one_pending` means a request already exists; catch it and refresh the
provider rather than showing a unique-violation message.

| ARB key | en | bn |
|---|---|---|
| `deleteAccountTitle` | Delete my account | আমার অ্যাকাউন্ট মুছে ফেলুন |
| `deleteAccountExplain` | An administrator reviews every request. Your appointments and payment records are kept for our accounts, but your profile will no longer be visible. | একজন প্রশাসক প্রতিটি অনুরোধ পর্যালোচনা করেন। আমাদের হিসাবের জন্য আপনার অ্যাপয়েন্টমেন্ট ও পেমেন্টের রেকর্ড রাখা হবে, তবে আপনার প্রোফাইল আর দেখা যাবে না। |
| `deleteAccountReason` | Why are you leaving? (optional) | আপনি কেন চলে যাচ্ছেন? (ঐচ্ছিক) |
| `deleteAccountConfirm` | Send request | অনুরোধ পাঠান |
| `deleteAccountPending` | Your request is being reviewed. | আপনার অনুরোধ পর্যালোচনা করা হচ্ছে। |
| `deleteAccountWithdraw` | Withdraw request | অনুরোধ প্রত্যাহার করুন |
| `deleteAccountRejected` | Your request was not approved. | আপনার অনুরোধ অনুমোদিত হয়নি। |

**The admin half is Part 10.** It needs: a queue at `/admin/account-deletions`, a
count on the admin dashboard, and an approve action that sets
`users.is_deleted = true` plus the request's `status`, `reviewed_at` and
`reviewed_by` — in **one** RPC, because two round trips can leave the user deleted
with the request still pending. Approving must never issue a `DELETE`.

**Acceptance.** Submit twice; the second attempt shows the pending state, not an
error dialog. As an admin, approve a request for a patient holding a paid
appointment, then assert the `payments` row still exists and the payout still
reconciles. Attempt `delete from account_deletion_requests` with an authenticated
key and assert a permission failure.

### 2.5 Legacy image paths — expected behaviour, not a bug

Rows migrated from MySQL hold values like `uploads/avatars/12.jpg`. No such object
exists in any bucket. `AppConfig.resolveAsset()`
(`app/lib/core/constants/app_config.dart:181`) returns `''` for any non-absolute
value, and `RemoteImage` / `AvatarCircle` draw their placeholder.

This is correct and must not be "fixed" by prefixing a bucket URL — that would
turn a silent placeholder into 26 sites firing 404s. When a user uploads a new
avatar the column is overwritten with a real path and the image appears. Any bug
report of "my old photo is missing" is this, and the answer is to re-upload.

---

## 3. Browse and search

### 3.1 What exists, and what each screen becomes

| Screen | File | Change |
|---|---|---|
| Doctors list | `app/lib/features/directory/presentation/doctors_screen.dart` (350) | add sort, distance, compare selection |
| Doctor detail | `.../doctor_detail_screen.dart` (449) | add map card, compare, prescription-free |
| Places list | `.../places_screen.dart` (260) | serves clinics/hospitals/pharmacies via `PlaceKind`; add services filter + distance |
| Place detail | `.../place_detail_screen.dart` (467) | replace the text-address block at `:341` with `ProviderMap`; add the services table |
| Nearby | `app/lib/features/patient/presentation/nearby_screen.dart` (276) | remove the "no coordinates" banner at `:4` once §3.4 lands; add real distance sort |
| Products | `app/lib/features/pharmacy/presentation/products_screen.dart` (455) | add compare selection |
| Blood banks | `app/lib/features/blood_bank/presentation/blood_bank_screen.dart` (726) | add area filter + distance |
| **Services** | — | **create** `.../directory/presentation/services_screen.dart` |

`DirectoryRepository.places(PlaceKind, ...)` at
`app/lib/features/directory/data/directory_repository.dart:164` already dispatches
one method across three tables by `PlaceKind`. Keep that shape for anything new
that spans the three; do not add three parallel methods.

### 3.2 Filters and sorts — the full matrix

Filter state lives in small `StateProvider`s beside the screen, exactly as
`nearby_screen.dart:28-31` already does (`nearbyTypeProvider`,
`nearbyCityProvider`, `nearbySearchProvider`). Do not invent a filter framework.

| Surface | Filters | Sorts |
|---|---|---|
| Doctors | specialty, city, min rating, fee range, available-today, verified-only | rating desc (default), fee asc/desc, reviews desc, distance asc |
| Hospitals / clinics | city, service category, has-emergency (hospitals) | rating desc, distance asc, name asc |
| Pharmacies | city, open-24h | rating desc, distance asc |
| Services | category (the 8-value CHECK, Part 01 §6.3), city, price range | price asc (default), rating desc, distance asc |
| Products | category, in-stock only, price range, prescription-required | name asc, price asc/desc |
| Blood banks | blood group, city, area | units desc, distance asc |

`verified-only` is a filter, not a default, for one reason: `provider_search`
already hard-filters `verification_status = 'verified'`
(`patient_repository.dart:176`), so on that surface the toggle is redundant. On
the `doctors` table it is not — `DirectoryRepository.doctors()` reads the table
directly. Keeping one control that means the same thing everywhere is worth the
redundancy on one screen.

**Pagination.** Every list uses the existing `PagedController`
(`app/lib/core/paged_controller.dart:18`) with `PagedListView`, page size
`AppConfig.defaultPageSize` = 20 (`app_config.dart:148`). `PagedListView` already
implements all four states, so a list that uses it satisfies R5 by construction.
Any list that hand-rolls a `ListView` does not — this is the single most common
way R5 gets violated.

**Debounce every text filter by 350 ms.** Each keystroke against `.ilike` on an
unindexed column is a sequential scan; typing "cardiologist" unthrottled is
twelve of them. 350 ms is above the ~200 ms inter-key interval of a fast typist
and below the ~400 ms at which a UI starts feeling unresponsive.

### 3.3 The bilingual search trap

`*_bn` columns exist (Part 01 §3.1) but the app's search predicates only touch
the English column. `patient_repository.dart:180-186` ORs across `name`, `city`
and `area` — none of them `_bn`. **A Bangla user searching "ঢাকা" gets nothing**,
which reads as a broken app rather than a missing index.

Every text search added or modified by this part must cover both columns:

```dart
// Both languages in one OR. `_escapeOr` (patient_repository.dart) is
// mandatory: an unescaped comma or parenthesis in the term terminates the
// PostgREST or() list early and silently changes which rows match.
final t = _escapeOr(term.trim());
query = query.or('name.ilike.%$t%,name_bn.ilike.%$t%,city.ilike.%$t%,area.ilike.%$t%');
```

Part 01 §3.1 creates GIN indexes over `to_tsvector('simple', name || name_bn)`.
`ilike` does not use them. Accept the scan at this data volume, and note in
`IMPLEMENTATION_LOG.md` that promoting these to full-text search is the first
thing to do if a directory list exceeds roughly 5 000 rows.

### 3.4 Distance sorting — Haversine, because PostGIS is not enabled

Per §0.1, no provider table has coordinates and PostGIS is absent. Enabling
PostGIS on a Supabase free project is possible, but it is a heavier dependency
than this needs: with a few thousand rows, a Haversine expression over two
`numeric` columns is fast enough, needs no extension, and cannot break a migration
on a project where the extension is unavailable.

```sql
-- =====================================================================
-- 20260810000025_provider_coordinates.sql
--
-- Optional coordinates on the five locatable tables, plus a Haversine
-- distance function. NOT PostGIS: the extension is not enabled on this
-- project, and at this row count a plain expression is sufficient.
--
-- Every column is NULLABLE and every existing row starts NULL. Nothing
-- in the app may require a coordinate; see the distance-sort fallback
-- in Part 08 section 3.4.
--
-- Structure only. No INSERT (master plan R1).
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array['doctors','hospitals','clinics','pharmacies','blood_banks']
  loop
    execute format(
      'alter table public.%I
         add column if not exists latitude  numeric(10,7),
         add column if not exists longitude numeric(10,7)', t);
    -- Same bounds as emergency_sms_lat_check (schema.sql:1169), so a
    -- transposed lat/lng pair is rejected at write time rather than
    -- surfacing as a provider that appears to be in the Indian Ocean.
    execute format(
      'alter table public.%I drop constraint if exists %I', t, t || '_lat_check');
    execute format(
      'alter table public.%I add constraint %I
         check (latitude is null or latitude between -90 and 90)', t, t || '_lat_check');
    execute format(
      'alter table public.%I drop constraint if exists %I', t, t || '_lng_check');
    execute format(
      'alter table public.%I add constraint %I
         check (longitude is null or longitude between -180 and 180)', t, t || '_lng_check');
  end loop;
end $$;
```

The `doctors` table gets coordinates too, even though a doctor is a person: the
column pair means *where you consult*, matching the existing `chamber_address`.

```sql
-- Haversine, kilometres. IMMUTABLE so it can be used in an index
-- expression later and so the planner may fold it for constant args.
--
-- 6371.0 is the mean Earth radius; over Bangladesh (roughly 20-27 N) the
-- spherical assumption costs well under 0.5%, which is far below the
-- error in a hand-placed provider pin. An ellipsoidal formula would be
-- more precise than the input data justifies.
create or replace function public.haversine_km(
  lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric
) returns numeric
language sql
immutable
parallel safe
set search_path = ''
as $$
  select case
    when lat1 is null or lon1 is null or lat2 is null or lon2 is null then null
    else round((
      2 * 6371.0 * asin(sqrt(
          power(sin(radians(lat2 - lat1) / 2), 2)
        + cos(radians(lat1)) * cos(radians(lat2))
        * power(sin(radians(lon2 - lon1) / 2), 2)
      ))
    )::numeric, 2)
  end;
$$;

grant execute on function public.haversine_km(numeric,numeric,numeric,numeric)
  to anon, authenticated;
```

**Returning NULL rather than raising on a NULL input is the load-bearing choice.**
Almost every row will have NULL coordinates until providers fill them in (Part 09),
and a patient who denies location permission has no origin at all. `NULL` flows
through `order by ... nulls last` and those providers simply sort to the end of a
distance-sorted list instead of vanishing from it or aborting the query.

PostgREST cannot call a function inside `order by`, so distance sorting needs an
RPC. One function serves all five tables:

```sql
-- Distance-sorted provider search. Wraps provider_search (the view the
-- app already reads at patient_repository.dart:170) and adds distance_km.
--
-- p_lat/p_lng NULL means "no origin": distance_km comes back NULL for
-- every row and the ordering falls back to rating, so the caller needs
-- no second code path for a user who denied location.
create or replace function public.providers_nearby(
  p_lat   numeric default null,
  p_lng   numeric default null,
  p_type  text    default 'all',
  p_city  text    default null,
  p_search text   default null,
  p_limit  integer default 20,
  p_offset integer default 0
)
returns table (
  provider_type text,
  id            bigint,
  name          text,
  city          text,
  area          text,
  rating        numeric,
  total_reviews integer,
  image         text,
  distance_km   numeric,
  total_count   bigint
)
language sql
stable
security invoker              -- RLS on the base tables still applies
set search_path = ''
as $$
  with filtered as (
    select ps.*,
           public.haversine_km(p_lat, p_lng, ps.latitude, ps.longitude) as dist
      from public.provider_search ps
     where ps.status = 'active'
       and ps.verification_status = 'verified'
       and (p_type = 'all' or ps.provider_type = p_type)
       and (p_city is null or ps.city ilike '%' || p_city || '%')
       and (p_search is null
            or ps.name    ilike '%' || p_search || '%'
            or ps.name_bn ilike '%' || p_search || '%'
            or ps.city    ilike '%' || p_search || '%'
            or ps.area    ilike '%' || p_search || '%')
  )
  select f.provider_type, f.id, f.name, f.city, f.area, f.rating,
         f.total_reviews, f.image, f.dist,
         count(*) over () as total_count
    from filtered f
   order by f.dist asc nulls last, f.rating desc nulls last, f.name asc
   limit p_limit offset p_offset;
$$;

grant execute on function public.providers_nearby(
  numeric,numeric,text,text,text,integer,integer) to anon, authenticated;
```

Two details worth stating. `security invoker` keeps RLS in force — a
`security definer` here would let an anonymous caller read unverified providers,
undoing the filter the view relies on. And `count(*) over ()` is a window
function, **not** a `GROUP BY`, so it is legal inside a view-shaped result and
gives the paginator its total in the same round trip; PostgREST's own
`count(CountOption.exact)` is unavailable through an RPC.

`provider_search` must expose `latitude`, `longitude` and `name_bn` for this to
compile. Part 01 §3.1 adds `name_bn` to the underlying tables; extend the view's
select list in this migration with `create or replace view` and no other change.

| Layer | Detail |
|---|---|
| Repository | **new** `PatientRepository.nearbyByDistance({double? lat, double? lng, ...})` returning `Paged<NearbyResult>`. R3: the existing `nearby()` at `patient_repository.dart:157` is **not** touched — five screens call it. |
| Model | add `double? distanceKm` to `NearbyResult` (`app/lib/models/patient_models.dart:210`) and delete the comment there claiming distance is impossible |
| Provider | `nearbySortProvider` — `StateProvider<NearbySort>`; when `distance` is selected and no position is available, show the permission prompt of §12.4 rather than silently sorting by rating |

Render distance as `২.৩ কিমি` in `bn` and `2.3 km` in `en`, via the Part 06
numeral formatter. When `distanceKm` is null, render nothing at all — not "—" and
not "unknown", both of which read as an error.

### 3.5 Slice — the hospital services browser

New screen, because `hospital_services` (Part 01 §6.3) is a new table and nothing
in the app reads it. This is what makes the brief's "MRI, ultrasonography, blood
test, X-ray, ECG" a real feature rather than a substring of
`hospitals.departments`.

| Layer | Detail |
|---|---|
| Route | `Routes.services = '/services'`; `Routes.serviceDetail(int id) => '/services/$id'` |
| Screen | **create** `app/lib/features/directory/presentation/services_screen.dart` |
| Provider | `PagedController` + `serviceCategoryProvider`, `serviceCityProvider`, `servicePriceRangeProvider` |
| Repository | **new** `DirectoryRepository.services({category, city, maxPrice, page, limit})` and `service(int id)` |
| Table | `public.hospital_services`, index `idx_hospital_services_compare (category, price) where status='active'` |

The owner is an XOR of `hospital_id` and `clinic_id`, so both embeds are left
joins and exactly one is non-null per row:

```dart
// hospitals!left and clinics!left: the owner is an XOR (Part 01 section 6.3),
// so on any given row one of these is null by construction. An inner join
// would return the empty set for every row.
final res = await _sb
    .db('hospital_services')
    .select('id, name, name_bn, category, price, duration_minutes, '
        'prescription_required, preparation_notes, preparation_notes_bn, '
        'hospitals!left(id, name, name_bn, city, area, rating, total_reviews), '
        'clinics!left(id, name, name_bn, city, area, rating, total_reviews)')
    .eq('status', 'active');
```

The category chips use the eight CHECK values. Their labels are ARB keys, not the
raw enum text — `imaging` must read "Imaging" / "ইমেজিং", and Part 01 §6.3 already
warns that adding a ninth category means editing both the CHECK and the ARB.

| ARB key | en | bn |
|---|---|---|
| `svcCatImaging` | Imaging | ইমেজিং |
| `svcCatPathology` | Pathology | প্যাথলজি |
| `svcCatCardiology` | Cardiology | কার্ডিওলজি |
| `svcCatConsultation` | Consultation | পরামর্শ |
| `svcCatProcedure` | Procedure | প্রক্রিয়া |
| `svcCatTherapy` | Therapy | থেরাপি |
| `svcCatVaccination` | Vaccination | টিকা |
| `svcCatOther` | Other | অন্যান্য |
| `svcFree` | Free | বিনামূল্যে |
| `svcPrepRequired` | Preparation required | প্রস্তুতি প্রয়োজন |
| `svcEmpty` | No services match these filters. | এই ফিল্টারগুলোর সাথে কোনো সেবা মেলেনি। |

`price = 0.00` renders as `svcFree`, never as `৳0` — Part 01 §6.3 makes that
distinction deliberately, and "৳0.00" reads like a data-entry error.

**Acceptance.** Filter to `imaging`, sort by price ascending, assert the order is
non-decreasing and every row shows exactly one provider name. Insert a service
with both `hospital_id` and `clinic_id` set and assert `23514` from
`hospital_services_owner_check`.

---

## 4. Comparison — doctors, services and medicines side by side

The brief asks for this explicitly. It is the feature most constrained by the
PostgREST `GROUP BY` limitation, so read §4.2 before writing the query.

### 4.1 Selection UX

Comparison is a *mode* on an existing list, not a separate browsing surface.
Forcing the user into a dedicated screen to pick items means picking them blind,
without the filters that got them there.

- A "Compare" action in the list's app bar enters selection mode. Each card grows
  a checkbox; the rest of the card stays tappable and still opens the detail page,
  so entering the mode never traps the user.
- **Cap: 3 on a phone, 4 on a tablet** (`MediaQuery.sizeOf(context).width >= 600`).
  Three 120 dp columns plus a 96 dp label gutter is 456 dp — the last comfortable
  fit on a 360 dp-wide phone with one horizontal scroll. A fourth column on a
  phone forces either unreadable text or a scroll long enough that the two columns
  being compared are never visible together, which defeats the feature.
- At the cap, further checkboxes disable and a snackbar says why. Do not silently
  evict the oldest selection — the user cannot see which one vanished.
- A persistent bottom bar shows the count and a Compare button, enabled at ≥2.
  One item is not a comparison.
- Selection survives filter changes and pagination but **not** a leave of the
  list. It lives in a `StateNotifierProvider` scoped to the route, not a global.

```dart
/// Comparison selection. Typed by kind so a doctor and a medicine can never
/// end up in the same table -- there is no meaningful row that spans them.
enum CompareKind { doctor, service, product }

class CompareSelection extends StateNotifier<Set<int>> {
  CompareSelection(this.kind, this.maxItems) : super(const {});

  final CompareKind kind;
  final int maxItems;

  /// Returns false when the cap blocked the add, so the caller can show the
  /// snackbar without re-deriving the reason.
  bool toggle(int id) {
    if (state.contains(id)) {
      state = {...state}..remove(id);
      return true;
    }
    if (state.length >= maxItems) return false;
    state = {...state, id};
    return true;
  }

  void clear() => state = const {};
  bool get canCompare => state.length >= 2;
}

final compareSelectionProvider = StateNotifierProvider.autoDispose
    .family<CompareSelection, Set<int>, CompareKind>((ref, kind) {
  // The cap is read from the provider, not the widget, so every surface that
  // reads the selection agrees on it.
  return CompareSelection(kind, 3);
});
```

The 3-vs-4 cap is read from `MediaQuery` at the call site and passed in; the
literal `3` above is the phone default. Do not scatter the number.

### 4.2 The query, and why no aggregate is computed at read time

The comparison table's columns are rating, review count and price. Two of those
are averages over `reviews`. **PostgREST cannot express `GROUP BY`**, so
`select avg(rating) ... group by doctor_id` is not available from the client at
any URL.

The schema already solved this, and the solution must be used rather than
worked around: `rating numeric(3,2)` and `total_reviews integer` are
**denormalised columns** on all four provider tables —
`supabase/schema.sql:332-333` (doctors), `:405-406` (hospitals), `:459-460`
(clinics), `:514-515` (pharmacies) — maintained by the
`recalc_reviewable_rating()` trigger on `reviews` (`schema.sql:1319`), which
recomputes from **approved** reviews only. `CHECK` constraints keep them in range
(`doctors_rating_check`, `doctors_total_reviews_check`).

> **Rule for this feature: a comparison never computes an aggregate. It reads a
> column that a trigger already maintains.** If a future comparison column has no
> such backing — say "appointments completed this month" — add a denormalised
> column with a trigger, or a view, in a migration. Do not attempt it from Dart
> with N queries; three doctors is three round trips today and thirty on the day
> someone raises the cap.

So the comparison query is an ordinary `in` filter and nothing more:

```dart
/// R3: new method. Returns rows in the caller's selection order, because the
/// user picked column 1 first and expects it first -- `.inFilter` returns
/// primary-key order, which is arbitrary from the user's point of view.
Future<List<DoctorCompareRow>> compareDoctors(List<int> ids) async {
  if (ids.length < 2) {
    throw ApiException(
      message: 'Select at least two to compare.',
      statusCode: 422,
      errors: const {'ids': 'min_two'},
    );
  }
  return SupabaseService.guard(() async {
    final rows = await _sb
        .db('doctors')
        .select('id, specialization, specialization_bn, consultation_fee, '
            'experience_years, rating, total_reviews, chamber_address, '
            'latitude, longitude, verification_status, '
            'users!left(name, name_bn, profile_image)')
        .inFilter('id', ids)
        .eq('status', 'active');

    final byId = {for (final r in rows) r['id'] as int: r};
    return [
      for (final id in ids)
        if (byId[id] != null) DoctorCompareRow.fromJson(byId[id]!),
    ];
  });
}
```

`users!left` per §1: a doctor whose `users` row is not readable would otherwise
drop out of the comparison entirely, leaving a column the user selected simply
missing with no explanation.

`hospital_services` needs the owner's rating, which lives on the owner table, so
the service comparison embeds it exactly as §3.5 does. `pharmacy_products` has
**no** rating column at all — medicines are compared on price, stock and pharmacy,
and the rating row shows the *pharmacy's* rating with the label saying so. Do not
invent a product rating; there is no table behind it.

### 4.3 The comparison table

| Layer | Detail |
|---|---|
| Route | `Routes.compare = '/compare'`, with `?kind=doctor&ids=4,9,12` |
| Screen | **create** `app/lib/features/directory/presentation/compare_screen.dart` |
| Provider | `compareRowsProvider` — `FutureProvider.autoDispose.family<List<CompareRow>, CompareArgs>` |

Encoding the ids in the query string, rather than passing objects through
`GoRouter.extra`, is what makes a comparison shareable and restorable: `extra` is
lost on a cold start from a deep link, and "send my sister these three doctors" is
a real use of this screen.

**Layout.** A frozen first column of row labels and a horizontally scrolling body
of item columns, both driven by one `SingleChildScrollView(scrollDirection:
Axis.horizontal)` wrapping a `Table` whose first column is pinned by a `Row` with
a fixed-width leading `Column`. Rows in this order — identity first, then the
three the brief names, then the tie-breakers:

| Row | Doctor | Service | Medicine |
|---|---|---|---|
| Photo + name | `users.name` / `name_bn` | service `name` / `name_bn` | product `name` |
| Subtitle | specialisation | owning hospital/clinic | pharmacy name |
| **Rating** | `doctors.rating` | owner's `rating` | pharmacy's `rating` (labelled) |
| **Reviews** | `total_reviews` | owner's `total_reviews` | pharmacy's `total_reviews` |
| **Price** | `consultation_fee` | `price` (0 → Free) | `price` |
| Experience | `experience_years` | `duration_minutes` | pack size |
| Availability | next free slot | — | in stock / out of stock |
| Distance | `distance_km` if known | ditto | ditto |
| Action | Book | View | Add to cart |

Highlight the best cell in each numeric row — highest rating, lowest price — with
a subtle tonal background and, critically, a `Semantics(label: 'Best price')`
wrapper. Colour alone fails for a colour-blind user and is invisible to a screen
reader; Part 07 requires both.

"Next free slot" costs one `available_slots()` call per column. Cap it at the
selection cap (3), fire them concurrently with `Future.wait`, and render each
independently so one slow provider does not block the table. If a call fails,
that cell shows a dash — a comparison must still be usable when one sub-query
fails, so **never** let it collapse the whole screen into `ErrorView`.

**Four states.** Loading: a skeleton table with the right column count, since the
count is known from the URL before the data arrives. Empty: unreachable by
construction (≥2 ids), but if every id resolves to nothing — all deleted — show
`compareGone` with a back action. Error: full `ErrorView` with retry. Content: the
table.

| ARB key | en | bn |
|---|---|---|
| `compareStart` | Compare | তুলনা করুন |
| `compareSelected` | {count} selected | {count}টি নির্বাচিত |
| `compareLimit` | You can compare up to {max} at a time. | আপনি একসাথে সর্বোচ্চ {max}টি তুলনা করতে পারবেন। |
| `compareNeedTwo` | Select at least two to compare. | তুলনা করতে অন্তত দুটি নির্বাচন করুন। |
| `compareRating` | Rating | রেটিং |
| `compareReviews` | Reviews | রিভিউ |
| `comparePrice` | Price | মূল্য |
| `compareFee` | Consultation fee | পরামর্শ ফি |
| `compareNextSlot` | Next available | পরবর্তী খালি সময় |
| `compareBestPrice` | Lowest price | সর্বনিম্ন মূল্য |
| `compareBestRating` | Highest rated | সর্বোচ্চ রেটিং |
| `comparePharmacyRating` | Pharmacy rating | ফার্মেসির রেটিং |
| `compareGone` | Those items are no longer available. | এই আইটেমগুলো আর পাওয়া যাচ্ছে না। |

**Acceptance.** Select three doctors, compare, and assert the column order matches
the tap order. Assert exactly one cell in the price row carries the best-price
semantics label. Select a fourth on a 360 dp-wide test surface and assert the
checkbox is disabled and `compareLimit` is shown. Deep-link to
`/compare?kind=doctor&ids=1,2` on a cold start and assert the table renders.

---

## 5. Booking

### 5.1 What exists

`app/lib/features/appointments/presentation/book_appointment_screen.dart` (396
lines) already does date picking with `table_calendar` and slot picking from
`AppointmentRepository.slots()` (`.../data/appointment_repository.dart:96`). Its
header comment at `:1-6` already states the correct principle — the server is the
only authority on availability — and the `slotsProvider` family at `:27` is
correctly keyed by a `({int doctorId, DateTime date})` record.

What changes: the empty state, the hold, the 409 handling, and localisation.

### 5.2 The slot picker against the Part 01 model

After Part 01 §6.2, `available_slots(bigint, date)` resolves in three steps —
blackout → `doctor_schedules` template → legacy CSV fallback — and returns bare
`time` values already filtered against `appointments` and already excluding times
in the past *in Asia/Dhaka*. The signature is unchanged, so
`AppointmentRepository.slots()` needs no edit.

Three consequences the screen must respect:

1. **Never filter the returned list further.** The generator has already removed
   booked, held and past slots. A client-side "hide past times" filter using the
   device clock would drop valid slots for a user whose phone is on the wrong
   timezone.
2. **A doctor may sit twice a day.** The template branch unions multiple windows,
   so a returned list can be `09:00…11:30, 17:00…20:00` with a gap. Group the
   chips under Morning / Afternoon / Evening headings by hour (<12, <17, else)
   rather than rendering one flat wrapped grid, which makes the gap invisible.
3. **A blackout returns zero rows, and so does a non-working weekday.** These are
   different situations to a user and §5.3 distinguishes them.

Refetch `slotsProvider` when the app returns to the foreground after more than 60
seconds, and always after a failed booking. A slot grid held open for ten minutes
is fiction.

### 5.3 The "no slots" state — three distinct empty states

The single biggest usability defect available here is one generic "no slots"
message for three different causes. The screen must tell them apart, because the
user's next action differs in each case.

| Cause | How to detect | Message | Action offered |
|---|---|---|---|
| Doctor does not work this weekday | no `doctor_schedules` row for `extract(dow)` and the date is not in `available_days` | `slotsNotWorkingDay` | jump to the next working day |
| Doctor is on leave | a `doctor_blackouts` row covers the date | `slotsOnLeave` | jump to the first day after `ends_on` |
| Every slot is taken | slots exist for the weekday but all are booked or held | `slotsAllBooked` | try another date, or join no waitlist — say so plainly |

`available_slots()` returns an empty set in all three cases and cannot tell them
apart. Add a companion RPC rather than making the client guess:

```sql
-- Why a day has no slots. available_slots() returns the same empty set
-- for "not a working day", "on leave" and "fully booked", and those are
-- three different sentences to a patient.
--
-- Included in 20260810000025 rather than a file of its own: it reads the
-- same tables and shipping it separately means two migrations that are
-- meaningless apart.
create or replace function public.slot_day_status(
  p_doctor_id bigint,
  p_date      date
) returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_dow smallint := extract(dow from p_date)::smallint;
begin
  if exists (select 1 from public.doctor_blackouts b
              where b.doctor_id = p_doctor_id
                and p_date between b.starts_on and b.ends_on) then
    return 'on_leave';
  end if;

  if not exists (select 1 from public.doctor_schedules s
                  where s.doctor_id = p_doctor_id
                    and s.weekday = v_dow and s.is_active)
     and not exists (select 1 from public.doctors d
                      where d.id = p_doctor_id
                        and d.available_days ilike
                            '%' || lower(to_char(p_date, 'dy')) || '%') then
    return 'not_working';
  end if;

  if exists (select 1 from public.available_slots(p_doctor_id, p_date)) then
    return 'available';
  end if;

  return 'fully_booked';
end;
$$;

grant execute on function public.slot_day_status(bigint, date)
  to anon, authenticated;
```

Fold this into `SlotsResult` so the screen makes one call, not two:
`AppointmentRepository.slots()` gains a `dayStatus` field on its return type.
This changes a **return type**, which R3 forbids — so add the field to the
existing `SlotsResult` class rather than returning a different class. Adding a
nullable field to a returned model is source-compatible with every existing
caller; changing which class is returned is not.

| ARB key | en | bn |
|---|---|---|
| `slotsNotWorkingDay` | This doctor does not see patients on this day. | এই ডাক্তার এই দিনে রোগী দেখেন না। |
| `slotsOnLeave` | This doctor is on leave on this date. | এই তারিখে ডাক্তার ছুটিতে আছেন। |
| `slotsAllBooked` | Every appointment on this day is taken. | এই দিনের সব অ্যাপয়েন্টমেন্ট বুক হয়ে গেছে। |
| `slotsNextWorkingDay` | Go to {date} | {date} তারিখে যান |
| `slotsMorning` | Morning | সকাল |
| `slotsAfternoon` | Afternoon | দুপুর |
| `slotsEvening` | Evening | সন্ধ্যা |

### 5.4 The hold during checkout

Part 12 §4 owns this mechanism in full — `status = 'pending_payment'`,
`hold_expires_at`, the `pg_cron` expiry job, and the partial unique index that
makes a held row block others. Do not restate or re-derive it. This section
specifies only what the patient sees.

Booking a slot creates a **held** appointment and moves straight to payment. The
hold is what makes the brief's requirement coherent: the slot must be reserved
while the patient types a bKash PIN, but must not be lost forever if they close
the app at that moment.

| Layer | Detail |
|---|---|
| Screen | modify `book_appointment_screen.dart`; on success push the Part 04 payment sheet, never `/appointments` |
| Provider | `holdCountdownProvider` — `StreamProvider.autoDispose.family<Duration, DateTime>` ticking once per second off `hold_expires_at` |
| Repository | existing `AppointmentRepository.book()` at `:166`, which already returns the created `Appointment` |
| Rejection | `HOLD_ALREADY_ACTIVE` from Part 12 §7 (contradiction #6) — one pending hold per patient |

Show the remaining hold time as a countdown on the payment screen. When it
reaches zero, do not silently fail the payment: stop the timer, disable the pay
button, and offer "Pick another time", which returns to the slot grid with
`slotsProvider` invalidated. A patient staring at a payment sheet that has quietly
expired will submit and get an error they cannot interpret.

`HOLD_ALREADY_ACTIVE` deserves its own dialog, not a snackbar — the user has an
unfinished booking elsewhere, and the only useful action is to go finish or
cancel it. The dialog offers exactly that, deep-linking to the held appointment.

| ARB key | en | bn |
|---|---|---|
| `holdCountdown` | Slot held for {mm}:{ss} | সময়টি {mm}:{ss} ধরে রাখা হয়েছে |
| `holdExpired` | Your hold on this time has expired. | এই সময়ের জন্য আপনার সংরক্ষণের মেয়াদ শেষ হয়েছে। |
| `holdPickAnother` | Pick another time | অন্য সময় বেছে নিন |
| `holdAlreadyActive` | You already have an unpaid booking. Finish or cancel it first. | আপনার একটি অপরিশোধিত বুকিং আছে। প্রথমে সেটি সম্পন্ন বা বাতিল করুন। |
| `holdGoToPending` | Go to that booking | সেই বুকিংয়ে যান |

### 5.5 The 409 — two patients, one slot

Part 12 §3 owns the constraint. The patient-facing behaviour:

`uq_appointments_doctor_slot` raises `23505`, which
`SupabaseService._uniqueMessage()` maps to a 409. Part 12 §3 records that the Dart
matcher at `supabase_service.dart:329` currently tests two index names that **do
not exist** and must be fixed to include the real one. Verify that fix landed
before testing this path — until it does, a double booking surfaces as a generic
unique-violation message and this slice cannot be accepted.

**The screen must refetch, not just apologise.** The grid on screen is now known
to be stale; leaving it up invites the same failure on the next tap.

```dart
try {
  final appt = await repo.book(doctorId: id, date: d, time: t);
  if (context.mounted) _goToPayment(appt);
} on ApiException catch (e) {
  if (e.statusCode == 409) {
    // Known-stale. Invalidate before showing the message so the grid is
    // already reloading behind the snackbar.
    ref.invalidate(slotsProvider(key));
    _showSlotTaken(context);
  } else {
    _showError(context, e);
  }
}
```

| Locale | `errSlotTaken` |
|---|---|
| en | That time slot has just been taken. Please pick another. |
| bn | এই সময়টি এইমাত্র বুক হয়ে গেছে। অনুগ্রহ করে অন্য একটি সময় বেছে নিন। |

These are the exact strings Part 12 §3 specifies; use them verbatim so the ARB
key has one definition.

**Other rejections reachable from this screen**, all from Part 12 and all mapped
by DETAIL code in `core/network/integrity_errors.dart`:

| Code | Cause | Part 12 § |
|---|---|---|
| `SLOT_TAKEN` (23505) | concurrent booking | §3 |
| `HOLD_ALREADY_ACTIVE` | one pending hold per patient | §7 |
| `SLOT_NOT_AVAILABLE` | past, outside hours, or unverified doctor | §6 |
| `PROVIDER_NOT_VERIFIED` | doctor's verification revoked mid-session | §6 |

**Four states.** Loading: the calendar renders immediately and only the slot area
shows a spinner — the month grid needs no network and blanking it makes the screen
feel twice as slow. Empty: the three-way state of §5.3. Error: `ErrorView` inside
the slot area, with the calendar still usable so the user can try another date.
Content: the grouped chips.

**Acceptance.** Two concurrent clients book the same slot; assert exactly one
succeeds, the loser sees `errSlotTaken`, and its grid no longer offers that time
without a manual pull-to-refresh. Set a blackout and assert `slotsOnLeave`, not
`slotsAllBooked`.

### 5.6 Slice — rescheduling (master plan gap)

Named in master plan §2 as a gap assigned to this part. Without it a patient
cancels and rebooks, which releases the slot to everyone else in the moment
between the two writes — so the patient who wanted 5 pm Thursday loses it to a
stranger while trying to move to 6 pm.

| Layer | Detail |
|---|---|
| Route | none — a bottom sheet from `/appointments` |
| Screen | modify `app/lib/features/appointments/presentation/my_appointments_screen.dart` (733 lines); add a Reschedule action beside Cancel |
| Provider | reuses `slotsProvider` — the picker is the same widget, extracted from `book_appointment_screen.dart` into `widgets/slot_grid.dart` |
| Repository | **new** `AppointmentRepository.reschedule({required int appointmentId, required DateTime date, required TimeOfDay time})` |

**This must be one RPC, not an update.** A client-side "update date and time"
races: between validating the new slot and writing it, another patient can take
it, and the appointment ends up moved to a slot that is now double-booked — or
the update fails and the patient is left unsure which slot they hold.

`20260806000010_appointments_guard_reschedule.sql` already exists in the repo;
read it before writing anything, and extend it rather than adding a parallel path.
The RPC must, in one transaction: verify the caller owns the appointment; verify
its status permits a move (`confirmed` or `pending`, never `completed`,
`cancelled` or `no_show` — Part 12 §16's state machine decides, not this part);
verify the new slot is in `available_slots()`; and update the row so
`uq_appointments_doctor_slot` adjudicates the race. A `23505` from that index is
the same `SLOT_TAKEN` the booking path uses.

Payment is **not** re-taken. The fee is frozen onto the row (Part 12,
contradiction #15) and moving a booking does not change what was paid. Say so on
the sheet, or the patient will expect a second charge.

Limit rescheduling to more than 2 hours before the current appointment time in
Asia/Dhaka, and enforce that in the RPC. Compute the client-side preview with the
fixed +6 offset Part 12 §5 prescribes, never `DateTime.now()` in device local
time.

| ARB key | en | bn |
|---|---|---|
| `reschedule` | Reschedule | সময় পরিবর্তন করুন |
| `rescheduleKeepsPayment` | Your payment carries over. You will not be charged again. | আপনার পেমেন্ট বহাল থাকবে। আপনাকে আবার চার্জ করা হবে না। |
| `rescheduleTooLate` | Appointments can be moved up to 2 hours before the scheduled time. | নির্ধারিত সময়ের ২ ঘণ্টা আগে পর্যন্ত অ্যাপয়েন্টমেন্ট পরিবর্তন করা যায়। |
| `rescheduleDone` | Moved to {date} at {time}. | {date} তারিখে {time}-এ পরিবর্তন করা হয়েছে। |

---

## 6. Payment and the printable receipt

Part 04 owns the gateway abstraction, the simulated sandbox, commission, the state
machine and idempotency. **Do not restate any of it.** This section is the patient
surface and the receipt's role as proof at the point of service.

### 6.1 What the patient sees

Three payment paths reach a patient, all behind Part 04 §1's single
`PaymentGateway` interface: the simulated sandbox (Part 04 §3, the demo path,
needs no credentials), manual bKash transfer with admin verification, and Stripe
test mode. Per master plan D2 every credential slot is empty, and an unconfigured
gateway must render a labelled "payment not configured" state — never a crash and
never a blank sheet.

The patient-side rule: **the payment sheet is reached only from a held
appointment or a placed order, never from a menu.** A payment with nothing to pay
for is how orphan `payments` rows appear, and Part 12 §11 exists because of them.

`app/lib/features/appointments/presentation/payments_screen.dart` (179 lines) is
the patient's payment *history*, not a payment entry point. Keep it that way.

### 6.2 The receipt — the brief's "verification at the point of service"

`app/lib/features/appointments/presentation/receipt_screen.dart` (400 lines)
already generates an A4 PDF. Part 04 §7.1 documents the defect that makes it
unusable here and it must be fixed before this slice is accepted:

> `pw.Document()` at `receipt_screen.dart:69` has no theme, so the PDF renders in
> built-in Helvetica, which contains **no Bengali glyphs at all** — including `৳`
> (U+09F3), used at `receipt_screen.dart:206`. A receipt printing `▯1500` instead
> of `৳1500` is not a valid financial document.

Fix per Part 04 §7.1: embed Noto Sans Bengali, build a `pw.ThemeData` once, cache
it. That is Part 04's code; call it, do not rewrite it.

**Three receipt kinds, one document builder.** The brief asks for receipts for
doctor visits, shop orders and hospital services. They differ only in the line
items, so the header, footer, QR and totals block are shared.

| Kind | Source | Line items | Route |
|---|---|---|---|
| Doctor consultation | `appointments` + `payments` | one: consultation fee | `/receipt/:appointmentId` (exists) |
| Pharmacy order | `orders` + `order_items` | one per medicine | **new** `/orders/:id/receipt` |
| Hospital service | `appointments` (service-linked) + `payments` | one per booked service | `/receipt/:appointmentId` |

`AppointmentRepository.getReceipt()` (`appointment_repository.dart:376`) already
serves the first. Add `PharmacyRepository.orderReceipt(int orderId)` for the
second; `_order()` at `pharmacy_repository.dart:426` already loads items and
totals, so this is a thin projection, not a new query shape.

**What a point-of-service receipt must carry.** A receptionist holding this on a
phone screen has to verify it in a few seconds without a computer:

1. **The order/appointment number, large.** `orders.order_number` is generated by
   `orders_set_order_number()` (`schema.sql`, trigger) and is unique
   (`uq_order_number`); appointments use their `bigint` id.
2. **Patient name and phone**, so the person presenting it can be matched.
3. **Provider name and address** — which chamber, which branch.
4. **Date and time** of the service, not of the payment. These differ, and the
   receptionist cares about the appointment.
5. **Amount paid, and the payment status word.** `paid`, `pending` and `refunded`
   must be unmistakable. A refunded receipt still exists and must not look valid.
6. **A QR code** encoding `ayurbd://verify/appointment/<id>` (or `/order/<id>`),
   the same custom scheme `app_links` already handles for the Stripe return
   (`app/lib/core/deep_links/deep_link_service.dart`). A provider with the app
   scans it and lands on the authoritative record. This matters because **a PDF is
   forgeable and a database row is not** — the QR turns the paper into a pointer
   to the truth rather than the truth itself.
7. Both languages on the same document, not one per locale. A Bangla-speaking
   patient may hand it to an English-reading administrator. Bilingual labels
   (`Amount / পরিমাণ`) cost two lines and remove that failure mode entirely — and
   this is precisely why §7.1's font fix is a prerequisite rather than a polish.

Render money via one helper so `৳` and Bangla numerals are consistent between the
screen and the PDF. Do **not** reuse the screen's `Fmt` directly inside the PDF
without confirming the numeral choice: a receipt with Bangla numerals is correct
for a `bn` user, but the amount digits should stay Western Arabic when the
document is bilingual, because the number is the one field an English reader must
also parse. State the amount once in Western digits and put the Bangla label
beside it.

**Sharing.** `printing: ^5.12.0` provides `Printing.sharePdf`, which covers save,
share and print in one call and needs no extra package. Do not add `share_plus`
for this.

**Four states.** Loading: a spinner over the receipt area while the row and the
fonts load — font loading is real work on first use. Empty: not reachable; a
receipt requires a payment row. Error: `ErrorView` with retry, and if the
appointment is unpaid, the "not paid yet" state with a Pay action rather than an
error. Content: the preview plus Print / Share.

| ARB key | en | bn |
|---|---|---|
| `receiptTitle` | Receipt | রসিদ |
| `receiptNumber` | Receipt no. | রসিদ নম্বর |
| `receiptPaid` | Paid | পরিশোধিত |
| `receiptPending` | Payment pending | পেমেন্ট বাকি |
| `receiptRefunded` | Refunded | ফেরত দেওয়া হয়েছে |
| `receiptShowAtDesk` | Show this at the reception desk. | অভ্যর্থনা ডেস্কে এটি দেখান। |
| `receiptPrint` | Print | প্রিন্ট করুন |
| `receiptShare` | Share | শেয়ার করুন |
| `receiptNotPaidYet` | This appointment has not been paid for yet. | এই অ্যাপয়েন্টমেন্টের পেমেন্ট এখনো হয়নি। |

**Acceptance.** Generate a receipt with a Bangla patient name and assert the
extracted PDF text contains that name and `৳` — not `▯`. Assert a refunded
appointment's receipt shows `receiptRefunded` prominently. Scan the QR and assert
it resolves through `DeepLinkService` to the right record.

### 6.3 Refund visibility (master plan gap)

Part 04 §8 documents that a refund is already automatic:
`appointments_refund_on_cancel()` (`schema.sql:1651`) sets
`payment_status = 'refunded'` and reverses the `provider_payouts` row in the same
statement. The gap is purely that **the patient is never told.**

Add to `my_appointments_screen.dart` and `payments_screen.dart`: a `refunded`
`StatusPill` (`core/widgets/state_views.dart:161` already renders pills by status
string — extend its map rather than adding a new widget), and one plain sentence
about timing. Part 04 §8.2 explains the `payments` row is deliberately not
mutated, so the patient's *history* still shows the original payment alongside the
refunded status; without a sentence explaining that, it reads as a double charge.

| ARB key | en | bn |
|---|---|---|
| `refundIssued` | Refunded on {date} | {date} তারিখে ফেরত দেওয়া হয়েছে |
| `refundTiming` | Refunds reach your account within 5 to 10 working days, depending on your bank or wallet. | আপনার ব্যাংক বা ওয়ালেট অনুযায়ী ৫ থেকে ১০ কর্মদিবসের মধ্যে টাকা ফেরত পৌঁছে যাবে। |
| `refundOriginalCharge` | The original payment is kept in your history for your records. | আপনার রেকর্ডের জন্য মূল পেমেন্টটি ইতিহাসে রাখা হয়েছে। |

Part 05's event catalogue should also fire a notification on the transition, so
the patient learns of it without opening the app. Confirm it is in Part 05 §2; if
not, note the gap rather than adding a trigger here.

---

## 7. Pharmacy — browse, cart, checkout, tracking

### 7.1 What exists

Eight files, all working: `products_screen.dart` (455),
`product_detail_screen.dart` (338), `cart_screen.dart` (321),
`cart_controller.dart` (110), `checkout_screen.dart` (424), `orders_screen.dart`
(176), `order_detail_screen.dart` (266), and `pharmacy_repository.dart` (717) with
thirteen methods including `addToCart`, `updateQuantity`, `removeFromCart`,
`checkout` and `orders`.

**This module needs the least new code and the most careful review.** Its gaps are
in error handling and stock semantics, not in missing screens.

<!--CONT-->
