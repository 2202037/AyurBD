/// Account screen: profile edit, password change, theme, sign out.
///
/// The edit form sends only the keys `auth_profile_update()` whitelists —
/// `name`, `phone`, `address`, `city`, `blood_group`, `profile_image`. Anything
/// else `validate()` would drop silently, and a body it recognises *nothing* in
/// is a hard 400 ("No fields to update."), so Save is disabled until something
/// actually changes.
///
/// One more constraint the server imposes: `validate()` treats an empty string
/// as *absent*, so a blank value cannot clear a field that already has one — it
/// is simply dropped, and if it was the only field sent the request 400s. The
/// form says so instead of letting the user think the clear worked.
///
/// Sign out clears secure storage even if the network call fails — otherwise a
/// user with no connection could not sign out of a shared phone (§10).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_config.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme_controller.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/app_user.dart';
import '../../../models/blood_models.dart';
import '../data/auth_repository.dart';
import 'auth_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: user == null
          // The router only reaches this screen with a session, so this is the
          // brief window during a sign-out, not an error state.
          ? const LoadingView()
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.gap, AppTheme.gap, AppTheme.gap, AppTheme.gap * 2),
              children: [
                _IdentityCard(user: user),
                const SizedBox(height: AppTheme.gap),
                _DetailsCard(user: user),
                const SizedBox(height: AppTheme.gap),
                const _PreferencesCard(),
                const SizedBox(height: AppTheme.gap),
                _MoreCard(role: user.role),
                const SizedBox(height: AppTheme.gap),
                _ActionsCard(user: user),
                const SizedBox(height: AppTheme.gap),
                Center(
                  child: Text(
                    '${AppConfig.appName} · v1.0.0',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gap),
        child: Row(
          children: [
            AvatarCircle(imagePath: user.image, name: user.name, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: theme.textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.email,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      // Role is server-assigned and read-only here. The register
                      // form has no role selector for the same reason.
                      //
                      // Fixed 'active' status rather than a flag: `users` has no
                      // is_active column, and a signed-in session is by
                      // definition an enabled account.
                      StatusPill(
                        status: 'active',
                        label: user.role.label,
                        dense: true,
                      ),
                      if (user.bloodGroup != null) ...[
                        const SizedBox(width: 6),
                        StatusPill(
                          status: 'critical',
                          label: user.bloodGroup!,
                          dense: true,
                        ),
                      ],
                    ],
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

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Contact details', style: theme.textTheme.titleSmall),
                ),
                TextButton.icon(
                  onPressed: () => _openEditor(context, user),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Edit'),
                ),
              ],
            ),
            _InfoRow(icon: Icons.call_outlined, label: 'Phone', value: user.phone),
            _InfoRow(icon: Icons.place_outlined, label: 'Address', value: user.address),
            _InfoRow(
                icon: Icons.location_city_outlined, label: 'City', value: user.city),
            _InfoRow(
              icon: Icons.bloodtype_outlined,
              label: 'Blood group',
              value: user.bloodGroup,
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, AppUser user) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _EditProfileSheet(user: user),
    );
    if (saved == true && context.mounted) {
      showToast(context, 'Profile updated.');
    }
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final empty = value == null || value!.isEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: muted),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              empty ? 'Not set' : value!,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: empty ? muted : null,
                fontStyle: empty ? FontStyle.italic : null,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreferencesCard extends ConsumerWidget {
  const _PreferencesCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Both lines are needed: `.notifier` hands over the controller but does not
    // rebuild when the mode changes, so the icon and label would go stale.
    final mode = ref.watch(themeModeProvider);
    final controller = ref.watch(themeModeProvider.notifier);
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Appearance', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined, size: 18),
                  label: Text('System'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined, size: 18),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined, size: 18),
                  label: Text('Dark'),
                ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => controller.set(s.first),
            ),
            const SizedBox(height: 8),
            Text(
              controller.label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Everything reachable from the profile that is not the account itself: the
/// patient extras (§5), then the §13 static pages.
///
/// The first three rows are patient-only because the router's `_patientOnly`
/// guard would bounce any other role straight back — offering a tap that
/// redirects is worse than not offering it. The static pages and feedback are
/// open to every role, so they are always shown.
class _MoreCard extends StatelessWidget {
  const _MoreCard({required this.role});

  final UserRole role;

  @override
  Widget build(BuildContext context) {
    final patient = role == UserRole.patient;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (patient) ...[
            const _MoreRow(
              icon: Icons.insights_outlined,
              label: 'My dashboard',
              subtitle: 'Visits, orders and reviews at a glance',
              route: Routes.dashboard,
            ),
            const Divider(height: 1),
            const _MoreRow(
              icon: Icons.rate_review_outlined,
              label: 'My reviews',
              subtitle: 'Everything you have written',
              route: Routes.myReviews,
            ),
            const Divider(height: 1),
            const _MoreRow(
              icon: Icons.near_me_outlined,
              label: 'Nearby',
              subtitle: 'Providers in your city',
              route: Routes.nearby,
            ),
            const Divider(height: 1),
          ],
          const _MoreRow(
            icon: Icons.emergency_outlined,
            label: 'Emergency hotlines',
            subtitle: 'Ambulance, fire, police',
            route: Routes.emergency,
            danger: true,
          ),
          const Divider(height: 1),
          const _MoreRow(
            icon: Icons.forum_outlined,
            label: 'Send feedback',
            route: Routes.feedback,
          ),
          const Divider(height: 1),
          const _MoreRow(
            icon: Icons.info_outline,
            label: 'About',
            route: Routes.about,
          ),
          const Divider(height: 1),
          const _MoreRow(
            icon: Icons.gavel_outlined,
            label: 'Terms of use',
            route: Routes.terms,
          ),
          const Divider(height: 1),
          const _MoreRow(
            icon: Icons.privacy_tip_outlined,
            label: 'Privacy',
            route: Routes.privacy,
          ),
          const Divider(height: 1),
          const _MoreRow(
            icon: Icons.mail_outline,
            label: 'Contact',
            route: Routes.contact,
          ),
        ],
      ),
    );
  }
}

