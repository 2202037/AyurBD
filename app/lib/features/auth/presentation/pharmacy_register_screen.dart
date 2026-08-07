/// §3.5 — pharmacy sign-up.
///
/// The widest of the four forms: a pharmacy carries two licence numbers (trade
/// and drug), a named pharmacist with their own licence, and delivery settings.
///
/// `license_number` is marked required here even though the server's rule is only
/// `max:100`. The reason is the insert: it defaults that column to `''` rather
/// than null because the live column is NOT NULL, so a blank field would quietly
/// create a pharmacy with no licence on record — which is exactly the thing an
/// admin verifying the row needs to see.
///
/// The delivery radius follows the delivery switch, and the hours follow the 24h
/// switch, so no stored value can contradict the flag beside it.
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

class PharmacyRegisterScreen extends ConsumerStatefulWidget {
  const PharmacyRegisterScreen({super.key});

  @override
  ConsumerState<PharmacyRegisterScreen> createState() =>
      _PharmacyRegisterScreenState();
}

class _PharmacyRegisterScreenState
    extends ConsumerState<PharmacyRegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _account = AccountControllers();

  final _whatsapp = TextEditingController();
  final _licenseNumber = TextEditingController();
  final _drugLicenseNumber = TextEditingController();
  final _ownerName = TextEditingController();
  final _pharmacistName = TextEditingController();
  final _pharmacistLicense = TextEditingController();
  final _establishedYear = TextEditingController();
  final _area = TextEditingController();
  final _services = TextEditingController();
  final _deliveryRadiusKm = TextEditingController();
  final _description = TextEditingController();

  String? _pharmacyType;
  TimeOfDay? _openingTime;
  TimeOfDay? _closingTime;
  bool _deliveryAvailable = false;
  bool _open24Hours = false;
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    _account.dispose();
    for (final c in [
      _whatsapp, _licenseNumber, _drugLicenseNumber, _ownerName,
      _pharmacistName, _pharmacistLicense, _establishedYear, _area,
      _services, _deliveryRadiusKm, _description,
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
            role: SignupRole.pharmacy.value,
            passwordConfirm: _account.confirm.text,
            city: _account.city.text,
            address: _account.address.text,
            extra: RegistrationFields.pharmacy(
              whatsapp: _whatsapp.text,
              licenseNumber: _licenseNumber.text,
              drugLicenseNumber: _drugLicenseNumber.text,
              pharmacyType: _pharmacyType,
              ownerName: _ownerName.text,
              pharmacistName: _pharmacistName.text,
              pharmacistLicense: _pharmacistLicense.text,
              establishedYear: _establishedYear.text,
              area: _area.text,
              services: _services.text,
              deliveryAvailable: _deliveryAvailable,
              deliveryRadiusKm: _deliveryRadiusKm.text,
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
        showToast(
          context,
          'Account created. An admin will verify your pharmacy.',
        );
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
      appBar: AppBar(title: const Text('Register a pharmacy')),
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
                    const ProviderPendingNotice(what: 'Your pharmacy'),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Contact details'),
                    const SizedBox(height: 12),
                    AccountSection(
                      controllers: _account,
                      errors: _serverErrors,
                      gender: null,
                      onGenderChanged: (_) {},
                      nameLabel: 'Pharmacy name',
                      emailLabel: 'Pharmacy email',
                      addressLabel: 'Pharmacy address',
                      showGender: false,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _whatsapp,
                      label: 'WhatsApp number',
                      hint: 'For order enquiries',
                      wireKey: 'whatsapp',
                      errors: _serverErrors,
                      icon: Icons.chat_outlined,
                      keyboardType: TextInputType.phone,
                      textCapitalization: TextCapitalization.none,
                      validator: RegValidators.optionalPhone,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Licensing'),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _licenseNumber,
                      label: 'Trade licence number',
                      wireKey: 'license_number',
                      errors: _serverErrors,
                      icon: Icons.verified_outlined,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 100,
                      required: true,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _drugLicenseNumber,
                      label: 'Drug licence number',
                      wireKey: 'drug_license_number',
                      errors: _serverErrors,
                      icon: Icons.medication_outlined,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 100,
                    ),
                    const SizedBox(height: 12),
                    RegDropdown(
                      label: 'Pharmacy type',
                      value: _pharmacyType,
                      options: const [
                        'Retail',
                        'Wholesale',
                        'Hospital',
                        'Online',
                        'Ayurvedic',
                        'Herbal',
                      ],
                      onChanged: (v) => setState(() => _pharmacyType = v),
                      icon: Icons.category_outlined,
                    ),
                    const SizedBox(height: 12),
                    RegNumberField(
                      controller: _establishedYear,
                      label: 'Established year',
                      hint: 'e.g. 2012',
                      wireKey: 'established_year',
                      errors: _serverErrors,
                      icon: Icons.calendar_today_outlined,
                      // Server rule is `min:1800`; matching it here keeps the
                      // client from rejecting a year the API would accept.
                      min: 1800,
                      max: DateTime.now().year,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'People'),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _ownerName,
                      label: 'Owner name',
                      wireKey: 'owner_name',
                      errors: _serverErrors,
                      icon: Icons.person_outline,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 150,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _pharmacistName,
                      label: 'Pharmacist name',
                      wireKey: 'pharmacist_name',
                      errors: _serverErrors,
                      icon: Icons.medical_information_outlined,
                      textCapitalization: TextCapitalization.words,
                      maxLength: 150,
                    ),
                    const SizedBox(height: 12),
                    RegField(
                      controller: _pharmacistLicense,
                      label: 'Pharmacist licence',
                      wireKey: 'pharmacist_license',
                      errors: _serverErrors,
                      icon: Icons.badge_outlined,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 100,
                    ),
                    const SizedBox(height: 20),
                    const SectionHeader(title: 'Location & delivery'),
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
                    RegField(
                      controller: _services,
                      label: 'Services',
                      hint: 'Prescription filling, home delivery, BP checks…',
                      wireKey: 'services',
                      errors: _serverErrors,
                      maxLines: 3,
                      maxLength: 2000,
                    ),
                    const SizedBox(height: 4),
                    RegSwitch(
                      label: 'Home delivery',
                      subtitle: 'Deliver orders to a patient address',
                      value: _deliveryAvailable,
                      onChanged: (v) => setState(() => _deliveryAvailable = v),
                    ),
                    if (_deliveryAvailable) ...[
                      const SizedBox(height: 8),
                      RegNumberField(
                        controller: _deliveryRadiusKm,
                        label: 'Delivery radius (km)',
                        wireKey: 'delivery_radius_km',
                        errors: _serverErrors,
                        icon: Icons.social_distance_outlined,
                        min: 0,
                        max: 500,
                      ),
                    ],
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
                              onChanged: (v) => setState(() => _openingTime = v),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: RegTimeField(
                              label: 'Closing time',
                              value: _closingTime,
                              onChanged: (v) => setState(() => _closingTime = v),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 12),
                    RegField(
                      controller: _description,
                      label: 'Description',
                      hint: 'Tell customers about your pharmacy',
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
                          : const Text('Create pharmacy account'),
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
