/// §10.3–10.6 — provider verification and moderation.
///
/// One screen for doctors, hospitals, clinics and pharmacies: the type picker at
/// the top decides which table the backend reads from, and the rows parse
/// accordingly. Verifying is what unlocks the provider's workspace and makes them
/// visible in the public directory, so this is the queue an admin clears first.
///
/// A rejected provider sees "not approved" on their own dashboard and gets the
/// reason in a notification, so it is worth asking for even though the server
/// allows an empty one. Deactivating is softer than rejecting — it keeps them
/// verified but hides them from the public directory, which is what an admin does
/// when a licence expires and the provider has to re-upload.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/admin_models.dart';
import '../data/admin_repository.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

const _types = <FilterOption>[
  (value: 'doctors', label: 'Doctors'),
  (value: 'hospitals', label: 'Hospitals'),
  (value: 'clinics', label: 'Clinics'),
  (value: 'pharmacies', label: 'Pharmacies'),
];

const _verificationFilters = <FilterOption>[
  (value: 'pending', label: 'Pending'),
  (value: 'verified', label: 'Verified'),
  (value: 'rejected', label: 'Rejected'),
  (value: null, label: 'All'),
];

const _statusFilters = <FilterOption>[
  (value: null, label: 'Any'),
  (value: 'active', label: 'Active'),
  (value: 'inactive', label: 'Inactive'),
];

class AdminProvidersScreen extends ConsumerStatefulWidget {
  const AdminProvidersScreen({super.key});

  @override
  ConsumerState<AdminProvidersScreen> createState() =>
      _AdminProvidersScreenState();
}

class _AdminProvidersScreenState extends ConsumerState<AdminProvidersScreen> {
  bool _busy = false;

  PagedController<AdminProvider> get _controller =>
      ref.read(adminProvidersProvider.notifier);

