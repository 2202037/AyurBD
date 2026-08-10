# Supabase Network Configuration Audit & Fix

**Date:** 2026-08-10
**Scope:** Flutter app (`app/`), Supabase Edge Function, deployment guide
**Supabase project:** `cbmmhygivrejcjpfodkr` (https://cbmmhygivrejcjpfodkr.supabase.co)

---

## 1. Executive summary

The Flutter app's Supabase **backend** configuration was already correct in every
source file: the URL is the deployed HTTPS host, the key is the publishable anon
key, and there are zero hard-coded localhost/127.0.0.1/54321 backend references
in `lib/`.

The audit nevertheless found **two real defects**, both of which would have
surfaced only on a real device, and one **structural gap** that explains why
neither was noticed:

1. **The release APK could not reach the network at all.** `android.permission.INTERNET`
   existed only in `src/debug/AndroidManifest.xml` and `src/profile/AndroidManifest.xml`
   (Flutter template overlays), not in `src/main/AndroidManifest.xml`. Debug and
   profile builds work; the release APK that ships to users has **no INTERNET
   permission whatsoever** — every Supabase request dies at the socket with a
   `SecurityException`, indistinguishable from a dead backend. **This was proven
   against the built artefact**, not just inferred from source: the binary
   manifest inside `build/app/outputs/flutter-apk/app-release.apk` (2026-08-09)
   contains no `android.permission.INTERNET` string at all.

2. **Stripe's return redirect was broken for one platform by construction.**
   The Edge Function built `success_url` from the single `APP_URL` secret, and
   one value cannot be right for web and mobile at once. Set to the web dev
   origin (`http://localhost:62095`), every Android user would be redirected
   after payment to `http://localhost:62095` — which on a phone is the phone.
   Set to `ayurbd`, no browser could follow it. The Flutter client is the only
   party that knows its platform, so it now sends `return_target` with each
   checkout request; the Edge Function validates it against an allowlist and
   only falls back to `APP_URL` for unrecognised values.

3. **Why nobody noticed:** the Android build has **never completed** on this
   machine. `app/android/hs_err_pid*.log` show the Gradle daemon (8.14)
   dying of native OOM twice on 2026-08-02, and the only successful run since
   (`app/flutter_run.log`, 2026-08-06) was **Chrome**. So the last real check of
   Android behaviour predates the whole migration, and the one artefact that
   would have exposed defect #1 was never inspected. Defect #1 is now fixed;
   defect #3 is a host-RAM build issue, not a configuration error, and is
   documented in §7.

No authentication, database schema, appointment logic, RLS or payment *state*
logic was changed. The only payment-adjacent change is the redirect-target
mechanism, which is configuration plumbing (where a browser goes after
checkout), not payment logic.

---

## 2. Files changed

| File | Change | Why |
|---|---|---|
| `app/android/app/src/main/AndroidManifest.xml` | Added `<uses-permission android:name="android.permission.INTERNET"/>` | **Critical.** Release builds had no network permission at all. |
| `app/lib/core/constants/app_config.dart` | Added `assertValidBackendConfig()` (runtime startup guard), `_loopbackHosts`, `paymentReturnTarget` | Enforces the backend/frontend split in code; computes the per-platform return origin. |
| `app/lib/main.dart` | Calls `AppConfig.assertValidBackendConfig()` before `Supabase.initialize()` | Fails fast instead of shipping a phone that reaches itself. |
| `app/lib/features/payment/data/payment_service.dart` | Sends `return_target` in the `create-checkout-session` body; imports `app_config.dart` | The client is the only party that knows its platform. |
| `supabase/functions/create-checkout-session/index.ts` | `resolveReturnTarget()` allowlist; `buildSuccessUrl`/`buildCancelUrl` take the resolved target; reads `return_target` from the body; reads `APP_WEB_ORIGINS` secret | Validates the client's claim instead of trusting it; falls back to `APP_URL` for old clients. |
| `app/lib/core/widgets/state_views.dart` | Doc comment fixed (referenced the removed `AppConfig.assetBaseUrl`) | Pre-existing stale reference; `flutter analyze` hygiene. |
| `DEPLOYMENT_GUIDE.md` | Replaced the one-secret-per-platform instructions with `APP_URL` (fallback) + `APP_WEB_ORIGINS` (allowlist) | The old instructions encoded the bug: three different `APP_URL` values for one deployed project. |

Files inspected and **unchanged**: `app/lib/core/network/supabase_service.dart`,
`app/lib/core/network/api_client.dart` (tombstone), `app/lib/core/constants/api_endpoints.dart`
(tombstone), `app/web/index.html`, `app/web/manifest.json`, `app/test/*`, the
debug and profile Android manifests, `android/app/build.gradle.kts`,
`android/gradle.properties`, `android/settings.gradle.kts`, `pubspec.yaml`.

(There is no `supabase/config.toml` in this repo — the Supabase CLI local-dev
config was never generated, which is consistent with the project only ever
targeting the hosted instance.)

---

## 3. Supabase URL actually used by Flutter

One constant, used everywhere:

```
url:     https://cbmmhygivrejcjpfodkr.supabase.co
anonKey: sb_publishable_jhfgd59kqxmBmSR1XciofQ_TeWGrF5G
```

Verified by tracing every use of `AppConfig.supabaseUrl` / `supabaseAnonKey`:
`main.dart` (`Supabase.initialize`) and `test/widget_test.dart`. No Dart file
constructs a Supabase URL by hand — there are **zero** `/rest/v1`, `/auth/v1`,
`/storage/v1`, `/functions/v1` string literals in `lib/`; everything goes
through the SDK. `api_client.dart` (the old Dio client) and
`api_endpoints.dart` (the old PHP route table) are empty tombstones.

### Key classification

`sb_publishable_...` is the new-style **publishable/anon** key — not a JWT, not
secret, never capable of bypassing RLS. The app does not use Supabase Realtime
(no `.channel(...)`, `onPostgresChanges` or `.stream(` calls anywhere), so the
key only ever travels as the `apikey` header PostgREST requires. No `eyJ...`
JWT-shaped key, no `sb_secret_` key, no service_role key exists anywhere in the
repo except in the Edge Function environment and the docs' redacted placeholder.

### Backend vs frontend origins

- **Supabase backend** — the deployed HTTPS URL above, identical on web,
  Android and iOS. Deliberately a `const`, not a `--dart-define`, so a release
  build cannot silently point at a dev machine.
- **Flutter web dev server** — `http://localhost:<port>`, allowed and expected,
  but only as the *frontend* origin. This is where the localhost references in
  the repo legitimately live (§4).

---

## 4. Was localhost found?

Yes — and every hit was classified. **No remaining hit is a Supabase backend
reference.**

| Location | Classification |
|---|---|
| `app/lib/core/constants/app_config.dart` (new) | Intentional: the loopback **blocklist** and explanatory docs. |
| `app/lib/features/payment/data/payment_service.dart` (new comment) | Doc explaining why `localhost` is wrong on mobile. |
| `app/test/deep_link_service_test.dart:39` | Test fixture for a web dev-server redirect URL — valid frontend use. |
| `supabase/functions/create-checkout-session/index.ts` (new comment) | Doc explaining the bug. |
| `DEPLOYMENT_GUIDE.md` | Updated: `http://localhost:62095` now documented as a **web dev origin** in the `APP_WEB_ORIGINS` allowlist, explicitly "never the Supabase backend URL". |
| `DEPLOYMENT_GUIDE.md:142` | `stripe listen --forward-to localhost:54321` — Supabase **CLI** local dev, not the app. |
| `README.md`, `backend/config/config.php`, `ayur_db (4).sql` | Legacy PHP/MySQL (XAMPP) docs and code, deliberately kept for the old stack; the Dart app no longer references any of it. |
| `app/android/hs_err_pid*.log`, `app/flutter_run.log`, `app/android/replay_pid*.log` | JVM crash dumps and a Chrome debug-session log. Untracked, ignored. |
| `supabase/.temp/*` | CLI session metadata. |

`127.0.0.1` appears only in: the blocklist constant, JVM crash logs, the
XAMPP-era `config.php`/`README`, and one row of the MySQL dump. `54321` appears
in exactly one place (the CLI `stripe listen` forwarding example). **No Dart,
Gradle, XML, HTML or JS file references localhost/127.0.0.1/54321 as a
backend.**

---

## 5. Android and iOS configuration

### Android (verified)

- **INTERNET permission — fixed.** Now declared in `src/main/AndroidManifest.xml`
  (previously only in the debug/profile overlays). This is the permission that
  ships in release.
- **Cleartext:** no `usesCleartextTraffic` anywhere. Platform default (Android
  9+) blocks cleartext — correct, because every backend call is HTTPS. Not
  changed; adding an exemption would weaken security.
- **Deep link:** `ayurbd://` scheme registered via `<intent-filter>` with
  `VIEW`/`BROWSABLE` — correct for the Stripe return trip.
- `minSdk 24`, `targetSdk 36`, namespace `com.example.ayur`.
- **Build defect (not a config error):** the last two Gradle builds OOM'd in the
  daemon (native allocation failure, `GradleDaemon 8.14`). `android/gradle.properties`
  requests `-Xmx8G`; the host apparently cannot satisfy the daemon plus the
  Kotlin compiler plus the AGP workers. See §7 for the fix to try.

### iOS (structural gap — cannot be verified here)

**There is no `app/ios/` directory in this project.** It was never created
(`flutter create` with the platform flag, or running the app on iOS, generates
it). Consequences:

- There is no `Info.plist`, so nothing to verify for ATS exceptions (none exist
  anywhere; a generated plist would have none by default, which is correct —
  ATS blocks cleartext, and all traffic is HTTPS).
- There is no `CFBundleURLTypes` entry for `ayurbd://`. Once the iOS platform is
  generated, this must be added or the Stripe return trip will not hand the
  `ayurbd://payment-success` link back to the app. The exact snippet to paste
  into `ios/Runner/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>com.example.ayur.redirects</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>ayurbd</string>
        </array>
    </dict>
</array>
```

- Verify after generation: `<key>NSAppTransportSecurity</key>` absent (default
  = cleartext blocked = correct for a HTTPS-only app), and the scheme above
  present.

---

## 6. Environment-aware configuration (requirement 9)

The backend/frontend split is now enforced in code:

| Platform | Supabase backend | Stripe return target |
|---|---|---|
| Android / iOS | `https://cbmmhygivrejcjpfodkr.supabase.co` | `ayurbd` (custom scheme) |
| Web debug | same | `Uri.base.origin` → e.g. `http://localhost:62095` |
| Web release | same | `Uri.base.origin` → e.g. `https://ayurbd.me` |

`AppConfig.paymentReturnTarget` computes the frontend origin automatically
(`Uri.base`), so the web dev server's random port is always right with no
constant to edit. The Edge Function's `resolveReturnTarget()` allows the value
only if it matches the mobile scheme or an entry in the `APP_WEB_ORIGINS`
allowlist (or `APP_URL`), and silently falls back to `APP_URL` otherwise — an
attacker cannot aim the redirect (which carries `session_id`) at an arbitrary
host. Old clients that send no `return_target` get exactly the pre-fix
behaviour.

`AppConfig.assertValidBackendConfig()` runs at startup and throws if the
backend URL is not absolute HTTPS, is a loopback host (`localhost`,
`127.0.0.1`, `10.0.2.2`, …), or if the anon key looks like a secret. It is a
runtime check, not an `assert`, because asserts are compiled out of release.

---

## 7. Tests performed, and what could not be run

This environment has no Flutter SDK, no Dart, no Gradle, no Android SDK tools
(no `adb`/`aapt`/`apkanalyzer`), no `psql`, no `deno`, and no root. **`flutter
clean`, `flutter pub get` and `flutter analyze` could not be executed.**
Verification was static plus proof against built artefacts, and that is stated
plainly rather than claimed as a pass.

Actually performed:

1. **Full-repo sweeps** for `localhost`, `127.0.0.1`, `54321`, the project ref —
   each hit classified (§4). Result: no backend misuse remains.
2. **Shipped-APK binary manifest audit** — parsed the actual string pool of
   `build/app/outputs/flutter-apk/app-release.apk` (UTF-16LE, 86 strings):
   `android.permission.INTERNET` was absent before the fix; the fix is now in
   `src/main/AndroidManifest.xml`, the manifest that release builds merge.
3. **XML well-formedness** of all three manifests, including the edit.
4. **Node execution** of the exact `resolveReturnTarget`/`buildRedirectUrl`
   functions (copied verbatim) across 14 platform/attacker/legacy combinations —
   all redirects correct, attacker origin refused, legacy behaviour preserved.
5. **Node port** of `assertValidBackendConfig` against 7 URL/key combinations —
   shipped config accepted, all forbidden forms rejected.
6. **Dart static checks** on every edited file: delimiter balance, import
   resolution (all imports resolve inside `lib/`), `AppConfig.*` member
   existence (the two "missing" members turned out to be stale doc references,
   one fixed in `state_views.dart`), line endings (all CRLF + trailing newline,
   matching the repo convention).
7. **TS brace/paren/bracket balance** on the edited Edge Function.
8. **RPC/HTTP trace**: the only place the anon key is handed to the network is
   `Supabase.initialize`; the only place checkout is started is
   `PaymentService.startCardCheckout`, which now sends `return_target`.

To be run by the user (this machine cannot):

```
flutter clean
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

and then re-verify §5's manifest findings against the new APK.

---

## 8. Remaining risks

1. **`flutter analyze` / `flutter test` unrun.** Static analysis found two real
   bugs before, but the compiler is the referee; run it before shipping.
2. **`flutter build apk` may still OOM the Gradle daemon** (pre-existing).
   First thing to try: drop `org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G`
   in `app/android/gradle.properties` to e.g. `-Xmx3G -XX:MaxMetaspaceSize=1G`,
   close other JVM hosts, and retry. If it still fails, `./gradlew --stop` and
   rebuild. This is a host-memory issue, not an app-configuration one.
3. **iOS is ungenerated** — the `CFBundleURLTypes` snippet in §5 must be applied
   after `flutter create --platforms=ios .` (or the first iOS build) or the
   post-payment return trip fails on iOS.
4. **`APP_WEB_ORIGINS` is a new secret** — it must be set (`supabase secrets set
   APP_WEB_ORIGINS=https://ayurbd.me,http://localhost:62095`) or web users fall
   back to `APP_URL`; the allowlist then adds nothing. The fallback keeps old
   behaviour, so nothing breaks until it is set.
5. **The release build still signs with the debug key** (`build.gradle.kts` TODO).
   Unrelated to networking, but a release APK on a store must be re-signed.
