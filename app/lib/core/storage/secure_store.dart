/// Session + cached identity storage.
///
/// §10: credentials go in the OS keystore (Android EncryptedSharedPreferences /
/// iOS Keychain) via flutter_secure_storage — never SharedPreferences. The cached
/// user JSON is kept here too, because it carries name/phone/role and §10 says to
/// minimise sensitive data sitting in plain local storage.
///
/// Two things live here now:
///
///   - The cached `AppUser` JSON, as before, read at startup so the first frame
///     can pick a shell without a network round trip.
///   - GoTrue's own session blob, via [SecureGotrueStorage] at the bottom of
///     this file. supabase_flutter defaults to SharedPreferences for that, which
///     would have put a refresh token in plain text on disk and quietly broken
///     the §10 rule the moment PHP's hand-managed JWT went away.
///
/// [readToken] and [writeToken] are gone: nothing hand-manages a token any more.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const _kUser = 'ayur.user';

  /// The old hand-managed JWT key. Nothing writes it any more; [clear] still
  /// deletes it so an app upgraded in place does not leave a bearer token for
  /// the retired PHP backend sitting in the keystore forever.
  static const _kLegacyToken = 'ayur.jwt';

  Future<Map<String, dynamic>?> readUser() async {
    final raw = await _storage.read(key: _kUser);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      // Corrupt or from an older schema — treat as no session rather than crash.
      await _storage.delete(key: _kUser);
      return null;
    }
  }

  Future<void> writeUser(Map<String, dynamic> user) =>
      _storage.write(key: _kUser, value: jsonEncode(user));

  /// Called on logout and on any 401. Must leave nothing behind that could let
  /// the app act as if it were still signed in.
  ///
  /// Deliberately does NOT delete the GoTrue session key: `auth.signOut()` owns
  /// that, and deleting it from underneath the client would leave the in-memory
  /// session live while its storage was gone.
  Future<void> clear() async {
    await _storage.delete(key: _kUser);
    await _storage.delete(key: _kLegacyToken);
  }
}

/// Keeps GoTrue's session in the OS keystore instead of SharedPreferences.
///
/// Installed in main.dart via `Supabase.initialize(authOptions:
/// FlutterAuthClientOptions(localStorage: SecureGotrueStorage()))`.
///
/// Why this exists: the session blob contains the refresh token, which is a
/// long-lived credential. The package default (`SharedPrefsLocalStorage`) writes
/// it to plain-text app storage — readable on a rooted or jailbroken device and
/// in a filesystem backup. Under PHP the equivalent secret was the JWT and §10
/// required the keystore for it; nothing about that requirement changed when the
/// issuer did.
///
/// Every method swallows its own failure. On web, flutter_secure_storage goes
/// through the browser's crypto and storage APIs, which throw on a non-secure
/// origin and in some hardened or private-mode profiles. A throw here would
/// escape `Supabase.initialize` and abort bootstrap before the first frame, so
/// the app would show nothing at all. Losing persistence degrades to "you must
/// sign in again", which the app already handles.
class SecureGotrueStorage extends LocalStorage {
  SecureGotrueStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
              iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
            );

  final FlutterSecureStorage _storage;

  static const _kSession = 'ayur.supabase.session';

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() async {
    try {
      return await _storage.read(key: _kSession);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasAccessToken() async {
    try {
      return await _storage.containsKey(key: _kSession);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _storage.write(key: _kSession, value: persistSessionString);
    } catch (_) {
      // Session stays in memory for this run; the user re-authenticates next
      // launch rather than the app failing to start.
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await _storage.delete(key: _kSession);
    } catch (_) {
      // Nothing to do — a session that cannot be deleted also could not be
      // written, so there is none to leak.
    }
  }
}
