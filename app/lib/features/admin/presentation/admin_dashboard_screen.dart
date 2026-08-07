/// §10.1 — the admin console home.
///
/// The console's job is to answer one question on open: what is waiting on me?
/// So the four pending queues come first, above the platform totals, and each
/// tile navigates to its list with the matching filter already set — an admin
/// tapping "12 pending reviews" should land on those twelve, not on every review
/// ever written.
///
/// `pending_verifications` arrives split by provider type as well as a total, so
/// the moderation entry points are per-type rather than one lump list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/admin_models.dart';
import '../../provider/presentation/widgets/stat_grid.dart';
import '../../provider/presentation/widgets/workspace_actions.dart';
import 'admin_controllers.dart';

/// Label, path segment and icon for each moderation list. Kept as data so the
/// tiles, the badges and the navigation all read from one place.
const _providerTypes = <({String type, String label, IconData icon})>[
  (type: 'doctors', label: 'Doctors', icon: Icons.medical_services_outlined),
  (type: 'hospitals', label: 'Hospitals', icon: Icons.local_hospital_outlined),
  (type: 'clinics', label: 'Clinics', icon: Icons.medical_information_outlined),
  (type: 'pharmacies', label: 'Pharmacies', icon: Icons.local_pharmacy_outlined),
];

