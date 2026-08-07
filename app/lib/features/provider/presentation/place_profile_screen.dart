/// §7–9 — the hospital / clinic / pharmacy profile form.
///
/// Two wire-format traps, both the same shape as the doctor form's:
///
///  * `place_public()` renames columns on the way out while the PUT expects the
///    real column names. `beds_total` comes back for a `total_beds` column and
///    `is_24h` for `open_24_hours`, so the controllers here are keyed by the
///    *column* name and read from the renamed model field — see [_seed].
///  * `hours` is synthesised server-side by `place_hours()` from
///    `opening_time`/`closing_time`/`open_24_hours`. There is no `hours` column,
///    so the form edits the two times and never sends `hours`.
///
/// Several whitelisted columns are absent from `place_public()` — the licence and
/// registration numbers, `established_year`, the `*_type` fields, `whatsapp`,
/// `owner_name`, `pharmacist_name`, `delivery_radius_km`, `available_days`, and
/// the raw time pair. Those cannot be prefilled, so they open blank with helper
/// text and the repository's `_clean()` drops them when left that way. Blank
/// therefore means "keep what is on file", never "erase it".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/directory_models.dart';
import '../../../models/provider_models.dart';
import '../data/provider_repository.dart';
import 'provider_controllers.dart';
import 'widgets/verification_banner.dart';

class PlaceProfileScreen extends ConsumerStatefulWidget {
  const PlaceProfileScreen({super.key});

  @override
  ConsumerState<PlaceProfileScreen> createState() => _PlaceProfileScreenState();
}

class _PlaceProfileScreenState extends ConsumerState<PlaceProfileScreen> {
  final _form = GlobalKey<FormState>();

  /// Keyed by real column name, so [_payload] needs no translation table.
  final Map<String, TextEditingController> _c = {};

  bool _is24h = false;
  bool _delivery = false;
  bool _saving = false;

  /// The dashboard is the only source of the current profile, and it is what
  /// tells us which role's field set to render — so the form is built from it
  /// rather than fetching separately.
  PlaceKind? _builtFor;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Fills the controllers once the dashboard resolves. Guarded by [_builtFor]
  /// so a rebuild mid-edit does not discard what the user has typed.
  void _seed(PlaceDashboard d) {
    if (_builtFor == d.kind) return;
    _builtFor = d.kind;
    final p = d.profile;

    void put(String column, String? value) {
      _c[column] = TextEditingController(text: value ?? '');
    }

    // Shared across all three tables.
    put('name', p?.name);
    put('phone', p?.phone);
    put('email', p?.email);
    put('website', p?.website);
    put('address', p?.address);
    put('city', p?.city);
    put('area', p?.area);
    // `description` on the row, `about` on the model.
    put('description', p?.about);
    // Not returned by the shaper — `hours` is a composed string, not these.
    put('opening_time', null);
    put('closing_time', null);
    put('established_year', null);
    put('license_number', null);
    put('license_document', null);

    switch (d.kind) {
      case PlaceKind.hospital:
        put('emergency_phone', p?.emergencyPhone);
        put('hospital_type', null);
        // `total_beds` on the row, `bedsTotal` on the model.
        put('total_beds', p?.bedsTotal?.toString());
        put('icu_beds', p?.icuBeds?.toString());
        put('facilities', p?.services.join(', '));
        put('departments', null);
        put('registration_number', null);
      case PlaceKind.clinic:
        put('clinic_type', null);
        put('services', p?.services.join(', '));
        put('specializations', null);
        put('available_days', null);
        put('registration_number', null);
      case PlaceKind.pharmacy:
        put('whatsapp', null);
        put('pharmacy_type', null);
        put('owner_name', null);
        put('pharmacist_name', null);
        put('pharmacist_license', null);
        put('services', p?.services.join(', '));
        put('delivery_radius_km', null);
        put('drug_license_number', null);
        _delivery = p?.deliveryAvailable ?? false;
    }

    _is24h = p?.is24h ?? false;
  }

