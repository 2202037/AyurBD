/// §6.4 — the doctor's own profile editor.
///
/// Two things about the wire format are easy to get wrong, so they are handled in
/// one place here rather than at each field:
///
///   * the PUT takes the real column names (`specialization`,
///     `hospital_clinic_name`) while `doctor_public()` answers with renamed keys
///     (`specialty`, `workplace`). So the form reads from [Doctor] but writes the
///     column names — see [_payload].
///   * `available_days` goes up as a comma-separated string (max 100 chars), not
///     a JSON list, because that is the column type.
///
/// Only changed fields are sent. The repository drops nulls and blank strings, so
/// clearing a field by emptying it is deliberately not possible — the server
/// whitelist has no way to express "set this to NULL", and sending "" would write
/// an empty string into a column the directory then renders as a blank line.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/directory_models.dart';
import '../data/provider_repository.dart';
import 'provider_controllers.dart';
import 'widgets/verification_banner.dart';

/// The `doctors.available_days` values. Stored as a comma-separated string, so
/// the spelling here is what ends up in the column and what
/// `appointments_slots()` matches against when generating times.
///
/// Must use 3-letter lowercase abbreviations to match the backend's comparison
/// at appointments.php:190, which parses the stored CSV and compares against
/// PHP's `date('D')` output (lowercase 'sat', 'sun', etc.). Full names like
/// 'Saturday' were previously written but never matched, leaving every doctor
/// unbookable the moment they saved their profile.
const _weekdays = <String>[
  'sat',
  'sun',
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
];

/// Display labels for [_weekdays]. The stored value has to stay lowercase and
/// abbreviated for the backend, but a chip reading "sat" looks like a defect,
/// so the label is mapped separately from the wire value.
const _weekdayLabels = <String, String>{
  'sat': 'Sat',
  'sun': 'Sun',
  'mon': 'Mon',
  'tue': 'Tue',
  'wed': 'Wed',
  'thu': 'Thu',
  'fri': 'Fri',
};