class _MoreRow extends StatelessWidget {
  const _MoreRow({
    required this.icon,
    required this.label,
    required this.route,
    this.subtitle,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String route;
  final String? subtitle;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? Theme.of(context).colorScheme.error : null;

    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: () => context.push(route),
    );
  }
}

class _ActionsCard extends ConsumerWidget {
  const _ActionsCard({required this.user});

  final AppUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(authControllerProvider).busy;
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Change password'),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: busy ? null : () => _changePassword(context),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.logout, color: theme.colorScheme.error),
            title: Text(
              'Sign out',
              style: TextStyle(
                color: theme.colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text('Signed in as ${user.email}'),
            onTap: busy ? null : () => _signOut(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _changePassword(BuildContext context) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _ChangePasswordSheet(),
    );
    if (changed == true && context.mounted) {
      showToast(context, 'Password changed.');
    }
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need your password to sign back in.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // No navigation here — the router watches the session and redirects to
    // /login on its own. Pushing as well would race it.
    await ref.read(authControllerProvider.notifier).logout();
  }
}

/// Edit sheet. Sends only changed fields, which keeps the request small and, more
/// importantly, matches the server: a body with nothing it recognises is a 400.
class _EditProfileSheet extends ConsumerStatefulWidget {
  const _EditProfileSheet({required this.user});

  final AppUser user;

  @override
  ConsumerState<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<_EditProfileSheet> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _city;

