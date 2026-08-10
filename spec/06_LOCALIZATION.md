# Part 06 — Localization

**Phase 5 in master plan §5. Nothing in Parts 07–11 may be written before this
file is executed.**

The ordering is not stylistic. There are 115 Dart files and roughly 60 screens in
`app/lib/features/`, and a direct count of hardcoded literals gives:

```bash
# Run from F:\Project folder\AyurBD
grep -rn "Text('" app/lib --include=*.dart | wc -l          # 250
grep -rn 'Text("' app/lib --include=*.dart | wc -l          #   0
grep -rnE "(labelText|hintText|title|label|tooltip): *'" app/lib --include=*.dart | wc -l   # 415
```

Every one of those is English written directly into a widget. Localizing after
the UI phase means opening all ~60 screens twice, and the second pass is the one
that gets abandoned half-finished — which is precisely how this repository ended
up with **eight files containing hardcoded Bangla** already, mixed into English
screens with no mechanism behind it:

```
app/lib/core/constants/app_config.dart          (the ৳ constant — legitimate)
app/lib/core/utils/formatters.dart              (the ৳ constant — legitimate)
app/lib/features/admin/presentation/admin_providers_screen.dart
app/lib/features/appointments/presentation/receipt_screen.dart
app/lib/features/auth/presentation/doctor_register_screen.dart
app/lib/features/pharmacy/data/pharmacy_repository.dart
app/lib/features/pharmacy/presentation/cart_screen.dart
app/lib/models/pharmacy_models.dart
```

The app is accidentally bilingual and unmanageably so. This part replaces that
accident with a system.

Master plan §7 is the standard this file implements: English and Bangla are
co-equal, a Bangla-first user completes every journey without meeting an English
string, the switch is runtime with no restart, and it persists per user.

---

## 1. Setup

### 1.1 What is present and what is absent

Verified on 2026-08-10 against `app/pubspec.yaml`:

| Thing | State |
|---|---|
| `intl: ^0.19.0` | **present** — already a direct dependency, used by `core/utils/formatters.dart:5` |
| `flutter_localizations` | **absent** |
| `l10n.yaml` | **absent** — `ls app/l10n.yaml` returns nothing |
| `app/lib/l10n/` | **absent** |
| `generate: true` under `flutter:` | **absent** |
| `app/assets/` | **absent entirely** — there is no asset directory at all |

The last row matters twice: once for fonts (§2) and once because
`app/pubspec.yaml` carries a comment explaining that an `assets:` key pointing at
a non-existent folder fails the build. Create the folder before declaring it.

### 1.2 Exact pubspec additions

`intl` is already there. **Do not change its version.** Flutter's bundled
`flutter_localizations` pins a specific `intl`, and `^0.19.0` is what the
current SDK constraint (`>=3.3.0 <4.0.0`) expects. If `flutter pub get` reports
a conflict, adjust `intl` to whatever `flutter_localizations` demands and change
nothing else.

Add to `dependencies:` in `app/pubspec.yaml`, immediately after the `flutter:`
sdk entry:

```yaml
  flutter_localizations:
    sdk: flutter
```

Add under the existing `flutter:` section, beside `uses-material-design: true`:

```yaml
flutter:
  uses-material-design: true
  generate: true
```

`generate: true` is what makes `flutter pub get` and `flutter run` invoke
`gen_l10n`. Without it the ARB files are inert and `AppLocalizations` never
exists.

### 1.3 `app/l10n.yaml` — exact contents

Create this file at `app/l10n.yaml` (sibling of `pubspec.yaml`, **not** inside
`lib/`):

```yaml
# gen_l10n configuration. Read by `flutter gen-l10n`, which `flutter pub get`
# runs automatically because pubspec.yaml sets `generate: true`.
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
output-class: AppLocalizations
output-dir: lib/l10n/gen
synthetic-package: false

# Fail the generation when a key exists in app_en.arb but not app_bn.arb.
# The default is to silently fall back to English, which is exactly the
# failure mode master plan §7 forbids: a Bangla user meeting an English
# string, with nothing in the build to flag it.
untranslated-messages-file: lib/l10n/untranslated.txt

nullable-getter: false
```

Two choices need justifying.

**`synthetic-package: false`.** The default writes the generated class into a
synthetic package resolved only through `package:flutter_gen/...`, which some
IDE and analyzer configurations fail to resolve, producing a phantom "undefined
class AppLocalizations" across 60 files. Writing real files into
`lib/l10n/gen/` costs a directory and removes an entire class of tooling
failure. `output-dir` must be inside `lib/` for this to work.

**`nullable-getter: false`.** Makes `AppLocalizations.of(context)` return a
non-nullable instance, so call sites read `AppLocalizations.of(context).btnSave`
rather than `AppLocalizations.of(context)!.btnSave`. Across an estimated 665
call sites that removes 665 null assertions. The generated code throws if the
delegate is missing, which is a startup misconfiguration, not a runtime state.

> Part 12 §2 shows `AppLocalizations.of(context)!` with a bang. That snippet was
> written before this decision. Drop the `!` when you implement
> `localizeIntegrityError`.

### 1.4 Add the gen directory to version control, not to the analyzer's ignore list

`lib/l10n/gen/` is generated but **must be committed**. A checkout that has not
run `flutter pub get` still needs to analyze, and CI that runs `flutter analyze`
before `pub get` would otherwise report 665 undefined getters.

Add to `app/analysis_options.yaml` — read the file first, and merge rather than
replace, because `flutter_lints` is already wired in via `include:`:

```yaml
analyzer:
  exclude:
    - lib/l10n/gen/**
```

Excluding generated code from lint is standard; excluding it from *version
control* is not.

### 1.5 Wiring into `MaterialApp`

`app/lib/app/app.dart` is 27 lines and currently passes no localization
delegates. §4.3 gives the finished file, because the locale provider and the
delegates land in the same edit.

### 1.6 Verification for this section

```bash
cd app
flutter pub get          # must regenerate lib/l10n/gen/app_localizations.dart
ls lib/l10n/gen/         # app_localizations.dart, app_localizations_en.dart,
                         # app_localizations_bn.dart
cat lib/l10n/untranslated.txt   # must be empty or absent
```

An `untranslated.txt` with entries in it is a failed build, not a warning.

---

## 2. The Bangla font problem

**Read this section before writing a single widget. It is the single most likely
way to ship an app that looks broken to every Bangla user.**

### 2.1 What goes wrong

Flutter's default `fontFamily` on Android resolves to Roboto. Roboto has no
Bengali glyphs. When a text run contains a codepoint the font cannot render, the
platform draws `.notdef` — a hollow rectangle, universally called tofu. A Bangla
sentence in Roboto renders as:

```
□□□□□ □□□□□ □□□□□□
```

On Android this *sometimes* appears to work in development, because Android
performs system-level font fallback to Noto Sans Bengali when that font is
installed on the device. That fallback is what makes this bug so dangerous:

- It works on the developer's phone.
- It fails on a device whose system font set lacks Bengali.
- It fails on **web**, where there is no system fallback to reach for.
- It fails in **PDF** unconditionally — the `pdf` package embeds only what you
  give it and has no system font access at all.

So "I tested it and Bangla showed up" is not evidence. The font must be embedded
in the app bundle.

### 2.2 Which font

**Use Hind Siliguri as the app font and Noto Sans Bengali as the PDF font.**

| | Hind Siliguri | Noto Sans Bengali |
|---|---|---|
| Licence | SIL OFL 1.1 — redistributable in a commercial app | SIL OFL 1.1 |
| Scripts | Devanagari, **Bengali**, Latin | **Bengali**, Latin |
| `৳` U+09F3 | yes | yes |
| Bangla numerals ০–৯ | yes | yes |
| Weights needed | Regular 400, Medium 500, SemiBold 600, Bold 700 | Regular 400, Bold 700 |
| Design | humanist, slightly condensed, tuned for UI | neutral, tuned for wide coverage |

Master plan §7 names Hind Siliguri, and it is the better UI face: its Bengali
letterforms are drawn for small sizes and its Latin is a proper companion rather
than an afterthought, so one family covers the whole interface and English and
Bangla in the same paragraph share a voice.

Noto Sans Bengali is specified for PDFs to match Part 04 §7.1, which already
names it. Keeping the two separate is deliberate — the PDF font is loaded through
`rootBundle.load` and parsed by the `pdf` package, and pinning that to a font
whose file name Part 04 already cites avoids a cross-file rename.

### 2.3 Where the files go

`app/assets/` does not exist. Create:

```
app/assets/fonts/HindSiliguri-Regular.ttf
app/assets/fonts/HindSiliguri-Medium.ttf
app/assets/fonts/HindSiliguri-SemiBold.ttf
app/assets/fonts/HindSiliguri-Bold.ttf
app/assets/fonts/NotoSansBengali-Regular.ttf
app/assets/fonts/NotoSansBengali-Bold.ttf
```

Download from Google Fonts (`fonts.google.com/specimen/Hind+Siliguri`,
`fonts.google.com/noto/specimen/Noto+Sans+Bengali`). Both are OFL; ship the
`OFL.txt` alongside as `app/assets/fonts/OFL-Hind-Siliguri.txt` and
`app/assets/fonts/OFL-Noto-Sans-Bengali.txt`. The OFL requires the licence to
travel with the font.

**Size budget.** Six TTFs at roughly 250–400 KB each adds about 2 MB to the APK.
That is the correct trade for an app that must render Bangla. Do not try to
subset the fonts to save space: Bengali shaping uses conjuncts and reordering
vowel signs, and a naive subsetter that drops a glyph you did not know was
needed produces tofu in exactly one word.

### 2.4 The pubspec `fonts:` block

Add under the existing `flutter:` section:

```yaml
flutter:
  uses-material-design: true
  generate: true

  # Bangla-capable font. A Latin-only face renders every Bangla string as
  # tofu boxes, and on web there is no system fallback to save it. See
  # spec/06_LOCALIZATION.md section 2.
  assets:
    - assets/fonts/

  fonts:
    - family: HindSiliguri
      fonts:
        - asset: assets/fonts/HindSiliguri-Regular.ttf
          weight: 400
        - asset: assets/fonts/HindSiliguri-Medium.ttf
          weight: 500
        - asset: assets/fonts/HindSiliguri-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/HindSiliguri-Bold.ttf
          weight: 700

    # PDF receipts only, loaded via rootBundle and embedded by the `pdf`
    # package. See Part 04 section 7.1.
    - family: NotoSansBengali
      fonts:
        - asset: assets/fonts/NotoSansBengali-Regular.ttf
          weight: 400
        - asset: assets/fonts/NotoSansBengali-Bold.ttf
          weight: 700
```

