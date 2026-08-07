/// §10.12 — the audit log.
///
/// The filter dropdowns are populated from the response rather than hard-coded:
/// `action` and `entity` are free-text columns, so the only honest list of values
/// is the distinct set the server reports in `filters`. Until the first page
/// lands there is nothing to offer, which is why the dropdowns are hidden rather
/// than shown empty.
///
/// The summary counts the whole log, not the current page, so it does not change
/// as the admin scrolls.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../models/admin_models.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

class AdminAuditScreen extends ConsumerWidget {
  const AdminAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(adminAuditProvider);
    final controller = ref.read(adminAuditProvider.notifier);
    final summary = ref.watch(adminAuditSummaryProvider);
    final action = ref.watch(adminAuditActionProvider);
    final entity = ref.watch(adminAuditEntityProvider);

    final bar = AdminFilterBar(
      searchHint: 'Search actor or details',
      onSearch: (v) => ref.read(adminAuditSearchProvider.notifier).state = v,
      trailing: summary == null
          ? null
          : Row(
              children: [
                Expanded(
                  child: _Picker(
                    label: 'Action',
                    value: action,
                    values: summary.actions,
                    onChanged: (v) =>
                        ref.read(adminAuditActionProvider.notifier).state = v,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Picker(
                    label: 'Entity',
                    value: entity,
                    values: summary.entities,
                    onChanged: (v) =>
                        ref.read(adminAuditEntityProvider.notifier).state = v,
                  ),
                ),
              ],
            ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit log'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      body: Column(
        children: [
          if (summary != null) _SummaryStrip(summary: summary),
          Expanded(
            child: PagedListView<AuditEntry>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: 'Nothing logged',
              emptyIcon: Icons.history,
              emptyMessage: 'Nothing matches those filters.',
              itemBuilder: (context, e, _) => _AuditRow(entry: e),
            ),
          ),
        ],
      ),
    );
  }
}

/// A dropdown whose options come from the server. A null selection means the
/// param is omitted entirely.
class _Picker extends StatelessWidget {
  const _Picker({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> values;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    // A selected value that has fallen out of the server's distinct set would
    // assert inside DropdownButton, so include it defensively.
    final options = <String>{...values, if (value != null) value!}.toList()
      ..sort();

    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: [
        const DropdownMenuItem(value: null, child: Text('Any')),
        for (final o in options)
          DropdownMenuItem(value: o, child: Text(Fmt.label(o))),
      ],
      onChanged: onChanged,
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final AuditSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gap,
        vertical: 10,
      ),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Count(label: 'Created', value: summary.inserts, color: AppColors.success),
              _Count(label: 'Updated', value: summary.updates, color: AppColors.primary),
              _Count(label: 'Deleted', value: summary.deletes, color: AppColors.danger),
              _Count(label: 'Entities', value: summary.trackedEntities),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Whole log · last activity ${summary.latestLabel}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, this.color});

  final String label;
  final int value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Resolved here rather than at the call site: this paints the colour as
    // text, and the light-mode semantics are too dark to read on dark surfaces.
    final resolved = AppSemantic.of(context).resolveOrNull(color);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$value',
            style: theme.textTheme.titleMedium?.copyWith(
              color: resolved,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry});

  final AuditEntry entry;

  /// `action` is free text, so this maps the four the handlers actually write
  /// and falls through to a neutral icon for anything else.
  ///
  /// A getter has no BuildContext, so this returns the light-mode constant and
  /// the theme resolve happens in [build] where the brightness is known.
  (IconData, Color) get _glyph => switch (entry.action) {
        'create' || 'insert' => (Icons.add_circle_outline, AppColors.success),
        'update' => (Icons.edit_outlined, AppColors.primary),
        'delete' => (Icons.delete_outline, AppColors.danger),
        'login' => (Icons.login, AppColors.primary),
        'logout' => (Icons.logout, AppColors.warning),
        _ => (Icons.circle_outlined, AppColors.warning),
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = entry;
    final muted = theme.colorScheme.onSurfaceVariant;
    final (icon, rawColor) = _glyph;
    final color = AppSemantic.of(context).resolve(rawColor);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: e.actorLabel,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: ' ${Fmt.label(e.action).toLowerCase()} ',
                          style: theme.textTheme.bodyMedium,
                        ),
                        TextSpan(
                          text: e.targetLabel,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  if (e.details != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      e.details!,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    [
                      e.timeLabel,
                      if (e.userRole != null) Fmt.label(e.userRole!),
                      if (e.ipAddress != null) e.ipAddress!,
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
