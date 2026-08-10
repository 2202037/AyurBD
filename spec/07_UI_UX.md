# Part 07 — UI/UX Foundation

**Phase 6 in master plan §5. Do not start this file until Part 06 (localization)
is executed**, because §4 of that part is what lets every widget written here be
bilingual on its first write, and because the Hind Siliguri font this part wires
into the theme is downloaded and declared there.

This part is unusual among the spec files: **the design system already exists and
is already good.** The audit below was run against the real repository on
2026-08-10, and it found a palette that was measured rather than guessed, a
theme-aware semantic colour set, and a state-view family. Your job is not to
design a new one. Your job is to (a) fix the four concrete defects listed in
§0.2, (b) fill the gaps that were never built — Bangla typography, a four-state
wrapper for `AsyncValue`, skeletons, accessibility semantics, offline handling —
and (c) make adoption universal instead of partial.

> **The governing rule for this part.** Every value in
> `app/lib/core/constants/app_colors.dart` is the output of a contrast fit.
> Changing one "to brighten it slightly" is how a palette acquires invisible
> text. If you change a colour, re-run the arithmetic in §1.5 and update the
> table. If you cannot re-run it, do not change the colour.

---

## 0. Audit — what exists, verified by inspection

### 0.1 Files that make up the current design system

| File | Lines | What it holds |
|---|---:|---|
| `app/lib/core/constants/app_colors.dart` | 342 | `AppColors` brand + surface tokens, `AppSemantic` theme-aware set, `forStatus`, `statusIcon` |
| `app/lib/core/constants/app_theme.dart` | 303 | `AppTheme.light()` / `AppTheme.dark()`, one shared `_build`, 14 component themes |
| `app/lib/core/widgets/state_views.dart` | 440 | `LoadingView`, `EmptyView`, `ErrorView`, `StatusPill`, `RemoteImage`, `AvatarCircle`, `SectionHeader`, `BlockingOverlay`, `showToast` |
| `app/lib/core/widgets/paged_list_view.dart` | 157 | `PagedListView` — already renders five list states |
| `app/lib/core/theme_controller.dart` | 44 | `ThemeModeController`, `themeModeProvider` |
| `app/lib/core/storage/prefs_store.dart` | 67 | theme mode persisted to `SharedPreferences` |
| `app/lib/features/home/presentation/patient_shell.dart` | 70 | the five-tab patient `NavigationBar` |
| `app/lib/app/router.dart` | 781 | `Routes`, the shell, `_guard` |

Two things follow from this table and they are worth stating plainly, because the
brief for this part assumed otherwise:

- **Dark mode is already built and already wired.** `app/lib/app/app.dart:21-23`
  passes `AppTheme.light()`, `AppTheme.dark()` and
  `ref.watch(themeModeProvider)` to `MaterialApp.router`. The toggle exists in
  three places. §2 does not build dark mode; it fixes what is missing around it.
- **The three async state views already exist and are used 50 times.** §5 does
  not replace them; it wraps them so the *fourth* state stops being optional.

### 0.2 The four real defects

Each is a specific, reproducible failure, not a preference.

**D-A — No `fontFamily` is set, so every Bangla string is a risk of tofu.**
`_build` in `app/lib/core/constants/app_theme.dart:137` returns
`base.copyWith(...)` and never sets `fontFamily`. Flutter falls back to Roboto,
which has no Bengali glyphs. Part 06 §2 explains why "it looked fine on my
phone" is not evidence. This is the single highest-value line in this part.

**D-B — Line heights are tuned for Latin.**
`_textTheme` (`app/lib/core/constants/app_theme.dart:287-302`) sets body copy to
`height: 1.55` and `titleLarge` to `1.3`. Bangla needs more, and it needs
*different amounts at different sizes*. §3 explains the mechanism and gives the
replacement.

**C — Three interactive targets are below 48 dp.**
`SectionHeader`'s action button sets `minimumSize: Size.zero` with
`tapTargetSize: MaterialTapTargetSize.shrinkWrap`
(`app/lib/core/widgets/state_views.dart:365-369`); `_Footer`'s retry button is
40 dp (`app/lib/core/widgets/paged_list_view.dart:132-135`); `AppTheme.rowAction`
is 40 dp (`app/lib/core/constants/app_theme.dart:27-31`). §7 fixes all three
without changing how they look.

