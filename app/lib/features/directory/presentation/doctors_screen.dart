/// `/directory/doctors` — the searchable doctor directory.
///
/// Search and the specialty filter both re-key the same [PagedController] rather
/// than owning separate lists, so there is exactly one source of truth for what
/// is on screen. Search is debounced: `doctor_list()` runs three LIKEs and a join,
/// and firing that per keystroke is how you turn a dev laptop into a fan heater.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../../../core/constants/app_theme.dart';
import '../../../core/paged_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/paged_list_view.dart';
import '../../../core/widgets/state_views.dart';
import '../../../models/directory_models.dart';
import '../data/directory_repository.dart';

/// The active query. Held above the list controller so the controller can be
/// rebuilt from it without the widget tree having to re-plumb the filters.
@immutable
class DoctorQuery {
  const DoctorQuery({this.search = '', this.specialty});

  final String search;
  final String? specialty;

  DoctorQuery copyWith({String? search, String? specialty, bool clearSpecialty = false}) =>
      DoctorQuery(
        search: search ?? this.search,
        specialty: clearSpecialty ? null : (specialty ?? this.specialty),
      );

  /// Empty strings must not be sent — `doctor_list()` would build
  /// `LIKE '%%'`, which matches everything but still pays for the join.
  String? get searchOrNull => search.trim().isEmpty ? null : search.trim();
}

final doctorQueryProvider = StateProvider<DoctorQuery>((ref) => const DoctorQuery());

/// The specialty chips. Kept out of the paged controller because
/// `/directory/specialties` is unpaginated and changes far less often than the
/// doctor list — folding it in would refetch it on every search keystroke.
final specialtiesProvider = FutureProvider<List<Specialty>>((ref) {
  return ref.watch(directoryRepositoryProvider).specialties();
});

final doctorListProvider =
    StateNotifierProvider<PagedController<Doctor>, PagedState<Doctor>>((ref) {
  final repo = ref.watch(directoryRepositoryProvider);
  final query = ref.watch(doctorQueryProvider);

  // Watching the query means Riverpod disposes and rebuilds this controller when
  // a filter changes, which resets pagination for free.
  return PagedController<Doctor>((page) => repo.doctors(
        page: page,
        search: query.searchOrNull,
        specialty: query.specialty,
      ));
});

class DoctorsScreen extends ConsumerStatefulWidget {
  const DoctorsScreen({super.key});

  @override
  ConsumerState<DoctorsScreen> createState() => _DoctorsScreenState();
}

class _DoctorsScreenState extends ConsumerState<DoctorsScreen> {
  late final TextEditingController _search =
      TextEditingController(text: ref.read(doctorQueryProvider).search);
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final current = ref.read(doctorQueryProvider);
      if (current.search == value) return;
      ref.read(doctorQueryProvider.notifier).state = current.copyWith(search: value);
    });
  }

  void _selectSpecialty(String? name) {
    final current = ref.read(doctorQueryProvider);
    if (name == null) {
      ref.read(doctorQueryProvider.notifier).state = current.copyWith(clearSpecialty: true);
    } else {
      ref.read(doctorQueryProvider.notifier).state = current.copyWith(specialty: name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(doctorListProvider);
    final controller = ref.read(doctorListProvider.notifier);
    final query = ref.watch(doctorQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Find a doctor'),
        actions: [
          IconButton(
            tooltip: 'Clinics',
            icon: const Icon(Icons.local_hospital_outlined),
            onPressed: () => context.push(Routes.clinics),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppTheme.gap, 12, AppTheme.gap, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: (v) {
                // Submitting should not wait out the debounce.
                _debounce?.cancel();
                ref.read(doctorQueryProvider.notifier).state = query.copyWith(search: v);
              },
              decoration: InputDecoration(
                hintText: 'Name, specialty or clinic',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _debounce?.cancel();
                          _search.clear();
                          ref.read(doctorQueryProvider.notifier).state =
                              query.copyWith(search: '');
                        },
                      ),
              ),
            ),
          ),
          _SpecialtyChips(
            selected: query.specialty,
            onSelect: _selectSpecialty,
          ),
          Expanded(
            child: PagedListView<Doctor>(
              state: state,
              onRefresh: controller.refresh,
              onLoadMore: controller.loadMore,
              onRetry: controller.reload,
              emptyTitle: 'No doctors found',
              emptyMessage: query.search.isEmpty && query.specialty == null
                  ? 'The directory has no listings yet.'
                  : 'Try a different search or clear the specialty filter.',
              emptyIcon: Icons.medical_services_outlined,
              itemBuilder: (context, doctor, _) => DoctorCard(doctor: doctor),
            ),
          ),
        ],
      ),
    );
  }
}

/// Horizontally scrolling filter chips, with "All" pinned first.
///
/// A failure here is silent by design: the specialty list is a convenience, and
/// hiding the strip is better than putting an error banner above a doctor list
/// that loaded perfectly well.
class _SpecialtyChips extends ConsumerWidget {
  const _SpecialtyChips({required this.selected, required this.onSelect});

  final String? selected;
  final void Function(String?) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(specialtiesProvider);

    return async.maybeWhen(
      data: (items) {
        if (items.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppTheme.gap),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: const Text('All'),
                  selected: selected == null,
                  onSelected: (_) => onSelect(null),
                ),
              ),
              for (final s in items)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(s.doctorCount > 0 ? '${s.name} (${s.doctorCount})' : s.name),
                    selected: selected == s.name,
                    // Tapping the selected chip clears it — a filter you cannot
                    // undo without hunting for an "All" chip is a trap.
                    onSelected: (on) => onSelect(on ? s.name : null),
                  ),
                ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox(height: 48),
    );
  }
}

/// One doctor row. Shared with the clinic/hospital detail screens, which list
/// their affiliated doctors in the same shape.
class DoctorCard extends StatelessWidget {
  const DoctorCard({super.key, required this.doctor});

  final Doctor doctor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => context.push(Routes.doctorDetail(doctor.id)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RemoteImage(
                path: doctor.image,
                width: 68,
                height: 84,
                radius: AppTheme.radius - 2,
                fallbackIcon: Icons.person_outline,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            doctor.name,
                            style: theme.textTheme.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!doctor.isAvailable)
                          const StatusPill(status: 'inactive', label: 'Unavailable', dense: true),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      doctor.specialty,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (doctor.qualifications != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        doctor.qualifications!,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        _Meta(icon: Icons.star_rounded, text: Fmt.rating(doctor.rating)),
                        _Meta(icon: Icons.work_history_outlined, text: doctor.experienceLabel),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            doctor.workplaceLabel,
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          doctor.feeLabel,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(color: theme.colorScheme.primary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.textTheme.bodySmall?.color),
        const SizedBox(width: 3),
        Text(text, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
