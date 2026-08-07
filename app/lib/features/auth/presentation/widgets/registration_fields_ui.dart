/// Field widgets shared by the five sign-up forms (§3.1–3.5).
///
/// The four provider forms differ only in which of these they show and in what
/// order, so factoring them out keeps each screen a readable list of fields
/// instead of two hundred lines of near-identical `TextFormField` blocks.
///
/// Every field here takes the server error map and prefers it over the local
/// validator, so a 422 lands on the field that caused it.
library;

import 'package:flutter/material.dart';

import '../../../../core/utils/validators.dart';
import '../../data/registration_fields.dart';

/// A labelled text field wired to the server-error convention.
///
/// [wireKey] is the server's field name — both the key looked up in [errors] and
/// the thing that must match the rule list, so the two cannot drift apart.
class RegField extends StatelessWidget {
  const RegField({
    super.key,
    required this.controller,
    required this.label,
    required this.wireKey,
    required this.errors,
    this.hint,
    this.icon,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.sentences,
    this.maxLines = 1,
    this.maxLength,
    this.required = false,
    this.validator,
  });

  final TextEditingController controller;
  final String label;
  final String wireKey;
  final Map<String, String> errors;
  final String? hint;
  final IconData? icon;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final int maxLines;
  final int? maxLength;

  /// Only affects the label's asterisk and the empty check. The server is the
  /// authority on what is genuinely required; this is the hint, not the rule.
  final bool required;

  /// Runs after the server error and the empty check. Return null to accept.
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      maxLines: maxLines,
      maxLength: maxLength,
      textInputAction:
          maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon),
        alignLabelWithHint: maxLines > 1,
        border: maxLines > 1 ? const OutlineInputBorder() : null,
      ),
      validator: (v) {
        final server = errors[wireKey];
        if (server != null) return server;
        final text = (v ?? '').trim();
        if (text.isEmpty) return required ? '$label is required.' : null;
        return validator?.call(v);
      },
    );
  }
}

/// A whole-number field for the `int|min|max` rules.
///
/// Separate from [RegField] because an empty numeric field must send *no key*
/// rather than an empty string — [RegistrationFields] handles the dropping, and
/// this handles rejecting a non-number before the round trip.
class RegNumberField extends StatelessWidget {
  const RegNumberField({
    super.key,
    required this.controller,
    required this.label,
    required this.wireKey,
    required this.errors,
    this.hint,
    this.icon,
    this.min = 0,
    this.max = 100000,
    this.required = false,
    this.decimal = false,
  });

  final TextEditingController controller;
  final String label;
  final String wireKey;
  final Map<String, String> errors;
  final String? hint;
  final IconData? icon;
  final num min;
  final num max;
  final bool required;

  /// True for `consultation_fee`, whose rule is `numeric` rather than `int`.
  final bool decimal;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType:
          decimal ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.number,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(
        labelText: required ? '$label *' : label,
        hintText: hint,
        prefixIcon: icon == null ? null : Icon(icon),
      ),
      validator: (v) {
        final server = errors[wireKey];
        if (server != null) return server;
        final text = (v ?? '').trim();
        if (text.isEmpty) return required ? '$label is required.' : null;
        final n = decimal ? num.tryParse(text) : int.tryParse(text);
        if (n == null) {
          return decimal ? '$label must be a number.' : '$label must be a whole number.';
        }
        if (n < min || n > max) return '$label must be between $min and $max.';
        return null;
      },
    );
  }
}

/// A tappable `HH:MM` field backed by the platform time picker.
///
/// The server's `time` rule wants `HH:MM`; typing that by hand is error-prone, so
/// the field is read-only and the picker is the only way to set it. [value] is
/// null until picked, which keeps the key out of the payload.
class RegTimeField extends StatelessWidget {
  const RegTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon = Icons.schedule_outlined,
  });

  final String label;
  final TimeOfDay? value;
  final ValueChanged<TimeOfDay?> onChanged;
  final IconData icon;

  /// Zero-padded so `9:05` serialises as `09:05` — `H:MM` would fail the rule.
  static String format(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final v = value;
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: v ?? const TimeOfDay(hour: 9, minute: 0),
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          // Lets the user undo a pick — without this the key can never go back to
          // absent once set, and "not stated" is a legitimate answer.
          suffixIcon: v == null
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => onChanged(null),
                ),
        ),
        child: Text(
          v == null ? 'Not set' : format(v),
          style: v == null
              ? TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }
}

/// A labelled switch for the `in:0,1` flags.
class RegSwitch extends StatelessWidget {
  const RegSwitch({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// A dropdown over a fixed set of `max:50`-style free-text values.
///
/// The column is free text server-side, but offering a list keeps the directory
/// filters usable — a table where one row says "Pvt." and the next "Private"
/// cannot be grouped.
class RegDropdown extends StatelessWidget {
  const RegDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon,
  });

  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: icon == null ? null : Icon(icon),
      ),
      items: [
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
      ],
      onChanged: onChanged,
    );
  }
}

/// Weekday multi-select that renders to the comma list `available_days` expects.
///
/// `max:100` free text server-side; chips instead of a text box so the stored
/// value is predictable enough for a profile screen to parse back.
class RegDayPicker extends StatelessWidget {
  const RegDayPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  static const days = ['Sat', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri'];

  /// Emitted in [days] order rather than selection order, so two clinics open the
  /// same days store the same string.
  static String? encode(Set<String> selected) {
    if (selected.isEmpty) return null;
    return days.where(selected.contains).join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Available days', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final d in days)
              FilterChip(
                label: Text(d),
                selected: selected.contains(d),
                onSelected: (on) {
                  final next = {...selected};
                  if (on) {
                    next.add(d);
                  } else {
                    next.remove(d);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

/// Gender dropdown over [Gender], showing labels and yielding the enum.
///
/// A plain [RegDropdown] over `Gender.values.map((g) => g.value)` would put the
/// wire values — `male`, lowercase — in front of the user.
class RegGenderField extends StatelessWidget {
  const RegGenderField({super.key, required this.value, required this.onChanged});

  final Gender? value;
  final ValueChanged<Gender?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<Gender>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Gender',
        prefixIcon: Icon(Icons.person_outline),
      ),
      items: [
        for (final g in Gender.values)
          DropdownMenuItem(value: g, child: Text(g.label)),
      ],
      onChanged: onChanged,
    );
  }
}

/// Shared validators for fields several roles have in common.
class RegValidators {
  const RegValidators._();

  /// `website` and `license_document` are `max:255` strings with no format rule,
  /// so this only catches the obviously-wrong rather than enforcing a scheme.
  static String? url(String? v) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    if (t.length > 255) return 'Keep the address under 255 characters.';
    if (t.contains(' ')) return 'A web address cannot contain spaces.';
    return null;
  }

  /// Bounded by the server's `int|min:1800|max:2100`, and additionally refused if
  /// it is in the future — a hospital established next year is a typo.
  static String? establishedYear(String? v, {int min = 1800}) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    if (n == null) return 'Enter a four-digit year.';
    final now = DateTime.now().year;
    if (n < min || n > now) return 'Enter a year between $min and $now.';
    return null;
  }

  static String? optionalPhone(String? v) => Validators.phone(v, optional: true);
}
