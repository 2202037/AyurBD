/// Brand tokens — §9.
///
/// These are tuned for a healthcare product read for long stretches, often on a
/// phone at arm's length, sometimes by tired or older eyes. Two rules drive every
/// value here, and both are measured, not guessed:
///
/// 1. **Nothing sits at maximum contrast.** Pure black text on pure white is
///    ~17:1 and pure-white-on-near-black about 16:1 — the old palette did both.
///    Both are far past AAA (7:1) and land in halation territory, where glyph
///    edges appear to glow and bleed; worst for readers with astigmatism, and
///    worst of all light-on-dark. Body text here runs 10.2–13.3:1: comfortably
///    AAA, none of the glare. Surfaces carry a very slight green tint rather
///    than being neutral grey, which suits a botanical-medicine product and
///    takes the hard edge off large pale areas.
///
/// 2. **Colour is never the only signal.** Status colours pair with a text label
///    *and* a shape glyph (see [AppColors.statusIcon]), so red/green confusion —
///    roughly 8% of men — never costs the user information.
///
/// ## Why there are two sets of semantic colours
///
/// A single fixed colour *cannot* be legible on both a light and a dark surface.
/// For 4.5:1 against this light surface a colour needs relative luminance ≤0.151;
/// for 4.5:1 against this dark surface it needs ≥0.209. Those are contradictory.
/// That is exactly why the old `warning` (#EAB308) measured 1.92:1 on white —
/// effectively invisible — while scoring 9.87:1 on dark.
///
/// So the constants below are fitted to a deliberate compromise band: ≥4.5:1 on
/// every light surface (legal for body text) **and** ≥3:1 on the dark background
/// (legal for icons, large text and UI boundaries). That keeps every existing
/// call site readable in both themes with no edit. Where a colour carries small
/// text — status pills above all — resolve it through [AppSemantic.of] instead,
/// which swaps in the dark-tuned variants and reaches 4.5:1 on dark too.
///
/// Adjusting anything here means re-running the contrast check. Every value is
/// the output of a fit; "brightening one slightly" is how the old palette ended
/// up with invisible text.
library;

