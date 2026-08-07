/// §3.2 — doctor sign-up.
///
/// Twelve role-specific fields on top of the shared account block, posted to the
/// one `/auth/register` endpoint with `role: 'doctor'`. The server picks the
/// matching rule set from `auth_role_rules()` and writes `users` + `doctors` in a
/// single transaction, both left at status `pending`.
///
/// `chamber_address` is the doctor's own practice location and is separate from
/// the account's home `address`; `hospital_clinic_name` is free text naming where
/// they work, not a foreign key — the live `doctors` table has no clinic_id.
///
/// feature.md §3.2 also lists a BMDC certificate upload. No multipart handler is
/// wired to this endpoint (the column is a `max:255` path string), so the form
/// does not pretend to collect a file.
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

class DoctorRegisterScreen extends ConsumerStatefulWidget {
  const DoctorRegisterScreen({super.key});

  @override
  ConsumerState<DoctorRegisterScreen> createState() =>
      _DoctorRegisterScreenState();
}

class _DoctorRegisterScreenState extends ConsumerState<DoctorRegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _account = AccountControllers();

  final _bmdcNumber = TextEditingController();
  final _specialization = TextEditingController();
  final _qualifications = TextEditingController();
  final _medicalSchool = TextEditingController();
  final _graduationYear = TextEditingController();
  final _experienceYears = TextEditingController();
  final _hospitalClinicName = TextEditingController();
  final _chamberAddress = TextEditingController();
  final _area = TextEditingController();
  final _consultationFee = TextEditingController();
  final _bio = TextEditingController();

  Gender? _gender;
  String? _doctorType;
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    _account.dispose();
    for (final c in [
      _bmdcNumber,
      _specialization,
      _qualifications,
      _medicalSchool,
      _graduationYear,
      _experienceYears,
      _hospitalClinicName,
      _chamberAddress,
      _area,
      _consultationFee,
      _bio,
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
            role: SignupRole.doctor.value,
            passwordConfirm: _account.confirm.text,
            city: _account.city.text,
            address: _account.address.text,
            gender: _gender?.value,
            extra: RegistrationFields.doctor(
              bmdcNumber: _bmdcNumber.text,
              specialization: _specialization.text,
              qualifications: _qualifications.text,
              medicalSchool: _medicalSchool.text,
              graduationYear: _graduationYear.text,
              experienceYears: _experienceYears.text,
              doctorType: _doctorType,
              hospitalClinicName: _hospitalClinicName.text,
              chamberAddress: _chamberAddress.text,
              area: _area.text,
              consultationFee: _consultationFee.text,
              bio: _bio.text,
            ),
          );
      if (!mounted) return;
      // On success the router redirects on the auth state change; this only adds
      // the wording, since landing on a pending dashboard with no explanation
      // reads as a broken sign-up.
      if (signedIn) {
        showToast(context, 'Account created. An admin will verify your profile.');
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
      appBar: AppBar(title: const Text('Register as a doctor')),
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
                    const ProviderPendingNotice(),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Your account'),
                    const SizedBox(height: 12),
                    AccountSection(
                      controllers: _account,
                      errors: _serverErrors,
                      gender: _gender,
                      onGenderChanged: (v) => setState(() => _gender = v),
                      nameHint: 'As registered with the BMDC',
                      addressLabel: 'Home address',
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(title: 'Registration & qualifications'),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _bmdcNumber,
                      label: 'BMDC number',
                      hint: 'Bangladesh Medical & Dental Council',
                      wireKey: 'bmdc_number',
                      errors: _serverErrors,
                      icon: Icons.badge_outlined,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 50,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _specialization,
                      label: 'Specialization',
                      hint: 'Cardiology, Medicine, Ayurveda…',
                      wireKey: 'specialization',
                      errors: _serverErrors,
                      icon: Icons.medical_services_outlined,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 150,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _qualifications,
                      label: 'Qualifications',
                      hint: 'MBBS, FCPS, BAMS…',
                      wireKey: 'qualifications',
                      errors: _serverErrors,
                      icon: Icons.school_outlined,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 255,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _medicalSchool,
                      label: 'Medical school',
                      wireKey: 'medical_school',
                      errors: _serverErrors,
                      icon: Icons.domain_outlined,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 150,
                    ),
                    const SizedBox(height: 12),
                    RegNumberField(
                      controller: _graduationYear,
                      label: 'Graduation year',
                      hint: 'e.g. 2015',
                      wireKey: 'graduation_year',
                      errors: _serverErrors,
                      icon: Icons.calendar_today_outlined,
                      // Narrower than the server's 1900..2100: a future
                      // graduation year is a typo, not a valid answer.
                      min: 1940,
                      max: DateTime.now().year,
                    ),
                    const SizedBox(height: 12),
                    RegNumberField(
                      controller: _experienceYears,
                      label: 'Years of experience',
                      wireKey: 'experience_years',
                      errors: _serverErrors,
                      icon: Icons.work_outline,
                      min: 0,
                      max: 80,
                    ),
                    const SizedBox(height: 24),
                    const SectionHeader(title: 'Practice'),
                    const SizedBox(height: 12),
                    RegDropdown(
                      label: 'Doctor type',
                      value: _doctorType,
                      options: const [
                        'General physician',
                        'Specialist',
                        'Consultant',
                        'Surgeon',
                        'Ayurvedic',
                        'Dentist',
                      ],
                      onChanged: (v) => setState(() => _doctorType = v),
                      icon: Icons.category_outlined,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _hospitalClinicName,
                      label: 'Hospital or clinic',
                      hint: 'Where you currently practise',
                      wireKey: 'hospital_clinic_name',
                      errors: _serverErrors,
                      icon: Icons.local_hospital_outlined,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 200,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _chamberAddress,
                      label: 'Chamber address',
                      hint: 'Where patients come to see you',
                      wireKey: 'chamber_address',
                      errors: _serverErrors,
                      icon: Icons.place_outlined,
                      maxLines: 2,
                      maxLength: 255,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _area,
                      label: 'Area',
                      hint: 'Dhanmondi, Gulshan…',
                      wireKey: 'area',
                      errors: _serverErrors,
                      icon: Icons.map_outlined,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 100,
                    ),
                    const SizedBox(height: 12),
                    RegNumberField(
                      controller: _consultationFee,
                      label: 'Consultation fee (৳)',
                      wireKey: 'consultation_fee',
                      errors: _serverErrors,
                      icon: Icons.payments_outlined,
                      min: 0,
                      max: 1000000,
                      decimal: true,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _bio,
                      label: 'About you',
                      hint: 'A short introduction shown to patients',
                      wireKey: 'bio',
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
                          : const Text('Create doctor account'),
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
