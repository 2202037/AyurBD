/// §10.11 — blog management.
///
/// The admin can see drafts, which the public blog endpoint hides. The server
/// de-duplicates the slug, so `saveBlog` returns only `{id, slug}` rather than
/// the full row; the list refetches after a save rather than trying to patch one
/// row with partial data.
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
import '../data/admin_repository.dart';
import 'admin_controllers.dart';
import 'widgets/admin_filter_bar.dart';

const _statusFilters = <FilterOption>[
  (value: null, label: 'All'),
  (value: 'published', label: 'Published'),
  (value: 'draft', label: 'Drafts'),
  (value: 'archived', label: 'Archived'),
];

class AdminBlogsScreen extends ConsumerStatefulWidget {
  const AdminBlogsScreen({super.key});

  @override
  ConsumerState<AdminBlogsScreen> createState() => _AdminBlogsScreenState();
}

class _AdminBlogsScreenState extends ConsumerState<AdminBlogsScreen> {
  bool _busy = false;

  PagedController<AdminBlog> get _controller =>
      ref.read(adminBlogsProvider.notifier);

  Future<void> _openSheet({AdminBlog? existing}) async {
    final saved = await showModalBottomSheet<_BlogInput>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BlogSheet(existing: existing),
    );
    if (saved == null) return;

    setState(() => _busy = true);
    try {
      final result = await ref.read(adminRepositoryProvider).saveBlog(
            id: existing?.id,
            title: saved.title,
            content: saved.content,
            excerpt: saved.excerpt,
            category: saved.category,
            status: saved.status,
          );
      // The handler returns only `{id, slug}`, so the list must refetch.
      await _controller.reload();
      if (mounted) {
        showToast(
          context,
          existing == null
              ? 'Post created: ${result.slug}'
              : 'Post updated.',
        );
      }
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

  Future<void> _delete(AdminBlog blog) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${blog.title}"?'),
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
      await ref.read(adminRepositoryProvider).deleteBlog(blog.id);
      _controller.removeWhere((r) => r.id == blog.id);
      if (mounted) showToast(context, 'Post deleted.');
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
    final state = ref.watch(adminBlogsProvider);
    final status = ref.watch(adminBlogStatusProvider);

    final bar = AdminFilterBar(
      searchHint: 'Search title or category',
      onSearch: (v) => ref.read(adminBlogSearchProvider.notifier).state = v,
      options: _statusFilters,
      selected: status,
      onSelected: (v) => ref.read(adminBlogStatusProvider.notifier).state = v,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Blog'),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(bar.height),
          child: bar,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openSheet(),
        icon: const Icon(Icons.add),
        label: const Text('New post'),
      ),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Saving…',
        child: PagedListView<AdminBlog>(
          state: state,
          onRefresh: _controller.refresh,
          onLoadMore: _controller.loadMore,
          onRetry: _controller.reload,
          emptyTitle: 'No posts',
          emptyIcon: Icons.article_outlined,
          emptyMessage: 'Write one with the button.',
          itemBuilder: (context, blog, _) => _BlogCard(
            blog: blog,
            onTap: () => _openSheet(existing: blog),
            onDelete: () => _delete(blog),
          ),
        ),
      ),
    );
  }
}

class _BlogCard extends StatelessWidget {
  const _BlogCard({required this.blog, required this.onTap, this.onDelete});

  final AdminBlog blog;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = blog;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: b.image != null
            ? RemoteImage(path: b.image, width: 48, height: 48, radius: 6)
            : Icon(
                Icons.article_outlined,
                color: theme.colorScheme.primary,
              ),
        title: Text(
          b.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [b.category, b.dateLabel]
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusPill(status: b.status, label: Fmt.label(b.status), dense: true),
            if (onDelete != null) ...[
              const SizedBox(width: 4),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppSemantic.of(context).danger,
                onPressed: onDelete,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The sheet's input, collected as a record so the screen decides what the
/// repository call looks like.
typedef _BlogInput = ({
  String title,
  String content,
  String? excerpt,
  String? category,
  String? status,
});

class _BlogSheet extends StatefulWidget {
  const _BlogSheet({this.existing});

  final AdminBlog? existing;

  @override
  State<_BlogSheet> createState() => _BlogSheetState();
}

class _BlogSheetState extends State<_BlogSheet> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _title;
  late TextEditingController _content;
  late TextEditingController _excerpt;
  late TextEditingController _category;
  late String _status;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title);
    _content = TextEditingController(text: e?.content);
    _excerpt = TextEditingController(text: e?.excerpt);
    _category = TextEditingController(text: e?.category);
    _status = e?.status ?? 'draft';
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    _excerpt.dispose();
    _category.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      (
        title: _title.text.trim(),
        content: _content.text.trim(),
        excerpt: _excerpt.text.trim().isEmpty
            ? null
            : _excerpt.text.trim(),
        category:
            _category.text.trim().isEmpty ? null : _category.text.trim(),
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
                widget.existing == null ? 'New post' : 'Edit post',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Title *',
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').trim().length < 3
                    ? 'Title must be at least 3 characters.'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _content,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'Content *',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'Content cannot be empty.'
                    : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _excerpt,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Excerpt',
                  hintText: 'Short summary shown in cards…',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  hintText: 'e.g. Ayurvedic medicine',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _status,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'draft', child: Text('Draft')),
                  DropdownMenuItem(value: 'published', child: Text('Published')),
                  DropdownMenuItem(value: 'archived', child: Text('Archived')),
                ],
                onChanged: (v) => setState(() => _status = v ?? 'draft'),
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _submit, child: const Text('Save')),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