import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  // -- Brand ---------------------------------------------------------------
  // Teal primary: the healthcare convention (Cleveland Clinic, Mayo, MyChart,
  // Doctolib, NHS), and it doubles as the Ayurvedic botanical note.
  static const Color primary = Color(0xFF17736A);
  static const Color primaryHover = Color(0xFF0E4A45);
  static const Color secondary = Color(0xFF3168B0);
  static const Color accent = Color(0xFF9E550D);

  // -- Semantic ------------------------------------------------------------
  static const Color success = Color(0xFF127834);
  static const Color danger = Color(0xFFC2302B);
  static const Color warning = Color(0xFF875F03);
  static const Color info = Color(0xFF116F8C);

  // Borders come in two weights, and the distinction is not cosmetic.
  //
  // `*Border` is decorative: card edges, dividers, table rules. It only has to
  // be *seen*, so it sits ~1.4–1.9:1 from the surfaces it separates. Pushing it
  // higher turns every card into a boxed-in outline and makes a dense list look
  // like a spreadsheet.
  //
  // `*BorderStrong` is the outline of an interactive control — a text field, a
  // dropdown, a checkbox. WCAG 1.4.11 asks for 3:1 against the adjacent colour
  // for anything needed to identify a control, and a form field whose edge is
  // invisible is a real usability failure in an app where people type dosages
  // and phone numbers. These measure ≥3:1 against the field fill itself
  // (bgMuted), not just against the page.
  //
  // -- Light surfaces ------------------------------------------------------
  static const Color lightBg = Color(0xFFF7FAF8);
  static const Color lightBgAlt = Color(0xFFF1F7F4);
  static const Color lightBgMuted = Color(0xFFE7F0EB);
  static const Color lightBorder = Color(0xFFBCCFC6);
  static const Color lightBorderStrong = Color(0xFF647870);
  static const Color lightText = Color(0xFF2C3A35);
  static const Color lightTextMuted = Color(0xFF4F615A);

  // -- Dark surfaces -------------------------------------------------------
  // Not pure black: a black panel next to light glyphs maximises halation and
  // makes smearing visible when scrolling. #101613 keeps contrast in the
  // comfortable band while still reading as a true dark theme.
  static const Color darkBg = Color(0xFF101613);
  static const Color darkBgAlt = Color(0xFF171F1B);
  static const Color darkBgMuted = Color(0xFF1F2A25);
  static const Color darkBorder = Color(0xFF374840);
  static const Color darkBorderStrong = Color(0xFF748880);
  static const Color darkText = Color(0xFFD4DEDA);
  static const Color darkTextMuted = Color(0xFF9CADA5);

  // -- Dark-mode semantic variants -----------------------------------------
  // Reach these through [AppSemantic.of] rather than directly, so a widget does
  // not have to know which theme it is in.
  static const Color darkPrimary = Color(0xFF5CC4B8);
  static const Color darkPrimaryHover = Color(0xFF7BD6CB);
  static const Color darkSecondary = Color(0xFF8FB8E5);
  static const Color darkAccent = Color(0xFFE8A33D);
  static const Color darkSuccess = Color(0xFF5FBE78);
  static const Color darkDanger = Color(0xFFE8827A);
  static const Color darkWarning = Color(0xFFD3A625);
  static const Color darkInfo = Color(0xFF5EBAD3);

  /// Status pill colours, shared by appointments, orders and payments so the
  /// same word never renders in two different colours across the app.
  ///
  /// The vocabulary here is the union of several real database enums, which do
  /// not agree with each other:
  ///   appointments.status          pending confirmed completed cancelled
  ///                                expired
  ///   appointments.payment_status  pending paid refunded
  ///   payments.payment_status      pending verified rejected
  ///   orders.status                pending confirmed processing shipped
  ///                                delivered cancelled
  ///   blood_requests.status        active fulfilled cancelled
  ///   *.verification_status        pending verified rejected
  /// Anything not listed falls through to [secondary] rather than guessing.
  ///
  /// This returns the light-mode value. Inside a widget prefer
  /// `AppSemantic.of(context).forStatus(...)`, which picks the variant that
  /// suits the active theme.
  static Color forStatus(String status) => AppSemantic.light.forStatus(status);

  /// The shape half of the status signal. Colour alone fails red/green colour
  /// blindness, so every pill carries one of these alongside its label.
  static IconData statusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'confirmed':
      case 'completed':
      case 'paid':
      case 'verified':
      case 'delivered':
      case 'fulfilled':
      case 'available':
      case 'active':
      case 'published':
        return Icons.check_circle_outline_rounded;
      case 'pending':
      case 'pending_payment':
      case 'processing':
      case 'shipped':
      case 'draft':
      case 'new':
      case 'in_progress':
        return Icons.schedule_rounded;
      case 'cancelled':
      case 'canceled':
      case 'failed':
      case 'rejected':
      case 'refunded':
      case 'unavailable':
      case 'inactive':
      case 'banned':
        return Icons.cancel_outlined;
      case 'expired':
        return Icons.timer_off_outlined;
      case 'critical':
        return Icons.priority_high_rounded;
      case 'high':
      case 'urgent':
        return Icons.keyboard_double_arrow_up_rounded;
      case 'low':
        return Icons.keyboard_arrow_down_rounded;
      default:
        return Icons.circle_outlined;
    }
  }
}

/// Theme-aware semantic colours.
///
/// Use `AppSemantic.of(context)` wherever a semantic colour is drawn as **text
/// or a small icon**, because those need the full 4.5:1 and no single constant
/// can deliver that on both themes. Large filled surfaces can keep using the
/// [AppColors] constants directly.
@immutable
class AppSemantic {
  const AppSemantic({
    required this.brightness,
    required this.primary,
    required this.primaryHover,
    required this.secondary,
    required this.accent,
    required this.success,
    required this.danger,
    required this.warning,
    required this.info,
  });

  final Brightness brightness;
  final Color primary;
  final Color primaryHover;
  final Color secondary;
  final Color accent;
  final Color success;
  final Color danger;
  final Color warning;
  final Color info;

  static const AppSemantic light = AppSemantic(
    brightness: Brightness.light,
    primary: AppColors.primary,
    primaryHover: AppColors.primaryHover,
    secondary: AppColors.secondary,
    accent: AppColors.accent,
    success: AppColors.success,
    danger: AppColors.danger,
    warning: AppColors.warning,
    info: AppColors.info,
  );

  static const AppSemantic dark = AppSemantic(
    brightness: Brightness.dark,
    primary: AppColors.darkPrimary,
    primaryHover: AppColors.darkPrimaryHover,
    secondary: AppColors.darkSecondary,
    accent: AppColors.darkAccent,
    success: AppColors.darkSuccess,
    danger: AppColors.darkDanger,
    warning: AppColors.darkWarning,
    info: AppColors.darkInfo,
  );

