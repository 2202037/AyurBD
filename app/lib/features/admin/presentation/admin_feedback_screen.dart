/// §10.9 — contact-form submissions and the support queue.
///
/// The one admin list where the response is written rather than picked: typing a
/// reply stamps `responded_at` and notifies the submitter when the row has a user
/// account behind it. An anonymous submission gets no notification, which is why
/// the sheet says so before the admin spends time writing one.
///
/// `priority` and the wider `status` set arrive with migration_v2. The server
/// answers 422 naming the column when this database's enum does not accept a
/// value, so the error is surfaced verbatim rather than being reworded into
/// something less diagnosable.
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

const _statusFilters = <FilterOption>[
  (value: null, label: 'All'),
  (value: 'pending', label: 'New'),
  (value: 'in_progress', label: 'In progress'),
  (value: 'resolved', label: 'Resolved'),
  (value: 'closed', label: 'Closed'),
];

const _priorityFilters = <FilterOption>[
  (value: null, label: 'Any priority'),
  (value: 'low', label: 'Low'),
  (value: 'medium', label: 'Medium'),
  (value: 'high', label: 'High'),
];

class AdminFeedbackScreen extends ConsumerStatefulWidget {
  const AdminFeedbackScreen({super.key});

  @override
  ConsumerState<AdminFeedbackScreen> createState() =>
      _AdminFeedbackScreenState();
}

class _AdminFeedbackScreenState extends ConsumerState<AdminFeedbackScreen> {
  bool _busy = false;

  PagedController<AdminFeedback> get _controller =>
      ref.read(adminFeedbackProvider.notifier);

  Future<void> _openSheet(AdminFeedback f) async {
    final result = await showModalBottomSheet<_FeedbackEdit>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _FeedbackSheet(feedback: f),
    );
    if (result == null) return;

    setState(() => _busy = true);
    try {
      await ref.read(adminRepositoryProvider).updateFeedback(
            feedbackId: f.id,
            status: result.status,
            response: result.response,
            priority: result.priority,
          );
      // The handler answers `data: null`, so there is no updated row to patch
      // in — refetch rather than guessing what the server wrote.
      await _controller.reload();
      ref.invalidate(adminDashboardProvider);
      if (mounted) showToast(context, 'Feedback updated.');
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

  Future<void> _delete(AdminFeedback f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this submission?'),
        content: const Text('It is removed permanently.'),
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
      await ref.read(adminRepositoryProvider).deleteFeedback(f.id);
      _controller.removeWhere((row) => row.id == f.id);
      ref.invalidate(adminDashboardProvider);
      if (mounted) showToast(context, 'Submission deleted.');
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
    final state = ref.watch(adminFeedbackProvider);
    final status = ref.watch(adminFeedbackStatusProvider);
    final priority = ref.watch(adminFeedbackPriorityProvider);

    final bar = AdminFilterBar(
      options: _statusFilters,
      selected: status,
      onSelected: (v) => ref.read(adminFeedbackStatusProvider.notifier).state = v,
      trailing: DropdownButtonFormField<String?>(
        initialValue: priority,
        decoration: const InputDecoration(
          labelText: 'Priority',
          isDense: true,
          border: OutlineInputBorder(),
        ),
        items: _priorityFilters
            .map((f) => DropdownMenuItem(value: f.value, child: Text(f.label)))
            .toList(),
        onChanged: (v) =>
            ref.read(adminFeedbackPriorityProvider.notifier).state = v,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Feedback'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving…',
        child: PagedListView<AdminFeedback>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: 'No submissions',
          emptyIcon: Icons.support_agent_outlined,
          emptyMessage: 'Nothing matches those filters.',
          itemBuilder: (context, f, _) => _FeedbackCard(
            feedback: f,
            onTap: () => _openSheet(f),
            onDelete: () => _delete(f),
          ),
        ),
      ),
    );
  }
}

