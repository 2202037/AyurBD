// Boots the app shell far enough to prove the widget tree assembles.
//
// The router guard and the auth controller read `supabaseServiceProvider`,
// which needs `Supabase.instance.client` to exist, so Supabase is initialised
// here exactly as main.dart does — just without the SecureGotrueStorage, which
// has no platform channel in a test. SharedPreferences is mocked, so the
// default in-memory storage the client picks up is harmless. Nothing performs a
// network call: no session is restored and no profile is fetched, so the app
// settles on the splash behind the unauthenticated redirect.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:ayur/app/app.dart';
import 'package:ayur/core/constants/app_config.dart';
import 'package:ayur/core/providers.dart';
import 'package:ayur/core/storage/prefs_store.dart';

void main() {
  testWidgets('app boots', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsStore(await SharedPreferences.getInstance());

    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      anonKey: AppConfig.supabaseAnonKey,
      // No session is ever restored here, so the periodic token-refresh timer
      // would only leak into the test zone and trip the pending-timer check.
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsStoreProvider.overrideWithValue(prefs)],
        child: const AyurApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // `pumpAndSettle` is deliberately not used: the router guard parks everyone
    // on the splash (a continuous spinner) until restore() resolves, which it
    // never does in this test — so the tree would never settle.
    expect(find.byType(AyurApp), findsOneWidget);
  });
}
