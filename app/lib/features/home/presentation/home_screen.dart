/// The patient landing tab.
///
/// Deliberately thin on data: a greeting, the quick-action grid that is the real
/// navigation surface of the app, and one short strip of top-rated doctors. Two
/// network calls at most, both independently recoverable — the home tab is the
/// first thing a cold-started app renders, so a directory outage must not leave
/// the user staring at a full-screen error with no way to reach the other tabs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_config.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_result.dart';
import '../../../core/theme_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/directory_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../content/data/content_repository.dart';
import '../../directory/data/directory_repository.dart';

/// Unread badge count. Autodispose so it refetches when the user comes back to
/// the tab rather than showing a count from twenty minutes ago.
final _unreadCountProvider = FutureProvider.autoDispose<int>((ref) async {
  // limit: 1 — we want the count, not the list. `unread_count` is computed
  // unfiltered server-side, so a one-row page carries the same total.
  final res = await ref.watch(contentRepositoryProvider).notifications(limit: 1);
  return res.unreadCount;
});

/// A handful of top-rated doctors for the home strip.
///
/// No `sort:` argument on purpose. `/directory/doctors` does not read a sort
/// parameter at all — its ORDER BY is fixed at `d.rating DESC, d.id DESC` — so
/// passing one would be silently ignored and would read as a guarantee the API
/// never made. The default order already is "top rated".
final _featuredDoctorsProvider = FutureProvider.autoDispose<Paged<Doctor>>((ref) {
  return ref.watch(directoryRepositoryProvider).doctors(limit: 5);
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const List<_Action> _actions = [
    _Action('Doctors', Icons.medical_services_outlined, Routes.doctors),
    _Action('Clinics', Icons.local_hospital_outlined, Routes.clinics),
    _Action('Hospitals', Icons.apartment_outlined, Routes.hospitals),
    _Action('Pharmacies', Icons.local_pharmacy_outlined, Routes.pharmacies),
    _Action('Blood bank', Icons.bloodtype_outlined, Routes.bloodBank),
    _Action('Medicines', Icons.shopping_bag_outlined, Routes.shop),
    _Action('My visits', Icons.event_note_outlined, Routes.appointments),
    _Action('Health blog', Icons.article_outlined, Routes.blog),
    _Action('Nearby', Icons.near_me_outlined, Routes.nearby, push: true),
    _Action('Emergency', Icons.emergency_outlined, Routes.emergency, push: true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider);
    final themeCtl = ref.watch(themeModeProvider.notifier);
    ref.watch(themeModeProvider); // rebuilds the toolbar icon when the mode cycles

    final unread = ref.watch(_unreadCountProvider);
    final featured = ref.watch(_featuredDoctorsProvider);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(_unreadCountProvider);
            ref.invalidate(_featuredDoctorsProvider);
            await Future.wait([
              ref.read(_unreadCountProvider.future).catchError((_) => 0),
              ref
                  .read(_featuredDoctorsProvider.future)
                  .catchError((_) => Paged.empty<Doctor>()),
            ]);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _Header(
                name: user?.name,
                image: user?.image,
                unread: unread.asData?.value ?? 0,
                themeIcon: themeCtl.icon,
                themeLabel: themeCtl.label,
                onCycleTheme: themeCtl.cycle,
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
                child: _SearchBar(onTap: () => context.go(Routes.doctors)),
              ),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppTheme.gap),
                child: _ActionGrid(actions: _actions),
              ),
              const SizedBox(height: 8),
              // SectionHeader carries only bottom padding, so the horizontal
              // inset has to come from here to line up with the grid above it.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
                child: SectionHeader(
                  title: 'Top rated doctors',
                  actionLabel: 'See all',
                  onAction: () => context.go(Routes.doctors),
                ),
              ),
              _FeaturedStrip(
                state: featured,
                onRetry: () => ref.invalidate(_featuredDoctorsProvider),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
                child: _EmergencyCard(onTap: () => context.go(Routes.bloodBank)),
              ),
              const SizedBox(height: 20),
              Center(
                child: Text(
                  '${AppConfig.appName} — Ayurvedic care, Bangladesh',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Action {
  const _Action(this.label, this.icon, this.route, {this.push = false});

  final String label;
  final IconData icon;
  final String route;

  /// True for routes that live on the root navigator rather than inside the tab
  /// shell. Those need `push`: `go` would replace the shell itself, and the user
  /// would land on a full-screen page with no tab bar and no way back.
  final bool push;
}

/// Greeting row with the avatar, the notification bell and the theme toggle.
/// Painted on the primary colour so the tab reads as a "home" rather than
/// another list screen.
class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.image,
    required this.unread,
    required this.themeIcon,
    required this.themeLabel,
    required this.onCycleTheme,
  });

  final String? name;
  final String? image;
  final int unread;
  final IconData themeIcon;
  final String themeLabel;
  final VoidCallback onCycleTheme;

  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onPrimary = theme.colorScheme.onPrimary;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.primary,
        borderRadius: const BorderRadius.vertical(
          bottom: Radius.circular(AppTheme.radius * 2),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppTheme.gap,
        AppTheme.gap,
        AppTheme.gap,
        AppTheme.gap * 1.75,
      ),
      child: Row(
        children: [
          AvatarCircle(imagePath: image, name: name, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _greeting,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: onPrimary.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  name ?? 'Welcome',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCycleTheme,
            icon: Icon(themeIcon, color: onPrimary),
            tooltip: themeLabel,
          ),
          _BellButton(unread: unread, color: onPrimary),
        ],
      ),
    );
  }
}

