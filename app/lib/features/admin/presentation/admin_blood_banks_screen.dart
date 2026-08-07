/// §10.10 — blood bank directory management.
///
/// The table key is a group→units map ("A+" → 12), but the server maps it onto
/// eight columns (`blood_type_a_positive`, etc.) upstream so no client has to
/// know the column names. The save sheet sends the map and the list refetches.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/paged_controller.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/admin_models.dart';
import '../data/admin_repository.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

/// The eight blood groups. A stock form is eight number fields, each labeled
/// with the group, so the map arrives as `Map<String, int>`.
const _groups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

class AdminBloodBanksScreen extends ConsumerStatefulWidget {
  const AdminBloodBanksScreen({super.key});

  @override
  ConsumerState<AdminBloodBanksScreen> createState() =>
      _AdminBloodBanksScreenState();
}

class _AdminBloodBanksScreenState
    extends ConsumerState<AdminBloodBanksScreen> {
  bool _busy = false;

  PagedController<AdminBloodBank> get _controller =>
      ref.read(adminBloodBanksProvider.notifier);

  Future<void> _openSheet({AdminBloodBank? existing}) async {
    final saved = await showModalBottomSheet<AdminBloodBank>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BloodBankSheet(existing: existing),
    );
    if (saved == null) return;

    setState(() => _busy = true);
    try {
      final bb = await ref.read(adminRepositoryProvider).saveBloodBank(
            id: existing?.id,
            name: saved.name,
            address: saved.address,
            city: saved.city,
            phone: saved.phone,
            email: saved.email,
            status: saved.status,
            stock: saved.stock,
          );
      if (existing != null) {
        _controller.replaceWhere((r) => r.id == existing.id, bb);
      } else {
        await _controller.reload();
      }
      if (mounted) showToast(context, existing == null ? 'Added.' : 'Updated.');
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

  Future<void> _delete(AdminBloodBank bb) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${bb.name}?'),
        content: const Text('This cannot be undone.'),
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
      await ref.read(adminRepositoryProvider).deleteBloodBank(bb.id);
      _controller.removeWhere((r) => r.id == bb.id);
      if (mounted) showToast(context, '${bb.name} deleted.');
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(adminBloodBanksProvider);

    final bar = AdminFilterBar(
      searchHint: 'Search name, address or city',
      onSearch: (v) =>
          ref.read(adminBloodBankSearchProvider.notifier).state = v,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blood banks'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openSheet(),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving…',
        child: PagedListView<AdminBloodBank>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: 'No blood banks',
          emptyIcon: Icons.bloodtype_outlined,
          emptyMessage: 'Add one with the button.',
          itemBuilder: (context, bb, _) => _BloodBankCard(
            bank: bb,
            onTap: () => _openSheet(existing: bb),
            onDelete: () => _delete(bb),
          ),
        ),
      ),
    );
  }
}

class _BloodBankCard extends StatelessWidget {
  const _BloodBankCard({required this.bank, required this.onTap, this.onDelete});

  final AdminBloodBank bank;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bb = bank;
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(bb.name,
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        if (bb.city != null || bb.address != null)
                          Text(
                            [bb.address, bb.city]
                                .where((s) => s != null && s.isNotEmpty)
                                .join(', '),
                            style:
                                theme.textTheme.bodySmall?.copyWith(color: muted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  StatusPill(status: bb.status, dense: true),
                  if (onDelete != null)
                    IconButton(
                      tooltip: 'Delete',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      color: AppSemantic.of(context).danger,
                      onPressed: onDelete,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // The stock grid is the point of the row — an admin scanning for a
              // shortage should not have to open each bank.
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final g in _groups) _GroupChip(group: g, units: bb.stock[g] ?? 0),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${bb.totalUnits} unit${bb.totalUnits == 1 ? '' : 's'} in stock'
                '${bb.phone == null ? '' : ' · ${bb.phone}'}',
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Zero units is coloured as a warning: an empty group is the thing worth
/// spotting in this list, not a neutral fact.
class _GroupChip extends StatelessWidget {
  const _GroupChip({required this.group, required this.units});

  final String group;
  final int units;

  @override
  Widget build(BuildContext context) {
    final color = units == 0 ? AppSemantic.of(context).danger : AppSemantic.of(context).success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppSemantic.of(context).tintAlpha),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: AppSemantic.of(context).tintBorderAlpha)),
      ),
      child: Text(
        '$group $units',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}

class _BloodBankSheet extends StatefulWidget {
  const _BloodBankSheet({this.existing});

  final AdminBloodBank? existing;

  @override
  State<_BloodBankSheet> createState() => _BloodBankSheetState();
}

class _BloodBankSheetState extends State<_BloodBankSheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _c = {};
  late String _status;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _status = e?.status ?? 'active';
    _c['name'] = TextEditingController(text: e?.name);
    _c['address'] = TextEditingController(text: e?.address);
    _c['city'] = TextEditingController(text: e?.city);
    _c['phone'] = TextEditingController(text: e?.phone);
    _c['email'] = TextEditingController(text: e?.email);
    for (final g in _groups) {
      _c[g] = TextEditingController(text: '${e?.stock[g] ?? 0}');
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _t(String key) {
    final v = _c[key]!.text.trim();
    return v.isEmpty ? null : v;
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    final stock = <String, int>{
      for (final g in _groups) g: int.tryParse(_c[g]!.text.trim()) ?? 0,
    };
    // Returns a model rather than calling the repository here: the screen owns
    // the busy overlay and the error toast, so the sheet just collects input.
    Navigator.pop(
      context,
      AdminBloodBank(
        id: widget.existing?.id ?? 0,
        name: _c['name']!.text.trim(),
        stock: stock,
        totalUnits: stock.values.fold(0, (a, b) => a + b),
        address: _t('address'),
        city: _t('city'),
        phone: _t('phone'),
        email: _t('email'),
        status: _status,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(AppTheme.gap, AppTheme.gap, AppTheme.gap,
          AppTheme.gap + MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.existing == null ? 'Add blood bank' : 'Edit blood bank',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _c['name'],
                decoration: const InputDecoration(
                  labelText: 'Name *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').trim().length < 2
                    ? 'At least 2 characters.'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _c['address'],
                decoration: const InputDecoration(
                  labelText: 'Address',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _c['city'],
                      decoration: const InputDecoration(
                        labelText: 'City',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextFormField(
                      controller: _c['phone'],
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _c['email'],
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final t = (v ?? '').trim();
                  if (t.isEmpty) return null;
                  return t.contains('@') && t.contains('.')
                      ? null
                      : 'Enter a valid email.';
                },
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(value: 'inactive', child: Text('Inactive')),
                ],
                onChanged: (v) => setState(() => _status = v ?? 'active'),
              ),
              const SizedBox(height: 16),
              Text('Stock (units)',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              // Two columns of four, so the eight groups fit without scrolling
              // the sheet a second screen's worth.
              for (var i = 0; i < _groups.length; i += 2)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(child: _stockField(_groups[i])),
                      const SizedBox(width: 8),
                      Expanded(child: _stockField(_groups[i + 1])),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              FilledButton(onPressed: _submit, child: const Text('Save')),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stockField(String group) => TextFormField(
        controller: _c[group],
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: group,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        validator: (v) {
          final t = (v ?? '').trim();
          if (t.isEmpty) return null;
          final n = int.tryParse(t);
          return n == null || n < 0 ? 'Whole number, 0 or more.' : null;
        },
      );
}