Declaring `assets/fonts/` under `assets:` as well as `fonts:` is required: the
`fonts:` key registers the family with the text engine, while `assets:` is what
makes the bytes reachable through `rootBundle.load` for the PDF path.

> `weight:` values must match the file. Registering `HindSiliguri-Medium.ttf` at
> `weight: 400` makes every `FontWeight.w400` render medium and every `w500`
> synthesize a fake bold. The four declared weights cover what
> `app/lib/core/constants/app_theme.dart` actually asks for: `w600` on app-bar
> titles (`:153`) and buttons (`:227`), `w700` on section headers
> (`core/widgets/state_views.dart:359`).

### 2.5 Wiring the family into `ThemeData`

Declaring a font in `pubspec.yaml` registers it. It does not *use* it. Without
this step every widget still asks for Roboto and §2.1 happens anyway.

`app/lib/core/constants/app_theme.dart` builds both themes through one private
`_build()` (`:82`), so there is exactly one line to change. At `:135`:

```dart
    final base = ThemeData(brightness: brightness);
```

becomes:

```dart
    // Hind Siliguri covers Latin AND Bengali. Roboto (Flutter's default) has no
    // Bengali glyphs, so every Bangla string would render as tofu boxes on any
    // device without a system Bengali fallback, and on web unconditionally.
    // See spec/06_LOCALIZATION.md section 2.
    final base = ThemeData(brightness: brightness, fontFamily: 'HindSiliguri');
```

**It must go on the `ThemeData` constructor, not on the `copyWith` at `:137`.**
`ThemeData.copyWith` has no `fontFamily` parameter — the constructor uses it to
build a `Typography`/`TextTheme` whose every style already carries the family,
and `copyWith` only accepts the finished `textTheme`. Passing it to the
constructor also means `_textTheme()` (`:287`) receives a `base.textTheme` that
already has the family, and both `.apply()` and `.copyWith()` preserve it, so
the line-height work in that method needs no change.

One line covers light and dark, because `light()` (`:60`) and `dark()` (`:71`)
both delegate to `_build`.

Two places still escape the theme and must be fixed by hand, because they build
a `TextStyle` from scratch rather than from the text theme:

| Site | What it is | Fix |
|---|---|---|
| `app_theme.dart:150` | `appBarTheme.titleTextStyle` | inherits nothing; add `fontFamily: 'HindSiliguri'` |
| `app_theme.dart:227` | `filledButtonTheme` `textStyle` | same |

A bare `TextStyle(...)` does not inherit `ThemeData.fontFamily`. Leaving these
two produces the worst possible symptom: body text renders Bangla correctly and
every app-bar title and every button label renders tofu, which reviewers read as
"a font glitch" rather than "a missing font".

### 2.6 Verifying that Bangla actually renders

Do not verify by opening the app on an Android phone and looking at it. Android
falls back to a system Bengali font (§2.1), so a completely unwired build looks
correct there. Three checks, in this order:

**1. The font is in the bundle.** After a build, list the asset manifest:

```bash
cd app
flutter build apk --debug
unzip -l build/app/outputs/flutter-apk/app-debug.apk | grep -i siliguri
# must list assets/fonts/HindSiliguri-Regular.ttf and the other three
```

A missing line here means `pubspec.yaml` is wrong and every later check is
meaningless.

**2. The app uses it, on a platform with no fallback to hide the bug.** Web has
no system font fallback for a Flutter canvas, so it is the honest target:

```bash
cd app
flutter run -d chrome
```

Then set the locale to `bn` and read any screen. If Bangla shows and English on
the same screen looks slightly narrower and more humanist than before, the
family is live. If Bangla shows but English looks like Roboto, the theme wiring
did not take.

**3. A widget test that fails when the family is dropped.** Put this in
`app/test/localization/font_test.dart` — a real gate, unlike a screenshot:

```dart
testWidgets('app theme applies the Bangla-capable family', (tester) async {
  final theme = AppTheme.light();
  expect(theme.textTheme.bodyMedium?.fontFamily, 'HindSiliguri');
  expect(theme.appBarTheme.titleTextStyle?.fontFamily, 'HindSiliguri');
  expect(
    theme.filledButtonTheme.style?.textStyle
        ?.resolve({})?.fontFamily,
    'HindSiliguri',
  );
});
```

The three expectations map one-to-one onto the three edits above. A future
refactor that rewrites `_build` and forgets `fontFamily` fails this test instead
of shipping tofu.

> Flutter cannot report a missing glyph at runtime — the text engine draws
> `.notdef` and returns success. There is no exception to catch and no log line
> to grep. That is why the check is structural.

---

## 3. ARB keys and the initial catalogue

### 3.1 Naming convention

Keys are `camelCase` — `gen_l10n` turns each key into a Dart getter, and a key
with an underscore becomes a getter with an underscore, which `flutter_lints`
flags as a non-conforming member name across 600 call sites.

The shape is **`<domain><Thing>`**, domain first:

| Domain prefix | Covers | Example |
|---|---|---|
| `common` | words used by three or more features | `commonSave`, `commonCancel` |
| `auth` | login, register, password, session | `authLoginTitle` |
| `appt` | appointments, slots, booking | `apptBookNow` |
| `pay` | payments, receipts, gateways | `payMethodBkash` |
| `shop` | pharmacy catalogue, cart, orders | `shopAddToCart` |
| `blood` | blood bank and requests | `bloodRequestTitle` |
| `emg` | emergency hotlines | `emgCallNow` |
| `blog` | articles and content pages | `blogReadMore` |
| `dir` | directory: doctors, clinics, hospitals | `dirFilterCity` |
| `admin` | admin console | `adminApprove` |
| `prov` | provider workspace | `provTodaySchedule` |
| `err` | error messages shown to a user | `errNetwork` |
| `val` | form validation messages | `valEmailInvalid` |
| `status` | enum-backed status labels | `statusPending` |

Domain first, not last, because the ARB file is read alphabetically. `authEmail`,
`authPassword`, `authLoginTitle` sort together; `emailAuth`, `passwordAuth`
scatter across the file and a reviewer cannot tell whether a feature is fully
translated by looking at one region of it.

Three rules on top:

1. **No key names the widget.** `authLoginButton` is wrong if the same string
   also appears on a bottom sheet. Name the *meaning*: `authSignIn`.
2. **No `1`/`2` suffixes.** `errNetwork2` means someone had two error messages
   and could not tell them apart. Name the case: `errNetworkTimeout`.
3. **A key is never reused across two meanings that happen to share an English
   word.** English "Book" is a verb on a doctor card and a noun nowhere in this
   app, but "Order" is a verb in admin and a noun in the shop. Bangla splits
   them (`অর্ডার করুন` vs `অর্ডার`), so they are two keys.

### 3.2 ARB mechanics this project relies on

`app/lib/l10n/app_en.arb` is the template; every key must also exist in
`app/lib/l10n/app_bn.arb` (§1.3 fails the build otherwise). The template carries
the `@key` metadata; the Bangla file carries **only** the translations. Metadata
duplicated into `app_bn.arb` is not an error but it is dead weight that drifts.

```json
{
  "@@locale": "en",

  "apptBookNow": "Book now",
  "@apptBookNow": {
    "description": "Primary action on a doctor card and on the doctor detail screen."
  },

  "apptSlotsLeft": "{count, plural, =0{No slots left} =1{1 slot left} other{{count} slots left}}",
  "@apptSlotsLeft": {
    "description": "Remaining capacity on a time slot.",
    "placeholders": { "count": { "type": "int" } }
  },

  "payAmountDue": "Amount due: {amount}",
  "@payAmountDue": {
    "description": "amount arrives pre-formatted from Fmt.money — do NOT add a currency format here.",
    "placeholders": { "amount": { "type": "String" } }
  }
}
```

Three decisions worth stating because they are easy to get backwards.

**Money placeholders are `String`, never `double` with an ARB `currency`
format.** ARB's `NumberFormat.currency` cannot produce `৳1,250` with Bangla
numerals conditionally, and it does not know about the paisa-suppression rule in
`app/lib/core/utils/formatters.dart:15-20`. Money is formatted by §5's helper and
handed to the ARB as an already-finished string.

**Plurals use `=0`, `=1`, `other` and nothing else.** Bangla, like English, has
CLDR categories `one` and `other`; there is no dual and no paucal. `=0` is not a
CLDR category but an explicit-value branch, which is what lets "No slots left"
read like a sentence rather than "0 slots left".

**Every parameterised key gets a `description` naming who supplies the
placeholder.** Without it a translator writes `{count}টি` where the count is
already suffixed, and the string renders `৩টিটি`.

### 3.3 The catalogue

These are the real strings. Write them into the two ARB files as given; they are
not placeholders and they are not to be re-translated by a machine. Bangla here
is what a Bangladeshi user actually says — `অ্যাপয়েন্টমেন্ট`, `ডেলিভারি`,
`পেমেন্ট` are borrowed words in ordinary Bangla speech and are correct; forcing
`সাক্ষাৎকার` or `প্রদান` produces text that reads like a government form.

Verb forms use the polite imperative (`করুন`, not `করো` or `কর`), which is the
register a stranger's app owes a user.

#### common — 40 keys

Used by three or more features. `app/lib/core/widgets/state_views.dart` alone
consumes eight of them.

| Key | English | বাংলা |
|---|---|---|
| `commonSave` | Save | সংরক্ষণ করুন |
| `commonCancel` | Cancel | বাতিল |
| `commonConfirm` | Confirm | নিশ্চিত করুন |
| `commonDelete` | Delete | মুছে ফেলুন |
| `commonEdit` | Edit | সম্পাদনা |
| `commonClose` | Close | বন্ধ করুন |
| `commonBack` | Back | পেছনে |
| `commonNext` | Next | পরবর্তী |
| `commonDone` | Done | হয়ে গেছে |
| `commonRetry` | Try again | আবার চেষ্টা করুন |
| `commonSearch` | Search | খুঁজুন |
| `commonSearchHint` | Search… | খুঁজুন… |
| `commonFilter` | Filter | ফিল্টার |
| `commonClearFilters` | Clear filters | ফিল্টার মুছুন |
| `commonSeeAll` | See all | সব দেখুন |
| `commonLoading` | Loading… | লোড হচ্ছে… |
| `commonNoResults` | Nothing found | কিছু পাওয়া যায়নি |
| `commonEmptyHint` | Try a different search or filter. | অন্য কিছু লিখে বা ফিল্টার বদলে দেখুন। |
| `commonYes` | Yes | হ্যাঁ |
| `commonNo` | No | না |
| `commonOptional` | Optional | ঐচ্ছিক |
| `commonRequired` | Required | আবশ্যক |
| `commonName` | Name | নাম |
| `commonPhone` | Phone number | ফোন নম্বর |
| `commonEmail` | Email | ইমেইল |
| `commonAddress` | Address | ঠিকানা |
| `commonCity` | City | শহর |
| `commonNotes` | Notes | নোট |
| `commonDate` | Date | তারিখ |
| `commonTime` | Time | সময় |
| `commonStatus` | Status | অবস্থা |
| `commonCall` | Call | কল করুন |
| `commonShare` | Share | শেয়ার করুন |
| `commonRefresh` | Refresh | রিফ্রেশ করুন |
| `commonSettings` | Settings | সেটিংস |
| `commonLanguage` | Language | ভাষা |
| `commonAppearance` | Appearance | থিম |
| `commonThemeSystem` | System | সিস্টেম অনুযায়ী |
| `commonThemeLight` | Light | লাইট |
| `commonThemeDark` | Dark | ডার্ক |

