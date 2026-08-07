/// Auth against Supabase Auth (GoTrue) plus the `public.users` mirror row.
///
/// Every public method below has the identical signature it had against the PHP
/// backend, so no screen and no controller changed. What changed is underneath:
///
///   - `POST /auth/login`    -> auth.signInWithPassword
///   - `POST /auth/register` -> auth.signUp, with the profile columns passed as
///                              user metadata and copied into public.users by
///                              the `handle_new_user()` trigger in schema.sql
///   - `GET  /auth/profile`  -> select from public.users where id = auth.uid()
///   - `PUT  /auth/profile`  -> update public.users (RLS: users_update_self)
///   - `POST /auth/password` -> auth.updateUser(password:)
///   - `POST /auth/logout`   -> auth.signOut
///
/// The JWT is no longer written by hand anywhere. GoTrue owns it, persists it
/// through the SecureStore-backed LocalStorage installed in main.dart, and
/// refreshes it in the background. `SecureStore` still holds the cached user
/// JSON so a cold start can pick a shell before the network answers.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/supabase_service.dart';
import '../../../core/providers.dart';
import '../../../core/storage/secure_store.dart';
import '../../../models/app_user.dart';

class AuthRepository {
  AuthRepository({required SupabaseService supabase, required SecureStore store})
      : _sb = supabase,
        _store = store;

  final SupabaseService _sb;
  final SecureStore _store;

  /// The five roles a person may self-register as. `admin` is absent by design:
  /// the PHP handler clamped anything outside this set back to `patient`, and
  /// [_safeRole] below does the same. Sending role='admin' from a patched client
  /// therefore cannot create an administrator, and the `aa_guard_users` trigger
  /// in rls_policies.sql blocks changing `role` afterwards too.
  static const _selfRegisterableRoles = {
    'patient',
    'doctor',
    'clinic',
    'pharmacy',
    'hospital',
  };

  Future<AppUser> login({required String email, required String password}) async {
    return SupabaseService.guard(() async {
      // TEMP-DIAG: log what is actually being sent so a "invalid credentials"
      // report can be matched against GoTrue's expectation.
      // ignore: avoid_print
      print('[login-diag] email=<${email.trim()}> rawLen=${email.length} '
          'pwLen=${password.length} pw="${password.replaceAll(RegExp(r'.'), 'x')}" '
          'first="${password.codeUnits.take(8).toList()}"');
      AuthResponse res;
      try {
        res = await _sb.auth.signInWithPassword(
          email: email.trim(),
          password: password,
        );
      } catch (e) {
        // ignore: avoid_print
        print('[login-diag] signInWithPassword threw: $e');
        rethrow;
      }
      final authUser = res.user;
      if (authUser == null) {
        throw ApiException(
          message: 'Sign-in did not return a session.',
          statusCode: 401,
        );
      }
      // The profile lives in public.users, not in the JWT. Read it so `role` is
      // authoritative — the router's guards key off it, and a role read from
      // client-supplied metadata would be a privilege-escalation route.
      final user = await _loadProfile(authUser.id);
      await _store.writeUser(user.toJson());
      return user;
    });
  }

