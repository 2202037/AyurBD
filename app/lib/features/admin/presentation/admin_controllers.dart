/// Riverpod wiring for the admin console (feature.md §10).
///
/// One file for the whole console: every list here is the same shape — a filter
/// or two feeding a [PagedController] — and splitting them per screen would mean
/// eight copies of the same three lines.
///
/// Each list watches its own filter providers, so setting a filter rebuilds the
/// controller and the page resets to 1 for free. That is why no screen calls
/// `reload()` after changing a filter.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/paged_controller.dart';
import '../../../models/admin_models.dart';
import '../../../models/app_user.dart';
import '../../../models/appointment_models.dart';
import '../../../models/provider_models.dart';
import '../data/admin_repository.dart';

// -- §10.1 Dashboard ---------------------------------------------------------

/// `autoDispose` for the same reason as the provider dashboards: a moderation
/// queue length is the one number that must not be stale, because the whole
/// point of the screen is to say what still needs doing.
final adminDashboardProvider = FutureProvider.autoDispose<AdminDashboard>(
  (ref) => ref.watch(adminRepositoryProvider).dashboard(),
);

// -- §10.2 Users -------------------------------------------------------------

/// Null means every role. The server rejects an unknown role with a 400, so the
/// UI only ever sets values from [UserRole].
final adminUserRoleProvider = StateProvider<String?>((ref) => null);

/// Matches name, email or phone server-side. Debounced by the screen, not here.
final adminUserSearchProvider = StateProvider<String?>((ref) => null);