`commonAppearance` is `থিম`, a loanword, not a coined Bangla compound. Every
Bangladeshi smartphone user knows the word; নকশা and চেহারা both mean something
else in this context.

#### auth — 34 keys

`app/lib/features/auth/` is 14 files with 31 `Text('` and 117 labelled
parameters — the second-largest concentration in the app after `admin`.

| Key | English | বাংলা |
|---|---|---|
| `authSignIn` | Sign in | সাইন ইন |
| `authSignUp` | Create account | অ্যাকাউন্ট খুলুন |
| `authSignOut` | Sign out | সাইন আউট |
| `authLoginTitle` | Welcome back | আবার স্বাগতম |
| `authLoginSubtitle` | Sign in to book appointments and order medicine. | অ্যাপয়েন্টমেন্ট নিতে ও ওষুধ অর্ডার করতে সাইন ইন করুন। |
| `authPassword` | Password | পাসওয়ার্ড |
| `authConfirmPassword` | Confirm password | পাসওয়ার্ড আবার লিখুন |
| `authCurrentPassword` | Current password | বর্তমান পাসওয়ার্ড |
| `authNewPassword` | New password | নতুন পাসওয়ার্ড |
| `authChangePassword` | Change password | পাসওয়ার্ড পরিবর্তন |
| `authForgotPassword` | Forgot password? | পাসওয়ার্ড ভুলে গেছেন? |
| `authResetLinkSent` | We sent a reset link to {email}. | {email} ঠিকানায় একটি রিসেট লিংক পাঠানো হয়েছে। |
| `authNoAccount` | Don't have an account? | অ্যাকাউন্ট নেই? |
| `authHaveAccount` | Already have an account? | আগে থেকেই অ্যাকাউন্ট আছে? |
| `authRoleQuestion` | How will you use AYUR? | আপনি AYUR কীভাবে ব্যবহার করবেন? |
| `authRolePatient` | I need healthcare | আমার চিকিৎসা প্রয়োজন |
| `authRoleDoctor` | I am a doctor | আমি একজন ডাক্তার |
| `authRoleClinic` | We are a clinic | আমরা একটি ক্লিনিক |
| `authRoleHospital` | We are a hospital | আমরা একটি হাসপাতাল |
| `authRolePharmacy` | We are a pharmacy | আমরা একটি ফার্মেসি |
| `authGender` | Gender | লিঙ্গ |
| `authGenderMale` | Male | পুরুষ |
| `authGenderFemale` | Female | মহিলা |
| `authGenderOther` | Other | অন্যান্য |
| `authBloodGroup` | Blood group | রক্তের গ্রুপ |
| `authProfile` | Profile | প্রোফাইল |
| `authEditProfile` | Edit profile | প্রোফাইল সম্পাদনা |
| `authProfileSaved` | Profile updated. | প্রোফাইল হালনাগাদ হয়েছে। |
| `authSignOutConfirm` | Sign out of AYUR? | AYUR থেকে সাইন আউট করবেন? |
| `authSessionExpired` | Your session expired. Please sign in again. | আপনার সেশনের মেয়াদ শেষ। আবার সাইন ইন করুন। |
| `authAccountSuspended` | This account has been suspended. Contact support. | এই অ্যাকাউন্টটি স্থগিত করা হয়েছে। সহায়তায় যোগাযোগ করুন। |
| `authPendingApproval` | Your account is awaiting admin approval. | আপনার অ্যাকাউন্ট অ্যাডমিনের অনুমোদনের অপেক্ষায় আছে। |
| `authLicenseNumber` | Licence / BMDC number | লাইসেন্স / বিএমডিসি নম্বর |
| `authUploadDocument` | Upload verification document | যাচাইয়ের কাগজ আপলোড করুন |

#### appt — appointments and booking, 32 keys

| Key | English | বাংলা |
|---|---|---|
| `apptTitle` | Appointments | অ্যাপয়েন্টমেন্ট |
| `apptBookNow` | Book now | এখনই বুক করুন |
| `apptBookAppointment` | Book appointment | অ্যাপয়েন্টমেন্ট বুক করুন |
| `apptUpcoming` | Upcoming | আসন্ন |
| `apptPast` | Past | পূর্ববর্তী |
| `apptNoUpcoming` | No upcoming appointments | কোনো আসন্ন অ্যাপয়েন্টমেন্ট নেই |
| `apptNoUpcomingHint` | Find a doctor and book a visit. | ডাক্তার খুঁজে একটি ভিজিট বুক করুন। |
| `apptSelectDate` | Choose a date | তারিখ বাছুন |
| `apptSelectSlot` | Choose a time | সময় বাছুন |
| `apptNoSlots` | No slots on this day | এই দিনে কোনো সময় খালি নেই |
| `apptSlotsLeft` | {count, plural, =0{Full} =1{1 seat left} other{{count} seats left}} | {count, plural, =0{পূর্ণ} =1{১টি আসন খালি} other{{count}টি আসন খালি}} |
| `apptSlotTaken` | Someone just took this slot. Pick another. | এই সময়টি এইমাত্র অন্য কেউ নিয়ে নিয়েছেন। অন্য একটি বাছুন। |
| `apptReason` | Reason for visit | কী সমস্যার জন্য আসছেন |
| `apptReasonHint` | e.g. fever for three days | যেমন: তিন দিন ধরে জ্বর |
| `apptConfirmTitle` | Confirm your appointment | আপনার অ্যাপয়েন্টমেন্ট নিশ্চিত করুন |
| `apptConfirmWith` | With {doctor} | {doctor}-এর সঙ্গে |
| `apptConfirmAt` | {date} at {time} | {date}, {time} |
| `apptFee` | Consultation fee | পরামর্শ ফি |
| `apptBooked` | Appointment confirmed. | অ্যাপয়েন্টমেন্ট নিশ্চিত হয়েছে। |
| `apptCancel` | Cancel appointment | অ্যাপয়েন্টমেন্ট বাতিল করুন |
| `apptCancelConfirm` | Cancel this appointment? This cannot be undone. | এই অ্যাপয়েন্টমেন্টটি বাতিল করবেন? এটি আর ফেরানো যাবে না। |
| `apptCancelReason` | Why are you cancelling? | কেন বাতিল করছেন? |
| `apptCancelled` | Appointment cancelled. | অ্যাপয়েন্টমেন্ট বাতিল হয়েছে। |
| `apptCancelTooLate` | This appointment is within {hours, plural, =1{1 hour} other{{hours} hours}} and can no longer be cancelled here. Call the provider. | এই অ্যাপয়েন্টমেন্টের আর {hours, plural, =1{১ ঘণ্টা} other{{hours} ঘণ্টা}} বাকি, তাই এখান থেকে বাতিল করা যাবে না। সেবাদাতাকে কল করুন। |
| `apptReschedule` | Reschedule | সময় পরিবর্তন করুন |
| `apptSerial` | Serial no. | সিরিয়াল নং |
| `apptTokenReady` | Your turn is next. | পরের সিরিয়ালই আপনার। |
| `apptFollowUp` | Follow-up visit | ফলো-আপ ভিজিট |
| `apptPrescription` | Prescription | প্রেসক্রিপশন |
| `apptNoPrescription` | The doctor has not added a prescription yet. | ডাক্তার এখনও প্রেসক্রিপশন যোগ করেননি। |
| `apptReviewPrompt` | How was your visit with {doctor}? | {doctor}-এর কাছে আপনার অভিজ্ঞতা কেমন ছিল? |
| `apptWriteReview` | Write a review | রিভিউ লিখুন |

`apptCancelTooLate` is one sentence with an ICU plural inside it, not "This
appointment is within" + a number + "hours". §9 forbids the second shape and
Bangla is why: the number lands mid-clause in English and takes a classifier
suffix in Bangla, so the fragments cannot be reassembled in either order.

`apptConfirmWith` uses `{doctor}-এর সঙ্গে`. The hyphen before a Bangla case
ending after a name is standard Bangla typography when the name may be in Latin
script ("Dr. Rahman-এর সঙ্গে"), which it will be for a doctor whose row has no
`name_bn`.

#### dir — directory, 22 keys

Covers `app/lib/features/directory/` and the doctor/clinic/hospital/pharmacy
list and detail screens.

| Key | English | বাংলা |
|---|---|---|
| `dirDoctors` | Doctors | ডাক্তার |
| `dirClinics` | Clinics | ক্লিনিক |
| `dirHospitals` | Hospitals | হাসপাতাল |
| `dirPharmacies` | Pharmacies | ফার্মেসি |
| `dirSearchDoctors` | Search doctors, specialities | ডাক্তার বা বিশেষত্ব খুঁজুন |
| `dirSpeciality` | Speciality | বিশেষত্ব |
| `dirAllSpecialities` | All specialities | সব বিশেষত্ব |
| `dirFilterCity` | City | শহর |
| `dirAllCities` | All cities | সব শহর |
| `dirSortBy` | Sort by | সাজান |
| `dirSortRating` | Highest rated | সর্বোচ্চ রেটিং |
| `dirSortFeeLow` | Lowest fee | সবচেয়ে কম ফি |
| `dirSortFeeHigh` | Highest fee | সবচেয়ে বেশি ফি |
| `dirExperience` | {years, plural, =1{1 year experience} other{{years} years experience}} | {years, plural, =1{১ বছরের অভিজ্ঞতা} other{{years} বছরের অভিজ্ঞতা}} |
| `dirReviewCount` | {count, plural, =0{No reviews yet} =1{1 review} other{{count} reviews}} | {count, plural, =0{এখনও কোনো রিভিউ নেই} =1{১টি রিভিউ} other{{count}টি রিভিউ}} |
| `dirRatingNew` | New | নতুন |
| `dirAbout` | About | পরিচিতি |
| `dirServices` | Services | সেবা |
| `dirDepartments` | Departments | বিভাগ |
| `dirFacilities` | Facilities | সুবিধা |
| `dirOpenHours` | Opening hours | খোলার সময় |
| `dirVerified` | Verified | যাচাইকৃত |

