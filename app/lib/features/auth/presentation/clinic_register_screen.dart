/// §3.4 — clinic sign-up.
///
/// Lighter than the hospital form: no bed counts, no emergency line, a weekday
/// picker in place of the 24h switch. The `available_days` column is free text
/// server-side, so [RegDayPicker] serialises to a predictable comma list rather
/// than letting a free-text field accumulate "SAT", "Sat", "Saturday" and "週六"
/// from four different sign-ups.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/widgets/state_views.dart';
import '../data/registration_fields.dart';
import 'auth_controller.dart';
import 'widgets/account_section.dart';
import 'widgets/registration_fields_ui.dart';

class ClinicRegisterScreen extends ConsumerStatefulWidget {
  const ClinicRegisterScreen({super.key});

  @override
  ConsumerState<ClinicRegisterScreen> createState() =>
      _ClinicRegisterScreenState();
}

class _ClinicRegisterScreenState extends ConsumerState<ClinicRegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _account = AccountControllers();

  final _registrationNumber = TextEditingController();
  final _licenseNumber = TextEditingController();
  final _establishedYear = TextEditingController();
  final _website = TextEditingController();
  final _area = TextEditingController();
  final _services = TextEditingController();
  final _specializations = TextEditingController();
  final _description = TextEditingController();

  String? _clinicType;
  TimeOfDay? _openingTime;
  TimeOfDay? _closingTime;
  Set<String> _availableDays = {};
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    _account.dispose();
    for (final c in [
      _registrationNumber, _licenseNumber, _establishedYear, _website,
      _area, _services, _specializations, _description,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverErrors = const {});
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    try {
      final signedIn = await ref.read(authControllerProvider.notifier).register(
            name: _account.name.text,
            email: _account.email.text,
            password: _account.password.text,
            phone: _account.phone.text,
            role: SignupRole.clinic.value,
            passwordConfirm: _account.confirm.text,
            city: _account.city.text,
            address: _account.address.text,
            extra: RegistrationFields.clinic(
              registrationNumber: _registrationNumber.text,
              licenseNumber: _licenseNumber.text,
              clinicType: _clinicType,
              establishedYear: _establishedYear.text,
              website: _website.text,
              area: _area.text,
              services: _services.text,
              specializations: _specializations.text,
              availableDays: RegDayPicker.encode(_availableDays),
              openingTime: _openingTime == null
                  ? null
                  : RegTimeField.format(_openingTime!),
              closingTime: _closingTime == null
                  ? null
                  : RegTimeField.format(_closingTime!),
              description: _description.text,
            ),
          );
      if (!mounted) return;
      if (signedIn) {
        showToast(context, 'Account created. An admin will verify your clinic.');
      } else {
        showToast(context, 'Account created. Please sign in.');
        context.pop();
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _serverErrors = e.errors);
      _form.currentState?.validate();
      showToast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(authControllerProvider).busy;

    return Scaffold(
      appBar: AppBar(title: const Text('Register a clinic')),
      body: AbsorbPointer(
        absorbing: busy,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const ProviderPendingNotice(what: 'Your clinic'),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Contact details'),
                    const SizedBox(height: 12),
                    AccountSection(
                      controllers: _account,
                      errors: _serverErrors,
                      gender: null,
                      onGenderChanged: (_) {},
                      nameLabel: 'Clinic name',
                      emailLabel: 'Clinic email',
                      addressLabel: 'Clinic address',
                      showGender: false,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Registration'),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _registrationNumber,
                      label: 'Registration number',
                      wireKey: 'registration_number',
                      errors: _serverErrors,
                      icon: Icons.badge_outlined,
                      maxLength: 100,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _licenseNumber,
                      label: 'License number',
                      wireKey: 'license_number',
                      errors: _serverErrors,
                      icon: Icons.verified_outlined,
                      maxLength: 100,
                    ),
                    const SizedBox(height: 12),
                    RegDropdown(
                      label: 'Clinic type',
                      value: _clinicType,
                      options: const [
                        'General',
                        'Specialised',
                        'Diagnostic centre',
                        'Ayurvedic',
                        'Wellness',
                        'Spa',
                      ],
                      onChanged: (v) => setState(() => _clinicType = v),
                      icon: Icons.category_outlined,
                    ),
                    const SizedBox(height: 12),
                    RegNumberField(
                      controller: _establishedYear,
                      label: 'Established year',
                      hint: 'e.g. 2018',
                      wireKey: 'established_year',
                      errors: _serverErrors,
                      icon: Icons.calendar_today_outlined,
                      // Server rule is `min:1800`; matching it here keeps the
                      // client from rejecting a year the API would accept.
                      min: 1800,
                      max: DateTime.now().year,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _website,
                      label: 'Website',
                      hint: 'https://example.com',
                      wireKey: 'website',
                      errors: _serverErrors,
                      icon: Icons.language_outlined,
                      keyboardType: TextInputType.url,
                      textCapitalization: TextCapitalization.none,
                      validator: RegValidators.url,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Location & services'),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _area,
                      label: 'Area',
                      hint: 'Dhanmondi, Gulshan, etc.',
                      wireKey: 'area',
                      errors: _serverErrors,
                      icon: Icons.map_outlined,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 100,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _services,
                      label: 'Services',
                      hint: 'Panchakarma, Udvartana, Nasya…',
                      wireKey: 'services',
                      errors: _serverErrors,
                      maxLines: 3,
                      maxLength: 2000,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _specializations,
                      label: 'Specializations',
                      hint: 'Ayurveda, Yoga, Siddha…',
                      wireKey: 'specializations',
                      errors: _serverErrors,
                      maxLines: 2,
                      maxLength: 2000,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Hours'),
                    const SizedBox(height: 12),
                    RegDayPicker(
                      selected: _availableDays,
                      onChanged: (v) => setState(() => _availableDays = v),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: RegTimeField(
                            label: 'Opening time',
                            value: _openingTime,
                            onChanged: (v) =>
                                setState(() => _openingTime = v),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: RegTimeField(
                            label: 'Closing time',
                            value: _closingTime,
                            onChanged: (v) =>
                                setState(() => _closingTime = v),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _description,
                      label: 'Description',
                      hint: 'Tell patients about your clinic',
                      wireKey: 'description',
                      errors: _serverErrors,
                      maxLines: 4,
                      maxLength: 2000,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: busy ? null : _submit,
                      child: busy
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Create clinic account'),
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
