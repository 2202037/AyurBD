/// Sign in. On success nothing here navigates — the auth state flips, the
/// router's refreshListenable fires, and the redirect sends the user to the shell
/// or the stub dashboard depending on their role (§7).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_config.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import 'auth_controller.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _obscure = true;

  /// Field errors the *server* returned, keyed as §6 sends them. Cleared on the
  /// next submit so a stale message can't outlive the value that caused it.
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _serverErrors = const {});
    if (!(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();

    try {
      await ref.read(authControllerProvider.notifier).login(
            email: _email.text,
            password: _password.text,
          );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _serverErrors = e.errors);
      // Re-run validation so any field-level message from the server appears
      // under the right input rather than only in the snackbar.
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
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: busy,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: AppSemantic.of(context).primary,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.spa_rounded,
                              size: 38, color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Welcome back',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Sign in to book appointments and order medicine.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          hintText: 'you@example.com',
                          prefixIcon: Icon(Icons.mail_outline),
                        ),
                        validator: (v) =>
                            _serverErrors['email'] ?? Validators.email(v),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        autofillHints: const [AutofillHints.password],
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            tooltip:
                                _obscure ? 'Show password' : 'Hide password',
                          ),
                        ),
                        validator: (v) =>
                            _serverErrors['password'] ??
                            Validators.loginPassword(v),
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
                            : const Text('Sign in'),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'New to ${AppConfig.appName}?',
                            style: theme.textTheme.bodyMedium,
                          ),
                          TextButton(
                            onPressed:
                                busy ? null : () => context.push(Routes.signup),
                            child: const Text('Create an account'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _DemoCredentials(onUseAdmin: () {
                        _email.text = 'admin@ayur.com';
                        _password.text = 'Ayur@1234';
                        setState(() => _obscure = false);
                      }),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How to get an account, shown in-app so a first run needs no README lookup.
///
/// The admin account is real and its credentials are fixed, so they are listed
/// with a one-tap fill — no typing, which eliminates keyboard/autofill
/// discrepancies as a failure mode for the demo path.
class _DemoCredentials extends StatelessWidget {
  const _DemoCredentials({required this.onUseAdmin});

  final VoidCallback onUseAdmin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.science_outlined,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Demo admin access',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'admin@ayur.com\nAyur@1234',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This account was created in Supabase Auth and promoted to admin '
              'in public.users. If your own typing keeps failing, use the fill '
              'button below — it puts the exact values into the form.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: onUseAdmin,
                icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                label: const Text('Fill admin credentials'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