`dirRatingNew` replaces the literal `'New'` at
`app/lib/core/utils/formatters.dart:105`, which returns a user-visible English
word from a util class. §5.6 moves that decision out of `Fmt`.

#### pay — payments and receipts, 30 keys

Cross-check every one of these against Part 04. `pay*` keys naming a gateway or
a payment status must use the same vocabulary the payments spec uses, or a
support agent reading a screenshot cannot match it to a row.

| Key | English | বাংলা |
|---|---|---|
| `payTitle` | Payments | পেমেন্ট |
| `payPayNow` | Pay now | এখনই পরিশোধ করুন |
| `payAmountDue` | Amount due | পরিশোধযোগ্য পরিমাণ |
| `payAmountPaid` | Amount paid | পরিশোধিত পরিমাণ |
| `payTotal` | Total | মোট |
| `paySubtotal` | Subtotal | উপমোট |
| `payDeliveryFee` | Delivery charge | ডেলিভারি চার্জ |
| `payMethod` | Payment method | পেমেন্ট মাধ্যম |
| `payMethodBkash` | bKash | বিকাশ |
| `payMethodNagad` | Nagad | নগদ |
| `payMethodRocket` | Rocket | রকেট |
| `payMethodCard` | Card | কার্ড |
| `payMethodCash` | Cash on delivery | ক্যাশ অন ডেলিভারি |
| `payMethodBank` | Bank transfer | ব্যাংক ট্রান্সফার |
| `payTransactionId` | Transaction ID | লেনদেন আইডি |
| `payTransactionIdHint` | The TrxID from your payment SMS | পেমেন্ট এসএমএসে পাওয়া TrxID |
| `payManualInstructions` | Send {amount} to {number}, then enter the transaction ID below. | {number} নম্বরে {amount} পাঠান, তারপর নিচে লেনদেন আইডি লিখুন। |
| `paySubmitted` | Payment submitted. An admin will verify it shortly. | পেমেন্ট জমা হয়েছে। অ্যাডমিন শীঘ্রই যাচাই করবেন। |
| `payVerified` | Payment verified | পেমেন্ট যাচাই হয়েছে |
| `payAwaitingVerification` | Awaiting verification | যাচাইয়ের অপেক্ষায় |
| `payFailed` | Payment failed | পেমেন্ট ব্যর্থ হয়েছে |
| `payFailedHint` | No money was taken. You can try again. | কোনো টাকা কাটা হয়নি। আবার চেষ্টা করতে পারেন। |
| `payCancelled` | Payment cancelled | পেমেন্ট বাতিল হয়েছে |
| `payReceipt` | Receipt | রসিদ |
| `payReceiptNumber` | Receipt no. | রসিদ নং |
| `payDownloadReceipt` | Download receipt | রসিদ ডাউনলোড করুন |
| `payNoReceipt` | A receipt is available once the payment is verified. | পেমেন্ট যাচাই হলে রসিদ পাওয়া যাবে। |
| `payHistory` | Payment history | পেমেন্টের ইতিহাস |
| `payNoHistory` | No payments yet | এখনও কোনো পেমেন্ট নেই |
| `payRefundIssued` | Refunded on {date} | {date} তারিখে ফেরত দেওয়া হয়েছে |

`payMethodBkash` is `বিকাশ` in Bangla and `bKash` in English because the company
brands itself both ways and the Bangla form is what appears on the app a user is
copying the TrxID from. `payTransactionIdHint` keeps `TrxID` in Latin inside the
Bangla string — it is the literal label on the bKash SMS, and translating it
would send the user looking for a field that does not exist.

`payManualInstructions` takes `{amount}` and `{number}` as pre-formatted
`String`s. `{number}` is a merchant phone number and stays in Latin digits per
§5.3.

> The PDF receipt does **not** use these keys. Part 04 §7.3 prints both
> languages stacked on the same page, from a fixed table, regardless of locale.
> Do not swap that for `AppLocalizations`.

#### shop — pharmacy, cart and orders, 34 keys

| Key | English | বাংলা |
|---|---|---|
| `shopTitle` | Pharmacy | ফার্মেসি |
| `shopSearchHint` | Search medicine or brand | ওষুধ বা ব্র্যান্ড খুঁজুন |
| `shopCategories` | Categories | ক্যাটাগরি |
| `shopAddToCart` | Add to cart | কার্টে যোগ করুন |
| `shopAddedToCart` | Added to cart | কার্টে যোগ হয়েছে |
| `shopCart` | Cart | কার্ট |
| `shopCartEmpty` | Your cart is empty | আপনার কার্ট খালি |
| `shopCartEmptyHint` | Browse medicines and add what you need. | ওষুধ দেখে যা দরকার যোগ করুন। |
| `shopCartItems` | {count, plural, =1{1 item} other{{count} items}} | {count, plural, =1{১টি পণ্য} other{{count}টি পণ্য}} |
| `shopQuantity` | Quantity | পরিমাণ |
| `shopRemove` | Remove | সরিয়ে ফেলুন |
| `shopRemoveConfirm` | Remove {product} from your cart? | কার্ট থেকে {product} সরিয়ে ফেলবেন? |
| `shopInStock` | In stock | স্টকে আছে |
| `shopOutOfStock` | Out of stock | স্টকে নেই |
| `shopLowStock` | {count, plural, =1{Only 1 left} other{Only {count} left}} | {count, plural, =1{মাত্র ১টি বাকি} other{মাত্র {count}টি বাকি}} |
| `shopStockChanged` | Stock changed while you were shopping. Check your cart. | আপনি কেনাকাটা করার সময় স্টক বদলে গেছে। কার্ট দেখে নিন। |
| `shopPrescriptionRequired` | Prescription required | প্রেসক্রিপশন লাগবে |
| `shopUploadPrescription` | Upload prescription | প্রেসক্রিপশন আপলোড করুন |
| `shopGenericName` | Generic name | জেনেরিক নাম |
| `shopManufacturer` | Manufacturer | প্রস্তুতকারক |
| `shopCheckout` | Checkout | চেকআউট |
| `shopDeliveryAddress` | Delivery address | ডেলিভারির ঠিকানা |
| `shopDeliveryNotes` | Delivery instructions | ডেলিভারির নির্দেশনা |
| `shopPlaceOrder` | Place order | অর্ডার করুন |
| `shopOrderPlaced` | Order placed. | অর্ডার সম্পন্ন হয়েছে। |
| `shopOrders` | My orders | আমার অর্ডার |
| `shopOrderNumber` | Order no. | অর্ডার নং |
| `shopNoOrders` | No orders yet | এখনও কোনো অর্ডার নেই |
| `shopTrackOrder` | Track order | অর্ডার ট্র্যাক করুন |
| `shopCancelOrder` | Cancel order | অর্ডার বাতিল করুন |
| `shopReorder` | Order again | আবার অর্ডার করুন |
| `shopItemCount` | {count, plural, =1{1 medicine} other{{count} medicines}} | {count, plural, =1{১টি ওষুধ} other{{count}টি ওষুধ}} |
| `shopEstimatedDelivery` | Arrives by {date} | {date}-এর মধ্যে পৌঁছাবে |
| `shopContactPharmacy` | Call pharmacy | ফার্মেসিতে কল করুন |

`shopPlaceOrder` is `অর্ডার করুন` (verb) and `shopOrderNumber` is `অর্ডার নং`
(noun) — the split §3.1 rule 3 warns about, kept as two keys.

#### blood — blood bank, 18 keys

| Key | English | বাংলা |
|---|---|---|
| `bloodTitle` | Blood bank | ব্লাড ব্যাংক |
| `bloodFindDonor` | Find a donor | রক্তদাতা খুঁজুন |
| `bloodRequestTitle` | Request blood | রক্তের জন্য অনুরোধ |
| `bloodGroupNeeded` | Blood group needed | যে গ্রুপের রক্ত দরকার |
| `bloodUnitsNeeded` | {units, plural, =1{1 bag} other{{units} bags}} | {units, plural, =1{১ ব্যাগ} other{{units} ব্যাগ}} |
| `bloodUrgency` | How urgent? | কতটা জরুরি? |
| `bloodUrgencyCritical` | Critical — needed today | অতি জরুরি — আজই দরকার |
| `bloodUrgencyUrgent` | Urgent — within 3 days | জরুরি — ৩ দিনের মধ্যে |
| `bloodUrgencyPlanned` | Planned | পরিকল্পিত |
| `bloodHospitalName` | Hospital name | হাসপাতালের নাম |
| `bloodPatientName` | Patient name | রোগীর নাম |
| `bloodContactNumber` | Contact number | যোগাযোগের নম্বর |
| `bloodRequestPosted` | Your request is live. Donors nearby will see it. | আপনার অনুরোধ প্রকাশিত হয়েছে। কাছের রক্তদাতারা এটি দেখতে পাবেন। |
| `bloodOpenRequests` | Open requests | চলমান অনুরোধ |
| `bloodNoRequests` | No open requests right now | এই মুহূর্তে কোনো চলমান অনুরোধ নেই |
| `bloodIWillDonate` | I can donate | আমি রক্ত দিতে পারি |
| `bloodBanks` | Blood banks | ব্লাড ব্যাংক |
| `bloodDonorLastDonated` | Last donated {relative} | সর্বশেষ রক্ত দিয়েছেন {relative} |

`bloodUnitsNeeded` counts in **bags** (`ব্যাগ`), not units. A Bangladeshi
hospital asks for "two bags of B positive"; "units" is a clinical term nobody
uses at a donor's door.

#### emg — emergency, 12 keys

This screen is public (`app/lib/features/patient/presentation/emergency_screen.dart`)
and is the one place where a wrong translation has physical consequences. Keep
every string short enough to read at a glance.

| Key | English | বাংলা |
|---|---|---|
| `emgTitle` | Emergency | জরুরি সেবা |
| `emgCallNow` | Call now | এখনই কল করুন |
| `emgNational` | National emergency | জাতীয় জরুরি সেবা |
| `emgAmbulance` | Ambulance | অ্যাম্বুলেন্স |
| `emgFire` | Fire service | ফায়ার সার্ভিস |
| `emgPolice` | Police | পুলিশ |
| `emgHospital` | Hospital | হাসপাতাল |
| `emgGeneral` | Other helplines | অন্যান্য হেল্পলাইন |
| `emgCallConfirm` | Call {name} at {number}? | {name} ({number}) নম্বরে কল করবেন? |
| `emgCannotDial` | This device cannot place calls. | এই ডিভাইস থেকে কল করা যাচ্ছে না। |
| `emgShareLocation` | Share my location | আমার অবস্থান পাঠান |
| `emgOffline` | You are offline, but these numbers still dial. | আপনি অফলাইনে আছেন, তবে এই নম্বরগুলোতে কল করা যাবে। |

