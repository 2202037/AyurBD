/// `POST /blood_bank/request` — post a donor appeal to the public board.
///
/// Every field here maps one-to-one onto a rule in `blood_request_create()`'s
/// `validate()` call, and the client-side bounds are the same bounds (1..20
/// units, 100-char patient name, 255-char hospital name, 50-char city, 500-char
/// reason, BD phone). That is UX, not security — the server validates again
/// regardless (§10).
///
/// Six fields are required here rather than optional, because the matching
/// columns on `blood_requests` are NOT NULL: patient_name, blood_group,
/// units_needed, hospital_name, city and needed_by. Sending any of them blank
/// would be a 422 at best and a 500 at worst.
///
/// There is no urgency control. `blood_requests` has no urgency column, so the
/// old radio group sent a key `validate()` silently dropped — it looked like it
/// worked and changed nothing. The board derives urgency from `needed_by`, which
/// is real data rather than a self-reported priority.
///
/// `requester_name` IS on this form, and that is a deliberate change from the
/// earlier version. There is no `requester_id` and no FK to users on this table,
/// so the server cannot derive the requester from the JWT — it defaults to the
/// account name and lets the user override it, since the person posting is often
/// not the patient. `require_auth()` still gates the endpoint.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/blood_models.dart';
import '../../auth/presentation/auth_controller.dart';
import '../data/blood_repository.dart';
import 'blood_bank_screen.dart';

class BloodRequestScreen extends ConsumerStatefulWidget {
  const BloodRequestScreen({super.key});

  @override
  ConsumerState<BloodRequestScreen> createState() => _BloodRequestScreenState();
}

class _BloodRequestScreenState extends ConsumerState<BloodRequestScreen> {
  final _form = GlobalKey<FormState>();
  final _patient = TextEditingController();
  final _units = TextEditingController(text: '1');
  final _hospital = TextEditingController();
  final _city = TextEditingController();
  final _phone = TextEditingController();
  final _requester = TextEditingController();
  final _reason = TextEditingController();

  String _group = kBloodGroups.first;
  DateTime? _neededBy;

  /// Set once, from the signed-in account, so the common case needs no typing.
  bool _prefilled = false;