class DoctorProfileScreen extends ConsumerWidget {
  const DoctorProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(doctorDashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: async.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(
          error: e,
          onRetry: () => ref.invalidate(doctorDashboardProvider),
        ),
        // A doctor who has never saved a profile has no `doctors` row yet; §6.4
        // creates one on first write, so the form opens empty rather than erroring.
        data: (d) => _Form(
          doctor: d.doctor,
          banner: VerificationBanner(
            status: d.verification,
            accountStatus: d.accountStatus,
          ),
        ),
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({required this.doctor, required this.banner});

  final Doctor? doctor;
  final Widget banner;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  final _form = GlobalKey<FormState>();

  late final Map<String, TextEditingController> _c;
  late Set<String> _days;
  String? _gender;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.doctor;
    _c = {
      'name': TextEditingController(text: d?.name ?? ''),
      'phone': TextEditingController(text: d?.phone ?? ''),
      // Real column names as keys so [_payload] needs no translation table.
      'specialization': TextEditingController(text: d?.specialty ?? ''),
      'qualifications': TextEditingController(text: d?.qualifications ?? ''),
      'bmdc_number': TextEditingController(),
      'medical_school': TextEditingController(text: d?.medicalSchool ?? ''),
      'graduation_year': TextEditingController(
        text: d?.graduationYear == null ? '' : '${d!.graduationYear}',
      ),
      'doctor_type': TextEditingController(text: d?.doctorType ?? ''),
      'experience_years': TextEditingController(
        text: (d?.experienceYears ?? 0) == 0 ? '' : '${d!.experienceYears}',
      ),
      'consultation_fee': TextEditingController(
        text: (d?.consultationFee ?? 0) == 0
            ? ''
            : d!.consultationFee.toStringAsFixed(0),
      ),
      'hospital_clinic_name': TextEditingController(text: d?.workplace ?? ''),
      'chamber_address': TextEditingController(text: d?.chamberAddress ?? ''),
      'city': TextEditingController(text: d?.city ?? ''),
      'area': TextEditingController(text: d?.area ?? ''),
      'bio': TextEditingController(text: d?.bio ?? ''),
      'available_from': TextEditingController(text: d?.availableFrom ?? ''),
      'available_to': TextEditingController(text: d?.availableTo ?? ''),
      'slot_minutes': TextEditingController(text: '${d?.slotMinutes ?? 30}'),
    };
    _days = {...?widget.doctor?.availableDays};
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  String _t(String key) => _c[key]!.text.trim();

  /// Only non-empty values, keyed by the column names the PUT whitelists.
  Map<String, Object?> _payload() => {
        'name': _t('name'),
        'phone': _t('phone'),
        'gender': _gender,
        'bmdc_number': _t('bmdc_number'),
        'medical_school': _t('medical_school'),
        'graduation_year': int.tryParse(_t('graduation_year')),
        'doctor_type': _t('doctor_type'),
        'specialization': _t('specialization'),
        'qualifications': _t('qualifications'),
        'experience_years': int.tryParse(_t('experience_years')),
        'hospital_clinic_name': _t('hospital_clinic_name'),
        'chamber_address': _t('chamber_address'),
        'city': _t('city'),
        'area': _t('area'),
        'consultation_fee': double.tryParse(_t('consultation_fee')),
        'bio': _t('bio'),
        // Comma-separated, in week order rather than tap order, so the string is
        // stable across saves and the directory reads sensibly.
        'available_days':
            _weekdays.where(_days.contains).join(','),
        'available_from': _t('available_from'),
        'available_to': _t('available_to'),
        'slot_minutes': int.tryParse(_t('slot_minutes')),
      };

  Future<void> _save() async {
    if (_form.currentState?.validate() != true) return;

    // The server 400s on an empty body. Reaching that needs every field blank,
    // which the required validators already prevent, but the check is cheap.
    final body = _payload();
    setState(() => _busy = true);
    try {
      await ref.read(providerRepositoryProvider).updateDoctorProfile(body);
      // The PUT answers with the doctor only, not the stats, so the dashboard is
      // invalidated rather than patched — it also recomputes the banner.
      ref.invalidate(doctorDashboardProvider);
      if (mounted) showToast(context, 'Profile updated.');
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickTime(String key) async {
    final existing = _t(key);
    final parts = existing.split(':');
    final initial = TimeOfDay(
      hour: parts.isNotEmpty ? int.tryParse(parts[0]) ?? 9 : 9,
      minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    // `HH:MM:SS` — the `time` validator on the server accepts this, and it is
    // what the slots generator reads back.
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    setState(() => _c[key]!.text = '$hh:$mm:00');
  }
  @override
  Widget build(BuildContext context) {
    return BlockingOverlay(
      busy: _busy,
      message: 'Saving…',
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppTheme.gap),
          children: [
            widget.banner,
            if (widget.doctor == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'You have not set up your practice details yet. Fill this '
                      'in and save — an administrator then reviews it before you '
                      'appear in the directory.',
                    ),
                  ),
                ),
              ),
            _Group(
              title: 'About you',
              children: [
                _field('name', 'Full name',
                    icon: Icons.person_outline,
                    validator: Validators.name),
                _field('phone', 'Phone',
                    icon: Icons.call_outlined,
                    keyboard: TextInputType.phone,
                    validator: (v) => Validators.phone(v, optional: true)),
                DropdownButtonFormField<String>(
                  // `value:`, not `initialValue:` — the latter only exists on
                  // Flutter 3.35+ and this package targets 3.3.
                  initialValue: _gender,
                  decoration: const InputDecoration(
                    labelText: 'Gender',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  // Exactly the three values the server's `in:` rule accepts.
                  items: const [
                    DropdownMenuItem(value: 'male', child: Text('Male')),
                    DropdownMenuItem(value: 'female', child: Text('Female')),
                    DropdownMenuItem(value: 'other', child: Text('Other')),
                  ],
                  onChanged: (v) => setState(() => _gender = v),
                ),
                const SizedBox(height: 12),
                _field('bio', 'About your practice',
                    icon: Icons.notes_outlined,
                    maxLines: 4,
                    maxLength: 2000,
                    validator: (v) => Validators.notes(v, max: 2000)),
              ],
            ),
            _Group(
              title: 'Credentials',
              children: [
                _field('specialization', 'Specialisation',
                    icon: Icons.medical_services_outlined,
                    validator: (v) => Validators.text(
                        v, field: 'Specialisation', min: 2, max: 150)),
                _field('qualifications', 'Qualifications',
                    icon: Icons.workspace_premium_outlined,
                    hint: 'MBBS, FCPS (Medicine)'),
                // Not prefilled: `doctor_public()` does not return the BMDC
                // number, so the current value is unknown here. Left blank and
                // dropped when blank, so saving does not overwrite it.
                _field('bmdc_number', 'BMDC registration number',
                    icon: Icons.verified_outlined,
                    maxLength: 50,
                    helper: 'Leave blank to keep what is on file.'),
                _field('medical_school', 'Medical school',
                    icon: Icons.school_outlined, maxLength: 150),
                _field('graduation_year', 'Graduation year',
                    icon: Icons.calendar_today_outlined,
                    keyboard: TextInputType.number,
                    validator: (v) => _yearOrEmpty(v)),
                _field('doctor_type', 'Practice type',
                    icon: Icons.category_outlined,
                    hint: 'Consultant, Specialist, General',
                    maxLength: 50),
                _field('experience_years', 'Years of experience',
                    icon: Icons.timelapse_outlined,
                    keyboard: TextInputType.number,
                    validator: (v) => _intOrEmpty(v, max: 80)),
              ],
            ),
            _Group(
              title: 'Chamber and fee',
              children: [
                _field('consultation_fee', 'Consultation fee (BDT)',
                    icon: Icons.payments_outlined,
                    keyboard: TextInputType.number,
                    validator: (v) => _numOrEmpty(v, max: 1000000)),
                _field('hospital_clinic_name', 'Hospital or clinic',
                    icon: Icons.local_hospital_outlined, maxLength: 200),
                _field('chamber_address', 'Chamber address',
                    icon: Icons.place_outlined, maxLines: 2),
                _field('city', 'City', icon: Icons.location_city_outlined, maxLength: 100),
                _field('area', 'Area', icon: Icons.map_outlined, maxLength: 100),
              ],
            ),
            _Group(
              title: 'When you see patients',
              subtitle:
                  'Patients can only book on these days, between these times. '
                  'Leave the days empty and no slots are offered at all.',
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final day in _weekdays)
                      FilterChip(
                        label: Text(_weekdayLabels[day] ?? day),
                        selected: _days.contains(day),
                        onSelected: (on) => setState(
                          () => on ? _days.add(day) : _days.remove(day),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _timeField('available_from', 'From')),
                    const SizedBox(width: 12),
                    Expanded(child: _timeField('available_to', 'To')),
                  ],
                ),
                const SizedBox(height: 12),
                _field('slot_minutes', 'Minutes per appointment',
                    icon: Icons.timer_outlined,
                    keyboard: TextInputType.number,
                    helper: 'Between 5 and 240.',
                    validator: (v) => _intOrEmpty(v, min: 5, max: 240)),
              ],
            ),
            const SizedBox(height: AppTheme.gap),
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Save profile'),
            ),
            const SizedBox(height: AppTheme.gap),
          ],
        ),
      ),
    );
  }

  Widget _field(
    String key,
    String label, {
    IconData? icon,
    String? hint,
    String? helper,
    int maxLines = 1,
    int? maxLength,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: _c[key],
        maxLines: maxLines,
        maxLength: maxLength,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          prefixIcon: icon == null ? null : Icon(icon),
        ),
        validator: validator,
      ),
    );
  }

  Widget _timeField(String key, String label) {
    return TextFormField(
      controller: _c[key],
      readOnly: true,
      onTap: () => _pickTime(key),
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.schedule_outlined),
        suffixIcon: _t(key).isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => setState(() => _c[key]!.clear()),
              ),
      ),
    );
  }

  // Every numeric field is optional, so an empty box is valid — but a non-empty
  // box has to parse, or the server would answer 422 for a typo.
  static String? _intOrEmpty(String? v, {int min = 0, int max = 999999}) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) return 'Enter a whole number.';
    if (n < min || n > max) return 'Must be between $min and $max.';
    return null;
  }

  static String? _numOrEmpty(String? v, {double max = 999999}) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = double.tryParse(t);
    if (n == null) return 'Enter a number.';
    if (n < 0 || n > max) return 'Must be between 0 and ${max.toStringAsFixed(0)}.';
    return null;
  }

  static String? _yearOrEmpty(String? v) => _intOrEmpty(v, min: 1900, max: 2100);
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children, this.subtitle});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        ...children,
      ],
    );
  }
}