final adminUsersProvider =
    StateNotifierProvider<PagedController<AdminUser>, PagedState<AdminUser>>(
        (ref) {
  final role = ref.watch(adminUserRoleProvider);
  final search = ref.watch(adminUserSearchProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AdminUser>(
    (page) => repo.users(page: page, role: role, search: search),
  );
});

// -- §10.3–10.6 Provider moderation -----------------------------------------

/// doctors | hospitals | clinics | pharmacies. Part of the path, not a query
/// param, and it also decides whether each row parses as a doctor or a place.
final adminProviderTypeProvider = StateProvider<String>((ref) => 'doctors');

/// Defaults to `pending`: an admin opens this screen to clear a queue, not to
/// browse everyone who is already verified.
final adminProviderVerificationProvider =
    StateProvider<String?>((ref) => 'pending');

final adminProviderStatusProvider = StateProvider<String?>((ref) => null);
final adminProviderSearchProvider = StateProvider<String?>((ref) => null);

final adminProvidersProvider = StateNotifierProvider<
    PagedController<AdminProvider>, PagedState<AdminProvider>>((ref) {
  final type = ref.watch(adminProviderTypeProvider);
  final verification = ref.watch(adminProviderVerificationProvider);
  final status = ref.watch(adminProviderStatusProvider);
  final search = ref.watch(adminProviderSearchProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AdminProvider>(
    (page) => repo.providers(
      type: type,
      page: page,
      verification: verification,
      status: status,
      search: search,
    ),
  );
});

// -- §10.7 Appointments ------------------------------------------------------

final adminApptStatusProvider = StateProvider<String?>((ref) => null);

/// A single day, yyyy-MM-dd — the handler filters on equality, not a range.
final adminApptDateProvider = StateProvider<String?>((ref) => null);

/// Matches either the patient's or the doctor's name.
final adminApptSearchProvider = StateProvider<String?>((ref) => null);

final adminAppointmentsProvider =
    StateNotifierProvider<PagedController<Appointment>, PagedState<Appointment>>(
        (ref) {
  final status = ref.watch(adminApptStatusProvider);
  final date = ref.watch(adminApptDateProvider);
  final search = ref.watch(adminApptSearchProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<Appointment>(
    (page) => repo.appointments(
      page: page,
      status: status,
      date: date,
      search: search,
    ),
  );
});

// -- §10.8 Reviews -----------------------------------------------------------

/// A [String], not a nullable one: the endpoint defaults to `pending` and
/// treats `all` as "no status clause", so there is no "omit the param" case.
final adminReviewStatusProvider = StateProvider<String>((ref) => 'pending');

/// Sent as `type`. Null means every target kind.
final adminReviewTargetProvider = StateProvider<String?>((ref) => null);

final adminReviewsProvider =
    StateNotifierProvider<PagedController<AdminReview>, PagedState<AdminReview>>(
        (ref) {
  final status = ref.watch(adminReviewStatusProvider);
  final target = ref.watch(adminReviewTargetProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AdminReview>(
    (page) => repo.reviews(page: page, status: status, targetType: target),
  );
});

// -- §10.9 Feedback ----------------------------------------------------------

final adminFeedbackStatusProvider = StateProvider<String?>((ref) => null);
final adminFeedbackPriorityProvider = StateProvider<String?>((ref) => null);

final adminFeedbackProvider = StateNotifierProvider<
    PagedController<AdminFeedback>, PagedState<AdminFeedback>>((ref) {
  final status = ref.watch(adminFeedbackStatusProvider);
  final priority = ref.watch(adminFeedbackPriorityProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AdminFeedback>(
    (page) => repo.feedback(page: page, status: status, priority: priority),
  );
});

// -- §10.10 Blood banks ------------------------------------------------------

/// Matches name, address or city — there is no separate city filter.
final adminBloodBankSearchProvider = StateProvider<String?>((ref) => null);

final adminBloodBanksProvider = StateNotifierProvider<
    PagedController<AdminBloodBank>, PagedState<AdminBloodBank>>((ref) {
  final search = ref.watch(adminBloodBankSearchProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AdminBloodBank>(
    (page) => repo.bloodBanks(page: page, search: search),
  );
});

// -- §10.11 Blog -------------------------------------------------------------

final adminBlogStatusProvider = StateProvider<String?>((ref) => null);
final adminBlogSearchProvider = StateProvider<String?>((ref) => null);

final adminBlogsProvider =
    StateNotifierProvider<PagedController<AdminBlog>, PagedState<AdminBlog>>(
        (ref) {
  final status = ref.watch(adminBlogStatusProvider);
  final search = ref.watch(adminBlogSearchProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AdminBlog>(
    (page) => repo.blogs(page: page, status: status, search: search),
  );
});

// -- §10.12 Audit log --------------------------------------------------------

final adminAuditActionProvider = StateProvider<String?>((ref) => null);
final adminAuditEntityProvider = StateProvider<String?>((ref) => null);
final adminAuditSearchProvider = StateProvider<String?>((ref) => null);

/// The summary and the filter dropdown values arrive as siblings of `logs`, so
/// they are held here rather than being re-derived from the page. Updated on
/// every fetch; the first page is what populates the dropdowns.
final adminAuditSummaryProvider = StateProvider<AuditSummary?>((ref) => null);

final adminAuditProvider =
    StateNotifierProvider<PagedController<AuditEntry>, PagedState<AuditEntry>>(
        (ref) {
  final action = ref.watch(adminAuditActionProvider);
  final entity = ref.watch(adminAuditEntityProvider);
  final search = ref.watch(adminAuditSearchProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<AuditEntry>((page) async {
    final res = await repo.auditLog(
      page: page,
      action: action,
      entity: entity,
      search: search,
    );
    // Writing to another provider from inside a fetch is normally a smell, but
    // the summary is only available here and the alternative is a second request
    // for data the server already sent.
    ref.read(adminAuditSummaryProvider.notifier).state = res.summary;
    return res.page;
  });
});

// -- §10.13 Payments ---------------------------------------------------------

final adminPaymentStatusProvider = StateProvider<String?>((ref) => null);

final adminPaymentsProvider = StateNotifierProvider<
    PagedController<ProviderPayment>, PagedState<ProviderPayment>>((ref) {
  final status = ref.watch(adminPaymentStatusProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<ProviderPayment>(
    (page) => repo.payments(page: page, status: status),
  );
});

// -- §10.14 Payouts ----------------------------------------------------------

/// Defaults to `pending` for the same reason every other admin queue does: the
/// settlement screen opens on what needs transferring, and 'All' shows history.
final adminPayoutStatusProvider = StateProvider<String?>((ref) => 'pending');

final adminPayoutsProvider =
    StateNotifierProvider<PagedController<Payout>, PagedState<Payout>>((ref) {
  final status = ref.watch(adminPayoutStatusProvider);
  final repo = ref.watch(adminRepositoryProvider);
  return PagedController<Payout>(
    (page) => repo.payouts(page: page, status: status),
  );
});