**D-D — The shared widgets contain hardcoded English, which breaks R4.**
`ErrorView` hardcodes three sentences
(`app/lib/core/widgets/state_views.dart:120`, `:139`); `StatusPill._pretty`
(`:212-219`) *generates* an English label from a raw database enum;
`BlockingOverlay` hardcodes `'Please wait…'` (`:409`); `PagedListView` hardcodes
four more (`:23`, `:124`, `:130`, `:148`, the last with English pluralisation and
Latin digits). Every one of these is inside a widget used on dozens of screens,
so each is a bilingual failure repeated dozens of times. §5.6 lists the exact
replacements.

### 0.3 What is genuinely absent

| Gap | Consequence today | Section |
|---|---|---|
| No `AsyncValueView` wrapper | 15 screens hand-write `.when()`; the empty state is left to each one, so R5 is honoured by convention rather than by construction | §5 |
| No skeleton loaders | Every first load is a centred spinner, which reads as "frozen" on a 3G connection | §4.9 |
| No `Semantics` widget anywhere (`grep -rn "Semantics(" app/lib` → 0 results) | Icon-only buttons are unlabelled to TalkBack | §7 |
| No connectivity detection (`grep -rn -i connectivity app/lib` → 0 results) | The app cannot distinguish "you are offline" from "the server is broken" | §9 |
| No text-scale handling | 200% scaling is untested; several fixed-height rows will overflow | §7.3 |
| Theme mode not persisted to the user row | Preference does not follow the user to a second device | §2.3 |

---

## 1. Design language and the colour system

### 1.1 The intent, stated once

The user asked for "colors and interface which is good for human eye and feel
comfortable". That is a testable requirement, not a vague one, and the existing
palette already answers it in two specific ways which you must preserve:

**Nothing sits at maximum contrast.** Pure black on pure white measures about
17:1. That is far past AAA and lands in halation territory, where glyph edges
appear to bleed — worst for readers with astigmatism, and worst of all for
light-on-dark. Body text in this app measures 10.2–13.3:1: comfortably AAA, none
of the glare. Do not "fix" `lightText` to `#000000`.

**Surfaces carry a faint green tint rather than being neutral grey.** `#F7FAF8`
against `#FFFFFF` is a two-point shift, invisible as a colour and clearly felt as
a reduction in glare across a full phone screen. It also does quiet brand work:
the whole interface sits in the same hue family as the primary, which is what
makes a teal button look native rather than applied.

**Deep teal as primary is the right call for this product and it stays.**
`#17736A` is simultaneously the healthcare convention (Cleveland Clinic, Mayo,
MyChart, Doctolib, NHS) and a botanical note that suits Ayurvedic medicine. One
colour doing both jobs is why there is no need for a second brand colour.

### 1.2 Reconciliation with `app_colors.dart` — keep, change, add

This is the explicit answer to "say which existing values you keep and which you
change and why". **Every existing colour value is kept unchanged.** The audit
recomputed all 60 foreground/background pairs (§1.5) and found no failure.

| Token | Value | Decision | Reason |
|---|---|---|---|
| `primary` | `#17736A` | keep | 5.23:1 on page, 5.68:1 white-on-fill. Both pass AA. |
| `primaryHover` | `#0E4A45` | keep | Pressed/emphasis tone, 9.28:1. |
| `secondary` | `#3168B0` | keep | Blue for informational, distinct from teal in hue and in luminance. |
| `accent` | `#9E550D` | keep | The one restrained accent — burnt amber. Used for ratings and "urgent". |
| `success` `danger` `warning` `info` | as-is | keep | All land 5.14–5.28:1 on the page surface. |
| `light*` surfaces (7 tokens) | as-is | keep | Tinted neutrals, measured. |
| `dark*` surfaces (7 tokens) | as-is | keep | `darkBg #101613` is deliberately not `#000000`. |
| `dark*` semantic variants (8 tokens) | as-is | keep | Exist because one fixed colour cannot clear 4.5:1 on both themes. |
| — | — | **add** `AppColors.skeleton` / `darkSkeleton` | §4.9 needs a shimmer base that is not a semantic colour. |
| — | — | **add** `AppSemantic.offline` | §9 needs a distinct "no connection" tone that is not `danger` — being offline is not an error. |

Two additions, zero changes. Add them to `AppColors` beside the existing surface
tokens, and to `AppSemantic` as a computed getter:

```dart
// In AppColors, after the dark surface block:
/// Skeleton placeholder base. Deliberately a *surface* value, not a semantic
/// one: a shimmering block must read as "content is coming", and a tinted
/// success/danger/warning block reads as a status.
static const Color lightSkeleton = Color(0xFFE7F0EB); // == lightBgMuted
static const Color darkSkeleton  = Color(0xFF1F2A25); // == darkBgMuted

// In AppSemantic, beside tintAlpha:
/// "No connection" is not a failure of the app or the user, so it must not be
/// red. Amber-neutral, and paired with an icon per §7.4.
Color get offline => isDark ? AppColors.darkWarning : AppColors.warning;

/// Shimmer highlight sweep. 6% in light, 9% in dark — dark surfaces need a
/// heavier sweep for the motion to be perceptible at all.
double get skeletonSweepAlpha => isDark ? 0.09 : 0.06;
```

