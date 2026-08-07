/// Riverpod wiring for the provider workspaces (feature.md §6–§9).
///
/// Kept in one file because the doctor and place workspaces share the reviews
/// list and the same verification gate; splitting them would mean two copies of
/// the filter plumbing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/paged_controller.dart';
import '../../../models/appointment_models.dart';
import '../../../models/provider_models.dart';
import '../data/provider_repository.dart';

// -- §6.1 Doctor dashboard ---------------------------------------------------

/// `autoDispose` so returning to the dashboard refetches rather than showing
/// yesterday's stats. A dashboard is the one screen where stale numbers are
/// actively misleading.
final doctorDashboardProvider = FutureProvider.autoDispose<DoctorDashboard>(
  (ref) => ref.watch(providerRepositoryProvider).doctorDashboard(),
);

// -- §6.2 Doctor appointments -----------------------------------------------

/// Null means "no filter" — the param is omitted rather than sent empty, which
/// the server's whitelist would reject.
final doctorApptStatusProvider = StateProvider<String?>((ref) => null);

/// A single day, yyyy-MM-dd. The server rejects any other format with a 400
/// rather than guessing, so screens must format via `Fmt.apiDate`.
final doctorApptDateProvider = StateProvider<String?>((ref) => null);

final doctorAppointmentsProvider =
    StateNotifierProvider<PagedController<Appointment>, PagedState<Appointment>>(
        (ref) {
  final status = ref.watch(doctorApptStatusProvider);
  final date = ref.watch(doctorApptDateProvider);
  final repo = ref.watch(providerRepositoryProvider);
  return PagedController<Appointment>(
    (page) => repo.doctorAppointments(page: page, status: status, date: date),
  );
});

// -- §6.3 Payouts / balance --------------------------------------------------

/// Defaults to `pending`: that is the balance the provider acts on. `'all'` is
/// a valid value here, not a null — the server treats it as "no status clause".
final doctorPayoutStatusProvider = StateProvider<String>((ref) => 'pending');

final doctorPayoutsProvider = StateNotifierProvider<
    PagedController<Payout>, PagedState<Payout>>((ref) {
  final status = ref.watch(doctorPayoutStatusProvider);
  final repo = ref.watch(providerRepositoryProvider);
  return PagedController<Payout>(
    (page) => repo.payouts(page: page, status: status),
  );
});

// -- §7–9 Place dashboard ---------------------------------------------------

final placeDashboardProvider = FutureProvider.autoDispose<PlaceDashboard>(
  (ref) => ref.watch(providerRepositoryProvider).placeDashboard(),
);

// -- §6–9 Reviews about me --------------------------------------------------

final providerReviewStatusProvider = StateProvider<String?>((ref) => null);

final providerReviewsProvider = StateNotifierProvider<
    PagedController<ProviderReview>, PagedState<ProviderReview>>((ref) {
  final status = ref.watch(providerReviewStatusProvider);
  final repo = ref.watch(providerRepositoryProvider);
  return PagedController<ProviderReview>(
    (page) => repo.reviews(page: page, status: status),
  );
});
