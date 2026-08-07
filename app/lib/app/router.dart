/// Routing and the §7 role guards.
///
/// Three rules decide every redirect:
///   1. Nothing renders until [AuthState.isResolved] — the splash holds the app
///      while `restore()` reads secure storage, so a signed-in user never sees a
///      flash of the login screen on a cold start.
///   2. Only `patient` gets the tabbed shell. Every other role has its own
///      workspace prefix ([Routes.doctorHome], [Routes.placeHome],
///      [Routes.adminHome]) and is bounced back to it rather than shown a screen
///      whose API calls would 403.
///   3. Three access tiers, not two: [_anonymousOnly] for the auth screens,
///      [_openToAll] for the §13 static pages plus emergency and feedback (whose
///      endpoints authenticate optionally), and everything else session-only.
library;

// `kDebugMode` lives in foundation and is NOT re-exported by material.dart:
// material re-exports widgets, which only pulls a subset of foundation forward,
// and the build-mode constants are not in that subset. Import it explicitly.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/admin/presentation/admin_appointments_screen.dart';
import '../features/admin/presentation/admin_audit_screen.dart';
import '../features/admin/presentation/admin_blogs_screen.dart';
import '../features/admin/presentation/admin_blood_banks_screen.dart';
import '../features/admin/presentation/admin_dashboard_screen.dart';
import '../features/admin/presentation/admin_feedback_screen.dart';
import '../features/admin/presentation/admin_payments_screen.dart';
import '../features/admin/presentation/admin_payouts_screen.dart';
import '../features/admin/presentation/admin_providers_screen.dart';
import '../features/admin/presentation/admin_reviews_screen.dart';
import '../features/admin/presentation/admin_users_screen.dart';
import '../features/appointments/presentation/book_appointment_screen.dart';
import '../features/appointments/presentation/my_appointments_screen.dart';
import '../features/appointments/presentation/payments_screen.dart';
import '../features/auth/presentation/auth_controller.dart';
import '../features/auth/presentation/clinic_register_screen.dart';
import '../features/auth/presentation/doctor_register_screen.dart';
import '../features/auth/presentation/hospital_register_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/pharmacy_register_screen.dart';
import '../features/auth/presentation/profile_screen.dart';
import '../features/auth/presentation/register_screen.dart';
import '../features/auth/presentation/role_picker_screen.dart';
import '../features/auth/presentation/splash_screen.dart';
import '../features/blood_bank/presentation/blood_bank_screen.dart';
import '../features/blood_bank/presentation/blood_request_screen.dart';
import '../features/content/presentation/about_screen.dart';
import '../features/content/presentation/blog_detail_screen.dart';
import '../features/content/presentation/blog_screen.dart';
import '../features/content/presentation/contact_screen.dart';
import '../features/content/presentation/notifications_screen.dart';
import '../features/content/presentation/privacy_screen.dart';
import '../features/content/presentation/terms_screen.dart';
import '../features/directory/presentation/doctor_detail_screen.dart';
import '../features/directory/presentation/doctors_screen.dart';
import '../features/directory/presentation/place_detail_screen.dart';
import '../features/directory/presentation/places_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/home/presentation/patient_shell.dart';
import '../features/patient/presentation/emergency_screen.dart';
import '../features/patient/presentation/feedback_screen.dart';
import '../features/patient/presentation/my_reviews_screen.dart';
import '../features/patient/presentation/nearby_screen.dart';
import '../features/patient/presentation/patient_dashboard_screen.dart';
import '../features/pharmacy/presentation/cart_screen.dart';
import '../features/pharmacy/presentation/checkout_screen.dart';
import '../features/pharmacy/presentation/order_detail_screen.dart';
import '../features/pharmacy/presentation/orders_screen.dart';
import '../features/pharmacy/presentation/product_detail_screen.dart';
import '../features/pharmacy/presentation/products_screen.dart';
import '../features/provider/presentation/doctor_appointments_screen.dart';
import '../features/provider/presentation/doctor_dashboard_screen.dart';
import '../features/provider/presentation/doctor_payouts_screen.dart';
import '../features/provider/presentation/doctor_profile_screen.dart';
import '../features/provider/presentation/place_dashboard_screen.dart';
import '../features/provider/presentation/place_profile_screen.dart';
import '../features/provider/presentation/provider_reviews_screen.dart';
import '../models/app_user.dart';
import '../models/directory_models.dart';