### 1.3 The complete light palette

| Role | Hex | Where it is used |
|---|---|---|
| `primary` | `#17736A` | Filled buttons, links, focus ring, selected tab, progress |
| `primaryHover` | `#0E4A45` | `primaryContainer`, pressed state |
| `secondary` | `#3168B0` | Informational chips, unknown-status fallback |
| `accent` (tertiary) | `#9E550D` | Star ratings, "urgent" priority |
| `success` | `#127834` | confirmed / completed / paid / verified / delivered |
| `danger` (error) | `#C2302B` | cancelled / rejected / failed / refunded, destructive buttons |
| `warning` | `#875F03` | pending / pending_payment / processing / shipped / expired |
| `info` | `#116F8C` | "low" priority, neutral notices |
| `lightBg` | `#F7FAF8` | Cards, app bar, dialogs, nav bar (the *raised* surface) |
| `lightBgAlt` | `#F1F7F4` | Scaffold background (the *page*) |
| `lightBgMuted` | `#E7F0EB` | Text-field fill, `surfaceContainerHigh(est)` |
| `lightBorder` | `#BCCFC6` | Dividers, card edges — decorative only |
| `lightBorderStrong` | `#647870` | Control outlines: text fields, checkboxes |
| `lightText` | `#2C3A35` | `onSurface` |
| `lightTextMuted` | `#4F615A` | `onSurfaceVariant`, captions, disabled-looking labels |
| `onFilled` | `#FFFFFF` | Text on a filled semantic colour |

Note the inversion that is easy to get wrong: **in light mode the page is the
*darker* of the two and cards are the *lighter*.** `_build` handles this at
`app/lib/core/constants/app_theme.dart:104-105`. Raised things must be lighter
than what is behind them or they read as holes.

### 1.4 The complete dark palette

| Role | Hex | Note |
|---|---|---|
| `darkPrimary` | `#5CC4B8` | Luminous teal — the light `#17736A` measures 1.6:1 on dark and is unusable |
| `darkPrimaryHover` | `#7BD6CB` | |
| `darkSecondary` | `#8FB8E5` | |
| `darkAccent` | `#E8A33D` | |
| `darkSuccess` | `#5FBE78` | |
| `darkDanger` | `#E8827A` | |
| `darkWarning` | `#D3A625` | |
| `darkInfo` | `#5EBAD3` | |
| `darkBg` | `#101613` | Page. **Not `#000000`** — see below |
| `darkBgAlt` | `#171F1B` | Cards, app bar, dialogs, nav bar |
| `darkBgMuted` | `#1F2A25` | Field fill |
| `darkBorder` | `#374840` | Decorative |
| `darkBorderStrong` | `#748880` | Control outlines |
| `darkText` | `#D4DEDA` | **Not `#FFFFFF`** |
| `darkTextMuted` | `#9CADA5` | |
| `onFilled` | `#0B0F0D` | Near-black on the luminous dark fills |

**Why no pure black and no pure white text.** `#FFFFFF` on `#000000` is 21:1.
On an OLED panel in a dark room that is a light source with letter-shaped holes
in it; the pupil dilates for the black field and is then over-exposed by the
glyphs, which is what produces the smearing readers report when scrolling.
`#D4DEDA` on `#101613` is 13.31:1 — still AAA at every size, with the glare
removed. Pure black also breaks the elevation model: if the page is `#000000`
there is no darker tone available, so a modal scrim has nowhere to go.

The dark surfaces step **up** in lightness with elevation: page `#101613` →
card/app-bar `#171F1B` → field/hover `#1F2A25`. This is the M3 rule and the
opposite of the light theme, and `_build` already implements it
(`app/lib/core/constants/app_theme.dart:104-105`).

### 1.5 WCAG contrast — computed ratios

Computed with the WCAG 2.1 relative-luminance formula
(`L = 0.2126R + 0.7152G + 0.0722B` on linearised sRGB;
`ratio = (L_lighter + 0.05) / (L_darker + 0.05)`). Thresholds: **4.5:1** for body
text, **3:1** for text ≥18.66 px bold or ≥24 px, and for the boundary of any
control (WCAG 1.4.11).

**Light theme — foreground against the three surfaces**