class _BellButton extends StatelessWidget {
  const _BellButton({required this.unread, required this.color});

  final int unread;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      onPressed: () => context.go(Routes.notifications),
      icon: Icon(Icons.notifications_outlined, color: color),
      tooltip: 'Notifications',
    );
    if (unread <= 0) return button;

    return Badge.count(
      count: unread,
      alignment: Alignment.topRight,
      offset: const Offset(-6, 6),
      child: button,
    );
  }
}

/// Not a real text field — tapping it hands off to the doctors tab, which owns
/// the actual search. One search implementation, not two.
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppTheme.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.search, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(
                'Search doctors, specialities…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.actions});

  final List<_Action> actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Four across on a phone, more on a tablet or desktop window. Computed
        // from width rather than hard-coded so the grid does not stretch into
        // four enormous tiles on a wide window.
        final columns = (constraints.maxWidth / 96).floor().clamp(3, 6);
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.88,
          children: [for (final a in actions) _ActionTile(action: a)],
        );
      },
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.action});

  final _Action action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // `go` for tab destinations — pushing would stack a second copy of a tab
        // root on top of the shell. `push` for the root-navigator screens, which
        // `go` would swap the whole shell out for.
        onTap: () => action.push
            ? context.push(action.route)
            : context.go(action.route),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary
                      .withValues(alpha: AppSemantic.of(context).tintAlpha),
                  shape: BoxShape.circle,
                ),
                child: Icon(action.icon, color: theme.colorScheme.primary, size: 22),
              ),
              const SizedBox(height: 8),
              Text(
                action.label,
                style: theme.textTheme.labelSmall,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontally scrolling doctor cards. Failure here is inline and retryable —
/// it must not take the rest of the home tab down with it.
class _FeaturedStrip extends StatelessWidget {
  const _FeaturedStrip({required this.state, required this.onRetry});

  final AsyncValue<Paged<Doctor>> state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 186,
      child: state.when(
        loading: () => const LoadingView(),
        error: (e, _) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
          child: ErrorView(error: e, onRetry: onRetry),
        ),
        data: (paged) {
          if (paged.isEmpty) {
            return const EmptyView(
              message: 'No doctors listed yet.',
              icon: Icons.medical_services_outlined,
            );
          }
          return ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
            itemCount: paged.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _DoctorCard(doctor: paged.items[i]),
          );
        },
      ),
    );
  }
}

class _DoctorCard extends StatelessWidget {
  const _DoctorCard({required this.doctor});

  final Doctor doctor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 156,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.go(Routes.doctorDetail(doctor.id)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AvatarCircle(imagePath: doctor.image, name: doctor.name, size: 40),
                    const Spacer(),
                    Icon(Icons.star_rounded, size: 15, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 2),
                    Text(Fmt.rating(doctor.rating), style: theme.textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  doctor.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  doctor.specialty,
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const Spacer(),
                Text(
                  doctor.feeLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmergencyCard extends StatelessWidget {
  const _EmergencyCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: theme.colorScheme.errorContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gap),
          child: Row(
            children: [
              Icon(Icons.bloodtype, color: theme.colorScheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Need blood urgently?',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Check hospital stock near you and post a request.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.colorScheme.onErrorContainer),
            ],
          ),
        ),
      ),
    );
  }
}