  bool _busy = false;
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    for (final c in [_patient, _units, _hospital, _city, _phone, _requester, _reason]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _neededBy ?? now,
      // A request for blood needed in the past helps nobody, and the board is
      // ordered soonest-needed first — a stale date would sit at the top forever.
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 180)),
    );
    if (picked != null) setState(() => _neededBy = picked);
  }

  Future<void> _submit() async {
    // Clear stale server errors first, or a field the user just fixed would
    // keep showing the old message from the previous attempt.
    setState(() => _serverErrors = const {});
    if (!(_form.currentState?.validate() ?? false)) return;

    // `needed_by` is required by the column, and a date picker has no
    // TextFormField to hang a validator on, so it is checked by hand.
    if (_neededBy == null) {
      setState(() => _serverErrors = {'needed_by': 'Choose the date it is needed by.'});
      return;
    }
    FocusScope.of(context).unfocus();

    setState(() => _busy = true);
    try {
      await ref.read(bloodRepositoryProvider).createRequest(
            patientName: _patient.text,
            bloodGroup: _group,
            unitsNeeded: int.parse(_units.text.trim()),
            hospitalName: _hospital.text,
            city: _city.text,
            neededBy: _neededBy!,
            contactPhone: _phone.text,
            requesterName: _requester.text,
            reason: _reason.text,
          );
      if (!mounted) return;
      // The board is a paged controller; invalidating is cheaper and more
      // honest than splicing the new row in at a position the server chose.
      ref.invalidate(bloodRequestsProvider);
      showToast(context, 'Blood request posted.');
      context.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _serverErrors = e.errors;
      });
      // Re-run validation so per-field 400s land on the fields themselves.
      _form.currentState?.validate();
      showToast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The server defaults requester_name to the account name and has no way to
    // derive the phone at all, so seeding both from the profile saves typing
    // without hiding what will be posted. Done once: overwriting on every
    // rebuild would fight the user's own edits.
    final me = ref.watch(currentUserProvider);
    if (!_prefilled && me != null) {
      _prefilled = true;
      _requester.text = me.name;
      if (me.phone != null && me.phone!.isNotEmpty) _phone.text = me.phone!;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Request blood')),
      body: BlockingOverlay(
        busy: _busy,
        message: 'Posting your request…',
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Your request appears on the public board so donors can '
                      'call you directly. Only post a number you can answer.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),

                    TextFormField(
                      controller: _patient,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Patient name',
                        helperText: 'Who the blood is for.',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (v) =>
                          _serverErrors['patient_name'] ??
                          Validators.text(v, field: 'Patient name', min: 2, max: 100),
                    ),
                    const SizedBox(height: 4),

                    // Group is a closed set server-side (`in:` rule over the
                    // eight groups), so it is chips, never free text.
                    Text('Blood group', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final g in kBloodGroups)
                          ChoiceChip(
                            label: Text(g),
                            selected: _group == g,
                            // No de-select branch: the group is required, so
                            // there is no valid "none" state to fall back to.
                            onSelected: (_) => setState(() => _group = g),
                          ),
                      ],
                    ),
                    if (_serverErrors['blood_group'] != null) ...[
                      const SizedBox(height: 6),
                      _FieldError(message: _serverErrors['blood_group']!),
                    ],
                    const SizedBox(height: 20),

                    TextFormField(
                      controller: _units,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Units needed',
                        helperText: 'Between 1 and 20 bags.',
                        prefixIcon: Icon(Icons.water_drop_outlined),
                      ),
                      // 20 is the server's own cap, not a guess.
                      validator: (v) =>
                          _serverErrors['units_needed'] ??
                          Validators.positiveInt(v, field: 'Units', max: 20),
                    ),
                    const SizedBox(height: 4),

                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Contact number',
                        helperText: 'Donors will call this number.',
                        prefixIcon: Icon(Icons.call_outlined),
                      ),
                      validator: (v) => _serverErrors['contact_phone'] ?? Validators.phone(v),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _hospital,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      maxLength: 255,
                      decoration: const InputDecoration(
                        labelText: 'Hospital',
                        helperText: 'Free text — it does not have to be a listed hospital.',
                        prefixIcon: Icon(Icons.local_hospital_outlined),
                      ),
                      validator: (v) =>
                          _serverErrors['hospital_name'] ??
                          Validators.text(v, field: 'Hospital', min: 2, max: 255),
                    ),
                    const SizedBox(height: 4),

                    TextFormField(
                      controller: _city,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      maxLength: 50,
                      decoration: const InputDecoration(
                        labelText: 'City',
                        helperText: 'Donors filter the board by city.',
                        prefixIcon: Icon(Icons.location_city_outlined),
                      ),
                      validator: (v) =>
                          _serverErrors['city'] ??
                          Validators.text(v, field: 'City', min: 2, max: 50),
                    ),
                    const SizedBox(height: 4),

                    InkWell(
                      onTap: _pickDate,
                      borderRadius: BorderRadius.circular(8),
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Needed by',
                          prefixIcon: const Icon(Icons.event_outlined),
                          errorText: _serverErrors['needed_by'],
                          // No clear button: the date is required, so there is no
                          // valid empty state to clear back to.
                        ),
                        child: Text(
                          _neededBy == null
                              ? 'Tap to choose a date'
                              : Fmt.dayFull(_neededBy),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    TextFormField(
                      controller: _requester,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      maxLength: 100,
                      decoration: const InputDecoration(
                        labelText: 'Your name',
                        helperText: 'Shown to donors as the contact person.',
                        prefixIcon: Icon(Icons.badge_outlined),
                      ),
                      validator: (v) => _serverErrors['requester_name'] ??
                          Validators.notes(v, max: 100),
                    ),
                    const SizedBox(height: 4),

                    TextFormField(
                      controller: _reason,
                      maxLines: 4,
                      maxLength: 500,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Reason / note (optional)',
                        alignLabelWithHint: true,
                        helperText: 'Patient condition, ward number, best time to call…',
                      ),
                      validator: (v) => _serverErrors['reason'] ?? Validators.notes(v),
                    ),
                    const SizedBox(height: 8),

                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: const Text('Post request'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Server-side errors for the chip and radio groups, which have no
/// `InputDecoration` of their own to hang an `errorText` on.
class _FieldError extends StatelessWidget {
  const _FieldError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      message,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
    );
  }
}