| Foreground | on page `#F1F7F4` | on card `#F7FAF8` | on field `#E7F0EB` | Verdict |
|---|---:|---:|---:|---|
| `lightText #2C3A35` | 10.97 | 11.33 | 10.24 | AAA |
| `lightTextMuted #4F615A` | 6.07 | 6.26 | 5.66 | AAA (normal text) |
| `primary #17736A` | 5.23 | 5.41 | 4.89 | AA |
| `primaryHover #0E4A45` | 9.28 | 9.59 | 8.67 | AAA |
| `secondary #3168B0` | 5.18 | 5.35 | 4.83 | AA |
| `accent #9E550D` | 5.15 | 5.32 | 4.80 | AA |
| `success #127834` | 5.14 | 5.31 | 4.80 | AA |
| `danger #C2302B` | 5.16 | 5.33 | 4.81 | AA |
| `warning #875F03` | 5.28 | 5.45 | 4.92 | AA |
| `info #116F8C` | 5.26 | 5.44 | 4.91 | AA |

Every light semantic colour clears 4.5:1 on all three surfaces with roughly
0.3 of headroom. That tight clustering is not an accident — it is what "fitted to
a compromise band" in the header comment of `app_colors.dart` means. It is also
why §7.4 insists on an icon: colours forced into the same luminance band differ
only in hue, and hue is the channel a colour-blind reader cannot use.

**Dark theme — foreground against the three surfaces**

| Foreground | on page `#101613` | on card `#171F1B` | on field `#1F2A25` | Verdict |
|---|---:|---:|---:|---|
| `darkText #D4DEDA` | 13.31 | 12.23 | 10.78 | AAA |
| `darkTextMuted #9CADA5` | 7.79 | 7.16 | 6.31 | AAA |
| `darkPrimary #5CC4B8` | 8.76 | 8.05 | 7.09 | AAA |
| `darkPrimaryHover #7BD6CB` | 10.75 | 9.87 | 8.70 | AAA |
| `darkSecondary #8FB8E5` | 8.86 | 8.14 | 7.17 | AAA |
| `darkAccent #E8A33D` | 8.50 | 7.80 | 6.88 | AAA |
| `darkSuccess #5FBE78` | 7.96 | 7.31 | 6.44 | AAA |
| `darkDanger #E8827A` | 6.90 | 6.33 | 5.58 | AAA |
| `darkWarning #D3A625` | 8.07 | 7.41 | 6.53 | AAA |
| `darkInfo #5EBAD3` | 8.24 | 7.56 | 6.67 | AAA |

**Text on a filled colour** — `AppSemantic.onFilled`
(`app/lib/core/constants/app_colors.dart:251`)

| Fill | Light: `#FFFFFF` on it | Fill | Dark: `#0B0F0D` on it |
|---|---:|---|---:|
| `primary` | 5.68 | `darkPrimary` | 9.23 |
| `primaryHover` | 10.08 | `darkPrimaryHover` | 11.32 |
| `secondary` | 5.62 | `darkSecondary` | 9.33 |
| `accent` | 5.59 | `darkAccent` | 8.95 |
| `success` | 5.58 | `darkSuccess` | 8.38 |
| `danger` | 5.60 | `darkDanger` | 7.26 |
| `warning` | 5.72 | `darkWarning` | 8.50 |
| `info` | 5.71 | `darkInfo` | 8.67 |

This table is the reason `AppTheme.destructive(context)`
(`app/lib/core/constants/app_theme.dart:42-48`) sets background *and* foreground
together. Overriding only the background on a dialog's delete button leaves the
foreground coming from the theme, and the two themes want opposite foregrounds.

**Status pill: label colour on its own 8% / 18% tint** — the hardest case,
because a tint pulls the background toward the very colour being drawn on it.

| Status colour | Light, pill on card | Light, pill on page | Dark, pill on card | Dark, pill on page |
|---|---:|---:|---:|---:|
| `primary` | 4.84 | 4.69 | 5.60 | 6.24 |
| `secondary` | 4.79 | 4.68 | 5.61 | 6.27 |
| `accent` | 4.78 | 4.62 | 5.51 | 6.14 |
| `success` | 4.77 | 4.62 | 5.19 | 5.80 |
| `danger` | 4.73 | 4.57 | 4.72 | 5.24 |
| `warning` | 4.90 | 4.75 | 5.32 | 5.87 |
| `info` | 4.88 | 4.72 | 5.35 | 5.90 |

The worst case is `danger` on a dark card at 4.72:1 — still AA, with 0.22 of
headroom. **This is why `tintAlpha` is capped at 0.08 / 0.18**
(`app/lib/core/constants/app_colors.dart:243`). Raising the dark value to 0.22
drops `danger` to roughly 4.3:1 and fails every cancelled-appointment pill in the
app at once. Do not raise it.

