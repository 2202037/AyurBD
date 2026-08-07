/// The shared half of every sign-up form (§3.1–3.5).
///
/// All five roles post the same `users` columns — name, email, phone, password,
/// gender, city, address — and differ only in the role-specific block below.
/// Rather than repeat that block in four provider screens, each screen owns the
/// controllers and hands them here.
///
/// Controllers stay with the screen because the screen is what reads them at
/// submit time; this widget only renders and validates them.
library;

import 'package:flutter/material.dart';

import '../../../../core/utils/validators.dart';
import '../../data/registration_fields.dart';
import 'registration_fields_ui.dart';

/// Groups the shared controllers so a screen passes one object, not seven args.
class AccountControllers {
  AccountControllers();

  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  final city = TextEditingController();
  final address = TextEditingController();

  /// Called from the screen's own `dispose`.
  void dispose() {
    for (final c in [name, email, phone, password, confirm, city, address]) {
      c.dispose();
    }
  }
}

class AccountSection extends StatefulWidget {
  const AccountSection({
    super.key,
    required this.controllers,
    required this.errors,
    required this.gender,
    required this.onGenderChanged,
    this.nameLabel = 'Full name',
    this.nameHint,
    this.emailLabel = 'Email',
    this.addressLabel = 'Address',
    this.showGender = true,
  });

  final AccountControllers controllers;
  final Map<String, String> errors;
  final Gender? gender;
  final ValueChanged<Gender?> onGenderChanged;

  /// Providers label these as the organisation's own contact details — a hospital
  /// signing up is naming the hospital, not a person.
  final String nameLabel;
  final String? nameHint;
  final String emailLabel;
  final String addressLabel;

  /// Off for the three organisation roles, where a gender field is meaningless.
  final bool showGender;

  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  /// Local because it is pure presentation — the screen has no reason to know
  /// whether the password is currently visible.
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final c = widget.controllers;
    final errors = widget.errors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RegField(
          controller: c.name,
          label: widget.nameLabel,
          hint: widget.nameHint,
          wireKey: 'name',
          errors: errors,
          icon: Icons.person_outline,
          textCapitalization: TextCapitalization.words,
          required: true,
          validator: Validators.name,
        ),
        const SizedBox(height: 12),
        RegField(
          controller: c.email,
          label: widget.emailLabel,
          wireKey: 'email',
          errors: errors,
          icon: Icons.mail_outline,
          keyboardType: TextInputType.emailAddress,
          textCapitalization: TextCapitalization.none,
          required: true,
          validator: Validators.email,
        ),
        const SizedBox(height: 12),
        RegField(
          controller: c.phone,
          label: 'Mobile number',
          hint: '01712345678',
          wireKey: 'phone',
          errors: errors,
          icon: Icons.phone_outlined,
          keyboardType: TextInputType.phone,
          textCapitalization: TextCapitalization.none,
          required: true,
          validator: Validators.phone,
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: c.password,
          obscureText: _obscure,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Password *',
            helperText: 'At least 8 characters, with a letter and a number.',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
          validator: (v) => errors['password'] ?? Validators.password(v),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: c.confirm,
          // Follows the same toggle: revealing one and masking the other would
          // defeat the point of checking them against each other.
          obscureText: _obscure,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Confirm password *',
            prefixIcon: Icon(Icons.lock_reset_outlined),
          ),
          validator: (v) =>
              errors['password_confirm'] ??
              Validators.confirmPassword(v, c.password.text),
        ),
        if (widget.showGender) ...[
          const SizedBox(height: 12),
          RegGenderField(
            value: widget.gender,
            onChanged: widget.onGenderChanged,
          ),
        ],
        const SizedBox(height: 12),
        RegField(
          controller: c.city,
          label: 'City',
          hint: 'Dhaka',
          wireKey: 'city',
          errors: errors,
          icon: Icons.location_city_outlined,
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 12),
        RegField(
          controller: c.address,
          label: widget.addressLabel,
          wireKey: 'address',
          errors: errors,
          icon: Icons.home_outlined,
          maxLines: 2,
          validator: (v) => Validators.notes(v, max: 255),
        ),
      ],
    );
  }
}

/// The "an admin will check this" banner the four provider forms share.
///
/// Said before the fields rather than after the button, so the review step is
/// known going in rather than discovered on submit.
class ProviderPendingNotice extends StatelessWidget {
  const ProviderPendingNotice({super.key, this.what = 'Your profile'});

  final String what;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: theme.colorScheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$what will be reviewed by an admin before it appears publicly. '
              'You can sign in and finish your details right away.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
