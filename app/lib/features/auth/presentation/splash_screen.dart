/// Shown only while `restore()` resolves, then the router redirects. It exists so
/// the app has something to draw during that gap — not as a timed brand splash.
///
/// It follows the active theme rather than painting a full-bleed brand field.
/// Two reasons. A saturated full-screen colour is the brightest thing the app
/// ever shows, and it lands on someone who may have opened this at 3am in a
/// dark room — then hands off to a page that is a completely different
/// brightness, so the eye has to re-adapt twice in under a second. And a fixed
/// dark-teal field ignores dark mode entirely, which is the one place that
/// flash is most unpleasant. Healthcare apps generally keep the launch surface
/// the same brightness as the app behind it and let the mark carry the brand.
library;

import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_config.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem = AppSemantic.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: sem.primary,
                borderRadius: BorderRadius.circular(28),
              ),
              alignment: Alignment.center,
              // onFilled, not a hardcoded white: the dark-mode primary is a
              // light teal, and white on it measures about 1.4:1.
              child: Icon(Icons.spa_rounded, size: 52, color: sem.onFilled),
            ),
            const SizedBox(height: 20),
            Text(
              AppConfig.appName,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: sem.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Ayurvedic care, close to home',
              // The muted body colour, which is measured against these
              // surfaces. A translucent white here was 3.66:1 and failed AA.
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 36),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                color: sem.primary,
                strokeWidth: 2.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
