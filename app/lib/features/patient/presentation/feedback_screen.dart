/// §5.7 — general feedback and complaints.
///
/// Not a review: those target a specific doctor/hospital/clinic/pharmacy and
/// carry a 1-5 rating (see `review_sheet.dart`). This is `POST /feedback`, which
/// takes a typed subject + message and is reachable by guests too.
///
/// The success wording comes from the envelope's `message`, so the thank-you
/// stays owned by the server rather than duplicated here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/content_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../../content/data/content_repository.dart';

class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key});

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  final _form = GlobalKey<FormState>();
  final _subject = TextEditingController();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _message = TextEditingController();

  FeedbackType _type = FeedbackType.general;
  bool _busy = false;
  Map<String, String> _serverErrors = const {};

  @override
  void initState() {
    super.initState();
    // Signed-in users get name and email pre-filled — the server would fall back
    // to the account anyway, so showing them avoids a form that looks emptier
    // than it is. Guests must fill both, and the validators below say so.
    final user = ref.read(currentUserProvider);
    if (user != null) {
      _name.text = user.name;
      _email.text = user.email;
      final phone = user.phone;
      if (phone != null && phone.isNotEmpty) _phone.text = phone;
    }
  }

  @override
  void dispose() {
    for (final c in [_subject, _name, _email, _phone, _message]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverErrors = const {});
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    setState(() => _busy = true);
    try {
      final thanks = await ref.read(contentRepositoryProvider).sendFeedback(
            subject: _subject.text,
            message: _message.text,
            type: _type,
            name: _name.text,
            email: _email.text,
            phone: _phone.text,
          );
      if (!mounted) return;
      // The server's own thanks message goes into a success dialog rather than
      // a toast so the user actually sees it — a green toast is gone in 3s.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 40),
          title: const Text('Sent'),
          content: Text(thanks),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (mounted) {
        _subject.clear();
        _message.clear();
        setState(() => _type = FeedbackType.general);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _serverErrors = e.errors);
      _form.currentState?.validate();
      showToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Drives which fields are starred. Watched, not read: signing in from another
    // tab while this form is open should relax the requirement, not strand it.
    final isGuest = ref.watch(currentUserProvider) == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Send feedback')),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Sending…',
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.gap),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "We'd love to hear from you. Report a problem, suggest an "
                  'improvement, or tell us what went well.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 20),
                // A dropdown rather than a segmented button: nine options do not
                // fit across a phone, and the server rejects anything outside
                // them, so the set cannot be trimmed to the three that would.
                DropdownButtonFormField<FeedbackType>(
                  initialValue: _type,
                  decoration: const InputDecoration(
                    labelText: 'Type',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: [
                    for (final t in FeedbackType.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) =>
                      setState(() => _type = v ?? FeedbackType.general),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _subject,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Subject *',
                    hintText: 'A one-line summary',
                    prefixIcon: Icon(Icons.subject_outlined),
                  ),
                  validator: (v) =>
                      _serverErrors['subject'] ??
                      Validators.text(v, field: 'Subject', min: 3, max: 255),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: isGuest ? 'Name *' : 'Name',
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                  validator: (v) {
                    final server = _serverErrors['name'];
                    if (server != null) return server;
                    // Required for guests only: `feedback_create()` swaps in
                    // `required` rules when there is no bearer token, and falls
                    // back to the account's own name when there is.
                    if (v == null || v.trim().isEmpty) {
                      return isGuest ? 'Name is required.' : null;
                    }
                    return Validators.name(v);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: isGuest ? 'Email *' : 'Email',
                    hintText: 'So we can reply',
                    prefixIcon: const Icon(Icons.email_outlined),
                  ),
                  validator: (v) {
                    final server = _serverErrors['email'];
                    if (server != null) return server;
                    if (v == null || v.trim().isEmpty) {
                      return isGuest ? 'Email is required.' : null;
                    }
                    return Validators.email(v);
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                    hintText: '01712345678',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (v) =>
                      _serverErrors['phone'] ?? Validators.phone(v, optional: true),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _message,
                  maxLines: 6,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Message *',
                    hintText: 'Describe your feedback in detail',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) {
                    final server = _serverErrors['message'];
                    if (server != null) return server;
                    return Validators.text(v, field: 'Message', min: 10, max: 2000);
                  },
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: const Icon(Icons.send_outlined, size: 20),
                  label: const Text('Send feedback'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