`emgCallConfirm` puts `{number}` in parentheses in Bangla instead of after "at",
because Bangla has no preposition there and `{number} নম্বরে` would collide with
the `{name}` that must come first for the sentence to scan. The number itself
stays in Latin digits (§5.3) — this is the single strongest case for that rule:
a person reading a phone number aloud in an emergency must read the same digits
that are printed on the ambulance.

#### blog — content, 10 keys

| Key | English | বাংলা |
|---|---|---|
| `blogTitle` | Health articles | স্বাস্থ্য বিষয়ক লেখা |
| `blogReadMore` | Read more | বিস্তারিত পড়ুন |
| `blogBy` | By {author} | লিখেছেন {author} |
| `blogPublished` | Published {date} | প্রকাশিত {date} |
| `blogRelated` | Related articles | সম্পর্কিত লেখা |
| `blogNoArticles` | No articles yet | এখনও কোনো লেখা নেই |
| `blogCategory` | Category | বিভাগ |
| `blogOnlyInEnglish` | This article is available in English only. | এই লেখাটি শুধু ইংরেজিতে পাওয়া যাচ্ছে। |
| `blogAbout` | About AYUR | AYUR সম্পর্কে |
| `blogContact` | Contact us | যোগাযোগ করুন |

`blogOnlyInEnglish` exists because §7's fallback is silent by design everywhere
*except* long-form reading. A one-word service name falling back to English is
invisible; a 1500-word article suddenly being in English is not, and the reader
deserves to be told rather than left thinking the app broke. Show it above the
body when locale is `bn` and `content_bn` is empty. The DB supports the check
directly — `idx_blogs_has_bn` (`spec/01_DATABASE.md:324`) indexes exactly this
predicate.

#### status — enum labels, 20 keys

`app/lib/core/utils/formatters.dart:87` has a `label()` that turns
`out_for_delivery` into `Out For Delivery` by title-casing the enum value. That
is a *translation-shaped hole*: it produces English from data, in a util with no
`BuildContext`. Replace every call site with a lookup on these keys.

| Key | English | বাংলা |
|---|---|---|
| `statusPending` | Pending | অপেক্ষমাণ |
| `statusConfirmed` | Confirmed | নিশ্চিত |
| `statusCompleted` | Completed | সম্পন্ন |
| `statusCancelled` | Cancelled | বাতিল |
| `statusRejected` | Rejected | প্রত্যাখ্যাত |
| `statusApproved` | Approved | অনুমোদিত |
| `statusActive` | Active | সক্রিয় |
| `statusInactive` | Inactive | নিষ্ক্রিয় |
| `statusSuspended` | Suspended | স্থগিত |
| `statusExpired` | Expired | মেয়াদোত্তীর্ণ |
| `statusPaid` | Paid | পরিশোধিত |
| `statusUnpaid` | Unpaid | অপরিশোধিত |
| `statusRefunded` | Refunded | ফেরতকৃত |
| `statusProcessing` | Processing | প্রক্রিয়াধীন |
| `statusPacked` | Packed | প্যাক করা হয়েছে |
| `statusOutForDelivery` | Out for delivery | ডেলিভারির পথে |
| `statusDelivered` | Delivered | পৌঁছে দেওয়া হয়েছে |
| `statusReturned` | Returned | ফেরত এসেছে |
| `statusNoShow` | Did not attend | আসেননি |
| `statusUnknown` | Unknown | অজানা |

Resolve with a switch, in `app/lib/core/l10n/status_labels.dart`:

```dart
String statusLabel(BuildContext context, String? raw) {
  final t = AppLocalizations.of(context);
  switch (raw?.trim().toLowerCase()) {
    case 'pending':            return t.statusPending;
    case 'confirmed':          return t.statusConfirmed;
    case 'completed':          return t.statusCompleted;
    case 'cancelled':
    case 'canceled':           return t.statusCancelled;
    case 'out_for_delivery':   return t.statusOutForDelivery;
    // …one arm per row above…
    default:                   return t.statusUnknown;
  }
}
```

A `default` that returns `statusUnknown` rather than the raw string: a new enum
value added to the database must show a translated placeholder, not leak
`awaiting_courier_pickup` into a Bangla screen.

#### admin — 26 keys

`app/lib/features/admin/` is the biggest single block of hardcoded text in the
app: 14 files, 81 `Text('` literals and 138 labelled parameters. It is also the
lowest-priority migration (§8), because its users are the platform operators.
Translate it anyway — master plan §7 says a Bangla-first user completes *every*
journey, and a Bangladeshi admin is a Bangla-first user.

| Key | English | বাংলা |
|---|---|---|
| `adminTitle` | Admin | অ্যাডমিন |
| `adminDashboard` | Dashboard | ড্যাশবোর্ড |
| `adminUsers` | Users | ব্যবহারকারী |
| `adminProviders` | Providers | সেবাদাতা |
| `adminPendingApprovals` | Pending approvals | অনুমোদনের অপেক্ষায় |
| `adminApprove` | Approve | অনুমোদন করুন |
| `adminReject` | Reject | প্রত্যাখ্যান করুন |
| `adminRejectReason` | Reason for rejection | প্রত্যাখ্যানের কারণ |
| `adminRejectReasonRequired` | Tell the applicant why. They will see this. | আবেদনকারীকে কারণ জানান। তিনি এটি দেখতে পাবেন। |
| `adminApproved` | {name} approved. | {name} অনুমোদিত হয়েছে। |
| `adminRejected` | {name} rejected. | {name} প্রত্যাখ্যাত হয়েছে। |
| `adminSuspend` | Suspend account | অ্যাকাউন্ট স্থগিত করুন |
| `adminSuspendConfirm` | Suspend {name}? They will be signed out and future appointments cancelled. | {name}-কে স্থগিত করবেন? তিনি সাইন আউট হয়ে যাবেন এবং ভবিষ্যতের অ্যাপয়েন্টমেন্ট বাতিল হবে। |
| `adminReactivate` | Reactivate | পুনরায় সক্রিয় করুন |
| `adminVerifyPayment` | Verify payment | পেমেন্ট যাচাই করুন |
| `adminPaymentVerified` | Payment marked verified. | পেমেন্ট যাচাইকৃত হিসেবে চিহ্নিত হয়েছে। |
| `adminRejectPayment` | Reject payment | পেমেন্ট প্রত্যাখ্যান করুন |
| `adminViewDocument` | View document | কাগজ দেখুন |
| `adminHotlines` | Emergency hotlines | জরুরি হেল্পলাইন |
| `adminAddHotline` | Add hotline | হেল্পলাইন যোগ করুন |
| `adminNameBangla` | Name (বাংলা) | নাম (বাংলা) |
| `adminDescriptionBangla` | Description (বাংলা) | বিবরণ (বাংলা) |
| `adminBanglaMissing` | No Bangla version — Bangla users will see the English text. | বাংলা সংস্করণ নেই — বাংলা ব্যবহারকারীরা ইংরেজি লেখাটি দেখবেন। |
| `adminCommission` | Platform commission | প্ল্যাটফর্ম কমিশন |
| `adminTotalRevenue` | Total revenue | মোট আয় |
| `adminExportCsv` | Export CSV | সিএসভি এক্সপোর্ট |

`adminNameBangla` keeps `(বাংলা)` in Bangla script **in the English string too**.
An admin filling the Bangla twin of a hotline name needs to see which field is
which regardless of their own UI language, and `(Bangla)` in Latin next to a
field that must contain Bengali script is a smaller cue than the script itself.

`adminBanglaMissing` is the counterpart to §7's silent fallback: it is the one
place a `_bn` column being empty is a problem someone can fix, so that is the one
place it is surfaced.

#### prov — provider workspace, 20 keys

| Key | English | বাংলা |
|---|---|---|
| `provWorkspace` | Workspace | কর্মক্ষেত্র |
| `provTodaySchedule` | Today's schedule | আজকের সময়সূচি |
| `provNoAppointmentsToday` | No appointments today | আজ কোনো অ্যাপয়েন্টমেন্ট নেই |
| `provPatientCount` | {count, plural, =0{No patients} =1{1 patient} other{{count} patients}} | {count, plural, =0{কোনো রোগী নেই} =1{১ জন রোগী} other{{count} জন রোগী}} |
| `provMarkArrived` | Mark arrived | এসেছেন হিসেবে চিহ্নিত করুন |
| `provMarkCompleted` | Mark completed | সম্পন্ন হিসেবে চিহ্নিত করুন |
| `provAddPrescription` | Add prescription | প্রেসক্রিপশন যোগ করুন |
| `provManageSlots` | Manage time slots | সময়ের স্লট ব্যবস্থাপনা |
| `provAddSlot` | Add slot | স্লট যোগ করুন |
| `provSlotCapacity` | Seats per slot | প্রতি স্লটে আসন |
| `provSlotOverlap` | This overlaps an existing slot. | এটি আগের একটি স্লটের সঙ্গে মিলে যাচ্ছে। |
| `provBlockDate` | Block a day | একটি দিন বন্ধ রাখুন |
| `provBlockDateWarning` | {count, plural, =0{No appointments on this day.} =1{1 patient is booked. They will be notified.} other{{count} patients are booked. They will be notified.}} | {count, plural, =0{এই দিনে কোনো অ্যাপয়েন্টমেন্ট নেই।} =1{১ জন রোগীর বুকিং আছে। তাঁকে জানানো হবে।} other{{count} জন রোগীর বুকিং আছে। তাঁদের জানানো হবে।}} |
| `provEarnings` | Earnings | আয় |
| `provPayouts` | Payouts | পরিশোধ |
| `provProfilePublic` | This is what patients see. | রোগীরা এটিই দেখেন। |
| `provInventory` | Inventory | স্টক |
| `provUpdateStock` | Update stock | স্টক হালনাগাদ করুন |
| `provOrdersToFulfil` | Orders to fulfil | যে অর্ডারগুলো পাঠাতে হবে | 
| `provReviewsAbout` | Reviews about you | আপনার সম্পর্কে রিভিউ |

`provPatientCount` counts people with `জন`, not `টি`. Bangla classifiers are
animacy-marked: `৩টি রোগী` is grammatical the way "3 pieces of patient" is
grammatical in English. Anywhere a count is of humans — patients, donors,
reviewers — the classifier is `জন`.

