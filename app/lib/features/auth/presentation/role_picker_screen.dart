/// The fork in the sign-up flow (§3.1–3.5).
///
/// One endpoint serves all five roles, but the forms differ enough that a single
/// screen with a role dropdown would show a doctor eleven fields it then hides
/// again when they switch to patient. Choosing first keeps each form honest about
/// what it needs.
///
/// Patient is listed first and carries no verification notice — it is the only
/// role that is usable the moment the account exists.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../data/registration_fields.dart';

class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key});

  /// Maps each role onto the form that collects its fields.
  static String _routeFor(SignupRole role) => switch (role) {
        SignupRole.patient => Routes.register,
        SignupRole.doctor => Routes.registerDoctor,
        SignupRole.hospital => Routes.registerHospital,
        SignupRole.clinic => Routes.registerClinic,
        SignupRole.pharmacy => Routes.registerPharmacy,
      };

  static IconData _iconFor(SignupRole role) => switch (role) {
        SignupRole.patient => Icons.person_outline,
        SignupRole.doctor => Icons.medical_services_outlined,
        SignupRole.hospital => Icons.local_hospital_outlined,
        SignupRole.clinic => Icons.medical_information_outlined,
        SignupRole.pharmacy => Icons.local_pharmacy_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'How will you use AYUR?',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Pick the closest match. An admin verifies provider accounts '
                  'before they appear in the directory.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                for (final role in SignupRole.values) ...[
                  _RoleCard(
                    role: role,
                    icon: _iconFor(role),
                    onTap: () => context.push(_routeFor(role)),
                  ),
                  const SizedBox(height: 10),
                ],
                const SizedBox(height: 10),
                // Sign-up is commonly reached by someone who already has an
                // account and tapped the wrong button.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Already registered?',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    TextButton(
                      onPressed: () => context.go(Routes.login),
                      child: const Text('Sign in'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.role,
    required this.icon,
    required this.onTap,
  });

  final SignupRole role;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gap),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      role.label,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      role.blurb,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (role.isProvider) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Needs admin verification',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.tertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
