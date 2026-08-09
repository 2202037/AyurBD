/// §10.2 — the user directory.
///
/// Two actions: delete, which is the only one that is not reversible, and
/// ban/unban, which flips `users.is_active`. Banning is the softer option —
/// the profile and history stay, the server cancels the user's future
/// appointments and notifies them, and every guarded RPC refuses the account
/// until it is un-banned. Both confirm first, because either one lands
/// silently if the tap was a mistake.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/admin_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/admin_repository.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

/// Null is "every role" — the filter provider omits the param entirely.
const _roleFilters = <FilterOption>[
  (value: null, label: 'All'),
  (value: 'patient', label: 'Patients'),
  (value: 'doctor', label: 'Doctors'),
  (value: 'hospital', label: 'Hospitals'),
  (value: 'clinic', label: 'Clinics'),
  (value: 'pharmacy', label: 'Pharmacies'),
  (value: 'admin', label: 'Admins'),
];

class AdminUsersScreen extends ConsumerStatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  ConsumerState<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends ConsumerState<AdminUsersScreen> {
  bool _busy = false;

  PagedController<AdminUser> get _controller =>
      ref.read(adminUsersProvider.notifier);

  Future<void> _delete(AdminUser user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${user.name} · ${user.email}'),
            const SizedBox(height: 12),
            Text(
              // Say what else goes, because the cascade is not obvious from a
              // screen that only shows accounts.
              'This removes the account and everything attached to it — '
              'appointments, orders and reviews. It cannot be undone.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: AppTheme.destructive(ctx),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).deleteUser(user.id);
      _controller.removeWhere((u) => u.id == user.id);
      // The dashboard counts this row, so its totals are now wrong.
      ref.invalidate(adminDashboardProvider);
      if (mounted) showToast(context, 'Account deleted.');
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Ban or un-ban. The confirm dialog spells out what banning actually does,
  /// because "their future appointments are cancelled" is not obvious from a
  /// button labelled Ban.
  Future<void> _toggleActive(AdminUser user) async {
    final banning = user.isActive;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(banning ? 'Ban ${user.name}?' : 'Un-ban ${user.name}?'),
        content: Text(
          banning
              ? 'The account stays, but their future pending/confirmed '
                  'appointments are cancelled and they are notified. They '
                  'cannot sign in to use the app until un-banned.'
              : 'They can sign in and use the app again. Their appointments '
                  'are not restored — the cancelled ones stay cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: banning ? AppTheme.destructive(ctx) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(banning ? 'Ban' : 'Un-ban'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .setUserActive(userId: user.id, active: !banning);
      _controller.replaceWhere((u) => u.id == user.id, user.copyWithActive(!banning));
      if (mounted) {
        showToast(context, banning ? 'Account banned.' : 'Account un-banned.');
      }
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminUsersProvider);
    final role = ref.watch(adminUserRoleProvider);
    // Compared by id, not by email: an admin can rename their own account, and
    // the id is what the server checks.
    final meId = ref.watch(authControllerProvider).user?.id;

    final bar = AdminFilterBar(
      searchHint: 'Search name, email or phone',
      onSearch: (v) => ref.read(adminUserSearchProvider.notifier).state = v,
      options: _roleFilters,
      selected: role,
      onSelected: (v) => ref.read(adminUserRoleProvider.notifier).state = v,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Users'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving…',
        child: PagedListView<AdminUser>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: 'No users',
          emptyIcon: Icons.group_outlined,
          emptyMessage: 'Nothing matches those filters.',
          itemBuilder: (context, u, _) => _UserCard(
            user: u,
            isSelf: u.id == meId,
            onDelete: u.id == meId ? null : () => _delete(u),
            // The server refuses to ban the calling admin too, so the UI
            // hides the option rather than letting a 422 explain itself.
            onToggleActive: u.id == meId ? null : () => _toggleActive(u),
          ),
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({
    required this.user,
    required this.isSelf,
    this.onDelete,
    this.onToggleActive,
  });

  final AdminUser user;
  final bool isSelf;
  final VoidCallback? onDelete;

  /// Ban when the account is active, un-ban when it is banned.
  final VoidCallback? onToggleActive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AvatarCircle(imagePath: user.image, name: user.name, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          user.name,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isSelf) ...[
                        const SizedBox(width: 6),
                        const StatusPill(
                          status: 'verified',
                          label: 'You',
                          dense: true,
                        ),
                      ],
                    ],
                  ),
                  Text(
                    user.email,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      StatusPill(
                        status: user.role.name,
                        label: user.role.label,
                        dense: true,
                      ),
                      if (!user.isActive)
                        const StatusPill(
                          status: 'banned',
                          label: 'Banned',
                          dense: true,
                        ),
                      if (user.city != null)
                        _Meta(icon: Icons.place_outlined, text: user.city!),
                      if (user.phone != null)
                        _Meta(icon: Icons.call_outlined, text: user.phone!),
                      if (user.createdAt != null)
                        _Meta(
                          icon: Icons.schedule,
                          text: 'Joined ${Fmt.dayMonth(user.createdAt)}',
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (onToggleActive != null)
                  IconButton(
                    tooltip: user.isActive ? 'Ban account' : 'Un-ban account',
                    icon: Icon(
                      user.isActive ? Icons.block : Icons.lock_open_outlined,
                      size: 20,
                    ),
                    color: user.isActive
                        ? AppSemantic.of(context).danger
                        : AppSemantic.of(context).success,
                    onPressed: onToggleActive,
                  ),
                if (onDelete != null)
                  IconButton(
                    tooltip: 'Delete account',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    color: AppSemantic.of(context).danger,
                    onPressed: onDelete,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
