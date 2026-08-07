/// Patient sign-up. Role is not a field: `role` is hard-coded to `patient` in the
/// repository, because letting a stranger pick `admin` from a dropdown would be a
/// privilege-escalation hole. Provider accounts are created by an admin (§4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import 'auth_controller.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _city = TextEditingController();
  final _address = TextEditingController();

  bool _obscure = true;
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _password, _confirm, _city, _address]) {
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
            name: _name.text,
            email: _email.text,
            password: _password.text,
            phone: _phone.text,
            city: _city.text,
            address: _address.text,
          );
      if (!mounted) return;
      if (signedIn) {
        // The router redirect handles navigation; just confirm.
        showToast(context, 'Welcome to AYUR.');
      } else {
        // Registered but not signed in. The project runs with email
        // confirmation disabled (mailer_autoconfirm), so this branch is
        // normally dead — signUp returns a session and the caller is signed
        // in above. It is kept as a safety net for the day confirmation is
        // re-enabled: the account is unusable until the link is followed, so
        // say so plainly instead of the generic "please sign in", which
        // would read as a failure.
        showToast(
          context,
          'Account created. Confirm your email first, then sign in.',
        );
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
      appBar: AppBar(title: const Text('Create account')),
      body: AbsorbPointer(
        absorbing: busy,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (v) => _serverErrors['name'] ?? Validators.name(v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (v) => _serverErrors['email'] ?? Validators.email(v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Mobile number',
                        hintText: '01712345678',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                      validator: (v) => _serverErrors['phone'] ?? Validators.phone(v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Password',
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
                      validator: (v) => _serverErrors['password'] ?? Validators.password(v),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _confirm,
                      obscureText: _obscure,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Confirm password',
                        prefixIcon: Icon(Icons.lock_reset_outlined),
                      ),
                      validator: (v) => Validators.confirmPassword(v, _password.text),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _city,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'City (optional)',
                        hintText: 'Dhaka',
                        prefixIcon: Icon(Icons.location_city_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _address,
                      textCapitalization: TextCapitalization.sentences,
                      maxLines: 2,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Address (optional)',
                        prefixIcon: Icon(Icons.home_outlined),
                      ),
                      validator: (v) => Validators.notes(v, max: 255),
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
                          : const Text('Create account'),
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
