/// Session state. The router watches this to decide what a user may see (§7),
/// and main.dart's GoTrue auth-state subscription calls into it when a session
/// is rejected or revoked.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/app_user.dart';
import '../data/auth_repository.dart';

enum AuthStatus {
  /// Reading storage on startup — show the splash, decide nothing yet.
  unknown,
  authenticated,
  unauthenticated,
}

class AuthState {
  const AuthState({this.status = AuthStatus.unknown, this.user, this.busy = false});

  final AuthStatus status;
  final AppUser? user;

  /// A login/register/logout call is in flight.
  final bool busy;

  bool get isAuthenticated => status == AuthStatus.authenticated && user != null;
  bool get isResolved => status != AuthStatus.unknown;

  UserRole? get role => user?.role;

  AuthState copyWith({AuthStatus? status, AppUser? user, bool? busy, bool clearUser = false}) =>
      AuthState(
        status: status ?? this.status,
        user: clearUser ? null : (user ?? this.user),
        busy: busy ?? this.busy,
      );
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._repo) : super(const AuthState());

  final AuthRepository _repo;

  /// Called once from main() before the first frame settles.
  ///
  /// Must always finish in a *resolved* state. `_guard` pins every route to the
  /// splash while [AuthState.isResolved] is false, so a throw in here does not
  /// surface as an error screen — it silently freezes the whole app on the
  /// splash, with a spinner and no control that responds. Reading the token can
  /// genuinely fail: on web flutter_secure_storage goes through the browser's
  /// crypto and storage APIs, which throw on a non-secure origin and in some
  /// hardened or private-mode profiles.
  ///
  /// The timeout covers the other half of the same risk — a read that never
  /// completes holds the splash open just as effectively as one that throws.
  /// Either way the honest answer is "no usable session", and that is a state
  /// the app already knows how to render: the login screen.
  Future<void> restore() async {
    AppUser? user;
    try {
      user = await _repo.cachedUser().timeout(const Duration(seconds: 5));
    } catch (_) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }

    if (user == null) {
      state = const AuthState(status: AuthStatus.unauthenticated);
      return;
    }
    state = AuthState(status: AuthStatus.authenticated, user: user);

    // Deliberately not awaited. main() waits on restore() before the first
    // frame, and awaiting a network call here would hold the splash for as long
    // as the request takes whenever the network is slow or Supabase is
    // unreachable — the one case where showing the cached session promptly
    // matters most.
    unawaited(_refreshProfile());
  }

  /// A role change or deactivation made on the website should take effect here
  /// without a manual sign-out. A failure is ignored so the app still works
  /// offline with the cached session — except an expired session, which GoTrue's
  /// onAuthStateChange stream already turns into signedOutByServer (see
  /// main.dart), and a deactivated account, which fetchProfile signs out itself.
  Future<void> _refreshProfile() async {
    try {
      final fresh = await _repo.fetchProfile();
      if (mounted) state = state.copyWith(user: fresh);
    } catch (_) {
      // keep the cached user
    }
  }

  Future<void> login({required String email, required String password}) async {
    state = state.copyWith(busy: true);
    try {
      final user = await _repo.login(email: email, password: password);
      state = AuthState(status: AuthStatus.authenticated, user: user);
    } finally {
      if (mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  /// Returns true when the server also signed the user in; false when they need
  /// to log in manually.
  /// Returns true when the server signed the user in (it issues a token on 201,
  /// so this is the normal path); false means the caller should route to /login.
  ///
  /// [role] and [extra] carry the §3.2–3.5 provider sign-ups. Build [extra] with
  /// [RegistrationFields] rather than composing wire keys at the call site.
  Future<bool> register({
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
    state = state.copyWith(busy: true);
    try {
      final user = await _repo.register(
        name: name,
        email: email,
        password: password,
        phone: phone,
        role: role,
        passwordConfirm: passwordConfirm,
        address: address,
        city: city,
        gender: gender,
        extra: extra,
      );
      final signedIn = await _repo.cachedUser() != null;
      state = signedIn
          ? AuthState(status: AuthStatus.authenticated, user: user)
          : const AuthState(status: AuthStatus.unauthenticated);
      return signedIn;
    } finally {
      if (mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  Future<void> logout() async {
    state = state.copyWith(busy: true);
    await _repo.logout();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// §10: a rejected session anywhere is a normal logout. GoTrue has already
  /// discarded it by the time this runs; this just moves the app to the
  /// signed-out state so the router redirects. No error dialog.
  void signedOutByServer() {
    if (state.status == AuthStatus.unauthenticated) return;
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  void setUser(AppUser user) => state = state.copyWith(user: user);
}

final authControllerProvider = StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(ref.watch(authRepositoryProvider));
});

/// Convenience for widgets that only care who is signed in.
final currentUserProvider = Provider<AppUser?>(
  (ref) => ref.watch(authControllerProvider).user,
);
