/// §6.1 — the doctor's landing screen.
///
/// Leads with the verification banner because everything else on the screen is
/// moot while the account is unverified: an unverified doctor is absent from the
/// directory, so their zeroes are expected rather than a sign of a quiet week.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/appointment_models.dart';
import '../../../models/provider_models.dart';
import '../../auth/presentation/auth_controller.dart';
import 'provider_controllers.dart';
import 'widgets/stat_grid.dart';
import 'widgets/verification_banner.dart';
import 'widgets/workspace_actions.dart';

class DoctorDashboardScreen extends ConsumerWidget {
  const DoctorDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(doctorDashboardProvider);
    final name = ref.watch(authControllerProvider).user?.name;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My practice'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: const Icon(Icons.notifications_none_rounded),
            onPressed: () => context.push(Routes.notifications),
          ),
          IconButton(
            tooltip: 'My profile',
            icon: const Icon(Icons.person_outline),
            onPressed: () => context.push(Routes.doctorProfile),
          ),
          const WorkspaceActions(),
        ],
      ),
      body: async.when(
        loading: () => const LoadingView(message: 'Loading your dashboard…'),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(doctorDashboardProvider),
        ),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(doctorDashboardProvider),
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.gap),
            children: [
              if (name != null && name.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    name,
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              VerificationBanner(
                status: d.verification,
                accountStatus: d.accountStatus,
                onEditProfile: () => context.push(Routes.doctorProfile),
              ),
              _Stats(stats: d.stats, onTapQueue: (status) {
                // Set the filter before navigating so the list opens on the
                // slice the doctor tapped, not on "All".
                ref.read(doctorApptStatusProvider.notifier).state = status;
                context.push(Routes.doctorAppointments);
              }, onTapPayouts: () => context.push(Routes.doctorPayouts)),
              DashboardSection(
                title: 'Today and next',
                actionLabel: 'All appointments',
                onAction: () {
                  ref.read(doctorApptStatusProvider.notifier).state = null;
                  context.push(Routes.doctorAppointments);
                },
                child: d.recentAppointments.isEmpty
                    ? const _Blank(
                        icon: Icons.event_available_outlined,
                        text: 'No recent appointments.',
                      )
                    : Column(
                        children: [
                          for (final a in d.recentAppointments)
                            _MiniAppointment(appointment: a),
                        ],
                      ),
              ),
              DashboardSection(
                title: 'Quick actions',
                child: Column(
                  children: [
                    _Action(
                      icon: Icons.account_balance_wallet_outlined,
                      title: 'Payouts & balance',
                      subtitle: d.stats.pendingPayout == 0
                          ? 'Nothing pending'
                          : '${d.stats.payoutLabel} waiting for the platform',
                      highlight: d.stats.pendingPayout > 0,
                      onTap: () => context.push(Routes.doctorPayouts),
                    ),
                    _Action(
                      icon: Icons.reviews_outlined,
                      title: 'Reviews about me',
                      subtitle: 'See what patients have written',
                      onTap: () => context.push(Routes.doctorReviews),
                    ),
                    _Action(
                      icon: Icons.badge_outlined,
                      title: 'Profile and chamber details',
                      subtitle: 'Fees, schedule, specialisation',
                      onTap: () => context.push(Routes.doctorProfile),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.gap),
            ],
          ),
        ),
      ),
    );
  }
}

class _Stats extends StatelessWidget {
  const _Stats({
    required this.stats,
    required this.onTapQueue,
    required this.onTapPayouts,
  });

  final DoctorStats stats;

  /// Passes the status to pre-filter with, or null for "all".
  final void Function(String? status) onTapQueue;
  final VoidCallback onTapPayouts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.gap),
      child: StatGrid(
        tiles: [
          stat(
            "Today's appointments",
            stats.today,
            icon: Icons.today_outlined,
            onTap: () => onTapQueue(null),
          ),
          stat(
            'Awaiting confirmation',
            stats.pending,
            icon: Icons.pending_actions_outlined,
            color: stats.pending > 0 ? AppColors.warning : null,
            onTap: () => onTapQueue('pending'),
          ),
          stat(
            'Confirmed',
            stats.confirmed,
            icon: Icons.event_available_outlined,
            color: AppColors.success,
            onTap: () => onTapQueue('confirmed'),
          ),
          stat(
            'Completed',
            stats.completed,
            icon: Icons.task_alt_outlined,
            onTap: () => onTapQueue('completed'),
          ),
          stat(
            'Pending payout',
            stats.pendingPayout,
            icon: Icons.account_balance_wallet_outlined,
            color: stats.pendingPayout > 0 ? AppColors.warning : null,
            onTap: onTapPayouts,
          ),
          // Verified earnings only — a submitted transaction id is not money
          // until it has been checked, so this deliberately lags the bookings.
          stat(
            'Verified earnings',
            stats.earningsLabel,
            icon: Icons.payments_outlined,
            color: AppColors.success,
          ),
        ],
      ),
    );
  }
}

class _MiniAppointment extends StatelessWidget {
  const _MiniAppointment({required this.appointment});

  final Appointment appointment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = appointment;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: AvatarCircle(name: a.patientName, size: 40),
        title: Text(
          a.patientName ?? 'Patient',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyLarge,
        ),
        subtitle: Text(a.whenLabel, style: theme.textTheme.bodySmall),
        trailing: StatusPill(status: a.status, dense: true),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = highlight ? AppSemantic.of(context).warning : theme.colorScheme.primary;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: theme.textTheme.bodyLarge),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class _Blank extends StatelessWidget {
  const _Blank({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Row(
          children: [
            Icon(icon, color: theme.colorScheme.onSurfaceVariant, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
