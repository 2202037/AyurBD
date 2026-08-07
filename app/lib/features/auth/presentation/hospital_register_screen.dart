/// §3.3 — hospital sign-up.
///
/// `open_24_hours` gates the time pickers: when on, the two values are left out
/// of the payload entirely rather than set to meaningless placeholders, and the
/// profile screen can render "Open 24 hours" without also rendering "09:00–17:00"
/// underneath it.
///
/// The `description` field is `users.address` for the hospital's own contact
/// address, distinct from the free-text location details in the address field
/// below.
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

class HospitalRegisterScreen extends ConsumerStatefulWidget {
  const HospitalRegisterScreen({super.key});

  @override
  ConsumerState<HospitalRegisterScreen> createState() =>
      _HospitalRegisterScreenState();
}

class _HospitalRegisterScreenState extends ConsumerState<HospitalRegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _account = AccountControllers();

  final _emergencyPhone = TextEditingController();
  final _registrationNumber = TextEditingController();
  final _licenseNumber = TextEditingController();
  final _establishedYear = TextEditingController();
  final _website = TextEditingController();
  final _area = TextEditingController();
  final _totalBeds = TextEditingController();
  final _icuBeds = TextEditingController();
  final _facilities = TextEditingController();
  final _departments = TextEditingController();
  final _description = TextEditingController();

  String? _hospitalType;
  TimeOfDay? _openingTime;
  TimeOfDay? _closingTime;
  bool _open24Hours = false;
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    _account.dispose();
    for (final c in [
      _emergencyPhone, _registrationNumber, _licenseNumber, _establishedYear,
      _website, _area, _totalBeds, _icuBeds, _facilities, _departments,
      _description,
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
            role: SignupRole.hospital.value,
            passwordConfirm: _account.confirm.text,
            city: _account.city.text,
            address: _account.address.text,
            extra: RegistrationFields.hospital(
              emergencyPhone: _emergencyPhone.text,
              registrationNumber: _registrationNumber.text,
              licenseNumber: _licenseNumber.text,
              hospitalType: _hospitalType,
              establishedYear: _establishedYear.text,
              website: _website.text,
              area: _area.text,
              totalBeds: _totalBeds.text,
              icuBeds: _icuBeds.text,
              facilities: _facilities.text,
              departments: _departments.text,
              open24Hours: _open24Hours,
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
        showToast(context, 'Account created. An admin will verify your hospital.');
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
      appBar: AppBar(title: const Text('Register a hospital')),
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
                    const ProviderPendingNotice(what: 'Your hospital'),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Contact details'),
                    const SizedBox(height: 12),
                    AccountSection(
                      controllers: _account,
                      errors: _serverErrors,
                      gender: null,
                      onGenderChanged: (_) {},
                      nameLabel: 'Hospital name',
                      emailLabel: 'Hospital email',
                      addressLabel: 'Hospital address',
                      showGender: false,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _emergencyPhone,
                      label: 'Emergency phone',
                      hint: 'Separate line for urgent inquiries',
                      wireKey: 'emergency_phone',
                      errors: _serverErrors,
                      icon: Icons.local_police_outlined,
                      keyboardType: TextInputType.phone,
                      textCapitalization: TextCapitalization.none,
                      validator: RegValidators.optionalPhone,
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
                      label: 'Hospital type',
                      value: _hospitalType,
                      options: const [
                        'General',
                        'Specialised',
                        'Teaching',
                        'District',
                        'Private',
                        'Ayurvedic',
                      ],
                      onChanged: (v) => setState(() => _hospitalType = v),
                      icon: Icons.category_outlined,
                    ),
                    const SizedBox(height: 12),
                    RegNumberField(
                      controller: _establishedYear,
                      label: 'Established year',
                      hint: 'e.g. 2005',
                      wireKey: 'established_year',
                      errors: _serverErrors,
                      icon: Icons.calendar_today_outlined,
                      // Matches the server's `min:1800`. Several hospitals in
                      // Dhaka predate 1900 — Mitford dates to 1820 — so a
                      // tighter floor would reject a true answer.
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
                    const SectionHeader(title: 'Location & capacity'),
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
                    Row(
                      children: [
                        Expanded(
                          child: RegNumberField(
                            controller: _totalBeds,
                            label: 'Total beds',
                            wireKey: 'total_beds',
                            errors: _serverErrors,
                            icon: Icons.bed_outlined,
                            min: 0,
                            max: 100000,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: RegNumberField(
                            controller: _icuBeds,
                            label: 'ICU beds',
                            wireKey: 'icu_beds',
                            errors: _serverErrors,
                            icon: Icons.air_outlined,
                            min: 0,
                            max: 100000,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _facilities,
                      label: 'Facilities',
                      hint: 'MRI, CT, cath lab, dialysis centre…',
                      wireKey: 'facilities',
                      errors: _serverErrors,
                      maxLines: 3,
                      maxLength: 2000,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _departments,
                      label: 'Departments',
                      hint: 'Cardiology, Neurology, Surgery…',
                      wireKey: 'departments',
                      errors: _serverErrors,
                      maxLines: 3,
                      maxLength: 2000,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Hours'),
                    const SizedBox(height: 12),
                    RegSwitch(
                      label: 'Open 24 hours',
                      value: _open24Hours,
                      onChanged: (v) => setState(() => _open24Hours = v),
                    ),
                    if (!_open24Hours) ...[
                      const SizedBox(height: 12),
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
                    ],
                    const SizedBox(height: 12),
                    RegField(
                      controller: _description,
                      label: 'Description',
                      hint: 'Tell patients about your hospital',
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
                          : const Text('Create hospital account'),
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