#### err — errors, 16 keys

Errors are the hardest domain here, because the strings are produced where there
is no `BuildContext`. `app/lib/core/network/supabase_service.dart:86-113` builds
five user-facing English sentences inside a static `guard()`; `ApiException`
carries `message` as a plain `String`.

**Do not add a `BuildContext` to the repository layer.** The fix is that
`ApiException` already carries a `kind` (`ApiErrorKind`), and the widget layer
maps the kind to a key. The English `message` stays as the developer-facing
detail and the log line; the user sees the mapped key.

| Key | English | বাংলা |
|---|---|---|
| `errTitle` | Something went wrong | কিছু একটা ভুল হয়েছে |
| `errNetwork` | No internet connection. | ইন্টারনেট সংযোগ নেই। |
| `errNetworkHint` | Check your connection and try again. | সংযোগ পরীক্ষা করে আবার চেষ্টা করুন। |
| `errTimeout` | The server took too long to respond. | সার্ভার সাড়া দিতে অনেক সময় নিচ্ছে। |
| `errServer` | The server had a problem. Please try again. | সার্ভারে সমস্যা হয়েছে। আবার চেষ্টা করুন। |
| `errUnauthorized` | Please sign in to continue. | চালিয়ে যেতে সাইন ইন করুন। |
| `errForbidden` | You do not have permission to do that. | এটি করার অনুমতি আপনার নেই। |
| `errNotFound` | We could not find that. | এটি খুঁজে পাওয়া যায়নি। |
| `errConflict` | Someone changed this while you were working. Reload and try again. | আপনি কাজ করার সময় অন্য কেউ এটি বদলে দিয়েছেন। রিলোড করে আবার চেষ্টা করুন। |
| `errMalformed` | The app could not read the server's reply. | সার্ভারের উত্তর অ্যাপ পড়তে পারেনি। |
| `errUnknown` | Something went wrong. Please try again. | কিছু একটা ভুল হয়েছে। আবার চেষ্টা করুন। |
| `errOffline` | You are offline. | আপনি অফলাইনে আছেন। |
| `errUploadFailed` | Upload failed. | আপলোড ব্যর্থ হয়েছে। |
| `errFileTooLarge` | That file is too large. Maximum {mb} MB. | ফাইলটি অনেক বড়। সর্বোচ্চ {mb} মেগাবাইট। |
| `errTryAgain` | Try again | আবার চেষ্টা করুন |
| `errContactSupport` | Contact support | সহায়তায় যোগাযোগ করুন |

In `app/lib/core/l10n/error_labels.dart`:

```dart
/// Maps a repository-layer failure to a user-facing sentence.
///
/// The English text inside [ApiException.message] is diagnostic: it is written
/// by supabase_service.dart's `guard()`, which has no BuildContext and must not
/// be given one. This function is the single boundary where a failure becomes
/// something a person reads.
String errorMessage(BuildContext context, Object error) {
  final t = AppLocalizations.of(context);
  if (error is! ApiException) return t.errUnknown;
  switch (error.kind) {
    case ApiErrorKind.network:   return t.errNetwork;
    case ApiErrorKind.malformed: return t.errMalformed;
    case ApiErrorKind.auth:      return t.errUnauthorized;
    case ApiErrorKind.forbidden: return t.errForbidden;
    case ApiErrorKind.notFound:  return t.errNotFound;
    case ApiErrorKind.conflict:  return t.errConflict;
    case ApiErrorKind.server:    return t.errServer;
    case ApiErrorKind.unknown:   return t.errUnknown;
  }
}
```

Read the real `ApiErrorKind` values from
`app/lib/core/network/api_exception.dart` before writing the switch and cover
every one of them without a `default:` — an exhaustive switch on an enum is a
compile error when a case is added, which is the point.

Part 12 §2's `localizeIntegrityError` sits beside this function and handles the
database-constraint messages specifically. Same file, same pattern.

#### val — validation, 14 keys

`app/lib/core/utils/validators.dart` returns English sentences from a
context-free static class (`:10`, `:17`, `:26`, `:36`, `:42`). Validators run
inside `TextFormField.validator`, which **does** have a `BuildContext` in scope
at the call site. Change the signatures to take the `AppLocalizations` instance:

```dart
// Before — validators.dart:22
static String? email(String? v) { … return 'Enter a valid email address.'; }

// After
static String? email(AppLocalizations t, String? v) { … return t.valEmailInvalid; }
```

Passing `AppLocalizations` rather than `BuildContext` keeps `Validators` free of
a Flutter widget dependency and makes it unit-testable with a locale.

| Key | English | বাংলা |
|---|---|---|
| `valRequired` | This field is required. | এই ঘরটি পূরণ করতে হবে। |
| `valRequiredField` | {field} is required. | {field} দিতে হবে। |
| `valNameShort` | Name must be at least 3 characters. | নাম কমপক্ষে ৩ অক্ষরের হতে হবে। |
| `valNameLong` | Name must be under 100 characters. | নাম ১০০ অক্ষরের কম হতে হবে। |
| `valEmailInvalid` | Enter a valid email address. | সঠিক ইমেইল ঠিকানা লিখুন। |
| `valPhoneRequired` | Phone number is required. | ফোন নম্বর দিতে হবে। |
| `valPhoneInvalid` | Enter a valid Bangladeshi mobile number (e.g. 01712345678). | সঠিক বাংলাদেশি মোবাইল নম্বর লিখুন (যেমন: 01712345678)। |
| `valPasswordShort` | Password must be at least 8 characters. | পাসওয়ার্ড কমপক্ষে ৮ অক্ষরের হতে হবে। |
| `valPasswordLetter` | Include at least one letter. | কমপক্ষে একটি অক্ষর রাখুন। |
| `valPasswordNumber` | Include at least one number. | কমপক্ষে একটি সংখ্যা রাখুন। |
| `valPasswordMismatch` | Passwords do not match. | দুটি পাসওয়ার্ড মিলছে না। |
| `valNumberInvalid` | {field} must be a number. | {field} একটি সংখ্যা হতে হবে। |
| `valMinValue` | {field} must be at least {min}. | {field} কমপক্ষে {min} হতে হবে। |
| `valMaxValue` | {field} cannot exceed {max}. | {field} {max}-এর বেশি হতে পারবে না। |

`valPhoneInvalid` keeps the example number `01712345678` in **Latin digits in
the Bangla string**. It is an example of what to type into a field that accepts
Latin digits; rendering it as `০১৭১২৩৪৫৬৭৮` would show the user a string their
keyboard will not produce. This is §5.3's rule appearing inside a translation
rather than inside a formatter.

The catalogue above is roughly 330 keys and does **not** cover everything: the
415 labelled parameters and 250 `Text('` literals will surface more as §8's
migration walks the screens. That is expected. The catalogue is the spine —
every domain has a prefix, every shared word has a home, and a new key has an
obvious place to go rather than being invented ad hoc as `title2`.

---

## 4. Runtime language switching

Master plan §7: runtime switch, no restart, persisted per user in
`users.preferred_language` so it follows them across devices. Two storage
locations, because they answer different questions:

| Store | Answers | Available |
|---|---|---|
| `SharedPreferences` | what language did *this device* last show | before login, offline, on the first frame |
| `users.preferred_language` | what language does *this person* want | only when signed in, only online |

Local is the source of truth for **rendering** — it is synchronous and available
at `main()` time, so the first frame is already in the right language. Server is
the source of truth for **the account**, and is read once at sign-in to seed
local. A signed-in user switching language writes both.

### 4.1 `PrefsStore` gains a locale

`app/lib/core/storage/prefs_store.dart` already has this exact shape for
`ThemeMode` (`:37-56`). Follow it — including the swallowed exceptions, which
exist because `PrefsStore.open()` is awaited before `runApp` and a throw there
means a blank dead page (`:20-26`).

```dart
  static const String _kLocale = 'preferred_language';

  /// Null means "never chosen" — which is what makes the first-run picker
  /// (§4.5) distinguishable from a user who deliberately chose English.
  String? get languageCode {
    final v = _prefs?.getString(_kLocale);
    return (v == 'en' || v == 'bn') ? v : null;
  }

  Future<void> setLanguageCode(String code) async {
    try {
      await _prefs?.setString(_kLocale, code);
    } catch (_) {
      // Not remembered next launch; the session still switches.
    }
  }
```

The getter validates against the two supported codes rather than returning
whatever string is stored. A stale `'ar'` from a future build must fall back to
the device locale, not construct a `Locale('ar')` that has no delegate and
renders the template English with Arabic date formats.

### 4.2 The provider

New file, `app/lib/core/locale_controller.dart`, sibling of the existing
`app/lib/core/theme_controller.dart` and deliberately shaped like it.

```dart
/// UI language, persisted twice: locally so the first frame is correct before
/// any network call, and to `users.preferred_language` so the choice follows
/// the account to another device (master plan §7).
///
/// Lives in core/ rather than features/settings/ for the same reason
/// theme_controller.dart does: app.dart needs it, and core must not depend on
/// features.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'storage/prefs_store.dart';

/// The only locales with delegates. Anything else falls back to English.
const List<Locale> kSupportedLocales = [Locale('en'), Locale('bn')];

class LocaleController extends StateNotifier<Locale> {
  LocaleController(this._prefs, this._ref) : super(_initial(_prefs));

  final PrefsStore _prefs;
  final Ref _ref;

  /// Resolution order: stored choice, then device locale, then English.
  ///
  /// Synchronous by necessity — this runs while building the first frame, and
  /// an async read here would flash an English UI at a Bangla user, which is
  /// the same bug prefs_store.dart:19 already avoids for the theme.
  static Locale _initial(PrefsStore prefs) {
    final stored = prefs.languageCode;
    if (stored != null) return Locale(stored);

    // PlatformDispatcher, not View.of(context): there is no context yet.
    for (final l in WidgetsBinding.instance.platformDispatcher.locales) {
      if (l.languageCode == 'bn') return const Locale('bn');
      if (l.languageCode == 'en') return const Locale('en');
    }
    return const Locale('en');
  }

  bool get isBangla => state.languageCode == 'bn';

  /// Applies immediately, persists locally, then pushes to the server.
  ///
  /// The order matters. State first so the UI turns over on the same frame as
  /// the tap; local write next because it cannot fail in a way that matters;
  /// the server write last and unawaited-by-the-UI, because a user on a bad
  /// connection must not watch a spinner to change their language.
  Future<void> set(Locale locale) async {
    if (locale.languageCode == state.languageCode) return;
    if (!kSupportedLocales.any((l) => l.languageCode == locale.languageCode)) {
      return;
    }

    state = locale;
    await _prefs.setLanguageCode(locale.languageCode);
    await _pushToServer(locale.languageCode);
  }

  Future<void> toggle() =>
      set(isBangla ? const Locale('en') : const Locale('bn'));

  /// Best-effort. A failure here means the choice is device-local until the
  /// next successful write; it must never surface as an error dialog and must
  /// never revert the UI the user just changed.
  Future<void> _pushToServer(String code) async {
    final sb = _ref.read(supabaseServiceProvider);
    final id = sb.currentUserId;
    if (id == null) return; // Not signed in — local is the whole story.
    try {
      await sb.db('users').update({'preferred_language': code}).eq('id', id);
    } catch (_) {
      // Offline, RLS, anything. The language still changed.
    }
  }

  /// Called once after a successful sign-in, with the value from the user row.
  ///
  /// Only applies when the device has no stored choice. A user who set Bangla
  /// on this phone must not be flipped to English because an old account row
  /// still says 'en' — the device choice is the more recent intent.
  Future<void> adoptServerPreference(String? code) async {
    if (_prefs.languageCode != null) return;
    if (code != 'en' && code != 'bn') return;
    state = Locale(code!);
    await _prefs.setLanguageCode(code);
  }
}

final localeProvider =
    StateNotifierProvider<LocaleController, Locale>((ref) {
  return LocaleController(ref.watch(prefsStoreProvider), ref);
});
```

