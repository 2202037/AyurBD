/// The AppBar actions every non-patient workspace needs.
///
/// Sign-out used to live on a single placeholder dashboard, which is where all
/// five non-patient roles landed. Now that the doctor, place and admin
/// workspaces each have a real dashboard, sign-out lives here instead — shared,
/// rather than re-implemented per dashboard and forgotten on one of them.
///
/// The same argument covers Account. Only the patient shell has a Profile tab,
/// so without this entry the §5.5 account page — and with it password change,
/// which is not a patient-only feature — would be reachable by no other role.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../app/router.dart';
import '../../../../core/theme_controller.dart';
import '../../../auth/presentation/auth_controller.dart';

/// Drop into `AppBar.actions`. Callers add their own screen-specific buttons
/// before this so the overflow menu stays last.
class WorkspaceActions extends ConsumerWidget {
  const WorkspaceActions({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need to sign in again to continue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // The router's guard watches auth state, so clearing the session is all it
    // takes — no explicit navigation, and none that could race the redirect.
    await ref.read(authControllerProvider.notifier).logout();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeCtl = ref.watch(themeModeProvider.notifier);
    ref.watch(themeModeProvider); // rebuild the icon when the mode cycles

    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        switch (value) {
          case 'account':
            // Push, not go: this sits over the workspace so the back button
            // returns to it. `go` would replace the stack and strand them.
            context.push(Routes.account);
          case 'theme':
            themeCtl.cycle();
          case 'signout':
            _signOut(context, ref);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'account',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.person_outline),
            title: Text('Account'),
            subtitle: Text('Profile and password'),
          ),
        ),
        PopupMenuItem(
          value: 'theme',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(themeCtl.icon),
            title: Text(themeCtl.label),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'signout',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.logout),
            title: Text('Sign out'),
          ),
        ),
      ],
    );
  }
}