/// Path strings in one place so no widget hard-codes a route the way no
/// repository hard-codes a URL.
class Routes {
  const Routes._();

  static const String splash = '/splash';
  static const String login = '/login';

  /// The role fork. `/register` remains the patient form so existing links and
  /// the login screen's "create account" button keep working unchanged.
  static const String signup = '/signup';
  static const String register = '/register';
  static const String registerDoctor = '/register/doctor';
  static const String registerHospital = '/register/hospital';
  static const String registerClinic = '/register/clinic';
  static const String registerPharmacy = '/register/pharmacy';

  // Shell branches.
  static const String home = '/home';
  static const String doctors = '/doctors';
  static const String shop = '/shop';
  static const String appointments = '/appointments';
  static const String profile = '/profile';

  /// The same [ProfileScreen] as the `/profile` tab, on the root navigator.
  ///
  /// §5.5 is one shared account page for every role — `auth_profile_update()`
  /// and `auth_change_password()` both call `require_auth()` with no role check,
  /// and changing your own password is not a patient feature. But `/profile` is
  /// a branch of the patient shell, so a doctor opening it would get the patient
  /// tab bar, and four of those five tabs redirect them straight back out.
  ///
  /// Two paths to one screen is the smaller cost: the tab keeps its branch
  /// history for patients, and every other role pushes this over their own
  /// workspace and gets a back button instead of someone else's navigation.
  static const String account = '/account';

  // Pushed over the shell.
  static const String clinics = '/clinics';
  static const String hospitals = '/hospitals';
  static const String pharmacies = '/pharmacies';
  static const String bloodBank = '/blood-bank';
  static const String bloodRequest = '/blood-bank/request';
  static const String cart = '/cart';
  static const String checkout = '/checkout';
  static const String orders = '/orders';
  static const String payments = '/payments';
  static const String notifications = '/notifications';
  static const String blog = '/blog';
  static const String dashboard = '/dashboard';
  static const String emergency = '/emergency';
  static const String nearby = '/nearby';
  static const String myReviews = '/my-reviews';
  static const String feedback = '/feedback';

  // -- §13 static pages ---------------------------------------------------
  // Reachable without a session: a visitor deciding whether to sign up is
  // exactly who reads the terms and the privacy notice.
  static const String about = '/about';
  static const String terms = '/terms';
  static const String privacy = '/privacy';
  static const String contact = '/contact';

  // -- provider workspaces (§6–§9) ---------------------------------------
  // Each role gets its own prefix rather than one shared '/provider' tree, so
  // the guard can keep a doctor out of the place screens by path alone.
  static const String doctorHome = '/doctor';
  static const String doctorAppointments = '/doctor/appointments';
  static const String doctorPayouts = '/doctor/payouts';
  static const String doctorProfile = '/doctor/profile';
  static const String doctorReviews = '/doctor/reviews';

  static const String placeHome = '/place';
  static const String placeProfile = '/place/profile';
  static const String placeReviews = '/place/reviews';

  // -- admin console (§10) ------------------------------------------------
  static const String adminHome = '/admin';
  static const String adminUsers = '/admin/users';
  static const String adminProviders = '/admin/providers';
  static const String adminAppointments = '/admin/appointments';
  static const String adminReviews = '/admin/reviews';
  static const String adminFeedback = '/admin/feedback';
  static const String adminBloodBanks = '/admin/blood-banks';
  static const String adminBlogs = '/admin/blogs';
  static const String adminPayments = '/admin/payments';
  static const String adminPayouts = '/admin/payouts';
  static const String adminAudit = '/admin/audit-log';