class AdminDashboardScreen extends ConsumerWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminDashboardProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin console'),
        actions: [
          IconButton(
            tooltip: 'Audit log',
            icon: const Icon(Icons.history),
            onPressed: () => context.push(Routes.adminAudit),
          ),
          const WorkspaceActions(),
        ],
      ),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(adminDashboardProvider),
        ),
        data: (d) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(adminDashboardProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gap,
              AppTheme.gap,
              AppTheme.gap,
              AppTheme.gap * 2,
            ),
            children: [
              _Attention(counts: d.counts),
              DashboardSection(
                title: 'Waiting on you',
                child: StatGrid(tiles: _queues(context, ref, d.counts)),
              ),
              DashboardSection(
                title: 'Verification queues',
                child: _VerificationQueues(pendingByType: d.pendingByType),
              ),
              DashboardSection(
                title: 'Platform',
                child: StatGrid(tiles: _totals(context, d.counts)),
              ),
              const DashboardSection(
                title: 'Manage',
                child: _ManageGrid(),
              ),
              DashboardSection(
                title: 'Recent activity',
                actionLabel: d.recentActivity.isEmpty ? null : 'Full log',
                onAction: d.recentActivity.isEmpty
                    ? null
                    : () => context.push(Routes.adminAudit),
                child: _Activity(entries: d.recentActivity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The four queues, each tapping through with its filter pre-set. A queue at
  /// zero stays on screen rather than being hidden: "0 pending" is the answer
  /// the admin came for, and a disappearing tile reads as a loading bug.
  List<StatTile> _queues(BuildContext context, WidgetRef ref, AdminCounts c) {
    Color tone(int n) => n == 0 ? AppColors.success : AppColors.warning;

    return [
      stat(
        'Verifications',
        c.pendingVerifications,
        icon: Icons.verified_outlined,
        color: tone(c.pendingVerifications),
        onTap: () {
          ref.read(adminProviderVerificationProvider.notifier).state = 'pending';
          context.push(Routes.adminProviders);
        },
      ),
      stat(
        'Reviews',
        c.pendingReviews,
        icon: Icons.rate_review_outlined,
        color: tone(c.pendingReviews),
        onTap: () {
          ref.read(adminReviewStatusProvider.notifier).state = 'pending';
          context.push(Routes.adminReviews);
        },
      ),
      stat(
        'Feedback',
        c.pendingFeedback,
        icon: Icons.support_agent_outlined,
        color: tone(c.pendingFeedback),
        onTap: () {
          ref.read(adminFeedbackStatusProvider.notifier).state = 'pending';
          context.push(Routes.adminFeedback);
        },
      ),
      stat(
        'Payments',
        c.pendingPayments,
        icon: Icons.receipt_long_outlined,
        color: tone(c.pendingPayments),
        onTap: () {
          ref.read(adminPaymentStatusProvider.notifier).state = 'pending';
          context.push(Routes.adminPayments);
        },
      ),
    ];
  }

  List<StatTile> _totals(BuildContext context, AdminCounts c) => [
        stat('Users', c.users, icon: Icons.group_outlined,
            onTap: () => context.push(Routes.adminUsers)),
        stat('Patients', c.patients, icon: Icons.personal_injury_outlined),
        stat('Doctors', c.doctors, icon: Icons.medical_services_outlined),
        stat('Hospitals', c.hospitals, icon: Icons.local_hospital_outlined),
        stat('Clinics', c.clinics, icon: Icons.medical_information_outlined),
        stat('Pharmacies', c.pharmacies, icon: Icons.local_pharmacy_outlined),
        stat('Blood banks', c.bloodBanks, icon: Icons.bloodtype_outlined,
            onTap: () => context.push(Routes.adminBloodBanks)),
        stat('Appointments', c.appointments, icon: Icons.event_available_outlined,
            onTap: () => context.push(Routes.adminAppointments)),
        // Verified payments only — the same rule as the doctor dashboard, so
        // the two numbers agree.
        stat('Revenue', c.revenueLabel,
            icon: Icons.payments_outlined, color: AppColors.success),
      ];
}

/// A single line at the top saying whether anything needs doing. Cheap to read
/// at a glance, which is the point — the tiles below give the breakdown.
class _Attention extends StatelessWidget {
  const _Attention({required this.counts});

  final AdminCounts counts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = counts.totalPending;
    final clear = n == 0;
    final color = clear ? AppSemantic.of(context).success : AppSemantic.of(context).warning;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Row(
        children: [
          Icon(
            clear ? Icons.check_circle_outline : Icons.pending_actions,
            color: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              clear
                  ? 'All queues are clear.'
                  : '$n item${n == 1 ? '' : 's'} waiting on a decision.',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row per provider type, badged with its own pending count. Tapping sets
/// both the type and the pending filter before pushing, so the list opens on
/// exactly the rows the badge counted.
class _VerificationQueues extends ConsumerWidget {
  const _VerificationQueues({required this.pendingByType});

  final Map<String, int> pendingByType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final t in _providerTypes) ...[
            ListTile(
              leading: Icon(t.icon),
              title: Text(t.label),
              trailing: _Badge(count: pendingByType[t.type] ?? 0),
              onTap: () {
                ref.read(adminProviderTypeProvider.notifier).state = t.type;
                ref.read(adminProviderVerificationProvider.notifier).state =
                    'pending';
                ref.read(adminProviderStatusProvider.notifier).state = null;
                ref.read(adminProviderSearchProvider.notifier).state = null;
                context.push(Routes.adminProviders);
              },
            ),
            if (t.type != _providerTypes.last.type) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Nothing pending shows a plain chevron rather than a "0" chip — a zero in
    // a warning-coloured pill reads as a problem when it is the opposite.
    if (count == 0) {
      return Icon(Icons.chevron_right, color: theme.colorScheme.outline);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: AppSemantic.of(context).warning.withValues(alpha: AppSemantic.of(context).tintAlpha),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: AppSemantic.of(context).warning,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Icon(Icons.chevron_right, color: theme.colorScheme.outline),
      ],
    );
  }
}

/// The lists that are not queues — content and records an admin edits or reads
/// rather than clears. Separate from "Waiting on you" so an empty queue section
/// does not bury the everyday navigation.
class _ManageGrid extends StatelessWidget {
  const _ManageGrid();

  @override
  Widget build(BuildContext context) {
    const items = <({String label, IconData icon, String route})>[
      (label: 'Users', icon: Icons.group_outlined, route: Routes.adminUsers),
      (
        label: 'Appointments',
        icon: Icons.event_note_outlined,
        route: Routes.adminAppointments
      ),
      (
        label: 'Blood banks',
        icon: Icons.bloodtype_outlined,
        route: Routes.adminBloodBanks
      ),
      (label: 'Blog', icon: Icons.article_outlined, route: Routes.adminBlogs),
      (
        label: 'Payments',
        icon: Icons.payments_outlined,
        route: Routes.adminPayments
      ),
      (
        label: 'Payouts',
        icon: Icons.account_balance_wallet_outlined,
        route: Routes.adminPayouts
      ),
      (label: 'Audit log', icon: Icons.history, route: Routes.adminAudit),
    ];

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final i in items) ...[
            ListTile(
              leading: Icon(i.icon),
              title: Text(i.label),
              trailing: Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.outline,
              ),
              onTap: () => context.push(i.route),
            ),
            if (i.route != items.last.route) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

/// The last few audit entries. Uses [AuditEntry.actorLabel] rather than
/// `userName` directly, because `user_id` is ON DELETE SET NULL — a real entry
/// can have no actor, and "System" is a better answer than a blank line.
class _Activity extends StatelessWidget {
  const _Activity({required this.entries});

  final List<AuditEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(20),
          child: EmptyView(
            icon: Icons.history_toggle_off,
            message: 'Nothing has been logged yet.',
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final shown = entries.take(8).toList();

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            ListTile(
              dense: true,
              leading: _ActionDot(action: shown[i].action),
              title: Text(
                '${shown[i].actorLabel} · ${Fmt.label(shown[i].action)}',
                style: theme.textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${shown[i].targetLabel} · ${shown[i].timeLabel}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (i != shown.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

/// Colour-codes the verb. Deletes are the ones worth spotting in a scan.
class _ActionDot extends StatelessWidget {
  const _ActionDot({required this.action});

  final String action;

  @override
  Widget build(BuildContext context) {
    final a = action.toLowerCase();
    final (color, icon) = switch (true) {
      _ when a.contains('delete') => (AppSemantic.of(context).danger, Icons.delete_outline),
      _ when a.contains('create') || a.contains('insert') => (
          AppSemantic.of(context).success,
          Icons.add
        ),
      _ when a.contains('reject') => (AppSemantic.of(context).danger, Icons.close),
      _ when a.contains('verify') || a.contains('approve') => (
          AppSemantic.of(context).success,
          Icons.check
        ),
      _ => (Theme.of(context).colorScheme.primary, Icons.edit_outlined),
    };

    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 16, color: color),
    );
  }
}