**Control boundaries (WCAG 1.4.11, needs 3:1)**

| Pair | Ratio | Verdict |
|---|---:|---|
| `lightBorderStrong #647870` vs field `#E7F0EB` | 4.05 | pass |
| `lightBorderStrong` vs page `#F1F7F4` | 4.34 | pass |
| `darkBorderStrong #748880` vs field `#1F2A25` | 3.94 | pass |
| `darkBorderStrong` vs card `#171F1B` | 4.47 | pass |
| `lightBorder #BCCFC6` vs card `#F7FAF8` | 1.55 | decorative only — **must never outline a control** |
| `darkBorder #374840` vs card `#171F1B` | 1.73 | decorative only |

The two-weight border split is load-bearing. `inputDecorationTheme` already uses
`borderStrong` for field outlines (`app/lib/core/constants/app_theme.dart:186-193`)
and `dividerTheme` uses `border` (`:142`). Keep that separation: a card outlined
at 4:1 turns a dense list into a spreadsheet, and a text field outlined at 1.5:1
is invisible.

### 1.6 The Material 3 `ColorScheme` — complete, both brightnesses

`_build` currently constructs `ColorScheme` with 18 roles
(`app/lib/core/constants/app_theme.dart:107-133`). Flutter fills the remainder by
falling back to the roles you did supply, which is safe but coarse: the biggest
visible consequence is that `SegmentedButton` — used for the theme picker at
`app/lib/features/auth/presentation/profile_screen.dart:260-278` — takes its
selected background from `secondaryContainer`, which currently resolves to the
full-strength blue `#3168B0`. A selected segment therefore paints a saturated
blue block inside a teal app.

Replace the `ColorScheme` literal with the complete one below. Every added role
is derived from a token that already exists, so nothing new needs measuring.

Extract it into its own method so `_build` stays readable, and call it from
`_build` where the literal is now:

```dart
  /// The full Material 3 role set for one brightness.
  ///
  /// Both brightnesses come through here; the difference is entirely in the
  /// [sem] set and the surface arguments, which is what keeps the two themes
  /// from drifting apart the way two hand-written schemes always do.
  static ColorScheme _scheme({
    required Brightness brightness,
    required AppSemantic sem,
    required Color pageBg,
    required Color raised,
    required Color lowest,
    required Color bgMuted,
    required Color text,
    required Color textMuted,
    required Color border,
    required Color borderStrong,
  }) {
    // An opaque low-emphasis fill for the `*Container` roles, produced by the
    // same tint arithmetic StatusPill uses — so a tonal button and a pill of the
    // same colour share one background rather than two that nearly match.
    //
    // alphaBlend, not withValues(alpha:): a ColorScheme role has to be opaque.
    // A translucent role composites against whatever happens to be behind the
    // widget, so the same "container" would render differently on a card than on
    // the page, and its measured contrast would stop being a fixed number.
    Color container(Color c) =>
        Color.alphaBlend(c.withValues(alpha: sem.tintAlpha), raised);

    return ColorScheme(
      brightness: brightness,

      primary: sem.primary,
      onPrimary: sem.onFilled,
      // Was `sem.primaryHover` with `onFilled` on top. That is a *higher*
      // emphasis than primary, which inverts what M3 means by a container: a
      // tonal button rendered darker than a filled one. The tint is the correct
      // low-emphasis fill, and the label on it measures 4.84:1 (§1.5).
      primaryContainer: container(sem.primary),
      onPrimaryContainer: sem.primary,

      secondary: sem.secondary,
      onSecondary: sem.onFilled,
      // Pinning this is the fix for the SegmentedButton described above.
      secondaryContainer: container(sem.secondary),
      onSecondaryContainer: sem.secondary,

      tertiary: sem.accent,
      onTertiary: sem.onFilled,
      tertiaryContainer: container(sem.accent),
      onTertiaryContainer: sem.accent,

      error: sem.danger,
      onError: sem.onFilled,
      errorContainer: container(sem.danger),
      onErrorContainer: sem.danger,

      surface: pageBg,
      onSurface: text,
      onSurfaceVariant: textMuted,

      // The six-step surface ramp. In light mode the page is the deeper tone and
      // raised things are paler; in dark mode it is the other way round. See the
      // note in _build.
      surfaceDim: brightness == Brightness.light ? bgMuted : lowest,
      surfaceBright: brightness == Brightness.light ? raised : bgMuted,
      surfaceContainerLowest: lowest,
      surfaceContainerLow: raised,
      surfaceContainer: raised,
      surfaceContainerHigh: bgMuted,
      surfaceContainerHighest: bgMuted,

      // M3 splits these deliberately: `outline` is for control boundaries
      // (field outlines, checkbox edges) and `outlineVariant` for decorative
      // rules. Matching that split is what lets a divider stay quiet while a
      // text field stays findable. Ratios in §1.5.
      outline: borderStrong,
      outlineVariant: border,

      // Snackbars and tooltips default to the inverse surface. Without these
      // they fall back to onSurface/surface, which produces a tooltip that is
      // the same colour as the card it is floating over.
      inverseSurface: text,
      onInverseSurface: pageBg,
      inversePrimary: sem.primaryHover,

      shadow: const Color(0xFF000000),
      // The modal scrim. 100% black at the widget's own opacity; a tinted scrim
      // shifts the hue of everything behind it, which looks like a rendering
      // fault rather than a dim.
      scrim: const Color(0xFF000000),

      // Every component theme below sets surfaceTintColor: Colors.transparent,
      // because M3's elevation tint fights a hand-fitted palette: it lightens a
      // card toward primary by an amount that depends on elevation, so a
      // measured 4.77:1 becomes an unmeasured something-else. surfaceTint is
      // still set correctly here for any widget that reaches for it directly.
      surfaceTint: sem.primary,
    );
  }
```