`adoptServerPreference` taking the value as a parameter rather than querying for
it keeps `LocaleController` off the auth path. The caller is
`auth_controller.dart`, which already has the fresh user row.

### 4.3 The finished `app/lib/app/app.dart`

The current file is 27 lines and passes no delegates. Replace it whole:

```dart
/// The MaterialApp. Thin by design — routing lives in router.dart, theming in
/// app_theme.dart and language in locale_controller.dart, so this file only
/// wires them together.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_config.dart';
import '../core/constants/app_theme.dart';
import '../core/locale_controller.dart';
import '../core/theme_controller.dart';
import '../l10n/gen/app_localizations.dart';
import 'router.dart';

class AyurApp extends ConsumerWidget {
  const AyurApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ref.watch(themeModeProvider),

      // Watched, not read: this is what makes the switch take effect on the
      // same frame as the tap, with no restart. Changing `locale` rebuilds
      // every descendant that called AppLocalizations.of(context).
      locale: ref.watch(localeProvider),
      supportedLocales: kSupportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        // Material's own strings: date picker headers, "Select all", the
        // calendar's month names. Without these three a bn locale gets a
        // Bangla app with an English date picker inside it — and on some
        // Flutter versions, a hard assertion instead.
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],

      routerConfig: ref.watch(routerProvider),
    );
  }
}
```

`table_calendar: ^3.1.2` (`app/pubspec.yaml:35`) renders the booking calendar
and reads `GlobalMaterialLocalizations` for its month and weekday names, so the
delegate list above is what makes the appointment date picker say `জানুয়ারি`.
Flutter ships Bangla (`bn`) in `flutter_localizations`; nothing extra is needed.

### 4.4 Seeding from the account at sign-in

`app/lib/features/auth/data/auth_repository.dart:287-289` selects a fixed column
list into `_profileColumns`. Add `preferred_language` to it:

```dart
  static const _profileColumns =
      'id, name, email, phone, address, city, profile_image, blood_group, '
      'role, gender, preferred_language, created_at';
```

Add the field to `AppUser` (`app/lib/models/app_user.dart:55`) alongside the
other nullable strings, read it in `fromJson` with the existing `Fmt.str`
pattern (`:104-119`), and write it in `toJson` (`:124`) so a restored session
carries it.

Then in `AuthController.login` (`auth_controller.dart:98`), after the state is
set:

```dart
      state = AuthState(status: AuthStatus.authenticated, user: user);
      // Server preference seeds the device only when the device has none.
      await _ref
          .read(localeProvider.notifier)
          .adoptServerPreference(user.preferredLanguage);
```

Same two lines in `restore()` (`:74`) and after `register()` (`:142`). Not in
`_refreshProfile()` (`:89`) — that runs on resume, and a resume must not change
the language under a user mid-session.

### 4.5 Where the toggle lives

**Settings, permanently.** `app/lib/features/auth/presentation/profile_screen.dart`
already has a `_PreferencesCard` (`:239`) holding the theme `SegmentedButton`
(`:255-278`). Language goes in the same card, directly above Appearance,
following the identical pattern — `ref.watch(localeProvider)` for the value and
`ref.watch(localeProvider.notifier)` for the controller, both lines, for the
reason the existing comment at `:244-245` gives.

```dart
            Text(t.commonLanguage, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                // NOT translated: each option is written in its own language.
                // A Bangla speaker looking for Bangla scans for "বাংলা", and
                // showing them "Bangla" in Latin when the UI is English is the
                // one case where translating the label makes it harder to find.
                ButtonSegment(value: 'en', label: Text('English')),
                ButtonSegment(value: 'bn', label: Text('বাংলা')),
              ],
              selected: {locale.languageCode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => controller.set(Locale(s.first)),
            ),
```

That endonym rule is why the two segment labels are the only user-facing strings
in the app that stay out of the ARB files. Every language picker worth using
does this.

**First run, once.** A user who has never chosen sees the device locale (§4.2
`_initial`), which for a Bangladeshi phone set to Bangla is already correct — so
the picker is not a gate, it is a confirmation. Put it on the splash route
(`app/lib/app/router.dart:283`), shown only when
`prefs.languageCode == null`, as a two-button sheet reading:

```
আপনার ভাষা / Your language
[ বাংলা ]   [ English ]
```

Bilingual by construction, because at that moment the app does not yet know
which language the user reads. `PrefsStore.seenIntro` (`:58`) already exists as
a first-run flag, but **do not reuse it** — a user who dismissed an intro in an
earlier build has still never chosen a language, and `languageCode == null` is
the precise question.

### 4.6 What "no restart" actually requires

`MaterialApp.locale` changing rebuilds the tree, and any widget that called
`AppLocalizations.of(context)` in `build()` picks up the new strings. Three
things break that, and all three are real risks in this codebase:

1. **A string captured in a `State` field or an `initState()`.** It is read once
   and never again. Read localised strings in `build()`, always.
2. **A `const` widget holding a literal.** `const Text('Save')` is not merely
   unlocalised, it is un-rebuildable. §8's grep catches these.
3. **A cached `DateFormat` built with a fixed locale at construction time.** §6
   handles this by resolving the locale per call rather than per instance.

---

## 5. Bangla numerals

Master plan §7 requires ০১২৩৪৫৬৭৮৯ for "dates, times, money and counts when
locale is `bn`". That is a rule with a sharp edge, and the edge is the subject of
§5.3.

### 5.1 Why not just let `intl` do it

`NumberFormat(pattern, 'bn')` may or may not emit Bengali digits depending on
whether the bundled CLDR symbol table for `bn` carries a `zeroDigit` override in
the exact `intl` version resolved (`0.19.0`, `app/pubspec.lock:362`). That is a
dependency-version question, and the answer changes silently on an upgrade.

More importantly, `intl` cannot help at all with the strings this app builds by
hand: `Fmt.relative` (`app/lib/core/utils/formatters.dart:72-82`) concatenates
`'${diff.inDays}d ago'`, and `Fmt.time` (`:53`) assembles from split parts.
Those digits never pass through a `NumberFormat`.

So the conversion is an explicit, testable transliteration applied **after**
formatting, and `NumberFormat` keeps its `'en_US'` locale for grouping and
decimals. One mechanism, deterministic, one unit test.

```bash
# Confirm the assumption rather than trusting it, once, in a scratch test:
cd app && flutter test test/localization/numerals_test.dart
```

### 5.2 Grouping stays Western

`Fmt.money` uses `'#,##0'` / `'#,##0.00'` (`formatters.dart:18`). Keep those
patterns for both locales. Bangladesh does count in লাখ and কোটি, and the Indic
grouping `#,##,##0` is not wrong — but the two systems produce identical output
below 100,000, and every amount this app renders is a consultation fee, a
medicine order or a payout. Changing the grouping would alter nothing a user
sees while adding a second money format for receipts to disagree about.

If a payout report ever needs Indic grouping, change the pattern in one place
(`L10nFormat._pattern`) and only there.

### 5.3 What stays in Latin digits, and why

**Numerals are localised. Phone numbers, transaction IDs, order numbers, receipt
numbers and NIDs are not.**

| Value | Locale `bn` renders | Reason |
|---|---|---|
| Money | ৳১,২৫০ | read, not transcribed |
| Counts, quantities | ৩টি ওষুধ | read, not transcribed |
| Dates, times | ১২ আগস্ট, বিকেল ৩:৩০ | read, not transcribed |
| Ratings | ৪.৫ | read, not transcribed |
| Percentages | ২০% | read, not transcribed |
| **Phone numbers** | **01712345678** | **gets dialled** |
| **Transaction IDs** | **BKA7X2M91** | **typed in from an SMS** |
| **Order / receipt numbers** | **ORD-2026-00418** | **quoted to support, filed** |
| **NID / licence numbers** | **1990123456789** | **matched against a document** |

The rule behind the table: **a number a person reads gets Bangla numerals; a
number a person transcribes stays Latin.** Three concrete failures if you get it
wrong:

- A dial pad has Latin digits. Rendering a hotline as `০১৭...` in the emergency
  screen means a user in a crisis is transliterating in their head.
- A bKash TrxID arrives by SMS in Latin and is typed into a Latin-only field.
  Showing it back as `বিকেএ৭এক্স২এম৯১` makes it unverifiable.
- An order number is read aloud to a support agent and searched in an admin
  console whose database column holds Latin. Two representations of one
  identifier is a support incident.

