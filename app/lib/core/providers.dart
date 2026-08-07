/// Riverpod providers for the objects everything else depends on.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'network/supabase_service.dart';
import 'storage/prefs_store.dart';
import 'storage/secure_store.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

/// The Supabase façade every repository holds.
///
/// Replaces `apiClientProvider`. Reads `Supabase.instance.client`, which means
/// `Supabase.initialize()` must have run first — bootstrap() in main.dart does
/// that before anything reads this provider.
final supabaseServiceProvider = Provider<SupabaseService>((ref) {
  return SupabaseService(Supabase.instance.client);
});

/// Has no default: [SharedPreferences.getInstance] is async, and the first frame
/// must already know the theme. main() opens it and overrides this provider, so
/// reading it before bootstrap is a programming error worth failing loudly on
/// rather than papering over with a throwaway instance.
final prefsStoreProvider = Provider<PrefsStore>((ref) {
  throw StateError('prefsStoreProvider was not overridden — see bootstrap() in main.dart');
});