  static String doctorDetail(int id) => '$doctors/$id';
  static String productDetail(int id) => '$shop/$id';
  static String orderDetail(int id) => '$orders/$id';
  static String blogPost(String slug) => '$blog/$slug';
  static String book(int doctorId) => '/book/$doctorId';

  static String placeList(PlaceKind kind) => switch (kind) {
        PlaceKind.clinic => clinics,
        PlaceKind.hospital => hospitals,
        PlaceKind.pharmacy => pharmacies,
      };

  static String placeDetail(PlaceKind kind, int id) => '${placeList(kind)}/$id';
}

/// Screens that only make sense *without* a session. A signed-in user landing on
/// one is bounced to their own landing screen — there is nothing for them here.
///
/// The five registration forms are matched by prefix via [_under], so
/// `/register/doctor` is covered by `/register`.
const List<String> _anonymousOnly = [
  Routes.splash,
  Routes.login,
  Routes.signup,
  Routes.register,
];

/// Reachable either way: with a session or without one.
///
/// Kept separate from [_anonymousOnly] because these must not bounce a signed-in
/// reader. Someone checking the privacy notice from their profile screen should
/// see it, not be redirected home.
///
/// Emergency and feedback are on this list because their endpoints authenticate
/// optionally (`current_user()`, not `require_auth()`) — an ambulance should not
/// need a login, and a guest should be able to report a problem.
const List<String> _openToAll = [
  Routes.about,
  Routes.terms,
  Routes.privacy,
  Routes.contact,
  Routes.emergency,
  Routes.feedback,
];

/// Patient-only prefixes. A provider or admin hitting one is sent back to their
/// own landing screen — the underlying endpoints would 403 for them anyway (§7).
const List<String> _patientOnly = [
  Routes.home,
  Routes.doctors,
  Routes.shop,
  Routes.appointments,
  Routes.clinics,
  Routes.hospitals,
  Routes.pharmacies,
  Routes.bloodBank,
  Routes.cart,
  Routes.checkout,
  Routes.orders,
  Routes.payments,
  Routes.nearby,
  Routes.myReviews,
  // `/patient/dashboard` only calls `require_auth()`, not `require_role`, so a
  // provider landing here would get a clean 200 with every count at zero —
  // their appointments are keyed by `doctor_id`, never `patient_id`. An empty
  // dashboard reads as "you have no appointments", which is worse than an
  // error. Keep the other roles on their own workspace.
  Routes.dashboard,
  // A branch of the patient shell, so reaching it as a provider means wearing
  // the patient tab bar. Other roles get the identical screen at
  // [Routes.account], pushed over their own workspace.
  Routes.profile,
  '/book',
];

