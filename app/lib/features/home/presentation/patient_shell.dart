/// The patient tab scaffold. Only `patient` ever sees this — every path in the
/// shell is listed in the router's `_patientOnly`, so the guard redirects the
/// other five roles to their own workspace before this widget builds. Nothing
/// here re-checks the role.
///
/// That is also why `/account` exists as a separate root-navigator route: it
/// renders the same ProfileScreen as the Profile tab, but outside this shell,
/// for the roles that must not see these tabs.
///
/// The five branches are an indexed stack, which is what keeps each tab's scroll
/// position and navigation history alive when you switch away and back. Booking,
/// cart and checkout deliberately live *outside* this shell (see router.dart) —
/// they are linear flows, and a visible tab bar invites a mid-checkout tab switch
/// that silently abandons the order.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class PatientShell extends StatelessWidget {
  const PatientShell({super.key, required this.shell});

  /// Supplied by [StatefulShellRoute.indexedStack]. Owns the branch navigators
  /// and the current index; this widget only renders it.
  final StatefulNavigationShell shell;

  /// Order must match the branch order in router.dart. Home, Doctors, Shop,
  /// Appointments, Profile.
  static const List<_Tab> _tabs = [
    _Tab('Home', Icons.home_outlined, Icons.home_rounded),
    _Tab('Doctors', Icons.medical_services_outlined, Icons.medical_services),
    _Tab('Shop', Icons.storefront_outlined, Icons.storefront),
    _Tab('Visits', Icons.event_note_outlined, Icons.event_note),
    _Tab('Profile', Icons.person_outline, Icons.person),
  ];

  void _onTap(int index) {
    // Tapping the tab you are already on pops that branch back to its root —
    // the standard "tap Home again to get out of a detail page" gesture. Passing
    // initialLocation: false on a different tab is what preserves its history.
    shell.goBranch(index, initialLocation: index == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: shell.currentIndex,
        onDestinationSelected: _onTap,
        destinations: [
          for (final t in _tabs)
            NavigationDestination(
              icon: Icon(t.icon),
              selectedIcon: Icon(t.activeIcon),
              label: t.label,
            ),
        ],
      ),
    );
  }
}

class _Tab {
  const _Tab(this.label, this.icon, this.activeIcon);

  final String label;
  final IconData icon;
  final IconData activeIcon;
}