  // -- validators ------------------------------------------------------------
  // Everything here is optional, so an empty value is valid: blank means "leave
  // the column alone" (see [_clean] in the repository). What these catch is a
  // value that *would* 422 — a stray letter in a bed count, a 5-digit year.

  String? _maxLen(String? v, int max) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    return t.length > max ? 'Keep this under $max characters.' : null;
  }

  String? _minMax(String? v, int min, int max) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    if (t.length < min) return 'At least $min characters.';
    return t.length > max ? 'Keep this under $max characters.' : null;
  }

  String? _emailOrEmpty(String? v) =>
      (v ?? '').trim().isEmpty ? null : Validators.email(v);

  String? _phoneOrEmpty(String? v) => Validators.phone(v, optional: true);

  String? _intOrEmpty(String? v, {int min = 0, int max = 100000}) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) return 'Numbers only.';
    if (n < min || n > max) return 'Enter a value between $min and $max.';
    return null;
  }

  String? _yearOrEmpty(String? v) => _intOrEmpty(v, min: 1800, max: 2100);

  // -- save ------------------------------------------------------------------

  /// Only the columns the caller's role actually has. Sending a hospital field
  /// as a pharmacy is a 422 here, not a silent drop, so the map is assembled per
  /// kind rather than sending every controller.
  Map<String, Object?> _payload(PlaceKind kind) {
    String? f(String k) => _c[k]?.text;

    final shared = <String, Object?>{
      'name': f('name'),
      'phone': f('phone'),
      'email': f('email'),
      'website': f('website'),
      'address': f('address'),
      'city': f('city'),
      'area': f('area'),
      'description': f('description'),
      'opening_time': f('opening_time'),
      'closing_time': f('closing_time'),
      'established_year': f('established_year'),
      'license_number': f('license_number'),
      'license_document': f('license_document'),
    };

    // `open_24_hours` is NOT shared: it is whitelisted for hospital and pharmacy
    // only. A clinic sending it would have it dropped, and the switch below would
    // then be lying about what it wrote.
    return switch (kind) {
      PlaceKind.hospital => {
          ...shared,
          // Booleans go as 0/1 — the rule is `in:0,1`, so a JSON bool fails it.
          'open_24_hours': _is24h ? 1 : 0,
          'emergency_phone': f('emergency_phone'),
          'hospital_type': f('hospital_type'),
          'total_beds': f('total_beds'),
          'icu_beds': f('icu_beds'),
          'facilities': f('facilities'),
          'departments': f('departments'),
          'registration_number': f('registration_number'),
        },
      PlaceKind.clinic => {
          ...shared,
          'clinic_type': f('clinic_type'),
          'services': f('services'),
          'specializations': f('specializations'),
          'available_days': f('available_days'),
          'registration_number': f('registration_number'),
        },
      PlaceKind.pharmacy => {
          ...shared,
          'open_24_hours': _is24h ? 1 : 0,
          'whatsapp': f('whatsapp'),
          'pharmacy_type': f('pharmacy_type'),
          'owner_name': f('owner_name'),
          'pharmacist_name': f('pharmacist_name'),
          'pharmacist_license': f('pharmacist_license'),
          'services': f('services'),
          'delivery_available': _delivery ? 1 : 0,
          'delivery_radius_km': f('delivery_radius_km'),
          'drug_license_number': f('drug_license_number'),
        },
    };
  }

  Future<void> _save(PlaceKind kind) async {
    if (_form.currentState?.validate() != true) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(providerRepositoryProvider)
          .updatePlaceProfile(_payload(kind), kind: kind);
      if (!mounted) return;
      // Invalidated rather than patched: the PUT answers with the profile only
      // and does not recompute the stats, so a patch would leave them stale.
      ref.invalidate(placeDashboardProvider);
      showToast(context, 'Profile updated.');
    } on ApiException catch (e) {
      if (mounted && !e.isUnauthorized) showToast(context, e.message, error: true);
    } catch (_) {
      if (mounted) showToast(context, 'Something went wrong.', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(placeDashboardProvider);

    // `valueOrNull` rather than `when`: saving invalidates the dashboard, and
    // `when(loading:)` would tear the form down and rebuild it on every save.
    // Riverpod keeps the previous value through a refresh, so the form stays put
    // and only a cold load shows the spinner.
    final dash = async.valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: Builder(
        builder: (context) {
          if (dash == null) {
            if (async.hasError) {
              return ErrorView(
                error: async.error!,
                onRetry: () => ref.invalidate(placeDashboardProvider),
              );
            }
            return const LoadingView(message: 'Loading your profile…');
          }

          final d = dash;
          _seed(d);
          return BlockingOverlay(
            busy: _saving,
            message: 'Saving…',
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(AppTheme.gap),
                children: [
                  VerificationBanner(
                    status: d.verification,
                    accountStatus: d.accountStatus,
                  ),
                  const SizedBox(height: AppTheme.gap),
                  ..._sections(d.kind),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : () => _save(d.kind),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save changes'),
                  ),
                  const SizedBox(height: AppTheme.gap),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _sections(PlaceKind kind) => [
        _group('Basics', [
          _field('name', 'Name', validator: (v) => _minMax(v, 2, 200)),
          _field(
            'phone',
            'Phone',
            keyboard: TextInputType.phone,
            validator: _phoneOrEmpty,
          ),
          _field(
            'email',
            'Email',
            keyboard: TextInputType.emailAddress,
            validator: _emailOrEmpty,
          ),
          _field('website', 'Website', validator: (v) => _maxLen(v, 255)),
        ]),
        _group('Where to find you', [
          _field('address', 'Address', validator: (v) => _maxLen(v, 255)),
          _field('city', 'City', validator: (v) => _maxLen(v, 100)),
          _field('area', 'Area', validator: (v) => _maxLen(v, 100)),
        ]),
        _group('Opening hours', [
          // Hospital and pharmacy only — `open_24_hours` is not writable on the
          // clinic table, so offering the switch there would silently do nothing.
          if (kind != PlaceKind.clinic)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _is24h,
              onChanged: (v) => setState(() => _is24h = v),
              title: const Text('Open 24 hours'),
              subtitle:
                  const Text('Patients see this instead of the times below.'),
            ),
          // Blank keeps whatever is on file: the shaper returns the composed
          // `hours` string, never these two columns, so there is nothing to
          // prefill them with.
          _time('opening_time', 'Opens at'),
          _time('closing_time', 'Closes at'),
        ]),
        ..._roleSections(kind),
        _group('About', [
          _field(
            'description',
            'Description',
            maxLines: 4,
            validator: (v) => _maxLen(v, 2000),
          ),
        ]),
      ];

  List<Widget> _roleSections(PlaceKind kind) => switch (kind) {
        PlaceKind.hospital => [
            _group('Hospital details', [
              _field(
                'hospital_type',
                'Hospital type',
                hint: 'General, specialised, teaching…',
                validator: (v) => _maxLen(v, 50),
              ),
              _field(
                'emergency_phone',
                'Emergency phone',
                keyboard: TextInputType.phone,
                validator: _phoneOrEmpty,
              ),
              _field(
                'total_beds',
                'Total beds',
                keyboard: TextInputType.number,
                validator: (v) => _intOrEmpty(v),
              ),
              _field(
                'icu_beds',
                'ICU beds',
                keyboard: TextInputType.number,
                validator: (v) => _intOrEmpty(v),
              ),
              _field(
                'facilities',
                'Facilities',
                hint: 'Comma separated',
                maxLines: 2,
                validator: (v) => _maxLen(v, 2000),
              ),
              _field(
                'departments',
                'Departments',
                hint: 'Comma separated',
                maxLines: 2,
                validator: (v) => _maxLen(v, 2000),
              ),
            ]),
            _group('Registration', _registration(extra: 'registration_number')),
          ],
        PlaceKind.clinic => [
            _group('Clinic details', [
              _field(
                'clinic_type',
                'Clinic type',
                hint: 'Diagnostic, dental, general…',
                validator: (v) => _maxLen(v, 50),
              ),
              _field(
                'services',
                'Services',
                hint: 'Comma separated',
                maxLines: 2,
                validator: (v) => _maxLen(v, 2000),
              ),
              _field(
                'specializations',
                'Specialisations',
                hint: 'Comma separated',
                maxLines: 2,
                validator: (v) => _maxLen(v, 2000),
              ),
              _field(
                'available_days',
                'Open days',
                hint: 'e.g. Sat,Sun,Mon',
                validator: (v) => _maxLen(v, 100),
              ),
            ]),
            _group('Registration', _registration(extra: 'registration_number')),
          ],
        PlaceKind.pharmacy => [
            _group('Pharmacy details', [
              _field(
                'pharmacy_type',
                'Pharmacy type',
                hint: 'Retail, wholesale, hospital…',
                validator: (v) => _maxLen(v, 50),
              ),
              _field(
                'whatsapp',
                'WhatsApp',
                keyboard: TextInputType.phone,
                validator: _phoneOrEmpty,
              ),
              _field('owner_name', 'Owner name',
                  validator: (v) => _maxLen(v, 150)),
              _field('pharmacist_name', 'Pharmacist name',
                  validator: (v) => _maxLen(v, 150)),
              _field('pharmacist_license', 'Pharmacist licence',
                  validator: (v) => _maxLen(v, 100)),
              _field(
                'services',
                'Services',
                hint: 'Comma separated',
                maxLines: 2,
                validator: (v) => _maxLen(v, 2000),
              ),
            ]),
            _group('Delivery', [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _delivery,
                onChanged: (v) => setState(() => _delivery = v),
                title: const Text('Home delivery'),
              ),
              if (_delivery)
                _field(
                  'delivery_radius_km',
                  'Delivery radius (km)',
                  keyboard: TextInputType.number,
                  validator: (v) => _intOrEmpty(v, max: 500),
                ),
            ]),
            _group(
              'Licences',
              _registration(extra: 'drug_license_number',
                  extraLabel: 'Drug licence number'),
            ),
          ],
      };

  /// The licence block is identical bar one field, so it is shared rather than
  /// written out three times.
  List<Widget> _registration({
    required String extra,
    String extraLabel = 'Registration number',
  }) =>
      [
        _field(
          'established_year',
          'Established year',
          keyboard: TextInputType.number,
          validator: _yearOrEmpty,
        ),
        _field(extra, extraLabel, validator: (v) => _maxLen(v, 100)),
        _field('license_number', 'Licence number',
            validator: (v) => _maxLen(v, 100)),
        _field(
          'license_document',
          'Licence document URL',
          validator: (v) => _maxLen(v, 255),
        ),
      ];

  Widget _group(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          ...children,
          const SizedBox(height: 12),
        ],
      );

  Widget _field(
    String key,
    String label, {
    String? hint,
    int maxLines = 1,
    TextInputType? keyboard,
    String? Function(String?)? validator,
  }) {
    final c = _c[key];
    // A controller is only created for the columns the caller's role has, so a
    // field asked for outside its role renders nothing rather than throwing.
    if (c == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        maxLines: maxLines,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: c.text.isEmpty ? 'Leave blank to keep what is on file.' : null,
        ),
        validator: validator,
      ),
    );
  }

  Widget _time(String key, String label) {
    final c = _c[key];
    if (c == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: c,
        readOnly: true,
        onTap: () => _pickTime(key),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.schedule_outlined),
          suffixIcon: c.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => setState(c.clear),
                ),
        ),
      ),
    );
  }

  Future<void> _pickTime(String key) async {
    final parts = _c[key]!.text.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: parts.isNotEmpty ? int.tryParse(parts[0]) ?? 9 : 9,
        minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
      ),
    );
    if (picked == null) return;
    // `HH:MM:SS` — what the server's `time` rule accepts and what
    // `place_hours()` reads back to compose the public string.
    final hh = picked.hour.toString().padLeft(2, '0');
    final mm = picked.minute.toString().padLeft(2, '0');
    setState(() => _c[key]!.text = '$hh:$mm:00');
  }
}
