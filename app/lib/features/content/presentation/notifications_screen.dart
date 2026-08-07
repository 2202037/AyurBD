/// `/notifications/my` — the patient's notification inbox.
///
/// Two rules this screen follows strictly:
///
/// 1. The unread badge is always the server's `unread_count`, never a count of
///    the rows currently on screen. `notifications_my()` computes it unfiltered,
///    so it stays correct while the list is filtered to unread-only or paged.
///    `markRead`/`markAllRead` both return a fresh count for the same reason.
/// 2. A row is only tappable when it carries both a `type` and a `ref_id`
///    ([AppNotification.isActionable]). The columns are nullable, and routing on
///    a null id would push a detail screen for record 0.
///
/// The `type` strings the backend actually writes are `appointment` (booked and
/// cancelled), `payment`, and `order`. Anything else renders with a neutral icon
/// and stays un-tappable rather than guessing a destination.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../data/content_repository.dart';

/// Unread-only toggle. Watched by [notificationsProvider], so flipping it
/// disposes the old controller and pagination restarts at page 1.
final unreadOnlyProvider = StateProvider<bool>((ref) => false);

/// The badge source of truth. Seeded by every list fetch and every mark-read
/// call, all of which read it from the server.
final unreadCountProvider = StateProvider<int>((ref) => 0);

final notificationsProvider = StateNotifierProvider<PagedController<AppNotification>,
    PagedState<AppNotification>>((ref) {
  final repo = ref.watch(contentRepositoryProvider);
  final unreadOnly = ref.watch(unreadOnlyProvider);

  return PagedController<AppNotification>((page) async {
    final result = await repo.notifications(page: page, unreadOnly: unreadOnly);
    // Writing to another provider during a fetch is safe here — it happens in an
    // async callback, well after the build phase.
    ref.read(unreadCountProvider.notifier).state = result.unreadCount;
    return result.page;
  });
});

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationsProvider);
    final controller = ref.read(notificationsProvider.notifier);
    final unreadOnly = ref.watch(unreadOnlyProvider);
    final unread = ref.watch(unreadCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (unread > 0)
            TextButton.icon(
              onPressed: () => _markAll(context, ref),
              icon: const Icon(Icons.done_all, size: 18),
              label: const Text('Mark all'),
            ),
        ],
      ),
      body: Column(
        children: [
          _FilterBar(
            unreadOnly: unreadOnly,
            unread: unread,
            onChanged: (v) => ref.read(unreadOnlyProvider.notifier).state = v,
          ),
          Expanded(
            child: PagedListView<AppNotification>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              gap: 8,
              emptyTitle: unreadOnly ? 'All caught up' : 'Nothing yet',
              emptyMessage: unreadOnly
                  ? 'You have read everything. Turn off the filter to see older notifications.'
                  : 'Updates about your appointments, payments and orders will appear here.',
              emptyIcon: unreadOnly
                  ? Icons.mark_email_read_outlined
                  : Icons.notifications_none_outlined,
              itemBuilder: (context, n, _) => _NotificationTile(
                notification: n,
                onTap: () => _open(context, ref, n),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _markAll(BuildContext context, WidgetRef ref) async {
    try {
      final count = await ref.read(contentRepositoryProvider).markAllRead();
      ref.read(unreadCountProvider.notifier).state = count;
      // Every row's is_read changed, so a reload is the honest refresh here —
      // patching them one by one would be the same work with more chances to
      // drift from the server.
      await ref.read(notificationsProvider.notifier).refresh();
    } on ApiException catch (e) {
      if (context.mounted) showToast(context, e.message, error: true);
    }
  }

  /// Marks read, then routes. The mark is fire-and-forget in the sense that a
  /// failure must not block navigation — the user tapped to read something.
  Future<void> _open(BuildContext context, WidgetRef ref, AppNotification n) async {
    final destination = _routeFor(n);

    if (!n.isRead) {
      // Optimistic: flip the row immediately so the tap feels instant, then let
      // the server's authoritative count replace the badge.
      ref.read(notificationsProvider.notifier).replaceWhere(
            (row) => row.id == n.id,
            n.markRead(),
          );
      unawaited(_syncRead(ref, n.id));
    }

    if (destination == null) {
      if (context.mounted && !n.isActionable) {
        // Not an error — plenty of notifications are purely informational.
        showToast(context, 'Nothing more to show for this one.');
      }
      return;
    }
    if (context.mounted) context.push(destination);
  }

  Future<void> _syncRead(WidgetRef ref, int id) async {
    try {
      final count = await ref.read(contentRepositoryProvider).markRead(id);
      ref.read(unreadCountProvider.notifier).state = count;
    } catch (_) {
      // The optimistic flip stands; the next list fetch will correct it if the
      // write really failed.
    }
  }

  /// Only the three types the backend writes are routed. `payment` deep-links to
  /// the payments ledger rather than to `ref_id` — that id is the *appointment*
  /// id (see appointments.php), and there is no per-payment detail screen.
  static String? _routeFor(AppNotification n) {
    if (!n.isActionable) return null;
    final id = n.referenceId!;
    switch (n.type) {
      case 'appointment':
        return Routes.appointments;
      case 'payment':
        return Routes.payments;
      case 'order':
        return Routes.orderDetail(id);
      default:
        return null;
    }
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.unreadOnly,
    required this.unread,
    required this.onChanged,
  });

  final bool unreadOnly;
  final int unread;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppTheme.gap, 10, AppTheme.gap, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              unread == 0
                  ? 'No unread notifications'
                  : '$unread unread notification${unread == 1 ? '' : 's'}',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          FilterChip(
            label: const Text('Unread only'),
            selected: unreadOnly,
            onSelected: onChanged,
          ),
        ],
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.notification, required this.onTap});

  final AppNotification notification;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final n = notification;
    final accent = _colorFor(n.type, theme);

    return Card(
      clipBehavior: Clip.antiAlias,
      // Unread rows get a tinted surface. It is a background wash rather than a
      // dot so the difference survives a glance at arm's length.
      color: n.isRead ? null : theme.colorScheme.primary.withValues(alpha: AppSemantic.of(context).tintAlpha),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: AppSemantic.of(context).tintAlpha),
                  borderRadius: BorderRadius.circular(19),
                ),
                child: Icon(_iconFor(n.type), size: 19, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            n.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!n.isRead) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (n.body.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        n.body,
                        style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          n.timeLabel,
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                        if (n.isActionable) ...[
                          const Spacer(),
                          Icon(Icons.chevron_right, size: 16, color: muted),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(String? type) => switch (type) {
        'appointment' => Icons.event_available_outlined,
        'payment' => Icons.payments_outlined,
        'order' => Icons.local_shipping_outlined,
        'blood' => Icons.bloodtype_outlined,
        _ => Icons.notifications_none_outlined,
      };

  static Color _colorFor(String? type, ThemeData theme) => switch (type) {
        'appointment' => theme.colorScheme.primary,
        'payment' => theme.colorScheme.secondary,
        'order' => theme.colorScheme.tertiary,
        'blood' => theme.colorScheme.error,
        _ => theme.colorScheme.onSurfaceVariant,
      };
}
