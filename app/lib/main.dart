/// Entry point.
///
/// Four things must happen before the first frame, in this order:
///   1. SharedPreferences opens, so the app doesn't flash a light theme at a
///      dark-mode user.
///   2. Supabase initialises. This must precede anything that reads
///      `supabaseServiceProvider`, and it is also what rehydrates a stored
///      session — so step 4 can answer "is anyone signed in" without a network
///      call.
///   3. The app subscribes to auth state changes (§10), replacing the old
///      `apiClientProvider.onUnauthorized` hook. Still wired here rather than
///      inside a `core/` provider because the auth controller is a feature;
///      wiring it there would make core depend on features and create a
///      provider cycle.
///   4. `restore()` reads the cached session, so the router's very first
///      redirect already knows whether anyone is signed in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/router.dart';
import 'core/constants/app_config.dart';
import 'core/deep_links/deep_link_service.dart';
import 'core/providers.dart';
import 'core/storage/prefs_store.dart';
import 'core/storage/secure_store.dart';
import 'core/utils/payment_debug_logger.dart';
import 'features/auth/presentation/auth_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await PrefsStore.open();

  // Refuses to start against a backend that could not work on device — an http
  // scheme, or a loopback host that on a phone means the phone itself. Cheaper
  // to fail here with a named error than to ship an APK whose every request
  // dies at the socket.
  AppConfig.assertValidBackendConfig();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
    // Refresh token in the OS keystore, not SharedPreferences (§10).
    authOptions: FlutterAuthClientOptions(
      localStorage: SecureGotrueStorage(),
    ),
    debug: AppConfig.verboseHttp,
  );

  // Initialize payment debug logger from build-time flag
  PaymentDebugLogger.enabled = const bool.fromEnvironment('AYUR_PAYMENT_DEBUG', defaultValue: false);

  final container = ProviderContainer(
    overrides: [prefsStoreProvider.overrideWithValue(prefs)],
  );

  // §10: a rejected or expired session is a normal logout, not a crash.
  //
  // The PHP build detected this by watching for a 401 on any response. GoTrue
  // reports it directly, and earlier: signedOut fires when the session is
  // cleared for any reason, and tokenRefreshed failing to produce a session
  // means the refresh token was revoked or expired past recovery. Either way the
  // app moves to the signed-out state and the router redirects. No error dialog.
  Supabase.instance.client.auth.onAuthStateChange.listen(
    (data) {
      final notifier = container.read(authControllerProvider.notifier);
      switch (data.event) {
        case AuthChangeEvent.signedOut:
        case AuthChangeEvent.userDeleted:
          notifier.signedOutByServer();
        case AuthChangeEvent.tokenRefreshed:
          if (data.session == null) notifier.signedOutByServer();
        default:
          // signedIn / initialSession / passwordRecovery / userUpdated are all
          // driven by the repository, which sets the state itself with a
          // profile already loaded. Reacting here as well would overwrite that
          // with a less complete state.
          break;
      }
    },
    // A closed stream must not take the app down.
    onError: (_) {},
  );

  // Awaited, so the splash is only ever shown for as long as storage takes to
  // read. `restore()` swallows network failures itself — an unreachable backend
  // must not stop the app from starting.
  await container.read(authControllerProvider.notifier).restore();

  // Riverpod 2.6 `ProviderContainer` has no `onDispose` callback.
  // The app-level container is process-lifetime, so the auth listener is meant
  // to live for the same lifetime as the app.

  // Stripe deep links (mobile only): translate `ayurbd://...` into a
  // go_router location. The router provider is read only after `restore()`
  // above, so a cold-start redirect already has a resolved auth state and the
  // guard lets the `/payment-success` route through instead of dumping the user
  // on the splash until a refresh that never changes the URL.
  deepLinkService.start((raw) {
    container.read(routerProvider).go(DeepLinkService.toRouterLocation(raw));
  });

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const AyurApp(),
    ),
  );
}
