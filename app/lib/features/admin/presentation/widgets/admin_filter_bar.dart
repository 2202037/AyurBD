/// The header every admin list screen wears: a debounced search field and a
/// row of filter chips.
///
/// Nine screens in the console need this. Debouncing in particular is the part
/// worth writing once — a filter provider rebuilds its [PagedController], so
/// pushing every keystroke straight through would fire a request per character
/// and reset the list under the admin's finger.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_theme.dart';

/// One chip. `value` of null is the "everything" option — the filter providers
/// use null for "omit the query param", so the chip strip can express it.
typedef FilterOption = ({String? value, String label});

/// Search field that reports its value 400ms after typing stops.
///
/// Deliberately [StatefulWidget] rather than a controller passed in: the timer
/// and the [TextEditingController] have to be disposed together, and every
/// screen doing that by hand is how a leaked timer ends up calling `ref.read`
/// after the widget is gone.
class DebouncedSearchField extends StatefulWidget {
  const DebouncedSearchField({
    super.key,
    required this.onChanged,
    this.hintText = 'Search',
    this.initialValue,
  });

  /// Called with null when the field is cleared, so callers can pass the value
  /// straight to a nullable filter provider.
  final ValueChanged<String?> onChanged;

  final String hintText;
  final String? initialValue;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  late final TextEditingController _c =
      TextEditingController(text: widget.initialValue ?? '');
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _apply(raw));
  }

  void _apply(String raw) {
    _debounce?.cancel();
    final trimmed = raw.trim();
    widget.onChanged(trimmed.isEmpty ? null : trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      textInputAction: TextInputAction.search,
      onChanged: _onChanged,
      // Submitting jumps the debounce — waiting 400ms after an explicit search
      // is just latency the admin can feel.
      onSubmitted: _apply,
      decoration: InputDecoration(
        hintText: widget.hintText,
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: _c.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _c.clear();
                  _apply('');
                  setState(() {});
                },
              ),
      ),
    );
  }
}

/// Horizontally scrolling chip strip. Scrolls rather than wraps so the header
/// keeps a fixed height — a wrapping row that grows to two lines shifts the
/// list down every time a filter is picked.
class FilterChips extends StatelessWidget {
  const FilterChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: AppTheme.gap),
  });

  final List<FilterOption> options;
  final String? selected;
  final ValueChanged<String?> onSelected;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: [
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(o.label),
                selected: selected == o.value,
                // Tapping the selected chip is a no-op rather than a toggle to
                // null: there is always exactly one filter in effect, and a
                // silent jump back to "all" is not what a second tap means.
                onSelected: (_) {
                  if (selected != o.value) onSelected(o.value);
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Search field plus one chip strip, spaced to match the list padding below it.
/// Drop into `AppBar.bottom` via [PreferredSize] or above a list in a [Column].
class AdminFilterBar extends StatelessWidget {
  const AdminFilterBar({
    super.key,
    this.onSearch,
    this.searchHint = 'Search',
    this.searchValue,
    this.options = const [],
    this.selected,
    this.onSelected,
    this.trailing,
  });

  final ValueChanged<String?>? onSearch;
  final String searchHint;
  final String? searchValue;

  final List<FilterOption> options;
  final String? selected;
  final ValueChanged<String?>? onSelected;

  /// A second row — a date picker, a type dropdown — for the screens that need
  /// more than one axis of filtering.
  final Widget? trailing;

  /// Height of the assembled bar, for [PreferredSize]. Computed rather than a
  /// magic number so removing the search field cannot leave a gap behind.
  double get height =>
      (onSearch != null ? 58 : 0) +
      (options.isEmpty ? 0 : 42) +
      (trailing != null ? 52 : 0) +
      8;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onSearch != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 0, AppTheme.gap, 8),
            child: DebouncedSearchField(
              hintText: searchHint,
              initialValue: searchValue,
              onChanged: onSearch!,
            ),
          ),
        if (options.isNotEmpty && onSelected != null)
          FilterChips(
            options: options,
            selected: selected,
            onSelected: onSelected!,
          ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 4, AppTheme.gap, 4),
            child: trailing,
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