final _rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _homeKey = GlobalKey<NavigatorState>(debugLabel: 'home');
final _doctorsKey = GlobalKey<NavigatorState>(debugLabel: 'doctors');
final _shopKey = GlobalKey<NavigatorState>(debugLabel: 'shop');
final _apptKey = GlobalKey<NavigatorState>(debugLabel: 'appointments');
final _profileKey = GlobalKey<NavigatorState>(debugLabel: 'profile');

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    navigatorKey: _rootKey,
    initialLocation: Routes.splash,
    // Same reasoning as [AppConfig.verboseHttp]: this logs every redirect and
    // every match, the guard runs on each navigation, and on web that console
    // traffic is paid for on the UI thread. Debug builds only.
    debugLogDiagnostics: kDebugMode,
    refreshListenable: refresh,
    redirect: (context, state) => _guard(ref.read(authControllerProvider), state),
    routes: [
      GoRoute(path: Routes.splash, builder: (_, __) => const SplashScreen()),
      GoRoute(path: Routes.login, builder: (_, __) => const LoginScreen()),
      GoRoute(path: Routes.signup, builder: (_, __) => const RolePickerScreen()),

      // -- §3.1–3.5 the five registration forms ------------------------------
      // `/register` stays the patient form so the login screen's existing link
      // and any saved deep link keep working. The four provider forms are
      // children of it, which is also what lets `_under()` cover all five with
      // one entry in [_anonymousOnly].
      GoRoute(
        path: Routes.register,
        builder: (_, __) => const RegisterScreen(),
        routes: [
          GoRoute(path: 'doctor', builder: (_, __) => const DoctorRegisterScreen()),
          GoRoute(path: 'hospital', builder: (_, __) => const HospitalRegisterScreen()),
          GoRoute(path: 'clinic', builder: (_, __) => const ClinicRegisterScreen()),
          GoRoute(path: 'pharmacy', builder: (_, __) => const PharmacyRegisterScreen()),
        ],
      ),

      // -- §13 static pages ---------------------------------------------------
      // Public on purpose: the reader most likely to want the terms is the one
      // deciding whether to sign up.
      GoRoute(path: Routes.about, builder: (_, __) => const AboutScreen()),
      GoRoute(path: Routes.terms, builder: (_, __) => const TermsScreen()),
      GoRoute(path: Routes.privacy, builder: (_, __) => const PrivacyScreen()),
      GoRoute(path: Routes.contact, builder: (_, __) => const ContactScreen()),

      // -- §5.9 emergency + feedback -----------------------------------------
      // Both endpoints authenticate optionally, so both routes are open to all.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.emergency,
        builder: (_, __) => const EmergencyScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.feedback,
        builder: (_, __) => const FeedbackScreen(),
      ),

      // -- §5 patient extras --------------------------------------------------
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.nearby,
        builder: (_, __) => const NearbyScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.myReviews,
        builder: (_, __) => const MyReviewsScreen(),
      ),

      // A patient's own summary. The guard keeps every other role out — see
      // [_patientOnly] — so this is not the generic landing screen its path
      // suggests; each other role lands on its own workspace instead.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.dashboard,
        builder: (_, __) => const PatientDashboardScreen(),
      ),

      // -- §6 the doctor workspace ------------------------------------------
      // Flat siblings on the root navigator rather than a nested tree: each is a
      // full screen, and nesting would make `push` from the dashboard rebuild the
      // dashboard underneath on every hop.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.doctorHome,
        builder: (_, __) => const DoctorDashboardScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.doctorAppointments,
        builder: (_, __) => const DoctorAppointmentsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.doctorPayouts,
        builder: (_, __) => const DoctorPayoutsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.doctorProfile,
        builder: (_, __) => const DoctorProfileScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.doctorReviews,
        builder: (_, __) => const ProviderReviewsScreen(),
      ),

      // -- §7–9 the hospital / clinic / pharmacy workspace -------------------
      // One tree for all three roles: the backend resolves the table from the
      // caller's JWT, so there is nothing role-specific to route to. The reviews
      // screen is the same widget the doctor uses for the same reason.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.placeHome,
        builder: (_, __) => const PlaceDashboardScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.placeProfile,
        builder: (_, __) => const PlaceProfileScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.placeReviews,
        builder: (_, __) => const ProviderReviewsScreen(),
      ),

      // -- §10 the admin console ---------------------------------------------
      // Flat siblings rather than children of `/admin`, so a deep link into any
      // one list does not have to rebuild the dashboard behind it. `_under()`
      // handles the prefix match in the guard.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminHome,
        builder: (_, __) => const AdminDashboardScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminUsers,
        builder: (_, __) => const AdminUsersScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminProviders,
        builder: (_, __) => const AdminProvidersScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminAppointments,
        builder: (_, __) => const AdminAppointmentsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminReviews,
        builder: (_, __) => const AdminReviewsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminFeedback,
        builder: (_, __) => const AdminFeedbackScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminBloodBanks,
        builder: (_, __) => const AdminBloodBanksScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminBlogs,
        builder: (_, __) => const AdminBlogsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminPayments,
        builder: (_, __) => const AdminPaymentsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminPayouts,
        builder: (_, __) => const AdminPayoutsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.adminAudit,
        builder: (_, __) => const AdminAuditScreen(),
      ),

      // -- the patient tab shell --------------------------------------------
      StatefulShellRoute.indexedStack(
        builder: (_, __, shell) => PatientShell(shell: shell),
        branches: [
          StatefulShellBranch(
            navigatorKey: _homeKey,
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (_, __) => const HomeScreen(),
                routes: [
                  GoRoute(path: 'notifications', builder: (_, __) => const NotificationsScreen()),
                  GoRoute(
                    path: 'blood-bank',
                    builder: (_, __) => const BloodBankScreen(),
                    routes: [
                      GoRoute(path: 'request', builder: (_, __) => const BloodRequestScreen()),
                    ],
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _doctorsKey,
            routes: [
              GoRoute(
                path: Routes.doctors,
                builder: (_, __) => const DoctorsScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => DoctorDetailScreen(doctorId: _id(s)),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _shopKey,
            routes: [
              GoRoute(
                path: Routes.shop,
                builder: (_, __) => const ProductsScreen(),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (_, s) => ProductDetailScreen(productId: _id(s)),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _apptKey,
            routes: [
              GoRoute(
                path: Routes.appointments,
                builder: (_, __) => const MyAppointmentsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: _profileKey,
            routes: [
              GoRoute(
                path: Routes.profile,
                builder: (_, __) => const ProfileScreen(),
                routes: [
                  GoRoute(path: 'orders', builder: (_, __) => const OrdersScreen()),
                  GoRoute(path: 'payments', builder: (_, __) => const PaymentsScreen()),
                ],
              ),
            ],
          ),
        ],
      ),

      // -- full-screen routes, pushed above the tab bar ----------------------
      // Booking, cart and checkout are deliberately outside the shell: they are
      // linear flows, and keeping the tab bar visible would invite a mid-checkout
      // tab switch that silently abandons the order.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: '/book/:id',
        builder: (_, s) => BookAppointmentScreen(doctorId: _id(s)),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.cart,
        builder: (_, __) => const CartScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.checkout,
        builder: (_, __) => const CheckoutScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.orders,
        builder: (_, __) => const OrdersScreen(),
        routes: [
          GoRoute(
            parentNavigatorKey: _rootKey,
            path: ':id',
            builder: (_, s) => OrderDetailScreen(orderId: _id(s)),
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.payments,
        builder: (_, __) => const PaymentsScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.notifications,
        builder: (_, __) => const NotificationsScreen(),
      ),
      // Same screen as the patient `/profile` tab — see [Routes.account] for why
      // it is reachable by two paths rather than one.
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.account,
        builder: (_, __) => const ProfileScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.bloodBank,
        builder: (_, __) => const BloodBankScreen(),
        routes: [
          GoRoute(
            parentNavigatorKey: _rootKey,
            path: 'request',
            builder: (_, __) => const BloodRequestScreen(),
          ),
        ],
      ),
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.blog,
        builder: (_, __) => const BlogScreen(),
        routes: [
          GoRoute(
            parentNavigatorKey: _rootKey,
            path: ':slug',
            builder: (_, s) => BlogDetailScreen(slug: s.pathParameters['slug'] ?? ''),
          ),
        ],
      ),
      ..._placeRoutes(PlaceKind.clinic),
      ..._placeRoutes(PlaceKind.hospital),
      ..._placeRoutes(PlaceKind.pharmacy),
    ],
    errorBuilder: (context, state) => _RouteNotFound(location: state.uri.toString()),
  );
});

/// The three place directories differ only by [PlaceKind], so the routes are
/// generated rather than triplicated.
List<RouteBase> _placeRoutes(PlaceKind kind) => [
      GoRoute(
        parentNavigatorKey: _rootKey,
        path: Routes.placeList(kind),
        builder: (_, __) => PlacesScreen(kind: kind),
        routes: [
          GoRoute(
            parentNavigatorKey: _rootKey,
            path: ':id',
            builder: (_, s) => PlaceDetailScreen(kind: kind, id: _id(s)),
          ),
        ],
      ),
    ];

/// Where each role belongs when it has no business being where it asked for.
///
/// The three place roles share one workspace — the backend picks the table from
/// the caller's role, so there is nothing role-specific to route to.
String _landingFor(UserRole? role) => switch (role) {
      UserRole.patient => Routes.home,
      UserRole.doctor => Routes.doctorHome,
      UserRole.hospital || UserRole.clinic || UserRole.pharmacy => Routes.placeHome,
      UserRole.admin => Routes.adminHome,
      null => Routes.login,
    };

/// Segment-aware prefix test.
///
/// Plain `startsWith` is wrong here: the patient directory is `/doctors` and the
/// doctor workspace is `/doctor`, so a prefix match would put every patient
/// browsing doctors into the provider guard. Requiring the next character to be a
/// `/` keeps the two apart.
bool _under(String loc, String prefix) =>
    loc == prefix || loc.startsWith('$prefix/');

/// Returns the path to redirect to, or null to allow the navigation.
String? _guard(AuthState auth, GoRouterState state) {
  final loc = state.matchedLocation;

  // Still reading storage: hold everything on the splash.
  if (!auth.isResolved) return loc == Routes.splash ? null : Routes.splash;

  final open = _openToAll.any((p) => _under(loc, p));

  if (!auth.isAuthenticated) {
    // A guest may read the static pages, use the emergency screen, send
    // feedback, or work through any of the five sign-up forms. Everything else
    // needs a session.
    if (open) return null;
    final anon = _anonymousOnly.any((p) => _under(loc, p));
    return anon && loc != Routes.splash ? null : Routes.login;
  }

  final role = auth.role;
  final landing = _landingFor(role);

  // Signed in: the splash and the auth screens have nothing left to say. Checked
  // before [open] so `/register/doctor` still bounces a signed-in user, while the
  // static pages below stay reachable from their profile screen.
  if (_anonymousOnly.any((p) => _under(loc, p))) return landing;

  if (open) return null;

  if (role != UserRole.patient && _patientOnly.any((p) => _under(loc, p))) {
    return landing;
  }

  // Each workspace is fenced off from the others. These endpoints 403 for the
  // wrong role, so without this a doctor deep-linking into `/place` would get a
  // screen full of error views instead of a redirect.
  if (_under(loc, Routes.doctorHome) && role != UserRole.doctor) return landing;

  if (_under(loc, Routes.placeHome) &&
      !(role == UserRole.hospital ||
          role == UserRole.clinic ||
          role == UserRole.pharmacy)) {
    return landing;
  }

  if (_under(loc, Routes.adminHome) && role != UserRole.admin) return landing;

  return null;
}

int _id(GoRouterState state) => int.tryParse(state.pathParameters['id'] ?? '') ?? 0;

/// Bridges Riverpod to go_router's [Listenable]-based refresh. Only fires when
/// something the guard actually reads changes — notifying on every `busy` flip
/// would re-run the redirect on each keystroke of a login form.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    _sub = ref.listen<AuthState>(
      authControllerProvider,
      (prev, next) {
        if (prev?.status != next.status || prev?.role != next.role) notifyListeners();
      },
      fireImmediately: false,
    );
  }

  late final ProviderSubscription<AuthState> _sub;

  @override
  void dispose() {
    _sub.close();
    super.dispose();
  }
}

class _RouteNotFound extends StatelessWidget {
  const _RouteNotFound({required this.location});

  final String location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Not found')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.explore_off_outlined, size: 56),
              const SizedBox(height: 16),
              Text('No screen for $location', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              // Width stated here rather than inherited: the button theme keeps
              // a bounded minimum width so buttons stay layout-safe in a Row.
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => context.go(Routes.home),
                  child: const Text('Go home'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