Part 04 §7.3 already reaches the same conclusion independently for printed
receipts ("Amounts print in Western digits… a printed financial figure is read
by banks and by software"). This section extends it to identifiers on screen and
narrows it: on-screen *money* is localised, on-screen *identifiers* are not.

`app/lib/core/constants/app_config.dart:152` (`currency = '৳'`) and `:153`
(`currencyCode = 'BDT'`) stay exactly as they are. `৳` is correct in both
locales.

### 5.4 The helper

New file, `app/lib/core/l10n/l10n_format.dart`. This is the locale-aware
counterpart to `Fmt`; `Fmt` stays and keeps doing the locale-independent work
(parsing, coercion, `apiDate`), because 115 files call it and R3 freezes nothing
about it but rewriting it would be gratuitous.

```dart
/// Locale-aware display formatting.
///
/// [Fmt] stays the context-free layer: parsing, coercion, and the wire formats
/// that must never change shape (`Fmt.apiDate`). This class is everything whose
/// output depends on which language is showing.
///
/// Obtain one with `context.fmt` (see the extension at the bottom) rather than
/// constructing it — the extension reads the active locale, so a widget can
/// never format with a stale one.
library;

import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../constants/app_config.dart';
import '../utils/formatters.dart';

class L10nFormat {
  const L10nFormat(this.languageCode);

  final String languageCode;

  bool get isBangla => languageCode == 'bn';

  // -- digits ---------------------------------------------------------------

  static const List<String> _bengaliDigits =
      ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];

  /// Transliterates ASCII 0-9 in [s] and leaves everything else — separators,
  /// the taka sign, letters, the AM/PM marker — untouched.
  ///
  /// Applied AFTER NumberFormat/DateFormat, never instead of them: grouping,
  /// decimal placement and month names are still CLDR's job.
  static String toBengaliDigits(String s) {
    if (s.isEmpty) return s;
    final out = StringBuffer();
    for (final unit in s.codeUnits) {
      // 0x30..0x39 is ASCII '0'..'9'.
      if (unit >= 0x30 && unit <= 0x39) {
        out.write(_bengaliDigits[unit - 0x30]);
      } else {
        out.writeCharCode(unit);
      }
    }
    return out.toString();
  }

  /// The single gate. Every method below funnels through it, so localising a
  /// new kind of value is one call and never a second copy of the digit map.
  String _digits(String s) => isBangla ? toBengaliDigits(s) : s;

  /// Explicit opt-OUT for values that must stay transcribable (section 5.3).
  ///
  /// Exists as a named method rather than "just don't call _digits" so that a
  /// reader of a widget can see the decision was made, and so a grep for
  /// `keepLatin` enumerates every identifier surface in the app.
  String keepLatin(Object? value) => Fmt.str(value, '—');
```


```dart
  // -- money ----------------------------------------------------------------

  /// `৳1,250` / `৳১,২৫০`; paisa shown only when non-zero.
  ///
  /// Mirrors Fmt.money's paisa rule (formatters.dart:17-19) deliberately: two
  /// money formats that disagree about trailing zeros is exactly the drift this
  /// class exists to prevent.
  String money(Object? amount) {
    final v = Fmt.toDouble(amount);
    final hasPaisa = (v * 100).round() % 100 != 0;
    final pattern = hasPaisa ? '#,##0.00' : '#,##0';
    // 'en_US' on purpose — grouping and decimal separators stay Western
    // (section 5.2). Only the glyphs change, and _digits does that.
    final formatted = NumberFormat(pattern, 'en_US').format(v);
    return '${AppConfig.currency}${_digits(formatted)}';
  }

  /// Money without the sign, for a column that carries `৳` in its header.
  String amount(Object? value) =>
      _digits(NumberFormat('#,##0.00', 'en_US').format(Fmt.toDouble(value)));

  // -- plain numbers --------------------------------------------------------

  String number(Object? value) =>
      _digits(NumberFormat('#,##0', 'en_US').format(Fmt.toInt(value)));

  /// `20%` / `২০%`. The sign is `%` in both locales — Bangla uses it.
  String percent(Object? value) => '${_digits(Fmt.toInt(value).toString())}%';

  /// `4.5` / `৪.৫`, and the "New" case delegated to the caller.
  ///
  /// Returns null for an unrated provider instead of the English literal
  /// 'New' that Fmt.rating hardcodes (formatters.dart:105). The widget shows
  /// `t.dirRatingNew` when this is null — a util class must not decide what
  /// language a word is in.
  String? rating(Object? value) {
    final v = Fmt.toDouble(value);
    return v <= 0 ? null : _digits(v.toStringAsFixed(1));
  }

  // -- dates and times ------------------------------------------------------

  /// The intl locale tag. `bn_BD`, not bare `bn`: Bangladesh and West Bengal
  /// share the language and differ on conventions, and this app is Bangladeshi.
  String get intlLocale => isBangla ? 'bn_BD' : 'en_US';

  /// `12 Aug 2026` / `১২ আগস্ট ২০২৬`
  String dayMonth(Object? value) {
    final d = Fmt.date(value);
    if (d == null) return '—';
    return _digits(DateFormat('d MMM yyyy', intlLocale).format(d));
  }

  /// `Wed, 12 Aug 2026` / `বুধ, ১২ আগস্ট ২০২৬`
  String dayFull(Object? value) {
    final d = Fmt.date(value);
    if (d == null) return '—';
    return _digits(DateFormat('EEE, d MMM yyyy', intlLocale).format(d));
  }

  /// `12 Aug 2026, 3:30 PM` / `১২ আগস্ট ২০২৬, বিকেল ৩:৩০`
  String dateTime(Object? value) {
    final d = Fmt.date(value);
    if (d == null) return '—';
    return '${dayMonth(d)}, ${time(d)}';
  }

  /// `3:30 PM` / `বিকেল ৩:৩০`.
  ///
  /// Accepts what the API actually sends for a slot — `HH:MM:SS` — as well as a
  /// DateTime, matching Fmt.time (formatters.dart:53-66) so no call site has to
  /// change shape during the migration.
  String time(Object? value) {
    final d = _asTime(value);
    if (d == null) return '—';
    if (!isBangla) return DateFormat('h:mm a', 'en_US').format(d);
    // Bangla puts the day-part BEFORE the clock time and names four of them
    // rather than two. See section 6.2.
    final clock = _digits(DateFormat('h:mm', 'en_US').format(d));
    return '${banglaDayPart(d.hour)} $clock';
  }

  static DateTime? _asTime(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    final parsed = Fmt.date(s);
    if (parsed != null) return parsed;
    final parts = s.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h != null && m != null) return DateTime(2000, 1, 1, h, m);
    }
    return null;
  }

  /// Bangla names four parts of the day, and using only দুপুর/রাত as AM/PM
  /// substitutes produces `রাত ৮:০০` for 8pm — which reads as "night 8", when
  /// a Bangladeshi says সন্ধ্যা ৮টা.
  static String banglaDayPart(int hour24) {
    if (hour24 < 4) return 'রাত';      // 12am-4am
    if (hour24 < 6) return 'ভোর';      // 4am-6am
    if (hour24 < 12) return 'সকাল';    // 6am-12pm
    if (hour24 < 16) return 'দুপুর';   // 12pm-4pm
    if (hour24 < 18) return 'বিকেল';   // 4pm-6pm
    if (hour24 < 20) return 'সন্ধ্যা'; // 6pm-8pm
    return 'রাত';                      // 8pm-12am
  }
}

/// `context.fmt.money(x)` — the only way widgets should reach this class.
///
/// Reads the locale from the widget tree, which MaterialApp.locale drives
/// (section 4.3), so a formatter can never outlive the locale it was built for.
extension L10nFormatX on BuildContext {
  L10nFormat get fmt =>
      L10nFormat(Localizations.localeOf(this).languageCode);
}
```

`Localizations.localeOf(context)` rather than `ref.read(localeProvider)`: the
extension then works in any widget without a `WidgetRef`, and it reads the locale
that is actually rendering rather than the one the provider holds — identical in
practice, but the widget tree is the authority during a rebuild.

### 5.5 Relative time

`Fmt.relative` (`formatters.dart:72-82`) returns `'just now'`, `'2h ago'`,
`'3d ago'` — English assembled from fragments, which §9 forbids. It cannot be
fixed inside `Fmt` because the replacement needs ARB keys.

Add to the catalogue (§3.3), domain `common`:

| Key | English | বাংলা |
|---|---|---|
| `timeJustNow` | just now | এইমাত্র |
| `timeMinutesAgo` | {count, plural, =1{1 minute ago} other{{count} minutes ago}} | {count, plural, =1{১ মিনিট আগে} other{{count} মিনিট আগে}} |
| `timeHoursAgo` | {count, plural, =1{1 hour ago} other{{count} hours ago}} | {count, plural, =1{১ ঘণ্টা আগে} other{{count} ঘণ্টা আগে}} |
| `timeDaysAgo` | {count, plural, =1{yesterday} other{{count} days ago}} | {count, plural, =1{গতকাল} other{{count} দিন আগে}} |
| `timeInMinutes` | {count, plural, =1{in 1 minute} other{in {count} minutes}} | {count, plural, =1{১ মিনিটে} other{{count} মিনিটে}} |
| `timeInHours` | {count, plural, =1{in 1 hour} other{in {count} hours}} | {count, plural, =1{১ ঘণ্টায়} other{{count} ঘণ্টায়} } |
| `timeToday` | Today | আজ |
| `timeTomorrow` | Tomorrow | আগামীকাল |
| `timeYesterday` | Yesterday | গতকাল |

`timeDaysAgo` with `=1` giving `yesterday` / `গতকাল` rather than "1 day ago":
both languages have the word, and a notification list that says "1 day ago" when
it means yesterday reads like a machine.

In `app/lib/core/l10n/relative_time.dart`:

```dart
/// Replaces Fmt.relative (formatters.dart:72), which built English by
/// concatenation. Past and future are separate branches because Bangla marks
/// them with different case endings, not with a leading word.
String relativeTime(BuildContext context, Object? value) {
  final t = AppLocalizations.of(context);
  final d = Fmt.date(value);
  if (d == null) return '';

  final diff = DateTime.now().difference(d);

  if (diff.isNegative) {
    final ahead = diff.abs();
    if (ahead.inMinutes < 1) return t.timeJustNow;
    if (ahead.inMinutes < 60) return t.timeInMinutes(ahead.inMinutes);
    if (ahead.inHours < 24) return t.timeInHours(ahead.inHours);
    return context.fmt.dayMonth(d);
  }

  if (diff.inMinutes < 1) return t.timeJustNow;
  if (diff.inMinutes < 60) return t.timeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return t.timeHoursAgo(diff.inHours);
  if (diff.inDays < 7) return t.timeDaysAgo(diff.inDays);
  return context.fmt.dayMonth(d);
}
```

The `isNegative` branch is not hypothetical: `Fmt.relative:76` handles it by
falling back to a date, which is why an upcoming appointment currently shows a
date where a relative time was intended. Numbers passed to an ICU plural are
converted to Bangla digits by `gen_l10n`'s own `NumberFormat` — it formats the
placeholder with the message's locale, so `{count}` inside `app_bn.arb` needs no
`_digits` call. Verify this on the first plural you wire up; if the digits come
out Latin, wrap the argument with `L10nFormat.toBengaliDigits` at the call site
rather than changing the ARB.

<!--CONT-->

