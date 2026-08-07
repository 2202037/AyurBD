/// Landing screen for doctor / clinic / pharmacy / hospital / admin.
///
/// The agreed scope for this build is §13 phases 1–6 — the patient journey
/// end-to-end. Provider and admin journeys are phases 7+, so rather than ship
/// half-wired dashboards whose API calls would 403 or return shapes nobody has
/// specified yet, those roles land here. This screen is honest about that: it
/// names the role, says what is not built, and offers a way out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_theme.dart';
import '../../../core/theme_controller.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/app_user.dart';
import '../../auth/presentation/auth_controller.dart';

class StubDashboardScreen extends ConsumerWidget {
  const StubDashboardScreen({super.key});

  /// What each role would get once phases 7+ land. Kept here as documentation
  /// rather than as dead navigation — none of these screens exist yet.
  static const Map<UserRole, List<String>> _plannedFeatures = {
    UserRole.doctor: [
      'Today\'s appointment queue with confirm / complete actions',
      'Chamber schedule and slot publishing',
      'Patient history for your own appointments',
      'Earnings summary from completed visits',
    ],
    UserRole.clinic: [
      'Doctor roster management',
      'Clinic profile, services and opening hours',
      'Appointment overview across all your doctors',
    ],
    UserRole.pharmacy: [
      'Product catalogue and stock levels',
      'Incoming order queue with fulfilment status',
      'Prescription verification for flagged items',
    ],
    UserRole.hospital: [
      'Blood bank inventory by group',
      'Incoming blood requests',
      'Department and doctor listings',
    ],
    UserRole.admin: [
      'User approval and suspension across all roles',
      'Content moderation for reviews and blog posts',
      'Platform-wide reporting',
    ],
  };

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to continue.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true) return;
    // The router's guard watches auth state, so clearing the session is all it
    // takes — no explicit navigation.
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final theme = Theme.of(context);
    final themeCtl = ref.watch(themeModeProvider.notifier);
    ref.watch(themeModeProvider); // rebuild the icon when the mode cycles

    final role = user?.role ?? UserRole.patient;
    final planned = _plannedFeatures[role] ?? const <String>[];

    return Scaffold(
      appBar: AppBar(
        title: Text('${role.label} dashboard'),
        actions: [
          IconButton(
            onPressed: themeCtl.cycle,
            icon: Icon(themeCtl.icon),
            tooltip: themeCtl.label,
          ),
          IconButton(
            onPressed: () => _signOut(context, ref),
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.gap),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      AvatarCircle(imagePath: user?.image, name: user?.name, size: 56),
                      const SizedBox(width: AppTheme.gap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.name ?? 'Signed in',
                              style: theme.textTheme.titleLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              user?.email ?? '',
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      StatusPill(status: 'pending', label: role.label, dense: true),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.gap),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.construction_outlined, color: theme.colorScheme.primary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Not built in this milestone',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'This build covers the patient journey end to end. '
                            'The ${role.label.toLowerCase()} workspace is scheduled for a later '
                            'phase, and your account already works — sign in from the web app '
                            'to use it in the meantime.',
                            style: theme.textTheme.bodyMedium,
                          ),
                          if (planned.isNotEmpty) ...[
                            const SizedBox(height: AppTheme.gap),
                            Text('Planned here', style: theme.textTheme.labelLarge),
                            const SizedBox(height: 8),
                            for (final f in planned)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.only(top: 5, right: 8),
                                      child: Icon(
                                        Icons.circle,
                                        size: 6,
                                        color: theme.colorScheme.outline,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(f, style: theme.textTheme.bodySmall),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.gap),
                  OutlinedButton.icon(
                    onPressed: () => _signOut(context, ref),
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
