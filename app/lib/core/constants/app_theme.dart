/// Light + dark ThemeData built purely from [AppColors] (§9).
///
/// Both themes are assembled by the same [_build], but the semantic colours are
/// resolved per brightness through [AppSemantic] — a fixed colour cannot clear
/// 4.5:1 on both a light and a dark surface, so anything that ends up as text or
/// a small icon has to come from the brightness-matched set. See the long note
/// at the top of app_colors.dart for the arithmetic.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

class AppTheme {
  const AppTheme._();

  static const double radius = 12.0;
  static const double gap = 16.0;

  /// For a button that sits directly inside a `Row` — card action strips,
  /// "Confirm"/"Verify"/"Pay now" and friends.
  ///
  /// A Row offers its children UNBOUNDED width, and a button can only be laid
  /// out there if its `minimumSize.width` is finite (see the note on
  /// [_build]'s `filledButtonTheme`). The app-wide 50px height is also too
  /// chunky for an inline action strip, so this trims it to a compact 40.
  static final ButtonStyle rowAction = FilledButton.styleFrom(
    minimumSize: const Size(64, 40),
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 16),
  );

  /// The red confirm button on a "delete this permanently?" dialog.
  ///
  /// Use this instead of `FilledButton.styleFrom(backgroundColor: danger)`.
  /// Overriding only the background leaves the *foreground* coming from the
  /// theme, and the two themes want opposite foregrounds — white over the deep
  /// light-mode red, near-black over the luminous dark-mode one. Setting just
  /// one of the pair produced near-black on deep red at 3.45:1, which fails AA
  /// on the single most consequential button in the app. This keeps them
  /// together so they cannot drift apart again.
  static ButtonStyle destructive(BuildContext context) {
    final sem = AppSemantic.of(context);
    return FilledButton.styleFrom(
      backgroundColor: sem.danger,
      foregroundColor: sem.onFilled,
    );
  }

  /// A destructive action rendered as a text button — "Reject", "Suspend".
  /// Same reasoning as [destructive]: the label is small text on the page
  /// surface, so it needs the brightness-matched red, not the light-mode one.
  static ButtonStyle destructiveText(BuildContext context) =>
      TextButton.styleFrom(foregroundColor: AppSemantic.of(context).danger);

  /// As [destructiveText] but for a cautionary rather than destructive action.
  static ButtonStyle cautionText(BuildContext context) =>
      TextButton.styleFrom(foregroundColor: AppSemantic.of(context).warning);

  static ThemeData light() => _build(
        brightness: Brightness.light,
        bg: AppColors.lightBg,
        bgAlt: AppColors.lightBgAlt,
        bgMuted: AppColors.lightBgMuted,
        border: AppColors.lightBorder,
        borderStrong: AppColors.lightBorderStrong,
        text: AppColors.lightText,
        textMuted: AppColors.lightTextMuted,
      );

  static ThemeData dark() => _build(
        brightness: Brightness.dark,
        bg: AppColors.darkBg,
        bgAlt: AppColors.darkBgAlt,
        bgMuted: AppColors.darkBgMuted,
        border: AppColors.darkBorder,
        borderStrong: AppColors.darkBorderStrong,
        text: AppColors.darkText,
        textMuted: AppColors.darkTextMuted,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color bgAlt,
    required Color bgMuted,
    required Color border,
    required Color borderStrong,
    required Color text,
    required Color textMuted,
  }) {
    final isLight = brightness == Brightness.light;

    /// Semantic colours matched to this brightness. Everything below pulls
    /// primary/danger/etc. from here rather than from [AppColors] directly.
    final sem = AppSemantic.forBrightness(brightness);

    // Raised things (cards, app bar, dialogs, nav bars) must be LIGHTER than
    // the page in both themes — that is what reads as "in front". In light mode
    // that means the page is the slightly deeper tone and cards are the paler
    // one; in dark mode it is the other way round. The old theme used the same
    // pair for both, which left dark-mode cards darker than the page behind
    // them, so they read as holes rather than surfaces.
    final pageBg = isLight ? bgAlt : bg;
    final raised = isLight ? bg : bgAlt;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: sem.primary,
      onPrimary: sem.onFilled,
      primaryContainer: sem.primaryHover,
      onPrimaryContainer: sem.onFilled,
      secondary: sem.secondary,
      onSecondary: sem.onFilled,
      tertiary: sem.accent,
      onTertiary: sem.onFilled,
      error: sem.danger,
      onError: sem.onFilled,
      surface: pageBg,
      onSurface: text,
      surfaceContainerLowest: isLight ? bg : bg,
      surfaceContainerLow: raised,
      surfaceContainer: raised,
      surfaceContainerHigh: bgMuted,
      surfaceContainerHighest: bgMuted,
      onSurfaceVariant: textMuted,
      // M3 splits these deliberately: `outline` is for control boundaries
      // (field outlines, checkbox edges) and `outlineVariant` for decorative
      // rules. Matching that split is what lets a divider stay quiet while a
      // text field stays findable.
      outline: borderStrong,
      outlineVariant: border,
    );

    final base = ThemeData(brightness: brightness);

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: pageBg,
      canvasColor: raised,
      dividerColor: border,
      dividerTheme: DividerThemeData(color: border, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: raised,
        foregroundColor: text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          height: 1.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: border),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: textMuted,
        textColor: text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        // bgMuted in both themes: it is the only surface that stays visibly
        // distinct from a card in light mode, where bgAlt sits ~1.03:1 from it
        // and the field boundary effectively disappears.
        fillColor: bgMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: TextStyle(color: textMuted),
        labelStyle: TextStyle(color: textMuted),
        prefixIconColor: textMuted,
        // borderStrong, not border: this is the outline that tells someone
        // where a tappable field begins. The decorative border measures ~1.2:1
        // against the field's own fill, which effectively erases the edge in
        // dark mode. See the note on the border tokens in app_colors.dart.
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: borderStrong),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: sem.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: sem.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: sem.danger, width: 1.6),
        ),
        errorStyle: TextStyle(color: sem.danger, height: 1.4),
      ),
      // minimumSize keeps a bounded WIDTH on purpose. The obvious-looking
      // `Size.fromHeight(50)` is `Size(double.infinity, 50)`, and that infinite
      // minimum width is a layout landmine: ButtonStyleButton wraps its child in
      // a ConstrainedBox and calls `constraints.enforce(incoming)`. Inside a
      // Column the infinity clamps down to the parent's finite maxWidth, so the
      // button looks full-width and all is well. Inside a Row — which offers its
      // children UNBOUNDED width — there is nothing to clamp against, minWidth
      // stays infinite, and layout throws "BoxConstraints forces an infinite
      // width". That assertion aborts the whole subtree: the screen paints blank
      // AND stops hit-testing, so every button on it, including Back, goes dead.
      //
      // 64x50 is Material's default width with this app's taller height. Buttons
      // that should span their container now say so at the call site with
      // SizedBox(width: double.infinity), which is safe in any parent.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: sem.primary,
          foregroundColor: sem.onFilled,
          minimumSize: const Size(64, 50),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: sem.primary,
          minimumSize: const Size(64, 50),
          side: BorderSide(color: sem.primary),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: sem.primary),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: bgMuted,
        selectedColor: sem.primary,
        labelStyle: TextStyle(color: text, fontSize: 13, height: 1.3),
        secondaryLabelStyle: TextStyle(color: sem.onFilled, fontSize: 13, height: 1.3),
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: raised,
        selectedItemColor: sem.primary,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: raised,
        indicatorColor: sem.primary.withValues(alpha: isLight ? 0.14 : 0.22),
        surfaceTintColor: Colors.transparent,
        elevation: 3,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius + 4)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: sem.primary),
      tabBarTheme: TabBarThemeData(
        labelColor: sem.primary,
        unselectedLabelColor: textMuted,
        indicatorColor: sem.primary,
      ),
      // Line height ≥1.5 on body copy (WCAG 1.4.12). Long medical descriptions,
      // doctor bios and blog posts are the bulk of the reading in this app, and
      // tight leading is what makes a wall of text feel unreadable well before
      // contrast does.
      textTheme: _textTheme(base.textTheme, text, textMuted),
    );
  }

  static TextTheme _textTheme(TextTheme base, Color text, Color textMuted) {
    final t = base.apply(bodyColor: text, displayColor: text);
    return t.copyWith(
      bodyLarge: t.bodyLarge?.copyWith(height: 1.55),
      bodyMedium: t.bodyMedium?.copyWith(height: 1.55),
      // Captions and helper text are small enough that they need both the extra
      // leading and a touch of tracking to stay separable.
      bodySmall: t.bodySmall?.copyWith(height: 1.5, letterSpacing: 0.15),
      titleLarge: t.titleLarge?.copyWith(height: 1.3),
      titleMedium: t.titleMedium?.copyWith(height: 1.35),
      titleSmall: t.titleSmall?.copyWith(height: 1.4),
      labelLarge: t.labelLarge?.copyWith(height: 1.3),
      labelMedium: t.labelMedium?.copyWith(height: 1.3, letterSpacing: 0.2),
      labelSmall: t.labelSmall?.copyWith(height: 1.3, letterSpacing: 0.2),
    );
  }
}
