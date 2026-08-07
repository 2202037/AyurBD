/// Theme mode, persisted. Small enough to live in one file rather than a feature
/// folder — it has no API surface and no models.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'storage/prefs_store.dart';

class ThemeModeController extends StateNotifier<ThemeMode> {
  ThemeModeController(this._prefs) : super(_prefs.themeMode);

  final PrefsStore _prefs;

  Future<void> set(ThemeMode mode) async {
    if (mode == state) return;
    state = mode;
    await _prefs.setThemeMode(mode);
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

  String get label => switch (state) {
        ThemeMode.system => 'System theme',
        ThemeMode.light => 'Light theme',
        ThemeMode.dark => 'Dark theme',
      };
}

final themeModeProvider = StateNotifierProvider<ThemeModeController, ThemeMode>((ref) {
  return ThemeModeController(ref.watch(prefsStoreProvider));
});