  static AppSemantic of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  static AppSemantic forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  bool get isDark => brightness == Brightness.dark;

  /// Tint strength for a pill, badge or banner background.
  ///
  /// Dark surfaces need a heavier wash than light ones to read as a distinct
  /// shape at all. Both numbers are ceilings found by measurement, not taste: a
  /// tint pulls the surface *toward* the very colour being drawn on it, so the
  /// heavier the wash the less contrast the label has. Past 0.09 light / 0.20
  /// dark, danger-on-its-own-tint drops below 4.5:1. These sit one step inside
  /// that edge. Raising either value re-opens a contrast failure across every
  /// banner and pill at once, so change them only with the numbers rechecked.
  double get tintAlpha => isDark ? 0.18 : 0.08;

  /// Border strength for those same containers.
  double get tintBorderAlpha => isDark ? 0.45 : 0.32;

  /// A readable foreground for text placed *on top of* a filled colour drawn
  /// from this set — white over the deep light-mode fills, near-black over the
  /// luminous dark-mode ones. Both directions measure ≥4.5:1.
  Color get onFilled => isDark ? const Color(0xFF0B0F0D) : const Color(0xFFFFFFFF);

  /// Late-resolve a semantic colour to the variant that suits the active theme.
  ///
  /// Plenty of small helper widgets in this app take a plain `Color? color` and
  /// paint it as text — `_Meta`, `_Count`, `_Stat`, the dashboard `stat()`
  /// tiles. By the time the colour reaches them it is just a value; the helper
  /// has no idea it was "warning" and so cannot pick the right variant itself.
  /// Rather than thread a semantic enum through every one of those call sites,
  /// the helper calls this on whatever it was handed, right before painting.
  ///
  /// Anything not recognised is returned untouched, so passing a one-off colour
  /// or an already-resolved dark variant is harmless and idempotent.
  Color resolve(Color? color) {
    if (color == null) return primary;
    if (!isDark) return color;
    return _darkVariants[color] ?? color;
  }

  /// Nullable-preserving [resolve], for the very common
  /// `color: someCondition ? AppColors.warning : null` shape where null means
  /// "inherit whatever the surrounding text style already uses".
  Color? resolveOrNull(Color? color) {
    if (color == null) return null;
    if (!isDark) return color;
    return _darkVariants[color] ?? color;
  }

  /// Cannot be `const`: Dart forbids constant map keys whose type overrides
  /// `operator ==`, and Color does.
  static final Map<Color, Color> _darkVariants = <Color, Color>{
    AppColors.primary: AppColors.darkPrimary,
    AppColors.primaryHover: AppColors.darkPrimaryHover,
    AppColors.secondary: AppColors.darkSecondary,
    AppColors.accent: AppColors.darkAccent,
    AppColors.success: AppColors.darkSuccess,
    AppColors.danger: AppColors.darkDanger,
    AppColors.warning: AppColors.darkWarning,
    AppColors.info: AppColors.darkInfo,
  };

  /// Theme-appropriate version of [AppColors.forStatus]. The vocabulary is
  /// documented there; keep the two switches in step.
  Color forStatus(String status) {
    switch (status.toLowerCase()) {
      case 'confirmed':
      case 'completed':
      case 'paid':
      case 'verified':
      case 'delivered':
      case 'fulfilled':
      case 'available':
      case 'active':
      case 'published':
        return success;
      case 'pending':
      // A held slot awaiting money reads as the same kind of "not settled yet"
      // as `pending`, and deliberately so: it is the state a booking opens in,
      // and inventing a fourth colour for it would make the common case the
      // loudest thing on the screen.
      case 'pending_payment':
      case 'processing':
      case 'shipped':
      case 'draft':
      case 'new':
      case 'in_progress':
        return warning;
      case 'cancelled':
      case 'canceled':
      case 'failed':
      case 'rejected':
      case 'refunded':
      case 'unavailable':
      case 'inactive':
      case 'banned':
        return danger;
      case 'expired':
        // A slot that lapsed unpaid: not a failure of the user, so amber rather
        // than red, but unmistakably not live.
        return warning;
      case 'critical':
        return danger;
      case 'high':
      case 'urgent':
        return accent;
      case 'low':
        return info;
      default:
        return secondary;
    }
  }
}
