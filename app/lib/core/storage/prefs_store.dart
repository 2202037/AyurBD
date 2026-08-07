/// Non-sensitive preferences. Deliberately separate from [SecureStore]: §10 puts
/// the JWT in the keystore and nothing else, so this file must never be given a
/// token, an id, or anything else worth stealing.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PrefsStore {
  PrefsStore(this._prefs);

  /// Null when the platform refused to give us a store. Every accessor below
  /// then falls back to a default, which for a theme preference is a fair trade.
  final SharedPreferences? _prefs;

  static const String _kThemeMode = 'theme_mode';
  static const String _kSeenIntro = 'seen_intro';

  /// Loaded once in main() so the first frame already knows the theme — reading
  /// it asynchronously would flash the light theme at a dark-mode user.
  ///
  /// Never throws and never hangs. main() awaits this before `runApp`, so an
  /// exception here means `runApp` is never reached at all: no error screen, no
  /// Flutter output, just a blank dead page. On web the backing store is browser
  /// storage, which can throw in hardened or private-mode profiles. Forgetting a
  /// remembered theme is an acceptable cost; losing the whole app is not.
  static Future<PrefsStore> open() async {
    try {
      return PrefsStore(
        await SharedPreferences.getInstance().timeout(const Duration(seconds: 5)),
      );
    } catch (_) {
      return PrefsStore(null);
    }
  }

  ThemeMode get themeMode {
    switch (_prefs?.getString(_kThemeMode)) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  /// Best-effort, like the reads: a preference that cannot be persisted must not
  /// throw out of a UI callback. The setting still applies for this session.
  Future<void> setThemeMode(ThemeMode mode) async {
    try {
      await _prefs?.setString(_kThemeMode, mode.name);
    } catch (_) {
      // Not remembered next launch; harmless.
    }
  }

  bool get seenIntro => _prefs?.getBool(_kSeenIntro) ?? false;

  Future<void> setSeenIntro() async {
    try {
      await _prefs?.setBool(_kSeenIntro, true);
    } catch (_) {
      // As above.
    }
  }
}