  Future<void> _moderate(
    AdminProvider p, {
    required ModerationAction action,
  }) async {
    String? reason;
    if (action == ModerationAction.reject) {
      reason = await _askReason(p);
      if (reason == null || reason.isEmpty) return;
    } else {
      final ok = await _confirm(p, action: action);
      if (ok != true) return;
    }

    setState(() => _busy = true);
    try {
      final type = ref.read(adminProviderTypeProvider);
      await ref.read(adminRepositoryProvider).moderateProvider(
            type: type,
            id: p.id,
            action: action,
            reason: reason,
          );

      // The handler returns nothing, so remove from the current filter or
      // refetch the whole list. Removing is faster and less jarring.
      final vFilter = ref.read(adminProviderVerificationProvider);
      final sFilter = ref.read(adminProviderStatusProvider);
      if ((vFilter == 'pending' && action != ModerationAction.activate) ||
          (sFilter == 'active' && action == ModerationAction.deactivate) ||
          (sFilter == 'inactive' && action == ModerationAction.activate)) {
        _controller.removeWhere((row) => row.id == p.id);
      } else {
        await _controller.reload();
      }

      ref.invalidate(adminDashboardProvider);
      if (mounted) showToast(context, '${action.label} complete.');
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) {
        showToast(context, e.message, error: true);
      }
    } catch (_) {
      if (mounted) showToast(context, 'Something went wrong.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirm(AdminProvider p, {required ModerationAction action}) {
    final verb = action.label;
    final name = p.name;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$verb $name?'),
        content: Text(_hint(action)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(verb),
          ),
        ],
      ),
    );
  }

  String _hint(ModerationAction action) => switch (action) {
        ModerationAction.verify =>
          'Verifying unlocks their workspace and makes them visible in the public '
              'directory.',
        ModerationAction.activate =>
          'Reactivating makes them visible in the public directory again.',
        ModerationAction.deactivate =>
          'Deactivating keeps them verified but hides them from the public directory. '
              'Use this when a licence expires.',
        _ => '',
      };

  Future<String?> _askReason(AdminProvider p) {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject this provider'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The provider sees this reason, so say what needs fixing.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                maxLines: 3,
                maxLength: 500,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'e.g. the uploaded licence document is unreadable',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').trim().length < 5
                    ? 'Please give a reason of at least 5 characters.'
                    : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
          FilledButton(
            style: AppTheme.destructive(ctx),
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(ctx, controller.text.trim());
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  /// Edits `doctors.consultation_fee` — the DB-stored figure new bookings are
  /// charged. Existing bookings keep the fee captured when they were made.
  Future<void> _editFee(AdminProvider p) async {
    final controller = TextEditingController(
      text: p.doctor != null && p.doctor!.consultationFee > 0
          ? p.doctor!.consultationFee.toStringAsFixed(2)
          : '',
    );
    final formKey = GlobalKey<FormState>();

    final fee = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Consultation fee'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Fee (৳)',
              prefixText: '৳ ',
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              final value = double.tryParse((v ?? '').trim());
              if (value == null || value < 0) {
                return 'Enter a valid fee in taka.';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(ctx, double.tryParse(controller.text.trim()));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (fee == null) return;

    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).updateConsultationFee(
            doctorId: p.id,
            fee: fee,
          );
      // The card shows the old fee until a reload; refresh the page.
      await _controller.reload();
      if (mounted) showToast(context, 'Fee updated to ${Fmt.money(fee)}.');
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Edits the platform commission (`commission_percentage`) on any provider —
  /// the percentage of every future paid appointment fee (or paid order) that
  /// is retained by the platform. Blood banks have none. Only affects future
  /// payments: the split is computed at verification time.
  Future<void> _editCommission(AdminProvider p) async {
    final controller = TextEditingController(
      text: p.commissionPercentage.toStringAsFixed(2),
    );
    final formKey = GlobalKey<FormState>();

    final percent = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Platform commission'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: controller,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Commission (%)',
                  prefixText: '% ',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final value = double.tryParse((v ?? '').trim());
                  if (value == null || value < 0 || value > 100) {
                    return 'Enter a percentage between 0 and 100.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Kept out of every verified payment before the rest is '
                'credited to the provider. Applies from the next payment.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(ctx, double.tryParse(controller.text.trim()));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (percent == null) return;

    setState(() => _busy = true);
    try {
      final type = ref.read(adminProviderTypeProvider);
      await ref.read(adminRepositoryProvider).updateCommission(
            type: type,
            id: p.id,
            percent: percent,
          );
      await _controller.reload();
      if (mounted) showToast(context, 'Commission updated to $percent%.');
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (_) {
      if (mounted) showToast(context, 'Something went wrong.', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Soft-delete or restore a listing (`is_deleted`). Deleting keeps every
  /// history row but hides the provider from the public directory and blocks
  /// new bookings — the hard-delete-shaped decision, minus the data loss.
  Future<void> _toggleDelete(AdminProvider p) async {
    final deleting = !p.isDeleted;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(deleting ? 'Hide ${p.name}?' : 'Restore ${p.name}?'),
        content: Text(
          deleting
              ? 'The provider disappears from the public directory and can no '
                  'longer be booked. Their history stays intact.'
              : 'The provider becomes visible in the public directory and can '
                  'be booked again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: deleting ? AppTheme.destructive(ctx) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(deleting ? 'Hide' : 'Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      final type = ref.read(adminProviderTypeProvider);
      await ref.read(adminRepositoryProvider).setProviderDeleted(
            type: type,
            id: p.id,
            deleted: deleting,
          );
      await _controller.reload();
      if (mounted) {
        showToast(context, deleting ? 'Listing hidden.' : 'Listing restored.');
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
    final state = ref.watch(adminProvidersProvider);
    final type = ref.watch(adminProviderTypeProvider);
    final verification = ref.watch(adminProviderVerificationProvider);
    final status = ref.watch(adminProviderStatusProvider);

    final bar = AdminFilterBar(
      searchHint: 'Search name, email or city',
      onSearch: (v) => ref.read(adminProviderSearchProvider.notifier).state = v,
      options: _verificationFilters,
      selected: verification,
      onSelected: (v) =>
          ref.read(adminProviderVerificationProvider.notifier).state = v,
      trailing: Row(
        children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(
                labelText: 'Type',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: _types
                  .map((t) => DropdownMenuItem(value: t.value, child: Text(t.label)))
                  .toList(),
              onChanged: (v) {
                if (v != null) ref.read(adminProviderTypeProvider.notifier).state = v;
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String?>(
              initialValue: status,
              decoration: const InputDecoration(
                labelText: 'Status',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: _statusFilters
                  .map((f) => DropdownMenuItem(value: f.value, child: Text(f.label)))
                  .toList(),
              onChanged: (v) => ref.read(adminProviderStatusProvider.notifier).state = v,
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Providers'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving…',
        child: PagedListView<AdminProvider>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: 'No providers',
          emptyIcon: Icons.medical_services_outlined,
          emptyMessage: 'Nothing matches those filters.',
          itemBuilder: (context, p, _) => _ProviderCard(
            provider: p,
            onAction: (action) => _moderate(p, action: action),
            // The fee is a doctor concept; the other three types have none.
            onEditFee: p.doctor != null ? () => _editFee(p) : null,
            onEditCommission: () => _editCommission(p),
            onToggleDelete: () => _toggleDelete(p),
          ),
        ),
      ),
    );
  }
}

/// One row in the moderation list. Shows the credential the admin checks
/// — BMDC for doctors, licence for the rest — and the four actions that apply
/// based on the current state: verify/reject for a pending row, activate or
/// deactivate for a verified one.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({
    required this.provider,
    required this.onAction,
    this.onEditFee,
    required this.onEditCommission,
    required this.onToggleDelete,
  });

  final AdminProvider provider;
  final ValueChanged<ModerationAction> onAction;

  /// Null for hospitals/clinics/pharmacies — they have no consultation fee.
  final VoidCallback? onEditFee;

  /// The platform commission is settable on every provider type.
  final VoidCallback onEditCommission;

  /// Soft-delete/restore the listing.
  final VoidCallback onToggleDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = provider;
    final muted = theme.colorScheme.onSurfaceVariant;
    final credential = p.credential;
    final doc = p.credentialDocument;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AvatarCircle(
                  imagePath: doc,
                  name: p.name,
                  size: 40,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, style: theme.textTheme.titleSmall,
                           maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (p.ownerEmail != null)
                        Text(p.ownerEmail!,
                            style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          StatusPill(status: p.verification, dense: true),
                          const SizedBox(width: 6),
                          StatusPill(status: p.status, dense: true),
                          if (p.isDeleted) ...[
                            const SizedBox(width: 6),
                            const StatusPill(
                              status: 'banned',
                              label: 'Hidden',
                              dense: true,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (credential != null) ...[
              const SizedBox(height: 10),
              _Meta(
                icon: Icons.description_outlined,
                label: credential.startsWith('A') ? 'BMDC' : 'Licence',
                value: credential,
              ),
            ],
            if (p.doctor != null) ...[
              const SizedBox(height: 3),
              _Meta(
                icon: Icons.payments_outlined,
                label: 'Fee',
                value: p.doctor!.feeLabel,
              ),
            ],
            const SizedBox(height: 3),
            _Meta(
              icon: Icons.percent_outlined,
              label: 'Commission',
              value: '${p.commissionPercentage.toStringAsFixed(2)}% kept by platform',
            ),
            if (p.city != null)
              _Meta(
                icon: Icons.place_outlined,
                label: 'City',
                value: p.city!,
              ),
            if (p.createdAt != null)
              _Meta(
                icon: Icons.schedule,
                label: 'Registered',
                value: Fmt.dayMonth(p.createdAt),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onEditFee != null)
                  TextButton.icon(
                    onPressed: onEditFee,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Edit fee'),
                  ),
                TextButton.icon(
                  onPressed: onEditCommission,
                  icon: const Icon(Icons.percent_outlined, size: 18),
                  label: const Text('Commission'),
                ),
                TextButton.icon(
                  onPressed: onToggleDelete,
                  icon: Icon(
                    p.isDeleted ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    size: 18,
                  ),
                  label: Text(p.isDeleted ? 'Restore' : 'Hide'),
                  style: p.isDeleted ? AppTheme.cautionText(context) : null,
                ),
                if (p.isActive)
                  TextButton.icon(
                    onPressed: () => onAction(ModerationAction.deactivate),
                    icon: const Icon(Icons.block, size: 18),
                    label: const Text('Deactivate'),
                    style: AppTheme.cautionText(context),
                  ),
                if (!p.isActive && p.isVerified)
                  TextButton.icon(
                    onPressed: () => onAction(ModerationAction.activate),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Activate'),
                  ),
                if (p.isPending) ...[
                  TextButton.icon(
                    onPressed: () => onAction(ModerationAction.reject),
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Reject'),
                    style: AppTheme.destructiveText(context),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    onPressed: () => onAction(ModerationAction.verify),
                    icon: const Icon(Icons.verified, size: 18),
                    label: const Text('Verify'),
                    style: AppTheme.rowAction,
                  ),
                ],
                if (p.isRejected)
                  FilledButton.icon(
                    onPressed: () => onAction(ModerationAction.verify),
                    icon: const Icon(Icons.verified, size: 18),
                    label: const Text('Verify anyway'),
                    style: AppTheme.rowAction,
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
  const _Meta({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: muted),
          const SizedBox(width: 4),
          Text(
            '$label: ',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
          ),
          Flexible(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