/// What the sheet returns. All three fields are optional because the endpoint
/// takes a partial update — but at least one must be set or the call is a 400,
/// which the sheet enforces before popping.
class _FeedbackEdit {
  const _FeedbackEdit({this.status, this.response, this.priority});

  final String? status;
  final String? response;
  final String? priority;
}

class _FeedbackCard extends StatelessWidget {
  const _FeedbackCard({required this.feedback, required this.onTap, this.onDelete});

  final AdminFeedback feedback;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = feedback;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          f.isUrgent ? Icons.priority_high : Icons.support_agent_outlined,
          color: f.isUrgent ? AppSemantic.of(context).danger : theme.colorScheme.primary,
        ),
        title: Text(
          f.subject ?? 'No subject',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${f.fromLabel} · ${f.dateLabel}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusPill(status: f.status, label: f.statusLabel, dense: true),
            if (f.priority != 'low' && f.priority != 'medium') ...[
              const SizedBox(width: 4),
              StatusPill(
                status: f.priority,
                label: f.priorityLabel,
                dense: true,
              ),
            ],
            if (onDelete != null)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppSemantic.of(context).danger,
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

class _FeedbackSheet extends StatefulWidget {
  const _FeedbackSheet({required this.feedback});

  final AdminFeedback feedback;

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  late String? _status;
  late String? _priority;
  late TextEditingController _responseController;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _status = widget.feedback.status;
    _priority = widget.feedback.priority;
    _responseController = TextEditingController(text: widget.feedback.adminResponse);
  }

  @override
  void dispose() {
    _responseController.dispose();
    super.dispose();
  }

  void _submit() {
    final response = _responseController.text.trim();
    // At least one must be set or the endpoint answers 400.
    if (_status == widget.feedback.status &&
        _priority == widget.feedback.priority &&
        response == (widget.feedback.adminResponse ?? '')) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(
      context,
      _FeedbackEdit(
        status: _status != widget.feedback.status ? _status : null,
        priority: _priority != widget.feedback.priority ? _priority : null,
        response: response != (widget.feedback.adminResponse ?? '') &&
                response.isNotEmpty
            ? response
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.feedback;
    final theme = Theme.of(context);
    final hasAccount = f.userId != null;

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
              // The original submission — read-only so the admin sees what they
              // are responding to.
              Text('From ${f.fromLabel}', style: theme.textTheme.titleMedium),
              if (f.email != null)
                Text(f.email!, style: theme.textTheme.bodySmall),
              if (f.phone != null)
                Text(f.phone!, style: theme.textTheme.bodySmall),
              const SizedBox(height: 10),
              if (f.subject != null)
                Text(f.subject!, style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(f.message ?? '(No message)',
                  style: theme.textTheme.bodyMedium),
              if (!hasAccount) ...[
                const SizedBox(height: 8),
                Card(
                  color: AppSemantic.of(context).warning.withValues(alpha: AppSemantic.of(context).tintAlpha),
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 18, color: AppSemantic.of(context).warning),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'This submission has no user account. A reply will NOT '
                            'reach the sender via the app — send it by email or phone '
                            'instead.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              const Divider(),
              // Status and priority pickers.
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: _statusFilters.where((o) => o.value != null).map((o) =>
                    DropdownMenuItem(value: o.value, child: Text(o.label))).toList(),
                onChanged: (v) => setState(() => _status = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _priority,
                decoration: const InputDecoration(
                  labelText: 'Priority',
                  border: OutlineInputBorder(),
                ),
                items: _priorityFilters.where((f) => f.value != null).map((f) =>
                    DropdownMenuItem(value: f.value, child: Text(f.label))).toList(),
                onChanged: (v) => setState(() => _priority = v),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _responseController,
                maxLines: 4,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Response',
                  hintText: 'Visible to the submitter…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              FilledButton(onPressed: _submit, child: const Text('Save')),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
