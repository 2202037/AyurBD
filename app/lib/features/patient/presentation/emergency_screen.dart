/// §5.9 — emergency assistance.
///
/// The hotline list comes first and the request form second, deliberately. No
/// SMS gateway is wired up: `POST /emergency/sms` records a row and returns
/// `delivered: false`, so the form cannot actually summon help. Putting the
/// dialable numbers above it means the fastest path on this screen is the one
/// that works.
///
/// Both endpoints are public — someone who needs an ambulance should not have to
/// sign in first.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/patient_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/patient_repository.dart';

final _hotlinesProvider = FutureProvider.autoDispose<List<Hotline>>((ref) {
  return ref.watch(patientRepositoryProvider).hotlines();
});

class EmergencyScreen extends ConsumerStatefulWidget {
  const EmergencyScreen({super.key});

  @override
  ConsumerState<EmergencyScreen> createState() => _EmergencyScreenState();
}

class _EmergencyScreenState extends ConsumerState<EmergencyScreen> {
  final _form = GlobalKey<FormState>();
  final _sender = TextEditingController();
  final _recipient = TextEditingController();
  final _message = TextEditingController();
  final _location = TextEditingController();

  bool _busy = false;
  Map<String, String> _serverErrors = const {};

  @override
  void initState() {
    super.initState();
    // Pre-fill the sender from the signed-in profile: in an emergency, one less
    // field to type. Guests get an empty field, which still works.
    final phone = ref.read(currentUserProvider)?.phone;
    if (phone != null && phone.isNotEmpty) _sender.text = phone;
  }

  @override
  void dispose() {
    for (final c in [_sender, _recipient, _message, _location]) {
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
      final res = await ref.read(patientRepositoryProvider).sendEmergency(
            senderPhone: _sender.text,
            recipientPhone: _recipient.text,
            message: _message.text,
            location: _location.text,
          );
      if (!mounted) return;
      // Show the server's own wording. It says the message was recorded but not
      // transmitted — a client-authored "Sent!" here would be a lie that could
      // get somebody hurt.
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(
            res.delivered ? Icons.check_circle : Icons.warning_amber_rounded,
            color: res.delivered ? AppSemantic.of(ctx).success : AppSemantic.of(ctx).warning,
            size: 40,
          ),
          title: Text(res.delivered ? 'Message sent' : 'Recorded, not sent'),
          content: Text(res.displayMessage),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Understood'),
            ),
          ],
        ),
      );
      if (mounted) {
        _message.clear();
        _location.clear();
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
    final hotlines = ref.watch(_hotlinesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Emergency')),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Recording your request…',
        child: ListView(
          padding: const EdgeInsets.all(AppTheme.gap),
          children: [
            const _CallFirstBanner(),
            const SizedBox(height: AppTheme.gap),
            const SectionHeader(title: 'Hotlines'),
            hotlines.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: LoadingView(),
              ),
              error: (e, _) => ErrorView(
                error: e,
                onRetry: () => ref.invalidate(_hotlinesProvider),
              ),
              data: (list) => list.isEmpty
                  ? const EmptyView(
                      message: 'No hotlines are listed. In Bangladesh, the '
                          'national emergency number is 999.',
                      icon: Icons.phone_disabled_outlined,
                    )
                  : Column(
                      children: [for (final h in list) _HotlineTile(hotline: h)],
                    ),
            ),
            const SizedBox(height: 24),
            const SectionHeader(title: 'Send an emergency request'),
            _FormCard(
              form: _form,
              sender: _sender,
              recipient: _recipient,
              message: _message,
              location: _location,
              serverErrors: _serverErrors,
              busy: _busy,
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// The most important thing on the screen, so it is the first thing on it.
class _CallFirstBanner extends StatelessWidget {
  const _CallFirstBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: AppSemantic.of(context).danger.withValues(alpha: AppSemantic.of(context).tintAlpha),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Row(
          children: [
            Icon(Icons.emergency, color: AppSemantic.of(context).danger, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Call, do not type',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppSemantic.of(context).danger,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'If this is life-threatening, call a hotline below now. The '
                    'request form records your details for follow-up — it does '
                    'not dispatch help.',
                    style: theme.textTheme.bodySmall,
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

class _HotlineTile extends StatelessWidget {
  const _HotlineTile({required this.hotline});

  final Hotline hotline;

  IconData get _icon => switch (hotline.category) {
        'ambulance' => Icons.local_shipping_outlined,
        'fire' => Icons.local_fire_department_outlined,
        'police' => Icons.local_police_outlined,
        'hospital' => Icons.local_hospital_outlined,
        'national' => Icons.shield_outlined,
        _ => Icons.support_agent_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = hotline;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(_icon, color: AppSemantic.of(context).danger),
        title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          h.description ?? h.categoryLabel,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          h.isDialable ? h.phone : '—',
          style: theme.textTheme.titleMedium?.copyWith(
            color: AppSemantic.of(context).danger,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _FormCard extends StatelessWidget {
  const _FormCard({
    required this.form,
    required this.sender,
    required this.recipient,
    required this.message,
    required this.location,
    required this.serverErrors,
    required this.busy,
    required this.onSubmit,
  });

  final GlobalKey<FormState> form;
  final TextEditingController sender;
  final TextEditingController recipient;
  final TextEditingController message;
  final TextEditingController location;
  final Map<String, String> serverErrors;
  final bool busy;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: sender,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Your number *',
                  hintText: '01712345678',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
                validator: (v) => serverErrors['sender_phone'] ?? Validators.phone(v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: recipient,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Number to contact *',
                  hintText: 'Family member or hotline',
                  prefixIcon: Icon(Icons.contact_phone_outlined),
                ),
                validator: (v) =>
                    serverErrors['recipient_phone'] ?? Validators.phone(v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: message,
                maxLines: 3,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What is happening? *',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  final server = serverErrors['message'];
                  if (server != null) return server;
                  final t = (v ?? '').trim();
                  if (t.length < 5) return 'Describe the emergency briefly.';
                  return null;
                },
              ),
              const SizedBox(height: 4),
              TextFormField(
                controller: location,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Where are you? (optional)',
                  hintText: 'Area, road, landmark',
                  prefixIcon: Icon(Icons.place_outlined),
                ),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: busy ? null : onSubmit,
                style: AppTheme.destructive(context),
                icon: const Icon(Icons.send_outlined, size: 20),
                label: const Text('Record request'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
