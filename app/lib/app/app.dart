/// The MaterialApp. Thin by design — routing lives in router.dart and theming in
/// app_theme.dart, so this file only wires them together.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_config.dart';
import '../core/constants/app_theme.dart';
import '../core/theme_controller.dart';
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
      routerConfig: ref.watch(routerProvider),
    );
  }
}