  String? _bloodGroup;
  bool _busy = false;
  Map<String, String> _serverErrors = const {};

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.user.name);
    _phone = TextEditingController(text: widget.user.phone ?? '');
    _address = TextEditingController(text: widget.user.address ?? '');
    _city = TextEditingController(text: widget.user.city ?? '');
    _bloodGroup = widget.user.bloodGroup;
  }

  @override
  void dispose() {
    for (final c in [_name, _phone, _address, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Only the differences, trimmed the same way the server trims them so an
  /// added space doesn't count as a change.
  Map<String, String?> _changes() {
    final u = widget.user;
    return {
      if (_name.text.trim() != u.name) 'name': _name.text.trim(),
      if (_phone.text.trim() != (u.phone ?? '')) 'phone': _phone.text.trim(),
      if (_address.text.trim() != (u.address ?? '')) 'address': _address.text.trim(),
      if (_city.text.trim() != (u.city ?? '')) 'city': _city.text.trim(),
      if (_bloodGroup != u.bloodGroup) 'blood_group': _bloodGroup,
    };
  }

  Future<void> _save() async {
    setState(() => _serverErrors = const {});
    if (!(_form.currentState?.validate() ?? false)) return;

    final changes = _changes();
    // Empty strings are dropped by validate(), so a change that only blanks a
    // field would silently do nothing. Say so rather than show a false success.
    final effective = changes.entries.where((e) => (e.value ?? '').isNotEmpty);
    if (effective.isEmpty) {
      showToast(
        context,
        changes.isEmpty
            ? 'Nothing changed.'
            : 'A field cannot be cleared from the app — enter a new value.',
        error: changes.isNotEmpty,
      );
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final map = Map.fromEntries(effective);
      final user = await ref.read(authRepositoryProvider).updateProfile(
            name: map['name'],
            phone: map['phone'],
            address: map['address'],
            city: map['city'],
            bloodGroup: map['blood_group'],
          );
      if (!mounted) return;
      ref.read(authControllerProvider.notifier).setUser(user);
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _serverErrors = e.errors;
      });
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
    return _SheetFrame(
      title: 'Edit profile',
      busy: _busy,
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
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Phone',
                hintText: '01XXXXXXXXX',
                prefixIcon: Icon(Icons.call_outlined),
              ),
              validator: (v) =>
                  _serverErrors['phone'] ?? Validators.phone(v, optional: true),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _city,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'City',
                prefixIcon: Icon(Icons.location_city_outlined),
              ),
              validator: (v) => _serverErrors['city'],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _address,
              textCapitalization: TextCapitalization.sentences,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Address',
                prefixIcon: Icon(Icons.place_outlined),
              ),
              validator: (v) => _serverErrors['address'],
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _bloodGroup,
              decoration: InputDecoration(
                labelText: 'Blood group',
                prefixIcon: const Icon(Icons.bloodtype_outlined),
                errorText: _serverErrors['blood_group'],
                helperText: 'Used to prefill your blood requests',
              ),
              items: [
                for (final g in kBloodGroups)
                  DropdownMenuItem(value: g, child: Text(g)),
              ],
              onChanged: _busy ? null : (v) => setState(() => _bloodGroup = v),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Change-password sheet. The server re-checks the current password with
/// `password_verify` and returns its complaint on the `current_password` field,
/// which is surfaced inline rather than as a bare toast.
class _ChangePasswordSheet extends ConsumerStatefulWidget {
  const _ChangePasswordSheet();

  @override
  ConsumerState<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<_ChangePasswordSheet> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _obscure = true;
  bool _busy = false;
  Map<String, String> _serverErrors = const {};

  @override
  void dispose() {
    for (final c in [_current, _next, _confirm]) {
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
      await ref.read(authRepositoryProvider).changePassword(
            currentPassword: _current.text,
            newPassword: _next.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _serverErrors = e.errors;
      });
      _form.currentState?.validate();
      // A wrong current password already shows on the field; a rate-limit or
      // server fault does not, so the message goes out either way.
      showToast(context, e.message, error: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      title: 'Change password',
      busy: _busy,
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _current,
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Current password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscure ? 'Show' : 'Hide',
                ),
              ),
              validator: (v) =>
                  _serverErrors['current_password'] ?? Validators.loginPassword(v),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _next,
              obscureText: _obscure,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'New password',
                prefixIcon: Icon(Icons.lock_reset_outlined),
                helperText: 'At least 8 characters, with a letter and a number',
              ),
              validator: (v) =>
                  _serverErrors['new_password'] ?? Validators.password(v),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _confirm,
              obscureText: _obscure,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
                prefixIcon: Icon(Icons.lock_reset_outlined),
              ),
              validator: (v) => Validators.confirmPassword(v, _next.text),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: const Text('Update password'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared chrome for the two sheets: drag handle, title, keyboard-aware padding,
/// and a busy blocker so neither form can be submitted twice.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.title, required this.busy, required this.child});

  final String title;
  final bool busy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // viewInsets keeps the fields above the keyboard on a short phone.
    final bottom = MediaQuery.viewInsetsOf(context).bottom;

    return AbsorbPointer(
      absorbing: busy,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.gap),
            child,
          ],
        ),
      ),
    );
  }
}