The `*Fixed` roles (`primaryFixed`, `onPrimaryFixedVariant`, …) are deliberately
omitted. They exist so a brand colour can stay identical across light and dark,
which is the opposite of what this palette does on purpose, and no Material
widget in this app consumes them.

Wire it in. Replace lines 107–133 of
`app/lib/core/constants/app_theme.dart` with:

```dart
    final scheme = _scheme(
      brightness: brightness,
      sem: sem,
      pageBg: pageBg,
      raised: raised,
      // The deepest tone available. In light mode that is the palest card
      // colour; in dark mode it is the page itself, because there is nothing
      // below it — which is precisely why darkBg is not #000000 (§1.4).
      lowest: isLight ? bg : bg,
      bgMuted: bgMuted,
      text: text,
      textMuted: textMuted,
      border: border,
      borderStrong: borderStrong,
    );
```

`lowest: isLight ? bg : bg` looks redundant and is kept verbatim from the existing
`surfaceContainerLowest` line (`:121`) on purpose: it documents that the answer
happens to be the same token in both themes for different reasons, and collapsing
it to `bg` invites someone to "simplify" it into `pageBg` later.

---

## 2. Dark mode

### 2.1 What is already true

Do not build this from scratch. Verified:

| Piece | Location | State |
|---|---|---|
| `themeMode` on `MaterialApp.router` | `app/lib/app/app.dart:23` | done |
| `ThemeModeController` with `set` / `cycle` / `icon` / `label` | `app/lib/core/theme_controller.dart:11-40` | done |
| Persisted to `SharedPreferences` | `app/lib/core/storage/prefs_store.dart:37-56` | done |
| Read **synchronously before the first frame** | `app/lib/core/storage/prefs_store.dart:27-35`, awaited in `main()` | done — this is what prevents a light-theme flash for a dark-mode user |
| Failure-tolerant store (`PrefsStore(null)` fallback) | `prefs_store.dart:32-34` | done |
| No pure black, no pure white text | §1.4 | done |
| Elevated dark surfaces step up in lightness | `app_theme.dart:104-105` | done |

### 2.2 Where the toggle lives — three places, all deliberate

| Surface | Location | Control |
|---|---|---|
| Patient profile / account | `app/lib/features/auth/presentation/profile_screen.dart:238-290` | three-way `SegmentedButton`: System / Light / Dark |
| Provider and admin app bars | `app/lib/features/provider/presentation/widgets/workspace_actions.dart:79-85` | overflow-menu item that calls `cycle()` |
| Patient home app bar | `app/lib/features/home/presentation/home_screen.dart:66-67` | icon button that calls `cycle()` |

Keep all three. The `SegmentedButton` is the canonical control because it is the
only one that makes "System" discoverable — `cycle()` alone gives no clue that a
third option exists. The two icon affordances are shortcuts, which is why they
cycle rather than set.

One required change: `cycle()` is `system → light → dark → system`
(`theme_controller.dart:23-27`). Keep that order, but the icon button must carry a
tooltip and a semantic label per §7.2, because an icon that changes meaning on
every tap is unreadable to a screen-reader user without one.

### 2.3 The gap: persist to the user row as well as locally

Master plan §7 requires the *language* preference to follow the user across
devices via `users.preferred_language`. The same argument applies to theme, and
neither column exists yet:

```bash
# Both return nothing. Verified 2026-08-10.
grep -rn "preferred_language" supabase/migrations/
grep -rn "theme_mode" supabase/migrations/
```

> **Dependency, state it in the log if it is unmet.** `users.preferred_language`
> is Part 06's migration to write. This part adds `users.theme_mode` in the same
> migration. If Part 06 has not yet added its column, add both here; if it has,
> add only `theme_mode`. **Do not create a second migration that re-adds
> `preferred_language`** — `add column if not exists` makes that harmless but it
> muddies the history.

```sql
-- supabase/migrations/<timestamp>_user_ui_preferences.sql
--
-- Two nullable preference columns. Nullable, not defaulted, because NULL has a
-- distinct meaning here: "this user has never expressed a preference", which is
-- what makes the device value authoritative on first sign-in instead of being
-- overwritten by a server default the user never chose.
alter table public.users
  add column if not exists theme_mode text;

alter table public.users
  drop constraint if exists users_theme_mode_check;
alter table public.users
  add constraint users_theme_mode_check
  check (theme_mode is null or theme_mode in ('system', 'light', 'dark'));

comment on column public.users.theme_mode is
  'UI theme preference: system | light | dark. NULL means never set, in which '
  'case the device preference wins. Mirrors ThemeMode.name in Dart.';
```

The values are exactly `ThemeMode.name`, so no mapping table is needed and
`prefs_store.dart:52` already writes the same strings.

### 2.4 The provider — complete replacement for `core/theme_controller.dart`

Three rules drive this code and each one exists because the naive version gets it
wrong.

1. **Local write first, remote write after, and never await the remote write on
   the UI path.** A theme tap must repaint on the next frame whether or not the
   phone has signal. The remote write is fire-and-forget with its failure
   swallowed, exactly as `PrefsStore` already swallows its own.
2. **The remote value only wins at sign-in, and only when the local store has
   never been written.** Otherwise a user who set Dark on this phone would have
   it yanked back to Light by a stale row from a tablet they used once.
3. **Never write the remote value while restoring from it**, or the restore
   echoes back as a change and two devices can ping-pong.

```dart
/// Theme mode, persisted twice: locally so the first frame is correct, and to
/// `users.theme_mode` so the choice follows the account to a second device.
///
/// Small enough to live in one file rather than a feature folder — it has no
/// models and its only API surface is a single column write.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'network/supabase_service.dart';
import 'providers.dart';
import 'storage/prefs_store.dart';

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._prefs, this._ref) : super(_prefs.themeMode);

  final PrefsStore _prefs;
  final Ref _ref;

  /// Guards rule 3: set while [adoptRemote] is applying a server value, so the
  /// resulting state change is not echoed back to the server.
  bool _restoring = false;

  Future<void> set(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;

    // Local first and awaited: it cannot fail (PrefsStore swallows), it is
    // microseconds, and it is what makes the next cold start correct.
    await _prefs.setThemeMode(mode);

    if (_restoring) return;
    // Remote second and NOT awaited. A theme tap on a train in a tunnel must
    // still repaint. `unawaited` is expressed as an ignored future rather than
    // an import of dart:async for one call.
    // ignore: discarded_futures
    _pushRemote(mode);
  }

  /// Best-effort mirror to `users.theme_mode`.
  ///
  /// Silent on every failure, including "not signed in". This is a preference,
  /// not data the user typed; surfacing a snackbar for it would train people to
  /// dismiss snackbars.
  Future<void> _pushRemote(ThemeMode mode) async {
    try {
      final uid = SupabaseService.client.auth.currentUser?.id;
      if (uid == null) return;
      await SupabaseService.client
          .from('users')
          .update({'theme_mode': mode.name})
          .eq('id', uid);
    } catch (_) {
      // Preference not mirrored. The device still has it.
    }
  }

  /// Called once by the auth controller immediately after a successful sign-in,
  /// with whatever `users.theme_mode` held (null when the user never set one).
  ///
  /// [deviceHasPreference] must be `PrefsStore.hasThemePreference` — see rule 2.
  /// Without it, "the server says light" overrides a deliberate local choice on
  /// every single sign-in.
  Future<void> adoptRemote(String? remote, {required bool deviceHasPreference}) async {
    if (remote == null || deviceHasPreference) return;
    final mode = switch (remote) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => null,
    };
    if (mode == null || mode == state) return;

    _restoring = true;
    try {
      await set(mode);
    } finally {
      _restoring = false;
    }
  }

  /// What the toolbar button does: system → light → dark → system.
  Future<void> cycle() => set(switch (state) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      });

  IconData get icon => switch (state) {
        ThemeMode.system => Icons.brightness_auto_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };

  /// Localized at the call site, not here: a StateNotifier has no BuildContext
  /// and must not acquire one. Callers map [state] through AppLocalizations —
  /// see §3.4 for the key names.
  ThemeMode get mode => state;
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  return ThemeModeController(ref.watch(prefsStoreProvider), ref);
});
```