  /// One method serves all five self-registerable roles (§3.1–3.5), exactly as
  /// the single PHP endpoint did.
  ///
  /// The role-specific columns in [extra] are forwarded as user metadata and the
  /// `handle_new_user()` trigger inserts both the `public.users` row and the
  /// provider's directory row (doctors/clinics/hospitals/pharmacies) in the same
  /// transaction as the auth user. That transactional guarantee is why this is a
  /// trigger and not a second call from here: a client-side insert after signUp
  /// can fail or be abandoned, leaving an auth user with no profile — an account
  /// that can sign in but has no role, which the router cannot place.
  ///
  /// [extra] is still a map rather than sixty named parameters, and
  /// [RegistrationFields] still builds it, so no screen assembles wire keys by
  /// hand.
  Future<AppUser> register({
    required String name,
    required String email,
    required String password,
    required String phone,
    String role = 'patient',
    String? passwordConfirm,
    String? address,
    String? city,
    String? gender,
    Map<String, Object?> extra = const {},
  }) async {
    // Checked client-side because GoTrue has no concept of a confirm field. The
    // PHP handler cross-checked it only when present and every screen sends it,
    // so the behaviour is unchanged for every real caller.
    if (passwordConfirm != null && passwordConfirm != password) {
      throw ApiException(
        message: 'The passwords do not match.',
        statusCode: 422,
        errors: const {'password_confirm': 'The passwords do not match.'},
      );
    }

    return SupabaseService.guard(() async {
      final res = await _sb.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'name': name.trim(),
          'phone': phone.trim(),
          'role': _safeRole(role),
          if (address != null && address.trim().isNotEmpty) 'address': address.trim(),
          if (city != null && city.trim().isNotEmpty) 'city': city.trim(),
          if (gender != null && gender.isNotEmpty) 'gender': gender,
          // Role-specific provider fields, consumed by handle_new_user().
          ...extra,
        },
      );

      final authUser = res.user;
      if (authUser == null) {
        throw ApiException(message: 'Registration failed.', statusCode: 400);
      }

      // With email confirmation ON, signUp returns a user but no session.
      // The project currently runs with it OFF (mailer_autoconfirm), so this
      // branch is a safety net. The old handler always issued a token, so
      // this repository keeps the same contract it always had: return the
      // user either way and let the caller decide, which it already does by
      // checking cachedUser().
      if (res.session == null) {
        return await _profileFromMetadata(authUser, role: _safeRole(role));
      }

      final user = await _loadProfile(authUser.id);
      await _store.writeUser(user.toJson());
      return user;
    });
  }

  /// Refetches the profile. Used on resume so a role or contact change made on
  /// the website is picked up.
  Future<AppUser> fetchProfile() async {
    final id = _sb.currentUserId;
    if (id == null) {
      throw ApiException(message: 'Not signed in.', statusCode: 401);
    }
    final user = await _loadProfile(id);
    await _store.writeUser(user.toJson());
    return user;
  }

  /// Only the columns the app is allowed to change are sent.
  ///
  /// `role` and `email` are absent deliberately — `aa_guard_users` in
  /// rls_policies.sql rejects an update that touches either, so including them
  /// would turn every profile save into a 403. Changing an email is an auth
  /// operation (auth.updateUser) and is not part of this screen.
  Future<AppUser> updateProfile({
    String? name,
    String? phone,
    String? address,
    String? city,
    String? bloodGroup,
    String? profileImage,
  }) async {
    final id = _sb.currentUserId;
    if (id == null) {
      throw ApiException(message: 'Not signed in.', statusCode: 401);
    }

    final patch = <String, dynamic>{
      if (name != null) 'name': name.trim(),
      if (phone != null) 'phone': phone.trim(),
      if (address != null) 'address': address.trim(),
      if (city != null) 'city': city.trim(),
      if (bloodGroup != null) 'blood_group': bloodGroup,
      if (profileImage != null) 'profile_image': profileImage,
    };

    // Matches the old handler's hard 400 on an empty patch. Postgrest would
    // accept `update({})` as a no-op, which would silently look like success.
    if (patch.isEmpty) {
      throw ApiException(message: 'No fields to update.', statusCode: 400);
    }

    return SupabaseService.guard(() async {
      final row = await _sb
          .db('users')
          .update(patch)
          .eq('id', id)
          .select(_profileColumns)
          .single();

      final user = _userFromRow(row);
      await _store.writeUser(user.toJson());
      return user;
    });
  }

  /// GoTrue verifies the current password by re-authenticating with it first.
  ///
  /// updateUser(password:) alone would let anyone holding an unlocked device
  /// change the password without knowing the old one, which the PHP endpoint did
  /// not allow — it required current_password. Re-signing in preserves that.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final email = _sb.auth.currentUser?.email;
    if (email == null) {
      throw ApiException(message: 'Not signed in.', statusCode: 401);
    }

    await SupabaseService.guard(() async {
      try {
        await _sb.auth.signInWithPassword(email: email, password: currentPassword);
      } on AuthException {
        throw ApiException(
          message: 'Your current password is incorrect.',
          statusCode: 422,
          errors: const {'current_password': 'Your current password is incorrect.'},
        );
      }
      await _sb.auth.updateUser(UserAttributes(password: newPassword));
    });
  }

  /// Signs out with GoTrue, then clears locally. The local clear happens even if
  /// the call fails — otherwise a user offline could not sign out.
  Future<void> logout() async {
    try {
      await _sb.auth.signOut();
    } catch (_) {
      // Best-effort: the session is about to be discarded anyway.
    }
    await _store.clear();
  }

  /// Session restored from storage at startup, without hitting the network.
  ///
  /// The token check is now `hasSession` rather than a manual read of
  /// `ayur.jwt`: supabase_flutter has already rehydrated (and if necessary
  /// refreshed) the session by the time bootstrap runs, so it is the only honest
  /// source of "is there a usable session".
  Future<AppUser?> cachedUser() async {
    if (!_sb.hasSession) return null;
    final json = await _store.readUser();
    if (json == null) return null;
    return AppUser.fromJson(json);
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// Explicit column list rather than `*`.
  ///
  /// `users` also holds columns this app never renders, and selecting them
  /// widens what a compromised client sees for no benefit. It also keeps the row
  /// stable if a column is added later.
  ///
  /// `status` is deliberately absent: `public.users` has no such column (see
  /// schema.sql). Asking PostgREST for it returns 400 "column users.status does
  /// not exist", which failed every sign-in. Account state under MySQL was a
  /// per-provider concept and it still is — the `status` enum lives on the four
  /// provider tables (doctors/hospitals/clinics/pharmacies), not on the profile.
  static const _profileColumns =
      'id, name, email, phone, address, city, profile_image, blood_group, '
      'role, gender, created_at';

  Future<AppUser> _loadProfile(String id) async {
    final row = await _sb
        .db('users')
        .select(_profileColumns)
        .eq('id', id)
        .maybeSingle();

    if (row == null) {
      // An auth user with no public.users row. handle_new_user() makes this
      // impossible for accounts created through this app, so it means the row
      // was deleted underneath a live session — treat it as signed out rather
      // than crash on a null.
      throw ApiException(
        message: 'Your account is no longer available.',
        statusCode: 401,
      );
    }

    // No deactivation check here any more. It used to read `row['status']`,
    // but `public.users` has no `status` column, so the check could never fire
    // even once the select stopped failing. Provider deactivation still works:
    // `status` lives on doctors/hospitals/clinics/pharmacies, the public
    // directory views filter on it, and the provider workspace reads it — so a
    // deactivated provider still loses their listing. What is gone is a
    // whole-account disable switch, which the schema never modelled.

    return _userFromRow(row);
  }

  /// Builds an [AppUser] from a `users` row, mapping the storage path in
  /// `profile_image` to an absolute URL.
  ///
  /// This is where the avatar becomes displayable: the column holds an object
  /// path such as `<uuid>/avatar.jpg`, and every widget downstream expects a
  /// finished URL (see AppConfig.resolveAsset).
  AppUser _userFromRow(Map<String, dynamic> row) {
    final avatarUrl = _sb.storageHelper.avatar(row['profile_image'] as String?);
    return AppUser.fromJson({
      ...row,
      'profile_image': avatarUrl.isEmpty ? null : avatarUrl,
    });
  }

  /// Fallback for the email-confirmation-required path, where no session exists
  /// yet so `public.users` cannot be read under RLS. Everything here came from
  /// the caller a moment ago, so nothing is invented.
  Future<AppUser> _profileFromMetadata(User authUser, {required String role}) async {
    final meta = authUser.userMetadata ?? const <String, dynamic>{};
    return AppUser.fromJson({
      'id': authUser.id,
      'name': meta['name'],
      'email': authUser.email,
      'role': role,
      'phone': meta['phone'],
      'address': meta['address'],
      'city': meta['city'],
      'profile_image': null,
      'blood_group': meta['blood_group'],
      'created_at': authUser.createdAt,
    });
  }

  static String _safeRole(String role) {
    final r = role.trim().toLowerCase();
    return _selfRegisterableRoles.contains(r) ? r : 'patient';
  }
}

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepository(
    supabase: ref.watch(supabaseServiceProvider),
    store: ref.watch(secureStoreProvider),
  );
});