**The `label` getter is deliberately deleted.** It returned the hardcoded English
strings `'System theme'` / `'Light theme'` / `'Dark theme'`
(`app/lib/core/theme_controller.dart:35-39`), which R4 forbids after Phase 5.
Two call sites must change:

| Call site | Was | Becomes |
|---|---|---|
| `app/lib/features/auth/presentation/profile_screen.dart:284` | `controller.label` | `l10n.themeLabel(mode)` helper in §3.4 |
| `app/lib/features/provider/presentation/widgets/workspace_actions.dart:83` | `title: Text(themeCtl.label)` | same helper |

Add the companion flag to `PrefsStore` (`app/lib/core/storage/prefs_store.dart`),
beside the existing `themeMode` getter:

```dart
  /// True once the user has chosen a theme on *this* device.
  ///
  /// Distinct from `themeMode != ThemeMode.system`: choosing "System" is itself
  /// a choice, and must not be treated as "no preference" or a stale server row
  /// would overwrite it on the next sign-in.
  bool get hasThemePreference => _prefs?.getString(_kThemeMode) != null;
```

Finally, the auth controller calls `adoptRemote` after a successful sign-in. It
already fetches the user row, so pass the new column through — no extra round
trip:

```dart
// In AuthController, immediately after the AppUser is built on sign-in:
await ref.read(themeModeProvider.notifier).adoptRemote(
      row['theme_mode'] as String?,
      deviceHasPreference: ref.read(prefsStoreProvider).hasThemePreference,
    );
```

`AppUser` (`app/lib/models/app_user.dart`) is **not** extended with a
`themeMode` field. It is a presentation-layer preference read once at sign-in,
not account data, and adding it would mean touching `fromJson`, `toJson`,
`copyWith` and `copyWithActive` for a value nothing else reads.

---

## 3. Typography, and why Bangla changes the numbers

### 3.1 The font

Part 06 §2.2 settles this: **Hind Siliguri for the UI, Noto Sans Bengali for
PDFs.** This part does one thing with that decision — actually applies it, which
Part 06 never does because `app_theme.dart` is out of its scope.

In `_build`, add `fontFamily` to the returned theme:

```dart
    return base.copyWith(
      colorScheme: scheme,
      // Declared in pubspec.yaml by Part 06 §2.4. Without this line every Bangla
      // string falls back to Roboto, which has no Bengali glyphs, and renders as
      // □□□□. It appears to work on an Android device that happens to ship a
      // Bengali system font, which is what makes the bug ship.
      fontFamily: 'HindSiliguri',
      // Latin digits, Bangla digits and ৳ all come from the same family, so a
      // price never mixes two typefaces mid-string.
      fontFamilyFallback: const ['HindSiliguri'],
      scaffoldBackgroundColor: pageBg,
      // ... rest unchanged
```

`ThemeData(brightness:)` at `app/lib/core/constants/app_theme.dart:135` builds
the base *before* this, so `base.textTheme` still carries Roboto metrics.
`copyWith(fontFamily:)` overrides the family on every style in the theme, which
is what you want; the per-style `height` values in §3.3 are applied on top.

**Verification that actually proves it.** "I switched to Bangla and it looked
fine" does not, per Part 06 §2.1. Do this instead:

```dart
// test/theme_font_test.dart
test('every text style resolves to HindSiliguri', () {
  for (final theme in [AppTheme.light(), AppTheme.dark()]) {
    expect(theme.textTheme.bodyMedium!.fontFamily, 'HindSiliguri');
    expect(theme.textTheme.titleLarge!.fontFamily, 'HindSiliguri');
    expect(theme.appBarTheme.titleTextStyle!.fontFamily, 'HindSiliguri');
  }
});
```

Note the third assertion. `appBarTheme.titleTextStyle` is constructed explicitly
at `app/lib/core/constants/app_theme.dart:150-155` and therefore **does not
inherit `fontFamily` from `copyWith`** — a `TextStyle` built by hand has a null
family and resolves to the platform default. It needs the family named on it, and
so do the three other hand-built styles in that file: `chipTheme.labelStyle`
(`:246`), `chipTheme.secondaryLabelStyle` (`:247`), and the two button
`textStyle`s (`:227`, `:236`). Five styles. Miss one and exactly one widget in the
app renders Bangla as boxes, which is the hardest kind of bug to notice.

<!--CONT-->